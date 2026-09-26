//
//  QQMusicTrackListBody.swift
//  kmgccc_player
//
//  The rows of an online track list.
//
//  Four pages drew this themselves — 我喜欢 / 新歌电台 / 猜你喜欢, the entity detail
//  pages, search results and an artist's songs — and the four copies had drifted
//  into agreeing on everything anyway: the same `LazyVStack`, the same row
//  arguments, the same "already-owned rows first while selecting" ordering, the
//  same play-from-here rule, the same bottom spacer. Three of them had also each
//  grown their own copy of the duration formatter.
//
//  What differs per page is only ever *which* tracks and *what happens* at the
//  end of the list, so those are the parameters. Everything else — the selection
//  wiring, the selection-run continuity, the ownership dimming, the padding —
//  lives here once.
//

import SwiftUI

struct QQMusicTrackListBody: View {

    let tracks: [QQMusicOnlineTrack]
    /// Rankings show their position, the way the upstream index does.
    var showsRank: Bool = false
    /// Whether rows may be selected for batch download. An artist's song list and
    /// a station are endless, so a selection there could not mean "all".
    var allowsSelection: Bool = true
    /// Called when the end of the list comes into view, so a paging page can ask
    /// for more. Nil for lists with a fixed end.
    var onReachEnd: (() -> Void)?
    /// Play from this position. The list is handed over **as displayed**, so
    /// "play this one" means the same thing here as it does in the library:
    /// continue through the list from where the user clicked.
    let onPlay: (_ displayedTracks: [QQMusicOnlineTrack], _ index: Int) -> Void

    /// The columns the list aligns to, plus the library's own 24pt content
    /// padding — read here rather than passed in, so a list's rows and the
    /// header above them cannot disagree about where the column starts.
    @Environment(\.qqMusicColumnInsets) private var insets
    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @Environment(QQMusicSelectionModel.self) private var selection
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        let displayed = displayedTracks
        let displayedSongMids = displayed.map(\.songMid)

        VStack(spacing: 0) {
            LazyVStack(spacing: 0) {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, track in
                    QQMusicTrackRow(
                        track: track,
                        rank: showsRank ? index + 1 : nil,
                        columnLeftPad: insets.left + Self.contentPadding,
                        columnRightPad: insets.right + Self.contentPadding,
                        onPlay: { onPlay(displayed, index) },
                        isSelecting: isSelecting,
                        isSelected: selection.isSelected(track.songMid),
                        // Selection is a colour, and a run of selected rows merges
                        // into one block — so a row needs to know whether its
                        // neighbours are selected. Computed from the displayed
                        // order, which is what is actually adjacent on screen.
                        selectionContinuity: selection.continuity(at: index, in: displayedSongMids),
                        onToggleSelection: { selection.toggle(track.songMid) },
                        isOwnedByUser: coordinator.isUserDownloaded(track.songMid)
                    )
                    .onAppear {
                        guard index >= tracks.count - 3 else { return }
                        onReachEnd?()
                    }
                }
            }

            Color.clear.frame(height: QQMusicPageCanvas<EmptyView>.listBottomInset)
        }
    }

    /// The library's own content padding inside the center pane.
    private static let contentPadding: CGFloat = 24

    private var isSelecting: Bool { allowsSelection && selection.isSelecting }

    /// Rows in display order.
    ///
    /// In selection mode the tracks the user already downloaded move to the
    /// **top**: they cannot be selected, so an inert block at the top is out of
    /// the way, while leaving them interleaved would put dead entries in the
    /// middle of the list being worked through. Every other mode shows the list
    /// exactly as the source gave it.
    private var displayedTracks: [QQMusicOnlineTrack] {
        guard isSelecting else { return tracks }
        let owned = Set(tracks.map(\.songMid).filter { coordinator.isUserDownloaded($0) })
        return tracks.filter { owned.contains($0.songMid) }
            + tracks.filter { !owned.contains($0.songMid) }
    }
}

// MARK: - Shared list chrome

enum QQMusicTrackListChrome {

    /// "471 首歌曲" + a total running time. Used by every list header.
    static func metadata(count: Int, tracks: [QQMusicOnlineTrack]) -> String? {
        guard count > 0 else { return nil }
        var parts = ["\(count) 首歌曲"]
        let seconds = tracks.compactMap(\.duration).reduce(0, +)
        if seconds > 0 {
            parts.append(formatTotalDuration(Double(seconds)))
        }
        return parts.joined(separator: " · ")
    }

    static func formatTotalDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分钟"
    }

    /// "1.2 万" style counts, for listeners and plays.
    static func compactCount(_ count: Int, suffix: String) -> String {
        count >= 10_000
            ? String(format: "%.1f 万%@", Double(count) / 10_000, suffix)
            : "\(count)\(suffix)"
    }
}
