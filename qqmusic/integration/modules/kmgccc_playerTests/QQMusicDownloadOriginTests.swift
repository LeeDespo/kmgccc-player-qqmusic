import Foundation
@testable import kmgccc_player
import XCTest

/// The download-origin fields decide whether a file counts against the
/// automatic-download cache, so they have to survive a real round trip through
/// the sidecar — a field that silently fails to encode would make every track
/// look prefetched again after a restart, and the user's own downloads would
/// become eviction candidates.
@MainActor
final class QQMusicDownloadOriginTests: XCTestCase {

    private func makeTrack(origin: String?) -> Track {
        // Argument order follows `Track.init`: the QQ provenance fields come
        // before the file fields.
        Track(
            title: "t",
            qqMusicSongMid: "001abc",
            qqMusicDownloadOrigin: origin,
            qqMusicDownloadedAt: origin == nil ? nil : Date(timeIntervalSince1970: 1_700_000_000),
            fileBookmarkData: Data("b".utf8)
        )
    }

    // MARK: - Model semantics

    func testOriginDefaultsToUserRequestedWhenUnrecorded() {
        // Unrecorded files are the pre-existing backlog. Treating them as cache
        // deleted the user's own downloads, so the default is now the safe one.
        let track = makeTrack(origin: nil)
        XCTAssertEqual(track.qqMusicOrigin, .userRequested)
        XCTAssertFalse(track.countsAsDownloadCache)
    }

    func testUserRequestedIsNotCache() {
        let track = makeTrack(origin: QQMusicDownloadOrigin.userRequested.rawValue)
        XCTAssertEqual(track.qqMusicOrigin, .userRequested)
        XCTAssertFalse(track.countsAsDownloadCache)
    }

    func testPrefetchCountsAsCache() {
        let track = makeTrack(origin: QQMusicDownloadOrigin.prefetch.rawValue)
        XCTAssertTrue(track.countsAsDownloadCache)
    }

    /// A library track has no song mid, so it is not part of the online cache at
    /// all and must never be evicted by it.
    func testLocalTrackIsNotPartOfTheDownloadCache() {
        let local = Track(title: "local", fileBookmarkData: Data("b".utf8))
        XCTAssertNil(local.qqMusicOrigin)
        XCTAssertFalse(local.countsAsDownloadCache)
    }

    // MARK: - Sidecar round trip

