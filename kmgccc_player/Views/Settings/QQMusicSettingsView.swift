//
//  QQMusicSettingsView.swift
//  kmgccc_player
//
//  Settings page for the online QQ Music source.
//
//  Three concerns live here:
//  - Account: QR login, status, logout. Anonymous sessions are rate limited by
//    the upstream after a handful of requests, so logging in is what makes
//    browsing stable, not just a way to reach VIP tracks.
//  - Helper runtime: version and capabilities, plus the update path. The helper
//    is versioned independently of the app, so a newer build can be dropped in
//    without rebuilding.
//  - Behaviour: download quality preference.
//

import AppKit
import SwiftUI

@MainActor
struct QQMusicSettingsView: View {

    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var loginStatus: QQMusicLoginStatus?
    @State private var helperInfo: QQMusicHelperInfo?
    @State private var qrCode: QQMusicLoginQRCode?
    @State private var qrImage: NSImage?
    @State private var isCheckingStatus = false
    @State private var isStartingLogin = false
    @State private var statusText: String?
    @State private var statusIsError = false
    @State private var pollTask: Task<Void, Never>?
    @State private var cacheSizeText = "计算中…"


    /// Supplied by the window manager so the page can report and clear the
    /// online source's cache. Nil when no library session is active.
    var coordinator: QQMusicOnlineCoordinator?

