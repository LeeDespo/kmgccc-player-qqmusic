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
    /// Index of the next track to prefetch into the player queue.
    private var nextPrefetchIndex = 0
    /// Guard so two prefetch loops never run at once.
    private var prefetchTask: Task<Void, Never>?
    private var trackChangeObserver: Task<Void, Never>?
    /// Backoff after upstream rate limiting, to stop hammering the API.
    private var rateLimitedUntil: Date?

    init(
        helper: QQMusicHelperProcess = .shared,
        downloader: QQMusicDownloadService = QQMusicDownloadService()
    ) {
        self.helper = helper
        self.downloader = downloader
    }

    // MARK: - Status

    private func report(_ message: String?, isError: Bool = false) {
        statusMessage = message
        statusIsError = isError
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
        do {
            if let cached = await cachedTracks(.recommendFeed, key: "default", force: force) {
                recommendFeed = cached
                seenFeedSongMids = Set(cached.map(\.songMid))
                report(nil)
                return
            }
            let fetched = try await helper.fetchRecommendFeed()
            await storeTracks(fetched, category: .recommendFeed, key: "default")
            recommendFeed = fetched
            seenFeedSongMids = Set(fetched.map(\.songMid))
            report(nil)
        } catch {
            report("推荐加载失败：\(noteFailure(error))", isError: true)
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

            // Keep the playback session in step with what is on screen, so a
            // track added by scrolling is also reachable when playing.
            if !sessionTracks.isEmpty, sessionSupportsPaging {
                sessionTracks.append(contentsOf: fresh)
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
        do {
            if let cached = await cachedTracks(.newSongs, key: region.rawValue, force: force) {
                newSongs = cached
                report(nil)
                return
            }
            let fetched = try await helper.fetchNewSongs(region: region)
            await storeTracks(fetched, category: .newSongs, key: region.rawValue)
            newSongs = fetched
            report(nil)
        } catch {
            report("新歌加载失败：\(noteFailure(error))", isError: true)
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
    func loadLikedSongs(force: Bool = false) async {
        guard !isLoadingLikedSongs else { return }
        if !force, !likedSongs.isEmpty { return }
        isLoadingLikedSongs = true
        defer { isLoadingLikedSongs = false }
        do {
            if !force, let cached = await cachedLikedSongs(page: 1) {
                likedSongs = cached.tracks
                likedSongsTotal = cached.total
                likedSongsPage = 1
                userLibraryNeedsLogin = false
                report(nil)
                return
            }
            let page = try await helper.fetchLikedSongs(page: 1, limit: 100)
            await cacheLikedSongs(page, page: 1)
            likedSongs = page.tracks
            likedSongsTotal = page.total
            likedSongsPage = 1
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
            let page = try await helper.fetchLikedSongs(page: next, limit: 100)
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

    private func cachedLikedSongs(page: Int) async -> QQMusicLikedSongs? {
        guard let store = cacheStore,
              let data = await store.catalog(.likedSongs, key: "page-\(page)"),
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
        isLoadingLikedAlbums = true
        defer { isLoadingLikedAlbums = false }
        do {
            if !force, let cached = await cachedAlbums(force: force) {
                likedAlbums = cached
                report(nil)
                return
            }
            let albums = try await helper.fetchLikedAlbums()
            await cacheAlbums(albums)
            likedAlbums = albums
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
              let data = await store.catalog(.userLibrary, key: "albums"),
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
        isLoadingUserPlaylists = true
        defer { isLoadingUserPlaylists = false }
        do {
            if !force, let cached = await cachedUserPlaylists(force: force) {
                userPlaylists = cached
                report(nil)
                return
            }
            let playlists = try await helper.fetchUserPlaylists()
            await cacheUserPlaylists(playlists)
            userPlaylists = playlists
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
              let data = await store.catalog(.userLibrary, key: "playlists"),
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

    /// Open a favorited album as a track list.
    func openAlbum(id: Int, title: String) async {
        await loadPlaylistTracks(cacheKey: "album-\(id)", title: title) {
            try await self.helper.fetchAlbumTracks(albumID: id)
        }
    }

    /// Whether an error means the user must log in, rather than a real failure.
    private static func isLoginRequired(_ error: Error) -> Bool {
        let text = String(describing: error)
        return text.contains("需要登录")
            || text.contains("登录凭证已过期")
            || text.contains("LoginExpired")
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

    func artistSongs(singerMid: String, sort: ArtistSongSort) async throws -> [QQMusicOnlineTrack] {
        try await helper.fetchArtistSongs(singerMid: singerMid, limit: 100, page: 1, sort: sort.rawValue)
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
        return likedSongMids.contains(mid)
    }

    func isLikePending(_ track: Track) -> Bool {
        guard let mid = track.qqMusicSongMid else { return false }
        return pendingLikeSongMids.contains(mid)
    }

    /// Whether this track can be liked at all. Only online-sourced tracks carry
    /// the upstream identifier; the helper resolves it to the numeric id the
    /// write endpoint needs.
    func canLike(_ track: Track) -> Bool {
        track.qqMusicSongMid?.isEmpty == false
    }

    /// Refresh the set of liked song mids from the account.
    func refreshLikedSongMids() async {
        do {
            var mids: Set<String> = []
            var page = 1
            // The folder can hold hundreds of tracks; walk pages until the
            // reported total is covered.
            while page <= 20 {
                let payload = try await helper.fetchLikedSongs(page: page, limit: 100)
                mids.formUnion(payload.tracks.map(\.songMid))
                if mids.count >= payload.total || payload.tracks.isEmpty { break }
                page += 1
            }
            likedSongMids = mids
        } catch {
            Log.warning("[QQMusicOnline] liked mids refresh failed: \(error)", category: .import)
        }
    }

    /// Toggle the favorite state of a library track.
    ///
    /// The upstream applies the change asynchronously, so the local set is
    /// updated optimistically and rolled back if the write is rejected.
    @discardableResult
    func toggleLike(_ track: Track) async -> Bool {
        guard let mid = track.qqMusicSongMid, !mid.isEmpty else { return false }
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
            likedSongs = []
            likedSongsPage = 0
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
        force: Bool
    ) async -> [QQMusicOnlineTrack]? {
        guard !force, let store = cacheStore else { return nil }
        guard let data = await store.catalog(category, key: key) else { return nil }
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
        nextPrefetchIndex = index + 1
        // Everything on screen counts as seen, so a later refresh cannot
        // re-queue a track the session already holds.
        seenFeedSongMids.formUnion(playable.map(\.songMid))

        let seed = playable[index]
        guard let first = await materialize(seed) else { return }

        // Start the tapped track, then let the queue grow behind it.
        playerViewModel.playTracks([first], startingAt: 0)
        activePlayingSongMid = seed.songMid
        report("正在播放：\(seed.title)")

        observeTrackChanges()
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
        sessionTracks = []
        sessionQueueSongMids = []
        nextPrefetchIndex = 0
        activePlayingSongMid = nil
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

    /// Walk forward through the session, downloading each track and appending
    /// it to the player queue. Exits when the session is replaced, the list
    /// runs out, or the user plays something outside this session.
    private func runPrefetchLoop() async {
        guard let playerViewModel else { return }
        while !Task.isCancelled {
            // The list can grow while playing (guess-you-like paging), so the
            // bound is re-read every iteration rather than hoisted.
            guard nextPrefetchIndex < sessionTracks.count else {
                guard sessionSupportsPaging else { return }
                // Feed session is exhausted: pull another page so playback can
                // continue instead of stopping at the end of the visible list.
                let added = await extendRecommendFeed()
                if added.isEmpty {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                continue
            }

            // The user moved to a different source; stop feeding this queue.
            guard let playingPosition = currentSessionPosition() else { return }

            // Download at most `prefetchDepth` tracks beyond the one playing.
            // A deeper queue is not built on purpose: the whole point of the
            // online source is to fetch what is about to be heard, not to
            // mirror an entire playlist onto disk.
            let depth = max(0, AppSettings.shared.qqMusicPrefetchDepth)
            guard depth > 0 else { return }
            if nextPrefetchIndex > playingPosition + depth {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            let track = sessionTracks[nextPrefetchIndex]
            nextPrefetchIndex += 1
            guard let imported = await materialize(track) else {
                // One unavailable track must not end the session.
                continue
            }
            guard !Task.isCancelled else { return }
            playerViewModel.insertTracksAfterCurrent([imported])
        }
    }

    /// Index of the currently playing track within the session, or nil when the
    /// player is on something that is not part of this session.
    private func currentSessionPosition() -> Int? {
        guard let mid = playerViewModel?.currentTrack?.qqMusicSongMid else { return nil }
        return sessionTracks.firstIndex { $0.songMid == mid }
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
