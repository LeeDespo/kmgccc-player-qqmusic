//
//  QQMusicArtworkView.swift
//  kmgccc_player
//
//  Cover image for an online track or playlist, served through the QQ Music
//  cache.
//
//  `AsyncImage` was not usable here: it goes through URLSession's own cache,
//  which lives outside the library and is invisible to the feature's cache
//  settings — so scrolling a list re-requested every cover. This view asks the
//  cache store first and only hits the network on a miss, then writes the
//  result back into the QQMusic/Artwork folder.
//

import SwiftUI

struct QQMusicArtworkView: View {

    let urlString: String?
    /// Rendered size; also used to avoid re-decoding for every row.
    var size: CGFloat
    var cornerRadius: CGFloat = 5

    @Environment(\.qqMusicArtworkLoader) private var loader
    @State private var image: NSImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .overlay {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: size * 0.32))
                                .foregroundStyle(.tertiary)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: urlString) {
            await load()
        }
    }

    private func load() async {
        image = nil
        guard let urlString, !urlString.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        image = await loader?.image(for: urlString)
    }
}

/// Loads cover data, consulting the QQ Music cache before the network.
///
/// A single shared instance per session: rows deep in a list must not each get
/// their own, or the in-flight coalescing below would not work and the same
/// cover could be fetched several times over.
///
/// Concurrency is capped deliberately. A 100-row list would otherwise open 100
/// sockets at once, which is slow to start and looks like abuse to the CDN.
@MainActor
final class QQMusicArtworkLoader {

    private let cache: QQMusicCacheStore?
    private let session: URLSession

    /// Decoded images shared across every row, so scrolling back up does not
    /// re-read and re-decode the same cover from disk.
    private static let imageCache = NSCache<NSString, NSImage>()

    /// In-flight fetches keyed by URL, so N rows wishing for the same cover
    /// share one request instead of racing to download it N times.
    private var inFlight: [String: Task<Data?, Never>] = [:]

    /// Bounds simultaneous downloads; the rest queue behind these.
    private let limiter: AsyncSemaphore

    init(
        cache: QQMusicCacheStore?,
        session: URLSession = QQMusicDownloadService.makeDefaultSession(),
        maxConcurrent: Int = 6
    ) {
        self.cache = cache
        self.session = session
        self.limiter = AsyncSemaphore(limit: maxConcurrent)
    }

    func image(for remoteURL: String) async -> NSImage? {
        if let cachedImage = Self.imageCache.object(forKey: remoteURL as NSString) {
            return cachedImage
        }
        guard let data = await artwork(for: remoteURL), let image = NSImage(data: data) else {
            return nil
        }
        Self.imageCache.setObject(image, forKey: remoteURL as NSString)
        return image
    }

    func artwork(for remoteURL: String) async -> Data? {
        if let cached = await cache?.artwork(for: remoteURL) {
            return cached
        }
        if let existing = inFlight[remoteURL] {
            return await existing.value
        }
        let task = Task<Data?, Never> { [session, cache, limiter] in
            await limiter.acquire()
            defer { Task { await limiter.release() } }
            guard let url = URL(string: remoteURL) else { return nil }
            var request = URLRequest(url: url)
            // The CDN rejects requests without a QQ Music referer.
            request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty
            else { return nil }
            await cache?.storeArtwork(data, for: remoteURL)
            return data
        }
        inFlight[remoteURL] = task
        defer { inFlight[remoteURL] = nil }
        return await task.value
    }
}

private struct QQMusicArtworkLoaderKey: EnvironmentKey {
    static let defaultValue: QQMusicArtworkLoader? = nil
}

extension EnvironmentValues {
    var qqMusicArtworkLoader: QQMusicArtworkLoader? {
        get { self[QQMusicArtworkLoaderKey.self] }
        set { self[QQMusicArtworkLoaderKey.self] = newValue }
    }
}


/// Minimal counting semaphore for bounding concurrent network work.
///
/// `TaskGroup` would be the usual tool, but these fetches are started by
/// independent SwiftUI rows rather than from one place, so the limit has to
/// live in the loader instead.
actor AsyncSemaphore {

    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            active = max(0, active - 1)
        }
    }
}
