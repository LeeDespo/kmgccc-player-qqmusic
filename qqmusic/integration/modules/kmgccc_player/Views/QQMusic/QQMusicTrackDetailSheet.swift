//
//  QQMusicTrackDetailSheet.swift
//  kmgccc_player
//
//  查看详情 for an online track.
//
//  The library's rows open `TrackDetailDescriptionSheet` there, which resolves a
//  *description* for the local track (the user's own note, else the album's, else
//  the artist's). An online track has none of that — the catalogue holds no
//  prose — so the same sheet is used with the same shape and the facts that do
//  exist take the body: album, length, whether it needs a subscription, what the
//  library already holds, and the song mid.
//
//  `DetailDescriptionReaderSheet` is reused rather than approximated: it is the
//  app's own read-only detail reader, down to the 580pt panel and the artwork
//  block, so 查看详情 looks like 查看详情 wherever it is invoked.
//

import AppKit
import SwiftUI

/// What the library currently holds for an online track.
///
/// Three states rather than a flag because the difference is the user's: audio
/// fetched for playback counts against the download cache and can be reclaimed,
/// while audio they asked for is theirs.
nonisolated enum QQMusicTrackLibraryState: Equatable {
    case notDownloaded
    case automaticCache
    case userDownload

    var description: String {
        switch self {
        case .notDownloaded: return "未下载"
        case .automaticCache: return "已在曲库（自动下载，可被缓存回收）"
        case .userDownload: return "已在曲库（手动下载）"
        }
    }
}

/// The wording of 查看详情, pulled out of the view so it is testable.
nonisolated enum QQMusicTrackDetail {

    static func content(
        for track: QQMusicOnlineTrack,
        libraryState: QQMusicTrackLibraryState
    ) -> TrackDetailContent {
        var lines: [String] = []
        if let album = track.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            lines.append("专辑：\(album)")
        }
        if let duration = track.duration, duration > 0 {
            lines.append(String(format: "时长：%d:%02d", duration / 60, duration % 60))
        }
        lines.append("音质：\(availabilityText(for: track))")
        lines.append("曲库状态：\(libraryState.description)")
        if !track.songMid.isEmpty {
            lines.append("歌曲 MID：\(track.songMid)")
        }

        return TrackDetailContent(
            title: "歌曲详情",
            subtitle: subtitle(for: track),
            attributionNote: nil,
            text: lines.joined(separator: "\n")
        )
    }

    /// "歌曲 - 歌手", the same composition the library's resolver uses, so the
    /// two sheets read alike.
    private static func subtitle(for track: QQMusicOnlineTrack) -> String {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, !artist.isEmpty { return "\(title) - \(artist)" }
        if !title.isEmpty { return title }
        if !artist.isEmpty { return artist }
        return "未知歌曲"
    }

    /// What the catalogue says about playing it.
    ///
    /// `payPlay` is a heuristic — the authoritative answer only arrives when a
    /// playback url is asked for — so this is worded as a likelihood rather than
    /// as a promise.
    private static func availabilityText(for track: QQMusicOnlineTrack) -> String {
        guard !track.songMid.isEmpty else { return "未知" }
        return track.isExpectedPlayable ? "可直接播放" : "可能需要会员"
    }
}

struct QQMusicTrackDetailSheet: View {

    let track: QQMusicOnlineTrack

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @EnvironmentObject private var themeStore: ThemeStore

    /// The cover is fetched through the browse cache's own loader, so opening
    /// this sheet cannot open a second path to the CDN.
    @State private var artworkImage: NSImage?

    private var libraryState: QQMusicTrackLibraryState {
        guard coordinator.isImported(track.songMid) else { return .notDownloaded }
        return coordinator.isUserDownloaded(track.songMid) ? .userDownload : .automaticCache
    }

    var body: some View {
        let content = QQMusicTrackDetail.content(for: track, libraryState: libraryState)
        DetailDescriptionReaderSheet(
            title: content.title,
            systemImage: "music.note",
            subtitle: content.subtitle,
            text: content.text,
            artworkImage: artworkImage
        )
        .environmentObject(themeStore)
        .task(id: track.imageURL) {
            artworkImage = nil
            guard let url = track.imageURL, !url.isEmpty else { return }
            artworkImage = await coordinator.artworkLoader.image(for: url)
        }
    }
}
