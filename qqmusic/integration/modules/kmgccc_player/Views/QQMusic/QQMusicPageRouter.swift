//
//  QQMusicPageRouter.swift
//  kmgccc_player
//
//  Routes the online browse surface: one view per page, driven by
//  `QQMusicNavigation`'s stack.
//
//  This replaces the previous single view with a segmented control at the top.
//  The app's own pages have no tab strip — where you are comes from the sidebar
//  or from the page's header, and how you get back is the toolbar's back/forward
//  pill — so the online surface now works the same way. The `switch` below is
//  the whole of the routing.
//
//  There is no status banner here either. The surface used to hang a thin banner
//  under the toolbar for its notices (failures, the playback-start line,
//  "已加入下一首", like and download confirmations), and the user asked for both
//  the notices and the presentation to go. Failures are logged — see the note at
//  the top of `QQMusicOnlineCoordinator` — and what a user can act on is drawn
//  where it belongs: a row's download glyph, a page's own empty state, the
//  batch-download control's own availability.
//

import SwiftUI

struct QQMusicPageRouter: View {

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @Environment(QQMusicNavigation.self) private var navigation
    @Environment(QQMusicSelectionModel.self) private var selection
    @EnvironmentObject private var themeStore: ThemeStore

    /// Ambient background scroll feed, as on Home.
    private let ambientMotion = HomeAmbientMotionState.shared

    var body: some View {
        @Bindable var coordinator = coordinator
        return QQMusicPageCanvas(
            onScroll: { offset in
                ambientMotion.setScrollOffset(offset)
            },
            // A new page starts at its top: the offset of the page before it has
            // nothing to do with where the user should land.
            scrollResetKey: navigation.displayKey
        ) { insets, mode in
            // One page replaces another in place, with no transition of its own.
            //
            // The movement the user asked for is not a transition at all: the app
            // animates its **Home page arriving**. `HomeView` draws its scroll
            // content with `.opacity(hasAppeared ? 1 : 0)`,
            // `.offset(y: hasAppeared ? 0 : 12)` and
            // `.animation(.easeOut(duration: 0.4), value: hasAppeared)`, flipping
            // the flag 80ms after appearing — so 侧边栏 → 主页 and 艺人二级页 → 主页
            // are a fade with a 12pt rise, and nothing slides sideways.
            //
            // `QQMusicHomePage` carries that same entrance (see
            // `QQMusicLandingEntrance`), which covers both of those movements here:
            // the sidebar entry lands on it, and so does 返回 from any second-level
            // page. Second-level pages themselves get no entrance, which is also
            // what the app does — `PlaylistDetailView` appears at once, and only
            // its header colours fade in as they resolve.
            pageContent(insets: insets, mode: mode)
                .id(navigation.displayKey)
        }
        // 查看详情 / 查看歌曲描述 from a row's 更多 menu. Presented here rather
        // than by the row itself: rows are recycled as they scroll, and a sheet
        // they owned would be dismissed by that.
        .sheet(item: $coordinator.trackForDetail) { track in
            QQMusicTrackDetailSheet(track: track)
        }
        .sheet(item: $coordinator.trackForDescription) { track in
            QQMusicTrackDescriptionSheet(track: track)
        }
        .task(id: coordinator.libraryAvailabilityToken) {
            // Browsing-wide bookkeeping, independent of which page shows:
            // whether downloads can land here at all, and the liked-mid set the
            // hearts read from.
            await coordinator.prepareForBrowsing()
        }
        // Keyed on the page, so entering a page loads it exactly once — and so
        // returning to a page the coordinator already has data for is free,
        // because every loader returns early when its content is present.
        //
        // Deliberately not `.task(id:)`: that ties the request to this view's
        // task, so switching pages mid-flight cancels the in-flight helper
        // request and surfaces as "操作被取消". Firing and forgetting is safe
        // because each loader guards against duplicate work itself.
        .onChange(of: navigation.displayKey, initial: true) { _, _ in
            let page = navigation.displayed
            // A selection belongs to the list it was started on. Leaving a
            // selectable page would otherwise strand the toolbar control in a
            // selection mode that has no rows to act on.
            if !coordinator.canSelectTracks(for: page) {
                selection.cancel()
            }
            Task { await coordinator.loadContent(for: page) }
        }
        // The toolbar's refresh button. The page is re-requested rather than
        // re-read, which is the whole difference between refreshing and doing
        // nothing: every loader returns early when its content is present and
        // otherwise answers from the catalogue cache.
        .onChange(of: coordinator.reloadToken) { _, _ in
            let page = navigation.displayed
            Task { await coordinator.loadContent(for: page, force: true) }
        }
        .onChange(of: coordinator.onlineSearchKind) { _, _ in
            // The toolbar field drives the type on a search page; the results
            // have to follow it rather than only the page identity.
            guard case .search = navigation.displayed else { return }
            Task {
                await coordinator.searchFromToolbar(
                    coordinator.onlineSearchKeyword,
                    kind: coordinator.onlineSearchKind
                )
            }
        }
    }

