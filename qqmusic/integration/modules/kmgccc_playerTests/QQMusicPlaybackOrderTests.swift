//
//  QQMusicPlaybackOrderTests.swift
//  kmgccc_playerTests
//
//  The listening order an online session plays in.
//
//  This is where "shuffle plays in list order" came from, and the failure is
//  silent — the list still plays, just in the wrong order. The properties pinned
//  here are the two the listener actually hears:
//
//    * the order starts on the track that was asked for, never on the list's
//      first row (an order that begins with the head makes a click on the 10th
//      row play the 1st — and makes shuffle indistinguishable from sequential);
//    * with shuffle on, the order is a permutation of the whole list rather than
//      the list again.
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

    // MARK: - Where the session starts

    /// The track that was asked for plays first. Starting anywhere else is the
    /// bug the listener reported as "点第 10 首却从第 1 首开始".
    func testOrderStartsOnTheRequestedTrack() {
        for shuffle in [true, false] {
            let order = make(shuffle: shuffle, keeping: "song-10")
            XCTAssertEqual(order.first, "song-10", "shuffle=\(shuffle)")
        }
    }

    /// Sequential is the library's "play from here": the tail of the list, in
    /// order, and nothing from above the cursor.
    func testSequentialPlaysTheListTailFromTheCursor() {
        let order = make(shuffle: false, keeping: "song-7")
        XCTAssertEqual(order, Array(list.suffix(14)))          // songs 7...20
        XCTAssertEqual(order.count, 14)
    }

    /// A whole-list play (the header's 播放) has no cursor to speak of, so it
    /// starts at the top and covers everything.
    func testSequentialFromTheHeadIsTheListOrder() {
        XCTAssertEqual(make(shuffle: false), list)
        XCTAssertEqual(make(shuffle: false, keeping: "song-1"), list)
    }

    // MARK: - Shuffle

    /// Shuffle must cover the *whole* list, including the rows above the cursor:
    /// shuffling only the tail would be shuffling the wrong list.
    func testShuffleCoversEveryTrackIncludingThoseAboveTheCursor() {
        let order = make(shuffle: true, keeping: "song-10")
        XCTAssertEqual(order.count, list.count)
        XCTAssertEqual(Set(order), Set(list))
        XCTAssertEqual(order.first, "song-10")
    }

    /// The property that was silently absent: with shuffle on, the order must be
    /// a permutation rather than the list again.
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

    /// An anchor that is not in the list falls back to the head rather than
    /// producing a list with a hole in it.
    func testUnknownAnchorFallsBackToTheHead() {
        let order = make(shuffle: true, keeping: "not-in-the-list")
        XCTAssertEqual(order.count, list.count)
        XCTAssertEqual(order.first, "song-1")
        XCTAssertEqual(Set(order), Set(list))
    }
}
