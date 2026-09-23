//
//  QQMusicPlaybackOrderTests.swift
//  kmgccc_playerTests
//
//  The listening order an online session plays in.
//
//  This is where "shuffle plays in list order" came from, and the failure is
//  silent — the list still plays, just in the wrong order, over a range that
//  looks arbitrary because it is limited to what has been downloaded. The
//  properties pinned here are the ones that make shuffle audibly different from
//  sequential, plus the ones that keep a mid-session rebuild from disturbing
//  what is already playing.
//

import XCTest
@testable import kmgccc_player

final class QQMusicPlaybackOrderTests: XCTestCase {

    /// Deterministic generator, so "did it shuffle" is a stable assertion.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private let list = (1...20).map { "song-\($0)" }

    private func make(shuffle: Bool, keeping: String? = nil, seed: UInt64 = 42) -> [String] {
        var generator = SeededGenerator(seed: seed)
        return QQMusicPlaybackOrder.make(
            allSongMids: list,
            keeping: keeping,
            shuffle: shuffle,
            using: &generator
        )
    }

    // MARK: - Invariants that hold either way

    func testEveryTrackAppearsExactlyOnce() {
        for shuffle in [true, false] {
            let order = make(shuffle: shuffle)
            XCTAssertEqual(order.count, list.count)
            XCTAssertEqual(Set(order), Set(list), "shuffle=\(shuffle) lost or duplicated a track")
        }
    }

    func testEmptyListProducesEmptyOrder() {
        var generator = SeededGenerator(seed: 1)
        let order = QQMusicPlaybackOrder.make(
            allSongMids: [],
            keeping: nil,
            shuffle: true,
            using: &generator
        )
        XCTAssertTrue(order.isEmpty)
    }

    /// The track that is playing stays where it is: moving it would interrupt
    /// playback, and reshuffling behind it would make "previous" jump somewhere
    /// unrelated.
    func testAnchorHoldsItsPositionAndPlayedPrefixIsPreserved() {
        let anchor = "song-7"
        let expectedPlayedPrefix = Array(list.prefix(6))   // songs 1...6

        for shuffle in [true, false] {
            let order = make(shuffle: shuffle, keeping: anchor)
            XCTAssertEqual(order[0..<6].map { $0 }, expectedPlayedPrefix, "shuffle=\(shuffle)")
            XCTAssertEqual(order[6], anchor, "shuffle=\(shuffle)")
        }
    }

    /// An anchor that is not in the list falls back to the head rather than
    /// producing a list with a hole in it.
    func testUnknownAnchorFallsBackToTheHead() {
        let order = make(shuffle: true, keeping: "not-in-the-list")
        XCTAssertEqual(order.count, list.count)
        XCTAssertEqual(order.first, "song-1")
        XCTAssertEqual(Set(order), Set(list))
    }

    // MARK: - The difference between the two modes

    func testSequentialOrderIsTheListOrder() {
        XCTAssertEqual(make(shuffle: false), list)
    }

    /// The property that was silently absent: with shuffle on, the unplayed part
    /// must actually be a permutation, not the list again.
    func testShuffledOrderIsNotTheListOrder() {
        let order = make(shuffle: true)
        XCTAssertNotEqual(
            order,
            list,
            "shuffle produced the list order — this is the bug where shuffle played sequentially"
        )
    }

    /// And it must vary with the draw, rather than being one fixed permutation.
    func testDifferentDrawsGiveDifferentOrders() {
        let first = make(shuffle: true, seed: 1)
        let second = make(shuffle: true, seed: 2)
        XCTAssertNotEqual(first, second)
    }

    /// Shuffling is confined to the unplayed remainder: everything before the
    /// cursor keeps its order, so the history stays truthful.
    func testShuffleDoesNotTouchTheAlreadyPlayedPortion() {
        let anchor = "song-10"
        let order = make(shuffle: true, keeping: anchor)

        XCTAssertEqual(Array(order.prefix(9)), Array(list.prefix(9)))
        XCTAssertEqual(order[9], anchor)
        XCTAssertEqual(Set(order.suffix(10)), Set(list.suffix(10)))
    }
}