    /// One page per case. Every page reads its column insets from the
    /// environment (set by the canvas), so nothing has to be threaded through
    /// here — and nothing can be forgotten.
    @ViewBuilder
    private func pageContent(insets: QQMusicColumnInsets, mode: HomeLayoutMode) -> some View {
        switch navigation.displayed {
        case .home:
            QQMusicHomePage(navigation: navigation, mode: mode)
                .modifier(QQMusicLandingEntrance())

        // MARK: Account lists
        case .likedSongs:
            QQMusicTrackListPage(page: .likedSongs, mode: mode)
        case .newSongs(let region):
            QQMusicTrackListPage(page: .newSongs(region), mode: mode)
        case .recommend:
            QQMusicTrackListPage(page: .recommend, mode: mode)
        case .search(let kind):
            QQMusicSearchPage(kind: kind, mode: mode)

        // MARK: Entity indexes
        case .userPlaylists:
            QQMusicPlaylistIndexPage(mode: mode)
        case .likedAlbums:
            QQMusicAlbumIndexPage(mode: mode)
        case .followedArtists:
            QQMusicArtistIndexPage(mode: mode)
        case .toplists:
            QQMusicToplistIndexPage(mode: mode)
        case .radio:
            QQMusicRadioIndexPage(mode: mode)

        // MARK: Entity detail
        case .playlist, .album, .toplist, .radioStation:
            QQMusicEntityDetailPage(page: navigation.displayed, mode: mode)
        case .artist(let ref):
            QQMusicArtistPage(artist: ref, mode: mode)
                .id(ref.singerMid)
        }
    }

}

/// The app's own entrance for its Home page, applied to the online landing page.
///
/// `HomeView` draws its scroll content as
/// `.opacity(hasAppeared ? 1 : 0)`, `.offset(y: hasAppeared ? 0 : 12)`,
/// `.animation(.easeOut(duration: 0.4), value: hasAppeared)`, and flips
/// `hasAppeared` 80ms after appearing (or at once, with `reduceMotion`). That is
/// the whole of what the user sees when entering 主页 — from the sidebar, or
/// coming back from a second-level page — and it is what they asked this surface
/// to copy. Nothing slides; the page settles.
///
/// It re-runs on every arrival because the router identifies pages by
/// `displayKey`: leaving and returning to the landing page builds it afresh, so
/// `onAppear` fires again and the flag starts false.
private struct QQMusicLandingEntrance: ViewModifier {

    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 12)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: hasAppeared)
            .onAppear(perform: reveal)
    }

    /// The delay is `HomeView`'s: it gives the page one frame to lay out before
    /// the fade starts, so the rise reads as the content arriving rather than as
    /// a layout jitter being animated.
    private func reveal() {
        if reduceMotion {
            hasAppeared = true
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            hasAppeared = true
        }
    }
}
