//
//  QQMusicDownloadOrigin.swift
//  kmgccc_player
//
//  Why an online track's audio is on disk.
//
//  The distinction exists because the two kinds of download have different
//  owners: a file the user explicitly asked for is theirs and is never evicted,
//  while one the app fetched to keep playback ahead is a cache entry and can be
//  reclaimed when space runs short.
//
//  It records *whether the user ever asked for this track*, not why it was first
//  downloaded. That is what makes the automatic-to-manual transition work: a
//  track prefetched during playback becomes user-requested the moment the user
//  downloads or plays it deliberately, and stops counting as cache — without
//  downloading it a second time.
//

import Foundation

nonisolated enum QQMusicDownloadOrigin: String, Sendable, CaseIterable {
    /// The user asked for it: tapped play, tapped download, or chose it in the
    /// batch download sheet. Never reclaimed by the cache budget.
    case userRequested
    /// Fetched in the background to keep the queue fed. Reclaimable.
    case prefetch

    var displayName: String {
        switch self {
        case .userRequested: return "手动下载"
        case .prefetch: return "自动下载"
        }
    }
}

extension Track {
    /// Why this track's audio is on disk, if it came from the online source.
    ///
    /// Defaults to `.prefetch` when the field is absent, which is the safe
    /// direction: files imported before this was recorded cannot be classified,
    /// and treating them as reclaimable means a cache limit can actually be
    /// honoured. Treating them as permanent would silently make the limit
    /// unreachable. They are re-downloadable, so the cost of a wrong guess is
    /// small and recoverable.
    var qqMusicOrigin: QQMusicDownloadOrigin? {
        guard qqMusicSongMid?.isEmpty == false else { return nil }
        guard let raw = qqMusicDownloadOrigin,
              let origin = QQMusicDownloadOrigin(rawValue: raw)
        else { return .prefetch }
        return origin
    }

    /// Whether this file counts against the automatic-download cache budget.
    var countsAsDownloadCache: Bool {
        qqMusicOrigin == .prefetch
    }
}
