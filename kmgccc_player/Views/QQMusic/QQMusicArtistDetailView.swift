//
//  QQMusicArtistDetailView.swift
//  kmgccc_player
//
//  Online artist page.
//
//  Deliberately replicates the look of the app's library artist page — a large
//  circular portrait, then title / subtitle / metadata, and a list beneath —
//  so browsing an online artist feels like the same application. It is a
//  separate view built from the same styling rather than a reuse of
//  `PlaylistDetailView`: that page is driven by `LibrarySelection` and local
//  `Track` values, and bending it to carry catalogue data would change the
//  library surface. `PlaylistDetailView` and `LibraryDetailHeaderView` are
//  untouched.
//
//  The app's artist page lists tracks only, so the album list here is an
//  addition (a segmented switch). Albums have no notion of "hot"/"latest", so
//  that second-level control appears only under songs.
//

import SwiftUI

struct QQMusicArtistDetailView: View {

    let artist: QQMusicOnlineArtist

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// Top-level content switch.
    private enum Tab: String, CaseIterable, Identifiable {
        case songs
        case albums

        var id: String { rawValue }
        var title: String { self == .songs ? "歌曲" : "专辑" }
    }

    /// Ordering for the song list.
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
    /// Album whose tracks are being shown in place of the artist's own list.
    @State private var openedAlbumTitle: String?

    /// Matches the library header's artwork side so the two pages read alike.
    private static let artworkSide: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            // Back is drawn inside the content, matching the app's own pages
            // (no toolbar), so it looks identical wherever the user is.
            navigationBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    contentSwitch
                    content
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .frame(minWidth: 720, minHeight: 600)
        .background(ThemedBaseBackgroundColorView())
        .task { await loadSongs(force: true) }
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack(spacing: 6) {
            Button {
                if openedAlbumTitle != nil {
                    // Step back to the artist's own list first.
                    openedAlbumTitle = nil
                    Task { await loadSongs(force: true) }
                } else {
                    dismiss()
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 13))
                }
                .foregroundStyle(themeStore.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回")

            Spacer()

            if isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Header

    /// Mirror of the library artist header: circular portrait on the left,
    /// text column on the right.
    private var header: some View {
        HStack(alignment: .top, spacing: 22) {
            QQMusicArtworkView(
                urlString: artist.coverURL,
                size: Self.artworkSide,
                cornerRadius: Self.artworkSide / 2
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(artist.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                Text(countText)
                    .font(.callout)
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
        .frame(minHeight: Self.artworkSide, alignment: .top)
    }

    private var countText: String {
        var parts: [String] = []
        if let songs = artist.songCount { parts.append("\(songs) 首歌曲") }
        if let albums = artist.albumCount { parts.append("\(albums) 张专辑") }
        return parts.isEmpty ? "在线歌手" : parts.joined(separator: " · ")
    }

    // MARK: - Content switch

    @ViewBuilder
    private var contentSwitch: some View {
        if let openedAlbumTitle {
            Text(openedAlbumTitle)
                .font(.headline)
                .lineLimit(1)
        } else {
            HStack(spacing: 8) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: tab) { _, newValue in
                    Task {
                        if newValue == .albums { await loadAlbums() }
                    }
                }

                // An album has no notion of hot/latest, so this control is
                // absent there rather than present but meaningless.
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
                Button("重试") { Task { await loadSongs(force: true) } }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else if tab == .songs || openedAlbumTitle != nil {
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
                LazyVStack(spacing: 2) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                        QQMusicOnlineTrackRow(track: track) {
                            Task { await coordinator.startPlayback(songs, startingAt: index) }
                        }
                    }
                }
            }
        }
    }

    private var albumGrid: some View {
        Group {
            if albums.isEmpty {
                if isLoading { loadingView } else { emptyView("暂无专辑") }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                    ForEach(albums) { album in
                        QQMusicAlbumCard(album: album) {
                            Task { await openAlbum(album) }
                        }
                    }
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("加载中…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func emptyView(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
    }

    // MARK: - Loading

    private func loadSongs(force: Bool) async {
        if !force, !songs.isEmpty { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            songs = try await coordinator.artistSongs(
                singerMid: artist.singerMid,
                sort: songSort == .hot ? .hot : .latest
            )
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadAlbums() async {
        if !albums.isEmpty { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            albums = try await coordinator.artistAlbums(singerMid: artist.singerMid)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Show an album's tracks in place, keeping the artist header above them.
    private func openAlbum(_ album: QQMusicOnlineAlbum) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            songs = try await coordinator.albumTracks(albumID: album.id)
            openedAlbumTitle = album.title
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
