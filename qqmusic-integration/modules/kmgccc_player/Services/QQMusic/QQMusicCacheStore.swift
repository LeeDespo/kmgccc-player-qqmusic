//
//  QQMusicCacheStore.swift
//  kmgccc_player
//
//  On-disk cache for everything the online QQ Music source produces.
//
//  Without this, every visit to a browse page re-requested the upstream, which
//  is both slow and the fastest way to trip the upstream's rate limiting. Three
//  kinds of data are cached, each in its own subfolder of the library's
//  `QQMusic/` directory:
//
//    Catalog/   JSON payloads (recommendations, playlists, rankings, search)
//    Artwork/   cover images, keyed by their upstream URL
//
//  `QQMusic/` is deliberately a sibling of the app's own `Cache/` folder, so
//  the app's cache eviction cannot delete data this feature owns, and so it can
//  be inspected or wiped in one place. TTLs are per category because catalogue
//  data goes stale quickly while artwork never changes.
//

import CryptoKit
import Foundation

/// Which cached payload a caller is asking for. The category decides the TTL.
nonisolated enum QQMusicCacheCategory: String, Sendable {
    /// "Guess you like" radio; changes often.
    case recommendFeed
    /// Ranking structure; changes daily.
    case toplists
    /// New-song radio; refreshed daily upstream.
    case newSongs
    /// Playlist search results, keyed by the query the user typed.
    case playlistSearch
    /// "我喜欢" tracks, keyed by page. Short TTL: the user may have just liked
    /// something on their phone.
    case likedSongs
    /// The account's own playlists and favorited albums.
    case userLibrary
    /// Radio station groups; the list is stable for a long time.
    case radioStations
    /// Artist search results, keyed by query.
    case artistSearch
    /// A playlist's track list; changes occasionally.
    case playlistTracks
    /// Search results; short-lived because the user is iterating on queries.
    case search

    var timeToLive: TimeInterval {
        switch self {
        case .search: return 5 * 60
        case .recommendFeed: return 30 * 60
        case .toplists: return 6 * 60 * 60
        case .newSongs: return 6 * 60 * 60
        case .playlistSearch: return 60 * 60
        case .likedSongs, .userLibrary: return 10 * 60
        case .radioStations: return 24 * 60 * 60
        case .artistSearch: return 60 * 60
        case .playlistTracks: return 2 * 60 * 60
        }
    }
}

actor QQMusicCacheStore {

    private let paths: LibraryPaths
    private let fileManager = FileManager.default
    /// In-memory mirror so a page revisits without touching disk at all.
    private var memoryCatalog: [String: (date: Date, data: Data)] = [:]

    init(paths: LibraryPaths) {
        self.paths = paths
    }

    // MARK: - Catalog

    /// Return a cached payload when it is still fresh.
    func catalog(_ category: QQMusicCacheCategory, key: String) -> Data? {
        let cacheKey = "\(category.rawValue)|\(key)"
        if let entry = memoryCatalog[cacheKey],
           Date().timeIntervalSince(entry.date) < category.timeToLive {
            return entry.data
        }
        let url = catalogFileURL(category: category, key: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(modified) < category.timeToLive
        else {
            // Expired: drop it so a stale file cannot be served later.
            try? fileManager.removeItem(at: url)
            memoryCatalog[cacheKey] = nil
            return nil
        }
        memoryCatalog[cacheKey] = (Date(), data)
        return data
    }

    /// Return a cached payload whatever its age, for stale-while-revalidate.
    ///
    /// `catalog` answers "is this fresh enough to trust"; this answers "is there
    /// anything to show". Callers use it to paint immediately and then revalidate
    /// against the upstream, replacing the content only if it actually differs.
    ///
    /// That distinction matters because a short TTL makes `catalog` almost always
    /// miss: the "我的" lists are 10 minutes old at most by design, so a cache
    /// entry was deleted before it could ever be shown and every visit waited on
    /// three round-trips. Age-gating the *display* is not the same as age-gating
    /// the *decision to trust it*.
    ///
    /// The payload is not deleted here: a revalidation that fails should still
    /// leave the user with the last known list rather than an empty page.
    func staleCatalog(_ category: QQMusicCacheCategory, key: String) -> Data? {
        let cacheKey = "\(category.rawValue)|\(key)"
        if let entry = memoryCatalog[cacheKey] {
            return entry.data
        }
        let url = catalogFileURL(category: category, key: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        memoryCatalog[cacheKey] = (Date(), data)
        return data
    }

    func storeCatalog(_ data: Data, category: QQMusicCacheCategory, key: String) {
        memoryCatalog["\(category.rawValue)|\(key)"] = (Date(), data)
        let url = catalogFileURL(category: category, key: key)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            Log.warning("[QQMusicCache] catalog write failed key=\(key) reason=\(error)", category: .import)
        }
    }

    /// Drop catalogue entries whose payload no longer parses or that the caller
    /// considers invalid, so a bad cache cannot wedge a page permanently.
    func invalidateCatalog(_ category: QQMusicCacheCategory, key: String) {
        memoryCatalog["\(category.rawValue)|\(key)"] = nil
        try? fileManager.removeItem(at: catalogFileURL(category: category, key: key))
    }

    // MARK: - Artwork

    /// Artwork never changes for a given upstream URL, so a hit is forever.
    func artwork(for remoteURL: String) -> Data? {
        guard !remoteURL.isEmpty else { return nil }
        return try? Data(contentsOf: artworkFileURL(remoteURL))
    }

    func storeArtwork(_ data: Data, for remoteURL: String) {
        guard !remoteURL.isEmpty else { return }
        let url = artworkFileURL(remoteURL)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            Log.warning("[QQMusicCache] artwork write failed reason=\(error)", category: .import)
        }
    }

    // MARK: - Maintenance

    /// Total bytes held by the QQ Music data folder, for the settings window.
    func diskUsageBytes() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: paths.qqMusicRootURL,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Remove every cached payload, keeping the folder itself.
    func clearAll() {
        memoryCatalog.removeAll()
        for directory in [
            paths.qqMusicCatalogCacheURL,
            paths.qqMusicArtworkCacheURL,
        ] {
            try? fileManager.removeItem(at: directory)
        }
    }

    // MARK: - Paths

    private func catalogFileURL(category: QQMusicCacheCategory, key: String) -> URL {
        paths.qqMusicCatalogCacheURL
            .appendingPathComponent(category.rawValue, isDirectory: true)
            .appendingPathComponent("\(Self.safeName(key)).json")
    }

    private func artworkFileURL(_ remoteURL: String) -> URL {
        let ext = URL(string: remoteURL)?.pathExtension
        let suffix = (ext?.isEmpty == false) ? ".\(ext!)" : ".img"
        return paths.qqMusicArtworkCacheURL
            .appendingPathComponent("\(Self.safeName(remoteURL))\(suffix)")
    }

    /// Hash the key so arbitrary upstream URLs and ids are always safe filenames.
    private static func safeName(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(40).description
    }
}
