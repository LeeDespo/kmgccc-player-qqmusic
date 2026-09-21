//
//  QQMusicHomeView.swift
//  kmgccc_player
//
//  The QQ Music landing page, laid out like the app's own home page.
//
//  The point of matching the library's home is that the online source should
//  read as part of the same application: same shelf primitive, same card size
//  and spacing, same "see all" affordance. Each shelf shows a bounded slice and
//  defers the full list to a pushed page — rendering hundreds of covers inline
//  would make the landing page slow to appear, which is the same trade the
//  library's home sections make.
//

import SwiftUI

/// Which full list a shelf's "see all" opens.
enum QQMusicHomeDestination: Hashable {
    case likedSongs
    case userPlaylists
    case likedAlbums
    case newSongs
    case toplists
    case radio
    case recommend
}

struct QQMusicHomeView: View {

    let onOpen: (QQMusicHomeDestination) -> Void

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @EnvironmentObject private var themeStore: ThemeStore

    /// Covers shown per shelf before deferring to the full list.
    private let shelfLimit = 20
    private let cardSize: CGFloat = 146

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 22) {
                likedSongsShelf
                playlistsShelf
                albumsShelf
                newSongsShelf
                toplistsShelf
                radioShelf
                recommendShelf

                // The playback bar floats over the content.
                Color.clear.frame(height: GlassStyleTokens.miniPlayerHeight + 70)
            }
            .padding(.vertical, 16)
        }
    }

    // MARK: - Shelves

    /// The liked folder sits first because it is the most-used entry, and is a
    /// favourite *playlist* in upstream terms — so it is presented as one, with
    /// a heart standing in for the cover it does not have.
    private var likedSongsShelf: some View {
        QQMusicShelf(
            title: "我喜欢",
            seeAllTitle: coordinator.likedSongs.isEmpty ? nil : "查看全部",
            onSeeAll: { onOpen(.likedSongs) },
            cardCount: coordinator.likedSongs.isEmpty ? 0 : 1
        ) {
            QQMusicShelfCard(
                title: "我喜欢的音乐",
                subtitle: "\(coordinator.likedSongsTotal) 首",
                size: cardSize,
                onOpen: { onOpen(.likedSongs) }
            ) {
                QQMusicShelfArtwork.LikedHeart(size: cardSize)
            }
        }
    }

    private var playlistsShelf: some View {
        QQMusicShelf(
            title: "收藏歌单",
            seeAllTitle: "查看全部",
            onSeeAll: { onOpen(.userPlaylists) },
            cardCount: coordinator.userPlaylists.count
        ) {
            ForEach(coordinator.userPlaylists.prefix(shelfLimit)) { playlist in
                QQMusicShelfCard(
                    title: playlist.title,
                    subtitle: playlist.songCount.map { "\($0) 首" } ?? "歌单",
                    size: cardSize,
                    onOpen: { onOpen(.userPlaylists) }
                ) {
                    QQMusicArtworkView(urlString: playlist.coverURL, size: cardSize, cornerRadius: 8)
                }
            }
        }
    }

    private var albumsShelf: some View {
        QQMusicShelf(
            title: "收藏专辑",
            seeAllTitle: "查看全部",
            onSeeAll: { onOpen(.likedAlbums) },
            cardCount: coordinator.likedAlbums.count
        ) {
            ForEach(coordinator.likedAlbums.prefix(shelfLimit)) { album in
                QQMusicShelfCard(
                    title: album.title,
                    subtitle: album.artist ?? "专辑",
                    size: cardSize,
                    onOpen: { onOpen(.likedAlbums) }
                ) {
                    QQMusicArtworkView(urlString: album.coverURL, size: cardSize, cornerRadius: 8)
                }
            }
        }
    }

    /// Regions have no artwork upstream, so the name stands in for one.
    private var newSongsShelf: some View {
        QQMusicShelf(
            title: "新歌电台",
            seeAllTitle: "查看全部",
            onSeeAll: { onOpen(.newSongs) },
            cardCount: QQMusicNewSongRegion.allCases.count
        ) {
            ForEach(QQMusicNewSongRegion.allCases, id: \.self) { region in
                QQMusicShelfCard(
                    title: region.displayName,
                    subtitle: coordinator.newSongsRegion == region ? "当前" : "新歌",
                    size: cardSize,
                    onOpen: { onOpen(.newSongs) }
                ) {
                    QQMusicShelfArtwork.TextCover(text: region.displayName, size: cardSize)
                }
            }
        }
    }

    private var toplistsShelf: some View {
        // Grouped upstream; the shelf flattens them, which reads as one row.
        let toplists = coordinator.toplistGroups.flatMap(\.toplists)
        return QQMusicShelf(
            title: "排行榜",
            seeAllTitle: "查看全部",
            onSeeAll: { onOpen(.toplists) },
            cardCount: toplists.count
        ) {
            ForEach(toplists.prefix(shelfLimit)) { toplist in
                QQMusicShelfCard(
                    title: toplist.name,
                    subtitle: "排行榜",
                    size: cardSize,
                    onOpen: { onOpen(.toplists) }
                ) {
                    // Rankings carry no artwork upstream, so the name stands in.
                    QQMusicShelfArtwork.TextCover(text: toplist.name, size: cardSize)
                }
            }
        }
    }

    private var radioShelf: some View {
        let stations = coordinator.radioGroups.flatMap(\.stations)
        return QQMusicShelf(
            title: "电台",
            seeAllTitle: "查看全部",
            onSeeAll: { onOpen(.radio) },
            cardCount: stations.count
        ) {
            ForEach(stations.prefix(shelfLimit)) { station in
                QQMusicShelfCard(
                    title: station.title,
                    subtitle: station.listenerCount.map { "\($0) 人在听" } ?? "电台",
                    size: cardSize,
                    onOpen: { onOpen(.radio) }
                ) {
                    // Stations have a cover when the upstream supplies one, and
                    // a text stand-in when it does not.
                    if let cover = station.coverURL, !cover.isEmpty {
                        QQMusicArtworkView(urlString: cover, size: cardSize, cornerRadius: 8)
                    } else {
                        QQMusicShelfArtwork.TextCover(text: station.title, size: cardSize)
                    }
                }
            }
        }
    }

    private var recommendShelf: some View {
        QQMusicShelf(
            title: "猜你喜欢",
            seeAllTitle: "查看全部",
            onSeeAll: { onOpen(.recommend) },
            cardCount: coordinator.recommendFeed.count
        ) {
            ForEach(coordinator.recommendFeed.prefix(shelfLimit)) { track in
                QQMusicShelfCard(
                    title: track.title,
                    subtitle: track.artist,
                    size: cardSize,
                    onOpen: { onOpen(.recommend) }
                ) {
                    QQMusicArtworkView(urlString: track.imageURL, size: cardSize, cornerRadius: 8)
                }
            }
        }
    }
}
