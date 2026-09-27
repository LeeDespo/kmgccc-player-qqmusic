//
//  QQMusicHomePage.swift
//  kmgccc_player
//
//  The online landing page: the shelves, laid out as the library's home is.
//
//  Section order, titles, card size, spacing and the trailing "查看全部"
//  affordance are all the library home's own (`HomeAlbumsSection` /
//  `HomeArtistsSection`). The `HorizontalFadeScrollContainer` underneath is
//  literally the same primitive, so a rail here scrolls, snaps and shows its
//  buttons exactly as a rail there does — including travelling past the
//  center column and under the sidebar glass.
//
//  Sections are rendered as the cards they are, not as rows of text: the
//  library's home is a wall of artwork, and a page of plain rows beside it
//  reads as a different application.
//

import SwiftUI

struct QQMusicHomePage: View {

    let navigation: QQMusicNavigation
    /// Width of the sidebar / lyrics panes. `HomeView` adds the layout mode's
    /// own horizontal padding to these to get the content column's edges; the
    /// computed pair below does the same, which is why a rail's first card lines
    /// up with the section title above it while the rail itself runs the full
    /// window width.
    let mode: HomeLayoutMode

    /// The content column's left/right edges, matching `HomeView`:
    /// `centerLeftPad = leftInset + mode.horizontalPadding`.
    private var centerLeftPad: CGFloat { insets.left + mode.horizontalPadding }
    private var centerRightPad: CGFloat { insets.right + mode.horizontalPadding }

    /// The columns this page aligns to. Supplied by the canvas, so no page
    /// can be drawn without it (see `QQMusicColumnInsetsKey`).
    @Environment(\.qqMusicColumnInsets) private var insets
    @Environment(QQMusicOnlineCoordinator.self) private var coordinator

    /// Which entry of the recommend feed the 精选 card is showing.
    @State private var heroIndex = 0

    /// Cards shown per shelf before deferring to the full list.
    ///
    /// The same trade the library's home makes: a bounded slice keeps the
    /// landing page quick to appear, and the full list is one tap away.
    private let shelfLimit = 20

    private var cardSize: CGFloat { QQMusicCardRail<EmptyView>.cardSize(for: mode) }

    var body: some View {
        QQMusicSectionHeader(
            title: "QQ 音乐",
            mode: mode,
            subtitle: coordinator.canDownload ? nil : "原位资料库：仅可浏览",
            leadingPad: centerLeftPad,
            trailingPad: centerRightPad
        )

        heroShelf
        playlistsShelf
        albumsShelf
        followedArtistsShelf
        newSongsShelf
        toplistsShelf
        radioShelf
        recommendShelf
    }

    // MARK: - 精选

    /// The featured card, at the top of the page as Home has it.
    ///
    /// Its content is the recommend feed — the online source's own "guess you
    /// like" — because that is what the app's hero is: a preference-weighted pick
    /// from what the source has to offer. 换一首 moves to the next entry, and asks
    /// the feed for more when it runs out, so the button never runs dry.
    @ViewBuilder
    private var heroShelf: some View {
        if let track = heroTrack {
            QQMusicHeroCard(
                track: track,
                containerWidth: contentColumnWidth,
                mode: mode,
                onPlay: { playHero(track) },
                onSwitch: switchHero
            )
            .padding(.leading, centerLeftPad)
            .padding(.trailing, centerRightPad)
        }
    }

    private var heroTrack: QQMusicOnlineTrack? {
        let feed = coordinator.recommendFeed
        guard !feed.isEmpty else { return nil }
        return feed[heroIndex % feed.count]
    }

    private func switchHero() {
        heroIndex &+= 1
        // The feed is short (the upstream hands back a handful per call), so a
        // switch that ran past the end asks for more rather than repeating.
        if heroIndex >= coordinator.recommendFeed.count {
            Task { await coordinator.extendRecommendFeed() }
        }
    }

    private func playHero(_ track: QQMusicOnlineTrack) {
        let feed = coordinator.recommendFeed
        let start = feed.firstIndex { $0.songMid == track.songMid } ?? 0
        Task {
            await coordinator.startPlayback(feed, startingAt: start, pageable: true)
        }
    }

    /// The content column's width, which the wide hero's height follows.
    private var contentColumnWidth: CGFloat {
        let center = HomeWindowLayoutState.shared.geometry.centerWidth
        let fallback = HomeWindowLayoutState.shared.discreteSnapshot.contentWidthBucket
        let width = center > 1 ? center : CGFloat(fallback)
        return max(200, width - mode.horizontalPadding * 2)
    }

