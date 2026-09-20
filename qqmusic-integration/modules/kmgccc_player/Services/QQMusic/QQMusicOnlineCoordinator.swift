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
    /// Writes in flight, so the button can show progress and not double-fire.
    private(set) var pendingLikeSongMids: Set<String> = []
    private var isLoadingMoreLikedSongs = false
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
    /// Whether the web path has ever worked. Read only to decide whether a
    /// fallback is worth logging: a user who is simply not logged in would
    /// otherwise get a warning on every call.
    private var webLikedSongsSucceeded = false

    /// On-disk cache for catalogue payloads and artwork. Nil until a library
    /// session supplies paths, which also disables caching rather than failing.
    private(set) var cacheStore: QQMusicCacheStore?

    /// One loader for the whole session, so cover fetches coalesce across rows
    /// and stay within the concurrency cap instead of each row racing its own.
    /// Built together with the cache store so it always has the right one.
    private(set) var artworkLoader = QQMusicArtworkLoader(cache: nil)

    /// Library root, exposed so the QQ Music window can report and reveal cache.
    var libraryRootURL: URL? { paths?.rootURL }

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
    /// Song mids already handed to the player queue this session. Keeps the
    /// prefetch loop from re-inserting a track that is already queued ahead.
    private var queuedSongMids: Set<String> = []

    init(
        helper: QQMusicHelperProcess = .shared,
        downloader: QQMusicDownloadService = QQMusicDownloadService(),
        webAPI: QQMusicWebAPI = .shared
    ) {
        self.helper = helper
        self.downloader = downloader
        self.webAPI = webAPI
    }

    /// Fetch one page of "我喜欢", preferring the direct HTTP path.
    ///
    /// Pilot for moving read paths off the helper: the same endpoint answers a
    /// plain HTTPS request in about a quarter of the time the helper takes,
    /// because the helper pays for a process and a fresh client per call.
    ///
    /// The helper remains the fallback, and is still the only thing that can log
    /// in. If the web path fails for any reason — credential file unreadable,
    /// upstream shape changed, transport error — the call silently falls back
    /// rather than surfacing a failure the user cannot act on.
    private func fetchLikedSongs(page: Int, limit: Int) async throws -> QQMusicLikedSongs {
        do {
            let result = try await webAPI.fetchLikedSongs(page: page, limit: limit)
            webLikedSongsSucceeded = true
            return result
        } catch {
            if webLikedSongsSucceeded {
                Log.warning(
                    "[QQMusicOnline] web liked-songs failed, falling back to helper: \(error)",
                    category: .import
                )
            }
            webLikedSongsSucceeded = false
            return try await helper.fetchLikedSongs(page: page, limit: limit)
        }
    }

    // MARK: - Status

    private func report(_ message: String?, isError: Bool = false) {
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
    private func preloadUserLibrary() async {
        await loadLikedSongs()
        await loadLikedAlbums()
        await loadUserPlaylists()
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

    func loadInitialContentIfNeeded() async {
        guard recommendFeed.isEmpty, toplistGroups.isEmpty else { return }
        async let feed: Void = loadRecommendFeed()
        async let toplists: Void = loadToplists()
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
    func searchPlaylists(_ keyword: String) async {
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
            if let cached = await cachedPlaylists(.playlistSearch, key: trimmed, force: false) {
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

    var hasMoreLikedSongs: Bool { likedSongs.count < likedSongsTotal }

    /// Load the first page of "我喜欢".
    /// Load "我喜欢".
    ///
    /// Cache-first by design: the account's favourites change rarely and only
    /// slightly, so a cached page is shown immediately and the network result
    /// is applied only if it actually differs. That keeps the page instant on
    /// every visit instead of re-fetching hundreds of tracks each time.
    func loadLikedSongs(force: Bool = false) async {
        guard !isLoadingLikedSongs else { return }
        if !force, !likedSongs.isEmpty { return }

        // Serve what we have first.
        var servedFromCache = false
        if let cached = await cachedLikedSongs(page: 1) {
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
            let changed = page.total != likedSongsTotal
                || page.tracks.map(\.songMid) != likedSongs.map(\.songMid)
            await cacheLikedSongs(page, page: 1)
            if changed || !servedFromCache {
                likedSongs = page.tracks
                likedSongsTotal = page.total
                likedSongsPage = 1
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
        likedSongs.append(contentsOf: tracks.filter { !known.contains($0.songMid) })
        likedSongsPage = page
        likedSongsTotal = max(total, likedSongs.count)
        report(nil)
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
        if let cached = await cachedAlbums(force: false) {
            likedAlbums = cached
            servedFromCache = true
            report(nil)
        }

        isLoadingLikedAlbums = true
        defer { isLoadingLikedAlbums = false }
        do {
            let albums = try await helper.fetchLikedAlbums()
            await cacheAlbums(albums)
            // Only replace what is on screen when the list actually differs —
            // the albums set changes rarely, and swapping it needlessly makes
            // covers flicker.
            if !servedFromCache || albums.map(\.identity) != likedAlbums.map(\.identity) {
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
        if let cached = await cachedUserPlaylists(force: false) {
            userPlaylists = cached
            servedFromCache = true
            report(nil)
        }

        isLoadingUserPlaylists = true
        defer { isLoadingUserPlaylists = false }
        do {
            let playlists = try await helper.fetchUserPlaylists()
            await cacheUserPlaylists(playlists)
            // Compare by id and track count: a playlist gaining a track should
            // refresh, but an unchanged list should not be re-rendered.
            let changed = playlists.map { "\($0.id):\($0.songCount ?? -1)" }
                != userPlaylists.map { "\($0.id):\($0.songCount ?? -1)" }
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
    func loadUserLibraryIfNeeded() async {
        async let liked: Void = loadLikedSongs()
        async let albums: Void = loadLikedAlbums()
        async let playlists: Void = loadUserPlaylists()
        _ = await (liked, albums, playlists)
    }

    /// Make sure the liked-mid set is populated, so hearts are accurate.
    ///
    /// Fired when the browse view appears rather than at launch: the browse
    /// lists are where the buttons live, and a row's heart is wrong until this
    /// has run. Only the first page is awaited — that is up to 100 tracks and
    /// covers what is on screen — with the remainder walked in the background.
    /// Skipped once the set is known.
    func ensureLikedSongMidsIfNeeded() async {
        guard likedSongMids.isEmpty, !isRefreshingLikedMids else { return }
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
    func openAlbum(id: Int, title: String) async {
        await loadPlaylistTracks(cacheKey: "album-\(id)", title: title) {
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

    func searchArtists(_ keyword: String) async {
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
            if let store = cacheStore,
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
    func toggleLike(songMid mid: String) async -> Bool {
        guard !mid.isEmpty else { return false }
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
            // The change also invalidates the cached liked list.
            if let store = cacheStore {
                await store.invalidateCatalog(.likedSongs, key: "page-1")
            }
            // Cleared so the next visit refetches. The total has to be reset
            // too: leaving the old one makes `hasMoreLikedSongs` briefly lie,
            // which shows a "load more" affordance for a list that is gone.
            likedSongs = []
            likedSongsPage = 0
            likedSongsTotal = 0
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

    func search(_ keyword: String) async {
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
            if let cached = await cachedTracks(.search, key: trimmed, force: false) {
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

    func openPlaylist(id: Int, title: String) async {
        await loadPlaylistTracks(cacheKey: "songlist-\(id)", title: title) {
            try await self.helper.fetchPlaylistTracks(songlistId: id, limit: 100)
        }
    }

    func openToplist(id: Int, title: String) async {
        await loadPlaylistTracks(cacheKey: "toplist-\(id)", title: title) {
            try await self.helper.fetchPlaylistTracks(topId: id, limit: 100)
        }
    }

    private func loadPlaylistTracks(
        cacheKey: String,
        title: String,
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
            if let cached = await cachedTracks(.playlistTracks, key: cacheKey, force: false) {
                playlistTracks = cached
                report(nil)
                return
            }
            let fetched = try await fetch()
            await storeTracks(fetched, category: .playlistTracks, key: cacheKey)
            playlistTracks = fetched
            report(nil)
        } catch {
            // Deliberately keep `playlistTracks` as-is. A failed open must not
            // erase a list the user is already looking at.
            report("曲目加载失败：\(noteFailure(error))", isError: true)
            Log.warning("[QQMusicOnline] playlist tracks failed: \(error)", category: .import)
        }
    }

    func closePlaylist() {
        playlistTracks = []
        loadedPlaylistTitle = ""
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
        guard let imported = await materialize(track) else { return false }

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
        pageable: Bool = false
    ) async {
        guard canDownload, let playerViewModel else {
            report("资料库尚未就绪", isError: true)
            return
        }
        let playable = tracks.filter { !$0.songMid.isEmpty }
        guard playable.indices.contains(index) else { return }

        // A new session replaces the previous prefetch loop.
        prefetchTask?.cancel()
        sessionTracks = playable
        sessionSupportsPaging = pageable
        sessionQueueSongMids = playable.map(\.songMid)
        // Everything on screen counts as seen, so a later refresh cannot
        // re-queue a track the session already holds.
        seenFeedSongMids.formUnion(playable.map(\.songMid))

        let seed = playable[index]

        // Build the playing order across the whole list before anything starts.
        // Doing it here, rather than letting the engine shuffle a one-track
        // queue, is what makes shuffle cover every track instead of the handful
        // downloaded so far.
        //
        // `queuedSongMids` is cleared first, and the rebuild is forced, because
        // this is a new session: keeping either from the previous one would make
        // the prefetch loop believe tracks were already queued and decline to
        // feed them.
        queuedSongMids = []
        playbackOrder = []
        orderIsShuffled = !wantsShuffle  // forces the rebuild below to take effect
        sessionAllSongMids = playable.map(\.songMid)
        rebuildPlaybackOrder(keeping: seed.songMid)

        guard let first = await materialize(seed) else { return }

        // Start the tapped track, then let the queue grow behind it.
        playerViewModel.playTracks([first], startingAt: 0)
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
        prefetchTask?.cancel()
        prefetchTask = nil
        playbackModeObserver?.cancel()
        playbackModeObserver = nil
        sessionTracks = []
        sessionQueueSongMids = []
        sessionAllSongMids = []
        playbackOrder = []
        orderIsShuffled = false
        queuedSongMids = []
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

        let shuffle = wantsShuffle
        // The anchor is the playing track; without one, fall back to the head.
        let anchor = currentMid.flatMap { mids.contains($0) ? $0 : nil } ?? mids[0]
        let anchorIndex = mids.firstIndex(of: anchor) ?? 0

        // Already-played portion is preserved verbatim: reshuffling behind the
        // cursor would make "previous" jump somewhere unrelated.
        let played = Array(mids[..<anchorIndex])
        var upcoming = Array(mids[anchorIndex...])
        let first = upcoming.removeFirst()

        if shuffle {
            var rng = SystemRandomNumberGenerator()
            upcoming.shuffle(using: &rng)
        }
        let rebuilt = played + [first] + upcoming

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

    /// Where the current track sits in the playing order.
    private func orderPosition(of songMid: String?) -> Int? {
        guard let songMid else { return nil }
        return playbackOrder.firstIndex(of: songMid)
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
    private func playbackStatusMessage(for track: QQMusicOnlineTrack) -> String {
        guard wantsShuffle, sessionAllSongMids.count > 1 else {
            return "正在播放：\(track.title)"
        }
        return "正在播放：\(track.title)（随机播放，共 \(sessionAllSongMids.count) 首）"
    }

    /// Download `track` (or reuse an already-imported copy) and return its
    /// library `Track`. Returns nil when the upstream withholds it.
    ///
    /// The imported `Track` comes straight from the import result rather than a
    /// library re-lookup: the in-memory library snapshot is refreshed
    /// asynchronously, so looking it up here would race and drop the track.
    private func materialize(_ track: QQMusicOnlineTrack) async -> Track? {
        if let existing = existingTrack(for: track.songMid) {
            importedSongMids.insert(track.songMid)
            return existing
        }
        let imported = await downloadAndImport(track)
        return imported.first
    }
    /// Find an already-imported track for a song mid, so a re-tap reuses the
    /// local copy instead of downloading it again.
    private func existingTrack(for songMid: String) -> Track? {
        libraryViewModel?.allTracks.first { $0.qqMusicSongMid == songMid }
    }

    // MARK: - Background prefetch

    private func beginPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            await self?.runPrefetchLoop()
        }
    }

    /// Feed the player queue along `playbackOrder`.
    ///
    /// The engine's shuffle pulls its next track from whatever sits immediately
    /// after the current one, and `insertTracksAfterCurrent` writes into exactly
    /// that slot. So inserting in *our* shuffled order is what makes the engine
    /// play that order — the coordinator decides, the engine just advances. This
    /// is also why the previous code was wrong in a subtle way: it inserted in
    /// list order, which is what made shuffle indistinguishable from sequential.
    private func runPrefetchLoop() async {
        guard let playerViewModel else { return }

        while !Task.isCancelled {
            // The user moved to a different source; stop feeding this queue.
            guard let playingMid = playerViewModel.currentTrack?.qqMusicSongMid,
                  let playingPosition = orderPosition(of: playingMid) else { return }

            let depth = max(0, AppSettings.shared.qqMusicPrefetchDepth)
            guard depth > 0 else { return }

            // How much of our order is already sitting in the queue ahead.
            let ahead = playbackOrder[(playingPosition + 1)...]
            let queuedAhead = ahead.reduce(0) { $0 + (queuedSongMids.contains($1) ? 1 : 0) }
            if queuedAhead >= depth {
                // The queue is deep enough; wait for playback to consume some
                // rather than downloading the whole list.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            guard let nextMid = ahead.first(where: { !queuedSongMids.contains($0) }) else {
                // Everything in the known order is queued. A pageable feed can
                // supply more; a fixed list is finished, so the loop stops.
                guard sessionSupportsPaging else { return }
                let added = await extendRecommendFeed()
                if added.isEmpty {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                continue
            }

            // Mark before downloading: a failure must not make the loop retry
            // the same track forever. It is skipped and the order moves on.
            queuedSongMids.insert(nextMid)
            guard let online = trackInSession(nextMid) else { continue }
            guard let imported = await materialize(online) else { continue }
            guard !Task.isCancelled else { return }

            // Inserted one at a time, in order. Each insert lands immediately
            // after the current track (or after the previously inserted one),
            // so the queue builds up in exactly `playbackOrder` sequence.
            playerViewModel.insertTracksAfterCurrent([imported])
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
        // The player moved on; make sure the next tracks are queued.
        if let mid, sessionTracks.contains(where: { $0.songMid == mid }) {
            if prefetchTask == nil || prefetchTask?.isCancelled == true {
                beginPrefetch()
            }
        }
    }

    // MARK: - Download & import

    func phase(for songMid: String) -> QQMusicDownloadPhase {
        downloadPhases[songMid] ?? .idle
    }

    func isImported(_ songMid: String) -> Bool {
        importedSongMids.contains(songMid) || existingTrack(for: songMid) != nil
    }

    func isPlaying(_ songMid: String) -> Bool {
        activePlayingSongMid == songMid
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
        return imported
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
