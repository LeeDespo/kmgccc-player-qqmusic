import Foundation
@testable import kmgccc_player
import XCTest

/// The online source owns the playing order and hands the engine one track at a
/// time. The engine must therefore advance *linearly* — it must not shuffle the
/// same tracks a second time, which is what made shuffle appear to only cover
/// the already-downloaded tracks.
@MainActor
final class ExternalPlaybackOrderTests: XCTestCase {

    private func harness() throws -> (SmartPlaybackController, AVAudioPlaybackService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = kmgccc_player.LibraryPaths(rootURL: root)
        let stats = PreferenceStatsService()
        let controller = SmartPlaybackController(
            playbackHistoryStore: .inMemory(),
            preferenceStatsService: stats,
            libraryService: LocalLibraryService(paths: paths, preferenceStatsService: stats)
        )
        let service = AVAudioPlaybackService(smartController: controller, libraryPaths: paths)
        return (controller, service, root)
    }

    private func track(_ name: String, _ root: URL) -> Track {
        Track(
            title: name,
            fileBookmarkData: Data("b".utf8),
            mediaLocator: .referenced(kmgccc_player.ReferencedFileLocator(
                fileBookmarkData: Data("b".utf8),
                lastKnownPath: root.appendingPathComponent("\(name).mp3").path
            )),
            libraryRootSnapshot: root.path
        )
    }

    /// `externalOrder` means the engine plays the caller's sequence in order.
    func testExternalOrderDisablesEngineShuffle() throws {
        let (controller, service, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        let tracks = (1...4).map { track("t\($0)", root) }
        service.playTracks([tracks[0]], startingAt: 0, startPolicy: .externalOrder)

        XCTAssertFalse(
            controller.isShuffleEnabled,
            "the engine must not shuffle a sequence an external driver owns"
        )
    }

    /// Even though the engine runs sequentially, the UI must keep reporting the
    /// mode the user picked — otherwise the mode button contradicts itself.
    func testExternalOrderKeepsReportingUserMode() throws {
        let (controller, service, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        let tracks = (1...4).map { track("t\($0)", root) }
        AppSettings.shared.playbackOrderMode = .shuffle
        service.playTracks([tracks[0]], startingAt: 0, startPolicy: .externalOrder)

        XCTAssertFalse(controller.isShuffleEnabled, "engine advances linearly")
        XCTAssertEqual(
            service.currentPlaybackOrderMode, .shuffle,
            "the UI must still show the user's chosen mode"
        )
    }

    /// A brief nil `currentTrack` is not a reason for the engine to change
    /// behaviour or for the caller to consider the session over.
    func testExternalOrderIsClearedByNormalLocalPlayback() throws {
        let (controller, service, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        let tracks = (1...3).map { track("t\($0)", root) }
        AppSettings.shared.playbackOrderMode = .shuffle

        service.playTracks([tracks[0]], startingAt: 0, startPolicy: .externalOrder)
        // Playing from a local page again hands the queue back to the app's own
        // logic, which means the engine's shuffle applies once more.
        service.playTracks(tracks, startingAt: 0, startPolicy: .useSavedMode)

        XCTAssertTrue(
            controller.isShuffleEnabled,
            "local playback must restore the app's own shuffle behaviour"
        )
    }

    /// Toggling the mode during an externally-ordered session is a preference
    /// for the driver to apply; it must not switch the engine's shuffle on.
    func testTogglingModeDuringExternalOrderDoesNotShuffleEngine() throws {
        let (controller, service, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        let tracks = (1...3).map { track("t\($0)", root) }
        service.playTracks([tracks[0]], startingAt: 0, startPolicy: .externalOrder)

        service.setShuffleEnabled(true)

        XCTAssertFalse(
            controller.isShuffleEnabled,
            "the external driver owns the order; the engine must stay linear"
        )
        XCTAssertTrue(AppSettings.shared.shuffleEnabled, "the user's preference is still recorded")
    }
}