    /// The origin and timestamp must survive being written and read back.
    func testOriginSurvivesSidecarRoundTrip() throws {
        let sidecar = kmgccc_player.TrackSidecar(
            id: UUID(),
            title: "song",
            artist: "artist",
            artistCredits: nil,
            album: "album",
            albumArtist: nil,
            description: nil,
            genreTags: [],
            language: nil,
            labelOrCompany: nil,
            releaseDate: nil,
            qqMusicSongMid: "001abc",
            qqMusicDownloadOrigin: QQMusicDownloadOrigin.userRequested.rawValue,
            qqMusicDownloadedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadataSource: nil,
            metadataFetchedAt: nil,
            metadataConfidence: nil,
            musicBrainzReleaseID: nil,
            duration: 200,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            importedAt: nil,
            lyricsTimeOffsetMs: nil,
            originalFilePath: nil,
            audioFileName: "audio.m4a",
            artworkFileName: nil,
            lyricsFileName: nil,
            lyricsType: nil,
            ttmlLyricsFileName: nil,
            ncmSourcePath: nil,
            ncmSourceIdentity: nil,
            ncmConversionAssociation: nil,
            playCount: nil,
            preferenceStats: nil,
            mediaLocator: .managed(libraryRelativePath: "Tracks/x/audio.m4a"),
            availability: .available,
            embeddedMetadataSnapshot: nil,
            userMetadataOverride: nil,
            enrichmentSuggestions: nil,
            importProvenance: nil,
            audioProperties: nil
        )
        let data = try JSONEncoder().encode(sidecar)
        let decoded = try JSONDecoder().decode(kmgccc_player.TrackSidecar.self, from: data)

        XCTAssertEqual(decoded.qqMusicDownloadOrigin, QQMusicDownloadOrigin.userRequested.rawValue)
        XCTAssertEqual(decoded.qqMusicDownloadedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(decoded.schemaVersion, kmgccc_player.TrackSidecar.currentSchemaVersion)
    }

    /// A sidecar written before the fields existed must still decode, and the
    /// fields must come back nil rather than failing the whole load.
    /// A sidecar written before the origin field existed.
    ///
    /// This is the case that matters most: those files are the user's *own*
    /// downloads from before provenance was recorded, so they must decode and
    /// must not be classified as reclaimable cache.
    func testOlderSidecarWithoutOriginStillDecodes() throws {
        // Schema 9 still requires the locator payload, which schema 7
        // introduced; a real sidecar of that age carries one.
        let json = """
        {"schemaVersion":9,"id":"\(UUID().uuidString)","title":"old","artist":"a",
         "album":"b","genreTags":[],"duration":100,"addedAt":0,
         "qqMusicSongMid":"001abc",
         "mediaLocator":{"kind":"managed","managed":{"libraryRelativePath":"Tracks/a/audio.flac"}}}
        """
        let decoded = try JSONDecoder().decode(kmgccc_player.TrackSidecar.self, from: Data(json.utf8))
        XCTAssertNil(decoded.qqMusicDownloadOrigin)
        XCTAssertNil(decoded.qqMusicDownloadedAt)
        XCTAssertEqual(decoded.qqMusicSongMid, "001abc")
    }

    // MARK: - The label rule

    /// Recording a label over an existing one.
    ///
    /// This is the whole of "automatic and manual are separate" and "an automatic
    /// download can be converted without fetching it again", so it is asserted
    /// case by case rather than left to the coordinator's internals.
    func testLabelRule() {
        // Nothing recorded: either label may be recorded.
        XCTAssertTrue(QQMusicDownloadOrigin.shouldReplace(existing: nil, with: .prefetch))
        XCTAssertTrue(QQMusicDownloadOrigin.shouldReplace(existing: nil, with: .userRequested))

        // The conversion the user asked for: choosing an automatic download
        // promotes it. No second download is involved — only this label changes.
        XCTAssertTrue(
            QQMusicDownloadOrigin.shouldReplace(existing: "prefetch", with: .userRequested),
            "an automatic download must be convertible to the user's own"
        )

        // Recorded once, kept: a later prefetch must never demote a track the
        // user owns. Deletion is decided from this label, so a demotion here
        // would put their own music back in the reclaimable pool.
        XCTAssertFalse(
            QQMusicDownloadOrigin.shouldReplace(existing: "userRequested", with: .prefetch),
            "prefetching must never take ownership away"
        )
        XCTAssertFalse(QQMusicDownloadOrigin.shouldReplace(existing: "prefetch", with: .prefetch))
        XCTAssertFalse(
            QQMusicDownloadOrigin.shouldReplace(existing: "userRequested", with: .userRequested)
        )
    }

    /// Playback-driven downloads are the automatic kind; only the download
    /// actions are the user's own.
    ///
    /// Pinned because it was the inverse in practice: the track playback started
    /// on was recorded as the user's own, so every listening session looked like
    /// deliberate downloads — the cache read as empty and nothing was reclaimable.
    func testPlaybackDownloadsAreAutomatic() {
        XCTAssertEqual(QQMusicDownloadOrigin.prefetch.displayName, "自动下载")
        XCTAssertEqual(QQMusicDownloadOrigin.userRequested.displayName, "手动下载")

        let prefetched = makeTrack(origin: QQMusicDownloadOrigin.prefetch.rawValue)
        XCTAssertTrue(prefetched.countsAsDownloadCache, "playback-downloaded audio is cache")

        let chosen = makeTrack(origin: QQMusicDownloadOrigin.userRequested.rawValue)
        XCTAssertFalse(chosen.countsAsDownloadCache, "a download the user asked for is not cache")
    }

    /// A download needs a managed library, which is a separate question from
    /// "does this page offer a selection".
    ///
    /// The batch control combines the two: the page-kind check keeps the button
    /// steady across navigation (see `QQMusicBrowseEnvironmentTests`), while this
    /// one is about whether a download can land at all — an in-place library
    /// cannot host a downloaded file. This used to be announced by a banner; the
    /// banner is gone, so the control's own availability is the whole answer.
    func testDownloadsRequireAManagedLibrary() {
        let coordinator = QQMusicOnlineCoordinator()
        XCTAssertFalse(coordinator.canDownload, "no library session at all")
        XCTAssertTrue(coordinator.offersBatchDownload(.likedSongs), "the page kind still qualifies")
    }
}
