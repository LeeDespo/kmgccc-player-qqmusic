import Foundation
@testable import kmgccc_player
import XCTest

/// The reclamation rules. A bug here deletes files the user asked for, so the
/// boundary between "cache" and "library" is tested explicitly.
@MainActor
final class QQMusicCacheBudgetTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    /// A track whose audio file is really on disk, so sizes are measured rather
    /// than assumed.
    private func makeTrack(
        _ name: String,
        megabytes: Int,
        origin: QQMusicDownloadOrigin?,
        downloadedAt: Date? = nil
    ) throws -> Track {
        let relative = "Tracks/\(UUID().uuidString)/\(name).bin"
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: megabytes * 1_000_000).write(to: url)
        return Track(
            title: name,
            duration: 100,
            fileBookmarkData: Data(),
            mediaLocator: .managed(libraryRelativePath: relative),
            libraryRootSnapshot: root.path,
            qqMusicSongMid: name,
            qqMusicDownloadOrigin: origin?.rawValue,
            qqMusicDownloadedAt: downloadedAt
        )
    }

    private func enableSongLimit(gb: Double, reclaimPercent: Int) {
        let settings = AppSettings.shared
        settings.qqMusicSongCacheLimitEnabled = true
        settings.qqMusicSongCacheLimitGB = gb
        settings.qqMusicSongCacheReclaimPercent = reclaimPercent
    }

    private func disableLimits() {
        let settings = AppSettings.shared
        settings.qqMusicSongCacheLimitEnabled = false
        settings.qqMusicOtherCacheLimitEnabled = false
    }

    // MARK: - Usage accounting

    /// Only automatic downloads count. The user's own downloads must be excluded
    /// from the measured total, not merely spared from deletion.
    func testUsageCountsOnlyAutomaticDownloads() throws {
        defer { disableLimits() }
        let prefetched = try makeTrack("a", megabytes: 3, origin: .prefetch)
        let requested = try makeTrack("b", megabytes: 5, origin: .userRequested)
        let local = Track(title: "local", fileBookmarkData: Data("x".utf8))

        let (bytes, cached) = QQMusicCacheBudget.shared.songCacheUsage(
            tracks: [prefetched, requested, local]
        )
        XCTAssertEqual(bytes, 3_000_000)
        XCTAssertEqual(cached.map(\.title), ["a"])
    }

    /// Tracks with no recorded origin are treated as the user's own, so they are
    /// never reclaimed. This is the regression that deleted real downloads: every
    /// track fetched before the field existed is unrecorded, and the first version
    /// classified exactly those as evictable.
    func testUnclassifiedDownloadsAreTreatedAsUserOwned() throws {
        defer { disableLimits() }
        let unknown = try makeTrack("old", megabytes: 2, origin: nil)
        let (bytes, cached) = QQMusicCacheBudget.shared.songCacheUsage(tracks: [unknown])
        XCTAssertEqual(bytes, 0, "unrecorded downloads must not count as cache")
        XCTAssertTrue(cached.isEmpty, "and must never be offered for reclamation")
    }

    /// The specific shape of the reported bug: a folder of pre-existing downloads
    /// plus one genuine prefetch. Only the prefetch may be evicted.
    func testOnlyExplicitPrefetchIsEverEvicted() async throws {
        defer { disableLimits() }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let legacyA = try makeTrack("legacy-a", megabytes: 4, origin: nil, downloadedAt: base)
        let legacyB = try makeTrack("legacy-b", megabytes: 4, origin: nil, downloadedAt: base)
        let prefetched = try makeTrack("prefetched", megabytes: 4, origin: .prefetch, downloadedAt: base)

        // Limit far below the total, reclaim to zero: everything reclaimable
        // must go, and nothing else may.
        enableSongLimit(gb: 0.001, reclaimPercent: 0)

        var deleted: [Track] = []
        let outcome = await QQMusicCacheBudget.shared.reclaimSongsIfNeeded(
            tracks: [legacyA, legacyB, prefetched],
            playingAndQueued: [],
            delete: { deleted.append(contentsOf: $0) }
        )

        XCTAssertEqual(deleted.map(\.title), ["prefetched"])
        XCTAssertTrue(outcome.stillOverLimit, "the rest is user content, which is reported not deleted")
    }

    // MARK: - Reclamation

    /// Exceeding the limit evicts the oldest automatic downloads first, and
    /// never the user's own.
    func testReclaimEvictsOldestAutomaticDownloadsOnly() async throws {
        defer { disableLimits() }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let oldest = try makeTrack("oldest", megabytes: 3, origin: .prefetch, downloadedAt: base)
        let middle = try makeTrack("middle", megabytes: 3, origin: .prefetch, downloadedAt: base.addingTimeInterval(60))
        let newest = try makeTrack("newest", megabytes: 3, origin: .prefetch, downloadedAt: base.addingTimeInterval(120))
        let mine = try makeTrack("mine", megabytes: 3, origin: .userRequested, downloadedAt: base)

        // 9 MB of cache, limit 4 MB, reclaim to 50% => target 2 MB => free >= 7 MB.
        enableSongLimit(gb: 0.004, reclaimPercent: 50)

        var deleted: [Track] = []
        let outcome = await QQMusicCacheBudget.shared.reclaimSongsIfNeeded(
            tracks: [oldest, middle, newest, mine],
            playingAndQueued: [],
            delete: { deleted.append(contentsOf: $0) }
        )

        XCTAssertEqual(deleted.map(\.title), ["oldest", "middle", "newest"], "oldest first")
        XCTAssertFalse(deleted.contains { $0.title == "mine" }, "user downloads are never evicted")
        XCTAssertEqual(outcome.removedTrackCount, 3)
        XCTAssertGreaterThan(outcome.reclaimedBytes, 0)
    }

    /// Nothing happens when the limit is disabled, when usage is under it, or
    /// when the only content is the user's own.
    func testReclaimIsANoOpWhenNotNeeded() async throws {
        defer { disableLimits() }
        let small = try makeTrack("small", megabytes: 1, origin: .prefetch)
        let mine = try makeTrack("mine", megabytes: 10, origin: .userRequested)

        // Disabled.
        var deleted: [Track] = []
        _ = await QQMusicCacheBudget.shared.reclaimSongsIfNeeded(
            tracks: [small, mine], playingAndQueued: [], delete: { deleted.append(contentsOf: $0) }
        )
        XCTAssertTrue(deleted.isEmpty, "no limit configured means nothing is reclaimed")

        // Enabled but under the limit.
        enableSongLimit(gb: 1, reclaimPercent: 70)
        _ = await QQMusicCacheBudget.shared.reclaimSongsIfNeeded(
            tracks: [small, mine], playingAndQueued: [], delete: { deleted.append(contentsOf: $0) }
        )
        XCTAssertTrue(deleted.isEmpty, "under the limit means nothing is reclaimed")

        // Over the limit, but only the user's own downloads are large.
        enableSongLimit(gb: 0.0005, reclaimPercent: 70)
        _ = await QQMusicCacheBudget.shared.reclaimSongsIfNeeded(
            tracks: [small, mine], playingAndQueued: [], delete: { deleted.append(contentsOf: $0) }
        )
        XCTAssertEqual(deleted.map(\.title), ["small"])
    }

    /// What is playing, or queued behind it, is never deleted — the file would
    /// vanish under the audio engine.
    func testPlayingAndQueuedTracksAreSkipped() async throws {
        defer { disableLimits() }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let playing = try makeTrack("playing", megabytes: 3, origin: .prefetch, downloadedAt: base)
        let queued = try makeTrack("queued", megabytes: 3, origin: .prefetch, downloadedAt: base.addingTimeInterval(1))
        let idle = try makeTrack("idle", megabytes: 3, origin: .prefetch, downloadedAt: base.addingTimeInterval(2))

        enableSongLimit(gb: 0.004, reclaimPercent: 0)

        var deleted: [Track] = []
        _ = await QQMusicCacheBudget.shared.reclaimSongsIfNeeded(
            tracks: [playing, queued, idle],
            playingAndQueued: [playing.id, queued.id],
            delete: { deleted.append(contentsOf: $0) }
        )

        XCTAssertEqual(deleted.map(\.title), ["idle"], "only the idle track may go")
    }

    /// When everything reclaimable is gone and the total still exceeds the
    /// limit, that is reported rather than reaching for the user's library.
    func testStillOverLimitIsReportedNotForced() async throws {
        defer { disableLimits() }
        let cache = try makeTrack("cache", megabytes: 1, origin: .prefetch)
        let mine = try makeTrack("mine", megabytes: 20, origin: .userRequested)

        enableSongLimit(gb: 0.005, reclaimPercent: 0)

        var deleted: [Track] = []
        let outcome = await QQMusicCacheBudget.shared.reclaimSongsIfNeeded(
            tracks: [cache, mine],
            playingAndQueued: [],
            delete: { deleted.append(contentsOf: $0) }
        )

        XCTAssertEqual(deleted.map(\.title), ["cache"])
        XCTAssertTrue(outcome.stillOverLimit, "the user's own content is the reason, and is not deleted")
    }

    // MARK: - Unit conversion

    /// Decimal GB, matching how the settings window and Finder report sizes.
    func testGigabyteConversionIsDecimal() {
        XCTAssertEqual(QQMusicBytes.bytes(1), 1_000_000_000)
        XCTAssertEqual(QQMusicBytes.bytes(0.5), 500_000_000)
        XCTAssertEqual(QQMusicBytes.gigabytes(1_000_000_000), 1.0, accuracy: 1e-9)
        XCTAssertEqual(QQMusicBytes.bytes(-5), 0, "a negative limit is meaningless and clamps to zero")
    }
}
