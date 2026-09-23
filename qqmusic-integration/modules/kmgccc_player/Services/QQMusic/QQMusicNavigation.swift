//
//  QQMusicNavigation.swift
//  kmgccc_player
//
//  Page stack for the online browse surface.
//
//  The library side of the app keeps navigation in two places: which list is
//  selected lives in `LibraryViewModel.currentSelection`, and the back/forward
//  history lives in `UIStateViewModel.homeBackStack`. The online surface has no
//  equivalent notion of a "selection" — every page is reached by drilling in
//  from the landing page — so a single stack serves both roles here.
//
//  Why a stack rather than the segmented control it replaces: the app's own
//  pages have no in-page tab strip. Which entity you are looking at comes from
//  the sidebar (for library pages) or from the page's 220pt header (for detail
//  pages), and the only way back is the toolbar's back/forward pill. Modelling
//  the online pages the same way is what lets the toolbar drive them, and it
//  removes the last piece of chrome the online surface was drawing for itself.
//

import Foundation
import Observation

/// Which content type a search is running against.
///
/// The online search backend has separate endpoints per type, so the type is
/// part of the page identity: "搜索 歌曲" and "搜索 歌手" are different pages
/// with different results, exactly as the app treats its own list pages.
nonisolated enum QQMusicSearchKind: String, Hashable, Sendable, CaseIterable, Identifiable {
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

    var placeholder: String {
        switch self {
        case .songs: return "搜索在线歌曲"
        case .artists: return "搜索歌手"
        case .playlists: return "搜索歌单"
        }
    }
}

/// The artist a page is about.
///
/// A value type of its own rather than the whole `QQMusicOnlineArtist`: the
/// page is identified by the singer mid, and these fields are what the header
/// needs to draw before the artist's songs have loaded.
nonisolated struct QQMusicArtistRef: Hashable, Sendable {
    var singerMid: String
    var name: String
    var coverURL: String?
    var songCount: Int?
    var albumCount: Int?

    init(singerMid: String, name: String, coverURL: String? = nil, songCount: Int? = nil, albumCount: Int? = nil) {
        self.singerMid = singerMid
        self.name = name
        self.coverURL = coverURL
        self.songCount = songCount
        self.albumCount = albumCount
    }

    init(_ artist: QQMusicOnlineArtist) {
        self.singerMid = artist.singerMid
        self.name = artist.name
        self.coverURL = artist.coverURL
        self.songCount = artist.songCount
        self.albumCount = artist.albumCount
    }
}

