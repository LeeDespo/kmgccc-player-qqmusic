//
//  QQMusicSettingsView.swift
//  kmgccc_player
//
//  The QQ Music window.
//
//  Mirrors the app's own settings surface — `NavigationSplitView` with a
//  category sidebar, a close button drawn inside the content, and the same
//  themed base background — so it reads as part of the same application rather
//  than a separate utility window. The category list is specific to this
//  feature; the app's own settings scene is untouched.
//

import AppKit
import SwiftUI

/// Pages of the QQ Music window.
enum QQMusicSettingsCategory: String, CaseIterable, Identifiable {
    case account
    case browse
    case playback
    case helper
    case cache

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .account: return "账号"
        case .browse: return "在线内容"
        case .playback: return "播放与下载"
        case .helper: return "Helper 组件"
        case .cache: return "缓存"
        }
    }

    var systemImage: String {
        switch self {
        case .account: return "person.crop.circle"
        case .browse: return "square.grid.2x2"
        case .playback: return "play.circle"
        case .helper: return "shippingbox"
        case .cache: return "internaldrive"
        }
    }
}

@MainActor
struct QQMusicSettingsView: View {

    var coordinator: QQMusicOnlineCoordinator?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var selection: QQMusicSettingsCategory = .account
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    // Account
    @State private var loginStatus: QQMusicLoginStatus?
    @State private var qrCode: QQMusicLoginQRCode?
    @State private var qrImage: NSImage?
    @State private var isCheckingStatus = false
    @State private var isStartingLogin = false
    @State private var statusText: String?
    @State private var statusIsError = false
    @State private var pollTask: Task<Void, Never>?

    // Helper
    @State private var helperInfo: QQMusicHelperInfo?

    // Cache
    @State private var cacheSizeText = "计算中…"

