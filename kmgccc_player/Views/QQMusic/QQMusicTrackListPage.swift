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
            columnLeftPad: leftPad,
            columnRightPad: rightPad
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

    private var headerMetadata: String? {
        guard !tracks.isEmpty else { return nil }
        var parts: [String] = []
        switch page {
        case .likedSongs:
            let total = max(coordinator.likedSongsTotal, tracks.count)
            parts.append("\(total) 首歌曲")
        default:
            parts.append("\(tracks.count) 首歌曲")
        }
        let seconds = tracks.compactMap(\.duration).reduce(0, +)
        if seconds > 0 {
            parts.append(Self.formatTotalDuration(Double(seconds)))
        }
        return parts.joined(separator: " · ")
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
            VStack(spacing: 0) {
                let displayedSongMids = displayedTracks.map(\.songMid)

                if page == .likedSongs && coordinator.hasMoreLikedSongs {
                    // The full list normally arrives in one batched round trip;
                    // this is the honest state while the remainder streams in.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在载入其余曲目…")
                            .font(.system(size: 11))
                            .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
                        Spacer()
                    }
                    .padding(.leading, leftPad + 24)
                .padding(.trailing, rightPad + 24)
                    .padding(.bottom, 6)
                }

                LazyVStack(spacing: 0) {
                    ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                        QQMusicTrackRow(
                            track: track,
                            columnLeftPad: leftPad + 24,
                            columnRightPad: rightPad + 24,
                            onPlay: { play(track, at: index) },
                            isSelecting: selection.isSelecting,
                            isSelected: selection.isSelected(track.songMid),
                            // Selection is a colour, and a run of selected rows
                            // merges into one block — so a row needs to know
                            // whether its neighbours are selected. Computed from
                            // the displayed order, which is what is on screen.
                            selectionContinuity: selection.continuity(at: index, in: displayedSongMids),
                            onToggleSelection: { selection.toggle(track.songMid) },
                            isOwnedByUser: coordinator.isUserDownloaded(track.songMid)
                        )
                        .onAppear { loadMoreIfNeeded(index: index) }
                    }

                    if isEndless {
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

                Color.clear.frame(height: QQMusicPageCanvas<EmptyView>.listBottomInset)
            }
        }
    }

    /// Rows in display order.
    ///
    /// While selecting, tracks the user already owns move to the end: they
    /// cannot be selected, so leaving them interleaved would put inert entries
    /// in the middle of the list the user is working through.
    /// Rows in display order.
    ///
    /// In selection mode the tracks the user already downloaded move to the
    /// **top**: they cannot be selected, so an inert block at the top is out of
    /// the way, while leaving them interleaved would put dead entries in the
    /// middle of the list being worked through. Every other mode shows the list
    /// exactly as the source gave it.
    private var displayedTracks: [QQMusicOnlineTrack] {
        guard selection.isSelecting else { return tracks }
        let owned = ownedSongMids
        return tracks.filter { owned.contains($0.songMid) }
            + tracks.filter { !owned.contains($0.songMid) }
    }

    private func play(_ track: QQMusicOnlineTrack, at index: Int) {
        // Play within the list as shown, so "play this one" means the same
        // thing it does in the library: continue through the list from here.
        let ordered = displayedTracks
        let start = ordered.firstIndex(where: { $0.songMid == track.songMid }) ?? index
        Task {
            await coordinator.startPlayback(ordered, startingAt: start, pageable: isEndless)
        }
    }

    // MARK: - Loading

    private func loadMoreIfNeeded(index: Int) {
        guard index >= tracks.count - 3 else { return }
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

    // MARK: - Selection

    private var ownedSongMids: Set<String> {
        Set(tracks.map(\.songMid).filter { coordinator.isUserDownloaded($0) })
    }

    private static func formatTotalDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分钟"
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
