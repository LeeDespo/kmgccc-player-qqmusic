//
//  QQMusicOnlineCoordinator.swift
//  kmgccc_player
//
//  Bridges the online QQ Music catalog into the local library.
//
//  The catalogue side is network work, and all of it is served by one channel:
//  `QQMusicHelperProcess`, the data component that owns the credential, the rate
//  limit and the circuit breaker. The library side is main-actor state owned by the
//  import pipeline. This coordinator is where the two meet: it downloads a track
//  to staging, imports it, and — for a playback session — keeps the player queue
//  fed so playback never has to stop and wait.
//
//  Cache policy for the lists that change over time (我喜欢, 收藏歌单, 收藏专辑, a
//  playlist's tracks): paint what the cache holds, fetch the complete list, and
//  replace what is on screen in one step only if it actually differs. Never page
//  or merge into a visible list, and never clear it to load — an empty page is
//  what "don't reload" is meant to prevent.
//
//  Playback model: the player consumes only real `Track` values backed by
//  local files, so an online "play" is download-then-play. To make that feel
//  like streaming, `startPlayback` downloads the requested track and then
//  prefetches ahead in the background, appending each result to the queue.
//  Playback then advances through the queue with the player's own logic.
//
//  Failures are **log-only**. There used to be a status line reported to a thin
//  banner under the toolbar; it was removed on request, along with the
//  informational notices (playback start, like confirmations, download
//  confirmations) that shared it. A failure now belongs where it can be acted
//  on — a row's own download glyph, a page's own empty state — and the log
//  carries the detail, including the rate-limit backoff that `noteFailure`
//  records.
//

import Foundation
import Observation

@Observable
@MainActor
final class QQMusicOnlineCoordinator {

    // MARK: - Browsing state

    private(set) var recommendFeed: [QQMusicOnlineTrack] = []
    private(set) var toplistGroups: [QQMusicToplistGroup] = []
    private(set) var searchResults: [QQMusicOnlineTrack] = []
    private(set) var playlistTracks: [QQMusicOnlineTrack] = []
    /// Station currently open, so "load more" continues its rotation.
    private(set) var activeRadioStationID: Int?
    /// New-song radio for the selected region.
    private(set) var newSongs: [QQMusicOnlineTrack] = []
    private(set) var newSongsRegion: QQMusicNewSongRegion = .latest
    /// Playlists found by keyword, for category/mood browsing.
    private(set) var searchedPlaylists: [QQMusicOnlinePlaylist] = []

    // User library (read-only)
    private(set) var likedSongs: [QQMusicOnlineTrack] = []
    private(set) var likedSongsTotal = 0
    private(set) var likedAlbums: [QQMusicOnlineAlbum] = []
    /// The singers the account follows.
    private(set) var followedArtists: [QQMusicOnlineArtist] = []
    private(set) var isLoadingFollowedArtists = false
    private(set) var userPlaylists: [QQMusicOnlinePlaylist] = []
    // Radio stations
    private(set) var radioGroups: [QQMusicRadioGroup] = []
    private(set) var isLoadingRadioStations = false
    private(set) var isLoadingRadioTracks = false

    // Artist search
    private(set) var searchedArtists: [QQMusicOnlineArtist] = []
    private(set) var isSearchingArtists = false

    // Album search
    private(set) var searchedAlbums: [QQMusicOnlineAlbum] = []
    private(set) var isSearchingAlbums = false

    private(set) var isLoadingLikedSongs = false
    private(set) var isLoadingLikedAlbums = false
    private(set) var isLoadingUserPlaylists = false
    /// Song mids currently liked, from the account's "我喜欢".
    ///
    /// Held as a set rather than re-querying per track: the upstream has no
    /// per-track membership endpoint, so the folder is read once and kept in
    /// memory while the session lives.
    private(set) var likedSongMids: Set<String> = []
    /// Walks the remaining pages of the liked folder in the background, so the
    /// first page can be shown immediately while the full set fills in.
    private var isRefreshingLikedMids = false
    /// The row a like was issued from, so the liked list can be adjusted
    /// without refetching it. Keyed by song mid; consumed on insert.
    private var pendingLikeRow: [String: QQMusicOnlineTrack] = [:]
    /// Writes in flight, so the button can show progress and not double-fire.
    private(set) var pendingLikeSongMids: Set<String> = []
    /// Guards the one-shot full-list load, which is separate from paging.
    private(set) var isLoadingNewSongs = false
    private(set) var isSearchingPlaylists = false

    private(set) var isLoadingFeed = false
    private(set) var isLoadingToplists = false
    private(set) var isSearching = false

    /// Per-track download state, keyed by song mid, so rows can show progress.
    private(set) var downloadPhases: [String: QQMusicDownloadPhase] = [:]
    /// Song mids already in the library as a QQ Music download.
    private(set) var importedSongMids: Set<String> = []

    /// Song mid of the track playback started on, so rows can show which one is
    /// playing.
    private(set) var activePlayingSongMid: String?

    // MARK: - Dependencies

    private let helper: QQMusicHelperProcess
    private let downloader: QQMusicDownloadService

    /// On-disk cache for catalogue payloads and artwork. Nil until a library
    /// session supplies paths, which also disables caching rather than failing.
    private(set) var cacheStore: QQMusicCacheStore?

    /// One loader for the whole session, so cover fetches coalesce across rows
    /// and stay within the concurrency cap instead of each row racing its own.
    /// Built together with the cache store so it always has the right one.
    private(set) var artworkLoader = QQMusicArtworkLoader(cache: nil)

    /// The batch-download selection.
    ///
    /// Owned here rather than by a page because the control that drives it is a
    /// window-toolbar item, and the AppKit side can only reach session state
    /// through the coordinator.
    let selection = QQMusicSelectionModel()

    /// Where the user is in the online browse surface.
    ///
    /// Owned by the coordinator rather than by the view so it survives leaving
    /// and re-entering the surface within a session, and so the window toolbar
    /// can drive back/forward and reach the online search from the AppKit side —
    /// both of which need a reference the view tree cannot supply.
    let navigation = QQMusicNavigation()

    /// Search keyword typed into the toolbar's field while browsing online.
    ///
    /// The field itself belongs to the window toolbar (the library searches
    /// through the same one), so its text arrives here by callback rather than
    /// living in a page's `@State`.
    private(set) var onlineSearchKeyword = ""

    /// Which content type the toolbar search should run against.
    private(set) var onlineSearchKind: QQMusicSearchKind = .songs

    /// Library root, exposed so the QQ Music window can report and reveal cache.
    var libraryRootURL: URL? { paths?.rootURL }

    // MARK: - Reload

    /// Bumped when the toolbar's refresh button is pressed.
    ///
    /// A counter, not a flag: pressing refresh twice has to be two distinct
    /// events, or the second press would look like "nothing changed" to the
    /// pages watching it.
    ///
    /// It only signals. What a reload has to re-request is knowledge the pages
    /// already have — the router owns page loading and the artist page owns its
    /// own — so each observes this and re-runs its own loaders with `force`.
    /// Enumerating the pages here instead would have to be kept in step with
    /// every page added later, which is how a page ends up with a refresh that
    /// silently does nothing.
    private(set) var reloadToken: UInt64 = 0

    /// Reload the page on screen, discarding what it was showing.
    func requestReload() {
        reloadToken &+= 1
    }

    // MARK: - 查看详情

    /// The track whose detail sheet is open, if any.
    ///
    /// Session state rather than a row's own `@State` because rows live in a
    /// `LazyVStack`: a row that scrolls out of view is torn down, and a sheet
    /// owned by it would go with it. One presentation point on the router is also
    /// what keeps the sheet from being rebuilt as the list recycles.
    var trackForDetail: QQMusicOnlineTrack?

    func showTrackDetail(_ track: QQMusicOnlineTrack) {
        trackForDetail = track
    }

    // MARK: - 歌曲描述

    /// The track whose description sheet is open, if any.
    ///
    /// A second presentation point rather than a flag on `trackForDetail`,
    /// because the two sheets say different things about the same song: 查看详情
    /// is the catalogue's facts (album, length, quality, whether it is in the
    /// library), 查看歌曲描述 is the prose QQ Music publishes about it.
    var trackForDescription: QQMusicOnlineTrack?

    func showTrackDescription(_ track: QQMusicOnlineTrack) {
        trackForDescription = track
    }

    /// Song descriptions already fetched, keyed by song mid.
    ///
    /// They do not change, and the hero card and the 查看歌曲描述 sheet ask for the
    /// same one — without this, opening the sheet after the card had shown it
    /// would cost a second round trip.
    private var songDescriptions: [String: String] = [:]

    /// The catalogue's own prose about `track`, or nil when it has none.
    ///
    /// An **empty answer is an answer**. Most songs carry no 简介 at all (checked
    /// live: four of six sampled tracks had none), so an empty read is cached as
    /// "this song has none" rather than retried. That is the opposite of the rule
    /// for whole-list reads, where an empty list is a failure to answer: a song
    /// with no prose is normal, while an account whose playlists vanished is not.
    func songDescription(for track: QQMusicOnlineTrack) async -> String? {
        guard !track.songMid.isEmpty else { return nil }
        if let cached = songDescriptions[track.songMid] {
            return cached.isEmpty ? nil : cached
        }
        do {
            let text = try await fetchSongDescription(songMid: track.songMid)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            songDescriptions[track.songMid] = text
            return text.isEmpty ? nil : text
        } catch {
            Log.warning(
                "[QQMusicOnline] song description failed: \(noteFailure(error))",
                category: .import
            )
            return nil
        }
    }

    /// How often the local library has played this online track.
    ///
    /// The app's hero reports the library's own preference stats, and an online
    /// track has them exactly when it has been played: playback downloads it
    /// through the import pipeline first, so it is a library track from then on.
    /// A song that has never played here therefore reads as 0 and the stats line
    /// shows the duration alone — which is what the app's hero does for an
    /// unplayed local track too.
    ///
    /// Deliberately not an upstream listen count: the endpoints this source reads
    /// carry none (the song-detail module returns 简介, 公司, 流派, 语种 and 发行时间
    /// and nothing else numeric).
    func localPlayCount(for songMid: String) -> Int {
        guard !songMid.isEmpty,
              let libraryViewModel,
              let local = libraryViewModel.allTracks.first(where: { $0.qqMusicSongMid == songMid })
        else { return 0 }
        return libraryViewModel.preferenceStats(for: local.id).playCount
    }

    /// Set once a library session exists; the coordinator cannot import without it.
    var importService: FileImportService?
    var paths: LibraryPaths? {
        didSet {
            guard let paths, cacheStore == nil else { return }
            let store = QQMusicCacheStore(paths: paths)
            cacheStore = store
            artworkLoader = QQMusicArtworkLoader(cache: store)
            let quality = AppSettings.shared.qqMusicPreferredQuality
            Task {
                await downloader.attach(cacheStore: store)
                await downloader.setPreferredQuality(quality)
            }
        }
    }
    var playerViewModel: PlayerViewModel?
    var libraryViewModel: LibraryViewModel?

    /// Whether downloads can land in the current library. Downloaded audio only
    /// exists as a managed file, so an in-place (referenced) library cannot host it.
    var canDownload: Bool {
        guard let importService, paths != nil else { return false }
        return importService.supportsProducedAudioImport
    }

    // MARK: - Session internals

    /// Remaining online tracks for the current playback session, in order.
    private var sessionTracks: [QQMusicOnlineTrack] = []
    /// Whether the session's list can be extended by paging (guess-you-like
    /// only). Static lists such as a playlist have a fixed end.
    private var sessionSupportsPaging = false
    /// Every song mid already shown in the feed or queued in the session, so a
    /// paging refresh can never repeat one. The upstream radio happily returns
    /// tracks it has already given out.
    private var seenFeedSongMids: Set<String> = []
    /// Guards against overlapping paging refreshes (scroll + queue refill can
    /// both fire near the end of the list).
    private var isExtendingFeed = false
    /// Guard so two prefetch loops never run at once.
    private var prefetchTask: Task<Void, Never>?
    private var trackChangeObserver: Task<Void, Never>?
    private var playbackModeObserver: Task<Void, Never>?
    /// Backoff after upstream rate limiting, to stop hammering the API.
    private var rateLimitedUntil: Date?

    // MARK: - Playback order (shuffle across the whole online list)
    //
    // The engine's own shuffle samples from the tracks it has been handed, and
    // those must be local files — so on the online source its pool only ever
    // held the few tracks downloaded so far. Shuffle therefore played out of a
    // slowly growing window instead of out of the whole list.
    //
    // The coordinator is the component that actually knows the whole list: it is
    // what fetched all 471 liked songs in the first place. So it decides the
    // order itself and downloads along that order, rather than asking the engine
    // to guess. The engine then just plays the queue in sequence, which it is
    // good at.
    //
    // Consequence worth knowing: the order covers the entire list, but the
    // player's queue window can only show what has been downloaded (only those
    // have a library Track). Downloading the rest up front is what we are
    // deliberately avoiding.