    private let helper = QQMusicHelperProcess.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: GlassStyleTokens.sidebarMinWidth,
                    ideal: GlassStyleTokens.sidebarWidth,
                    max: 300
                )
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(selection.title)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(.top, 18)
                .padding(.trailing, 20)
        }
        .frame(minWidth: 700, minHeight: 560)
        .scrollContentBackground(.hidden)
        .background(ThemedBaseBackgroundColorView())
        .environment(\.settingsAppForegroundColors, appForegroundColors)
        .foregroundStyle(appForegroundColors.primary)
        .task {
            await refreshStatus()
            await refreshCacheSize()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private var appForegroundColors: SettingsAppForegroundColors {
        let palette = themeStore.appForegroundPalette
        return SettingsAppForegroundColors(
            primary: palette.primaryColor,
            secondary: palette.secondaryColor,
            tertiary: palette.tertiaryColor,
            quaternary: palette.quaternaryColor,
            disabled: palette.disabledColor
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            Text("QQ 音乐")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 12)

            List(QQMusicSettingsCategory.allCases) { category in
                Button {
                    selection = category
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: category.systemImage)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 20)
                            .foregroundStyle(
                                selection == category
                                    ? themeStore.accentColor
                                    : themeStore.appForegroundPalette.secondaryColor
                            )
                        Text(category.title)
                            .font(.body)
                            .fontWeight(selection == category ? .medium : .regular)
                            .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                .listRowBackground(
                    Capsule()
                        .fill(selection == category ? themeStore.selectionFill : Color.clear)
                        .padding(.horizontal, 14)
                )
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Material.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: GlassStyleTokens.headerStandardIconSize, weight: .semibold))
                .foregroundStyle(themeStore.accentColor.opacity(colorScheme == .dark ? 0.94 : 0.84))
                .frame(
                    width: GlassStyleTokens.headerControlHeight,
                    height: GlassStyleTokens.headerControlHeight
                )
                .contentShape(Circle())
                .liquidGlassCircle(
                    colorScheme: colorScheme,
                    accentColor: nil as Color?,
                    isFloating: true
                )
        }
        .buttonStyle(.plain)
        .help("关闭")
    }

    // MARK: - Detail

    private var detailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyleTokens.sectionSpacing) {
                if let statusText {
                    statusBanner(statusText)
                }
                switch selection {
                case .account:
                    accountSection
                case .browse:
                    browseSection
                case .playback:
                    playbackSection
                case .helper:
                    helperSection
                case .cache:
                    cacheSection
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func statusBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(statusIsError ? Color.orange : themeStore.accentColor)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(SettingsStyleTokens.groupPadding)
        .background(
            RoundedRectangle(cornerRadius: SettingsStyleTokens.sectionCornerRadius, style: .continuous)
                .fill((statusIsError ? Color.orange : themeStore.accentColor).opacity(0.10))
        )
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
                    if loginStatus.hasPlaybackKey == false {
                        Text("未取到播放票据，VIP 歌曲可能无法获取播放地址。建议重新登录。")
                            .settingsDescriptionStyle()
                    }
                    HStack {
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
                Button("取消") { cancelLogin() }
            }
            Spacer()
        }
    }

    private var qrHint: String {
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

    // MARK: - Browse

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
            SettingsHeaderLabel(title: "在线内容", systemImage: "square.grid.2x2")

            VStack(alignment: .leading, spacing: 12) {
                Text("“猜你喜欢”每次向上游取 5 首。滑到底或当前队列快播完时会自动取下一批，并过滤掉已在列表里的歌曲。")
                    .settingsDescriptionStyle()
                labeledValue("每次取回", "5 首／次（上游限制）")
                Text("推荐、歌单与封面会缓存在本地，短时间内重复进入不会重新请求上游，这也是避免风控的主要手段。")
                    .settingsDescriptionStyle()
            }
            .padding(SettingsStyleTokens.groupPadding)
            .background(sectionBackground)
        }
    }

    // MARK: - Playback

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
            SettingsHeaderLabel(title: "播放与下载", systemImage: "play.circle")

            VStack(alignment: .leading, spacing: 14) {
                Text("在线歌曲会先下载到本地曲库再播放，因此和本地歌曲完全一致（无缝播放、原生歌词、频谱）。")
                    .settingsDescriptionStyle()

                prefetchDepthRow
                Divider().opacity(0.4)
                qualityRow
            }
            .padding(SettingsStyleTokens.groupPadding)
            .background(sectionBackground)
        }
    }

    private var prefetchDepthRow: some View {
        let settings = AppSettings.shared
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("预下载数量")
                    .settingsRowLabelStyle()
                Spacer()
                Text(settings.qqMusicPrefetchDepth == 0
                     ? "关闭"
                     : "\(settings.qqMusicPrefetchDepth) 首")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // 0 is a valid choice: download exactly what you play, nothing ahead.
            Slider(
                value: Binding(
                    get: { Double(settings.qqMusicPrefetchDepth) },
                    set: { settings.qqMusicPrefetchDepth = Int($0.rounded()) }
                ),
                in: 0...5,
                step: 1
            )
            .tint(themeStore.accentColor)
            Text(settings.qqMusicPrefetchDepth == 0
                 ? "不预取：只下载你实际播放的那一首，播放下一首时需要等待下载。"
                 : "播放当前歌曲时，后台提前下载接下来的 \(settings.qqMusicPrefetchDepth) 首，播完自动续上。")
                .settingsDescriptionStyle()
        }
    }

    private var qualityRow: some View {
        let settings = AppSettings.shared
        return VStack(alignment: .leading, spacing: 6) {
            Text("下载品质")
                .settingsRowLabelStyle()
            Picker("", selection: Binding(
                get: { settings.qqMusicPreferredQuality },
                set: { settings.qqMusicPreferredQuality = $0 }
            )) {
                ForEach(QQMusicQualityPreference.allCases, id: \.self) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Text(settings.qqMusicPreferredQuality.detail)
                .settingsDescriptionStyle()
        }
    }

    // MARK: - Helper

    private var helperSection: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
            SettingsHeaderLabel(title: "Helper 组件", systemImage: "shippingbox")

            VStack(alignment: .leading, spacing: 10) {
                labeledValue("组件版本", helperInfo?.helperVersion ?? "未知")
                labeledValue("协议版本", helperInfo.map { "v\($0.protocolVersion)" } ?? "未知")
                labeledValue("接口库版本", helperInfo?.libraryVersion ?? "未知")

                Text("QQ 音乐的接口是逆向来的，随时可能变化。Helper 与应用分离，可单独更新：把新版 qqmusic-helper 及其 _internal.bundle 放入下方目录即可，无需重新构建应用。")
                    .settingsDescriptionStyle()

                labeledValue("组件目录", QQMusicHelperProcess.externalHelperDirectory.path, monospaced: true)

                HStack(spacing: 8) {
                    Button("在访达中显示") { revealHelperDirectory() }
                    Button("重新检查") { Task { await refreshStatus() } }
                    Spacer()
                }
            }
            .padding(SettingsStyleTokens.groupPadding)
            .background(sectionBackground)
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
            SettingsHeaderLabel(title: "缓存", systemImage: "internaldrive")

            VStack(alignment: .leading, spacing: 10) {
                Text("在线内容的歌单、推荐、排行榜和封面会缓存在本地，避免重复请求上游（也是触发风控的主要原因）。缓存独立存放在下面这个目录，与应用自身的缓存分开管理。")
                    .settingsDescriptionStyle()

                labeledValue("缓存占用", cacheSizeText)
                labeledValue("缓存目录", cacheDirectoryPath ?? "资料库未就绪", monospaced: true)

                HStack(spacing: 8) {
                    Button("清除缓存") { Task { await clearCache() } }
                    Button("在访达中显示") { revealCacheDirectory() }
                    Spacer()
                }
            }
            .padding(SettingsStyleTokens.groupPadding)
            .background(sectionBackground)
        }
    }

    // MARK: - Shared bits

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

    private var cacheDirectoryPath: String? {
        guard let root = coordinator?.libraryRootURL else { return nil }
        return root.appendingPathComponent("QQMusic", isDirectory: true).path
    }

    // MARK: - Actions

    private func refreshStatus() async {
        isCheckingStatus = true
        defer { isCheckingStatus = false }
        helperInfo = try? await helper.helperInfo()
        do {
            loginStatus = try await helper.loginStatus()
        } catch {
            statusIsError = true
            statusText = "无法连接 Helper：\(error.localizedDescription)"
        }
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

    private func beginPolling(_ qr: QQMusicLoginQRCode) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
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

    private func revealCacheDirectory() {
        guard let path = cacheDirectoryPath else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
