//
//  QQMusicArtistDetailView.swift
//  kmgccc_player
//
//  Online artist page: songs and albums for an artist from QQ Music.
//
//  Deliberately its own view rather than a mode of the app's library artist
//  page. The library page is built around `ArtistEntry` and local tracks; this
//  one shows catalogue data with nothing local about it, and keeping them apart
//  means changes here cannot disturb the library surface.
//

import SwiftUI

struct QQMusicArtistDetailView: View {

    let artist: QQMusicOnlineArtist

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// Top-level choice. Songs carry a further sort; albums do not — an album
    /// has no notion of "hot" or "latest", so the sort control is hidden there
    /// rather than shown disabled.
    private enum Tab: String, CaseIterable, Identifiable {
        case songs
        case albums

        var id: String { rawValue }
        var title: String { self == .songs ? "歌曲" : "专辑" }
    }

    private enum SongSort: String, CaseIterable, Identifiable {
        case hot
        case latest

        var id: String { rawValue }
        var title: String { self == .hot ? "热门" : "最新" }
    }

    @State private var tab: Tab = .songs
    @State private var songSort: SongSort = .hot
    @State private var songs: [QQMusicOnlineTrack] = []
    @State private var albums: [QQMusicOnlineAlbum] = []
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(ThemedBaseBackgroundColorView())
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                QQMusicArtworkView(urlString: artist.coverURL, size: 64, cornerRadius: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(artist.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text(countText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isLoading { ProgressView().controlSize(.small) }

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: GlassStyleTokens.headerStandardIconSize, weight: .semibold))
                        .foregroundStyle(themeStore.accentColor.opacity(0.9))
                        .frame(
                            width: GlassStyleTokens.headerControlHeight,
                            height: GlassStyleTokens.headerControlHeight
                        )
                        .contentShape(Circle())
                        .liquidGlassCircle(
                            colorScheme: colorScheme,
                            accentColor: nil as Color?,
                            isFloating: true
                        )
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            // Sort is only meaningful for songs, so it disappears on the album
            // tab instead of sitting there disabled.
            HStack(spacing: 8) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: tab) { _, _ in
                    Task { await loadIfNeeded() }
                }

                if tab == .songs {
                    Picker("", selection: $songSort) {
                        ForEach(SongSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    .onChange(of: songSort) { _, _ in
                        Task { await loadSongs(force: true) }
                    }
                }

                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var countText: String {
        var parts: [String] = []
        if let songs = artist.songCount { parts.append("\(songs) 首歌曲") }
        if let albums = artist.albumCount { parts.append("\(albums) 张专辑") }
        return parts.isEmpty ? "在线歌手" : parts.joined(separator: " · ")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let errorText {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(errorText).font(.callout).foregroundStyle(.secondary)
                Button("重试") { Task { await loadIfNeeded(force: true) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tab == .songs {
            songList
        } else {
            albumGrid
        }
    }

    private var songList: some View {
        Group {
            if songs.isEmpty {
                if isLoading { loadingView } else { emptyView("暂无歌曲") }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                            QQMusicOnlineTrackRow(track: track) {
                                Task { await coordinator.startPlayback(songs, startingAt: index) }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var albumGrid: some View {
        Group {
            if albums.isEmpty {
                if isLoading { loadingView } else { emptyView("暂无专辑") }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                        ForEach(albums) { album in
                            QQMusicArtistAlbumCard(album: album) {
                                Task { await openAlbum(album) }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("加载中…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyView(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func load() async {
        await loadIfNeeded(force: true)
    }

    private func loadIfNeeded(force: Bool = false) async {
        switch tab {
        case .songs: await loadSongs(force: force)
        case .albums: await loadAlbums(force: force)
        }
    }

    private func loadSongs(force: Bool) async {
        if !force, !songs.isEmpty { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            // The upstream returns a single ordered list; "latest" is presented
            // by reversing the release-ordered portion where available. When
            // the upstream offers no time ordering this is a no-op rather than
            // a wrong claim, hence the explicit note in the settings copy.
            let fetched = try await coordinator.artistSongs(
                singerMid: artist.singerMid,
                sort: songSort == .hot ? .hot : .latest
            )
            songs = fetched
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadAlbums(force: Bool) async {
        if !force, !albums.isEmpty { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            albums = try await coordinator.artistAlbums(singerMid: artist.singerMid)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func openAlbum(_ album: QQMusicOnlineAlbum) async {
        // Reuse the browse coordinator's album view by pushing its tracks into
        // the shared playlist state is not appropriate here; instead open the
        // album's tracks in place.
        do {
            let tracks = try await coordinator.albumTracks(albumID: album.id)
            songs = tracks
            tab = .songs
            songSort = .hot
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Rows

private struct QQMusicArtistAlbumCard: View {

    let album: QQMusicOnlineAlbum
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                QQMusicArtworkView(urlString: album.coverURL, size: 128, cornerRadius: 8)
                    .frame(maxWidth: .infinity)
                Text(album.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let date = album.releaseDate, !date.isEmpty {
                    Text(date)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
