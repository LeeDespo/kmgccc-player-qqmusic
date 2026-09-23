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
    /// Center-column insets: the width of the sidebar / lyrics panes.
    /// Every alignment below adds the library's own content padding to
    /// these, which is how a full-window page lines up with a page that
    /// lives inside the center pane.
    let leftPad: CGFloat
    let rightPad: CGFloat
    let mode: HomeLayoutMode

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

    private enum SongSort: String, CaseIterable, Identifiable {
        case hot
        case latest

        var id: String { rawValue }
        var title: String { self == .hot ? "热门" : "最新" }
    }

    @State private var tab: Tab = .songs
    @State private var songSort: SongSort = .hot
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
            // Omitted rather than drawn disabled on the albums tab: "play all
            // albums" has no meaning.
            onPlay: canPlayFromHeader ? { playFromHeader() } : nil,
            canPlay: canPlayFromHeader
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

                // An album has no notion of hot/latest, so this is absent on the
                // album tab rather than present but meaningless.
                if tab == .songs {
                    Picker("", selection: $songSort) {
                        ForEach(SongSort.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize(horizontal: true, vertical: false)
                    .onChange(of: songSort) { _, _ in
                        Task { await loadSongs(force: true) }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, leftPad + 24)
                .padding(.trailing, rightPad + 24)
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
        let list = currentTracks
        if list.isEmpty {
            if isLoadingSongs {
                QQMusicListStateView(kind: .loading("正在载入…"))
            } else {
                QQMusicListStateView(kind: .empty("暂无歌曲", systemImage: "music.note.list"))
            }
        } else {
            VStack(spacing: 0) {
                let listSongMids = list.map(\.songMid)

                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, track in
                        QQMusicTrackRow(
                            track: track,
                            columnLeftPad: leftPad + 24,
                            columnRightPad: rightPad + 24,
                            onPlay: { play(track, at: index, in: list) },
                            isSelecting: selection.isSelecting && !isShowingAlbum,
                            isSelected: selection.isSelected(track.songMid),
                            // Selection is a colour, and a run of selected rows
                            // merges into one block — so a row needs to know
                            // whether its neighbours are selected. Computed from
                            // the displayed order, which is what is on screen.
                            selectionContinuity: selection.continuity(at: index, in: listSongMids),
                            onToggleSelection: { selection.toggle(track.songMid) },
                            isOwnedByUser: coordinator.isUserDownloaded(track.songMid)
                        )
                        .onAppear {
                            // Artists can have over a thousand songs, so page as
                            // the end comes into view rather than up front.
                            guard !isShowingAlbum, index >= list.count - 5 else { return }
                            Task { await loadMoreSongs() }
                        }
                    }

                    if isLoadingMore {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在载入更多…")
                                .font(.system(size: 11))
                                .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                }
                .padding(.leading, leftPad + 24)
                .padding(.trailing, rightPad + 24)

                Color.clear.frame(height: QQMusicPageCanvas<EmptyView>.listBottomInset)
            }
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
            .padding(.leading, leftPad + 24)
                .padding(.trailing, rightPad + 24)
        }
    }

    private var ownedSongMids: Set<String> {
        Set(songs.map(\.songMid).filter { coordinator.isUserDownloaded($0) })
    }

    private func play(_ track: QQMusicOnlineTrack, at index: Int, in list: [QQMusicOnlineTrack]) {
        let start = list.firstIndex(where: { $0.songMid == track.songMid }) ?? index
        Task { await coordinator.startPlayback(list, startingAt: start) }
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
            albums = []
            await loadAlbums()
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
                sort: songSort == .hot ? .hot : .latest,
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
                sort: songSort == .hot ? .hot : .latest,
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

    private func loadAlbums() async {
        if !albums.isEmpty { return }
        isLoadingAlbums = true
        errorText = nil
        defer { isLoadingAlbums = false }
        do {
            albums = try await coordinator.artistAlbums(singerMid: artist.singerMid)
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
