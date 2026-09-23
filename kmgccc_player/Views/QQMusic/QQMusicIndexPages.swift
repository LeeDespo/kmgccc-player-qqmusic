//
//  QQMusicIndexPages.swift
//  kmgccc_player
//
//  The "more" pages behind the home shelves: 收藏歌单, 收藏专辑, 排行榜, 电台.
//
//  Each one is the library's list page for its kind — `AllPlaylistsView` /
//  `AllAlbumsView` / `AllArtistsView` — which means: no page title bar, no tab
//  strip, 60pt artwork, 76pt rows on the hover wash, 24pt horizontal padding
//  and 16pt top padding. Identity comes from the toolbar's back pill, exactly
//  as on the library side.
//
//  These were the pages the user reported as "still the old page with a tab
//  bar at the top": they were previously rendered by the same segmented view
//  that owned the landing page. They are now their own pages.
//

import SwiftUI

// MARK: - Playlists

struct QQMusicPlaylistIndexPage: View {

    /// Center-column insets: the width of the sidebar / lyrics panes.
    /// Every alignment below adds the library's own content padding to
    /// these, which is how a full-window page lines up with a page that
    /// lives inside the center pane.
    let leftPad: CGFloat
    let rightPad: CGFloat
    let mode: HomeLayoutMode

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @Environment(QQMusicNavigation.self) private var navigation

    /// The liked folder counts as one of these, so the header says so.
    private var totalCount: Int { coordinator.userPlaylists.count + 1 }

    var body: some View {
        indexHeader(title: "收藏歌单", count: totalCount, leftPad: leftPad, rightPad: rightPad)

        list
    }

    private var list: some View {
        VStack(spacing: 0) {
            LazyVStack(spacing: 0) {
                // 我喜欢 first: upstream it is a playlist, and the user asked for
                // it to head this list rather than get a shelf of its own.
                QQMusicEntityRow(
                    title: "我喜欢的音乐",
                    subtitle: "QQ 音乐收藏",
                    meta: coordinator.likedSongsTotal > 0
                        ? "\(coordinator.likedSongsTotal) 首歌曲"
                        : nil,
                    artworkURL: nil,
                    placeholderSystemImage: "heart.fill",
                    columnLeftPad: leftPad + 24,
                    columnRightPad: rightPad + 24,
                    onOpen: { navigation.push(.likedSongs) }
                ) {
                    AnyView(
                        Button {
                            navigation.push(.likedSongs)
                        } label: {
                            Label("打开歌单", systemImage: "heart")
                        }
                    )
                }

                ForEach(coordinator.userPlaylists) { playlist in
                    QQMusicEntityRow(
                        title: playlist.title,
                        subtitle: playlist.creator,
                        meta: metaText(playlist),
                        artworkURL: playlist.coverURL,
                        columnLeftPad: leftPad + 24,
                        columnRightPad: rightPad + 24,
                        onOpen: {
                            navigation.push(.playlist(id: playlist.id, title: playlist.title))
                        }
                    ) {
                        AnyView(Group {
                            Button {
                                navigation.push(.playlist(id: playlist.id, title: playlist.title))
                            } label: {
                                Label("打开歌单", systemImage: "music.note.list")
                            }
                            Button {
                                play(playlist)
                            } label: {
                                Label("播放该歌单", systemImage: "play.fill")
                            }
                        })
                    }
                }
            }

            Color.clear.frame(height: QQMusicPageCanvas<EmptyView>.listBottomInset)
        }
    }

