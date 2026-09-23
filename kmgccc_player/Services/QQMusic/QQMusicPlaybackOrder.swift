//
//  QQMusicPlaybackOrder.swift
//  kmgccc_player
//
//  Derivation of the order an online session plays in.
//
//  Extracted as a pure function because this is where the "shuffle plays in list
//  order" bug lived, and because it is the one part of a session that can be
//  checked without a network, a player or a library: given the list, the track to
//  keep at the cursor, and the mode, the order is fully determined.
//
//  Why the coordinator derives an order at all: the engine's shuffle samples
//  from the tracks it has been handed, and those must be local files — so on the
//  online source its pool only ever held the few tracks downloaded so far, and
//  shuffle played out of a slowly growing window instead of the whole list. The
//  coordinator is what holds the whole list, so it decides the order and
//  downloads along it.
//

import Foundation

nonisolated enum QQMusicPlaybackOrder {

    /// Build the listening order for `allSongMids`.
    ///
    /// The already-played portion keeps its relative order, and the track at the
    /// cursor is pinned in place; only what comes after the cursor is permuted.
    /// Reshuffling behind the cursor would make "previous" jump somewhere
    /// unrelated, and moving the cursor would interrupt what is playing.
    ///
    /// - Parameters:
    ///   - allSongMids: every track of the session, in list order.
    ///   - currentMid: the track to keep at the cursor. Ignored when it is not in
    ///     the list, in which case the head is used.
    ///   - shuffle: whether the unplayed portion should be permuted.
    ///   - generator: injected so the result is reproducible under test.
    static func make<R: RandomNumberGenerator>(
        allSongMids: [String],
        keeping currentMid: String?,
        shuffle: Bool,
        using generator: inout R
    ) -> [String] {
        guard !allSongMids.isEmpty else { return [] }

        let anchor = currentMid.flatMap { allSongMids.contains($0) ? $0 : nil } ?? allSongMids[0]
        let anchorIndex = allSongMids.firstIndex(of: anchor) ?? 0

        let played = Array(allSongMids[..<anchorIndex])
        var upcoming = Array(allSongMids[anchorIndex...])
        let first = upcoming.removeFirst()

        if shuffle {
            upcoming.shuffle(using: &generator)
        }
        return played + [first] + upcoming
    }
}
