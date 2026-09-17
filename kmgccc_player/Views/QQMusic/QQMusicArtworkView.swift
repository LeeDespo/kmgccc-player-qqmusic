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
        guard let data = await loader?.artwork(for: urlString) else { return }
        image = NSImage(data: data)
    }
}

/// Loads cover data, consulting the QQ Music cache before the network.
///
/// Injected as an environment value so rows deep in a list do not each need a
/// reference to the coordinator.
@MainActor
struct QQMusicArtworkLoader {

    private let cache: QQMusicCacheStore?
    private let session: URLSession

    init(cache: QQMusicCacheStore?, session: URLSession = .shared) {
        self.cache = cache
        self.session = session
    }

    func artwork(for remoteURL: String) async -> Data? {
        if let cached = await cache?.artwork(for: remoteURL) {
            return cached
        }
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
