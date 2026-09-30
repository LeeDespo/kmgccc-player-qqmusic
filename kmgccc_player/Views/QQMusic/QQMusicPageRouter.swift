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
            // A new *page* starts at its top: the offset of the page before it has
            // nothing to do with where the user should land. `viewIdentityKey`
            // rather than `displayKey`, because the search page's content type is
            // a filter and not a place — switching 歌曲/歌手/专辑/歌单 keeps the
            // scroll position the user was reading at, as they asked.
            scrollResetKey: navigation.viewIdentityKey
        ) { insets, mode in
            // Every page enters the way the app's own Home does.
            //
            // The movement is not a transition — there is none here, and the app
            // has none. It is `HomeView` drawing its content with
            // `.opacity(hasAppeared ? 1 : 0)`, `.offset(y: hasAppeared ? 0 : 12)`
            // and `.animation(.easeOut(duration: 0.4), value: hasAppeared)`,
            // flipping the flag 80ms after appearing: a fade with a 12pt rise,
            // nowhere sliding sideways. `QQMusicPageEntrance` is that, verbatim.
            //
            // Applied to *every* page rather than only the landing page, which is
            // where the user asked for it: the app's detail pages appear at once,
            // but on this surface 我喜欢 and a playlist's 更多列表 are entered from
            // the same rails as the landing page, and having only some arrivals
            // animate reads as a glitch rather than as a rule.
            //
            // The entrance must sit *inside* the `.id`: that identity is what makes
            // SwiftUI build the page afresh, so the modifier's own appear state
            // starts false on each one and the animation replays. Outside it, only
            // the first page of a session would ever animate.
            //
            // The identity is `viewIdentityKey`, not `displayKey`: they differ for
            // the search page's content type, where the page is *the same page*
            // with a different filter and must not animate again (the user asked
            // for that switch to be still). The scroll reset still keys on
            // `displayKey`, so a new result list still starts at its top.
            pageContent(insets: insets, mode: mode)
                .modifier(QQMusicPageEntrance())
                .id(navigation.viewIdentityKey)
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

/// The app's own entrance for its Home page, applied to every online page.
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
/// `displayKey`, and the modifier is applied inside that identity: each page is
/// built afresh, so `onAppear` fires and the flag starts false again.
private struct QQMusicPageEntrance: ViewModifier {

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
