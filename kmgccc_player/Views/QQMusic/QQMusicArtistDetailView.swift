//
//  QQMusicArtistDetailView.swift
//  kmgccc_player
//
//  Online artist page, replicating the app's library artist page.
//
//  This is a faithful copy of `LibraryDetailHeaderView`'s composition rather
//  than a reuse of it: that view's edit paths write to the local library
//  (`saveArtistEntry`, artwork autofill, artist navigation through
//  `LibrarySelection`), none of which apply to a catalogue artist, and wiring
//  them up would let online browsing write into the user's library.
//
//  The layout constants are copied deliberately so the two pages read as the
//  same surface:
//    - 220pt artwork, circle for an artist / rounded 14 for an album
//    - HStack(alignment: .bottom, spacing: 20), padded 24 / 20
//    - title `.title` bold, subtitle `.callout`, metadata `.caption`
//    - a "播放" capsule in the accent colour, bottom-left of the text column
//

import SwiftUI

struct QQMusicArtistDetailView: View {

    let artist: QQMusicOnlineArtist
    /// Called when the user leaves the page.
    let onClose: () -> Void

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

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
    @State private var isLoadingMore = false
    @State private var songPage = 1
    @State private var hasMoreSongs = true
    @State private var errorText: String?
    @State private var biography: String?
    /// Set when a favourited/artist album has been opened in this page.
    @State private var openedAlbum: QQMusicOnlineAlbum?
    @State private var albumSongs: [QQMusicOnlineTrack] = []

