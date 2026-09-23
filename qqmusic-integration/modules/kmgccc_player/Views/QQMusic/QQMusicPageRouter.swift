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

import SwiftUI

struct QQMusicPageRouter: View {

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @Environment(QQMusicNavigation.self) private var navigation
    @Environment(QQMusicSelectionModel.self) private var selection
    @EnvironmentObject private var themeStore: ThemeStore

    /// Ambient background scroll feed, as on Home.
    private let ambientMotion = HomeAmbientMotionState.shared

    var body: some View {
        QQMusicPageCanvas(onScroll: { offset in
            ambientMotion.setScrollOffset(offset)
        }) { insets, mode in
            pageContent(insets: insets, mode: mode)
        }
        .statusBanner()
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

// MARK: - Status banner

private struct QQMusicStatusBannerModifier: ViewModifier {

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @EnvironmentObject private var themeStore: ThemeStore

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            // Failures and notices are reported here, above the content, rather
            // than replacing it: a failed request must never blank out what has
            // already loaded, which would read as the content disappearing.
            if !coordinator.canDownload {
                banner(
                    text: "当前资料库为原位模式，无法保存下载的歌曲。切换到托管资料库后即可播放在线歌曲。",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            } else if let message = coordinator.statusMessage {
                banner(
                    text: message,
                    systemImage: coordinator.statusIsError
                        ? "exclamationmark.triangle.fill"
                        : "info.circle.fill",
                    tint: coordinator.statusIsError ? .orange : themeStore.accentColor
                )
            }
        }
    }

    private func banner(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }
}

extension View {
    func statusBanner() -> some View {
        modifier(QQMusicStatusBannerModifier())
    }
}
