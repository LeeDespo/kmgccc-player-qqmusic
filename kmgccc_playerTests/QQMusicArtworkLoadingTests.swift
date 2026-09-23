import Foundation
@testable import kmgccc_player
import XCTest

/// Cover loading for online rows and cards.
///
/// Playlist covers were reported as never appearing while album covers worked.
/// The two paths differ in their source URL (playlists arrive as `http://`, and
/// the app has no ATS exception), so these tests pin the normalisation and the
/// loader's cache/network behaviour.
@MainActor
final class QQMusicArtworkLoadingTests: XCTestCase {

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The loader must not depend on the URL scheme it is handed: an `http://`
    /// cover has to be upgraded, because URLSession refuses it otherwise.
    func testNormalizedArtworkURLUpgradesHTTP() throws {
        let upgraded = QQMusicWebAPI.normalizedArtworkURLForTesting(
            "http://y.gtimg.cn/music/photo_new/T002R300x300M000004Iu0Z21UKvFd.jpg?n=1"
        )
        XCTAssertEqual(
            upgraded,
            "https://y.gtimg.cn/music/photo_new/T002R300x300M000004Iu0Z21UKvFd.jpg?n=1"
        )
    }

    func testNormalizedArtworkURLHandlesAllShapes() throws {
        XCTAssertEqual(
            QQMusicWebAPI.normalizedArtworkURLForTesting("//qpic.y.qq.com/x.jpg"),
            "https://qpic.y.qq.com/x.jpg"
        )
        XCTAssertEqual(
            QQMusicWebAPI.normalizedArtworkURLForTesting("https://y.gtimg.cn/a.jpg"),
            "https://y.gtimg.cn/a.jpg"
        )
        XCTAssertNil(QQMusicWebAPI.normalizedArtworkURLForTesting(""))
        XCTAssertNil(QQMusicWebAPI.normalizedArtworkURLForTesting(nil))
    }

    /// A stored cover must be served from disk without touching the network.
    /// The loader keys on the URL string, so a scheme change produces a
    /// different key — which is why covers cached under `http://` are not found
    /// after the upgrade and have to be fetched again under `https://`.
    func testCachedArtworkIsServedWithoutNetwork() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QQMusicCacheStore(paths: kmgccc_player.LibraryPaths(rootURL: root))

        let url = "https://y.gtimg.cn/music/photo_new/T002R300x300M000004Iu0Z21UKvFd.jpg?n=1"
        let payload = Data("fake-jpeg".utf8)
        await store.storeArtwork(payload, for: url)

        // The loader with a cache must return the stored bytes. A session that
        // cannot reach the network proves it came from disk.
        let loader = QQMusicArtworkLoader(cache: store, session: Self.unreachableSession())
        let data = await loader.artwork(for: url)
        XCTAssertEqual(data, payload, "a cached cover must be served without a network call")
    }

    /// With nothing cached and no reachable host, the loader must fail quietly
    /// rather than hang or throw — a missing cover shows a placeholder.
    func testMissingArtworkFailsQuietly() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QQMusicCacheStore(paths: kmgccc_player.LibraryPaths(rootURL: root))
        let loader = QQMusicArtworkLoader(cache: store, session: Self.unreachableSession())

        let data = await loader.artwork(for: "https://example.invalid/none.jpg")
        XCTAssertNil(data)
    }

    /// A session that never succeeds, so any returned bytes must be local.
    private static func unreachableSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        return URLSession(configuration: configuration)
    }
}
