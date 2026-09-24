//
//  QQMusicDownloadOriginPersistenceTests.swift
//  kmgccc_playerTests
//
//  The download provenance has to survive the whole storage round trip.
//
//  Written because it did not, in a way no other test could see: the sidecar
//  carried `qqMusicDownloadOrigin` correctly on disk (the writer builds it from
//  the live track), the scanner read it back correctly, and then the repository's
//  `ScannedTrackMeta` → `Track` conversion dropped the two fields. Every loaded
//  track therefore had no recorded origin, `countsAsDownloadCache` read that as
//  "the user's own", and the song-cache figure stayed at 0 bytes however many
//  automatic downloads were on disk.
//
//  So this test goes through the real path — a sidecar on disk, scanned, built
//  into a `Track`, and finally measured the way the settings window measures it —
//  rather than constructing a `Track` directly, which is precisely the shortcut
//  that hid the bug.
//

import Foundation
import XCTest
@testable import kmgccc_player

@MainActor
final class QQMusicDownloadOriginPersistenceTests: XCTestCase {

    private var root: URL!
    private var paths: kmgccc_player.LibraryPaths!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = kmgccc_player.LibraryPaths(rootURL: root)
        try paths.createRequiredDirectories()
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    /// An automatic download, committed the way the app commits one.
    ///
    /// Uses the repository's *real* sidecar writers (passing none) so the track
    /// reaches disk exactly as production writes it — hand-writing the JSON would
    /// be testing my transcription of the format instead of the format.
    private func commitTrack(
        id: UUID = UUID(),
        bytes: Int = 1_000_000,
        origin: String? = "prefetch",
        downloadedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) async throws -> UUID {
        let relative = "Tracks/\(id.uuidString)/audio.flac"
        let audioURL = paths.rootURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: audioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: bytes).write(to: audioURL)

        let track = Track(
            id: id,
            title: "自动下载的歌",
            qqMusicSongMid: "001abc",
            qqMusicDownloadOrigin: origin,
            qqMusicDownloadedAt: downloadedAt,
            duration: 200,
            fileBookmarkData: Data(),
            mediaLocator: .managed(libraryRelativePath: relative),
            libraryRootSnapshot: paths.rootURL.path
        )

        let libraryService = LocalLibraryService(
            paths: paths,
            preferenceStatsService: PreferenceStatsService()
        )
        // No injected writers: the repository's own write the sidecar to disk.
        let repository = SwiftDataLibraryRepository(libraryService: libraryService)
        _ = await repository.commitImportedTracks([track])
        return id
    }

    private func makeRepository() -> SwiftDataLibraryRepository {
        let libraryService = LocalLibraryService(
            paths: paths,
            preferenceStatsService: PreferenceStatsService()
        )
        return SwiftDataLibraryRepository(libraryService: libraryService)
    }

    /// Read the library back off disk, through the scanner and the repository's
    /// `ScannedTrackMeta` → `Track` conversion.
    private func loadTracks() async throws -> [Track] {
        let repository = makeRepository()
        await repository.reloadFromLibrary()
        return await repository.fetchTracks(in: nil)
    }

    // MARK: - The round trip

    func testOriginSurvivesBeingLoadedFromDisk() async throws {
        _ = try await commitTrack()

        let loaded = try await loadTracks()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(
            loaded.first?.qqMusicDownloadOrigin,
            "prefetch",
            "the origin was read by the scanner but dropped when the Track was built"
        )
        XCTAssertNotNil(loaded.first?.qqMusicDownloadedAt)
        XCTAssertEqual(
            loaded.first?.countsAsDownloadCache,
            true,
            "a loaded automatic download must still be classified as cache"
        )
    }

    /// And the figure the settings window shows must therefore be non-zero.
    ///
    /// This is the user-visible symptom: "the cache is always 0 no matter how much
    /// has been auto-downloaded".
    func testLoadedAutomaticDownloadCountsTowardsTheCacheFigure() async throws {
        _ = try await commitTrack(bytes: 2_000_000)

        let loaded = try await loadTracks()
        let (bytes, cached) = QQMusicCacheBudget.shared.songCacheUsage(
            tracks: loaded,
            libraryRoot: paths.rootURL
        )

        XCTAssertEqual(cached.count, 1)
        XCTAssertEqual(bytes, 2_000_000, "the cache figure must not be 0 for a loaded download")
    }

    /// A user's own download is loaded as such, and stays out of the cache.
    func testUserRequestedOriginSurvivesAndStaysOutOfTheCache() async throws {
        _ = try await commitTrack(origin: "userRequested")

        let loaded = try await loadTracks()
        let (bytes, cached) = QQMusicCacheBudget.shared.songCacheUsage(
            tracks: loaded,
            libraryRoot: paths.rootURL
        )

        XCTAssertEqual(loaded.first?.qqMusicDownloadOrigin, "userRequested")
        XCTAssertTrue(cached.isEmpty, "a manual download is library content, not cache")
        XCTAssertEqual(bytes, 0)
    }

    /// A sidecar predating the field still loads, as the user's own.
    func testSidecarWithoutOriginLoadsAsUserOwned() async throws {
        _ = try await commitTrack(origin: nil, downloadedAt: nil)

        let loaded = try await loadTracks()

        XCTAssertNil(loaded.first?.qqMusicDownloadOrigin)
        XCTAssertEqual(
            loaded.first?.qqMusicOrigin,
            .userRequested,
            "an unrecorded download must default to the safe classification, not to cache"
        )
    }
}
