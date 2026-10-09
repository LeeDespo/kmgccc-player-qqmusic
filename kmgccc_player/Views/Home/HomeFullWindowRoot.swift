//
//  HomeFullWindowRoot.swift
//  myPlayer2
//
//  SwiftUI root mounted in the AppKit window's full-window Home host (a
//  sibling layer between the art background and the split view). It only
//  renders the real `HomeView` when the active library selection is
//  `.home` and content mode is `.library`; otherwise it returns an empty
//  `Color.clear` that yields hit-testing entirely so clicks/scrolls fall
//  through to whatever lies beneath the host (the art background layer).
//
//  Environments injected here mirror the set provided by
//  `AppKitMainContentPaneRoot.contentView(...)` so `HomeView` and its
//  sections behave identically to when they were rendered inside the
//  center pane.
//

import MotionKit
import SwiftData
import SwiftUI

struct HomeFullWindowRoot: View {
    @ObservedObject var appSession: AppSessionHost
    @State private var settings = AppSettings.shared
    @State private var layout = HomeWindowLayoutState.shared
    @State private var hasMountedHome = false

    var body: some View {
        Group {
            switch presentedSurface {
            case .online:
                QQMusicFullWindowRoot(appSession: appSession)
            case .home:
                if let libraryVM = appSession.libraryVM,
                   let playerVM = appSession.playerVM,
                   let playbackCoordinator = appSession.playbackCoordinator,
                   let lyricsVM = appSession.lyricsVM,
                   let ledMeterProvider = appSession.ledMeterProvider,
                   let importEnrichmentService = appSession.importEnrichmentService,
                   let cacheServices = appSession.cacheServices,
                   let skinManager = appSession.skinManager {
                    let historyStore = appSession.playbackHistoryStore
                    HomeView(
                        playbackCoordinator: playbackCoordinator,
                        listeningFootprintProvider: {
                            historyStore.dailyPlayCounts()
                        }
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .environment(AppSettings.shared)
                        .environment(appSession.uiState)
                        .environment(appSession.homeVM)
                        .environment(appSession.playbackHistoryViewModel)
                        .environment(libraryVM)
                        .environment(playerVM)
                        .environment(playbackCoordinator)
                        .environment(lyricsVM)
                        .environment(ledMeterProvider)
                        .environment(importEnrichmentService)
                        .environment(cacheServices)
                        .environment(skinManager)
                        .environment(cacheServices.coverDownloadService)
                        .environment(cacheServices.netEaseCoverService)
                        .environmentObject(ThemeStore.shared)
                        .environment(\.libraryPresentedAccentColor, ThemeStore.shared.accentColor)
                        .modelContainer(appSession.sharedModelContainer)
                        .tint(ThemeStore.shared.accentColor)
                        .accentColor(ThemeStore.shared.accentColor)
                }
            case .none:
                Color.clear
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .all)
        .opacity(presentedSurface == .none ? 0 : 1)
        .allowsHitTesting(presentedSurface != .none)
        .accessibilityHidden(presentedSurface == .none)
        .transaction { $0.animation = nil }
        .onChange(of: shouldRenderHome, initial: true) { _, active in
            if active { hasMountedHome = true }
        }
        // Which surface this host draws is the difference between "the page is
        // broken" and "the page is not on screen": from the outside both look
        // like an empty window, and the online surface leaves no other trace.
        .onChange(of: presentedSurface, initial: true) { _, _ in
            Log.info(
                "[HomeHost] surface=\(presentedSurface) contentMode=\(appSession.uiState.contentMode) allows=\(layout.allowsHomeInteraction) coordinator=\(appSession.qqMusicOnlineCoordinator != nil) embeddedFullscreen=\(layout.isEmbeddedFullscreenActive) searchActive=\(layout.isHomeSearchActive)",
                category: .ui
            )
        }
        .motionEnvironment()
    }

    private enum PresentedSurface: Equatable {
        case online
        case home
        case none
    }

    /// The single place that decides what this host draws, so the branch taken,
    /// the visibility gates and the log cannot disagree.
    ///
    /// The online surface is asked first on purpose: `hasMountedHome` keeps Home
    /// alive across library navigation, and with the mounted shortcut first it
    /// also preempted the online pages — opening QQ Music kept drawing Home
    /// (invisible under the gates above) and never the online root.
    private var presentedSurface: PresentedSurface {
        if shouldRenderQQMusic { return .online }
        if hasMountedHome || shouldRenderHome { return .home }
        return .none
    }

    private var shouldRenderHome: Bool {
        guard layout.allowsHomeInteraction else { return false }
        guard let libraryVM = appSession.libraryVM else { return false }
        return appSession.uiState.contentMode == .library
            && libraryVM.currentSelection == .home
    }

    /// The online browse surface shares this host, for the same reason Home has
    /// it: its card rails must span the window so they can run under the
    /// sidebar / lyrics glass. `allowsHomeInteraction` already covers this mode
    /// (see its `isQQMusicMode` term), so the hit routing needs no new gate.
    private var shouldRenderQQMusic: Bool {
        guard layout.allowsHomeInteraction else { return false }
        return appSession.uiState.contentMode == .qqMusicOnline
            && appSession.qqMusicOnlineCoordinator != nil
    }
}
