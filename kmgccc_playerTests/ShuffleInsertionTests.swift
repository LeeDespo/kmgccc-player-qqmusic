import Foundation
@testable import kmgccc_player
import XCTest

/// Reproduces the reported "shuffle cannot advance" failure.
///
/// The online source starts playback with a single track and then feeds the
/// rest of its own shuffled order through `insertTracksAfterCurrent`. This test
/// reproduces that shape against the real controller — no mocks of the queue
/// logic — because reading the code was not enough to catch the bug the first
/// time.
@MainActor
final class ShuffleInsertionTests: XCTestCase {

    private func makeHarness() throws -> (SmartPlaybackController, LocalLibraryService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = LibraryPaths(rootURL: root)
        let preferenceStatsService = PreferenceStatsService()
        let libraryService = LocalLibraryService(
            paths: paths,
            preferenceStatsService: preferenceStatsService
        )
        let controller = SmartPlaybackController(
            playbackHistoryStore: .inMemory(),
            preferenceStatsService: preferenceStatsService,
            libraryService: libraryService
        )
        return (controller, libraryService, root)
    }

    private func makeTrack(_ title: String, root: URL) -> Track {
        Track(
            title: title,
            fileBookmarkData: Data("bookmark".utf8),
            mediaLocator: .referenced(ReferencedFileLocator(
                fileBookmarkData: Data("bookmark".utf8),
                lastKnownPath: root.appendingPathComponent("\(title).mp3").path
            )),
            libraryRootSnapshot: root.path
        )
    }