/// One page on the online browse stack.
///
/// Titles are carried inline for the entity pages (`playlist(id:title:)`) so a
/// page can draw its header before the network answers — the same reason the
/// coordinator already received a `title` alongside every open call.
nonisolated enum QQMusicPage: Hashable, Sendable {
    /// The landing page: the shelves.
    case home
    /// 我喜欢 — the account's liked songs, presented as a playlist detail.
    case likedSongs
    /// 收藏歌单 — the account's own and collected playlists, as a list page.
    case userPlaylists
    /// 收藏专辑 — the account's collected albums, as a list page.
    case likedAlbums
    /// 新歌电台 for one region, as a track list page.
    case newSongs(QQMusicNewSongRegion)
    /// 排行榜 — the ranking index, grouped, as a list page.
    case toplists
    /// 电台 — the station index, grouped, as a list page.
    case radio
    /// 猜你喜欢 — the endless recommendation feed.
    case recommend
    /// Search results for one content type.
    case search(QQMusicSearchKind)

    // Entity detail pages.
    case playlist(id: Int, title: String)
    case album(id: Int, title: String)
    case toplist(id: Int, title: String)
    case radioStation(id: Int, title: String)
    case artist(QQMusicArtistRef)

    /// Human-readable title, used by the toolbar and by accessibility.
    var title: String {
        switch self {
        case .home: return "QQ 音乐"
        case .likedSongs: return "我喜欢"
        case .userPlaylists: return "收藏歌单"
        case .likedAlbums: return "收藏专辑"
        case .newSongs(let region): return "新歌电台 · \(region.displayName)"
        case .toplists: return "排行榜"
        case .radio: return "电台"
        case .recommend: return "猜你喜欢"
        case .search(let kind): return "搜索 · \(kind.title)"
        case .playlist(_, let title): return title
        case .album(_, let title): return title
        case .toplist(_, let title): return title
        case .radioStation(_, let title): return title
        case .artist(let ref): return ref.name
        }
    }

    /// Whether this page's list has a fixed end.
    ///
    /// Describes the *page kind*: an endless feed has no "all", so a whole-list
    /// action there would promise something it cannot deliver.
    ///
    /// Note that the batch-download predicate is deliberately **not** derived
    /// from this — it is `QQMusicOnlineCoordinator.offersBatchDownload`, which
    /// this cannot answer because it also calls the landing page finite (there is
    /// no list there) and because it does not know which pages hold tracks rather
    /// than entities.
    var isFiniteList: Bool {
        switch self {
        // A station's rotation and the recommendation feed are endless; the
        // others here are not track lists at all.
        case .recommend, .search, .radio, .radioStation, .artist, .toplists,
             .userPlaylists, .likedAlbums:
            return false
        case .home, .likedSongs, .newSongs, .playlist, .album, .toplist:
            return true
        }
    }

    /// Stable key for `.task`/`.onAppear` keying, so re-entering a page reloads
    /// only when the page actually changed.
    var loadKey: String {
        switch self {
        case .home: return "home"
        case .likedSongs: return "liked"
        case .userPlaylists: return "userPlaylists"
        case .likedAlbums: return "likedAlbums"
        case .newSongs(let region): return "newSongs:\(region.rawValue)"
        case .toplists: return "toplists"
        case .radio: return "radio"
        case .recommend: return "recommend"
        case .search(let kind): return "search:\(kind.rawValue)"
        case .playlist(let id, _): return "playlist:\(id)"
        case .album(let id, _): return "album:\(id)"
        case .toplist(let id, _): return "toplist:\(id)"
        case .radioStation(let id, _): return "station:\(id)"
        case .artist(let ref): return "artist:\(ref.singerMid)"
        }
    }
}

/// Back/forward stack for the online browse surface.
///
/// Kept separate from `QQMusicOnlineCoordinator`'s data state because the two
/// answer different questions: the coordinator owns what has been fetched, this
/// owns where the user is. A page that has been visited before is still
/// re-entered from the stack — the coordinator's loaders are idempotent, so
/// re-entry is cheap and the page always reflects current data.
@Observable
@MainActor
final class QQMusicNavigation {

    /// Pages above the landing page, most recent last. Empty means the landing
    /// page is showing, which is why `canGoBack` tracks emptiness rather than
    /// counting a root entry.
    private(set) var stack: [QQMusicPage] = []
    private(set) var forwardStack: [QQMusicPage] = []

    /// The page on screen. `nil` means the landing page.
    var current: QQMusicPage? { stack.last }

    /// What the router should draw, landing page included.
    var displayed: QQMusicPage { stack.last ?? .home }

    var canGoBack: Bool { !stack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Change identity for the router's load trigger.
    var displayKey: String { displayed.loadKey }

    /// Drill into a page. Forward history is discarded, as in any browser.
    func push(_ page: QQMusicPage) {
        guard page != stack.last else { return }
        stack.append(page)
        forwardStack.removeAll()
    }

    /// Replace the page on screen without growing the stack.
    ///
    /// Used for a change of *filter* rather than of place: switching the region
    /// on 新歌电台 or the content type on search stays one page deep, so back
    /// still returns to where the user came from instead of stepping through
    /// each value they tried.
    func replaceTop(with page: QQMusicPage) {
        guard !stack.isEmpty else {
            push(page)
            return
        }
        guard stack[stack.count - 1] != page else { return }
        stack[stack.count - 1] = page
        forwardStack.removeAll()
    }

    @discardableResult
    func goBack() -> QQMusicPage? {
        guard let popped = stack.popLast() else { return nil }
        forwardStack.append(popped)
        return stack.last
    }

    @discardableResult
    func goForward() -> QQMusicPage? {
        guard let next = forwardStack.popLast() else { return nil }
        stack.append(next)
        return next
    }

    /// Return to the landing page, dropping all history.
    ///
    /// This is what the sidebar entry does: entering the online source from the
    /// sidebar is the same "start over" gesture as clicking 主页 in the library.
    func popToRoot() {
        stack.removeAll()
        forwardStack.removeAll()
    }
}
