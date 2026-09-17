//
//  QQMusicOnlineView.swift
//  kmgccc_player
//
//  Browse surface for online QQ Music content.
//
//  Design notes:
//  - Rows are catalog entries, not library tracks. Tapping play downloads the
//    track, imports it, and starts playback; the rest of the list is fetched in
//    the background so playback continues without visible buffering.
//  - Tracks the upstream will not grant (`payPlay == 1`) are marked rather than
//    hidden, because the user's account tier decides. The resolution result
//    remains the authoritative answer.
//  - A failed request never clears content already on screen; failures surface
//    as a dismissible banner above the list.
//

import SwiftUI

struct QQMusicOnlineView: View {

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var searchText = ""
    @State private var section: Section = .recommend

    private enum Section: String, CaseIterable, Identifiable {
        case recommend
        case playlists
        case toplists

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recommend: return "为你推荐"
            case .playlists: return "歌单推荐"
            case .toplists: return "排行榜"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            statusBanner
            Divider().opacity(0.3)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await coordinator.loadInitialContentIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                if !coordinator.loadedPlaylistTitle.isEmpty {
                    Button {
                        coordinator.closePlaylist()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("返回")
                }

                Text(currentTitle)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)

                if isShowingTrackList, !currentTrackList.isEmpty {
                    Button {
                        Task { await coordinator.startPlayback(currentTrackList, startingAt: 0) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 10))
                            Text("播放全部").font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(themeStore.accentColor.opacity(0.24)))
                    }
                    .buttonStyle(.plain)
                    .help("从第一首开始播放，其余歌曲会边播边下载")
                }

                Spacer()

                if coordinator.isBusyLoading {
                    ProgressView().controlSize(.small)
                }
            }

            if coordinator.loadedPlaylistTitle.isEmpty {
                HStack(spacing: 8) {
                    SlidingSelector(
                        segments: Section.allCases,
                        selection: Binding(
                            get: { section },
                            set: { newValue in
                                section = newValue
                                Task { await coordinator.loadInitialContentIfNeeded() }
                            }
                        ),
                        animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                        hSpacing: 0,
                        background: { Color.clear },
                        knob: {
                            Capsule(style: .continuous)
                                .fill(themeStore.accentColor.opacity(0.22))
                        },
                        content: { item, isSelected in
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                .frame(minWidth: 74, maxWidth: .infinity)
                                .frame(height: 24)
                                .contentShape(Rectangle())
                        }
                    )
                    .frame(width: 260, height: 30)

                    Spacer()

                    searchField
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索在线歌曲", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit {
                    Task { await coordinator.search(searchText) }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    coordinator.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .frame(width: 240)
    }

    // MARK: - Status banner
    //
    // Failures are reported here, above the content, instead of replacing it.

    @ViewBuilder
    private var statusBanner: some View {
        if !coordinator.canDownload {
            banner(
                text: "当前资料库为原位模式，无法保存下载的歌曲。切换到托管资料库后即可播放在线歌曲。",
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        } else if let message = coordinator.statusMessage {
            banner(
                text: message,
                systemImage: coordinator.statusIsError
                    ? "exclamationmark.triangle.fill"
                    : "info.circle.fill",
                tint: coordinator.statusIsError ? .orange : themeStore.accentColor
            )
        }
    }

    private func banner(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Content

    private var currentTitle: String {
        if !coordinator.loadedPlaylistTitle.isEmpty {
            return coordinator.loadedPlaylistTitle
        }
        if !coordinator.searchKeyword.isEmpty {
            return "搜索：\(coordinator.searchKeyword)"
        }
        return section.title
    }

    private var isShowingTrackList: Bool {
        !coordinator.loadedPlaylistTitle.isEmpty
            || !coordinator.searchKeyword.isEmpty
            || section == .recommend
    }

    private var currentTrackList: [QQMusicOnlineTrack] {
        if !coordinator.loadedPlaylistTitle.isEmpty {
            return coordinator.playlistTracks
        }
        if !coordinator.searchKeyword.isEmpty {
            return coordinator.searchResults
        }
        return coordinator.recommendFeed
    }

    @ViewBuilder
    private var content: some View {
        if !coordinator.loadedPlaylistTitle.isEmpty {
            trackList(coordinator.playlistTracks, loading: coordinator.isLoadingPlaylistTracks)
        } else if !coordinator.searchKeyword.isEmpty {
            trackList(coordinator.searchResults, loading: coordinator.isSearching)
        } else {
            switch section {
            case .recommend:
                trackList(coordinator.recommendFeed, loading: coordinator.isLoadingFeed)
            case .playlists:
                playlistGrid
            case .toplists:
                toplistList
            }
        }
    }

    private func trackList(_ tracks: [QQMusicOnlineTrack], loading: Bool) -> some View {
        Group {
            if tracks.isEmpty {
                if loading {
                    loadingState
                } else {
                    emptyState("这里还没有内容")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            QQMusicOnlineTrackRow(
                                track: track,
                                onPlay: {
                                    Task { await coordinator.startPlayback(tracks, startingAt: index) }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var playlistGrid: some View {
        Group {
            if coordinator.recommendPlaylists.isEmpty {
                if coordinator.isLoadingPlaylists { loadingState } else { emptyState("暂无推荐歌单") }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 168), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(coordinator.recommendPlaylists) { playlist in
                            QQMusicPlaylistCard(playlist: playlist) {
                                Task { await coordinator.openPlaylist(id: playlist.id, title: playlist.title) }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private var toplistList: some View {
        Group {
            if coordinator.toplistGroups.isEmpty {
                if coordinator.isLoadingToplists { loadingState } else { emptyState("暂无排行榜") }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(coordinator.toplistGroups.enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.name)
                                    .font(.headline)
                                    .padding(.horizontal, 20)

                                // Rendered as rows rather than wrapped chips: it
                                // matches the track lists, and a plain VStack
                                // needs no custom layout pass.
                                ForEach(group.toplists) { toplist in
                                    Button {
                                        Task { await coordinator.openToplist(id: toplist.id, title: toplist.name) }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "chart.bar.fill")
                                                .font(.system(size: 11))
                                                .foregroundStyle(themeStore.accentColor)
                                            Text(toplist.name)
                                                .font(.system(size: 13))
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("加载中…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct QQMusicOnlineTrackRow: View {

    let track: QQMusicOnlineTrack
    let onPlay: () -> Void

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @EnvironmentObject private var themeStore: ThemeStore

    private var phase: QQMusicDownloadPhase { coordinator.phase(for: track.songMid) }
    private var isImported: Bool { coordinator.isImported(track.songMid) }
    private var isPlaying: Bool { coordinator.isPlaying(track.songMid) }

    var body: some View {
        HStack(spacing: 10) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: isPlaying ? .semibold : .medium))
                    .foregroundStyle(isPlaying ? themeStore.accentColor : Color.primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let duration = track.duration, duration > 0 {
                Text(Self.format(duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            statusControl
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onPlay() }
    }

    private var artwork: some View {
        AsyncImage(url: track.imageURL.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                Rectangle().fill(Color.primary.opacity(0.08))
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    @ViewBuilder
    private var statusControl: some View {
        switch phase {
        case .resolving:
            busyLabel("解析中")
        case .downloading(let fraction):
            HStack(spacing: 6) {
                ProgressView(value: fraction).frame(width: 44)
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 84, alignment: .trailing)
        case .fetchingExtras:
            busyLabel("整理中")
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                playButton
            }
            .frame(maxWidth: 240, alignment: .trailing)
            .help(message)
        case .done, .idle:
            HStack(spacing: 6) {
                if isImported && !isPlaying {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("已下载到本地曲库")
                }
                playButton
            }
        }
    }

    private var playButton: some View {
        Button(action: onPlay) {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(
                    isPlaying
                        ? themeStore.accentColor
                        : (track.isExpectedPlayable ? Color.primary : Color.secondary)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        if isPlaying { return "正在播放" }
        if track.isExpectedPlayable { return "播放（后台自动下载）" }
        return "需要会员，仍可尝试播放"
    }

    private func busyLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(width: 84, alignment: .trailing)
    }

    private static func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Playlist card

private struct QQMusicPlaylistCard: View {

    let playlist: QQMusicOnlinePlaylist
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: playlist.coverURL.flatMap(URL.init(string:))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(Color.primary.opacity(0.08))
                    }
                }
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(playlist.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)

                if let count = playlist.songCount {
                    Text("\(count) 首")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