    /// Copied from `LibraryDetailHeaderView`.
    private static let artworkSide: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider().opacity(0.25).padding(.horizontal, 24)
                    contentSwitch
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                    content
                        .padding(.top, 10)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.18), value: tab)
                        .animation(.easeInOut(duration: 0.18), value: songSort)
                        .animation(.easeInOut(duration: 0.18), value: openedAlbum?.id)
                }
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { Task { await loadSongs(force: true) } }
    }

    // MARK: - Navigation

    /// Drawn inside the content, matching the app's own detail pages which use
    /// no toolbar for this.
    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button {
                if openedAlbum != nil {
                    // Step back to the artist's own list first.
                    openedAlbum = nil
                    albumSongs = []
                } else {
                    onClose()
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("返回").font(.system(size: 13))
                }
                .foregroundStyle(themeStore.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回")

            Spacer()

            if isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: - Header
    //
    // Mirrors `LibraryDetailHeaderView`: artwork column on the left, text column
    // on the right, bottom-aligned, same paddings.

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            artworkColumn
                .frame(width: Self.artworkSide, height: Self.artworkSide)

            headerTextColumn
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var artworkColumn: some View {
        // 220pt square; the clip shape is what makes it read as an artist or an
        // album, exactly as the library header does.
        QQMusicArtworkView(
            urlString: headerArtworkURL,
            size: Self.artworkSide,
            cornerRadius: isShowingAlbum ? 14 : Self.artworkSide / 2
        )
    }

    private var isShowingAlbum: Bool { openedAlbum != nil }

    private var headerArtworkURL: String? {
        openedAlbum?.coverURL ?? artist.coverURL
    }

    private var headerTextColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(headerTitle)
                    .font(.title)
                    .fontWeight(.bold)
                    .lineLimit(2)
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)

                subtitleView

                metadataView

                Spacer().frame(height: 2)

                // Biography, as the library artist page shows one. Omitted
                // entirely (rather than a placeholder) when upstream has none.
                if let biography, !biography.isEmpty, !isShowingAlbum {
                    Text(biography)
                        .font(.callout)
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                        .lineLimit(4)
                        .padding(.top, 4)
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: Self.artworkSide - GlassStyleTokens.headerControlHeight - 14,
                alignment: .topLeading
            )
            .clipped()

            Spacer(minLength: 0)

            // Omitted rather than faded on the albums tab: "play all albums" has
            // no meaning, and a disabled capsule still reads as a control.
            if canPlayFromHeader {
                playButton
            }
        }
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            minHeight: Self.artworkSide,
            maxHeight: Self.artworkSide,
            alignment: .leading
        )
    }

    private var headerTitle: String {
        openedAlbum?.title ?? artist.name
    }

    /// Artist: "N 首歌曲 · M 张专辑". Album: the artist name, as in the library
    /// header where it is the subtitle.
    @ViewBuilder
    private var subtitleView: some View {
        if isShowingAlbum {
            Button {
                // Return to the artist this album belongs to.
                openedAlbum = nil
                albumSongs = []
                tab = .songs
            } label: {
                Text(artist.name)
                    .font(.callout)
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
            }
            .buttonStyle(.plain)
        } else {
            Text(artistSubtitle)
                .font(.callout)
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
        }
    }

    private var artistSubtitle: String {
        var parts: [String] = []
        if let count = artist.songCount { parts.append("\(count) 首歌曲") }
        if let count = artist.albumCount { parts.append("\(count) 张专辑") }
        return parts.isEmpty ? "在线歌手" : parts.joined(separator: " · ")
    }

    /// Artist: nothing upstream supplies genre/region, so this stays absent
    /// rather than inventing values. Album: the release year, mirroring
    /// `buildAlbumMetaParts`.
    @ViewBuilder
    private var metadataView: some View {
        if let date = openedAlbum?.releaseDate, !date.isEmpty {
            Text(date)
                .font(.caption)
                .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
        }
    }

    /// The "播放" capsule, copied from `HeaderPlayButton`.
    private var playButton: some View {
        Button {
            let list = currentTracks
            guard !list.isEmpty else { return }
            Task { await coordinator.startPlayback(list, startingAt: 0) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("播放")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(colorScheme == .dark ? 0.95 : 0.90))
            .padding(.horizontal, 16)
            .frame(height: GlassStyleTokens.headerControlHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canPlayFromHeader)
        .background(Capsule().fill(themeStore.accentColor))
        .background(Capsule().fill(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08)))
        .glassEffect(.clear, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
        .clipShape(Capsule())
        // Visibility is decided by the caller (`canPlayFromHeader`), which omits
        // the button outright on the albums tab. Fading it here would be wrong:
        // `opacity` applied to the label alone left the capsule drawn behind it,
        // which is what made a hidden button look like a stray coloured pill.
        .help("播放全部")
    }

    /// What "播放" acts on.
    ///
    /// Only ever a concrete track list: the open album's tracks, or the
    /// artist's songs while the songs tab is showing. There is deliberately no
    /// button on the albums tab — "play all albums" has no meaning.
    private var currentTracks: [QQMusicOnlineTrack] {
        isShowingAlbum ? albumSongs : songs
    }

    /// Whether the header's play button applies.
    private var canPlayFromHeader: Bool {
        (isShowingAlbum || tab == .songs) && !currentTracks.isEmpty
    }

    // MARK: - Content switch

    @ViewBuilder
    private var contentSwitch: some View {
        if !isShowingAlbum {
            HStack(spacing: 8) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: tab) { _, newValue in
                    Task { if newValue == .albums { await loadAlbums() } }
                }

                // An album has no notion of hot/latest, so this is absent on the
                // album tab rather than present but meaningless.
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
        } else if tab == .songs || isShowingAlbum {
            songList
        } else {
            albumGrid
        }
    }

    private var songList: some View {
        Group {
            let list = currentTracks
            if list.isEmpty {
                if isLoading { loadingView } else { emptyView("暂无歌曲") }
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, track in
                        QQMusicOnlineTrackRow(track: track) {
                            Task { await coordinator.startPlayback(list, startingAt: index) }
                        }
                        .onAppear {
                            // Artists can have over a thousand songs, so page
                            // as the end comes into view rather than up front.
                            guard tab == .songs, !isShowingAlbum,
                                  index >= list.count - 5
                            else { return }
                            Task { await loadMoreSongs() }
                        }
                    }
                    if isLoadingMore {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在加载更多…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 14)
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
                .padding(.horizontal, 24)
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
                sort: songSort == .hot ? .hot : .latest,
                page: 1
            )
            songPage = 1
            hasMoreSongs = !songs.isEmpty
            await loadBiographyIfNeeded()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Append the next page of the artist's songs.
    private func loadMoreSongs() async {
        guard hasMoreSongs, !isLoadingMore, !isLoading, !isShowingAlbum else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = songPage + 1
            let more = try await coordinator.artistSongs(
                singerMid: artist.singerMid,
                sort: songSort == .hot ? .hot : .latest,
                page: next
            )
            // Comparing the tail guards against a server that keeps returning
            // the same page, which would otherwise loop forever.
            let known = Set(songs.map(\.songMid))
            let fresh = more.filter { !known.contains($0.songMid) }
            guard !fresh.isEmpty else {
                hasMoreSongs = false
                return
            }
            songs.append(contentsOf: fresh)
            songPage = next
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            hasMoreSongs = false
        }
    }

    /// Artist biography, shown under the header as the library page does.
    private func loadBiographyIfNeeded() async {
        guard biography == nil else { return }
        biography = await coordinator.artistBiography(singerMid: artist.singerMid)
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

    /// Open an album in place — the header switches to the album's cover, title
    /// and year, exactly as the library album page presents one.
    private func openAlbum(_ album: QQMusicOnlineAlbum) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            albumSongs = try await coordinator.albumTracks(albumID: album.id)
            openedAlbum = album
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