    /// The exact online shape: start with one track, then insert the rest one at
    /// a time, then check the queue can actually advance.
    func testInsertingAfterCurrentTrackKeepsQueueAdvancing() throws {
        let (controller, _, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        let seed = makeTrack("seed", root: root)
        let upcoming = (1...5).map { makeTrack("t\($0)", root: root) }

        // Online session: shuffle on, queue seeded with the tapped track only.
        controller.startPlayback(tracks: [seed], startingAt: 0, shuffle: true)
        XCTAssertEqual(controller.currentTrack?.id, seed.id, "seed should be current")

        // Prefetch: insert our order, one track per iteration.
        for track in upcoming {
            let inserted = controller.insertTracksAfterCurrent([track])
            XCTAssertGreaterThan(inserted, 0, "insert of \(track.title) was silently rejected")
        }

        // Walk the queue the way playback does and collect what comes out.
        var played = [controller.currentTrack?.title].compactMap { $0 }
        for _ in 0..<upcoming.count {
            controller.nextTrack()
            guard let title = controller.currentTrack?.title else { break }
            played.append(title)
        }

        XCTAssertEqual(
            played.count,
            upcoming.count + 1,
            "playback stopped early after \(played.count) of \(upcoming.count + 1) tracks: \(played)"
        )
        XCTAssertEqual(Set(played).count, played.count, "a track repeated: \(played)")
    }

    /// Sequential mode must behave the same way, since the coordinator drives
    /// both modes through the same insertion call.
    func testSequentialInsertionAlsoAdvances() throws {
        let (controller, _, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        let seed = makeTrack("seed", root: root)
        let upcoming = (1...3).map { makeTrack("t\($0)", root: root) }

        controller.startPlayback(tracks: [seed], startingAt: 0, shuffle: false)
        for track in upcoming {
            XCTAssertGreaterThan(controller.insertTracksAfterCurrent([track]), 0)
        }

        var played = [controller.currentTrack?.title].compactMap { $0 }
        for _ in 0..<upcoming.count {
            controller.nextTrack()
            guard let title = controller.currentTrack?.title else { break }
            played.append(title)
        }
        XCTAssertEqual(played.count, upcoming.count + 1, "sequential stopped early: \(played)")
    }

    /// The coordinator's loop treats a successful insert as "this track is
    /// queued". If the controller can reject an insert while reporting success,
    /// the loop would wait forever on a queue that never grew.
    func testInsertReturnValueMatchesQueueGrowth() throws {
        let (controller, _, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        let seed = makeTrack("seed", root: root)
        controller.startPlayback(tracks: [seed], startingAt: 0, shuffle: true)

        let before = controller.getUpcomingTracks(count: 100).count
        let inserted = controller.insertTracksAfterCurrent([makeTrack("a", root: root)])
        let after = controller.getUpcomingTracks(count: 100).count

        XCTAssertEqual(inserted, 1)
        XCTAssertEqual(after, before + 1, "reported inserting 1 but the queue did not grow")
    }

    /// Inserting a batch must preserve the order given, because the coordinator
    /// relies on that order being the shuffle result.
    func testBatchInsertPreservesGivenOrder() throws {
        let (controller, _, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        let seed = makeTrack("seed", root: root)
        controller.startPlayback(tracks: [seed], startingAt: 0, shuffle: true)

        let names = ["c", "a", "b"]
        let batch = names.map { makeTrack($0, root: root) }
        controller.insertTracksAfterCurrent(batch)

        let upcoming = controller.getUpcomingTracks(count: 10).map(\.title)
        XCTAssertEqual(
            Array(upcoming.prefix(3)),
            names,
            "batch order was not preserved; got \(upcoming)"
        )
    }
}

// MARK: - Coordinator loop shape

/// The coordinator only inserts `prefetchDepth` tracks ahead and then waits for
/// playback to consume them. These tests check what happens *after* the inserted
/// tracks have played, which is where the reported stall showed up.
@MainActor
final class ShufflePoolStarvationTests: XCTestCase {

    private func harness() throws -> (SmartPlaybackController, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = LibraryPaths(rootURL: root)
        let stats = PreferenceStatsService()
        let controller = SmartPlaybackController(
            playbackHistoryStore: .inMemory(),
            preferenceStatsService: stats,
            libraryService: LocalLibraryService(paths: paths, preferenceStatsService: stats)
        )
        return (controller, root)
    }

    private func track(_ name: String, _ root: URL) -> Track {
        Track(
            title: name,
            fileBookmarkData: Data("b".utf8),
            mediaLocator: .referenced(ReferencedFileLocator(
                fileBookmarkData: Data("b".utf8),
                lastKnownPath: root.appendingPathComponent("\(name).mp3").path
            )),
            libraryRootSnapshot: root.path
        )
    }

    /// Online sessions start with ONE track. The controller's shuffle session
    /// therefore has a one-element source pool, so anything it generates on its
    /// own can only ever be that same track. This checks what it reaches for
    /// once the explicitly inserted tracks are exhausted.
    func testShuffleSessionCannotGenerateBeyondTheSeedPool() throws {
        let (controller, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        let seed = track("seed", root: root)
        let inserted = ["a", "b"].map { track($0, root: root) }

        controller.startPlayback(tracks: [seed], startingAt: 0, shuffle: true)
        for t in inserted { controller.insertTracksAfterCurrent([t]) }

        var played = [controller.currentTrack?.title ?? "?"]
        for _ in 0..<6 {
            controller.nextTrack()
            played.append(controller.currentTrack?.title ?? "nil")
        }
        print("[starvation] sequence: \(played)")
        print("[starvation] distinct tracks: \(Set(played).count) of \(played.count)")

        // The pool should not cause a track to immediately repeat; if it does,
        // shuffle playback has degenerated into a short loop.
        for index in 1..<played.count where played[index] == played[index - 1] {
            XCTFail("track repeated back to back at \(index): \(played)")
        }
    }

    /// After `prefetchDepth` tracks are queued, the coordinator waits. Check
    /// that the controller reports a next track at that point — if it reports
    /// none, the coordinator would sleep forever on a queue that cannot advance.
    func testNextTrackExistsAfterInsertedTracksRunOut() throws {
        let (controller, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        let seed = track("seed", root: root)
        controller.startPlayback(tracks: [seed], startingAt: 0, shuffle: true)
        controller.insertTracksAfterCurrent([track("a", root: root)])

        controller.nextTrack()   // now on "a"
        XCTAssertEqual(controller.currentTrack?.title, "a")
        controller.nextTrack()   // past the inserted track
        print("[starvation] after exhausting inserts, current = \(controller.currentTrack?.title ?? "nil")")
        XCTAssertNotNil(controller.currentTrack, "playback stopped instead of advancing")
    }
}

// MARK: - Natural completion (the path the user actually hit)

/// The earlier tests called `nextTrack()` directly. Playback actually advances
/// through `autoAdvance()`, which is a *different* branch of the same decision
/// and stops (rather than wraps) when the shuffle session has nothing left.
///
/// The online session seeds the controller with a single track, so the shuffle
/// session's source pool holds one id. `WeightedRandomSampler.sample` filters
/// out the current track before choosing, which leaves that pool empty and makes
/// it return nil — so once the explicitly inserted tracks are consumed, the
/// session cannot generate anything and `autoAdvance` ends playback.
@MainActor
final class ShuffleAutoAdvanceTests: XCTestCase {

    private func harness() throws -> (SmartPlaybackController, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = LibraryPaths(rootURL: root)
        let stats = PreferenceStatsService()
        let controller = SmartPlaybackController(
            playbackHistoryStore: .inMemory(),
            preferenceStatsService: stats,
            libraryService: LocalLibraryService(paths: paths, preferenceStatsService: stats)
        )
        return (controller, root)
    }

    private func track(_ name: String, _ root: URL) -> Track {
        Track(
            title: name,
            fileBookmarkData: Data("b".utf8),
            mediaLocator: .referenced(ReferencedFileLocator(
                fileBookmarkData: Data("b".utf8),
                lastKnownPath: root.appendingPathComponent("\(name).mp3").path
            )),
            libraryRootSnapshot: root.path
        )
    }

    /// A one-track pool cannot generate a successor: this is the mechanism
    /// behind "playback stops after the preloaded tracks".
    func testOneTrackPoolCannotAutoAdvance() throws {
        let (controller, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        controller.startPlayback(tracks: [track("seed", root: root)], startingAt: 0, shuffle: true)

        // Nothing inserted: the pool holds only the seed, and the seed is the
        // current track, so sampling has no candidate left.
        let next = controller.autoAdvance()
        print("[autoadvance] next after seed with 1-track pool = \(next?.title ?? "nil")")
        XCTAssertNil(next, "expected the one-track pool to have nothing to advance to")
    }

    /// Feeding the pool is what makes auto-advance work. This is the behaviour
    /// the coordinator is supposed to provide.
    func testAutoAdvanceWorksAfterPoolIsFed() throws {
        let (controller, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        let seed = track("seed", root: root)
        controller.startPlayback(tracks: [seed], startingAt: 0, shuffle: true)
        controller.insertTracksAfterCurrent([track("a", root: root)])

        let first = controller.autoAdvance()
        XCTAssertEqual(first?.title, "a", "should advance to the inserted track")

        // Past the inserted one the pool is exhausted again — which is exactly
        // why the coordinator must keep feeding as playback progresses.
        let second = controller.autoAdvance()
        print("[autoadvance] after exhausting inserts = \(second?.title ?? "nil")")
    }
}

// MARK: - Sustained feeding

/// The online session starts with ONE track handed to the engine. The engine's
/// shuffle session therefore has a one-element source pool, and its sampler
/// excludes the current track before choosing — so it can never generate a
/// successor on its own. Everything past the seed depends on the coordinator
/// continuously inserting the next track of its order.
///
/// This test simulates that contract: keep refilling while a queue remains, and
/// assert playback reaches the end of the order without stalling.
@MainActor
final class ShuffleSustainedFeedingTests: XCTestCase {

    private func harness() throws -> (SmartPlaybackController, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = LibraryPaths(rootURL: root)
        let stats = PreferenceStatsService()
        let controller = SmartPlaybackController(
            playbackHistoryStore: .inMemory(),
            preferenceStatsService: stats,
            libraryService: LocalLibraryService(paths: paths, preferenceStatsService: stats)
        )
        return (controller, root)
    }

    private func track(_ name: String, _ root: URL) -> Track {
        Track(
            title: name,
            fileBookmarkData: Data("b".utf8),
            mediaLocator: .referenced(ReferencedFileLocator(
                fileBookmarkData: Data("b".utf8),
                lastKnownPath: root.appendingPathComponent("\(name).mp3").path
            )),
            libraryRootSnapshot: root.path
        )
    }

    /// Mirrors the coordinator: keep one track queued ahead, advancing the way
    /// natural completion does, through the whole shuffled order.
    func testContinuousFeedingReachesEndOfOrder() throws {
        let (controller, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        let order = ["seed", "a", "b", "c", "d"].map { track($0, root: root) }
        let depth = 1

        controller.startPlayback(tracks: [order[0]], startingAt: 0, shuffle: true)

        var delivered: [String] = [order[0].title]
        var nextToFeed = 1
        var guardCounter = 0

        // Feed, then advance — the same interleaving the coordinator and the
        // audio engine produce at runtime.
        while guardCounter < 40 {
            guardCounter += 1

            // How much is queued ahead, asked of the real queue.
            let queue = controller.currentQueueTracks
            guard let currentIndex = queue.firstIndex(where: { $0.id == controller.currentTrack?.id }) else {
                XCTFail("current track missing from the queue at \(delivered)")
                return
            }
            let ahead = queue.count - (currentIndex + 1)
            if ahead < depth, nextToFeed < order.count {
                controller.insertTracksAfterCurrent([order[nextToFeed]])
                nextToFeed += 1
                continue
            }
            if ahead < depth, nextToFeed >= order.count {
                break   // order fully delivered and consumed
            }

            let next = controller.autoAdvance()
            guard let next else {
                XCTFail("auto-advance returned nil after \(delivered); queue was \(queue.map(\.title))")
                return
            }
            delivered.append(next.title)
        }

        XCTAssertEqual(
            delivered,
            order.map(\.title),
            "playback did not walk the whole order; got \(delivered)"
        )
    }

    /// If the coordinator were to stop feeding, playback must be seen to stall —
    /// this pins the dependency the fix is built on, so a future change that
    /// drops the feeding fails loudly here.
    func testStoppingTheFeedStallsPlayback() throws {
        let (controller, root) = try harness()
        defer { try? FileManager.default.removeItem(at: root) }

        let seed = track("seed", root: root)
        controller.startPlayback(tracks: [seed], startingAt: 0, shuffle: true)
        controller.insertTracksAfterCurrent([track("a", root: root)])

        XCTAssertEqual(controller.autoAdvance()?.title, "a", "inserted track should play")
        XCTAssertNil(
            controller.autoAdvance(),
            "with the feed stopped the pool is exhausted, so playback must stall — this is the symptom the coordinator has to prevent"
        )
    }
}
