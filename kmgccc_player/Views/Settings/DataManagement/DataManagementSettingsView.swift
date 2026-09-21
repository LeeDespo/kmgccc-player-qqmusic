//
//  DataManagementSettingsView.swift
//  myPlayer2
//
//  kmgccc_player - Data Management Settings View
//

import SwiftUI

/// Data management settings split between music-library controls and app data.
struct DataManagementSettingsView: View {
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("数据", systemImage: "arrow.counterclockwise.circle")
            SettingsTabSelector(
                tabs: ["音乐", "应用数据"],
                selectedTab: $selectedTab,
                fillsWidth: true
            )

            if selectedTab == 0 {
                MusicSettingsView()
            } else {
                ApplicationDataSettingsView()
            }
        }
    }
}

private struct ApplicationDataSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LibraryCacheServices.self) private var cacheServices
    @AppStorage("telemetry.anonymousUsageEnabled") private var telemetryEnabled: Bool = false
    @AppStorage(CrashReportPreferences.automaticUploadKey) private var automaticCrashReportUploadEnabled = false

    @State private var showResetDataAlert: Bool = false
    @State private var showClearIndexCacheAlert: Bool = false
    @State private var showClearLibraryCacheAlert: Bool = false
    @State private var isClearingLibraryCaches: Bool = false
    @State private var isMoreSettingsExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Import and enrichment settings
            SettingsSection("歌曲信息与补全") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsSwitchRow(
                        title: "导入时延后补全歌曲信息",
                        isOn: Binding(
                            get: { settings.deferImportEnrichment },
                            set: { settings.deferImportEnrichment = $0 }
                        ),
                        detail: "导入时先完成文件复制，在后台补全歌词和封面"
                    )

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            LibraryCompletionDialogPresenter.present(
                                libraryVM: libraryVM,
                                cacheServices: cacheServices
                            )
                        } label: {
                            Text("补全所有歌曲信息")
                        }
                        .buttonStyle(.borderedProminent)
                        .clipShape(Capsule())

                        Text("自动联网补全本地曲库中缺失的歌曲信息、封面和歌词")
                            .settingsDescriptionStyle()
                    }
                }
            }

            // Reset app settings
            SettingsSection("重置设置") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("重置应用设置与状态", role: .destructive) {
                        showResetDataAlert = true
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())

                    Text("清除 app 设置项，恢复默认值")
                        .settingsDescriptionStyle()
                }
            }

            // More settings
            SettingsSection("更多设置", headerTrailing: {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isMoreSettingsExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isMoreSettingsExpanded ? 90 : 0))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isMoreSettingsExpanded ? "收起" : "展开")
                .accessibilityLabel(isMoreSettingsExpanded ? "收起更多设置" : "展开更多设置")
            }) {
                if isMoreSettingsExpanded {
                    VStack(alignment: .leading, spacing: 16) {
                        cacheManagementControls
                        musicPreferenceResetControl
                    }
                } else {
                    Text("包含缓存清理与播放统计数据重置")
                        .settingsDescriptionStyle()
                }
            }

            SettingsSection("数据共享") {
                VStack(alignment: .leading, spacing: 16) {
                    // This build is a modified fork. Both switches are shown as
                    // locked rather than removed, so the state is visible and its
                    // reason is readable — a silently missing control invites the
                    // question of whether it was ever there.
                    lockedSharingRow(
                        title: "帮助改进 kmgccc_player",
                        detail: "由于本版本是修改版，匿名使用统计已停用且不可开启：数据会发送到原作者的服务器，而原作者无法据修改版的数据做任何事。"
                    )
                    lockedSharingRow(
                        title: "自动发送崩溃报告",
                        detail: "由于本版本是修改版，崩溃报告已停用且不可开启：报告同样会发送到原作者的服务器。"
                    )
                }
            }
        }
        .alert("重置应用设置与状态？", isPresented: $showResetDataAlert) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                resetAppDataExceptMusicLibrary()
            }
        } message: {
            Text("会清除应用偏好、界面布局、播放状态和自定义资料库位置设置。不会删除音乐资料库文件，也不会清除资料库内的歌曲、播放列表、艺人、专辑、自定义排序或手动编辑内容。")
        }
        .alert("清除索引缓存？", isPresented: $showClearIndexCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task {
                    await libraryVM.clearIndexCacheAndRebuild()
                }
            }
        } message: {
            Text("将清空索引缓存并立即重新扫描音乐资料库，不会删除歌曲文件或播放列表。")
        }
        .alert("清理运行缓存？", isPresented: $showClearLibraryCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                clearLibraryCaches()
            }
        } message: {
            Text("将清除封面缩略图、联网搜索缓存、外部播放自动缓存、颜色缓存、Home 缓存和过期导入暂存。不会删除歌曲或手动外部播放规则。")
        }
    }

    private func resetAppDataExceptMusicLibrary() {
        AppVersionGate.shared.resetStoredState()
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let preservedTelemetryState = PreservedAnonymousTelemetryState()
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        preservedTelemetryState.restore()
        UserDefaults.standard.synchronize()
    }

    private func clearLibraryCaches() {
        guard !isClearingLibraryCaches else { return }
        isClearingLibraryCaches = true
        Task {
            await CacheManager.clearLibraryCaches(
                storageLocations: cacheServices.storageLocations,
                trackArtworkCache: cacheServices.trackArtworkCache,
                artworkDerivativeStore: cacheServices.artworkDerivativeStore,
                amllDBService: cacheServices.amllDBService,
                externalPlaybackMetadataStore: cacheServices.externalPlaybackMetadataStore
            )
            playbackCoordinator.clearExternalPlaybackRuntimeCaches()
            isClearingLibraryCaches = false
        }
    }

    /// A data-sharing switch that is fixed off, with its reason shown.
    private func lockedSharingRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title)
                    .settingsRowLabelStyle()
                Spacer(minLength: 16)
                Toggle("", isOn: .constant(false))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(true)
            }
            Text(detail)
                .settingsDescriptionStyle()
        }
    }

    private var telemetryEnabledBinding: Binding<Bool> {
        Binding(
            get: { telemetryEnabled },
            set: { newValue in
                telemetryEnabled = newValue
                TelemetryService.shared.setTelemetryEnabled(newValue)
            }
        )
    }

    private var automaticCrashReportUploadBinding: Binding<Bool> {
        Binding(
            get: { automaticCrashReportUploadEnabled },
            set: { newValue in
                automaticCrashReportUploadEnabled = newValue
                CrashReportService.shared.automaticUploadPreferenceDidChange(newValue)
                MetricKitDiagnosticService.shared.automaticUploadPreferenceDidChange(newValue)
            }
        )
    }

    private var cacheManagementControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Button("清除索引缓存") {
                    showClearIndexCacheAlert = true
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())

                Text("重新建立音乐资料库的索引，供 app 内显示使用")
                    .settingsDescriptionStyle()
            }

            VStack(alignment: .leading, spacing: 8) {
                Button(role: .destructive) {
                    showClearLibraryCacheAlert = true
                } label: {
                    if isClearingLibraryCaches {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("清理运行缓存")
                    }
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
                .disabled(isClearingLibraryCaches)

                Text("包含可再生成的封面缩略图、歌词索引、外部播放自动缓存、颜色、Home 与导入暂存缓存")
                    .settingsDescriptionStyle()
            }
        }
    }

    private var musicPreferenceResetControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("重置播放统计数据", role: .destructive) {
                MusicPreferenceResetDialogPresenter.present(
                    libraryVM: libraryVM,
                    playerVM: playerVM
                )
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())

            Text("清除音乐播放记录，包括歌曲聆听计数、播放时长等")
                .settingsDescriptionStyle()
        }
    }
}

private struct PreservedAnonymousTelemetryState {
    private let installID: String?
    private let installSeenAcknowledged: Bool?
    private let installSeenEventID: String?

    init(defaults: UserDefaults = .standard) {
        installID = defaults.string(forKey: Self.installIDKey)
        installSeenAcknowledged = defaults.object(forKey: Self.installSeenAcknowledgedKey) as? Bool
        installSeenEventID = defaults.string(forKey: Self.installSeenEventIDKey)
    }

    func restore(defaults: UserDefaults = .standard) {
        if let installID {
            defaults.set(installID, forKey: Self.installIDKey)
        }
        if let installSeenAcknowledged {
            defaults.set(installSeenAcknowledged, forKey: Self.installSeenAcknowledgedKey)
        }
        if let installSeenEventID {
            defaults.set(installSeenEventID, forKey: Self.installSeenEventIDKey)
        }
    }

    private static let installIDKey = "telemetry.anonymousInstallID"
    private static let installSeenAcknowledgedKey = "telemetry.installSeenAcknowledged"
    private static let installSeenEventIDKey = "telemetry.installSeenEventID"
}
