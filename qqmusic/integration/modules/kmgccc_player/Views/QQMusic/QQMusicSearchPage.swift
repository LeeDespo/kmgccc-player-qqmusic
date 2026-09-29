//
//  QQMusicSearchPage.swift
//  kmgccc_player
//
//  The search results page.
//
//  The keyword field is the window toolbar's, not the page's: the library
//  searches through the same field, and a second search box inside the page
//  was one of the things that made the online surface feel like a separate
//  application. What stays on the page is the content-type selector, because
//  the library has no equivalent — its own lists are already separated by the
//  sidebar.
//
//  Switching type re-runs the query in place (`navigation.replaceTop`) rather
//  than pushing: the user is changing a filter, not going somewhere. Back
//  therefore still returns to wherever they came from.
//

import SwiftUI

struct QQMusicSearchPage: View {

    /// The page's identity. The *live* type is read from the coordinator, which
    /// the toolbar field also writes to, so the selector cannot drift from the
    /// results on screen.
    let kind: QQMusicSearchKind
    let mode: HomeLayoutMode

    /// The columns this page aligns to. Supplied by the canvas, so no page
    /// can be drawn without it (see `QQMusicColumnInsetsKey`).
    @Environment(\.qqMusicColumnInsets) private var insets
    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @Environment(QQMusicNavigation.self) private var navigation
    @Environment(QQMusicSelectionModel.self) private var selection
    @EnvironmentObject private var themeStore: ThemeStore

    /// Gap between the type selector and the results.
    ///
    /// Every section adds exactly this above its first element, so the selector
    /// and the top of the results sit at the same y whichever type is on screen.
    /// `QQMusicDetailHeader` already keeps this much above itself (its own
    /// `.padding(.vertical, 20)`), which is why the songs section with results
    /// does not add it again.
    private static let resultsTopInset: CGFloat = 20

    var body: some View {
        // One root, not `typeSelector; content` side by side.
        //
        // As sibling children of the canvas's `LazyVStack` they were spaced by
        // *its* `sectionSpacing`, and the songs branch expands into more children
        // than the others (a header plus a list), so the page's own vertical
        // rhythm came from how many children a branch happened to produce — which
        // is what made switching the type shift the page. One child with explicit
        // spacing cannot do that.
        VStack(alignment: .leading, spacing: 0) {
            typeSelector
            content
        }
    }

    // MARK: - Type selector

