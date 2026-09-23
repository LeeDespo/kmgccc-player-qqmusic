//
//  QQMusicSelectionModel.swift
//  kmgccc_player
//
//  Batch-download selection for the online browse surface.
//
//  Session-scoped rather than view state, for the same reason the page stack is:
//  the control that drives it lives in the **window toolbar**, which is AppKit
//  and cannot reach into the SwiftUI view tree. Both the toolbar control and the
//  pages read this one object, so they can never disagree about whether a
//  selection is in progress.
//
//  Entering the online source from the sidebar clears it (`resetBrowsing`), so a
//  half-made selection does not survive leaving and re-entering the source.
//

import Foundation
import Observation

// MARK: - Batch selection

/// Which tracks a batch download has selected, if one is in progress.
///
/// Only finite lists are offered this. An endless list (the recommend feed, a
/// radio's rotation, an artist's song list) has no "all", so a select-all there
/// would promise something that cannot be delivered — that gate lives in
/// `QQMusicOnlineCoordinator.canSelectTracks(for:)`.
@Observable
@MainActor
final class QQMusicSelectionModel {

    private(set) var isSelecting = false
    private(set) var selectedSongMids: Set<String> = []
    private(set) var isDownloading = false

    func begin() {
        isSelecting = true
        selectedSongMids = []
    }

    func cancel() {
        isSelecting = false
        selectedSongMids = []
    }

    func toggle(_ songMid: String) {
        guard !songMid.isEmpty else { return }
        if selectedSongMids.contains(songMid) {
            selectedSongMids.remove(songMid)
        } else {
            selectedSongMids.insert(songMid)
        }
    }

    func isSelected(_ songMid: String) -> Bool {
        selectedSongMids.contains(songMid)
    }

    /// Select every track in the given list that is not already the user's own.
    ///
    /// Including those would inflate the count and do nothing: their download
    /// has already happened.
    func selectAll(in tracks: [QQMusicOnlineTrack], excluding owned: Set<String>) {
        selectedSongMids = Set(
            tracks.map(\.songMid).filter { !$0.isEmpty && !owned.contains($0) }
        )
    }

    func invert(in tracks: [QQMusicOnlineTrack], excluding owned: Set<String>) {
        let selectable = Set(
            tracks.map(\.songMid).filter { !$0.isEmpty && !owned.contains($0) }
        )
        selectedSongMids = selectable.subtracting(selectedSongMids)
    }

    func setDownloading(_ value: Bool) {
        isDownloading = value
    }
}

