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
//  It records *whether the user asked for this file*, and only the download
//  actions count as asking. Playing a song is a request to hear it, not to keep
//  it: the audio playback needs is fetched automatically, including the track
//  playback starts on. Counting those as the user's own made every listening
//  session look like a pile of deliberate downloads — the cache read as empty and
//  nothing was ever reclaimable.
//
//  The label is not one-way. Choosing an automatic download in 选择下载 promotes
//  it without fetching it again, and nothing ever demotes the user's own back to
//  automatic.
//

import Foundation

nonisolated enum QQMusicDownloadOrigin: String, Sendable, CaseIterable {
    /// The user asked for this file: 下载 in a row's menu, or 选择下载. Never
    /// reclaimed by the cache budget.
    case userRequested
    /// Fetched because playback needed it — the track playback started on, the
    /// tracks prefetched to keep the queue fed, and anything queued by 下一首播放.
    /// Reclaimable.
    case prefetch

    var displayName: String {
        switch self {
        case .userRequested: return "手动下载"
        case .prefetch: return "自动下载"
        }
    }

    /// Whether recording `next` should replace what a track already says.
    ///
    /// The rule in one place, because it is the whole of the label semantics:
    ///
    ///   - nothing recorded yet → record it;
    ///   - a download the user asks for replaces an automatic label (the
    ///     conversion, which must not re-fetch the file);
    ///   - anything else leaves the existing label alone, so a later prefetch can
    ///     never take away ownership the user already has. Deletion is decided
    ///     from this label, so a demotion here would put the user's own music back
    ///     in the reclaimable pool.
    static func shouldReplace(existing: String?, with next: QQMusicDownloadOrigin) -> Bool {
        guard let existing else { return true }
        switch next {
        case .userRequested: return existing != QQMusicDownloadOrigin.userRequested.rawValue
        case .prefetch: return false
        }
    }
}

extension Track {
    /// Why this track's audio is on disk, if it came from the online source.
    ///
    /// An unrecorded download is treated as **user-requested**, which means it is
    /// never reclaimed. This is deliberately the opposite of what would make the
    /// cache limit easiest to honour, and it was learned the hard way: the first
    /// version defaulted to `.prefetch` on the reasoning that unclassified files
    /// are re-downloadable, and it deleted the user's own downloaded music — every
    /// track downloaded before this field existed was unrecorded by definition.
    ///
    /// The asymmetry decides it: failing to reclaim a file costs disk space, while
    /// reclaiming one the user asked for destroys something they chose to keep.
    /// When the two cannot be told apart, the safe direction is to keep.
    ///
    /// Files downloaded from now on carry an explicit origin, so this default only
    /// applies to the pre-existing backlog.
    var qqMusicOrigin: QQMusicDownloadOrigin? {
        guard qqMusicSongMid?.isEmpty == false else { return nil }
        guard let raw = qqMusicDownloadOrigin,
              let origin = QQMusicDownloadOrigin(rawValue: raw)
        else { return .userRequested }
        return origin
    }

    /// Whether this file counts against the automatic-download cache budget.
    var countsAsDownloadCache: Bool {
        qqMusicOrigin == .prefetch
    }
}
