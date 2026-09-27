//
//  QQMusicTrackDescriptionSheet.swift
//  kmgccc_player
//
//  查看歌曲描述 for an online track.
//
//  The library's rows open `DetailDescriptionReaderSheet` for the song's
//  *description* — the user's own note, else the album's, else the artist's — and
//  that is a different thing from 查看详情, which reads out the facts (album,
//  length, quality, whether the track is in the library). An online track has no
//  user note and no local album prose, but QQ Music publishes a 简介 for many
//  songs, so this is the same sheet filled with that.
//
//  Reused rather than approximated, like 查看详情: it is the app's own read-only
//  reader, down to the 580pt panel, the artwork block and the empty state — so a
//  song the catalogue has no prose for shows 「暂无详细介绍」 in the app's own
//  wording instead of a blank panel of our own invention.
//

import AppKit
import SwiftUI

struct QQMusicTrackDescriptionSheet: View {

    let track: QQMusicOnlineTrack

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @EnvironmentObject private var themeStore: ThemeStore

    /// Nil until the description arrives. Kept apart from `""` so the sheet can
    /// tell "still loading" from "the catalogue has none".
    @State private var description: String?
    /// The cover, through the browse cache's own loader — the same path the rows
    /// use, so opening this cannot start a second route to the CDN.
    @State private var artworkImage: NSImage?

    var body: some View {
        DetailDescriptionReaderSheet(
            title: "歌曲描述",
            systemImage: "text.quote",
            subtitle: subtitle,
            text: description ?? "",
            artworkImage: artworkImage
        )
        .environmentObject(themeStore)
        .task(id: track.songMid) {
            description = await coordinator.songDescription(for: track) ?? ""
        }
        .task(id: track.imageURL) {
            artworkImage = nil
            guard let url = track.imageURL, !url.isEmpty else { return }
            artworkImage = await coordinator.artworkLoader.image(for: url)
        }
    }

    /// "歌曲 - 歌手", the same composition 查看详情 uses, so the two sheets read
    /// alike.
    private var subtitle: String {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, !artist.isEmpty { return "\(title) - \(artist)" }
        if !title.isEmpty { return title }
        if !artist.isEmpty { return artist }
        return "未知歌曲"
    }
}