    /// Song mids in the order they will be played. Equal to the list order in
    /// sequential mode, and a shuffle of it in shuffle mode.
    private var playbackOrder: [String] = []
    /// The list the order was derived from, so a mode switch can re-derive
    /// without re-fetching.
    private var sessionAllSongMids: [String] = []
    /// Whether `playbackOrder` came from a shuffle, so a redundant rebuild can
    /// be skipped.
    private var orderIsShuffled = false
    /// Whether this session's list is itself a radio feed.
    ///
    /// A radio (猜你喜欢, a station's tracks) is already a random draw from the
    /// catalogue, so applying shuffle on top changes nothing audible — the user
    /// is right that "shuffle and sequential sound the same" there. Recording it
    /// lets the order skip the reshuffle and keeps the two modes honest: the
    /// list plays in the order the radio produced, which is what the upstream
    /// considers the sequence.
    private var sessionIsRadio = false

    /// Tracks this session could not download, so the prefetch loop stops
    /// picking them. Without this an unplayable track is never queued, so it
    /// would be chosen again on every pass and retried forever.
    private var skippedSongMids: Set<String> = []
    /// Which list the drill-down has open (playlist, album or ranking), so its
    /// next page can be asked for and its cache key is known. Nil when none is.
    private var openedList: OpenList?
    /// The open list's own track count, as upstream reports it. 0 means unknown,
    /// which simply withholds "load more".
    private(set) var openedPlaylistTotal = 0
    /// Bumped every time another list is opened, so a fetch that is still in
    /// flight can tell that it has been superseded and drop its result instead of
    /// appending to a list the user has already left.
    private var listGeneration: UInt64 = 0
    private(set) var isLoadingMorePlaylistTracks = false
    /// How many list loads are in flight.
    ///
    /// A count rather than a flag: opening another list while one is still
    /// loading used to have the first load's `defer` clear the flag the second
    /// one had just set, so the page fell back to its "nothing here" state while
    /// a fetch was plainly running.
    private var listLoadsInFlight = 0

    /// Whether the shared track list is loading, for the page's own state.
    var isLoadingPlaylistTracks: Bool { listLoadsInFlight > 0 }
    /// Whether the prefetch loop is currently running. Explicit, because a
    /// *finished* `Task` is neither nil nor cancelled, so task identity cannot
    /// answer "is it still feeding the queue?".
    private var isPrefetching = false
    /// How many browsing-wide preparations are running. A count for the same
    /// reason as `listLoadsInFlight`: one finishing must not clear the state of
    /// one still running.
    private var isPreparingForBrowsing = 0
    /// Bumped whenever a loop starts or is stopped, so a finishing loop can tell
    /// whether the flag still belongs to it.
    private var prefetchGeneration: UInt64 = 0
    /// The scheduled retry for a rate-limited load. One at a time.
    private var backoffRetryTask: Task<Void, Never>?
    /// Bumped per search, so the newest query is the one that lands. One per
    /// search type: the three run against different endpoints and never overlap.
    private var searchGeneration: UInt64 = 0
    private var artistSearchGeneration: UInt64 = 0
    private var playlistSearchGeneration: UInt64 = 0
    private var albumSearchGeneration: UInt64 = 0

    init(
        helper: QQMusicHelperProcess = .shared,
        downloader: QQMusicDownloadService = QQMusicDownloadService()
    ) {
        self.helper = helper
        self.downloader = downloader
    }





    private func fetchLikedSongs(page: Int, limit: Int) async throws -> QQMusicLikedSongs {
        try await helper.fetchLikedSongs(page: page, limit: limit)
    }

    private func fetchLikedAlbums(limit: Int = 30) async throws -> [QQMusicOnlineAlbum] {
        try await helper.fetchLikedAlbums(limit: limit)
    }

    private func fetchFollowedArtists(limit: Int = 30) async throws -> [QQMusicOnlineArtist] {
        try await helper.fetchFollowedArtists(limit: limit)
    }

    /// Load 关注的歌手, in the shape every account list here uses: paint the cache,
    /// fetch the list, replace it in one step only if it differs.
    func loadFollowedArtists(force: Bool = false) async {
        guard !isLoadingFollowedArtists else { return }
        if !force, !followedArtists.isEmpty { return }
        if backoffRemaining() != nil {
            scheduleRetryAfterBackoff()
            return
        }
        isLoadingFollowedArtists = true
        defer { isLoadingFollowedArtists = false }

        if followedArtists.isEmpty,
           let store = cacheStore,
           let data = await store.staleCatalog(.userLibrary, key: "followedArtists"),
           let cached = try? JSONDecoder().decode([QQMusicOnlineArtist].self, from: data),
           !cached.isEmpty {
            followedArtists = cached
        }

        do {
            let fetched = try await fetchFollowedArtists()
            if let store = cacheStore, !fetched.isEmpty,
               let data = try? JSONEncoder().encode(fetched) {
                await store.storeCatalog(data, category: .userLibrary, key: "followedArtists")
            }
            // Same rule as the other account lists: replace wholesale, but only
            // when the list actually differs.
            let key: (QQMusicOnlineArtist) -> String = { "\($0.singerMid)|\($0.name)|\($0.coverURL ?? "")" }
            if fetched.map(key) != followedArtists.map(key) {
                followedArtists = fetched
            }
        } catch {
            Log.warning("[QQMusicOnline] followed artists failed: \(noteFailure(error))", category: .import)
        }
    }

    private func fetchUserPlaylists() async throws -> [QQMusicOnlinePlaylist] {
        try await helper.fetchUserPlaylists()
    }


    private func fetchLyric(
        songMid: String,
        songId: Int?
    ) async throws -> QQMusicLyricPayload {
        try await helper.fetchLyric(songMid: songMid, songId: songId)
    }

    /// The song's 简介, through the same metadata read the import enrichment
    /// uses (`fetch_song_detail`), so the prose is identical.
    private func fetchSongDescription(songMid: String) async throws -> String {
        let detail = try await helper.fetchSongDetail(songMid: songMid)
        return detail.description ?? ""
    }

    /// One page of a playlist's tracks, web-first with a helper fallback.
    ///
    /// One page of a playlist's tracks.
    ///
    /// The helper pages by number, not by offset, so the page is derived from
    /// the offset. It reports the list's own size (`dirinfo.songnum`), which is
    /// what lets the caller walk the rest of the pages; when it does not, the
    /// count received is the count there is, and paging simply stops there.
    private func fetchPlaylistPage(
        songlistId: Int,
        offset: Int,
        limit: Int
    ) async throws -> (tracks: [QQMusicOnlineTrack], total: Int) {
        let page = max(1, offset / max(1, limit) + 1)
        let page_ = try await helper.fetchPlaylistTracksPage(songlistId: songlistId, limit: limit, page: page)
        return (page_.tracks, page_.total ?? (offset + page_.tracks.count))
    }

    // MARK: - Page lifecycle

    /// Browsing-wide preparation, independent of which page is showing.
    ///
    /// Two things every page relies on: whether downloads can land in the
    /// current library at all (the toolbar's batch-download control reads it),
    /// and the
    /// liked-mid set the hearts read from — a row's heart is wrong until that
    /// set has been filled.
    func prepareForBrowsing(force: Bool = false) async {
        // A count, not a flag, and no early return: this is driven by the
        // surface's `.task`, which SwiftUI cancels when the surface goes away, so
        // a re-entry could find the *previous* prepare still "in flight" (its
        // guard set, its cancellation unobserved for a moment) and drop its own —
        // landing the page with nothing loaded and no way back except leaving
        // again. Each loader inside guards itself, so overlap is cheap.
        isPreparingForBrowsing += 1
        defer { isPreparingForBrowsing -= 1 }

        await loadInitialContentIfNeeded(force: force)
        await ensureLikedSongMidsIfNeeded(force: force)
        // The landing shelves read every account list, and the account library
        // is what makes 我喜欢 / 收藏歌单 / 收藏专辑 load instantly when opened
        // from a shelf rather than only on the first tap.
        await preloadUserLibrary(force: force)
    }

    /// Identity of the current library session, so a page's `.task` can tell
    /// when the browse surface has been re-entered after a library switch.
    var libraryAvailabilityToken: String {
        "\(canDownload)|\(paths?.rootURL.lastPathComponent ?? "none")"
    }

    /// Load whatever the given page needs, once.
    ///
    /// Every branch depends only on its own loader: awaiting one page's network
    /// work before starting another's is what previously made a section look
    /// like it only loaded on a second tap.
    ///
    /// `force` is the refresh path. Each loader normally returns early when its
    /// content is present and reads the catalogue cache otherwise, so without it
    /// a refresh would re-display exactly what is already on screen.
    func loadContent(for page: QQMusicPage, force: Bool = false) async {
        switch page {
        case .home:
            await prepareForBrowsing(force: force)

        case .likedSongs:
            await loadUserLibraryIfNeeded(force: force)

        case .userPlaylists:
            await loadUserPlaylists(force: force)

        case .likedAlbums:
            await loadLikedAlbums(force: force)

        case .followedArtists:
            await loadFollowedArtists(force: force)

        case .newSongs(let region):
            await loadNewSongs(region: region, force: force)

        case .toplists:
            await loadToplists(force: force)

        case .radio:
            await loadRadioStations(force: force)

        case .recommend:
            await loadRecommendFeed(force: force)

        case .search(let kind):
            // Results belong to the query, not to the page: entering the page
            // with an empty field must not run a search for nothing. A reload is
            // the other case — the query is known and the user asked for it
            // again, so it is re-run against upstream rather than the cache.
            if force {
                await searchFromToolbar(onlineSearchKeyword, kind: kind, force: true)
            }

        case .playlist(let id, _):
            await openPlaylist(id: id, force: force)

        case .album(let id, _):
            await openAlbum(id: id, force: force)

        case .toplist(let id, _):
            await openToplist(id: id, force: force)

        case .radioStation(let id, let title):
            // A station's rotation is generated per request and never cached, so
            // a reload and a first open are already the same request.
            _ = force
            await openRadioStation(id: id, title: title)

        case .artist:
            // The artist page owns its own multi-tab loading, as the library's
            // own artist page does.
            break
        }
    }

    /// Open a station by id, for a page restored from the navigation stack.
    ///
    /// Always refetches. Skipping when the id matched the open station looked
    /// like a cheap guard, but `playlistTracks` is shared with the playlist,
    /// album and ranking pages — so after visiting one of those, returning to a
    /// station would have shown *that* list under the station's header.
    func openRadioStation(id: Int, title: String) async {
        await openRadioStation(QQMusicRadioStation(id: id, title: title))
    }

    // MARK: - Toolbar-driven navigation and search

    /// Leave the online surface, dropping its history.
    ///
    /// Called when the user enters the online source from the sidebar: that is
    /// the same "start over" gesture as clicking 主页 in the library, so it
    /// lands on the landing page rather than resuming a previous drill-down.
    func resetBrowsing() {
        backoffRetryTask?.cancel()
        backoffRetryTask = nil
        navigation.popToRoot()
        // A selection belongs to the page it was started on, so entering from the
        // sidebar drops it along with the history.
        selection.cancel()
        onlineSearchKeyword = ""
        onlineSearchKind = .songs
    }

    var canGoBack: Bool { navigation.canGoBack }
    var canGoForward: Bool { navigation.canGoForward }

    /// Run the toolbar's search against the online catalogue.
    ///
    /// A search is a page, so this pushes one (or re-runs the one already on
    /// screen). The results themselves are fetched per type, and switching type
    /// re-runs the same keyword rather than clearing the field.
    func searchFromToolbar(
        _ keyword: String,
        kind: QQMusicSearchKind? = nil,
        force: Bool = false
    ) async {
        let kind = kind ?? onlineSearchKind
        onlineSearchKind = kind

        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        onlineSearchKeyword = trimmed

        let target = QQMusicPage.search(kind)
        if navigation.current == target {
            // Already on a search page: the filter stays put and only the
            // results change.
        } else if case .search = navigation.current {
            navigation.replaceTop(with: target)
        } else {
            navigation.push(target)
        }

        guard !trimmed.isEmpty else {
            clearSearchResults(kind: kind)
            return
        }

        switch kind {
        case .songs: await search(trimmed, force: force)
        case .artists: await searchArtists(trimmed, force: force)
        case .albums: await searchAlbums(trimmed, force: force)
        case .playlists: await searchPlaylists(trimmed, force: force)
        }
    }

    /// Clear the current type's results, leaving the other tabs' alone.
    func clearSearchResults(kind: QQMusicSearchKind? = nil) {
        switch kind ?? onlineSearchKind {
        case .songs: clearSearch()
        case .artists: clearArtistSearch()
        case .albums: clearAlbumSearch()
        case .playlists: clearPlaylistSearch()
        }
    }

    /// Placeholder for the toolbar field while browsing online.
    var onlineSearchPlaceholder: String { onlineSearchKind.placeholder }

    // MARK: - Whole-list actions

