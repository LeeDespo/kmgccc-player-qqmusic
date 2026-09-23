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

    var body: some View {
        typeSelector
        content
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
        .padding(.leading, leftPad + 24)
                .padding(.trailing, rightPad + 24)
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
        case .playlists:
            playlists
        }
    }

    @ViewBuilder
    private var songs: some View {
        let results = coordinator.searchResults
        if results.isEmpty {
            if coordinator.isSearching {
                QQMusicListStateView(kind: .loading("正在搜索…"))
            } else {
                QQMusicListStateView(
                    kind: .empty(emptySearchText, systemImage: "magnifyingglass")
                )
            }
        } else {
            QQMusicDetailHeader(
                title: "搜索结果",
                subtitle: nil,
                metadata: "\(results.count) 首歌曲",
                artworkURL: results.first?.imageURL,
                placeholderSystemImage: "magnifyingglass",
                onPlay: { playAll(results) },
                canPlay: !results.isEmpty,
                columnLeftPad: leftPad,
                columnRightPad: rightPad
            ) {
                EmptyView()
            }

            VStack(spacing: 0) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, track in
                        QQMusicTrackRow(
                            track: track,
                            columnLeftPad: leftPad + 24,
                            columnRightPad: rightPad + 24,
                            onPlay: { play(track, at: index, in: results) },
                            isSelecting: selection.isSelecting,
                            isSelected: selection.isSelected(track.songMid),
                            onToggleSelection: { selection.toggle(track.songMid) },
                            isOwnedByUser: coordinator.isUserDownloaded(track.songMid)
                        )
                        .onAppear {
                            guard index >= results.count - 3 else { return }
                            Task { await coordinator.search(coordinator.onlineSearchKeyword) }
                        }
                    }
                }

                Color.clear.frame(height: QQMusicPageCanvas<EmptyView>.listBottomInset)
            }
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
                            columnLeftPad: leftPad + 24,
                            columnRightPad: rightPad + 24,
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
            VStack(spacing: 0) {
                LazyVStack(spacing: 0) {
                    ForEach(found) { playlist in
                        QQMusicEntityRow(
                            title: playlist.title,
                            subtitle: playlist.creator,
                            meta: playlist.songCount.map { "\($0) 首" },
                            artworkURL: playlist.coverURL,
                            columnLeftPad: leftPad + 24,
                            columnRightPad: rightPad + 24,
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
        }
    }

    // MARK: - Actions

    private func playAll(_ tracks: [QQMusicOnlineTrack]) {
        Task { await coordinator.startPlayback(tracks, startingAt: 0) }
    }

    private func play(_ track: QQMusicOnlineTrack, at index: Int, in list: [QQMusicOnlineTrack]) {
        let start = list.firstIndex(where: { $0.songMid == track.songMid }) ?? index
        Task { await coordinator.startPlayback(list, startingAt: start) }
    }

    // MARK: - Text

    private var emptySearchText: String {
        hasKeyword ? "没有找到相关歌曲" : "用工具栏的搜索框开始搜索"
    }

    private var emptyArtistText: String {
        hasKeyword ? "没有找到相关歌手" : "用工具栏的搜索框搜索歌手"
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
