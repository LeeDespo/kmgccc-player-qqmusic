//
//  QQMusicCacheBudget.swift
//  kmgccc_player
//
//  Enforces the two QQ Music cache limits.
//
//  The distinction that matters here: audio the *user* asked for is their
//  library, not a cache, and is never reclaimed. Only audio the app fetched on
//  its own to keep playback ahead counts against the song budget. A track makes
//  the transition from one to the other the moment the user plays or downloads
//  it deliberately — without being downloaded a second time (see
//  `QQMusicDownloadOrigin`).
//
//  Reclaiming targets a percentage of the limit rather than the limit itself:
//  trimming only to the edge would evict again on the next download, so the
//  cache would churn continuously instead of occasionally.
//

import Foundation

/// Byte conversion for the GB values the settings window uses.
///
/// Decimal (1 GB = 10^9), matching how Finder and the storage pane report sizes.
/// Using 2^30 here while the UI says "GB" would make the displayed usage
/// disagree with the configured limit by 7%, which reads as a bug.
nonisolated enum QQMusicBytes {
    static let perGigabyte: Double = 1_000_000_000

    static func gigabytes(_ bytes: Int64) -> Double {
        Double(bytes) / perGigabyte
    }

    static func bytes(_ gigabytes: Double) -> Int64 {
        Int64((max(0, gigabytes) * perGigabyte).rounded())
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@MainActor
final class QQMusicCacheBudget {

    static let shared = QQMusicCacheBudget()

    private init() {}

    /// What a reclamation pass did, for reporting back to the settings window.
    struct Outcome: Sendable, Equatable {
        var reclaimedBytes: Int64 = 0
        var removedTrackCount: Int = 0
        /// True when everything reclaimable was removed and the total still
        /// exceeds the limit. Reported rather than silently deleting the user's
        /// own downloads to reach the target.
        var stillOverLimit = false
    }

    // MARK: - Song budget

    /// Total bytes of automatic-downloaded audio, and the tracks that hold them.
    ///
    /// Sizes come from the files themselves, so the figure matches what the disk
    /// actually holds. A track whose file cannot be measured contributes 0
    /// rather than failing the pass.
    ///
    /// `libraryRoot` is passed in rather than taken from each track: a track
    /// carries the root it was imported under, and that snapshot can be empty or
    /// stale (a relocated library keeps the old path). Resolving through it then
    /// fails for every track, so the *cache* figure read as 0 bytes no matter how
    /// much had been downloaded. The session's own root is the live one.
    func songCacheUsage(
        tracks: [Track],
        libraryRoot: URL? = nil
    ) -> (bytes: Int64, cached: [Track]) {
        let cached = tracks.filter { $0.countsAsDownloadCache }
        var total: Int64 = 0
        for track in cached {
            total += fileSize(of: track, libraryRoot: libraryRoot)
        }
        return (total, cached)
    }

    /// Remove automatic-downloaded audio until usage falls to the reclaim
    /// target.
    ///
    /// Oldest first, by the recorded download time — that is what makes the
    /// rule "reclaim what was fetched longest ago" rather than an arbitrary
    /// choice. Tracks currently playing or queued are skipped, since deleting
    /// the file under playback would break it.
    @discardableResult
    func reclaimSongsIfNeeded(
        tracks: [Track],
        playingAndQueued: Set<UUID>,
        libraryRoot: URL? = nil,
        delete: ([Track]) async -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        let settings = AppSettings.shared
        guard settings.qqMusicSongCacheLimitEnabled else { return outcome }

        let limit = QQMusicBytes.bytes(settings.qqMusicSongCacheLimitGB)
        guard limit > 0 else { return outcome }

        let (usage, cached) = songCacheUsage(tracks: tracks, libraryRoot: libraryRoot)
        guard usage > limit else { return outcome }

        let keepPercent = min(max(settings.qqMusicSongCacheReclaimPercent, 0), 90)
        let target = Int64(Double(limit) * Double(keepPercent) / 100)
        let needToFree = usage - target

        let candidates = cached
            .filter { !playingAndQueued.contains($0.id) }
            // Oldest download first. Tracks without a recorded time sort first,
            // so unclassified files are reclaimed before ones we know are recent.
            .sorted { ($0.qqMusicDownloadedAt ?? .distantPast) < ($1.qqMusicDownloadedAt ?? .distantPast) }

        var toDelete: [Track] = []
        var freed: Int64 = 0
        for track in candidates {
            guard freed < needToFree else { break }
            toDelete.append(track)
            freed += fileSize(of: track, libraryRoot: libraryRoot)
        }

        if !toDelete.isEmpty {
            // Deletion goes through the library so its index and the disk stay
            // in step; removing the file directly would leave a dangling track.
            await delete(toDelete)
            outcome.reclaimedBytes = freed
            outcome.removedTrackCount = toDelete.count
        }

        // Everything reclaimable is gone but the limit is still exceeded: that
        // is the user's own downloads filling the space, and they are not ours
        // to delete.
        outcome.stillOverLimit = usage - freed > limit
        return outcome
    }

    // MARK: - Other (catalogue + artwork) budget

    /// Trim the catalogue and artwork cache to the reclaim target.
    @discardableResult
    func reclaimOtherIfNeeded(store: QQMusicCacheStore?) async -> Outcome {
        var outcome = Outcome()
        let settings = AppSettings.shared
        guard settings.qqMusicOtherCacheLimitEnabled, let store else { return outcome }

        let limit = QQMusicBytes.bytes(settings.qqMusicOtherCacheLimitGB)
        guard limit > 0 else { return outcome }

        let usage = await store.nonAudioUsageBytes()
        guard usage > limit else { return outcome }

        let keepPercent = min(max(settings.qqMusicOtherCacheReclaimPercent, 0), 90)
        let target = Int64(Double(limit) * Double(keepPercent) / 100)

        let freed = await store.reclaimNonAudio(bytes: usage - target)
        outcome.reclaimedBytes = freed
        outcome.stillOverLimit = usage - freed > limit
        return outcome
    }

    // MARK: - Helpers

    /// On-disk size of a track's audio, or 0 when it cannot be resolved.
    ///
    /// A managed track is resolved against the library root it was handed, which
    /// is the live one for this session. `resolveFileURL()` is kept as the
    /// fallback because a referenced track's file lives outside the library and
    /// only its own locator can find it.
    private func fileSize(of track: Track, libraryRoot: URL?) -> Int64 {
        if let relative = track.mediaLocator.managedLibraryRelativePath,
           let root = libraryRoot {
            let candidate = root.appendingPathComponent(relative).standardizedFileURL
            if let size = sizeOnDisk(of: candidate) { return size }
        }
        guard let url = track.resolveFileURL().url else { return 0 }
        return sizeOnDisk(of: url) ?? 0
    }

    private func sizeOnDisk(of url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize, size > 0 else { return nil }
        return Int64(size)
    }
}