    /// The track list a page shows.
    ///
    /// One mapping rather than one per view, so the page's rows and the batch
    /// control that acts on them can never disagree about *what* is on screen.
    func tracks(for page: QQMusicPage) -> [QQMusicOnlineTrack] {
        switch page {
        case .likedSongs: return likedSongs
        case .newSongs: return newSongs
        case .recommend: return recommendFeed
        case .search: return searchResults
        case .playlist, .album, .toplist, .radioStation: return playlistTracks
        default: return []
        }
    }

    /// Whether the page's list can be selected for batch download.
    ///
    /// Finite lists with something in them, and nothing else: an endless list has
    /// no "all", so a select-all there would promise what it cannot deliver, and
    /// the index pages (歌单 / 专辑 / 排行榜 / 电台) hold entities rather than
    /// tracks.
    func canSelectTracks(for page: QQMusicPage) -> Bool {
        offersBatchDownload(page) && !tracks(for: page).isEmpty
    }

    /// Whether the page is a track list that batch download applies to at all.
    ///
    /// Deliberately separate from `canSelectTracks`, and deliberately blind to
    /// whether the rows have arrived yet. The toolbar control must be gated on
    /// this one: gating it on `canSelectTracks` made it dim and brighten as each
    /// page's first request landed, so the button appeared to animate away on
    /// arrival and back a moment later. Whether a page offers a selection is a
    /// property of the page, not of a network round trip.
    ///
    /// Not derived from `QQMusicPage.isFiniteList`, which also calls the landing
    /// page finite — there is no list there to act on.
    func offersBatchDownload(_ page: QQMusicPage) -> Bool {
        switch page {
        case .likedSongs, .newSongs, .playlist, .album, .toplist:
            return true
        case .home, .userPlaylists, .likedAlbums, .followedArtists, .toplists,
             .radio, .recommend, .search, .radioStation, .artist:
            return false
        }
    }