    private let helper = QQMusicHelperProcess.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyleTokens.sectionSpacing) {
                accountSection
                helperSection
                behaviourSection
                cacheSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(ThemedBaseBackgroundColorView())
        .task {
            await refreshStatus()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private var cacheDirectoryPath: String? {
        guard let root = coordinator?.libraryRootURL else { return nil }
        return root.appendingPathComponent("QQMusic", isDirectory: true).path
    }

    private func refreshCacheSize() async {
        guard let store = coordinator?.cacheStore else {
            cacheSizeText = coordinator == nil ? "资料库未就绪" : "不可用"
            return
        }
        let bytes = await store.diskUsageBytes()
        cacheSizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func clearCache() async {
        guard let store = coordinator?.cacheStore else { return }
        await store.clearAll()
        await refreshCacheSize()
        statusIsError = false
        statusText = "缓存已清除"
    }

    private func revealCacheDirectory() {
        guard let path = cacheDirectoryPath else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Account

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
            SettingsHeaderLabel(title: "账号", systemImage: "person.crop.circle")

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(isLoggedIn ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(accountSummary)
                        .settingsRowLabelStyle()
                    Spacer()
                    if isCheckingStatus {
                        ProgressView().controlSize(.small)
                    }
                }

                if let loginStatus, loginStatus.loggedIn {
                    if loginStatus.isVip {
                        labeledValue("会员", "已开通")
                    }
                    HStack(spacing: 8) {
                        Button("退出登录") {
                            Task { await performLogout() }
                        }
                        Spacer()
                    }
                } else if qrCode != nil {
                    qrLoginPanel
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("未登录时，QQ 音乐接口在少量请求后会触发风控，浏览歌单和推荐会不稳定。登录后即可正常使用。")
                            .settingsDescriptionStyle()

                        HStack(spacing: 8) {
                            Button("网页登录") {
                                presentWebLogin()
                            }
                            .buttonStyle(.borderedProminent)
                            Spacer()
                        }
                        Text("打开 QQ 音乐官方登录页，登录完成后自动获取凭证。推荐这种方式：登录页可以处理它自己要求的验证。")
                            .settingsDescriptionStyle()

                        Divider().opacity(0.4)

                        HStack(spacing: 8) {
                            ForEach(QQMusicLoginType.allCases, id: \.self) { type in
                                Button("扫码（\(type.displayName)）") {
                                    Task { await startLogin(type) }
                                }
                                .disabled(isStartingLogin)
                            }
                            if isStartingLogin {
                                ProgressView().controlSize(.small)
                            }
                            Spacer()
                        }
                    }
                }

                if let statusText {
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusIsError ? Color.orange : Color.secondary)
                }
            }
            .padding(SettingsStyleTokens.groupPadding)
            .background(sectionBackground)
        }
    }

    private var qrLoginPanel: some View {
        HStack(alignment: .top, spacing: 14) {
            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 132, height: 132)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 132, height: 132)
                    .overlay(ProgressView())
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("请用手机 QQ 或微信扫描二维码")
                    .settingsRowLabelStyle()
                Text(qrHint)
                    .settingsDescriptionStyle()
                Button("取消") {
                    cancelLogin()
                }
            }
            Spacer()
        }
    }

    private var qrHint: String {
        switch qrCode?.identifier.isEmpty {
        case .some(true): return "二维码生成失败，请重试"
        default: break
        }
        if let event = loginStatus?.event {
            switch event {
            case "SCAN": return "已扫描，请在手机上确认登录"
            case "CONF": return "已确认，正在完成登录…"
            case "TIMEOUT": return "二维码已过期，请重新生成"
            case "REFUSE": return "已取消登录"
            default: return "等待扫码…"
            }
        }
        return "等待扫码…"
    }

    private var isLoggedIn: Bool { loginStatus?.loggedIn == true }

    private var accountSummary: String {
        guard let loginStatus else { return "正在检查登录状态…" }
        guard loginStatus.loggedIn else { return "未登录（匿名模式）" }
        if let nickname = loginStatus.nickname, !nickname.isEmpty {
            return "已登录：\(nickname)"
        }
        if let musicId = loginStatus.musicId {
            return "已登录（ID \(musicId)）"
        }
        return "已登录"
    }

    // MARK: - Helper runtime

    private var helperSection: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
            SettingsHeaderLabel(title: "QQ 音乐组件", systemImage: "shippingbox")

            VStack(alignment: .leading, spacing: 10) {
                labeledValue("组件版本", helperInfo?.helperVersion ?? "未知")
                labeledValue("协议版本", helperInfo.map { "v\($0.protocolVersion)" } ?? "未知")
                labeledValue("接口库版本", helperInfo?.libraryVersion ?? "未知")

                Text("QQ 音乐的接口是逆向来的，随时可能变化。组件与应用分离，可单独更新：把新版 qqmusic-helper 放入下方目录即可，无需重新构建应用。")
                    .settingsDescriptionStyle()

                labeledValue("组件目录", QQMusicHelperProcess.externalHelperDirectory.path, monospaced: true)

                HStack(spacing: 8) {
                    Button("在访达中显示") {
                        revealHelperDirectory()
                    }
                    Button("重新检查") {
                        Task { await refreshStatus() }
                    }
                    Spacer()
                }
            }
            .padding(SettingsStyleTokens.groupPadding)
            .background(sectionBackground)
        }
    }

    // MARK: - Behaviour

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
            SettingsHeaderLabel(title: "播放与下载", systemImage: "arrow.down.circle")

            VStack(alignment: .leading, spacing: 12) {
                Text("在线歌曲会先下载到本地曲库再播放，因此和本地歌曲完全一致（无缝播放、原生歌词、频谱）。播放时会在后台预取接下来的几首。")
                    .settingsDescriptionStyle()
            }
            .padding(SettingsStyleTokens.groupPadding)
            .background(sectionBackground)
        }
    }

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
            SettingsHeaderLabel(title: "缓存", systemImage: "internaldrive")

            VStack(alignment: .leading, spacing: 10) {
                Text("在线内容的封面、歌单、排行榜和歌词会缓存在本地，避免重复请求上游（也是触发风控的主要原因）。缓存独立存放在下面这个目录，与应用自身的缓存分开管理。")
                    .settingsDescriptionStyle()

                labeledValue("缓存占用", cacheSizeText)
                labeledValue("缓存目录", cacheDirectoryPath ?? "资料库未就绪", monospaced: true)

                HStack(spacing: 8) {
                    Button("清除缓存") {
                        Task { await clearCache() }
                    }
                    Button("在访达中显示") {
                        revealCacheDirectory()
                    }
                    Spacer()
                }
            }
            .padding(SettingsStyleTokens.groupPadding)
            .background(sectionBackground)
        }
        .task {
            await refreshCacheSize()
        }
    }

    private func labeledValue(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .settingsRowLabelStyle()
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var sectionBackground: some View {
        RoundedRectangle(cornerRadius: SettingsStyleTokens.sectionCornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.04))
    }

    // MARK: - Actions

    private func refreshStatus() async {
        isCheckingStatus = true
        defer { isCheckingStatus = false }
        do {
            helperInfo = try await helper.helperInfo()
        } catch {
            helperInfo = nil
            Log.warning("[QQMusicSettings] helper info failed: \(error)", category: .import)
        }
        do {
            loginStatus = try await helper.loginStatus()
            statusText = nil
        } catch {
            statusIsError = true
            statusText = "无法连接组件：\(error.localizedDescription)"
        }
    }

    private func startLogin(_ type: QQMusicLoginType) async {
        isStartingLogin = true
        defer { isStartingLogin = false }
        cancelLogin()
        do {
            let qr = try await helper.startLogin(type: type)
            qrCode = qr
            qrImage = decodeQRImage(qr)
            loginStatus = QQMusicLoginStatus(loggedIn: false, event: "WAIT")
            statusIsError = false
            statusText = nil
            beginPolling(qr)
        } catch {
            statusIsError = true
            statusText = "生成二维码失败：\(error.localizedDescription)"
        }
    }

    private func decodeQRImage(_ qr: QQMusicLoginQRCode) -> NSImage? {
        guard let data = Data(base64Encoded: qr.imageBase64) else { return nil }
        return NSImage(data: data)
    }

    /// Poll the QR code until it is accepted, refused, or times out.
    private func beginPolling(_ qr: QQMusicLoginQRCode) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            // Upstream QR codes expire after a few minutes.
            let deadline = Date().addingTimeInterval(180)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let status = try await helper.pollLogin(qr)
                    loginStatus = status
                    if status.loggedIn {
                        qrCode = nil
                        qrImage = nil
                        statusIsError = false
                        statusText = "登录成功"
                        // A logged-in session changes what the catalogue grants.
                        await refreshStatus()
                        return
                    }
                    if status.event == "TIMEOUT" || status.event == "REFUSE" {
                        qrCode = nil
                        qrImage = nil
                        statusIsError = true
                        statusText = status.event == "TIMEOUT" ? "二维码已过期，请重新生成" : "登录已取消"
                        return
                    }
                } catch {
                    statusIsError = true
                    statusText = "登录状态检查失败：\(error.localizedDescription)"
                    return
                }
            }
            if !Task.isCancelled, qrCode != nil {
                qrCode = nil
                qrImage = nil
                statusIsError = true
                statusText = "二维码已过期，请重新生成"
            }
        }
    }

    private func cancelLogin() {
        pollTask?.cancel()
        pollTask = nil
        qrCode = nil
        qrImage = nil
    }

    private func performLogout() async {
        cancelLogin()
        do {
            loginStatus = try await helper.logout()
            statusIsError = false
            statusText = "已退出登录"
        } catch {
            statusIsError = true
            statusText = "退出失败：\(error.localizedDescription)"
        }
    }

    /// Open the official login page in a web view and adopt its cookies.
    private func presentWebLogin() {
        cancelLogin()
        statusText = "请在打开的窗口中登录…"
        statusIsError = false

        let window = QQMusicWebLoginWindow.shared
        window.onCookies = { cookies in
            Task { @MainActor in
                do {
                    let status = try await helper.importCookies(cookies)
                    loginStatus = status
                    statusIsError = false
                    statusText = status.hasPlaybackKey == true
                        ? "登录成功（已获取播放票据）"
                        : "登录成功"
                    await refreshStatus()
                } catch {
                    statusIsError = true
                    statusText = "保存登录信息失败：\(error.localizedDescription)"
                }
            }
        }
        window.onCancel = {
            Task { @MainActor in
                statusIsError = false
                statusText = "已取消登录"
            }
        }
        window.present()
    }

    private func revealHelperDirectory() {
        let directory = QQMusicHelperProcess.externalHelperDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}
