//
//  QQMusicArtistPage.swift
//  kmgccc_player
//
//  An online artist, laid out as the library's artist page is.
//
//  This is the previous `QQMusicArtistDetailView` re-composed on the shared
//  page primitives: the same 220pt circular header, the same segmented control
//  for 歌曲 / 专辑 at the leading edge, and the library's row geometry for both
//  lists. The old version drew its own header besides the one the library uses
//  and its own rows; both are now the shared ones, so an online artist and a
//  library artist read identically apart from the actions offered.
//

import SwiftUI

struct QQMusicArtistPage: View {

    let artist: QQMusicArtistRef
    let mode: HomeLayoutMode

    /// The columns this page aligns to. Supplied by the canvas, so no page
    /// can be drawn without it (see `QQMusicColumnInsetsKey`).
    @Environment(\.qqMusicColumnInsets) private var insets
    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @Environment(QQMusicNavigation.self) private var navigation
    @Environment(QQMusicSelectionModel.self) private var selection
    @EnvironmentObject private var themeStore: ThemeStore

    private enum Tab: String, CaseIterable, Identifiable {
        case songs
        case albums

        var id: String { rawValue }
        var title: String { self == .songs ? "歌曲" : "专辑" }
    }

    /// 热门 / 最新, shared by both tabs: the artist's songs and their albums each
    /// have a hotness order and a release-date order, and one control says so for
    /// whichever list is on screen rather than two controls that look identical.
    private enum ContentSort: String, CaseIterable, Identifiable {
        case hot
        case latest

        var id: String { rawValue }
        var title: String { self == .hot ? "热门" : "最新" }

        /// What the helper's `sort` parameter calls it.
        var helperSort: QQMusicOnlineCoordinator.ArtistSongSort {
            self == .latest ? .latest : .hot
        }
    }

    @State private var tab: Tab = .songs
    @State private var sort: ContentSort = .hot
    @State private var songs: [QQMusicOnlineTrack] = []
    @State private var albums: [QQMusicOnlineAlbum] = []
    @State private var isLoadingSongs = false
    @State private var isLoadingAlbums = false
    @State private var isLoadingMore = false
    @State private var songPage = 1
    @State private var hasMoreSongs = true
    @State private var errorText: String?
    @State private var biography: String?
    /// Set when one of the artist's albums has been opened in this page, so the
    /// header can switch to it and "back" steps out one level, as the library's
    /// album-to-artist drill-down does.
    @State private var openedAlbum: QQMusicOnlineAlbum?
    @State private var albumSongs: [QQMusicOnlineTrack] = []

    var body: some View {
        header
        controls
        content
    }

    // MARK: - Header

    private var header: some View {
        QQMusicDetailHeader(
            title: openedAlbum?.title ?? artist.name,
            subtitle: isShowingAlbum ? artist.name : artistSubtitle,
            metadata: openedAlbum?.releaseDate,
            artworkURL: headerArtworkURL,
            isCircleArtwork: !isShowingAlbum,
            placeholderSystemImage: isShowingAlbum ? "opticaldisc" : "person.fill",
            description: isShowingAlbum ? nil : biography,
            descriptionTitle: "艺人详情",
            // Omitted rather than drawn disabled on the albums tab: "play all
            // albums" has no meaning.
            onPlay: canPlayFromHeader ? { playFromHeader() } : nil,
            canPlay: canPlayFromHeader,
            // The header insets itself by these plus the library's own 24.
            columnLeftPad: insets.left,
            columnRightPad: insets.right
        ) {
            // Nothing beside 播放: the batch-download control lives in the page's
            // top-right corner, so the header keeps the single primary action.
            EmptyView()
        }
    }

    private var isShowingAlbum: Bool { openedAlbum != nil }

    private var headerArtworkURL: String? {
        openedAlbum?.coverURL ?? artist.coverURL
    }

    private var artistSubtitle: String? {
        var parts: [String] = []
        if let count = artist.songCount { parts.append("\(count) 首歌曲") }
        if let count = artist.albumCount { parts.append("\(count) 张专辑") }
        return parts.isEmpty ? "在线歌手" : parts.joined(separator: " · ")
    }

    private var currentTracks: [QQMusicOnlineTrack] {
        isShowingAlbum ? albumSongs : songs
    }

    private var canPlayFromHeader: Bool {
        (isShowingAlbum || tab == .songs) && !currentTracks.isEmpty
    }

    private func playFromHeader() {
        let list = currentTracks
        guard !list.isEmpty else { return }
        Task { await coordinator.startPlayback(list, startingAt: 0) }
    }

    // MARK: - Controls