    /// One line describing a failure, for the log.
    ///
    /// Every failure path must go through this: recognising rate limiting is
    /// what records the backoff (`rateLimitedUntil`), so a path that logs the
    /// raw error instead would keep hammering an upstream that asked us to stop.
    ///
    /// The wording is user-facing in origin — these strings used to be shown in
    /// a status banner — but there is no notice surface any more, so they are
    /// the log's way of saying the same thing.
    private func noteFailure(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("Ratelimited") || text.contains("风控") || text.contains("安全验证") {
            rateLimitedUntil = Date().addingTimeInterval(30)
            // Scheduled from here rather than from the loaders' entry checks: this
            // is the moment the limit is recorded, and the loader that tripped it
            // is about to return. Relying on the *next* entry to schedule meant a
            // page whose only load had just been limited sat empty with no retry
            // pending at all.
            scheduleRetryAfterBackoff()
            return "访问过于频繁，已暂停请求 30 秒"
        }
        if Self.isLoginRequired(error) {
            return "该接口需要登录 QQ 音乐账号（匿名会话被拒）"
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Come back to the page on screen once the rate-limit backoff expires.
    ///
    /// Every loader returns early while backing off, and nothing used to come
    /// back: a page whose first request was rate-limited stayed empty until the
    /// user left the online surface and re-entered it — pressing 刷新 did nothing
    /// either, because that load returns early for the same reason. Scheduling
    /// one retry turns "empty until you go away and come back" into "a pause".
    ///
    /// Deliberately one retry per backoff window, not a loop: if the upstream is
    /// still refusing, the retry sets a fresh window and schedules the next one,
    /// which works out to at most two requests a minute — the same thing a user
    /// pressing 刷新 repeatedly would do, and far below anything that looks like
    /// abuse.
    private func scheduleRetryAfterBackoff() {
        guard let wait = backoffRemaining() else { return }
        guard backoffRetryTask == nil else { return }
        backoffRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.backoffRetryTask = nil
            await self.loadContent(for: self.navigation.displayed, force: true)
        }
    }

    private func backoffRemaining() -> TimeInterval? {
        guard let until = rateLimitedUntil else { return nil }
        let remaining = until.timeIntervalSinceNow
        if remaining <= 0 {
            rateLimitedUntil = nil
            return nil
        }
        return remaining
    }

    // MARK: - Browsing
    //
    // Every loader keeps whatever content is already on screen when a refresh
    // fails. Clearing the list would look like the content vanished, which is
    // exactly what a transient upstream rejection must not do.

    /// Warm the browse surfaces at launch.
    ///
    /// Runs the same loaders the pages use, so anything already fetched is a
    /// cache hit by the time the user opens the tab. Deliberately sequential:
    /// firing every request at once is the fastest way to trip upstream
    /// throttling, and this is background work that nothing is waiting on.
    ///
    /// The "我的" library is included because those loaders revalidate against
    /// the account; starting them here means the page shows the cached list
    /// immediately instead of waiting for three round-trips on first visit.
    /// The "我的" library loaders, run one at a time.
    ///
    /// `loadUserLibraryIfNeeded` fans these out concurrently, which is right
    /// when a user is waiting on the page. At launch nothing is waiting, so the
    /// gentler order is used instead: this is the moment with the most requests
    /// in flight already, and serial round-trips are what keeps a burst from
    /// being read as abuse.
    private func preloadUserLibrary(force: Bool = false) async {
        // One call now fetches the whole folder, which is what removes the wait
        // when the page is opened and what lets shuffle cover every track.
        await loadLikedSongs(force: force)
        await loadLikedAlbums(force: force)
        await loadUserPlaylists(force: force)
        await loadFollowedArtists(force: force)
    }

    func preloadAtLaunch() async {
        guard AppSettings.shared.qqMusicPreloadOnLaunch else { return }
        Log.info("[QQMusicOnline] preloading at launch", category: .import)
        await loadInitialContentIfNeeded()
        await prefillRecommendFeed()
        await loadNewSongs(region: newSongsRegion)
        await loadRadioStations()
        await preloadUserLibrary()
    }

    /// How many "guess you like" tracks the launch preload aims to have ready.
    ///
    /// The radio hands back about five per round, and rounds must be serial, so
    /// this is a trade against launch time rather than a free setting.
    static let recommendPreloadTarget = 20

    /// Top the recommend feed up to `recommendPreloadTarget` tracks.
    ///
    /// One page of the radio is only about ten tracks, so opening the tab would
    /// otherwise show a short list that grows as you scroll. Extending here
    /// means the list is already a useful length when the page is opened.
    /// Stops on the first round that adds nothing, so a radio that has run dry
    /// does not spin.
    private func prefillRecommendFeed() async {
        var guardCounter = 0
        while recommendFeed.count < Self.recommendPreloadTarget, guardCounter < 4 {
            guardCounter += 1
            let before = recommendFeed.count
            let added = await extendRecommendFeed()
            if added.isEmpty, recommendFeed.count == before { return }
        }
    }

    func loadInitialContentIfNeeded(force: Bool = false) async {
        guard force || (recommendFeed.isEmpty && toplistGroups.isEmpty) else { return }
        async let feed: Void = loadRecommendFeed(force: force)
        async let toplists: Void = loadToplists(force: force)
        _ = await (feed, toplists)
    }

    func loadRecommendFeed(force: Bool = false) async {
        guard !isLoadingFeed else { return }
        if !force, !recommendFeed.isEmpty { return }
        if backoffRemaining() != nil {
            scheduleRetryAfterBackoff()
            return
        }
        isLoadingFeed = true
        defer { isLoadingFeed = false }

        // Show the last known list first, whatever its age — then revalidate
        // below and replace it only if the upstream actually differs. Waiting
        // for the round-trip before showing anything is what made the page look
        // empty on every visit.
        var servedFromCache = false
        if !force, let cached = await cachedTracks(.recommendFeed, key: "default", force: false, allowStale: true) {
            recommendFeed = cached
            seenFeedSongMids = Set(cached.map(\.songMid))
            servedFromCache = true
        }

        do {
            let fetched = try await helper.fetchRecommendFeed()
            if servedFromCache {
                // The radio is a rolling feed, not an enumeration: a fresh call
                // returns the *next* few tracks, not a corrected version of the
                // whole list. Replacing with it would shrink a prefilled list
                // back to six. Merge instead — fresh tracks first, then whatever
                // was already there and is still unseen.
                let freshMids = Set(fetched.map(\.songMid))
                let carried = recommendFeed.filter { !freshMids.contains($0.songMid) }
                let merged = fetched + carried
                if merged.map(\.songMid) != recommendFeed.map(\.songMid) {
                    recommendFeed = merged
                    seenFeedSongMids.formUnion(freshMids)
                }
                await storeTracks(merged, category: .recommendFeed, key: "default")
            } else {
                recommendFeed = fetched
                seenFeedSongMids = Set(fetched.map(\.songMid))
                await storeTracks(fetched, category: .recommendFeed, key: "default")
            }
        } catch {
            // A failure with something already on screen is not worth replacing
            // the list with an error: keep it, and let the log say so (the
            // notice surface that used to say it here is gone — see the header).
            Log.warning("[QQMusicOnline] recommend feed failed: \(noteFailure(error))", category: .import)
        }
    }

    /// Append another page of "guess you like" to the feed.
    ///
    /// Called both when the browse list is scrolled to the bottom and when the
    /// playback queue is running out, so the list a user sees and the list
    /// being played stay the same list. Tracks already shown are filtered out:
    /// the upstream radio repeats songs across calls.
    @discardableResult
    func extendRecommendFeed() async -> [QQMusicOnlineTrack] {
        guard !isExtendingFeed else { return [] }
        if backoffRemaining() != nil {
            scheduleRetryAfterBackoff()
            return []
        }
        isExtendingFeed = true
        defer { isExtendingFeed = false }

        do {
            // Two rounds per page keeps the wait short while still adding
            // enough that scrolling feels productive.
            let fetched = try await helper.fetchRecommendFeed(rounds: 2)
            let fresh = fetched.filter { !seenFeedSongMids.contains($0.songMid) }
            guard !fresh.isEmpty else { return [] }
            seenFeedSongMids.formUnion(fresh.map(\.songMid))
            recommendFeed.append(contentsOf: fresh)
            // Re-store the whole list, not just the new tracks: the cache holds
            // one payload per key, so writing only the additions would leave the
            // preload's extra tracks out of it and the list would shrink back on
            // the next launch.
            await storeTracks(recommendFeed, category: .recommendFeed, key: "default")

            // Keep the playback session in step with what is on screen, so a
            // track added by scrolling is also reachable when playing.
            if !sessionTracks.isEmpty, sessionSupportsPaging {
                sessionTracks.append(contentsOf: fresh)
                // Appended to the end of the playing order, not reshuffled: the
                // user is partway through, and re-shuffling the unplayed
                // remainder would replay tracks and drop others.
                extendPlaybackOrder(with: fresh)
            }
            return fresh
        } catch {
            Log.warning("[QQMusicOnline] feed paging failed: \(noteFailure(error))", category: .import)
            return []
        }
    }

    // MARK: - New songs & playlist search

    /// Load the new-song radio for a region.
    ///
    /// One call returns 65-99 tracks, so this is the better source when a long
    /// queue is wanted, unlike the guess-you-like radio which yields 5.
    func loadNewSongs(region: QQMusicNewSongRegion, force: Bool = false) async {
        if !force, newSongsRegion == region, !newSongs.isEmpty { return }
        if backoffRemaining() != nil {
            scheduleRetryAfterBackoff()
            return
        }
        // A region is a different list, not a refresh of the same one: showing
        // the previous region's tracks under the new region's header while the
        // fetch is in flight was a lie about what is on screen.
        if newSongsRegion != region {
            newSongs = []
        }

        isLoadingNewSongs = true
        newSongsRegion = region
        defer { isLoadingNewSongs = false }

        // Paint first, then replace only when the upstream actually differs.
        // Unlike the radio this *is* an enumeration (one call returns the whole
        // regional list), so a straight comparison is the right replacement rule
        // — and it is what makes a revisit not re-render an identical list.
        var servedFromCache = false
        if !force, let cached = await cachedTracks(.newSongs, key: region.rawValue, force: false, allowStale: true) {
            newSongs = cached
            servedFromCache = true
        }

        do {
            let fetched = try await helper.fetchNewSongs(region: region)
            // Another region may have been picked while this was in flight; its
            // response is the one that belongs on screen.
            guard newSongsRegion == region else { return }
            let changed = fetched.map(\.displayComparisonKey) != newSongs.map(\.displayComparisonKey)
            if changed || !servedFromCache {
                newSongs = fetched
            }
            await storeTracks(fetched, category: .newSongs, key: region.rawValue)
        } catch {
            Log.warning("[QQMusicOnline] new songs failed: \(noteFailure(error))", category: .import)
        }
    }

    /// Search playlists by keyword — the category/mood browse path.
    func searchPlaylists(_ keyword: String, force: Bool = false) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchedPlaylists = []
            return
        }
        if backoffRemaining() != nil {
            scheduleRetryAfterBackoff()
            return
        }
        // Newest wins, for the same reason as the artist search.
        playlistSearchGeneration &+= 1
        let generation = playlistSearchGeneration
        isSearchingPlaylists = true
        defer {
            if generation == playlistSearchGeneration { isSearchingPlaylists = false }
        }
        do {
            if let cached = await cachedPlaylists(.playlistSearch, key: trimmed, force: force) {
                guard generation == playlistSearchGeneration else { return }
                searchedPlaylists = cached
                return
            }
            let fetched = try await helper.searchPlaylists(keyword: trimmed, limit: 30)
            await storePlaylists(fetched, category: .playlistSearch, key: trimmed)
            guard generation == playlistSearchGeneration else { return }
            searchedPlaylists = fetched
        } catch {
            // Keep what is displayed; a failed search is not an empty result.
            Log.warning("[QQMusicOnline] playlist search failed: \(noteFailure(error))", category: .import)
        }
    }

    func clearPlaylistSearch() {
        searchedPlaylists = []
    }

    // MARK: - The account's own lists
    //
    // 我喜欢 / 收藏歌单 / 收藏专辑, plus the writes that change them. The
    // like/unlike write speaks the playlist-membership endpoint; `toggleLike` is
    // the only write in the whole surface.

    /// Load 我喜欢.
    ///
    /// The shape every account list here follows, because these lists change
    /// rarely and only slightly:
    ///
    ///   1. paint what the cache holds — the **complete** list, written as one
    ///      payload, so the page is complete and instant on every visit;
    ///   2. fetch the complete list from upstream;
    ///   3. swap it in as one replacement, and only if it actually differs.
    ///
    /// Never page by page into what is on screen. The folder's `total` counts
    /// rows and a few rows carry no playable track, so "I hold every row" is not
    /// a completion signal either — the complete fetch is what decides.
    func loadLikedSongs(force: Bool = false) async {
        guard !isLoadingLikedSongs else { return }
        if !force, !likedSongs.isEmpty { return }
        // Claimed before the first `await`: with the assignment after the cache
        // read, two callers could both pass the guard above and the first one to
        // finish would clear the flag the second had just set — so the page fell
        // back to its empty state while a fetch was still running.
        if backoffRemaining() != nil {
            // These three used to keep asking while rate-limited — the account
            // lists are the read path most likely to trip it, and they were the
            // ones with no check.
            scheduleRetryAfterBackoff()
            return
        }
        isLoadingLikedSongs = true
        defer { isLoadingLikedSongs = false }

        // 1. paint. Nothing on screen yet, so anything the cache holds is an
        // improvement — and it holds the whole folder, which is what makes the
        // page complete before the network answers.
        if likedSongs.isEmpty, let cached = await cachedLikedSongs() {
            likedSongs = cached.tracks
            likedSongsTotal = cached.total
        }

        do {
            // 2. the whole folder.
            let complete = try await fetchCompleteLikedSongs()
            // Compared by everything the row shows (see
            // `displayComparisonKey`), not by song id: a fix to how a cover, an
            // album id or a singer list is produced has to be able to supersede
            // what is on screen rather than being dismissed as "same tracks".
            let changed = complete.tracks.map(\.displayComparisonKey)
                != likedSongs.map(\.displayComparisonKey)
            likedSongsTotal = max(complete.total, complete.tracks.count)
            // This response enumerates the folder, so it is the cheapest source of
            // the liked-mid set the hearts read: one request answers both.
            likedSongMids = Set(complete.tracks.map(\.songMid))
            guard changed else { return }
            // 3. one swap.
            likedSongs = complete.tracks
            await cacheLikedSongs(complete)
        } catch {
            Log.warning("[QQMusicOnline] liked songs failed: \(noteFailure(error))", category: .import)
        }
    }

    /// The whole 我喜欢 folder, web-first with a helper fallback.
    ///
    /// The whole folder, page by page.
    ///
    /// `total` counts rows rather than playable tracks, so the loop cannot stop
    /// on `count == total` alone: it stops when a page adds nothing, which is
    /// the same signal the paging loader uses.
    private func fetchCompleteLikedSongs() async throws -> QQMusicLikedSongs {
        var tracks: [QQMusicOnlineTrack] = []
        var seen: Set<String> = []
        var total = 0
        var page = 1
        while page <= Self.maxLikedPages {
            let payload = try await fetchLikedSongs(page: page, limit: 100)
            total = max(total, payload.total)
            let fresh = payload.tracks.filter { seen.insert($0.songMid).inserted }
            tracks.append(contentsOf: fresh)
            // A page that adds nothing is the real completion signal: `total`
            // counts rows, so it can stay above the number of playable tracks.
            if fresh.isEmpty || tracks.count >= total { break }
            page += 1
        }
        return QQMusicLikedSongs(title: "我喜欢", total: max(total, tracks.count), tracks: tracks)
    }

    /// How many pages the helper fallback will walk. A bound, not a target: 20
    /// pages is 2000 tracks, and a folder larger than that is better served by
    /// the batched web call this is only a fallback for.
    private static let maxLikedPages = 20

    /// Apply a like or unlike to the loaded list without discarding it.
    ///
    /// Unlike needs only a removal. A like needs the track's row, which comes
    /// from whatever list it was liked from; when that row is not at hand the
    /// list is left for the next refresh to pick up rather than being cleared.
    func applyLikeChange(songMid: String, liked: Bool) {
        if !liked {
            likedSongs.removeAll { $0.songMid == songMid }
            likedSongsTotal = max(0, likedSongsTotal - 1)
        } else if let row = pendingLikeRow[songMid] {
            // Insert at the top: the folder is newest-first upstream, so that is
            // where a fresh like appears.
            likedSongs.insert(row, at: 0)
            likedSongsTotal += 1
            pendingLikeRow[songMid] = nil
        } else {
            // No row available (liked from a place that only knows the mid).
            // Leave the list intact and let the next visit reconcile; a cleared
            // list would be a worse answer than a momentarily stale one.
            likedSongsTotal = max(likedSongsTotal, likedSongs.count)
        }
        // Rewrite the cache from the adjusted list, so the change survives a
        // restart without a refetch.
        let payload = QQMusicLikedSongs(title: "我喜欢", total: likedSongsTotal, tracks: likedSongs)
        Task { await self.cacheLikedSongs(payload) }
    }

    /// The cached 我喜欢, whatever its age.
    ///
    /// Deliberately `staleCatalog`, not `catalog`: this is the "show something
    /// now" path and the caller revalidates immediately afterwards. TTL-gating it
    /// (10 minutes) meant a revisit almost never found the cache, so every visit
    /// waited on a round trip and the cache bought nothing.
    private func cachedLikedSongs() async -> QQMusicLikedSongs? {
        guard let store = cacheStore,
              let data = await store.staleCatalog(.likedSongs, key: "all"),
              let decoded = try? JSONDecoder().decode(QQMusicLikedSongs.self, from: data),
              !decoded.tracks.isEmpty
        else { return nil }
        return decoded
    }

    /// The key is `all` rather than a page number: what is stored is the whole
    /// folder, and calling it `page-1` is what invited the paging code that used
    /// to shrink a complete list back to its first hundred.
    private func cacheLikedSongs(_ payload: QQMusicLikedSongs) async {
        guard let store = cacheStore, !payload.tracks.isEmpty,
              let data = try? JSONEncoder().encode(payload) else { return }
        await store.storeCatalog(data, category: .likedSongs, key: "all")
    }

    /// Load favorited albums (resolved to names and covers by the helper).
    func loadLikedAlbums(force: Bool = false) async {
        guard !isLoadingLikedAlbums else { return }
        if !force, !likedAlbums.isEmpty { return }
        // Claimed before the cache read, for the reason in `loadLikedSongs`.
        var servedFromCache = false
        if let cached = await cachedAlbums(force: force) {
            likedAlbums = cached
            servedFromCache = true
        }

        isLoadingLikedAlbums = true
        defer { isLoadingLikedAlbums = false }
        do {
            let albums = try await fetchLikedAlbums()
            await cacheAlbums(albums)
            // Only replace what is on screen when the list actually differs —
            // the albums set changes rarely, and swapping it needlessly makes
            // covers flicker. The cover is included so a change in how covers
            // are derived is not mistaken for "nothing changed" (see the
            // playlist comparison key for the same reasoning).
            if !servedFromCache || albums.map(Self.albumComparisonKey) != likedAlbums.map(Self.albumComparisonKey) {
                likedAlbums = albums
            }
        } catch {
            Log.warning("[QQMusicOnline] liked albums failed: \(noteFailure(error))", category: .import)
        }
    }

    /// Identity of everything about a shown album that affects rendering.
    private static func albumComparisonKey(_ album: QQMusicOnlineAlbum) -> String {
        "\(album.identity):\(album.coverURL ?? "")"
    }

    private func cachedAlbums(force: Bool) async -> [QQMusicOnlineAlbum]? {
        guard !force, let store = cacheStore,
              let data = await store.staleCatalog(.userLibrary, key: "albums"),
              let decoded = try? JSONDecoder().decode([QQMusicOnlineAlbum].self, from: data),
              !decoded.isEmpty
        else { return nil }
        return decoded
    }

    private func cacheAlbums(_ albums: [QQMusicOnlineAlbum]) async {
        guard let store = cacheStore, !albums.isEmpty,
              let data = try? JSONEncoder().encode(albums) else { return }
        await store.storeCatalog(data, category: .userLibrary, key: "albums")
    }

    /// Load the account's own playlists.
    func loadUserPlaylists(force: Bool = false) async {
        guard !isLoadingUserPlaylists else { return }
        if !force, !userPlaylists.isEmpty { return }
        // Claimed before the cache read, for the reason in `loadLikedSongs`.
        var servedFromCache = false
        if let cached = await cachedUserPlaylists(force: force) {
            userPlaylists = cached
            servedFromCache = true
        }

        isLoadingUserPlaylists = true
        defer { isLoadingUserPlaylists = false }
        do {
            let playlists = try await fetchUserPlaylists()
            await cacheUserPlaylists(playlists)
            // Compare by id and track count: a playlist gaining a track should
            // refresh, but an unchanged list should not be re-rendered.
            //
            // The cover is part of the comparison too. Leaving it out meant a
            // cached list kept its stored cover URLs forever, because ids and
            // counts never change — so a fix to how covers are derived (such as
            // the http-to-https upgrade) could never reach the screen. Anything
            // that decides what is displayed has to take part in "did it change".
            let changed = playlists.map(Self.playlistComparisonKey)
                != userPlaylists.map(Self.playlistComparisonKey)
            if !servedFromCache || changed {
                userPlaylists = playlists
            }
        } catch {
            Log.warning("[QQMusicOnline] user playlists failed: \(noteFailure(error))", category: .import)
        }
    }

    /// Identity of everything about a shown playlist that affects rendering.
    ///
    /// Used to decide whether a cached list needs replacing. Cover URLs belong
    /// here: they are derived, so a change in how they are produced has to be
    /// able to supersede what is already on screen and in the cache.
    private static func playlistComparisonKey(_ playlist: QQMusicOnlinePlaylist) -> String {
        "\(playlist.id):\(playlist.songCount ?? -1):\(playlist.coverURL ?? "")"
    }

    private func cachedUserPlaylists(force: Bool) async -> [QQMusicOnlinePlaylist]? {
        guard !force, let store = cacheStore,
              let data = await store.staleCatalog(.userLibrary, key: "playlists"),
              let decoded = try? JSONDecoder().decode([QQMusicOnlinePlaylist].self, from: data),
              !decoded.isEmpty
        else { return nil }
        return decoded
    }

    private func cacheUserPlaylists(_ playlists: [QQMusicOnlinePlaylist]) async {
        guard let store = cacheStore, !playlists.isEmpty,
              let data = try? JSONEncoder().encode(playlists) else { return }
        await store.storeCatalog(data, category: .userLibrary, key: "playlists")
    }

    /// Load everything the "我的" section shows.
    func loadUserLibraryIfNeeded(force: Bool = false) async {
        async let liked: Void = loadLikedSongs(force: force)
        async let albums: Void = loadLikedAlbums(force: force)
        async let playlists: Void = loadUserPlaylists(force: force)
        _ = await (liked, albums, playlists)
    }

    /// Make sure the liked-mid set is populated, so hearts are accurate.
    ///
    /// Fill the liked-mid set the hearts read, once.
    ///
    /// Fired when the browse view appears rather than at launch: the browse lists
    /// are where the hearts are, and a row's heart is wrong until this has run.
    /// It asks for the whole folder for the same reason `loadLikedSongs` does —
    /// the folder's `total` counts rows, so a first page does not tell us whether
    /// it is complete — and the set is what makes a heart correct for a track
    /// that is not on screen yet.
    ///
    /// A failure is not surfaced: this is accuracy work for a cosmetic default,
    /// and there is no notice surface any more (see the file header).
    func ensureLikedSongMidsIfNeeded(force: Bool = false) async {
        guard force || likedSongMids.isEmpty else { return }
        guard !isRefreshingLikedMids else { return }
        isRefreshingLikedMids = true
        defer { isRefreshingLikedMids = false }
        do {
            let complete = try await fetchCompleteLikedSongs()
            likedSongMids = Set(complete.tracks.map(\.songMid))
        } catch {
            Log.warning("[QQMusicOnline] liked mids seed failed: \(noteFailure(error))", category: .import)
        }
    }

    /// Whether an error means the user must log in, rather than a real failure.
    ///
    /// The upstream reports this in several shapes and none of them is
    /// self-describing: the CGI codes below are what the favourites and
    /// playlists endpoints return to an anonymous session. Matching only on
    /// Chinese login wording meant a logged-out user got "加载失败" and no
    /// indication that signing in would fix it.
    private static func isLoginRequired(_ error: Error) -> Bool {
        let text = String(describing: error)
        return text.contains("需要登录")
            || text.contains("登录凭证已过期")
            || text.contains("LoginExpired")
            // CGI 10004: not logged in / no permission for this endpoint.
            || text.contains("10004")
            // CGI 80000: the folder endpoints' rejection for anonymous callers.
            || text.contains("80000")
    }

    // MARK: - Radio

    /// Load the grouped station list.
    func loadRadioStations(force: Bool = false) async {
        guard !isLoadingRadioStations else { return }
        if !force, !radioGroups.isEmpty { return }
        if backoffRemaining() != nil {
            scheduleRetryAfterBackoff()
            return
        }
        isLoadingRadioStations = true
        defer { isLoadingRadioStations = false }
        do {
            if !force, let store = cacheStore,
               let data = await store.catalog(.radioStations, key: "default"),
               let cached = try? JSONDecoder().decode([QQMusicRadioGroup].self, from: data),
               !cached.isEmpty {
                radioGroups = cached
                return
            }
            let groups = try await helper.fetchRadioStations()
            if let store = cacheStore, let data = try? JSONEncoder().encode(groups) {
                await store.storeCatalog(data, category: .radioStations, key: "default")
            }
            radioGroups = groups
        } catch {
            Log.warning("[QQMusicOnline] radio stations failed: \(noteFailure(error))", category: .import)
        }
    }

    /// Open a station and load its first batch of tracks.
    ///
    /// No in-flight guard: this is the *open* path, so a second open must win
    /// over the first rather than be dropped.
    func openRadioStation(_ station: QQMusicRadioStation) async {
        // A station is a list too, so the same isolation rule applies: whatever
        // is on screen must be something else's only while that something else is
        // still loading. Switching to a station from a playlist, or from another
        // station, clears first; re-opening the station already showing keeps its
        // rows (a refresh), which is the same distinction `openList` makes.
        let isSwitch = openedList != nil || activeRadioStationID != station.id
        if isSwitch {
            playlistTracks = []
        }
        // A station owns the shared list now, so nothing may page a playlist into
        // it (and `loadMoreRadioTracks` is what runs instead).
        openedList = nil
        listGeneration &+= 1
        isLoadingRadioTracks = true
        defer { isLoadingRadioTracks = false }
        do {
            playlistTracks = try await helper.fetchRadioTracks(stationID: station.id, limit: 30, firstPlay: true)
            activeRadioStationID = station.id
        } catch {
            // Keep whatever is on screen: a station that failed to open must not
            // blank the page (and the notice surface that used to say so is gone
            // — see the file header).
            Log.warning("[QQMusicOnline] radio tracks failed: \(noteFailure(error))", category: .import)
        }
    }

    /// Continue the current station's rotation.
    ///
    /// A radio is endless rather than paged, so this appends the next batch
    /// without restarting, de-duplicating against what is already listed.
    func loadMoreRadioTracks() async {
        guard let stationID = activeRadioStationID, !isLoadingRadioTracks else { return }
        isLoadingRadioTracks = true
        defer { isLoadingRadioTracks = false }
        do {
            let tracks = try await helper.fetchRadioTracks(stationID: stationID, limit: 20, firstPlay: false)
            let known = Set(playlistTracks.map(\.songMid))
            let fresh = tracks.filter { !known.contains($0.songMid) }
            guard !fresh.isEmpty else { return }
            playlistTracks.append(contentsOf: fresh)
        } catch {
            Log.warning("[QQMusicOnline] radio paging failed: \(noteFailure(error))", category: .import)
        }
    }

    /// Drop the station identity, so nothing pages a station's rotation for a
    /// playlist that is now open.
    ///
    /// Deliberately does **not** clear `playlistTracks`: every list here shares
    /// that array, and emptying it on the way to loading another one blanked the
    /// page for the duration of the fetch. The incoming load replaces it.
    func closeRadioStation() {
        activeRadioStationID = nil
    }

    // MARK: - Artist search & detail

    func searchArtists(_ keyword: String, force: Bool = false) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchedArtists = []
            return
        }
        if backoffRemaining() != nil {
            scheduleRetryAfterBackoff()
            return
        }
        // Newest wins, like `search`: without this, a superseded artist search
        // could land last and replace the results of the query the user is on.
        artistSearchGeneration &+= 1
        let generation = artistSearchGeneration
        isSearchingArtists = true
        defer {
            if generation == artistSearchGeneration { isSearchingArtists = false }
        }
        do {
            if !force,
               let store = cacheStore,
               let data = await store.catalog(.artistSearch, key: trimmed),
               let cached = try? JSONDecoder().decode([QQMusicOnlineArtist].self, from: data),
               !cached.isEmpty {
                guard generation == artistSearchGeneration else { return }
                searchedArtists = cached
                return
            }
            let artists = try await helper.searchArtists(keyword: trimmed, limit: 30)
            if let store = cacheStore, let data = try? JSONEncoder().encode(artists) {
                await store.storeCatalog(data, category: .artistSearch, key: trimmed)
            }
            guard generation == artistSearchGeneration else { return }
            searchedArtists = artists
        } catch {
            Log.warning("[QQMusicOnline] artist search failed: \(noteFailure(error))", category: .import)
        }
    }

    func clearArtistSearch() {
        searchedArtists = []
    }

    /// Search albums by keyword.
    ///
    /// Shaped after the artist search rather than the song one: the results are
    /// whole entities, cached as one payload per query, and a superseded query
    /// must not land on top of the one the user is looking at.
    func searchAlbums(_ keyword: String, force: Bool = false) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchedAlbums = []
            return
        }
        if backoffRemaining() != nil {
            scheduleRetryAfterBackoff()
            return
        }
        albumSearchGeneration &+= 1
        let generation = albumSearchGeneration
        isSearchingAlbums = true
        defer {
            if generation == albumSearchGeneration { isSearchingAlbums = false }
        }
        do {
            if !force,
               let store = cacheStore,
               let data = await store.catalog(.albumSearch, key: trimmed),
               let cached = try? JSONDecoder().decode([QQMusicOnlineAlbum].self, from: data),
               !cached.isEmpty {
                guard generation == albumSearchGeneration else { return }
                searchedAlbums = cached
                return
            }
            let albums = try await helper.searchAlbums(keyword: trimmed, limit: 30)
            if let store = cacheStore, let data = try? JSONEncoder().encode(albums) {
                await store.storeCatalog(data, category: .albumSearch, key: trimmed)
            }
            guard generation == albumSearchGeneration else { return }
            searchedAlbums = albums
        } catch {
            Log.warning("[QQMusicOnline] album search failed: \(noteFailure(error))", category: .import)
        }
    }

    func clearAlbumSearch() {
        searchedAlbums = []
    }

    /// Sort order for an artist's songs. The upstream ignores ordering
    /// parameters, so `latest` is computed from album release dates.
    nonisolated enum ArtistSongSort: String, Sendable {
        case hot
        case latest
    }

    func artistSongs(
        singerMid: String,
        sort: ArtistSongSort,
        page: Int = 1
    ) async throws -> [QQMusicOnlineTrack] {
        try await helper.fetchArtistSongs(
            singerMid: singerMid,
            limit: 50,
            page: page,
            sort: sort.rawValue
        )
    }

    /// The artist's own profile: name, portrait, counts and prose.
    ///
    /// One read, through `fetch_artist_detail`. The artist page used to take its
    /// portrait and counts from whatever the *navigating* row happened to carry —
    /// which works from 关注的歌手 (the row is a full artist) and leaves the header
    /// blank when the page is opened from a track row, where only a mid and a name
    /// exist. A page must not depend on which door the user came through.
    func artistProfile(singerMid: String) async -> QQMusicMetadataDetail? {
        try? await helper.fetchArtistDetail(name: nil, singerMid: singerMid)
    }

    /// Artist biography, or nil when upstream has none.
    func artistBiography(singerMid: String) async -> String? {
        let detail = try? await helper.fetchArtistDetail(singerMid: singerMid)
        let text = detail?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    /// Sort order for an artist's albums, hot or by release date. The same
    /// enumeration as the songs': "热门 / 最新" means the same thing in both tabs,
    /// and the upstream ignores ordering parameters in both, so the helper
    /// computes `latest`.
    func artistAlbums(
        singerMid: String,
        sort: ArtistSongSort = .hot
    ) async throws -> [QQMusicOnlineAlbum] {
        try await helper.fetchArtistAlbums(
            singerMid: singerMid,
            limit: 100,
            page: 1,
            sort: sort == .latest ? "latest" : "hot"
        )
    }

    func albumTracks(albumID: Int) async throws -> [QQMusicOnlineTrack] {
        try await helper.fetchAlbumTracks(albumID: albumID, limit: 200)
    }

    // MARK: - Like / unlike

    /// Whether the given library track is in the account's favorites.
    func isLiked(_ track: Track) -> Bool {
        guard let mid = track.qqMusicSongMid else { return false }
        return isLiked(songMid: mid)
    }

    func isLikePending(_ track: Track) -> Bool {
        guard let mid = track.qqMusicSongMid else { return false }
        return isLikePending(songMid: mid)
    }

    /// Whether an online track — one not yet in the library — is favorited.
    ///
    /// The browse lists hold `QQMusicOnlineTrack`, which has no local file, so
    /// the library `Track` overload cannot be used there. The upstream write
    /// endpoint only ever needed the song mid anyway.
    func isLiked(songMid: String) -> Bool {
        !songMid.isEmpty && likedSongMids.contains(songMid)
    }

    func isLikePending(songMid: String) -> Bool {
        !songMid.isEmpty && pendingLikeSongMids.contains(songMid)
    }

    /// Walk the pages after the first so the liked-mid set covers the folder.
    /// Toggle the favorite state of a library track.
    @discardableResult
    func toggleLike(_ track: Track) async -> Bool {
        guard let mid = track.qqMusicSongMid, !mid.isEmpty else { return false }
        return await toggleLike(songMid: mid)
    }

    /// Toggle the favorite state of an online track by its song mid.
    ///
    /// The upstream applies the change asynchronously, so the local set is
    /// updated optimistically and rolled back if the write is rejected.
    @discardableResult
    func toggleLike(songMid mid: String, row: QQMusicOnlineTrack? = nil) async -> Bool {
        guard !mid.isEmpty else { return false }
        // Remember where the like came from so the list can be adjusted in
        // place. Only meaningful for a like; an unlike needs no row.
        if let row { pendingLikeRow[mid] = row }
        guard !pendingLikeSongMids.contains(mid) else { return likedSongMids.contains(mid) }

        let target = !likedSongMids.contains(mid)
        pendingLikeSongMids.insert(mid)
        defer { pendingLikeSongMids.remove(mid) }

        do {
            let result = try await helper.setLiked(songMid: mid, liked: target)
            guard result.ok != false else {
                // The heart stays as it was, which is the whole feedback: there is
                // no notice surface for this any more (see the note at the top of
                // the file).
                Log.warning("[QQMusicOnline] like toggle rejected for \(mid)", category: .import)
                return likedSongMids.contains(mid)
            }
            if target {
                likedSongMids.insert(mid)
            } else {
                likedSongMids.remove(mid)
            }
            // Adjust the list in place rather than discarding it.
            //
            // This used to delete the cached page and clear the list, so the
            // next visit refetched hundreds of tracks to reflect a one-row
            // change — and the page visibly emptied in the meantime. A single
            // like or unlike changes exactly one entry, so it is applied to the
            // loaded list directly and the cache is rewritten from it.
            applyLikeChange(songMid: mid, liked: target)
            return target
        } catch {
            Log.warning("[QQMusicOnline] like toggle failed: \(error)", category: .import)
            return likedSongMids.contains(mid)
        }
    }

    // MARK: - Cache helpers

    /// Read a cached track list, or nil when absent/expired/undecodable.
    ///
    /// A cache entry that no longer decodes is treated as a miss, so a payload
    /// shape change cannot wedge a page on stale data.
    private func cachedTracks(
        _ category: QQMusicCacheCategory,
        key: String,
        force: Bool,
        allowStale: Bool = false
    ) async -> [QQMusicOnlineTrack]? {
        guard !force, let store = cacheStore else { return nil }
        // `allowStale` is the stale-while-revalidate path: show the last known
        // list immediately, then let the caller refresh it. Without it a short
        // TTL means the entry is deleted before it can ever be displayed.
        let data = allowStale
            ? await store.staleCatalog(category, key: key)
            : await store.catalog(category, key: key)
        guard let data else { return nil }
        guard let tracks = try? JSONDecoder().decode([QQMusicOnlineTrack].self, from: data) else {
            await store.invalidateCatalog(category, key: key)
            return nil
        }
        return tracks.isEmpty ? nil : tracks
    }

    private func storeTracks(
        _ tracks: [QQMusicOnlineTrack],
        category: QQMusicCacheCategory,
        key: String
    ) async {
        guard let store = cacheStore, !tracks.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        await store.storeCatalog(data, category: category, key: key)
    }

    private func cachedPlaylists(
        _ category: QQMusicCacheCategory,
        key: String,
        force: Bool
    ) async -> [QQMusicOnlinePlaylist]? {
        guard !force, let store = cacheStore else { return nil }
        guard let data = await store.catalog(category, key: key) else { return nil }
        guard let items = try? JSONDecoder().decode([QQMusicOnlinePlaylist].self, from: data) else {
            await store.invalidateCatalog(category, key: key)
            return nil
        }
        return items.isEmpty ? nil : items
    }

    private func storePlaylists(
        _ playlists: [QQMusicOnlinePlaylist],
        category: QQMusicCacheCategory,
        key: String
    ) async {
        guard let store = cacheStore, !playlists.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        await store.storeCatalog(data, category: category, key: key)
    }

    private func cachedToplists(_ key: String, force: Bool) async -> [QQMusicToplistGroup]? {
        guard !force, let store = cacheStore else { return nil }
        guard let data = await store.catalog(.toplists, key: key) else { return nil }
        guard let groups = try? JSONDecoder().decode([QQMusicToplistGroup].self, from: data) else {
            await store.invalidateCatalog(.toplists, key: key)
            return nil
        }
        return groups.isEmpty ? nil : groups
    }

    func loadToplists(force: Bool = false) async {
        guard !isLoadingToplists else { return }
        if !force, !toplistGroups.isEmpty { return }
        if backoffRemaining() != nil {
            scheduleRetryAfterBackoff()
            return
        }
        isLoadingToplists = true
        defer { isLoadingToplists = false }
        do {
            if let cached = await cachedToplists("default", force: force) {
                toplistGroups = cached
                return
            }
            let fetched = try await helper.fetchToplistCategories()
            if let store = cacheStore,
               let data = try? JSONEncoder().encode(fetched) {
                await store.storeCatalog(data, category: .toplists, key: "default")
            }
            toplistGroups = fetched
        } catch {
            Log.warning("[QQMusicOnline] toplists failed: \(noteFailure(error))", category: .import)
        }
    }

    func search(_ keyword: String, force: Bool = false) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        if backoffRemaining() != nil {
            scheduleRetryAfterBackoff()
            return
        }
        // The newest query wins rather than being dropped: an early return here
        // would leave the previous query's results on screen with no indication
        // that the new one never ran. Only the latest may write the array and the
        // loading flag, which is why both are guarded by the generation.
        searchGeneration &+= 1
        let generation = searchGeneration
        isSearching = true
        defer {
            if generation == searchGeneration { isSearching = false }
        }
        do {
            if let cached = await cachedTracks(.search, key: trimmed, force: force) {
                guard generation == searchGeneration else { return }
                searchResults = cached
                return
            }
            let fetched = try await helper.searchSongs(keyword: trimmed, limit: 30)
            await storeTracks(fetched, category: .search, key: trimmed)
            guard generation == searchGeneration else { return }
            searchResults = fetched
        } catch {
            // Keep the previous results; the new query simply did not land.
            Log.warning("[QQMusicOnline] search failed: \(noteFailure(error))", category: .import)
        }
    }

    func clearSearch() {
        searchResults = []
    }

    // MARK: - One list at a time (playlist / album / ranking)
    //
    // All three are one shared track list, so they share one loader and one set
    // of "which list is open" fields. Keeping them in step is not tidiness:
    // `hasMorePlaylistTracks` reads the open id, so an album opened after a
    // playlist used to page the *playlist's* next batch into the album's list.

    /// Which list is open, so paging asks the right endpoint.
    private enum OpenList: Equatable {
        case playlist(id: Int)
        case toplist(id: Int)
        case album(id: Int)

        var cacheKey: String {
            switch self {
            case .playlist(let id): return "songlist-\(id)"
            case .toplist(let id): return "toplist-\(id)"
            case .album(let id): return "album-\(id)"
            }
        }
    }

    func openPlaylist(id: Int, force: Bool = false) async {
        await openList(.playlist(id: id), force: force)
    }

    func openToplist(id: Int, force: Bool = false) async {
        await openList(.toplist(id: id), force: force)
    }

    /// Open a favorited album as a track list.
    func openAlbum(id: Int, force: Bool = false) async {
        await openList(.album(id: id), force: force)
    }

    /// Open one of the shared track lists.
    ///
    /// The cache policy the account lists use, applied to a list that can be
    /// longer than one page:
    ///
    ///   1. paint whatever the cache holds (a previously paged-in copy, so it can
    ///      already be the complete list);
    ///   2. fetch the first page **through the same channel paging uses**, which
    ///      also reports the list's own total;
    ///   3. if that page matches the cache and our length matches the total,
    ///      nothing changed — leave it alone;
    ///   4. otherwise fetch the remaining pages *before* touching what is on
    ///      screen, then swap the complete list in at once.
    ///
    /// Step 4 is what makes a refresh honest: replacing with the first page would
    /// shrink a 400-track playlist to 100 and let it grow back.
    private func openList(_ list: OpenList, force: Bool = false) async {
        // A station's rotation is a different kind of list: its id drives
        // "load more" for the station, which must not fire here.
        closeRadioStation()

        // Switching lists — as opposed to refreshing the same one — clears what is
        // on screen before anything else. Leaving it showed the *previous*
        // playlist's rows under the new playlist's header until the fetch landed,
        // which reads as "this page is showing someone else's content". A refresh
        // of the same list keeps its rows: they are not wrong, and blanking a page
        // the user is already on is worse than a moment of stale data.
        let isSwitch = openedList != list
        openedList = list
        openedPlaylistTotal = 0
        listGeneration &+= 1
        let generation = listGeneration
        // The flag counts loads, so a superseded one finishing cannot clear the
        // spinner of the load that replaced it.
        listLoadsInFlight += 1
        defer { listLoadsInFlight -= 1 }

        if backoffRemaining() != nil {
            // Checked before clearing: a rate-limited open must not empty the page
            // it was going to replace. The retry below opens it for real.
            scheduleRetryAfterBackoff()
            return
        }

        if isSwitch {
            playlistTracks = []
        }

        // 1. paint
        let cacheKey = list.cacheKey
        if let cached = await cachedTracks(.playlistTracks, key: cacheKey, force: force) {
            playlistTracks = cached
        }

        do {
            // 2. the first page, plus the total.
            let first = try await fetchListPage(list, offset: 0, limit: Self.listPageSize)
            guard generation == listGeneration else { return }
            openedPlaylistTotal = first.total

            // 3. unchanged? The head matching, and our length accounting for the
            // whole list, is the strongest signal available without fetching it.
            //
            // Not on a refresh: "the first page looks the same" is not what the
            // user asked when they pressed 刷新, and a change further down the
            // list is exactly what this check cannot see. A force always fetches
            // the complete list, so the button always means something.
            let unchanged = !force
                && first.tracks.map(\.displayComparisonKey)
                    == playlistTracks.prefix(first.tracks.count).map(\.displayComparisonKey)
                && (first.total <= 0 || playlistTracks.count == first.total)
            guard !unchanged else { return }

            // 4. the complete list, off screen, then one swap.
            let complete = try await fetchCompleteList(list, first: first, generation: generation)
            guard generation == listGeneration else { return }
            playlistTracks = complete
            await storeTracks(complete, category: .playlistTracks, key: cacheKey)
        } catch {
            // Deliberately keep `playlistTracks` as-is. A failed open must not
            // erase a list the user is already looking at.
            Log.warning("[QQMusicOnline] list open failed: \(noteFailure(error))", category: .import)
        }
    }

    /// Page size for the shared list. The upstream caps a page here, so this is
    /// its number rather than a preference.
    private static let listPageSize = 100

    /// One page of the open list.
    ///
    /// A ranking takes an offset and reports its own size, so it pages exactly
    /// like the others; an earlier helper could only ever answer the first
    /// batch, which is why this used to be a special case.
    private func fetchListPage(_ list: OpenList, offset: Int, limit: Int) async throws -> (tracks: [QQMusicOnlineTrack], total: Int) {
        switch list {
        case .playlist(let id):
            return try await fetchPlaylistPage(songlistId: id, offset: offset, limit: limit)

        case .toplist(let id):
            let page = try await helper.fetchToplistTracksPage(topId: id, offset: offset, limit: limit)
            return (page.tracks, page.total ?? (offset + page.tracks.count))

        case .album(let id):
            // One helper call returns the whole album; albums long enough to need
            // a second page are a corner the helper route cannot express, so the
            // count it returns is the count we have.
            let tracks = try await helper.fetchAlbumTracks(albumID: id, limit: limit)
            return (tracks, tracks.count)
        }
    }

    /// Walk the remaining pages so the caller can swap in one complete list.
    ///
    /// Bounded, and every pass must add something, so a mis-reported total cannot
    /// spin: a list whose tail the upstream refuses to serve simply stops here.
    private func fetchCompleteList(
        _ list: OpenList,
        first: (tracks: [QQMusicOnlineTrack], total: Int),
        generation: UInt64
    ) async throws -> [QQMusicOnlineTrack] {
        var all = first.tracks
        var seen = Set(all.map(\.songMid))
        guard first.total > all.count else { return all }
        while all.count < first.total, all.count < Self.maxListTracks, !Task.isCancelled {
            let page = try await fetchListPage(list, offset: all.count, limit: Self.listPageSize)
            let fresh = page.tracks.filter { seen.insert($0.songMid).inserted }
            guard !fresh.isEmpty else { break }
            all.append(contentsOf: fresh)
            // A refresh that was superseded by the user opening another list must
            // not keep fetching: the caller drops the result anyway.
            guard generation == listGeneration else { return all }
        }
        return all
    }

    /// Ceiling on how far the complete fetch will page. A frame around a broken
    /// total rather than a limit anyone should meet: 20 pages of 100.
    private static let maxListTracks = 2000

    /// Load the next page of the open list, for a list longer than what the open
    /// fetch pulled (a radio-style list that keeps growing, or a huge playlist
    /// opened before the complete fetch finished).
    func loadMorePlaylistTracks() async {
        guard !isLoadingMorePlaylistTracks, hasMorePlaylistTracks, let list = openedList else { return }
        isLoadingMorePlaylistTracks = true
        defer { isLoadingMorePlaylistTracks = false }

        let generation = listGeneration
        let offset = playlistTracks.count
        do {
            let page = try await fetchListPage(list, offset: offset, limit: Self.listPageSize)
            // The user may have opened another list while this was in flight; a
            // stale page appended now would mix two lists together.
            guard generation == listGeneration else { return }
            openedPlaylistTotal = page.total
            let known = Set(playlistTracks.map(\.songMid))
            let fresh = page.tracks.filter { !known.contains($0.songMid) }
            guard !fresh.isEmpty else { return }
            playlistTracks.append(contentsOf: fresh)
            // Cached as a whole, so reopening the list shows what was already
            // paged in rather than dropping back to page one.
            await storeTracks(playlistTracks, category: .playlistTracks, key: list.cacheKey)
        } catch {
            Log.warning("[QQMusicOnline] list paging failed: \(noteFailure(error))", category: .import)
        }
    }

    /// Keep loading pages until the open list is complete.
    ///
    /// Bounded, and each pass must make progress, so a mis-reported total cannot
    /// spin the loop.
    func loadRemainingListTracks(maxPasses: Int = 12) async {
        var passes = 0
        while hasMorePlaylistTracks, passes < maxPasses, !Task.isCancelled {
            passes += 1
            let before = playlistTracks.count
            await loadMorePlaylistTracks()
            if playlistTracks.count == before { break }
        }
    }

    /// Whether the open list has tracks beyond what is loaded.
    ///
    /// Only ever true for a ranking: the other kinds fetch their whole list (and
    /// an album is served whole by its helper route), so their total is what is
    /// already on screen.
    var hasMorePlaylistTracks: Bool {
        guard case .toplist = openedList else { return false }
        guard openedPlaylistTotal > 0 else { return false }
        return playlistTracks.count < openedPlaylistTotal
    }

    /// Queue an online track to play right after the current one.
    ///
    /// Unlike the prefetch path this is an explicit user request, so it goes
    /// through `insertTracksAfterCurrent` — which is exactly what that call
    /// means: put this next. It has to download first, because the queue holds
    /// playable local tracks, not online metadata.
    ///
    /// Returns false when the track could not be queued, so the caller can say
    /// why rather than appearing to do nothing.
    @discardableResult
    func playNext(_ track: QQMusicOnlineTrack) async -> Bool {
        guard canDownload, let playerViewModel else {
            Log.warning("[QQMusicOnline] play-next needs a managed library", category: .import)
            return false
        }
        // "Play next" is a playback request, so the file it needs is automatic —
        // it becomes the user's own only if they later download it.
        guard let imported = await materialize(track, origin: Self.playbackOrigin) else { return false }

        // `insertTracksAfterCurrent` needs something playing to insert after.
        // With an empty queue the honest interpretation of "play next" is
        // "play it", so start a session instead of failing silently.
        guard playerViewModel.currentTrack != nil else {
            await startPlayback([track], startingAt: 0)
            return true
        }
        guard playerViewModel.insertTracksAfterCurrent([imported]) > 0 else {
            Log.info("[QQMusicOnline] play-next: already in the queue", category: .import)
            return false
        }
        return true
    }

    // MARK: - Playback

    /// Play an online list, starting at `index`.
    ///
    /// `pageable` marks the guess-you-like feed, whose list has no end: the
    /// prefetch loop then refills the queue through `extendRecommendFeed` so
    /// playback continues past the tracks currently on screen. A playlist or
    /// ranking has a fixed end and is not refilled.
    func startPlayback(
        _ tracks: [QQMusicOnlineTrack],
        startingAt index: Int = 0,
        pageable: Bool = false,
        isRadio: Bool = false
    ) async {
        guard canDownload, let playerViewModel else {
            Log.warning("[QQMusicOnline] playback needs a managed library", category: .import)
            return
        }
        let playable = tracks.filter { !$0.songMid.isEmpty }
        guard playable.indices.contains(index) else { return }

        // A new session replaces the previous prefetch loop.
        stopPrefetch()
        sessionTracks = playable
        sessionSupportsPaging = pageable
        // A radio's own rotation is already a random draw from the catalogue, so
        // shuffling it changes nothing audible.
        //
        // This is an explicit parameter, deliberately NOT derived from
        // `activeRadioStationID`. That is "which station
        // is open", and they outlive a playback session — a previous visit to a
        // station used to leave this true forever, which suppressed the shuffle
        // for every later session: shuffle silently degraded to sequential over
        // whatever had been downloaded. A property of *this* playback must come
        // from this call, not from leftover browsing state.
        sessionIsRadio = pageable || isRadio
        skippedSongMids = []
        // Everything on screen counts as seen, so a later refresh cannot
        // re-queue a track the session already holds.
        seenFeedSongMids.formUnion(playable.map(\.songMid))

        let seed = playable[index]

        // Build the playing order across the whole list before anything starts.
        // Doing it here, rather than letting the engine shuffle a one-track
        // queue, is what makes shuffle cover every track instead of the handful
        // downloaded so far.
        //
        // `keeping: seed.songMid` is what puts the track the user pressed play on
        // at the head of that order; the prefetch loop below downloads along it,
        // so this is also what the listener hears first.
        //
        // The rebuild is forced rather than incremental: this is a new session,
        // and leaving the previous order in place would make the preview below
        // skip the rebuild entirely.
        playbackOrder = []
        orderIsShuffled = !wantsShuffle  // forces the rebuild below to take effect
        sessionAllSongMids = playable.map(\.songMid)
        rebuildPlaybackOrder(keeping: seed.songMid)

        // The track playback starts on: fetched because playback needs it, so
        // automatic. It is protected from reclamation anyway by being the
        // current track, and the user can make it theirs with one download.
        guard let first = await materialize(seed, origin: Self.playbackOrigin) else { return }

        // `externalOrder`: this session feeds the queue itself, so the engine
        // must advance linearly rather than shuffling the very same tracks a
        // second time. The user's mode is still honoured — it decided the order
        // above.
        playerViewModel.playTracks([first], startingAt: 0, startPolicy: .externalOrder)
        activePlayingSongMid = seed.songMid
        Log.info(
            "[QQMusicOnline] session started: \(seed.songMid), "
                + "\(sessionIsRadio ? "radio" : (wantsShuffle ? "shuffled" : "in order"))"
                + ", range=\(sessionAllSongMids.count)",
            category: .import
        )

        observeTrackChanges()
        observePlaybackModeChanges()
        beginPrefetch()
    }

    /// Play a single online track, replacing the current queue.
    func play(_ track: QQMusicOnlineTrack) async {
        await startPlayback([track], startingAt: 0)
    }

    /// Stop feeding the queue and forget the online session.
    func endSession() {
        stopPrefetch()
        playbackModeObserver?.cancel()
        playbackModeObserver = nil
        sessionTracks = []
        sessionAllSongMids = []
        playbackOrder = []
        orderIsShuffled = false
        activePlayingSongMid = nil
    }

    // MARK: - Playback order maintenance

    /// Whether playback should currently be shuffled.
    ///
    /// Read from the app's own playback mode rather than passed in, so the
    /// online source follows the same switch the local library does.
    ///
    /// Note what this does *not* do: it does not put the engine into shuffle
    /// mode. The engine keeps whichever mode the user chose, and when that is
    /// shuffle it advances by taking whatever sits directly after the current
    /// track. The coordinator writes our shuffle result into that slot, so the
    /// order the user hears is ours. Letting the engine shuffle *and* ordering
    /// ourselves would apply two shuffles and lose control of the sequence.
    private var wantsShuffle: Bool {
        AppSettings.shared.playbackOrderMode == .shuffle
    }

    /// Rebuild `playbackOrder` from `sessionAllSongMids`.
    ///
    /// `keeping` is the track at the cursor. The rebuilt order starts there, so a
    /// mode switch or a list refresh never interrupts what is playing: in
    /// shuffle the rest of the list is permuted, otherwise it is the list's tail.
    /// What already played is not in the result at all — it lives in the engine's
    /// own queue, which is where 上一首 reads it from.
    private func rebuildPlaybackOrder(keeping currentMid: String?) {
        let mids = sessionAllSongMids
        guard !mids.isEmpty else {
            playbackOrder = []
            orderIsShuffled = false
            return
        }

        // A radio's list is already a random draw, so permuting it again would
        // change nothing audible and would misreport the mode.
        let shuffle = wantsShuffle && !sessionIsRadio
        var rng = SystemRandomNumberGenerator()
        let rebuilt = QQMusicPlaybackOrder.make(
            allSongMids: mids,
            keeping: currentMid,
            shuffle: shuffle,
            using: &rng
        )

        // Rebuilding on every track change would reshuffle mid-playback: the
        // user would hear the upcoming order change under them, and tracks could
        // repeat or vanish. So when the membership and the mode are unchanged,
        // the existing order stands — advancing through it is the point.
        if rebuilt.count == playbackOrder.count,
           Set(rebuilt) == Set(playbackOrder),
           orderIsShuffled == shuffle {
            return
        }

        playbackOrder = rebuilt
        orderIsShuffled = shuffle
    }

    /// Append newly arrived tracks (paging) to the end of the listening order.
    ///
    /// Appended, never reshuffled: the user is partway through, and re-shuffling
    /// the unplayed remainder would replay tracks and drop others.
    private func extendPlaybackOrder(with tracks: [QQMusicOnlineTrack]) {
        let known = Set(playbackOrder)
        let additions = tracks.map(\.songMid).filter { !known.contains($0) }
        guard !additions.isEmpty else { return }
        sessionAllSongMids.append(contentsOf: additions)
        playbackOrder.append(contentsOf: additions)
    }

    /// React to the user switching shuffle on or off mid-session.
    ///
    /// Without this the order would keep following whatever it was built with,
    /// so the toggle would appear to do nothing until playback restarted.
    private func observePlaybackModeChanges() {
        guard playbackModeObserver == nil else { return }
        playbackModeObserver = Task { [weak self] in
            let changes = NotificationCenter.default.notifications(named: .playbackModeChanged)
            for await _ in changes {
                guard let self else { return }
                await self.handlePlaybackModeChange()
            }
        }
    }

    private func handlePlaybackModeChange() async {
        guard !sessionAllSongMids.isEmpty else { return }
        guard wantsShuffle != orderIsShuffled else { return }
        // The cursor has to be a track *of this session*. `make` falls back to
        // the head of the list for an unknown anchor — right for a session that
        // is starting, wrong here: it would place the playlist's first row at the
        // front of the order, and the prefetch loop would then queue the top of
        // the list behind whatever is playing. `activePlayingSongMid` covers the
        // moment `currentTrack` is briefly unset during a track swap.
        guard let current = playerViewModel?.currentTrack?.qqMusicSongMid ?? activePlayingSongMid,
              sessionAllSongMids.contains(current)
        else { return }
        rebuildPlaybackOrder(keeping: current)
        // The order changed, so the queue no longer reflects it. Restart the
        // loop, which now pulls from the rebuilt order.
        beginPrefetch()
    }

    /// What makes a download "the user's own" rather than cache.
    ///
    /// Only the explicit download actions do — 下载 and 选择下载. Everything
    /// fetched *because playback needed it* is automatic, including the very
    /// track the user pressed play on: pressing play asks to hear a song, not to
    /// add it to the library. Labeling that one as the user's own made every
    /// playback session look like a series of deliberate downloads, which is why
    /// the cache read as empty and nothing was ever reclaimable.
    ///
    /// A label is not a one-way door: choosing an automatic download for download
    /// changes its label without fetching it again (`promoteToUserRequested`), and
    /// nothing ever demotes the user's own back to cache.
    private static let playbackOrigin: QQMusicDownloadOrigin = .prefetch

    /// Download `track` (or reuse an already-imported copy) and return its
    /// library `Track`. Returns nil when the upstream withholds it.
    ///
    /// The imported `Track` comes straight from the import result rather than a
    /// library re-lookup: the in-memory library snapshot is refreshed
    /// asynchronously, so looking it up here would race and drop the track.
    /// Download a track if needed and return its library `Track`.
    ///
    /// `origin` records *why* it is being fetched. The distinction matters
    /// because a prefetched file is a cache entry the app may reclaim, while one
    /// the user asked for is permanent — and because a track prefetched earlier
    /// is upgraded to user-requested when they later ask for it, rather than
    /// being downloaded again.
    private func materialize(
        _ track: QQMusicOnlineTrack,
        origin: QQMusicDownloadOrigin = .prefetch
    ) async -> Track? {
        if let existing = existingTrack(for: track.songMid) {
            importedSongMids.insert(track.songMid)
            // Already on disk: this is the automatic-to-manual transition, so
            // ownership changes without a second download.
            await recordDownloadOrigin(origin, on: [existing])
            return existing
        }
        let imported = await downloadAndImport(track)
        await recordDownloadOrigin(origin, on: imported)
        return imported.first
    }

    /// Record why a downloaded track is on disk.
    ///
    /// Kept separate from the import so a provenance-write failure cannot roll
    /// back a file that imported successfully, mirroring how `applyProvenance`
    /// is kept apart from the import transaction.
    ///
    /// Only ever *upgrades* to `.userRequested`: once the user has asked for a
    /// track it stays theirs, so a later background pass cannot quietly
    /// reclassify it as evictable.
    private func recordDownloadOrigin(_ origin: QQMusicDownloadOrigin, on tracks: [Track]) async {
        var changed: [Track] = []
        for track in tracks where track.qqMusicSongMid?.isEmpty == false {
            guard QQMusicDownloadOrigin.shouldReplace(
                existing: track.qqMusicDownloadOrigin,
                with: origin
            ) else { continue }
            track.qqMusicDownloadOrigin = origin.rawValue
            if track.qqMusicDownloadedAt == nil { track.qqMusicDownloadedAt = Date() }
            changed.append(track)
        }
        guard !changed.isEmpty, let importService else { return }
        await importService.persistOnlineDownloadOrigin(changed)
    }

    /// Find an already-imported track for a song mid, so a re-tap reuses the
    /// local copy instead of downloading it again.
    private func existingTrack(for songMid: String) -> Track? {
        libraryViewModel?.allTracks.first { $0.qqMusicSongMid == songMid }
    }

    // MARK: - Background prefetch

    private func beginPrefetch() {
        // Never run two loops: they would race to insert the same tracks, and a
        // loop left over from a replaced session would insert its own order.
        guard !isPrefetching else { return }
        isPrefetching = true
        prefetchGeneration &+= 1
        let generation = prefetchGeneration
        prefetchTask = Task { [weak self] in
            await self?.runPrefetchLoop()
            // Cleared on every exit path, including cancellation. Guarded by the
            // generation so a finishing loop cannot clear the flag belonging to
            // a newer one that already started.
            await MainActor.run {
                guard let self, self.prefetchGeneration == generation else { return }
                self.isPrefetching = false
            }
        }
    }

    /// Stop feeding the queue and mark the loop not running.
    private func stopPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchGeneration &+= 1
        isPrefetching = false
    }

    /// Feed the player queue so it always holds the next tracks of our order.
    ///
    /// The engine's shuffle pulls its next track from whatever sits immediately
    /// after the current one, and `insertTracksAfterCurrent` writes into exactly
    /// that slot. So inserting in *our* order is what makes the engine play that
    /// order — the coordinator decides, the engine just advances.
    ///
    /// Two things this deliberately does *not* do, both of which caused playback
    /// to stop dead before:
    ///
    /// 1. It reads the **player's real queue** to decide whether more is needed,
    ///    never a private ledger of what it thinks it inserted. A ledger drifts
    ///    the moment anything is refused or fails, and a drifted ledger makes the
    ///    loop believe the queue is deeper than it is — so it waits forever while
    ///    playback starves.
    ///
    /// 2. It never exits on a transient condition. `currentTrack` is briefly nil
    ///    while a track is being swapped, and the loop used to treat that as "the
    ///    user left the session" and return. A finished task is neither nil nor
    ///    cancelled, so the restart check could not bring it back and playback
    ///    stopped for good. Transient conditions now sleep and retry; only a
    ///    cancelled task (session replaced, or user left) ends the loop.
    private func runPrefetchLoop() async {
        guard let playerViewModel else { return }

        // Consecutive iterations with no online track playing. Used to tell
        // "a track swap is in progress" (recoverable, a few hundred ms) from
        // "the user left this session" (permanent). Returning on the first nil
        // is what killed the loop before: a finished task is neither nil nor
        // cancelled, so the restart check could never revive it.
        var idleTicks = 0
        let idleTicksBeforeGivingUp = 10   // ~3s at 300ms per tick

        while !Task.isCancelled {
            let depth = max(0, AppSettings.shared.qqMusicPrefetchDepth)
            guard depth > 0 else { return }

            guard let playingMid = playerViewModel.currentTrack?.qqMusicSongMid else {
                idleTicks += 1
                if idleTicks >= idleTicksBeforeGivingUp { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            idleTicks = 0

            // Ask the player what it is actually holding, rather than trusting a
            // private ledger of what we think we inserted. A ledger drifts as
            // soon as an insert is refused or a download fails, and a drifted
            // ledger makes the loop wait forever on a queue that is in fact
            // starved.
            let queue = playerViewModel.currentQueueTracks
            let queuedMids = queue.compactMap(\.qqMusicSongMid)
            let queuedSet = Set(queuedMids)

            if let currentIndex = queuedMids.firstIndex(of: playingMid) {
                let aheadInQueue = queuedMids.count - (currentIndex + 1)
                if aheadInQueue >= depth {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
            }

            // The next track of our order that the queue does not hold yet.
            // Searched across the whole order, not just what follows the current
            // track: the engine may advance onto a track it picked itself, and
            // that must not stop us from feeding the rest.
            //
            // Safe to start at the head because the order *begins* at the track
            // the session was started on and only ever contains what has not
            // played — and that track is in the queue, so the search resumes at
            // whatever follows it. (An order that carried the rows above the
            // cursor at its head is what used to make every session download the
            // top of the list first, shuffle or not.)
            //
            // `skippedSongMids` is excluded because a track that cannot be
            // downloaded never enters the queue, so without this it would be
            // chosen again on every pass and retried forever.
            guard let nextMid = playbackOrder.first(where: {
                !queuedSet.contains($0) && !skippedSongMids.contains($0)
            }) else {
                // Everything known is queued or unplayable. A pageable feed can
                // supply more; a fixed list is finished.
                guard sessionSupportsPaging else { return }
                let added = await extendRecommendFeed()
                if added.isEmpty {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                continue
            }

            guard let online = trackInSession(nextMid) else {
                // Reachable if paging grew the order but not `sessionTracks` yet.
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            guard let imported = await materialize(online) else {
                // Unplayable for this account (VIP, region, delisted). Recorded
                // so the loop moves on instead of retrying it every pass; the
                // queue must not stall on one track.
                skippedSongMids.insert(nextMid)
                continue
            }
            guard !Task.isCancelled else { return }

            // One at a time, in order. Each insert lands directly after the
            // current track, so the queue ends up in `playbackOrder` sequence —
            // which is what makes the engine play our shuffled order.
            let inserted = playerViewModel.insertTracksAfterCurrent([imported])
            if inserted == 0 {
                // Refused, typically because a track swap has the current track
                // briefly unset. Retry rather than treating it as queued — that
                // assumption is what starved the queue before.
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    /// Find a session track by mid, including ones added by paging.
    private func trackInSession(_ songMid: String) -> QQMusicOnlineTrack? {
        sessionTracks.first { $0.songMid == songMid }
    }

    /// Re-prefetch when the player advances, so the queue stays ahead.
    private func observeTrackChanges() {
        guard trackChangeObserver == nil else { return }
        trackChangeObserver = Task { [weak self] in
            let changes = NotificationCenter.default.notifications(named: .playbackTrackDidChange)
            for await _ in changes {
                guard let self else { return }
                await self.handleTrackChange()
            }
        }
    }

    private func handleTrackChange() async {
        guard !sessionTracks.isEmpty else { return }
        let mid = playerViewModel?.currentTrack?.qqMusicSongMid
        activePlayingSongMid = mid

        // Playback moved to something outside this session. That happens when
        // the user plays from a local library page, and it is the signal to hand
        // the queue back to the app's own logic: this session stops feeding, so
        // the player's normal sequential/shuffle behaviour takes over from here.
        //
        // Only a track that is genuinely *not* part of the session counts. A
        // brief nil `currentTrack` during a swap, or a track the session is
        // still about to reach, must not end it.
        guard let mid else { return }
        guard sessionTracks.contains(where: { $0.songMid == mid }) else {
            releaseSessionForExternalPlayback()
            return
        }

        // The player moved on; make sure the next tracks are queued.
        //
        // Liveness is tracked with a flag rather than by inspecting the task:
        // a *finished* task is neither nil nor cancelled, so the old check
        // (`prefetchTask == nil || isCancelled`) could never restart a loop that
        // had exited — playback would simply stop for good.
        if !isPrefetching {
            beginPrefetch()
        }
    }

    /// Stop owning the queue because playback moved to a non-session track.
    ///
    /// Clears the session state but leaves the already-imported tracks and the
    /// queue untouched: whatever is playing keeps playing, and the app's own
    /// playback logic resumes control of the order from the current track on.
    private func releaseSessionForExternalPlayback() {
        stopPrefetch()
        sessionTracks = []
        sessionAllSongMids = []
        playbackOrder = []
        orderIsShuffled = false
        sessionIsRadio = false
        Log.info(
            "[QQMusicOnline] session released; playback continues under the app's own queue logic",
            category: .import
        )
    }

    // MARK: - Download & import

    func phase(for songMid: String) -> QQMusicDownloadPhase {
        downloadPhases[songMid] ?? .idle
    }

    func isImported(_ songMid: String) -> Bool {
        importedSongMids.contains(songMid) || existingTrack(for: songMid) != nil
    }

    /// Whether this track is already the user's own download.
    ///
    /// Distinct from `isImported`, which is also true for a track a prefetch
    /// happened to fetch — that one is still cache, so downloading it is
    /// meaningful (it converts it to the user's). Only a track the user already
    /// asked for has nothing left to do.
    func isUserDownloaded(_ songMid: String) -> Bool {
        guard let track = existingTrack(for: songMid) else { return false }
        return track.qqMusicOrigin == .userRequested
    }

    func isPlaying(_ songMid: String) -> Bool {
        activePlayingSongMid == songMid
    }

    /// Download several tracks the user picked, one after another.
    ///
    /// Serial on purpose: the upstream is sensitive to concurrent requests, and a
    /// batch download is the easiest way to look like abuse. Each track's
    /// progress reuses the per-row phase the list already displays, so no
    /// separate progress UI is needed.
    ///
    /// Already-downloaded tracks are not fetched again — `materialize` reuses the
    /// local copy and only promotes its ownership, which is exactly the
    /// automatic-to-manual transition.
    ///
    /// Returns a summary so the caller can report what happened rather than
    /// guessing from the phases.
    @discardableResult
    func downloadSelected(_ tracks: [QQMusicOnlineTrack]) async -> (downloaded: Int, converted: Int, failed: Int) {
        guard canDownload else {
            Log.warning("[QQMusicOnline] batch download needs a managed library", category: .import)
            return (0, 0, 0)
        }
        var downloaded = 0
        var converted = 0
        var failed = 0
        for track in tracks where !track.songMid.isEmpty {
            guard !Task.isCancelled else { break }
            // An already-downloaded track is *converted*, not fetched again:
            // `materialize` reuses the local copy and only rewrites the label.
            // Counted separately so the report tells the user which happened
            // instead of claiming a download that did not occur.
            let alreadyLocal = existingTrack(for: track.songMid) != nil
            if await materialize(track, origin: .userRequested) != nil {
                if alreadyLocal { converted += 1 } else { downloaded += 1 }
            } else {
                failed += 1
            }
        }
        return (downloaded, converted, failed)
    }

    /// Download `track` and import it into the library.
    ///
    /// Returns the imported tracks (empty on failure). `Track` is a SwiftData
    /// model and therefore not `Sendable`, so the result must stay on the main
    /// actor — callers must not pass it across a task boundary.
    @discardableResult
    func downloadAndImport(_ track: QQMusicOnlineTrack) async -> [Track] {
        guard let importService, let paths else {
            Log.warning("[QQMusicOnline] import needs a library session", category: .import)
            return []
        }
        guard !phase(for: track.songMid).isBusy else { return [] }

        downloadPhases[track.songMid] = .resolving
        defer {
            if case .failed = downloadPhases[track.songMid] {} else {
                downloadPhases[track.songMid] = importedSongMids.contains(track.songMid) ? .done : .idle
            }
        }

        let staging: QQMusicStagedDownload
        do {
            staging = try await downloader.download(
                track,
                stagingDirectory: paths.importStagingRootURL
                    .appendingPathComponent("qqmusic", isDirectory: true),
            ) { [weak self] phase in
                Task { @MainActor [weak self] in
                    self?.downloadPhases[track.songMid] = phase
                }
            }
        } catch {
            let message = noteFailure(error)
            // The row draws this failure out of `downloadPhases`, which is where
            // the user can act on it; the log carries the long form.
            downloadPhases[track.songMid] = .failed(message)
            Log.warning("[QQMusicOnline] download failed \(track.songMid): \(message) — \(error)", category: .import)
            return []
        }

        let override = ImportMetadataOverride(
            artist: nil,
            album: nil,
            artworkData: staging.artworkData,
            lyrics: Self.combinedLyrics(staging)
        )

        let imported = await importService.importProducedAudio(
            at: staging.audioURL,
            metadataOverride: override,
            origin: .onlineDownload
        )
        guard !imported.isEmpty else {
            downloadPhases[track.songMid] = .failed("导入失败")
            Log.warning("[QQMusicOnline] import failed for \(track.songMid)", category: .import)
            try? FileManager.default.removeItem(at: staging.audioURL)
            return []
        }

        // Record provenance so the row shows as already-added and the mid
        // survives for future metadata refreshes.
        await importService.applyProvenance(
            OnlineImportProvenance(source: "qqmusic", songMid: track.songMid),
            to: imported
        )

        importedSongMids.insert(track.songMid)
        downloadPhases[track.songMid] = .done
        try? FileManager.default.removeItem(at: staging.audioURL)
        // A download can push the automatic-download cache over its limit, so
        // the check runs once per completed download rather than on a timer.
        await enforceCacheLimits()
        return imported
    }

    /// Bring both caches back under their configured limits.
    ///
    /// Called after a download and from the settings window. Safe to call with
    /// no limit configured: it returns without touching anything.
    @discardableResult
    func enforceCacheLimits() async -> QQMusicCacheBudget.Outcome {
        guard let libraryViewModel else { return QQMusicCacheBudget.Outcome() }

        // Never delete what is playing, or what is queued behind it.
        var protected = Set<UUID>()
        if let current = playerViewModel?.currentTrack { protected.insert(current.id) }
        for queued in playerViewModel?.currentQueueTracks ?? [] { protected.insert(queued.id) }

        let outcome = await QQMusicCacheBudget.shared.reclaimSongsIfNeeded(
            tracks: libraryViewModel.allTracks,
            playingAndQueued: protected,
            libraryRoot: paths?.rootURL,
            delete: { [weak libraryViewModel] doomed in
                await libraryViewModel?.deleteTracks(doomed)
            }
        )
        if outcome.removedTrackCount > 0 {
            Log.info(
                "[QQMusicOnline] song cache reclaimed \(outcome.removedTrackCount) tracks, "
                    + "\(QQMusicBytes.formatted(outcome.reclaimedBytes))",
                category: .import
            )
        }
        _ = await QQMusicCacheBudget.shared.reclaimOtherIfNeeded(store: cacheStore)
        return outcome
    }

    /// Merge the QQ lyric and its translation into one LRC block.
    ///
    /// The player's lyric pipeline understands LRC, and keeping both languages
    /// in one document means the existing TTML conversion handles them without
    /// new plumbing.
    private static func combinedLyrics(_ staging: QQMusicStagedDownload) -> String? {
        guard let lyric = staging.lyricText, !lyric.isEmpty else { return nil }
        guard let translation = staging.translatedLyricText, !translation.isEmpty else {
            return lyric
        }
        return lyric + "\n" + translation
    }
}