    private func metaText(_ playlist: QQMusicOnlinePlaylist) -> String? {
        var parts: [String] = []
        if let count = playlist.songCount { parts.append("\(count) 首歌曲") }
        if let plays = playlist.playCount, plays > 0 {
            parts.append(Self.playCountText(plays))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func play(_ playlist: QQMusicOnlinePlaylist) {
        // Opening downloads the list and then starts it; there is nothing to
        // play until the tracks are known, so this is the same action as open.
        navigation.push(.playlist(id: playlist.id, title: playlist.title))
    }

    private static func playCountText(_ count: Int) -> String {
        count >= 10_000
            ? String(format: "%.1f 万次播放", Double(count) / 10_000)
            : "\(count) 次播放"
    }
}

// MARK: - Albums

struct QQMusicAlbumIndexPage: View {

    /// Center-column insets: the width of the sidebar / lyrics panes.
    /// Every alignment below adds the library's own content padding to
    /// these, which is how a full-window page lines up with a page that
    /// lives inside the center pane.
    let leftPad: CGFloat
    let rightPad: CGFloat
    let mode: HomeLayoutMode

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @Environment(QQMusicNavigation.self) private var navigation

    var body: some View {
        indexHeader(title: "收藏专辑", count: coordinator.likedAlbums.count, leftPad: leftPad, rightPad: rightPad)

        if coordinator.likedAlbums.isEmpty {
            if coordinator.isLoadingLikedAlbums {
                QQMusicListStateView(kind: .loading("正在载入…"))
            } else {
                QQMusicListStateView(
                    kind: .empty("还没有收藏的专辑", systemImage: "opticaldisc")
                )
            }
        } else {
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            LazyVStack(spacing: 0) {
                ForEach(coordinator.likedAlbums) { album in
                    QQMusicEntityRow(
                        title: album.title,
                        subtitle: album.artist,
                        meta: album.releaseDate,
                        artworkURL: album.coverURL,
                        placeholderSystemImage: "opticaldisc",
                        columnLeftPad: leftPad + 24,
                        columnRightPad: rightPad + 24,
                        onOpen: {
                            navigation.push(.album(id: album.id, title: album.title))
                        }
                    ) {
                        AnyView(Group {
                            Button {
                                navigation.push(.album(id: album.id, title: album.title))
                            } label: {
                                Label("打开专辑", systemImage: "opticaldisc")
                            }
                        })
                    }
                }
            }

            Color.clear.frame(height: QQMusicPageCanvas<EmptyView>.listBottomInset)
        }
    }
}

// MARK: - Rankings

struct QQMusicToplistIndexPage: View {

    /// Center-column insets: the width of the sidebar / lyrics panes.
    /// Every alignment below adds the library's own content padding to
    /// these, which is how a full-window page lines up with a page that
    /// lives inside the center pane.
    let leftPad: CGFloat
    let rightPad: CGFloat
    let mode: HomeLayoutMode

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @Environment(QQMusicNavigation.self) private var navigation
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        indexHeader(title: "排行榜", count: coordinator.toplistGroups.flatMap(\.toplists).count, leftPad: leftPad, rightPad: rightPad)

        if coordinator.toplistGroups.isEmpty {
            if coordinator.isLoadingToplists {
                QQMusicListStateView(kind: .loading("正在载入…"))
            } else {
                QQMusicListStateView(kind: .empty("暂无排行榜", systemImage: "chart.bar"))
            }
        } else {
            groupedList
        }
    }

    /// Grouped under their upstream headings, as the library groups its own
    /// collections. The heading uses the library's list-section type.
    private var groupedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Grouped by index: `QQMusicToplistGroup.id` is optional upstream,
            // so the group is not `Identifiable`.
            ForEach(Array(coordinator.toplistGroups.enumerated()), id: \.offset) { _, group in
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                    .padding(.leading, leftPad + 24)
                    .padding(.top, 16)
                    .padding(.bottom, 4)

                LazyVStack(spacing: 0) {
                    ForEach(group.toplists) { toplist in
                        QQMusicEntityRow(
                            title: toplist.name,
                            subtitle: nil,
                            meta: nil,
                            artworkURL: nil,
                            placeholderSystemImage: "chart.bar.fill",
                            columnLeftPad: leftPad + 24,
                            columnRightPad: rightPad + 24,
                            onOpen: {
                                navigation.push(.toplist(id: toplist.id, title: toplist.name))
                            }
                        ) {
                            AnyView(
                                Button {
                                    navigation.push(.toplist(id: toplist.id, title: toplist.name))
                                } label: {
                                    Label("打开排行榜", systemImage: "chart.bar")
                                }
                            )
                        }
                    }
                }
            }

            Color.clear.frame(height: QQMusicPageCanvas<EmptyView>.listBottomInset)
        }
    }
}

// MARK: - Radio stations

struct QQMusicRadioIndexPage: View {

    /// Center-column insets: the width of the sidebar / lyrics panes.
    /// Every alignment below adds the library's own content padding to
    /// these, which is how a full-window page lines up with a page that
    /// lives inside the center pane.
    let leftPad: CGFloat
    let rightPad: CGFloat
    let mode: HomeLayoutMode

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @Environment(QQMusicNavigation.self) private var navigation
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        indexHeader(title: "电台", count: coordinator.radioGroups.flatMap(\.stations).count, leftPad: leftPad, rightPad: rightPad)

        if coordinator.radioGroups.isEmpty {
            if coordinator.isLoadingRadioStations {
                QQMusicListStateView(kind: .loading("正在载入…"))
            } else {
                QQMusicListStateView(kind: .empty("暂无电台", systemImage: "dot.radiowaves.left.and.right"))
            }
        } else {
            groupedList
        }
    }

    private var groupedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(coordinator.radioGroups.enumerated()), id: \.offset) { _, group in
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                    .padding(.leading, leftPad + 24)
                    .padding(.top, 16)
                    .padding(.bottom, 4)

                LazyVStack(spacing: 0) {
                    ForEach(group.stations) { station in
                        QQMusicEntityRow(
                            title: station.title,
                            subtitle: nil,
                            meta: station.listenerCount.map { Self.listenerText($0) },
                            artworkURL: station.coverURL,
                            placeholderSystemImage: "dot.radiowaves.left.and.right",
                            columnLeftPad: leftPad + 24,
                            columnRightPad: rightPad + 24,
                            onOpen: {
                                navigation.push(.radioStation(id: station.id, title: station.title))
                            }
                        ) {
                            AnyView(
                                Button {
                                    navigation.push(.radioStation(id: station.id, title: station.title))
                                } label: {
                                    Label("打开电台", systemImage: "dot.radiowaves.left.and.right")
                                }
                            )
                        }
                    }
                }
            }

            Color.clear.frame(height: QQMusicPageCanvas<EmptyView>.listBottomInset)
        }
    }

    private static func listenerText(_ count: Int) -> String {
        count >= 10_000
            ? String(format: "%.1f 万人在听", Double(count) / 10_000)
            : "\(count) 人在听"
    }
}

// MARK: - Shared header

/// The line above an index list.
///
/// The library's own index pages have no title — the sidebar says where you
/// are. These pages have no sidebar entry, so one line of context is drawn in
/// the app's own section-title type, aligned with the list below it. It is a
/// caption, not a page banner: it scrolls away with the content.
@ViewBuilder
func indexHeader(title: String, count: Int, leftPad: CGFloat, rightPad: CGFloat) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(title)
            .font(.system(size: 20, weight: .semibold))
        if count > 0 {
            Text("\(count) 个")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        Spacer()
    }
    .padding(.leading, leftPad + 24)
    .padding(.trailing, rightPad + 24)
    .padding(.top, 8)
    .padding(.bottom, 4)
}
