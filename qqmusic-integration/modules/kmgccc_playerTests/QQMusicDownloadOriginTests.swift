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
        Track(
            title: "t",
            fileBookmarkData: Data("b".utf8),
            qqMusicSongMid: "001abc",
            qqMusicDownloadOrigin: origin,
            qqMusicDownloadedAt: origin == nil ? nil : Date(timeIntervalSince1970: 1_700_000_000)
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
        let sidecar = TrackSidecar(
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
        let decoded = try JSONDecoder().decode(TrackSidecar.self, from: data)

        XCTAssertEqual(decoded.qqMusicDownloadOrigin, QQMusicDownloadOrigin.userRequested.rawValue)
        XCTAssertEqual(decoded.qqMusicDownloadedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(decoded.schemaVersion, TrackSidecar.currentSchemaVersion)
    }

    /// A sidecar written before the fields existed must still decode, and the
    /// fields must come back nil rather than failing the whole load.
    func testOlderSidecarWithoutOriginStillDecodes() throws {
        let json = """
        {"schemaVersion":9,"id":"\(UUID().uuidString)","title":"old","artist":"a",
         "album":"b","genreTags":[],"duration":100,"addedAt":0,
         "qqMusicSongMid":"001abc"}
        """
        let decoded = try JSONDecoder().decode(TrackSidecar.self, from: Data(json.utf8))
        XCTAssertNil(decoded.qqMusicDownloadOrigin)
        XCTAssertNil(decoded.qqMusicDownloadedAt)
        XCTAssertEqual(decoded.qqMusicSongMid, "001abc")
    }
}