    /// Left-aligned segmented control, at the leading edge of the content
    /// column. `fixedSize(horizontal:)` is what keeps it hugging its content
    /// instead of being centred inside the width it is given.
    private var typeSelector: some View {
        HStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { coordinator.onlineSearchKind },
                set: { newKind in
                    navigate(to: newKind)
                }
            )) {
                ForEach(QQMusicSearchKind.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)
        }
        .padding(.leading, insets.left + 24)
                .padding(.trailing, insets.right + 24)
        .padding(.top, 4)
    }

    /// Re-run the same keyword against the newly chosen type.
    private func navigate(to newKind: QQMusicSearchKind) {
        guard newKind != kind else { return }
        Task { await coordinator.searchFromToolbar(coordinator.onlineSearchKeyword, kind: newKind) }
    }

    // MARK: - Results

    @ViewBuilder
    private var content: some View {
        switch coordinator.onlineSearchKind {
        case .songs:
            songs
        case .artists:
            artists
        case .albums:
            albums
        case .playlists:
            playlists
        }
    }

    @ViewBuilder
    private var songs: some View {
        let results = coordinator.searchResults
        if results.isEmpty {
            Group {
                if coordinator.isSearching {
                    QQMusicListStateView(kind: .loading("正在搜索…"))
                } else {
                    QQMusicListStateView(
                        kind: .empty(emptySearchText, systemImage: "magnifyingglass")
                    )
                }
            }
            // No header here to carry the inset, so the state starts where the
            // header would.
            .padding(.top, Self.resultsTopInset)
        } else {
            QQMusicDetailHeader(
                title: "搜索结果",
                subtitle: nil,
                metadata: "\(results.count) 首歌曲",
                artworkURL: results.first?.imageURL,
                placeholderSystemImage: "magnifyingglass",
                onPlay: { playAll(results) },
                canPlay: !results.isEmpty,
                columnLeftPad: insets.left,
                columnRightPad: insets.right
            ) {
                EmptyView()
            }

            QQMusicTrackListBody(
                tracks: results,
                onPlay: { displayed, index in play(displayed, at: index) }
            )
        }
    }

    @ViewBuilder
    private var artists: some View {
        let found = coordinator.searchedArtists
        if found.isEmpty {
            if coordinator.isSearchingArtists {
                QQMusicListStateView(kind: .loading("正在搜索…"))
            } else {
                QQMusicListStateView(
                    kind: .empty(emptyArtistText, systemImage: "person.crop.circle")
                )
            }
        } else {
            // Rows start where the header would, so the top of the results does
            // not move when the type changes.
            VStack(spacing: 0) {
                LazyVStack(spacing: 0) {
                    ForEach(found) { artist in
                        QQMusicEntityRow(
                            title: artist.name,
                            subtitle: nil,
                            meta: countText(artist),
                            artworkURL: artist.coverURL,
                            circularArtwork: true,
                            placeholderSystemImage: "person.fill",
                            onOpen: { navigation.push(.artist(QQMusicArtistRef(artist))) }
                        ) {
                            AnyView(
                                Button {
                                    navigation.push(.artist(QQMusicArtistRef(artist)))
                                } label: {
                                    Label("打开歌手", systemImage: "person.crop.circle")
                                }
                            )
                        }
                    }
                }

                Color.clear.frame(height: QQMusicPageCanvas<EmptyView>.listBottomInset)
            }
            .padding(.top, Self.resultsTopInset)
        }
    }

    /// Album results, as entity rows like 收藏专辑 — the same shape the account's
    /// albums use, so an album looks the same wherever it is met.
    @ViewBuilder
    private var albums: some View {
        let found = coordinator.searchedAlbums
        if found.isEmpty {
            if coordinator.isSearchingAlbums {
                QQMusicListStateView(kind: .loading("正在搜索…"))
            } else {
                QQMusicListStateView(
                    kind: .empty(emptyAlbumText, systemImage: "opticaldisc")
                )
            }
        } else {
            // Rows start where the header would, so the top of the results does
            // not move when the type changes.
            VStack(spacing: 0) {
                LazyVStack(spacing: 0) {
                    ForEach(found) { album in
                        QQMusicEntityRow(
                            title: album.title,
                            subtitle: album.artist,
                            meta: album.releaseDate,
                            artworkURL: album.coverURL,
                            placeholderSystemImage: "opticaldisc",
                            onOpen: {
                                navigation.push(.album(id: album.id, title: album.title))
                            }
                        ) {
                            AnyView(
                                Button {
                                    navigation.push(.album(id: album.id, title: album.title))
                                } label: {
                                    Label("打开专辑", systemImage: "opticaldisc")
                                }
                            )
                        }
                    }
                }

                Color.clear.frame(height: QQMusicPageCanvas<EmptyView>.listBottomInset)
            }
            .padding(.top, Self.resultsTopInset)
        }
    }

    @ViewBuilder
    private var playlists: some View {
        let found = coordinator.searchedPlaylists
        if found.isEmpty {
            if coordinator.isSearchingPlaylists {
                QQMusicListStateView(kind: .loading("正在搜索…"))
            } else {
                QQMusicListStateView(
                    kind: .empty(emptyPlaylistText, systemImage: "music.note.list")
                )
            }
        } else {
            // Rows start where the header would, so the top of the results does
            // not move when the type changes.
            VStack(spacing: 0) {
                LazyVStack(spacing: 0) {
                    ForEach(found) { playlist in
                        QQMusicEntityRow(
                            title: playlist.title,
                            subtitle: playlist.creator,
                            meta: playlist.songCount.map { "\($0) 首" },
                            artworkURL: playlist.coverURL,
                            onOpen: {
                                navigation.push(.playlist(id: playlist.id, title: playlist.title))
                            }
                        ) {
                            AnyView(
                                Button {
                                    navigation.push(.playlist(id: playlist.id, title: playlist.title))
                                } label: {
                                    Label("打开歌单", systemImage: "music.note.list")
                                }
                            )
                        }
                    }
                }

                Color.clear.frame(height: QQMusicPageCanvas<EmptyView>.listBottomInset)
            }
            .padding(.top, Self.resultsTopInset)
        }
    }

    // MARK: - Actions

    private func playAll(_ tracks: [QQMusicOnlineTrack]) {
        Task { await coordinator.startPlayback(tracks, startingAt: 0) }
    }

    private func play(_ displayed: [QQMusicOnlineTrack], at index: Int) {
        Task { await coordinator.startPlayback(displayed, startingAt: index) }
    }

    // MARK: - Text

    private var emptySearchText: String {
        hasKeyword ? "没有找到相关歌曲" : "用工具栏的搜索框开始搜索"
    }

    private var emptyArtistText: String {
        hasKeyword ? "没有找到相关歌手" : "用工具栏的搜索框搜索歌手"
    }

    private var emptyAlbumText: String {
        hasKeyword ? "没有找到相关专辑" : "用工具栏的搜索框搜索专辑"
    }

    private var emptyPlaylistText: String {
        hasKeyword
            ? "没有找到相关歌单"
            : "用工具栏的搜索框搜索歌单，例如「爵士」「深夜」「运动」"
    }

    private var hasKeyword: Bool {
        !coordinator.onlineSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func countText(_ artist: QQMusicOnlineArtist) -> String? {
        var parts: [String] = []
        if let songs = artist.songCount { parts.append("\(songs) 首歌曲") }
        if let albums = artist.albumCount { parts.append("\(albums) 张专辑") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
