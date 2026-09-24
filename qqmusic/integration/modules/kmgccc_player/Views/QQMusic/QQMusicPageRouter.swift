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
        return QQMusicPageCanvas(onScroll: { offset in
            ambientMotion.setScrollOffset(offset)
        }) { insets, mode in
            pageContent(insets: insets, mode: mode)
        }
        // 查看详情 from a row's 更多 menu. Presented here rather than by the row
        // itself: rows are recycled as they scroll, and a sheet they owned would
        // be dismissed by that.
        .sheet(item: $coordinator.trackForDetail) { track in
            QQMusicTrackDetailSheet(track: track)
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

    @ViewBuilder
    private func pageContent(insets: QQMusicColumnInsets, mode: HomeLayoutMode) -> some View {
        let leftPad = insets.left
        let rightPad = insets.right
        switch navigation.displayed {
        case .home:
            QQMusicHomePage(
                navigation: navigation,
                columnLeftInset: leftPad,
                columnRightInset: rightPad,
                mode: mode
            )

        // MARK: Account lists
        case .likedSongs:
            QQMusicTrackListPage(
                page: .likedSongs,
                leftPad: leftPad,
                rightPad: rightPad,
                mode: mode
            )
        case .newSongs(let region):
            QQMusicTrackListPage(
                page: .newSongs(region),
                leftPad: leftPad,
                rightPad: rightPad,
                mode: mode
            )
        case .recommend:
            QQMusicTrackListPage(
                page: .recommend,
                leftPad: leftPad,
                rightPad: rightPad,
                mode: mode
            )
        case .search(let kind):
            QQMusicSearchPage(kind: kind, leftPad: leftPad, rightPad: rightPad, mode: mode)

        // MARK: Entity indexes
        case .userPlaylists:
            QQMusicPlaylistIndexPage(leftPad: leftPad, rightPad: rightPad, mode: mode)
        case .likedAlbums:
            QQMusicAlbumIndexPage(leftPad: leftPad, rightPad: rightPad, mode: mode)
        case .toplists:
            QQMusicToplistIndexPage(leftPad: leftPad, rightPad: rightPad, mode: mode)
        case .radio:
            QQMusicRadioIndexPage(leftPad: leftPad, rightPad: rightPad, mode: mode)

        // MARK: Entity detail
        case .playlist, .album, .toplist, .radioStation:
            QQMusicEntityDetailPage(
                page: navigation.displayed,
                leftPad: leftPad,
                rightPad: rightPad,
                mode: mode
            )
        case .artist(let ref):
            QQMusicArtistPage(artist: ref, leftPad: leftPad, rightPad: rightPad, mode: mode)
        }
    }
}
