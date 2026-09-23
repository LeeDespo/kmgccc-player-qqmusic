//
//  QQMusicOnlineCoordinator.swift
//  kmgccc_player
//
//  Bridges the online QQ Music catalog into the local library.
//
//  The catalog side (browsing, search, recommendations) is network work owned
//  by `QQMusicHelperProcess`. The library side is main-actor state owned by the
//  import pipeline. This coordinator is the only place the two meet: it
//  downloads a track to staging, imports it, and — for a playback session —
//  keeps the player queue fed so playback never has to stop and wait.
//
//  Playback model: the player consumes only real `Track` values backed by
//  local files, so an online "play" is download-then-play. To make that feel
//  like streaming, `startPlayback` downloads the requested track and then
//  prefetches ahead in the background, appending each result to the queue.
//  Playback then advances through the queue with the player's own logic.
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
    private(set) var likedSongsPage = 0
    private(set) var likedAlbums: [QQMusicOnlineAlbum] = []
    private(set) var userPlaylists: [QQMusicOnlinePlaylist] = []
    // Radio stations
    private(set) var radioGroups: [QQMusicRadioGroup] = []
    private(set) var radioStationTitle = ""
    private(set) var isLoadingRadioStations = false
    private(set) var isLoadingRadioTracks = false

    // Artist search
    private(set) var searchedArtists: [QQMusicOnlineArtist] = []
    private(set) var isSearchingArtists = false
    private(set) var artistSearchKeyword = ""

    private(set) var isLoadingLikedSongs = false
    private(set) var isLoadingLikedAlbums = false
    private(set) var isLoadingUserPlaylists = false
    /// True when the last user-library call reported it needs a login.
    private(set) var userLibraryNeedsLogin = false
    /// Song mids currently liked, from the account's "我喜欢".
    ///
    /// Held as a set rather than re-querying per track: the upstream has no
    /// per-track membership endpoint, so the folder is read once and kept in
    /// memory while the session lives.
    private(set) var likedSongMids: Set<String> = []
    /// Walks the remaining pages of the liked folder in the background, so the
    /// first page can be shown immediately while the full set fills in.
    private var likedMidsCompletionTask: Task<Void, Never>?
    private var isRefreshingLikedMids = false
    /// The row a like was issued from, so the liked list can be adjusted
    /// without refetching it. Keyed by song mid; consumed on insert.
    private var pendingLikeRow: [String: QQMusicOnlineTrack] = [:]
    /// Writes in flight, so the button can show progress and not double-fire.
    private(set) var pendingLikeSongMids: Set<String> = []
    private var isLoadingMoreLikedSongs = false
    /// Whether the whole 我喜欢 list has actually been fetched.
    ///
    /// Recorded explicitly rather than inferred from the count. The folder's
    /// `total` counts *rows*, and a few rows carry no playable track, so
    /// `likedSongs.count` can sit permanently below `likedSongsTotal` — which
    /// made the page show "正在载入其余曲目…" forever even after everything had
    /// arrived, and made every scroll re-request the same pages.
    private(set) var hasLoadedAllLikedSongs = false
    /// Guards the one-shot full-list load, which is separate from paging.
    private var isLoadingAllLikedSongs = false
    private(set) var playlistSearchKeyword = ""
    private(set) var isLoadingNewSongs = false
    private(set) var isSearchingPlaylists = false
    private(set) var loadedPlaylistTitle: String = ""
    private(set) var searchKeyword: String = ""

    private(set) var isLoadingFeed = false
    private(set) var isLoadingPlaylists = false
    private(set) var isLoadingToplists = false
    private(set) var isSearching = false
    private(set) var isLoadingPlaylistTracks = false

    /// Per-track download state, keyed by song mid, so rows can show progress.
    private(set) var downloadPhases: [String: QQMusicDownloadPhase] = [:]
    /// Song mids already in the library as a QQ Music download.
    private(set) var importedSongMids: Set<String> = []

    /// Non-blocking status line. Never used to blank out loaded content.
    private(set) var statusMessage: String?
    private(set) var statusIsError = false

    /// Whether any browse request is currently in flight, for one spinner in
    /// the header instead of one per section.
    var isBusyLoading: Bool {
        isLoadingFeed || isLoadingPlaylists || isLoadingToplists
            || isSearching || isLoadingPlaylistTracks
    }

    /// Playback session state, so rows can show what is currently playing.
    private(set) var activePlayingSongMid: String?
    private(set) var sessionQueueSongMids: [String] = []

    // MARK: - Dependencies

    private let helper: QQMusicHelperProcess
    private let downloader: QQMusicDownloadService
    /// Direct HTTP access to the web endpoints, for the read paths that are
    /// worth avoiding a helper round trip for.
    private let webAPI: QQMusicWebAPI
    /// Which reads the web path has previously served. Used only to decide
    /// whether a fallback is worth a warning — it never gates the fallback
    /// itself, which is always taken on failure.
    private var webReadsSucceeded: Set<String> = []

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

    /// Whether the current playback session is a radio.
    ///
    /// Radios have no end, so the view uses this to withhold
    /// whole-list actions (select all, batch download).
    var isRadioSession: Bool { sessionIsRadio }
    /// Tracks this session could not download, so the prefetch loop stops
    /// picking them. Without this an unplayable track is never queued, so it
    /// would be chosen again on every pass and retried forever.
    private var skippedSongMids: Set<String> = []
    /// The playlist currently open in the drill-down, so its next page can be
    /// requested. Nil for a ranking, which pages differently.
    private var openedPlaylistID: Int?
    /// The ranking currently open, when the drill-down is a ranking rather
    /// than a playlist. Paging needs its id, so a flag is not enough.
    private var openedToplistID: Int?
    /// The open playlist's own track count. Drives whether another page exists;
    /// 0 means unknown, which simply disables paging.
    private(set) var openedPlaylistTotal = 0
    private(set) var isLoadingMorePlaylistTracks = false
    /// Whether the prefetch loop is currently running. Explicit, because a
    /// *finished* `Task` is neither nil nor cancelled, so task identity cannot
    /// answer "is it still feeding the queue?".
    private var isPrefetching = false
    /// Guards browsing-wide preparation, which several pages can trigger.
    private var isPreparingForBrowsing = false
    /// Bumped whenever a loop starts or is stopped, so a finishing loop can tell
    /// whether the flag still belongs to it.
    private var prefetchGeneration: UInt64 = 0

    init(
        helper: QQMusicHelperProcess = .shared,
        downloader: QQMusicDownloadService = QQMusicDownloadService(),
        webAPI: QQMusicWebAPI = .shared
    ) {
        self.helper = helper
        self.downloader = downloader
        self.webAPI = webAPI
    }

    /// Run a read through the direct HTTP client, falling back to the helper.
    ///
    /// The web client answers in roughly a quarter of the time the helper takes,
    /// because the helper pays for a process and a fresh client per call. These
    /// are all read paths that the browse pages hit constantly.
    ///
    /// The helper stays the fallback and is still the only thing that can log in.
    /// Any web-path failure — credential file unreadable, upstream shape changed,
    /// transport error, session expired — degrades to the old behaviour instead
    /// of surfacing an error the user cannot act on.
    ///
    /// A failure is logged only once the web path has previously worked, so a
    /// user who is simply signed out does not get a warning on every call.
    private func webFirst<T>(
        _ label: String,
        web: () async throws -> T,
        helper: () async throws -> T
    ) async throws -> T {
        do {
            let result = try await web()
            webReadsSucceeded.insert(label)
            return result
        } catch {
            if webReadsSucceeded.contains(label) {
                Log.warning(
                    "[QQMusicOnline] web \(label) failed, falling back to helper: \(error)",
                    category: .import
                )
            }
            webReadsSucceeded.remove(label)
            return try await helper()
        }
    }

    private func fetchLikedSongs(page: Int, limit: Int) async throws -> QQMusicLikedSongs {
        try await webFirst(
            "liked-songs",
            web: { try await self.webAPI.fetchLikedSongs(page: page, limit: limit) },
            helper: { try await self.helper.fetchLikedSongs(page: page, limit: limit) }
        )
    }

    private func fetchLikedAlbums(limit: Int = 30) async throws -> [QQMusicOnlineAlbum] {
        try await webFirst(
            "liked-albums",
            web: { try await self.webAPI.fetchLikedAlbums(limit: limit) },
            helper: { try await self.helper.fetchLikedAlbums(limit: limit) }
        )
    }

    private func fetchUserPlaylists() async throws -> [QQMusicOnlinePlaylist] {
        try await webFirst(
            "user-playlists",
            web: { try await self.webAPI.fetchUserPlaylists() },
            helper: { try await self.helper.fetchUserPlaylists() }
        )
    }

    private func fetchLyric(
        songMid: String,
        songId: Int?
    ) async throws -> QQMusicLyricPayload {
        try await webFirst(
            "lyric",
            web: { try await self.webAPI.fetchLyric(songMid: songMid) },
            helper: { try await self.helper.fetchLyric(songMid: songMid, songId: songId) }
        )
    }

    /// One page of a playlist's tracks, web-first with a helper fallback.
    ///
    /// The helper can serve a *page* (its route takes `page`), so unlike the
    /// ranking path below there is something to fall back to. The helper does
    /// not report the list's total, so a page served this way reports the
    /// count it actually received — which understates the total and simply
    /// stops paging rather than breaking the list.
    private func fetchPlaylistPage(
        songlistId: Int,
        offset: Int,
        limit: Int
    ) async throws -> (tracks: [QQMusicOnlineTrack], total: Int) {
        try await webFirst(
            "playlist-page",
            web: { try await self.webAPI.fetchPlaylistTracks(songlistId: songlistId, offset: offset, limit: limit) },
            helper: {
                // The helper pages by number, not by offset. Deriving the page
                // from the offset keeps the two paths consistent at the page
                // size both use.
                let page = max(1, offset / max(1, limit) + 1)
                let tracks = try await self.helper.fetchPlaylistTracks(
                    songlistId: songlistId,
                    limit: limit,
                    page: page
                )
                return (tracks, offset + tracks.count)
            }
        )
    }

    // MARK: - Status

    func report(_ message: String?, isError: Bool = false) {
        guard let message, isError else {
            statusMessage = message
            statusIsError = isError
            return
        }
        // Two independent switches: users who find the throttling notices
        // noisy can silence those without losing genuine failure reports, and
        // the reverse.
        let isCircuitNotice = Self.circuitNoticeMarkers.contains { message.contains($0) }
        let allowed = isCircuitNotice
            ? AppSettings.shared.qqMusicShowCircuitNotices
            : AppSettings.shared.qqMusicShowGeneralNotices
        statusMessage = allowed ? message : nil
        statusIsError = allowed && isError
    }

    /// Substrings that identify a throttling/breaker message rather than a
    /// content failure. Matched case-insensitively.
    private static let circuitNoticeMarkers = ["熔断", "暂停", "过于频繁", "风控", "circuit"]

    // MARK: - Page lifecycle

    /// Browsing-wide preparation, independent of which page is showing.
    ///
    /// Two things every page relies on: whether downloads can land in the
    /// current library at all (the banner in the router reads it), and the
    /// liked-mid set the hearts read from — a row's heart is wrong until that
    /// set has been filled.
    func prepareForBrowsing(force: Bool = false) async {
        guard !isPreparingForBrowsing else { return }
        isPreparingForBrowsing = true
        defer { isPreparingForBrowsing = false }

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
            // The folder reports its size, so the rest arrives in one batched
            // round trip rather than page by page on scroll.
            await loadAllLikedSongs(force: force)

        case .userPlaylists:
            await loadUserPlaylists(force: force)

        case .likedAlbums:
            await loadLikedAlbums(force: force)

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

        case .playlist(let id, let title):
            await openPlaylist(id: id, title: title, force: force)

        case .album(let id, let title):
            await openAlbum(id: id, title: title, force: force)

        case .toplist(let id, let title):
            await openToplist(id: id, title: title, force: force)

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
        case .playlists: await searchPlaylists(trimmed, force: force)
        }
    }

    /// Clear the current type's results, leaving the other tabs' alone.
    func clearSearchResults(kind: QQMusicSearchKind? = nil) {
        switch kind ?? onlineSearchKind {
        case .songs: clearSearch()
        case .artists: clearArtistSearch()
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
        case .home, .userPlaylists, .likedAlbums, .toplists, .radio, .recommend,
             .search, .radioStation, .artist:
            return false
        }
    }

    /// Whether an upstream failure looks like rate limiting, so we back off
    /// instead of retrying immediately.
    private func noteFailure(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("Ratelimited") || text.contains("风控") || text.contains("安全验证") {
            rateLimitedUntil = Date().addingTimeInterval(30)
            return "访问过于频繁，已暂停请求 30 秒"
        }
        if text.contains("LoginExpired") {
            return "该接口需要登录 QQ 音乐账号"
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        await loadLikedSongs(force: force)
        // Pull the remainder in the same launch pass. The folder reports its
        // size and the pages come back in one batched request, so finishing the
        // list here is cheap — and it is what removes the wait when the user
        // opens the page, and what lets shuffle cover every track.
        await loadAllLikedSongs(force: force)
        await loadLikedAlbums(force: force)
        await loadUserPlaylists(force: force)
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
        if let wait = backoffRemaining() {
            report("访问过于频繁，请 \(Int(wait.rounded(.up))) 秒后重试", isError: true)
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
            report(nil)
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
            report(nil)
        } catch {
            // A failure with something already on screen is not worth
            // replacing the list with an error; the banner says so instead.
            report("推荐加载失败：\(noteFailure(error))", isError: servedFromCache)
            Log.warning("[QQMusicOnline] recommend feed failed: \(error)", category: .import)
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
        if let wait = backoffRemaining() {
            report("访问过于频繁，请 \(Int(wait.rounded(.up))) 秒后重试", isError: true)
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
            report(nil)
            return fresh
        } catch {
            report("加载更多失败：\(noteFailure(error))", isError: true)
            Log.warning("[QQMusicOnline] feed paging failed: \(error)", category: .import)
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
        if let wait = backoffRemaining() {
            report("访问过于频繁，请 \(Int(wait.rounded(.up))) 秒后重试", isError: true)
            return
        }
        isLoadingNewSongs = true
        newSongsRegion = region
        defer { isLoadingNewSongs = false }

        // Same stale-while-revalidate shape as the recommend feed: paint from
        // cache first, then replace only when the upstream actually differs.
        // Unlike the radio this *is* an enumeration (one call returns the whole
        // regional list), so a straight comparison is the right replacement
        // rule.
        var servedFromCache = false
        if !force, let cached = await cachedTracks(.newSongs, key: region.rawValue, force: false, allowStale: true) {
            newSongs = cached
            servedFromCache = true
            report(nil)
        }

        do {
            let fetched = try await helper.fetchNewSongs(region: region)
            let changed = fetched.map(\.songMid) != newSongs.map(\.songMid)
            if changed || !servedFromCache {
                newSongs = fetched
            }
            await storeTracks(fetched, category: .newSongs, key: region.rawValue)
            report(nil)
        } catch {
            report("新歌加载失败：\(noteFailure(error))", isError: servedFromCache)
            Log.warning("[QQMusicOnline] new songs failed: \(error)", category: .import)
        }
    }

    /// Search playlists by keyword — the category/mood browse path.
    func searchPlaylists(_ keyword: String, force: Bool = false) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        playlistSearchKeyword = trimmed
        guard !trimmed.isEmpty else {
            searchedPlaylists = []
            return
        }
        if let wait = backoffRemaining() {
            report("访问过于频繁，请 \(Int(wait.rounded(.up))) 秒后重试", isError: true)
            return
        }
        isSearchingPlaylists = true
        defer { isSearchingPlaylists = false }
        do {
            if let cached = await cachedPlaylists(.playlistSearch, key: trimmed, force: force) {
                searchedPlaylists = cached
                report(nil)
                return
            }
            let fetched = try await helper.searchPlaylists(keyword: trimmed, limit: 30)
            await storePlaylists(fetched, category: .playlistSearch, key: trimmed)
            searchedPlaylists = fetched
            report(nil)
        } catch {
            // Keep what is displayed; a failed search is not an empty result.
            report("歌单搜索失败：\(noteFailure(error))", isError: true)
            Log.warning("[QQMusicOnline] playlist search failed: \(error)", category: .import)
        }
    }

    func clearPlaylistSearch() {
        playlistSearchKeyword = ""
        searchedPlaylists = []
    }

    // MARK: - User library (read-only)
    //
    // Everything here reads. The upstream rejects writes over the web channel
    // (see docs/qqmusic/02-helper.md 02-07), so no like/unlike affordance is
    // offered anywhere in the UI.

    /// Whether another page of 我喜欢 is worth asking for.
    ///
    /// Stops for good once a pass has come back with nothing new, because that —
    /// not the row count — is the real completion signal for this endpoint.
    var hasMoreLikedSongs: Bool {
        !hasLoadedAllLikedSongs && likedSongs.count < likedSongsTotal
    }

    /// Load the whole "我喜欢" list, not just the first page.
    ///
    /// The folder reports its size, so the remaining pages are fetched together
    /// in one round trip. Doing this up front is what makes two things work
    /// that otherwise cannot: the list is fully browsable without waiting for
    /// scroll-triggered paging, and shuffle can range over every track rather
    /// than over whatever happened to have loaded.
    ///
    /// `total` counts rows, and a few rows carry no playable track — so the
    /// loop stops when a fetch adds nothing new, which is the real completion
    /// signal.
    func loadAllLikedSongs(force: Bool = false) async {
        // A reload has to walk the pages again even when the loaded list already
        // looks complete: a track added upstream lands after the tracks we hold,
        // so "every row I have is accounted for" is not evidence that upstream
        // holds nothing more.
        if force { hasLoadedAllLikedSongs = false }
        guard !isLoadingLikedSongs, !isLoadingAllLikedSongs else { return }
        guard force || hasMoreLikedSongs else { return }
        isLoadingAllLikedSongs = true
        defer { isLoadingAllLikedSongs = false }

        do {
            let all = try await webAPI.fetchAllLikedSongs()
            var tracks = likedSongs
            var seen = Set(tracks.map(\.songMid))
            for track in all.tracks where seen.insert(track.songMid).inserted {
                tracks.append(track)
            }
            guard tracks.count != likedSongs.count else {
                // Nothing new came back: this is the documented completion
                // signal for a folder whose `total` counts rows rather than
                // playable tracks.
                hasLoadedAllLikedSongs = true
                return
            }
            likedSongs = tracks
            likedSongsTotal = all.total
            if tracks.count >= all.total { hasLoadedAllLikedSongs = true }
            // The whole list is now held in memory, so it is worth caching as
            // one payload — reopening the page should not refetch 471 tracks.
            await cacheLikedSongs(QQMusicLikedSongs(title: all.title, total: all.total, tracks: tracks), page: 1)
            report(nil)
        } catch {
            // Paging by hand still works, so a failure here is not fatal.
            Log.warning("[QQMusicOnline] full liked-songs load failed: \(error)", category: .import)
        }
    }

    /// Load the first page of "我喜欢".
    /// Load "我喜欢".
    ///
    /// Cache-first by design: the account's favourites change rarely and only
    /// slightly, so a cached page is shown immediately and the network result
    /// is applied only if it actually differs. That keeps the page instant on
    /// every visit instead of re-fetching hundreds of tracks each time.
    func loadLikedSongs(force: Bool = false) async {
        if force { hasLoadedAllLikedSongs = false }
        guard !isLoadingLikedSongs else { return }
        if !force, !likedSongs.isEmpty { return }

        // Serve what we have first — except on a reload. The cached entry holds
        // one page, while the list on screen may be the whole folder, so painting
        // from the cache there would shrink 471 tracks to 100 until the rest was
        // fetched again.
        var servedFromCache = false
        if !force, let cached = await cachedLikedSongs(page: 1) {
            likedSongs = cached.tracks
            likedSongsTotal = cached.total
            likedSongsPage = 1
            userLibraryNeedsLogin = false
            servedFromCache = true
            report(nil)
        }

        isLoadingLikedSongs = true
        defer { isLoadingLikedSongs = false }
        do {
            // Always revalidate, cache hit or not, so the page cannot drift.
            let page = try await fetchLikedSongs(page: 1, limit: 100)
            // The cover is compared too, for the same reason as the playlists:
            // it is derived, so a change in how it is produced must be able to
            // supersede what is cached rather than being dismissed as "same
            // tracks, nothing changed".
            let changed = page.total != likedSongsTotal
                || page.tracks.map(\.songMid) != likedSongs.map(\.songMid)
                || page.tracks.map(\.imageURL) != likedSongs.map(\.imageURL)
            await cacheLikedSongs(page, page: 1)
            if !servedFromCache {
                // Nothing on screen yet: use the response as-is.
                likedSongs = page.tracks
                likedSongsTotal = page.total
                likedSongsPage = 1
            } else if changed {
                // Something on screen and the upstream differs: reconcile in
                // place so only the real additions and removals take effect. A
                // wholesale replacement would blank and rebuild the list for a
                // one-row change.
                mergeLiked(page.tracks)
                likedSongsTotal = page.total
            }
            // This response enumerates the folder, so it is the cheapest source
            // of the liked-mid set: seeding it here fills the hearts everywhere
            // without a second round of requests.
            likedSongMids = Set(page.tracks.map(\.songMid))
            // One page is up to 100 tracks. If the folder is bigger, the rest
            // would stay unfilled, so walk the remaining pages in the
            // background rather than blocking the page the user is looking at.
            if page.total > page.tracks.count {
                let expected = page.total
                likedMidsCompletionTask?.cancel()
                likedMidsCompletionTask = Task { [weak self] in
                    await self?.completeLikedSongMids(expectedTotal: expected)
                }
            }
            userLibraryNeedsLogin = false
            report(nil)
        } catch {
            // A login requirement is a state to guide the user through, not a
            // generic failure.
            if Self.isLoginRequired(error) {
                userLibraryNeedsLogin = true
                report("需要登录后才能读取收藏", isError: true)
            } else {
                report("收藏加载失败：\(noteFailure(error))", isError: true)
            }
            Log.warning("[QQMusicOnline] liked songs failed: \(error)", category: .import)
        }
    }

    /// Append the next page of "我喜欢".
    func loadMoreLikedSongs() async {
        guard !isLoadingMoreLikedSongs, hasMoreLikedSongs else { return }
        isLoadingMoreLikedSongs = true
        defer { isLoadingMoreLikedSongs = false }
        let next = likedSongsPage + 1
        do {
            if let cached = await cachedLikedSongs(page: next) {
                appendLiked(cached.tracks, page: next, total: cached.total)
                return
            }
            let page = try await fetchLikedSongs(page: next, limit: 100)
            await cacheLikedSongs(page, page: next)
            appendLiked(page.tracks, page: next, total: page.total)
        } catch {
            report("加载更多失败：\(noteFailure(error))", isError: true)
        }
    }

    private func appendLiked(_ tracks: [QQMusicOnlineTrack], page: Int, total: Int) {
        // Guard against the upstream repeating a track across pages.
        let known = Set(likedSongs.map(\.songMid))
        let fresh = tracks.filter { !known.contains($0.songMid) }
        likedSongs.append(contentsOf: fresh)
        likedSongsPage = page
        likedSongsTotal = max(total, likedSongs.count)
        // A page that contributed nothing means the folder is exhausted, even if
        // `total` still reads higher.
        if fresh.isEmpty, !tracks.isEmpty {
            hasLoadedAllLikedSongs = true
        }
        report(nil)
    }

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
        let page = QQMusicLikedSongs(title: "我喜欢", total: likedSongsTotal, tracks: likedSongs)
        Task { await self.cacheLikedSongs(page, page: 1) }
    }

    /// Reconcile a refreshed list with what is on screen, in place.
    ///
    /// A list that differs by one or two entries should not visibly empty and
    /// refill. Entries that are still present keep their positions and their
    /// already-decoded artwork; only genuine additions and removals are applied.
    ///
    /// Returns true when anything changed, so the caller can skip a needless
    /// re-render.
    @discardableResult
    private func mergeLiked(_ incoming: [QQMusicOnlineTrack]) -> Bool {
        let incomingMids = incoming.map(\.songMid)
        guard incomingMids != likedSongs.map(\.songMid) else { return false }

        let incomingSet = Set(incomingMids)
        let removed = likedSongs.filter { !incomingSet.contains($0.songMid) }
        var byMid = Dictionary(likedSongs.map { ($0.songMid, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [QQMusicOnlineTrack] = []
        for track in incoming {
            // Reuse the existing row when present, so nothing is re-decoded.
            if let existing = byMid[track.songMid] {
                merged.append(existing)
                byMid[track.songMid] = nil
            } else {
                merged.append(track)
            }
        }
        if !removed.isEmpty || merged.count != likedSongs.count {
            Log.info(
                "[QQMusicOnline] liked list reconciled: +\(max(0, merged.count - likedSongs.count)) "
                    + "-\(removed.count)",
                category: .import
            )
        }
        likedSongs = merged
        return true
    }

    /// Read the first page of "我喜欢" regardless of age.
    ///
    /// Deliberately `staleCatalog`, not `catalog`: this is the "show something
    /// now" path, and the caller revalidates immediately afterwards. TTL-gating
    /// it meant the list was almost never on screen (the TTL is 10 minutes), so
    /// every visit waited on a round-trip and the cache bought nothing.
    private func cachedLikedSongs(page: Int) async -> QQMusicLikedSongs? {
        guard let store = cacheStore,
              let data = await store.staleCatalog(.likedSongs, key: "page-\(page)"),
              let decoded = try? JSONDecoder().decode(QQMusicLikedSongs.self, from: data),
              !decoded.tracks.isEmpty
        else { return nil }
        return decoded
    }

    private func cacheLikedSongs(_ payload: QQMusicLikedSongs, page: Int) async {
        guard let store = cacheStore, let data = try? JSONEncoder().encode(payload) else { return }
        await store.storeCatalog(data, category: .likedSongs, key: "page-\(page)")
    }

    /// Load favorited albums (resolved to names and covers by the helper).
    func loadLikedAlbums(force: Bool = false) async {
        guard !isLoadingLikedAlbums else { return }
        if !force, !likedAlbums.isEmpty { return }
        var servedFromCache = false
        if let cached = await cachedAlbums(force: force) {
            likedAlbums = cached
            servedFromCache = true
            report(nil)
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
            userLibraryNeedsLogin = false
            report(nil)
        } catch {
            if Self.isLoginRequired(error) {
                userLibraryNeedsLogin = true
                report("需要登录后才能读取收藏", isError: true)
            } else {
                report("收藏专辑加载失败：\(noteFailure(error))", isError: true)
            }
            Log.warning("[QQMusicOnline] liked albums failed: \(error)", category: .import)
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
        var servedFromCache = false
        if let cached = await cachedUserPlaylists(force: force) {
            userPlaylists = cached
            servedFromCache = true
            report(nil)
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
            userLibraryNeedsLogin = false
            report(nil)
        } catch {
            if Self.isLoginRequired(error) {
                userLibraryNeedsLogin = true
                report("需要登录后才能读取歌单", isError: true)
            } else {
                report("我的歌单加载失败：\(noteFailure(error))", isError: true)
            }
            Log.warning("[QQMusicOnline] user playlists failed: \(error)", category: .import)
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
    /// Fired when the browse view appears rather than at launch: the browse
    /// lists are where the buttons live, and a row's heart is wrong until this
    /// has run. Only the first page is awaited — that is up to 100 tracks and
    /// covers what is on screen — with the remainder walked in the background.
    /// Skipped once the set is known.
    func ensureLikedSongMidsIfNeeded(force: Bool = false) async {
        guard force || likedSongMids.isEmpty else { return }
        guard !isRefreshingLikedMids else { return }
        isRefreshingLikedMids = true
        defer { isRefreshingLikedMids = false }
        do {
            let page = try await fetchLikedSongs(page: 1, limit: 100)
            likedSongMids = Set(page.tracks.map(\.songMid))
            userLibraryNeedsLogin = false
            if page.total > page.tracks.count {
                likedMidsCompletionTask?.cancel()
                likedMidsCompletionTask = Task { [weak self] in
                    await self?.completeLikedSongMids(expectedTotal: page.total)
                }
            }
        } catch {
            // Not surfaced: this is background accuracy work, and the heart
            // simply starts unfilled if it fails. A login prompt here would
            // interrupt browsing for a cosmetic default.
            Log.warning("[QQMusicOnline] liked mids seed failed: \(error)", category: .import)
        }
    }

    /// Open a favorited album as a track list.
    func openAlbum(id: Int, title: String, force: Bool = false) async {
        await loadPlaylistTracks(cacheKey: "album-\(id)", title: title, force: force) {
            try await self.helper.fetchAlbumTracks(albumID: id)
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
        if let wait = backoffRemaining() {
            report("访问过于频繁，请 \(Int(wait.rounded(.up))) 秒后重试", isError: true)
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
                report(nil)
                return
            }
            let groups = try await helper.fetchRadioStations()
            if let store = cacheStore, let data = try? JSONEncoder().encode(groups) {
                await store.storeCatalog(data, category: .radioStations, key: "default")
            }
            radioGroups = groups
            report(nil)
        } catch {
            report("电台加载失败：\(noteFailure(error))", isError: true)
            Log.warning("[QQMusicOnline] radio stations failed: \(error)", category: .import)
        }
    }

    /// Open a station and load its first batch of tracks.
    func openRadioStation(_ station: QQMusicRadioStation) async {
        isLoadingRadioTracks = true
        radioStationTitle = station.title
        defer { isLoadingRadioTracks = false }
        do {
            playlistTracks = try await helper.fetchRadioTracks(stationID: station.id, limit: 30, firstPlay: true)
            activeRadioStationID = station.id
            report(nil)
        } catch {
            playlistTracks = []
            report("电台曲目加载失败：\(noteFailure(error))", isError: true)
            Log.warning("[QQMusicOnline] radio tracks failed: \(error)", category: .import)
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
            report("加载更多失败：\(noteFailure(error))", isError: true)
        }
    }

    func closeRadioStation() {
        playlistTracks = []
        radioStationTitle = ""
        activeRadioStationID = nil
    }

    // MARK: - Artist search & detail

    func searchArtists(_ keyword: String, force: Bool = false) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        artistSearchKeyword = trimmed
        guard !trimmed.isEmpty else {
            searchedArtists = []
            return
        }
        if let wait = backoffRemaining() {
            report("访问过于频繁，请 \(Int(wait.rounded(.up))) 秒后重试", isError: true)
            return
        }
        isSearchingArtists = true
        defer { isSearchingArtists = false }
        do {
            if !force,
               let store = cacheStore,
               let data = await store.catalog(.artistSearch, key: trimmed),
               let cached = try? JSONDecoder().decode([QQMusicOnlineArtist].self, from: data),
               !cached.isEmpty {
                searchedArtists = cached
                report(nil)
                return
            }
            let artists = try await helper.searchArtists(keyword: trimmed, limit: 30)
            if let store = cacheStore, let data = try? JSONEncoder().encode(artists) {
                await store.storeCatalog(data, category: .artistSearch, key: trimmed)
            }
            searchedArtists = artists
            report(nil)
        } catch {
            report("歌手搜索失败：\(noteFailure(error))", isError: true)
            Log.warning("[QQMusicOnline] artist search failed: \(error)", category: .import)
        }
    }

    func clearArtistSearch() {
        artistSearchKeyword = ""
        searchedArtists = []
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

    /// Artist biography, or nil when upstream has none.
    func artistBiography(singerMid: String) async -> String? {
        let detail = try? await helper.fetchArtistDetail(singerMid: singerMid)
        let text = detail?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    func artistAlbums(singerMid: String) async throws -> [QQMusicOnlineAlbum] {
        try await helper.fetchArtistAlbums(singerMid: singerMid, limit: 100, page: 1)
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

    /// Whether this track can be liked at all. Only online-sourced tracks carry
    /// the upstream identifier; the helper resolves it to the numeric id the
    /// write endpoint needs.
    func canLike(_ track: Track) -> Bool {
        track.qqMusicSongMid?.isEmpty == false
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

    /// Refresh the set of liked song mids from the account.
    ///
    /// This is what makes the heart in the UI show a *filled* state for tracks
    /// the account already has. Without it the set is only ever populated by
    /// likes made in this session, so everything reads as "not liked".
    func refreshLikedSongMids() async {
        do {
            var mids: Set<String> = []
            var page = 1
            // The folder can hold hundreds of tracks; walk pages until the
            // reported total is covered.
            while page <= 20 {
                let payload = try await fetchLikedSongs(page: page, limit: 100)
                mids.formUnion(payload.tracks.map(\.songMid))
                if mids.count >= payload.total || payload.tracks.isEmpty { break }
                page += 1
            }
            likedSongMids = mids
        } catch {
            Log.warning("[QQMusicOnline] liked mids refresh failed: \(error)", category: .import)
        }
    }

    /// Walk the pages after the first so the liked-mid set covers the folder.
    private func completeLikedSongMids(expectedTotal: Int) async {
        var mids = likedSongMids
        var page = 2
        while page <= 20 {
            if Task.isCancelled { return }
            do {
                let payload = try await fetchLikedSongs(page: page, limit: 100)
                if payload.tracks.isEmpty { break }
                let before = mids.count
                mids.formUnion(payload.tracks.map(\.songMid))
                // Stop when the walk adds nothing new: the folder shrank, or
                // paging wrapped around.
                if mids.count == before { break }
                if mids.count >= expectedTotal { break }
                page += 1
            } catch {
                Log.warning("[QQMusicOnline] liked mids completion stopped: \(error)", category: .import)
                return
            }
        }
        if !Task.isCancelled { likedSongMids = mids }
    }

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
                report(target ? "收藏失败" : "取消收藏失败", isError: true)
                return likedSongMids.contains(mid)
            }
            if target {
                likedSongMids.insert(mid)
            } else {
                likedSongMids.remove(mid)
            }
            report(target ? "已收藏到「我喜欢」" : "已取消收藏")
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
            report((error as? LocalizedError)?.errorDescription ?? "收藏操作失败", isError: true)
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
        if let wait = backoffRemaining() {
            report("访问过于频繁，请 \(Int(wait.rounded(.up))) 秒后重试", isError: true)
            return
        }
        isLoadingToplists = true
        defer { isLoadingToplists = false }
        do {
            if let cached = await cachedToplists("default", force: force) {
                toplistGroups = cached
                report(nil)
                return
            }
            let fetched = try await helper.fetchToplistCategories()
            if let store = cacheStore,
               let data = try? JSONEncoder().encode(fetched) {
                await store.storeCatalog(data, category: .toplists, key: "default")
            }
            toplistGroups = fetched
            report(nil)
        } catch {
            report("排行榜加载失败：\(noteFailure(error))", isError: true)
            Log.warning("[QQMusicOnline] toplists failed: \(error)", category: .import)
        }
    }

    func search(_ keyword: String, force: Bool = false) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        searchKeyword = trimmed
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        if let wait = backoffRemaining() {
            report("访问过于频繁，请 \(Int(wait.rounded(.up))) 秒后重试", isError: true)
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            if let cached = await cachedTracks(.search, key: trimmed, force: force) {
                searchResults = cached
                report(nil)
                return
            }
            let fetched = try await helper.searchSongs(keyword: trimmed, limit: 30)
            await storeTracks(fetched, category: .search, key: trimmed)
            searchResults = fetched
            report(nil)
        } catch {
            // Keep the previous results; the new query simply did not land.
            report("搜索失败：\(noteFailure(error))", isError: true)
            Log.warning("[QQMusicOnline] search failed: \(error)", category: .import)
        }
    }

    func clearSearch() {
        searchKeyword = ""
        searchResults = []
    }

    func openPlaylist(id: Int, title: String, force: Bool = false) async {
        // Leaving a station's rotation behind: its id drives "load more" for a
        // station, which must not fire for a playlist.
        closeRadioStation()
        openedPlaylistID = id
        openedToplistID = nil
        openedPlaylistTotal = 0
        await loadPlaylistTracks(cacheKey: "songlist-\(id)", title: title, force: force) {
            try await self.helper.fetchPlaylistTracks(songlistId: id, limit: 100)
        }
        // The list reports its size, so the rest is pulled in the background
        // instead of making the user scroll to discover it — and so a later
        // shuffle covers the whole playlist rather than the first page.
        Task { await self.loadRemainingListTracks() }
    }

    func openToplist(id: Int, title: String, force: Bool = false) async {
        closeRadioStation()
        openedPlaylistID = nil
        openedToplistID = id
        openedPlaylistTotal = 0
        await loadPlaylistTracks(cacheKey: "toplist-\(id)", title: title, force: force) {
            try await self.helper.fetchPlaylistTracks(topId: id, limit: 100)
        }
        Task { await self.loadRemainingListTracks() }
    }

    /// Keep loading pages until the open list is complete.
    ///
    /// Called once after opening, so a playlist or ranking ends up fully loaded
    /// without the user waiting on it — which is also what lets shuffle range
    /// over the whole list rather than the part that happened to be fetched.
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

    /// Load the next page of the open playlist or ranking, if it has one.
    ///
    /// Both kinds routinely hold more tracks than one request returns (the
    /// upstream caps a page at 100), so the list used to stop at that cap with
    /// no indication there was more. The web client reports the list's own
    /// total for both, which makes "is there another page?" answerable without
    /// guessing.
    func loadMorePlaylistTracks() async {
        guard !isLoadingMorePlaylistTracks, hasMorePlaylistTracks else { return }
        isLoadingMorePlaylistTracks = true
        defer { isLoadingMorePlaylistTracks = false }

        let offset = playlistTracks.count
        do {
            let tracks: [QQMusicOnlineTrack]
            let total: Int
            if let id = openedPlaylistID {
                let page = try await fetchPlaylistPage(songlistId: id, offset: offset, limit: 100)
                tracks = page.tracks
                total = page.total
            } else if let topId = openedToplistID {
                // Rankings have no helper fallback: the helper's route takes no
                // page/offset, so it can only ever return the first batch. If
                // the web call fails there is nothing to fall back to.
                let page = try await webAPI.fetchToplistTracks(topId: topId, offset: offset, limit: 100)
                tracks = page.tracks
                total = page.total
            } else {
                return
            }
            openedPlaylistTotal = total
            let known = Set(playlistTracks.map(\.songMid))
            let fresh = tracks.filter { !known.contains($0.songMid) }
            guard !fresh.isEmpty else { return }
            playlistTracks.append(contentsOf: fresh)
            // Cached as a whole, so reopening the list shows what was already
            // paged in rather than dropping back to page one.
            await storeTracks(playlistTracks, category: .playlistTracks, key: openedListCacheKey)
        } catch {
            Log.warning("[QQMusicOnline] list paging failed: \(error)", category: .import)
        }
    }

    /// Whether the open list has tracks beyond what is loaded.
    var hasMorePlaylistTracks: Bool {
        guard openedPlaylistID != nil || openedToplistID != nil else { return false }
        guard openedPlaylistTotal > 0 else { return false }
        return playlistTracks.count < openedPlaylistTotal
    }

    /// Cache key for the list currently open, so a paged-in list is stored under
    /// the same key it was loaded with.
    private var openedListCacheKey: String {
        if let id = openedPlaylistID { return "songlist-\(id)" }
        if let topId = openedToplistID { return "toplist-\(topId)" }
        return "unknown"
    }

    private func loadPlaylistTracks(
        cacheKey: String,
        title: String,
        force: Bool = false,
        fetch: @escaping () async throws -> [QQMusicOnlineTrack]
    ) async {
        if let wait = backoffRemaining() {
            report("访问过于频繁，请 \(Int(wait.rounded(.up))) 秒后重试", isError: true)
            return
        }
        isLoadingPlaylistTracks = true
        loadedPlaylistTitle = title
        defer { isLoadingPlaylistTracks = false }
        do {
            if let cached = await cachedTracks(.playlistTracks, key: cacheKey, force: force) {
                playlistTracks = cached
                report(nil)
                // Still ask the upstream for the total so paging can be offered;
                // a cached first page must not hide the rest of the playlist.
                await refreshOpenedPlaylistTotal()
                return
            }
            let fetched = try await fetch()
            await storeTracks(fetched, category: .playlistTracks, key: cacheKey)
            playlistTracks = fetched
            await refreshOpenedPlaylistTotal()
            report(nil)
        } catch {
            // Deliberately keep `playlistTracks` as-is. A failed open must not
            // erase a list the user is already looking at.
            report("曲目加载失败：\(noteFailure(error))", isError: true)
            Log.warning("[QQMusicOnline] playlist tracks failed: \(error)", category: .import)
        }
    }

    /// Learn how many tracks the open list holds.
    ///
    /// Asked separately from the track page because the helper's route does not
    /// report it. Failure leaves the total at 0, which just means the "load
    /// more" affordance stays hidden rather than the page breaking.
    private func refreshOpenedPlaylistTotal() async {
        do {
            if let id = openedPlaylistID {
                let page = try await fetchPlaylistPage(songlistId: id, offset: 0, limit: 1)
                openedPlaylistTotal = page.total
            } else if let topId = openedToplistID {
                let page = try await webAPI.fetchToplistTracks(topId: topId, offset: 0, limit: 1)
                openedPlaylistTotal = page.total
            }
        } catch {
            openedPlaylistTotal = 0
            Log.warning("[QQMusicOnline] list total unavailable: \(error)", category: .import)
        }
    }

    func closePlaylist() {
        playlistTracks = []
        loadedPlaylistTitle = ""
        openedPlaylistID = nil
        openedToplistID = nil
        openedPlaylistTotal = 0
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
            report("需要托管资料库才能播放", isError: true)
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
            report("这首已经在队列里了", isError: true)
            return false
        }
        report("已加入下一首：\(track.title)")
        return true
    }

    // MARK: - Playback

    /// Play an online list, starting at `index`, keeping the queue fed ahead.
    ///
    /// The tapped track is downloaded and started; the rest are downloaded in
    /// the background and appended, so playback advances without a stall.
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
            report("资料库尚未就绪", isError: true)
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
        // `radioStationTitle` / `activeRadioStationID`. Those are "which station
        // is open", and they outlive a playback session — a previous visit to a
        // station used to leave this true forever, which suppressed the shuffle
        // for every later session: shuffle silently degraded to sequential over
        // whatever had been downloaded. A property of *this* playback must come
        // from this call, not from leftover browsing state.
        sessionIsRadio = pageable || isRadio
        sessionQueueSongMids = playable.map(\.songMid)
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
        report(playbackStatusMessage(for: seed))

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
        sessionQueueSongMids = []
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
    /// `keeping` is the track that must stay as the current position; it is
    /// pinned to the cursor so a mode switch or a list refresh never interrupts
    /// what is playing. Everything before it keeps its relative order (already
    /// played, so no reason to disturb it); everything after is reshuffled or
    /// left in list order.
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
        let current = playerViewModel?.currentTrack?.qqMusicSongMid
        rebuildPlaybackOrder(keeping: current)
        // The order changed, so the queue no longer reflects it. Restart the
        // loop, which now pulls from the rebuilt order.
        beginPrefetch()
    }

    /// Message shown when a session starts, so the user knows the shuffle range.
    /// Message shown when a session starts.
    ///
    /// States the shuffle range explicitly, because "shuffle" means different
    /// things depending on what was played: shuffling inside 我喜欢 walks that
    /// list, while a radio is already random and shuffling it changes nothing.
    private func playbackStatusMessage(for track: QQMusicOnlineTrack) -> String {
        if sessionIsRadio {
            return "正在播放：\(track.title)（电台随机推荐）"
        }
        guard wantsShuffle, sessionAllSongMids.count > 1 else {
            return "正在播放：\(track.title)"
        }
        return "正在播放：\(track.title)（在本列表 \(sessionAllSongMids.count) 首内随机）"
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

    /// Mark an already-imported track as user-requested.
    ///
    /// This is the automatic-to-manual transition: the audio is already on disk,
    /// so nothing is downloaded again — only its ownership changes, and it stops
    /// counting against the automatic-download cache. Idempotent.
    func promoteToUserRequested(songMid: String) async {
        guard let track = existingTrack(for: songMid) else { return }
        await recordDownloadOrigin(.userRequested, on: [track])
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

    /// Feed the player queue along `playbackOrder`.
    ///
    /// The engine's shuffle pulls its next track from whatever sits immediately
    /// after the current one, and `insertTracksAfterCurrent` writes into exactly
    /// that slot. So inserting in *our* shuffled order is what makes the engine
    /// play that order — the coordinator decides, the engine just advances. This
    /// is also why the previous code was wrong in a subtle way: it inserted in
    /// list order, which is what made shuffle indistinguishable from sequential.
    /// Feed the player queue so it always holds the next tracks of our order.
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
        sessionQueueSongMids = []
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

    /// Download a single track the user picked, without playing it.
    ///
    /// Counts as a user request, so the file is theirs: if a prefetch already
    /// fetched it, this only promotes its ownership rather than downloading it
    /// again.
    func downloadOne(_ track: QQMusicOnlineTrack) async {
        guard canDownload else {
            report("需要托管资料库才能下载", isError: true)
            return
        }
        guard !track.songMid.isEmpty else { return }
        let alreadyLocal = existingTrack(for: track.songMid) != nil
        if await materialize(track, origin: .userRequested) != nil {
            // Already on disk from playback: this changed its label, and saying
            // "downloaded" would misreport what happened.
            report(alreadyLocal ? "已转为手动下载：\(track.title)" : "已下载：\(track.title)")
        }
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
            report("需要托管资料库才能下载", isError: true)
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
            report("资料库尚未就绪", isError: true)
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
                    .appendingPathComponent("qqmusic", isDirectory: true)
            ) { [weak self] phase in
                Task { @MainActor [weak self] in
                    self?.downloadPhases[track.songMid] = phase
                }
            }
        } catch {
            let message = noteFailure(error)
            downloadPhases[track.songMid] = .failed(message)
            report("\(track.title)：\(message)", isError: true)
            Log.warning("[QQMusicOnline] download failed \(track.songMid): \(error)", category: .import)
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
            report("\(track.title)：导入资料库失败", isError: true)
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