    /// The tab and sort controls, at the leading edge like the library's.
    @ViewBuilder
    private var controls: some View {
        if isShowingAlbum {
            // Inside an album the way out is the header's artist link or the
            // toolbar's back pill; no further controls apply.
            EmptyView()
        } else {
            HStack(spacing: 8) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: false)
                .onChange(of: tab) { _, newValue in
                    Task { if newValue == .albums { await loadAlbums() } }
                }

                // Present on both tabs: an artist's albums are ordered by
                // hotness upstream just as their songs are, and 最新 means the
                // same thing for both (newest release first, computed by the
                // helper — the upstream ignores ordering parameters).
                Picker("", selection: $sort) {
                    ForEach(ContentSort.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: false)
                .onChange(of: sort) { _, _ in
                    Task {
                        switch tab {
                        case .songs: await loadSongs(force: true)
                        case .albums: await loadAlbums(force: true)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, insets.left + 24)
                .padding(.trailing, insets.right + 24)
            .padding(.top, 4)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Group {
            if let errorText {
                QQMusicListStateView(kind: .error(errorText) {
                    Task { await reload() }
                })
            } else if tab == .songs || isShowingAlbum {
                songList
            } else {
                albumGrid
            }
        }
        // Nothing else starts the first load. The router's page loaders skip the
        // artist page deliberately — it owns its own multi-tab fetching — so
        // without this the page sat on "暂无歌曲" until the sort control was
        // touched. Both loaders below return early when their list is present,
        // so a repeat appearance costs nothing.
        .onAppear { Task { await loadCurrentTabIfNeeded() } }
        // The toolbar's refresh button, and the only way to re-request an
        // artist's songs: this page fetches outside the coordinator's loaders, so
        // it is not covered by the router's reload.
        .onChange(of: coordinator.reloadToken) { _, _ in Task { await reload() } }
    }

    @ViewBuilder
    private var songList: some View {
        if currentTracks.isEmpty {
            if isLoadingSongs {
                QQMusicListStateView(kind: .loading("正在载入…"))
            } else {
                QQMusicListStateView(kind: .empty("暂无歌曲", systemImage: "music.note.list"))
            }
        } else {
            QQMusicTrackListBody(
                tracks: currentTracks,
                // An artist can have over a thousand songs and the list pages
                // forever, so it has no "all" to select.
                allowsSelection: false,
                onReachEnd: { Task { await loadMoreSongs() } },
                onPlay: { displayed, index in
                    Task { await coordinator.startPlayback(displayed, startingAt: index) }
                }
            )
        }
    }

    /// The artist's albums, on the library's card grid.
    @ViewBuilder
    private var albumGrid: some View {
        if albums.isEmpty {
            if isLoadingAlbums {
                QQMusicListStateView(kind: .loading("正在载入…"))
            } else {
                QQMusicListStateView(kind: .empty("暂无专辑", systemImage: "opticaldisc"))
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168), spacing: 14)],
                spacing: 14
            ) {
                ForEach(albums) { album in
                    QQMusicCard(
                        title: album.title,
                        subtitle: album.artist,
                        size: 146,
                        titleColor: .primary,
                        subtitleColor: .secondary,
                        onOpen: { Task { await openAlbum(album) } }
                    ) {
                        QQMusicArtworkView(
                            urlString: album.coverURL,
                            size: 146,
                            cornerRadius: 8
                        )
                    }
                }
            }
            .padding(.leading, insets.left + 24)
                .padding(.trailing, insets.right + 24)
        }
    }

    private var ownedSongMids: Set<String> {
        Set(songs.map(\.songMid).filter { coordinator.isUserDownloaded($0) })
    }

    // MARK: - Loading

    /// Load the tab on screen, once.
    private func loadCurrentTabIfNeeded() async {
        guard !isShowingAlbum else { return }
        switch tab {
        case .songs: await loadSongs(force: false)
        case .albums: await loadAlbums()
        }
    }

    /// Fetch what is on screen again, for the toolbar's refresh button.
    ///
    /// Each loader returns early while its list is present, so a reload clears
    /// the list it is about to replace first — otherwise "again" would mean
    /// "nothing".
    private func reload() async {
        errorText = nil
        if let album = openedAlbum {
            await openAlbum(album)
            return
        }
        switch tab {
        case .songs:
            biography = nil
            await loadSongs(force: true)
        case .albums:
            await loadAlbums(force: true)
        }
    }

    private func loadSongs(force: Bool) async {
        if !force, !songs.isEmpty { return }
        isLoadingSongs = true
        errorText = nil
        defer { isLoadingSongs = false }
        do {
            songs = try await coordinator.artistSongs(
                singerMid: artist.singerMid,
                sort: sort.helperSort,
                page: 1
            )
            songPage = 1
            hasMoreSongs = !songs.isEmpty
            await loadBiographyIfNeeded()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Append the next page of the artist's songs.
    private func loadMoreSongs() async {
        guard hasMoreSongs, !isLoadingMore, !isLoadingSongs, !isShowingAlbum else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = songPage + 1
            let more = try await coordinator.artistSongs(
                singerMid: artist.singerMid,
                sort: sort.helperSort,
                page: next
            )
            // Comparing the tail guards against a server that keeps returning
            // the same page, which would otherwise loop forever.
            let known = Set(songs.map(\.songMid))
            let fresh = more.filter { !known.contains($0.songMid) }
            guard !fresh.isEmpty else {
                hasMoreSongs = false
                return
            }
            songs.append(contentsOf: fresh)
            songPage = next
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            hasMoreSongs = false
        }
    }

    /// Artist biography, shown in the header's description slot as the library
    /// page shows one. Omitted entirely when upstream has none.
    private func loadBiographyIfNeeded() async {
        guard biography == nil else { return }
        biography = await coordinator.artistBiography(singerMid: artist.singerMid)
    }

    /// Fetch the albums, in the sort on screen.
    ///
    /// `force` exists for the sort control: a list that is already present is
    /// left alone, so without clearing it "最新" would show the hot order it
    /// fetched a moment ago.
    private func loadAlbums(force: Bool = false) async {
        if !force, !albums.isEmpty { return }
        isLoadingAlbums = true
        errorText = nil
        defer { isLoadingAlbums = false }
        do {
            let fetched = try await coordinator.artistAlbums(
                singerMid: artist.singerMid,
                sort: sort.helperSort
            )
            albums = fetched
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Open an album in place, as the library's artist page does: the header
    /// switches to the album's cover, title and year.
    private func openAlbum(_ album: QQMusicOnlineAlbum) async {
        isLoadingSongs = true
        errorText = nil
        defer { isLoadingSongs = false }
        do {
            albumSongs = try await coordinator.albumTracks(albumID: album.id)
            openedAlbum = album
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
