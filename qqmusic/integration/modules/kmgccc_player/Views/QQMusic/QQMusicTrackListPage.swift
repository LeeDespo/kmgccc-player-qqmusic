//
//  QQMusicTrackListPage.swift
//  kmgccc_player
//
//  A page whose content is one list of online tracks.
//
//  Used for 我喜欢, 新歌电台 and 猜你喜欢, and for the playable lists behind
//  the entity indexes. Structurally it is the library's `PlaylistDetailView`:
//  a 220pt header, then the rows. What differs per page is the header's text,
//  its artwork, whether the list can be selected for batch download, and
//  whether it pages — all of which are decided from the `QQMusicPage` value
//  rather than by branching inside the layout.
//

import SwiftUI

struct QQMusicTrackListPage: View {

    let page: QQMusicPage
    let mode: HomeLayoutMode

    /// The columns this page aligns to. Supplied by the canvas, so no page
    /// can be drawn without it (see `QQMusicColumnInsetsKey`).
    @Environment(\.qqMusicColumnInsets) private var insets
    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @Environment(QQMusicNavigation.self) private var navigation
    @Environment(QQMusicSelectionModel.self) private var selection
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        header
        list
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        QQMusicDetailHeader(
            title: headerTitle,
            subtitle: headerSubtitle,
            metadata: headerMetadata,
            artworkURL: headerArtworkURL,
            placeholderSystemImage: headerPlaceholderIcon,
            onPlay: headerCanPlay ? { playAll() } : nil,
            canPlay: headerCanPlay,
            columnLeftPad: insets.left,
            columnRightPad: insets.right
        ) {
            // Nothing beside 播放: the batch-download control lives in the page's
            // top-right corner, so the header keeps the single primary action.
            EmptyView()
        }
        .padding(.horizontal, 0)
    }

    private var headerTitle: String {
        switch page {
        case .likedSongs: return "我喜欢的音乐"
        case .newSongs(let region): return "新歌电台 · \(region.displayName)"
        case .recommend: return "猜你喜欢"
        default: return page.title
        }
    }

    private var headerSubtitle: String? {
        switch page {
        case .likedSongs:
            return "QQ 音乐收藏"
        case .newSongs:
            return "按地区收听的在线新歌"
        case .recommend:
            return "根据你的收藏推荐"
        default:
            return nil
        }
    }

    /// 我喜欢 reads its count from the folder's own total: a few rows carry no
    /// playable track, so `tracks.count` can sit just below it and the header
    /// would look as though something had not loaded.
    private var headerMetadata: String? {
        let count = page == .likedSongs ? max(coordinator.likedSongsTotal, tracks.count) : tracks.count
        return QQMusicTrackListChrome.metadata(count: count, tracks: tracks)
    }

    private var headerArtworkURL: String? {
        switch page {
        case .likedSongs:
            // The liked folder has no cover of its own; the first track's
            // artwork is what the library does for a generated playlist cover.
            return tracks.first?.imageURL
        case .newSongs, .recommend:
            return tracks.first?.imageURL
        default:
            return nil
        }
    }

    private var headerPlaceholderIcon: String {
        switch page {
        case .likedSongs: return "heart.fill"
        case .recommend: return "sparkles"
        default: return "music.note"
        }
    }

    private var headerCanPlay: Bool { !tracks.isEmpty }

    private func playAll() {
        guard !tracks.isEmpty else { return }
        Task {
            await coordinator.startPlayback(
                tracks,
                startingAt: 0,
                pageable: isEndless
            )
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if tracks.isEmpty {
            if isLoading {
                QQMusicListStateView(kind: .loading("正在载入…"))
            } else {
                QQMusicListStateView(kind: .empty(emptyText, systemImage: emptyIcon))
            }
        } else {
            QQMusicTrackListBody(
                tracks: tracks,
                onReachEnd: { loadMoreIfNeeded() },
                onPlay: { displayed, index in play(displayed, at: index) }
            )
        }
    }

    // MARK: - Playback

    /// The list handed over is the one as displayed, so "play this one" means the
    /// same thing here as it does in the library: continue from where the user
    /// clicked.
    private func play(_ displayed: [QQMusicOnlineTrack], at index: Int) {
        Task {
            await coordinator.startPlayback(displayed, startingAt: index, pageable: isEndless)
        }
    }

    // MARK: - Loading

    /// Called when the end of the visible list comes into view.
    private func loadMoreIfNeeded() {
        if isEndless {
            Task { await coordinator.extendRecommendFeed() }
        } else if coordinator.hasMorePlaylistTracks {
            Task { await coordinator.loadMorePlaylistTracks() }
        }
    }

    private var isLoading: Bool {
        switch page {
        case .likedSongs: return coordinator.isLoadingLikedSongs
        case .newSongs: return coordinator.isLoadingNewSongs
        case .recommend: return coordinator.isLoadingFeed
        default: return false
        }
    }

    private var emptyText: String {
        switch page {
        case .likedSongs: return "还没有收藏的歌曲"
        case .newSongs: return "这个地区暂无新歌"
        case .recommend: return "暂无推荐"
        default: return "暂无内容"
        }
    }

    private var emptyIcon: String {
        switch page {
        case .likedSongs: return "heart"
        case .recommend: return "sparkles"
        default: return "music.note.list"
        }
    }

    // MARK: - Content

    private var tracks: [QQMusicOnlineTrack] {
        switch page {
        case .likedSongs: return coordinator.likedSongs
        case .newSongs: return coordinator.newSongs
        case .recommend: return coordinator.recommendFeed
        case .playlist, .album, .toplist, .radioStation:
            return coordinator.playlistTracks
        default: return []
        }
    }

    /// Whether the list continues indefinitely as the user scrolls.
    private var isEndless: Bool {
        page == .recommend
    }
}
