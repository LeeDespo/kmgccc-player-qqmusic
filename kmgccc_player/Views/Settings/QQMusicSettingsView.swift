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
    /// Usage strings for the two budgets. Kept as state so the numbers shown
    /// next to the limits are the ones the limits are applied to.
    @State private var songCacheUsageText = "计算中…"
    @State private var otherCacheUsageText = "计算中…"
    @State private var isReclaiming = false
    @State private var circuitState: QQMusicCircuitState?
    /// What the helper process reports it is actually using, so a setting that
    /// never reaches it is visible rather than silent.
    @State private var effectiveCircuit: QQMusicCircuitConfiguration?

    private let helper = QQMusicHelperProcess.shared

    /// Fixed window size for the settings sheet.
    ///
    /// Sized a little wider than the app's own settings (760×680 minimum) since
    /// this window carries its own sidebar, and tall enough that only the longest
    /// page (缓存) needs to scroll.
    private static let windowWidth: CGFloat = 860
    private static let windowHeight: CGFloat = 680

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
        // A fixed size, like the app's own settings window.
        //
        // With only minimums the sheet sized itself to whichever section was
        // selected, so the window grew and shrank as the user moved between
        // pages. Each page scrolls inside this frame instead, which keeps the
        // window still and puts the overflow somewhere the user can reach it.
        .frame(width: Self.windowWidth, height: Self.windowHeight)
        .scrollContentBackground(.hidden)
        .background(ThemedBaseBackgroundColorView())
        .environment(\.settingsAppForegroundColors, appForegroundColors)
        .foregroundStyle(appForegroundColors.primary)
        .task {
            await refreshStatus()
            await refreshCacheSize()
        }
        // The cache figures describe the library, which keeps changing while
        // this window is open (every playback session downloads). Recomputing on
        // arrival means the number shown is the one the limits apply to now,
        // rather than whatever was true when the window opened.
        .onChange(of: selection) { _, _ in
            Task { await refreshCacheSize() }
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

                Divider().opacity(0.4)

                Text("“我的”页可查看账号的收藏与自建歌单（我喜欢 / 收藏专辑 / 我的歌单）。")
                    .settingsDescriptionStyle()
                Text("收藏（喜欢）可在播放栏直接操作，上游需要几秒同步。歌单的新建、改名、增删目前无法在应用内完成。")
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
                Divider().opacity(0.4)
                likeButtonRow
                Divider().opacity(0.4)
                preloadRow
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
                 : "播放当前歌曲时，后台按播放顺序提前下载接下来的 \(settings.qqMusicPrefetchDepth) 首，播完自动续上。随机播放时这个值越大越不容易在切歌时等待。")
                .settingsDescriptionStyle()
        }
    }

    private var preloadRow: some View {
        let settings = AppSettings.shared
        return VStack(alignment: .leading, spacing: 6) {
            SettingsSwitchRow(
                title: "启动时预加载在线内容",
                isOn: Binding(
                    get: { settings.qqMusicPreloadOnLaunch },
                    set: { settings.qqMusicPreloadOnLaunch = $0 }
                ),
                detail: "应用启动后后台获取猜你喜欢、新歌电台与电台列表，打开 QQ 音乐页时内容已就绪。会提前消耗一些流量与上游请求。"
            )
        }
    }

    private var likeButtonRow: some View {
        let settings = AppSettings.shared
        return VStack(alignment: .leading, spacing: 6) {
            SettingsSwitchRow(
                title: "在播放栏显示收藏按钮",
                isOn: Binding(
                    get: { settings.qqMusicShowLikeButton },
                    set: { settings.qqMusicShowLikeButton = $0 }
                ),
                detail: "为从 QQ 音乐下载的歌曲显示心形按钮，可直接收藏到账号的「我喜欢」。本地歌曲没有对应的在线条目，不显示该按钮。"
            )
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
                labeledValue("QQMusicAPI 版本", helperInfo?.libraryVersion ?? "未知")

                Text("QQ 音乐的接口是逆向来的，随时可能变化。Helper 与应用分离，可单独更新：把新版 qqmusic-helper 及其 _internal.bundle 放入下方目录即可，无需重新构建应用。")
                    .settingsDescriptionStyle()

                labeledValue("组件目录", QQMusicHelperProcess.externalHelperDirectory.path, monospaced: true)

                Divider().opacity(0.4)

                stepperRow(
                    title: "空闲保持时间",
                    value: Binding(
                        get: { AppSettings.shared.qqMusicHelperIdleSeconds },
                        set: { AppSettings.shared.qqMusicHelperIdleSeconds = $0 }
                    ),
                    range: 30...1800,
                    unit: "秒",
                    step: 30,
                    detail: "组件在空闲这么久之后退出。保持得久一些可以避免每次切页都重新启动组件（这是感觉变慢的主要原因），代价是常驻内存。"
                )

                if let effective = effectiveCircuit {
                    Text("组件当前生效：\(effective.idleSeconds) 秒")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("在访达中显示") { revealHelperDirectory() }
                    Button("重新检查") { Task { await refreshStatus() } }
                    Spacer()
                }
            }
            .padding(SettingsStyleTokens.groupPadding)
            .background(sectionBackground)

            noticesSection
            circuitBreakerSection
        }
        .onChange(of: AppSettings.shared.qqMusicCircuitBreakerEnabled) { _, _ in
            Task { await pushCircuitConfiguration() }
        }
        .onChange(of: AppSettings.shared.qqMusicCircuitFailureThreshold) { _, _ in
            Task { await pushCircuitConfiguration() }
        }
        .onChange(of: AppSettings.shared.qqMusicCircuitFailureWindowSeconds) { _, _ in
            Task { await pushCircuitConfiguration() }
        }
        .onChange(of: AppSettings.shared.qqMusicCircuitOpenSeconds) { _, _ in
            Task { await pushCircuitConfiguration() }
        }
        .onChange(of: AppSettings.shared.qqMusicHelperIdleSeconds) { _, _ in
            Task { await pushCircuitConfiguration() }
        }
    }

    /// Which problem messages the browse page is allowed to show.
    private var noticesSection: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
            SettingsHeaderLabel(title: "提示与通知", systemImage: "bell")

            VStack(alignment: .leading, spacing: 12) {
                SettingsSwitchRow(
                    title: "显示熔断与限流提示",
                    isOn: Binding(
                        get: { AppSettings.shared.qqMusicShowCircuitNotices },
                        set: { AppSettings.shared.qqMusicShowCircuitNotices = $0 }
                    ),
                    detail: "请求过于频繁、被暂停等提示。关闭后这类提示不再显示，请求行为不受影响。"
                )
                SettingsSwitchRow(
                    title: "显示其他异常提示",
                    isOn: Binding(
                        get: { AppSettings.shared.qqMusicShowGeneralNotices },
                        set: { AppSettings.shared.qqMusicShowGeneralNotices = $0 }
                    ),
                    detail: "加载失败、导入失败等提示。关闭后同样不再显示。"
                )
            }
            .padding(SettingsStyleTokens.groupPadding)
            .background(sectionBackground)
        }
    }

    /// Circuit breaker controls.
    ///
    /// The breaker exists so a failing upstream is not hammered; the defaults
    /// suit a flaky network. These controls exist because the right trade-off
    /// depends on the account and connection, and because waiting out an
    /// automatic cooldown is pointless when the upstream is already reachable.
    private var circuitBreakerSection: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
            SettingsHeaderLabel(title: "熔断", systemImage: "bolt.horizontal.circle")

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(circuitStateIsOpen ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text(circuitStateText)
                        .settingsRowLabelStyle()
                    Spacer()
                    if circuitStateIsOpen {
                        Button("立即恢复") { resetCircuitBreaker() }
                    }
                }

                SettingsSwitchRow(
                    title: "启用自动熔断",
                    isOn: Binding(
                        get: { AppSettings.shared.qqMusicCircuitBreakerEnabled },
                        set: { AppSettings.shared.qqMusicCircuitBreakerEnabled = $0 }
                    ),
                    detail: "连续请求失败达到阈值时暂停一段时间，避免持续冲击上游。关闭后每个请求都会尝试。"
                )

                if let effective = effectiveCircuit {
                    Text("组件当前生效：\(effectiveSummary(effective))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("组件进程真正在用的值。改上面的数字后这里应立刻跟着变；不变即表示没送达组件。")
                }

                if AppSettings.shared.qqMusicCircuitBreakerEnabled {
                    Divider().opacity(0.4)
                    stepperRow(
                        title: "失败次数阈值",
                        value: Binding(
                            get: { AppSettings.shared.qqMusicCircuitFailureThreshold },
                            set: { AppSettings.shared.qqMusicCircuitFailureThreshold = $0 }
                        ),
                        range: 1...20,
                        unit: "次",
                        detail: "统计窗口内累计失败达到该次数即暂停。"
                    )
                    Divider().opacity(0.4)
                    stepperRow(
                        title: "统计窗口",
                        value: Binding(
                            get: { AppSettings.shared.qqMusicCircuitFailureWindowSeconds },
                            set: { AppSettings.shared.qqMusicCircuitFailureWindowSeconds = $0 }
                        ),
                        range: 10...600,
                        unit: "秒",
                        step: 10,
                        detail: "只统计这段时间内的失败，更早的失败会被忽略。"
                    )
                    Divider().opacity(0.4)
                    stepperRow(
                        title: "暂停时长",
                        value: Binding(
                            get: { AppSettings.shared.qqMusicCircuitOpenSeconds },
                            set: { AppSettings.shared.qqMusicCircuitOpenSeconds = $0 }
                        ),
                        range: 10...1800,
                        unit: "秒",
                        step: 30,
                        detail: "触发后暂停请求的时长。设为较小值配合登录使用效果更好。"
                    )
                }
            }
            .padding(SettingsStyleTokens.groupPadding)
            .background(sectionBackground)
        }
    }

    /// A numeric row bound to a setting, editable by typing or by stepping.
    ///
    /// The binding is passed in rather than a value plus setter: taking a
    /// `value` snapshot meant the row kept rendering the value captured when
    /// the section was built, so pressing the stepper changed the setting but
    /// the displayed number never moved.
    ///
    /// Stepping alone is impractical for wide ranges — the pause duration goes
    /// to 1800 seconds in steps of 30 — so the number itself is a text field.
    private func stepperRow(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        unit: String,
        step: Int = 1,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title)
                    .settingsRowLabelStyle()
                Spacer(minLength: 12)
                NumericSettingField(value: value, range: range, unit: unit)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
            }
            Text(detail)
                .settingsDescriptionStyle()
        }
    }

    private var circuitStateIsOpen: Bool { circuitState?.isOpen == true }

    private var circuitStateText: String {
        switch circuitState {
        case .disabled:
            return "自动熔断已关闭"
        case .open(let until, let reason):
            let remaining = max(0, Int(until.timeIntervalSinceNow.rounded(.up)))
            return "已暂停，剩余 \(remaining) 秒（\(reason)）"
        default:
            return "正常"
        }
    }

    private func resetCircuitBreaker() {
        Task {
            await QQMusicHelperProcess.shared.resetCircuitBreaker()
            await refreshCircuitState()
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
            SettingsHeaderLabel(title: "缓存", systemImage: "internaldrive")

            VStack(alignment: .leading, spacing: 10) {
                Text("在线内容的歌单、推荐、排行榜和封面会缓存在本地，避免重复请求上游（也是触发风控的主要原因）。缓存独立存放在下面这个目录，与应用自身的缓存分开管理。")
                    .settingsDescriptionStyle()

                labeledValue("缓存目录", cacheDirectoryPath ?? "资料库未就绪", monospaced: true)

                HStack(spacing: 8) {
                    Button("立即回收") { Task { await reclaimNow() } }
                        .disabled(isReclaiming)
                    Button("清除内容缓存") { Task { await clearCache() } }
                    Button("在访达中显示") { revealCacheDirectory() }
                    Spacer()
                }
            }
            .padding(SettingsStyleTokens.groupPadding)
            .background(sectionBackground)

            cacheBudgetSection(
                title: "歌曲缓存",
                subtitle: "播放时后台自动下载的歌曲。你自己点过播放或下载的歌曲属于曲库内容，不在这个上限之内，也不会被回收。",
                usage: songCacheUsageText,
                enabled: Binding(
                    get: { AppSettings.shared.qqMusicSongCacheLimitEnabled },
                    set: { AppSettings.shared.qqMusicSongCacheLimitEnabled = $0 }
                ),
                limitGB: Binding(
                    get: { AppSettings.shared.qqMusicSongCacheLimitGB },
                    set: { AppSettings.shared.qqMusicSongCacheLimitGB = $0 }
                ),
                reclaimPercent: Binding(
                    get: { AppSettings.shared.qqMusicSongCacheReclaimPercent },
                    set: { AppSettings.shared.qqMusicSongCacheReclaimPercent = $0 }
                )
            )

            cacheBudgetSection(
                title: "其他缓存",
                subtitle: "歌单、推荐、排行榜等目录数据与封面图片。这些内容都能重新获取，回收只会让下次加载稍慢。",
                usage: otherCacheUsageText,
                enabled: Binding(
                    get: { AppSettings.shared.qqMusicOtherCacheLimitEnabled },
                    set: { AppSettings.shared.qqMusicOtherCacheLimitEnabled = $0 }
                ),
                limitGB: Binding(
                    get: { AppSettings.shared.qqMusicOtherCacheLimitGB },
                    set: { AppSettings.shared.qqMusicOtherCacheLimitGB = $0 }
                ),
                reclaimPercent: Binding(
                    get: { AppSettings.shared.qqMusicOtherCacheReclaimPercent },
                    set: { AppSettings.shared.qqMusicOtherCacheReclaimPercent = $0 }
                )
            )
        }
    }

    /// One cache budget: enable switch, size limit, and reclaim target.
    ///
    /// The reclaim percentage is the interesting control. Trimming only to the
    /// limit would evict again on the very next download, so the cache would
    /// churn continuously; reclaiming to a lower water mark makes it occasional.
    private func cacheBudgetSection(
        title: String,
        subtitle: String,
        usage: String,
        enabled: Binding<Bool>,
        limitGB: Binding<Double>,
        reclaimPercent: Binding<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(themeStore.accentColor)
                Text(title)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(subtitle)
                    .settingsDescriptionStyle()

                labeledValue("当前占用", usage)

                SettingsSwitchRow(
                    title: "限制大小",
                    isOn: enabled,
                    detail: "关闭时不限制大小，也不回收。"
                )

                if enabled.wrappedValue {
                    Divider().opacity(0.4)

                    HStack(spacing: 12) {
                        Text("上限")
                            .settingsRowLabelStyle()
                        Spacer(minLength: 12)
                        DecimalSettingField(value: limitGB, range: 0.01...500, unit: "GB", fractionDigits: 2)
                    }

                    HStack(spacing: 12) {
                        Text("回收至上限的")
                            .settingsRowLabelStyle()
                        Spacer(minLength: 12)
                        NumericSettingField(value: reclaimPercent, range: 0...90, unit: "%")
                    }

                    Text("超过上限时回收，直到降到上限的这个百分比为止。留出余量是为了不必每下载一首就回收一次。90% 表示几乎贴着上限，0% 表示清空可回收的部分。")
                        .settingsDescriptionStyle()
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
        await pushCircuitConfiguration()
        do {
            loginStatus = try await helper.loginStatus()
        } catch {
            statusIsError = true
            statusText = "无法连接 Helper：\(error.localizedDescription)"
        }
    }

    private func refreshCircuitState() async {
        circuitState = await helper.circuitState()
        effectiveCircuit = await helper.effectiveCircuitConfiguration()
    }

    private func effectiveSummary(_ config: QQMusicCircuitConfiguration) -> String {
        guard config.isEnabled else { return "熔断已关闭" }
        return "阈值 \(config.threshold) 次 / 窗口 \(config.failureWindowSeconds) 秒 / 暂停 \(config.openSeconds) 秒"
    }

    /// Push the current settings into the helper.
    ///
    /// The helper is an actor and cannot read `AppSettings` itself, so changes
    /// made here must be forwarded explicitly — otherwise the controls would
    /// appear to do nothing until the next app launch.
    private func pushCircuitConfiguration() async {
        let settings = AppSettings.shared
        await helper.applyIdleTimeout(TimeInterval(settings.qqMusicHelperIdleSeconds))
        await helper.applyCircuitConfiguration(
            isEnabled: settings.qqMusicCircuitBreakerEnabled,
            threshold: settings.qqMusicCircuitFailureThreshold,
            failureWindow: TimeInterval(settings.qqMusicCircuitFailureWindowSeconds),
            openDuration: TimeInterval(settings.qqMusicCircuitOpenSeconds)
        )
        await refreshCircuitState()
    }

    private func refreshCacheSize() async {
        guard let store = coordinator?.cacheStore else {
            cacheSizeText = coordinator == nil ? "资料库未就绪" : "不可用"
            songCacheUsageText = cacheSizeText
            otherCacheUsageText = cacheSizeText
            return
        }
        let bytes = await store.diskUsageBytes()
        cacheSizeText = QQMusicBytes.formatted(bytes)
        otherCacheUsageText = QQMusicBytes.formatted(await store.nonAudioUsageBytes())

        // Song usage is measured from the library's own files: only the
        // automatic downloads count, and the count is taken over everything the
        // budget would consider reclaimable.
        if let libraryViewModel = coordinator?.libraryViewModel {
            // The session's own library root, not the per-track snapshot: a
            // relocated library leaves the snapshot stale, and then every file
            // measures as 0 and the cache appears empty however much is on disk.
            let (songBytes, cached) = QQMusicCacheBudget.shared.songCacheUsage(
                tracks: libraryViewModel.allTracks,
                libraryRoot: coordinator?.paths?.rootURL
            )
            songCacheUsageText = "\(QQMusicBytes.formatted(songBytes))（\(cached.count) 首）"
        } else {
            songCacheUsageText = "资料库未就绪"
        }
    }

    private func clearCache() async {
        guard let store = coordinator?.cacheStore else { return }
        await store.clearAll()
        await refreshCacheSize()
        statusIsError = false
        statusText = "缓存已清除"
    }

    /// Apply the limits now, so the effect can be seen without waiting for a
    /// download to cross one.
    private func reclaimNow() async {
        guard let coordinator else { return }
        isReclaiming = true
        defer { isReclaiming = false }
        let outcome = await coordinator.enforceCacheLimits()
        await refreshCacheSize()
        statusIsError = false
        if outcome.removedTrackCount > 0 {
            statusText = "已回收 \(outcome.removedTrackCount) 首自动下载的歌曲，"
                + "释放 \(QQMusicBytes.formatted(outcome.reclaimedBytes))"
        } else if outcome.stillOverLimit {
            statusText = "可回收的内容已清空，占用仍超过上限（正在播放或队列中的歌曲无法回收）"
        } else {
            statusText = "未超过上限，无需回收"
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

/// An integer setting shown as an editable field with its unit.
///
/// Typing commits on Return or when focus leaves; anything that does not parse,
/// or that falls outside `range`, reverts to the current value rather than being
/// silently clamped — clamping a typo like "3000" to the maximum would look like
/// the app accepted it. The text is re-synced from the binding whenever the
/// value changes elsewhere (the stepper, or another window).
private struct NumericSettingField: View {

    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 52)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    // Losing focus is a commit, not a cancel: the user typed a
                    // number and moved on.
                    if !focused { commit() }
                }
            Text(unit)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isFocused ? 0.10 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(isFocused ? 0.25 : 0.10), lineWidth: 0.5)
        )
        .onAppear { text = String(value) }
        .onChange(of: value) { _, newValue in
            // Don't fight the user while they are editing.
            if !isFocused { text = String(newValue) }
        }
    }

    private func commit() {
        guard let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              range.contains(parsed)
        else {
            text = String(value)
            return
        }
        if parsed != value { value = parsed }
        // Normalise what is shown, so "007" becomes "7".
        text = String(value)
    }
}

/// A decimal setting shown as an editable field with its unit.
///
/// Separate from `NumericSettingField` because the cache limits need decimals —
/// a whole-GB granularity cannot express 0.5 GB, and a default of 1 GB with only
/// integer steps makes small limits impossible to set.
private struct DecimalSettingField: View {

    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    let fractionDigits: Int

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 58)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
            Text(unit)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isFocused ? 0.10 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(isFocused ? 0.25 : 0.10), lineWidth: 0.5)
        )
        .onAppear { text = formatted(value) }
        .onChange(of: value) { _, newValue in
            // Don't fight the user while they are typing.
            if !isFocused { text = formatted(newValue) }
        }
    }

    private func formatted(_ number: Double) -> String {
        String(format: "%.\(fractionDigits)f", number)
    }

    private func commit() {
        // Reject rather than clamp: silently turning a typo like "500" into the
        // maximum would look like the value was accepted.
        guard let parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              range.contains(parsed)
        else {
            text = formatted(value)
            return
        }
        if abs(parsed - value) > 1e-9 { value = parsed }
        text = formatted(value)
    }
}