    // MARK: - Shelves

    /// 我喜欢, presented as what it is upstream: a playlist.
    ///
    /// It lives *inside* 收藏歌单 rather than in a shelf of its own — it is a
    /// collected playlist like any other, and the user asked for it to sit first
    /// there. The heart stands in for the cover it does not have.
    @ViewBuilder
    private var likedSongsCard: some View {
        QQMusicCard(
            title: "我喜欢的音乐",
            subtitle: likedCountText,
            size: cardSize,
            titleColor: .primary,
            subtitleColor: .secondary,
            onOpen: { navigation.push(.likedSongs) }
        ) {
            QQMusicCardArtwork.LikedHeart(size: cardSize)
        }
    }

    private var likedCountText: String {
        coordinator.likedSongsTotal > 0
            ? "\(coordinator.likedSongsTotal) 首"
            : "我喜欢的音乐"
    }

    @ViewBuilder
    private var playlistsShelf: some View {
        if !coordinator.userPlaylists.isEmpty || !coordinator.likedSongs.isEmpty
            || coordinator.isLoadingLikedSongs {
            QQMusicSectionHeader(
                title: "收藏歌单",
                mode: mode,
                seeAllTitle: "查看全部",
                onSeeAll: { navigation.push(.userPlaylists) },
                subtitle: collectedCountText,
                leadingPad: centerLeftPad,
                trailingPad: centerRightPad
            )

            QQMusicCardRail(mode: mode) {
                likedSongsCard
                ForEach(coordinator.userPlaylists.prefix(shelfLimit)) { playlist in
                    QQMusicCard(
                        title: playlist.title,
                        subtitle: playlist.songCount.map { "\($0) 首" },
                        size: cardSize,
                        titleColor: .primary,
                        subtitleColor: .secondary,
                        onOpen: {
                            navigation.push(.playlist(id: playlist.id, title: playlist.title))
                        }
                    ) {
                        QQMusicArtworkView(
                            urlString: playlist.coverURL,
                            size: cardSize,
                            cornerRadius: cardSize * 0.06
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var albumsShelf: some View {
        if !coordinator.likedAlbums.isEmpty {
            QQMusicSectionHeader(
                title: "收藏专辑",
                mode: mode,
                seeAllTitle: "查看全部",
                onSeeAll: { navigation.push(.likedAlbums) },
                subtitle: "\(coordinator.likedAlbums.count) 张",
                leadingPad: centerLeftPad,
                trailingPad: centerRightPad
            )

            QQMusicCardRail(mode: mode) {
                ForEach(coordinator.likedAlbums.prefix(shelfLimit)) { album in
                    QQMusicCard(
                        title: album.title,
                        subtitle: album.artist,
                        size: cardSize,
                        titleColor: .primary,
                        subtitleColor: .secondary,
                        onOpen: {
                            navigation.push(.album(id: album.id, title: album.title))
                        }
                    ) {
                        QQMusicArtworkView(
                            urlString: album.coverURL,
                            size: cardSize,
                            cornerRadius: cardSize * 0.06
                        )
                    }
                }
            }
        }
    }

    /// 关注的歌手, directly under 收藏专辑 as asked.
    @ViewBuilder
    private var followedArtistsShelf: some View {
        if !coordinator.followedArtists.isEmpty {
            QQMusicSectionHeader(
                title: "关注的歌手",
                mode: mode,
                seeAllTitle: "查看全部",
                onSeeAll: { navigation.push(.followedArtists) },
                subtitle: "\(coordinator.followedArtists.count) 位",
                leadingPad: centerLeftPad,
                trailingPad: centerRightPad
            )

            QQMusicCardRail(mode: mode) {
                ForEach(coordinator.followedArtists.prefix(shelfLimit)) { artist in
                    QQMusicCard(
                        title: artist.name,
                        subtitle: QQMusicArtistIndexPage.fanText(artist.fanCount),
                        size: cardSize,
                        titleColor: .primary,
                        subtitleColor: .secondary,
                        onOpen: { navigation.push(.artist(QQMusicArtistRef(artist))) }
                    ) {
                        QQMusicArtworkView(
                            urlString: artist.coverURL,
                            size: cardSize,
                            cornerRadius: cardSize / 2
                        )
                    }
                }
            }
        }
    }

    /// Regions carry no artwork upstream, so the name stands in for one.
    @ViewBuilder
    private var newSongsShelf: some View {
        QQMusicSectionHeader(
            title: "新歌电台",
            mode: mode,
            seeAllTitle: nil,
            onSeeAll: nil,
            subtitle: "按地区",
            leadingPad: centerLeftPad,
            trailingPad: centerRightPad
        )

        QQMusicCardRail(mode: mode) {
            ForEach(QQMusicNewSongRegion.allCases, id: \.self) { region in
                QQMusicCard(
                    title: region.displayName,
                    subtitle: coordinator.newSongsRegion == region && !coordinator.newSongs.isEmpty
                        ? "\(coordinator.newSongs.count) 首"
                        : "新歌",
                    size: cardSize,
                    titleColor: .primary,
                    subtitleColor: .secondary,
                    onOpen: { navigation.push(.newSongs(region)) }
                ) {
                    QQMusicCardArtwork.TextCover(
                        text: region.displayName,
                        size: cardSize,
                        systemImage: "music.note"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var toplistsShelf: some View {
        let toplists = coordinator.toplistGroups.flatMap(\.toplists)
        if !toplists.isEmpty {
            QQMusicSectionHeader(
                title: "排行榜",
                mode: mode,
                seeAllTitle: "查看全部",
                onSeeAll: { navigation.push(.toplists) },
                subtitle: "\(toplists.count) 个",
                leadingPad: centerLeftPad,
                trailingPad: centerRightPad
            )

            QQMusicCardRail(mode: mode) {
                ForEach(toplists.prefix(shelfLimit)) { toplist in
                    QQMusicCard(
                        title: toplist.name,
                        // Rankings carry no artwork upstream either.
                        subtitle: "排行榜",
                        size: cardSize,
                        titleColor: .primary,
                        subtitleColor: .secondary,
                        onOpen: {
                            navigation.push(.toplist(id: toplist.id, title: toplist.name))
                        }
                    ) {
                        QQMusicCardArtwork.TextCover(
                            text: toplist.name,
                            size: cardSize,
                            systemImage: "chart.bar.fill"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var radioShelf: some View {
        let stations = coordinator.radioGroups.flatMap(\.stations)
        if !stations.isEmpty {
            QQMusicSectionHeader(
                title: "电台",
                mode: mode,
                seeAllTitle: "查看全部",
                onSeeAll: { navigation.push(.radio) },
                subtitle: "\(stations.count) 个",
                leadingPad: centerLeftPad,
                trailingPad: centerRightPad
            )

            QQMusicCardRail(mode: mode) {
                ForEach(stations.prefix(shelfLimit)) { station in
                    QQMusicCard(
                        title: station.title,
                        subtitle: station.listenerCount.map { Self.listenerText($0) },
                        size: cardSize,
                        titleColor: .primary,
                        subtitleColor: .secondary,
                        onOpen: {
                            navigation.push(.radioStation(id: station.id, title: station.title))
                        }
                    ) {
                        if let cover = station.coverURL, !cover.isEmpty {
                            QQMusicArtworkView(
                                urlString: cover,
                                size: cardSize,
                                cornerRadius: cardSize * 0.06
                            )
                        } else {
                            QQMusicCardArtwork.TextCover(
                                text: station.title,
                                size: cardSize,
                                systemImage: "dot.radiowaves.left.and.right"
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recommendShelf: some View {
        if !coordinator.recommendFeed.isEmpty {
            QQMusicSectionHeader(
                title: "猜你喜欢",
                mode: mode,
                seeAllTitle: "查看全部",
                onSeeAll: { navigation.push(.recommend) },
                subtitle: "为你推荐",
                leadingPad: centerLeftPad,
                trailingPad: centerRightPad
            )

            QQMusicCardRail(mode: mode) {
                ForEach(coordinator.recommendFeed.prefix(shelfLimit)) { track in
                    QQMusicCard(
                        title: track.title,
                        subtitle: track.artist,
                        size: cardSize,
                        titleColor: .primary,
                        subtitleColor: .secondary,
                        onOpen: {
                            // The feed has no per-track page; opening one plays it
                            // in its own list context, which is what a card tap
                            // means everywhere else on this page.
                            navigation.push(.recommend)
                        }
                    ) {
                        QQMusicArtworkView(
                            urlString: track.imageURL,
                            size: cardSize,
                            cornerRadius: cardSize * 0.06
                        )
                    }
                }
            }
        }
    }

    /// Playlists plus the liked folder, which is presented as one of them.
    private var collectedCountText: String {
        "\(coordinator.userPlaylists.count + 1) 个"
    }

    private static func listenerText(_ count: Int) -> String {
        QQMusicTrackListChrome.compactCount(count, suffix: "人在听")
    }
}
