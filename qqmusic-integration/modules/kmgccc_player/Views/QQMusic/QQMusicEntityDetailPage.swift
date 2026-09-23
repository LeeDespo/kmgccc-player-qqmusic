//
//  QQMusicEntityDetailPage.swift
//  kmgccc_player
//
//  A playlist, album, ranking or radio station opened from the browse surface.
//
//  Shaped exactly like the library's `PlaylistDetailView`: a 220pt header
//  carrying the cover, title, artist and a "播放" capsule, then the track rows.
//  The user asked for the online pages to be the app's pages, and this is the
//  page where that matters most — a playlist opened from the online source
//  should be indistinguishable from a playlist opened from the library.
//
//  The list is loaded whole rather than paged by hand, because the source
//  reports its size: that is what lets shuffle cover the entire playlist, and
//  it is why the row count here is the true count rather than however many
//  pages happened to load.
//

import SwiftUI

struct QQMusicEntityDetailPage: View {

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

    private var header: some View {
        QQMusicDetailHeader(
            title: page.title,
            subtitle: subtitle,
            metadata: metadata,
            artworkURL: artworkURL,
            isCircleArtwork: isStation,
            placeholderSystemImage: placeholderIcon,
            description: nil,
            onPlay: tracks.isEmpty ? nil : { playAll() },
            canPlay: !tracks.isEmpty,
            columnLeftPad: leftPad,
            columnRightPad: rightPad
        ) {
            // Nothing beside 播放: the batch-download control lives in the page's
            // top-right corner, so the header keeps the single primary action.
            EmptyView()
        }
    }

    private var subtitle: String? {
        if isStation { return "在线电台" }
        if case .album = page { return nil }
        return trackCountText
    }

    /// Count and total duration, as the library's playlist header shows.
    ///
    /// The count is the list's own reported total while more pages are still
    /// arriving, so the header does not read "120 首" and then change to "471 首"
    /// in front of the user.
    private var metadata: String? {
        guard !tracks.isEmpty else { return nil }
        var parts: [String] = []
        let reported = coordinator.openedPlaylistTotal
        if reported > tracks.count {
            parts.append("已载入 \(tracks.count) / \(reported) 首")
        } else {
            parts.append("\(tracks.count) 首歌曲")
        }
        let seconds = tracks.compactMap(\.duration).reduce(0, +)
        if seconds > 0 { parts.append(Self.formatTotalDuration(Double(seconds))) }
        return parts.joined(separator: " · ")
    }

    /// The ranking index supplies the name but no cover, and the album's own
    /// cover comes from its first track's artwork when the index had none.
    private var artworkURL: String? {
        switch page {
        case .playlist, .album:
            return headerCoverFromIndex ?? tracks.first?.imageURL
        case .toplist, .radioStation:
            return headerCoverFromIndex
        default:
            return nil
        }
    }

    /// Cover carried by the index page that linked here, when it had one.
    private var headerCoverFromIndex: String? {
        switch page {
        case .playlist(let id, _):
            return coordinator.userPlaylists.first { $0.id == id }?.coverURL
        case .album(let id, _):
            return coordinator.likedAlbums.first { $0.id == id }?.coverURL
        case .radioStation(let id, _):
            return coordinator.radioGroups
                .flatMap(\.stations)
                .first { $0.id == id }?.coverURL
        default:
            return nil
        }
    }

    private var placeholderIcon: String {
        switch page {
        case .toplist: return "chart.bar.fill"
        case .radioStation: return "dot.radiowaves.left.and.right"
        case .album: return "opticaldisc"
        default: return "music.note.list"
        }
    }

    private var trackCountText: String? {
        guard !tracks.isEmpty else { return nil }
        return "\(tracks.count) 首歌曲"
    }

    private var isStation: Bool {
        if case .radioStation = page { return true }
        return false
    }

    private func playAll() {
        guard !tracks.isEmpty else { return }
        Task {
            await coordinator.startPlayback(tracks, startingAt: 0, pageable: isStation, isRadio: isStation)
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if tracks.isEmpty {
            if isLoading {
                QQMusicListStateView(kind: .loading("正在载入…"))
            } else {
                QQMusicListStateView(
                    kind: .empty(isStation ? "这个电台暂无曲目" : "这里还没有内容",
                                 systemImage: "music.note.list")
                )
            }
        } else {
            VStack(spacing: 0) {
                let displayedSongMids = displayedTracks.map(\.songMid)

                LazyVStack(spacing: 0) {
                    ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                        QQMusicTrackRow(
                            track: track,
                            // Rankings show their position, exactly as the
                            // upstream index does.
                            rank: isToplist ? index + 1 : nil,
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

                    if coordinator.isLoadingMorePlaylistTracks {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在载入其余曲目…")
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

    private var isToplist: Bool {
        if case .toplist = page { return true }
        return false
    }

    /// Rows in display order: already-owned tracks move to the end while
    /// selecting, since they cannot be selected.
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
        let ordered = displayedTracks
        let start = ordered.firstIndex(where: { $0.songMid == track.songMid }) ?? index
        Task {
            await coordinator.startPlayback(ordered, startingAt: start, pageable: isStation, isRadio: isStation)
        }
    }

    private func loadMoreIfNeeded(index: Int) {
        guard index >= tracks.count - 3 else { return }
        if isStation {
            Task { await coordinator.loadMoreRadioTracks() }
        } else if coordinator.hasMorePlaylistTracks {
            Task { await coordinator.loadMorePlaylistTracks() }
        }
    }

    private var isLoading: Bool {
        isStation ? coordinator.isLoadingRadioTracks : coordinator.isLoadingPlaylistTracks
    }

    private var tracks: [QQMusicOnlineTrack] { coordinator.playlistTracks }

    // MARK: - Selection

    /// A station is endless, so batch download is not offered there.
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
}
