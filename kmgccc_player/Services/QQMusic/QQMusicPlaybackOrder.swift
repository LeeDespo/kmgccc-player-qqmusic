//
//  QQMusicPlaybackOrder.swift
//  kmgccc_player
//
//  Derivation of the order an online session plays in.
//
//  Extracted as a pure function because this is where the "shuffle plays in list
//  order" bug lived, and because it is the one part of a session that can be
//  checked without a network, a player or a library: given the list, the track to
//  put at the cursor, and the mode, the order is fully determined.
//
//  Why the coordinator derives an order at all: the engine's shuffle samples
//  from the tracks it has been handed, and those must be local files — so on the
//  online source its pool only ever held the few tracks downloaded so far, and
//  shuffle played out of a slowly growing window instead of the whole list. The
//  coordinator is what holds the whole list, so it decides the order and
//  downloads along it.
//
//  The order returned here is the *session* order: it starts at the cursor track
//  and every entry is something that has not played yet. That is exactly what the
//  prefetch loop walks to decide what to download next, so an entry behind the
//  cursor is an entry that would play out of turn — see `make`.
//

import Foundation

nonisolated enum QQMusicPlaybackOrder {

    /// Build the listening order for `allSongMids`, starting at `currentMid`.
    ///
    /// The result always begins with the cursor track, and never contains
    /// anything that came *before* it in the list except where shuffle asks for
    /// it:
    ///
    ///   * **sequential** — the cursor track followed by the list's tail. This is
    ///     the library's own "play from here": pressing play on the 10th row of a
    ///     playlist plays 10, 11, 12 … and finishes at the end, rather than
    ///     wrapping around to the rows above it. Those rows were not asked for.
    ///   * **shuffle** — the cursor track followed by every *other* track,
    ///     permuted. Shuffle has to cover the whole list, not only the part below
    ///     the row the user happened to click.
    ///
    /// The rows above the cursor used to be emitted in list order at the front,
    /// labelled as "already played". They never were: at session start the user
    /// has just pressed play, so the result was that a shuffle and a sequential
    /// session both fed the queue from the top of the list and sounded identical
    /// — the reported "无论是随机播放还是顺序播放，都从歌单的第一首开始". What
    /// *has* played belongs to the engine's queue, which keeps it, and that is
    /// where 上一首 reads it from.
    ///
    /// - Parameters:
    ///   - allSongMids: every track of the session, in list order.
    ///   - currentMid: the track to put at the cursor. Ignored when it is not in
    ///     the list, in which case the head is used.
    ///   - shuffle: whether the rest of the list should be permuted.
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

        // Everything but the anchor, in list order.
        var rest = allSongMids
        rest.remove(at: anchorIndex)

        // Sequential keeps the list's tail only; the rows above the cursor drop
        // out of the order entirely. Shuffle keeps them all, because a shuffle
        // that could not reach them would be a shuffle of the wrong list.
        var upcoming = shuffle ? rest : Array(rest[anchorIndex...])
        if shuffle {
            upcoming.shuffle(using: &generator)
        }
        return [anchor] + upcoming
    }
}
