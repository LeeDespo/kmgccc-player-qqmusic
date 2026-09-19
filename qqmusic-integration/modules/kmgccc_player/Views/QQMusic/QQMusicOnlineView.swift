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
    @State private var searchKind: SearchKind = .songs
    @State private var mineSection: MineSection = .likedSongs
    /// Artist drilled into from search results.
    @State private var openedArtist: QQMusicOnlineArtist?
    @State private var section: Section = .recommend

    private enum Section: String, CaseIterable, Identifiable {
        case mine
        case recommend
        case radio
        case newSongs
        case search
        case toplists

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mine: return "我的"
            case .recommend: return "猜你喜欢"
            case .radio: return "电台"
            case .newSongs: return "新歌电台"
            case .search: return "搜索"
            case .toplists: return "排行榜"
            }
        }
    }

    /// Search is split by content type; the selector only appears on that page.
    private enum SearchKind: String, CaseIterable, Identifiable {
        case songs
        case artists
        case playlists

        var id: String { rawValue }

        var title: String {
            switch self {
            case .songs: return "歌曲"
            case .artists: return "歌手"
            case .playlists: return "歌单"
            }
        }
    }

    /// Sub-sections inside "我的".
    private enum MineSection: String, CaseIterable, Identifiable {
        case likedSongs
        case albums
        case playlists

        var id: String { rawValue }

        var title: String {
            switch self {
            case .likedSongs: return "我喜欢"
            case .albums: return "收藏专辑"
            case .playlists: return "我的歌单"
            }
        }
    }

    var body: some View {
        Group {
            if let artist = openedArtist {
                // A full page in place of the browse surface, mirroring how the
                // library swaps in its artist/album detail pages.
                QQMusicArtistDetailView(artist: artist) {
                    openedArtist = nil
                }
                .environment(coordinator)
                .environmentObject(themeStore)
                .environment(\.qqMusicArtworkLoader, coordinator.artworkLoader)
            } else {
                browseBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var browseBody: some View {
        VStack(spacing: 0) {
            header
            statusBanner
            Divider().opacity(0.3)
            content
        }
        // Driven by `section` rather than by the selector's setter: the setter
        // only fires on a user tap, so a section restored or defaulted to would
        // never load — which is how the "我的" page ended up permanently empty.
        // Deliberately NOT `.task(id:)`: that ties the request to this view's
        // task, so switching sections cancels an in-flight helper request and
        // surfaces as "操作被取消". The loaders guard against duplicate work
        // themselves, so firing and forgetting is safe.
        .onAppear {
            let target = section
            Task { await loadContent(for: target) }
        }
        .onChange(of: section) { _, newValue in
            Task { await loadContent(for: newValue) }
        }

    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                if drilledDownTitle != nil {
                    Button {
                        closeDrillDown()
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
                    .help("返回上一级")
                }

                Text(currentTitle)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)

                if isShowingTrackList, !currentTrackList.isEmpty {
                    Button {
                        Task {
                            await coordinator.startPlayback(
                                currentTrackList,
                                startingAt: 0,
                                pageable: isShowingRecommendFeed
                            )
                        }
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

            if drilledDownTitle == nil {
                // The selector takes the full available width: a fixed width
                // clipped the segments once there were five of them (each has a
                // minimum), which cut the first one off rather than shrinking.
                SlidingSelector(
                    segments: Section.allCases,
                    selection: Binding(
                        get: { section },
                        set: { newValue in
                            section = newValue
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
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: 30)

                // Controls that belong to a single section live on their own
                // row so they cannot squeeze the selector.
                if showsSectionControls {
                    HStack(spacing: 8) {
                        if section == .newSongs {
                            regionPicker
                        }
                        if section == .search {
                            searchKindSelector
                        }
                        if section == .mine {
                            mineSubSelector
                        }
                        Spacer()
                    }
                }

                // The keyword field belongs to the search page only; keeping it
                // out of the other sections is what frees the width for the
                // section selector.
                if section == .search {
                    HStack(spacing: 8) {
                        searchField
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// Kick off whatever the given section needs. Idempotent — each coordinator
    /// loader returns early when its content is already present.
    private func loadContent(for section: Section) async {
        await coordinator.loadInitialContentIfNeeded()
        switch section {
        case .mine:
            await coordinator.loadUserLibraryIfNeeded()
        case .newSongs:
            await coordinator.loadNewSongs(region: coordinator.newSongsRegion)
        case .radio:
            await coordinator.loadRadioStations()
        case .recommend, .search, .toplists:
            break
        }
    }

    private var showsSectionControls: Bool {
        section == .newSongs || section == .search || section == .mine
    }

    /// Region filter for the new-song radio.
    private var regionPicker: some View {
        Picker("", selection: Binding(
            get: { coordinator.newSongsRegion },
            set: { region in
                Task { await coordinator.loadNewSongs(region: region) }
            }
        )) {
            ForEach(QQMusicNewSongRegion.allCases, id: \.self) { region in
                Text(region.displayName).tag(region)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 110)
    }

    /// Keyword field for finding playlists by mood or genre.
    /// Content-type selector for the search page.
    private var searchKindSelector: some View {
        Picker("", selection: $searchKind) {
            ForEach(SearchKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 240)
        .onChange(of: searchKind) { _, _ in
            // Re-run the same query against the newly selected type so switching
            // does not leave an empty page behind.
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            Task { await runSearch(query) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit {
                    Task { await runSearch(searchText) }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    clearSearchResults()
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
        .frame(maxWidth: 320)
    }

    private var searchPlaceholder: String {
        switch searchKind {
        case .songs: return "搜索在线歌曲"
        case .artists: return "搜索歌手"
        case .playlists: return "搜索歌单"
        }
    }

    /// Dispatch the query to the loader matching the selected content type.
    private func runSearch(_ query: String) async {
        switch searchKind {
        case .songs:
            await coordinator.search(query)
        case .artists:
            await coordinator.searchArtists(query)
        case .playlists:
            await coordinator.searchPlaylists(query)
        }
    }

    /// Clear only the current type's results, so the other tabs keep theirs.
    private func clearSearchResults() {
        switch searchKind {
        case .songs: coordinator.clearSearch()
        case .artists: coordinator.clearArtistSearch()
        case .playlists: coordinator.clearPlaylistSearch()
        }
    }

    // MARK: - Radio

    /// Stations grouped by category, with drill-down into one station.
    @ViewBuilder
    private var radioContent: some View {
        if !coordinator.radioStationTitle.isEmpty {
            radioTrackList
        } else if coordinator.radioGroups.isEmpty {
            if coordinator.isLoadingRadioStations { loadingState } else { emptyState("暂无电台") }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(coordinator.radioGroups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.name)
                                .font(.headline)
                                .padding(.horizontal, 20)
                            ForEach(group.stations) { station in
                                Button {
                                    Task { await coordinator.openRadioStation(station) }
                                } label: {
                                    HStack(spacing: 10) {
                                        QQMusicArtworkView(
                                            urlString: station.coverURL,
                                            size: 34,
                                            cornerRadius: 5
                                        )
                                        Text(station.title)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        if let listeners = station.listenerCount, listeners > 0 {
                                            Text(Self.listenerText(listeners))
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 5)
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

    private var radioTrackList: some View {
        Group {
            if coordinator.playlistTracks.isEmpty {
                if coordinator.isLoadingRadioTracks { loadingState } else { emptyState("这个电台暂无曲目") }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(coordinator.playlistTracks.enumerated()), id: \.element.id) { index, track in
                            QQMusicOnlineTrackRow(track: track) {
                                // A station's rotation is endless, so playback
                                // continues by pulling more rather than stopping.
                                Task { await coordinator.startPlayback(coordinator.playlistTracks, startingAt: index) }
                            }
                            .onAppear {
                                guard index >= coordinator.playlistTracks.count - 3 else { return }
                                Task { await coordinator.loadMoreRadioTracks() }
                            }
                        }
                        if coordinator.isLoadingRadioTracks {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在加载更多…").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private static func listenerText(_ count: Int) -> String {
        count >= 10_000
            ? String(format: "%.1f 万人在听", Double(count) / 10_000)
            : "\(count) 人在听"
    }

    // MARK: - Search

    @ViewBuilder
    private var searchContent: some View {
        switch searchKind {
        case .songs:
            trackList(coordinator.searchResults, loading: coordinator.isSearching)
        case .artists:
            artistList
        case .playlists:
            searchedPlaylistGrid
        }
    }

    private var artistList: some View {
        Group {
            if coordinator.searchedArtists.isEmpty {
                if coordinator.isSearchingArtists {
                    loadingState
                } else {
                    emptyState(coordinator.artistSearchKeyword.isEmpty
                               ? "输入歌手名开始搜索"
                               : "没有找到相关歌手")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(coordinator.searchedArtists) { artist in
                            QQMusicArtistRow(artist: artist) {
                                openedArtist = artist
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
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

    /// Title of the drilled-down list, if we are inside one.
    ///
    /// Playback lists and radio stations are separate coordinator states, so
    /// both are consulted here — otherwise entering a station would leave the
    /// header showing the section name with no way back.
    private var drilledDownTitle: String? {
        if !coordinator.radioStationTitle.isEmpty { return coordinator.radioStationTitle }
        if !coordinator.loadedPlaylistTitle.isEmpty { return coordinator.loadedPlaylistTitle }
        return nil
    }

    private var currentTitle: String {
        if let drilledDownTitle { return drilledDownTitle }
        // Search state is only meaningful on the search page; showing it
        // elsewhere made results follow the user across tabs.
        if isOnSearchPage, !coordinator.searchKeyword.isEmpty {
            return "搜索：\(coordinator.searchKeyword)"
        }
        return section.title
    }

    /// Whether the search page is the one on screen.
    private var isOnSearchPage: Bool { section == .search }

    /// Leave whichever drill-down is active.
    private func closeDrillDown() {
        if !coordinator.radioStationTitle.isEmpty {
            coordinator.closeRadioStation()
        } else {
            coordinator.closePlaylist()
        }
    }

    private var isShowingTrackList: Bool {
        drilledDownTitle != nil
            || (isOnSearchPage && !coordinator.searchKeyword.isEmpty)
            || section == .recommend
    }

    /// True when the recommend feed is the list on screen, which is the only
    /// pageable (endless) list.
    private var isShowingRecommendFeed: Bool {
        drilledDownTitle == nil && section == .recommend
    }

    private var currentTrackList: [QQMusicOnlineTrack] {
        if drilledDownTitle != nil {
            // Both playlist and station tracks live in `playlistTracks`.
            return coordinator.playlistTracks
        }
        if isOnSearchPage, !coordinator.searchKeyword.isEmpty {
            return coordinator.searchResults
        }
        return coordinator.recommendFeed
    }

    @ViewBuilder
    private var content: some View {
        if drilledDownTitle != nil {
            // Playlist or radio station: both publish into `playlistTracks`.
            if coordinator.radioStationTitle.isEmpty {
                trackList(coordinator.playlistTracks, loading: coordinator.isLoadingPlaylistTracks)
            } else {
                radioTrackList
            }
        } else {
            switch section {
            case .recommend:
                trackList(coordinator.recommendFeed, loading: coordinator.isLoadingFeed, pageable: true)
            case .mine:
                mineContent
            case .newSongs:
                trackList(coordinator.newSongs, loading: coordinator.isLoadingNewSongs)
            case .radio:
                radioContent
            case .search:
                searchContent
            case .toplists:
                toplistList
            }
        }
    }

    private func trackList(
        _ tracks: [QQMusicOnlineTrack],
        loading: Bool,
        pageable: Bool = false
    ) -> some View {
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
                                    Task {
                                        await coordinator.startPlayback(
                                            tracks,
                                            startingAt: index,
                                            pageable: pageable
                                        )
                                    }
                                }
                            )
                            .onAppear {
                                // Pull the next page as the end comes into view.
                                guard pageable, index >= tracks.count - 3 else { return }
                                Task { await coordinator.extendRecommendFeed() }
                            }
                        }

                        if pageable {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在加载更多推荐…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var searchedPlaylistGrid: some View {
        Group {
            if coordinator.searchedPlaylists.isEmpty {
                if coordinator.isSearchingPlaylists {
                    loadingState
                } else {
                    emptyState(coordinator.playlistSearchKeyword.isEmpty
                               ? "输入风格或场景关键词，例如「爵士」「深夜」「运动」"
                               : "没有找到相关歌单")
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 168), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(coordinator.searchedPlaylists) { playlist in
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

    private var mineSubSelector: some View {
        Picker("", selection: $mineSection) {
            ForEach(MineSection.allCases, id: \.self) { item in
                Text(item.title).tag(item)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 300)
    }

    /// The "我的" section: liked songs, favorited albums, own playlists.
    ///
    /// Read-only by design. The upstream refuses writes over the web channel, so
    /// there is no like/unlike or playlist-editing affordance to be confused by.
    @ViewBuilder
    private var mineContent: some View {
        if coordinator.userLibraryNeedsLogin {
            loginPrompt
        } else {
            switch mineSection {
            case .likedSongs:
                likedSongsList
            case .albums:
                likedAlbumGrid
            case .playlists:
                userPlaylistGrid
            }
        }
    }

    private var loginPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("需要登录 QQ 音乐账号")
                .font(.headline)
            Text("收藏和自建歌单属于账号数据，登录后才能读取。点右下角的地球按钮进入 QQ 音乐设置即可登录。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var likedSongsList: some View {
        Group {
            if coordinator.likedSongs.isEmpty {
                if coordinator.isLoadingLikedSongs { loadingState } else { emptyState("还没有收藏的歌曲") }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        HStack {
                            Text("共 \(coordinator.likedSongsTotal) 首")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 8)

                        ForEach(Array(coordinator.likedSongs.enumerated()), id: \.element.id) { index, track in
                            QQMusicOnlineTrackRow(track: track) {
                                Task { await coordinator.startPlayback(coordinator.likedSongs, startingAt: index) }
                            }
                            .onAppear {
                                // "我喜欢" can run to hundreds of tracks, so page
                                // rather than fetching it all up front.
                                guard index >= coordinator.likedSongs.count - 5 else { return }
                                Task { await coordinator.loadMoreLikedSongs() }
                            }
                        }

                        if coordinator.hasMoreLikedSongs {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在加载更多…").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var likedAlbumGrid: some View {
        Group {
            if coordinator.likedAlbums.isEmpty {
                if coordinator.isLoadingLikedAlbums { loadingState } else { emptyState("还没有收藏的专辑") }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 14)], spacing: 14) {
                        ForEach(coordinator.likedAlbums) { album in
                            QQMusicAlbumCard(album: album) {
                                Task { await coordinator.openAlbum(id: album.id, title: album.title) }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private var userPlaylistGrid: some View {
        Group {
            if coordinator.userPlaylists.isEmpty {
                if coordinator.isLoadingUserPlaylists { loadingState } else { emptyState("还没有自建或收藏的歌单") }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 14)], spacing: 14) {
                        ForEach(coordinator.userPlaylists) { playlist in
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

struct QQMusicOnlineTrackRow: View {

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
        QQMusicArtworkView(urlString: track.imageURL, size: 38, cornerRadius: 5)
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
                QQMusicArtworkView(
                    urlString: playlist.coverURL,
                    size: 132,
                    cornerRadius: 8
                )
                .frame(maxWidth: .infinity)

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

// MARK: - Album card

struct QQMusicAlbumCard: View {

    let album: QQMusicOnlineAlbum
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                QQMusicArtworkView(
                    urlString: album.coverURL,
                    size: 132,
                    cornerRadius: 8
                )
                .frame(maxWidth: .infinity)

                Text(album.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)

                if let artist = album.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Artist row

struct QQMusicArtistRow: View {

    let artist: QQMusicOnlineArtist
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                QQMusicArtworkView(urlString: artist.coverURL, size: 42, cornerRadius: 21)

                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(countText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var countText: String {
        var parts: [String] = []
        if let songs = artist.songCount { parts.append("\(songs) 首歌曲") }
        if let albums = artist.albumCount { parts.append("\(albums) 张专辑") }
        return parts.isEmpty ? "歌手" : parts.joined(separator: " · ")
    }
}
