//
//  QQMusicDownloadService.swift
//  kmgccc_player
//
//  Downloads an online QQ Music track into the local library.
//
//  The player is local-file-first: playback, gapless scheduling, spectrum
//  analysis and the scrubber all consume `AVAudioFile`. Rather than teach that
//  stack to stream, an online track is materialized on disk first and then
//  enters the library through the normal import pipeline, exactly like an
//  NCM-decrypted file does.
//
//  Phase 1 covers anonymous (non-logged-in) content. Most mainstream tracks
//  are gated upstream and resolve to `playable == false`; callers surface that
//  to the user instead of pretending the tap worked.
//

import Foundation

nonisolated enum QQMusicDownloadError: LocalizedError, Sendable {
    case notPlayable(reason: String)
    case downloadFailed(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .notPlayable(let reason):
            switch reason {
            case "paid_required":
                return "需要会员或购买后才能播放"
            case "device_restricted":
                return "限制了当前设备的播放权限"
            default:
                return "暂时无法获取播放地址"
            }
        case .downloadFailed(let detail):
            return "下载失败：\(detail)"
        case .emptyAudio:
            return "下载到的内容为空"
        }
    }
}

/// Where a download stands, for driving per-row UI.
nonisolated enum QQMusicDownloadPhase: Equatable, Sendable {
    case idle
    case resolving
    case downloading(fraction: Double)
    case fetchingExtras
    case done
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .resolving, .downloading, .fetchingExtras: return true
        case .idle, .done, .failed: return false
        }
    }

    /// Fraction suitable for a progress indicator, or `nil` when indeterminate.
    var fraction: Double? {
        switch self {
        case .downloading(let value): return value
        default: return nil
        }
    }
}

/// Everything a downloaded track needs to be imported.
nonisolated struct QQMusicStagedDownload: Sendable {
    let audioURL: URL
    let track: QQMusicOnlineTrack
    let quality: String
    /// Album cover, fetched separately because the CDN audio carries no APIC frame.
    let artworkData: Data?
    /// Raw LRC text; the import path converts it to TTML.
    let lyricText: String?
    let translatedLyricText: String?
}

actor QQMusicDownloadService {

    private let helper: QQMusicHelperProcess
    private let session: URLSession
    /// Shared with the browse coordinator so artwork fetched once is reused by
    /// both the list rows and the download pipeline.
    private weak var cacheStore: QQMusicCacheStore?

    /// Deduplicates concurrent downloads of the same song so a double tap
    /// joins the first attempt instead of fetching twice.
    private var inFlight: [String: Task<QQMusicStagedDownload, Error>] = [:]
    private var phases: [String: QQMusicDownloadPhase] = [:]

    init(
        helper: QQMusicHelperProcess = .shared,
        session: URLSession = QQMusicDownloadService.makeDefaultSession(),
        cacheStore: QQMusicCacheStore? = nil
    ) {
        self.helper = helper
        self.session = session
        self.cacheStore = cacheStore
    }

    func attach(cacheStore: QQMusicCacheStore) {
        self.cacheStore = cacheStore
    }

    static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    func phase(for songMid: String) -> QQMusicDownloadPhase {
        phases[songMid] ?? .idle
    }

    /// Resolve the playback url without downloading, so the UI can tell the
    /// user up front whether a track is fetchable.
    func resolve(_ track: QQMusicOnlineTrack) async -> QQMusicStreamResolution? {
        try? await helper.resolveSongURL(
            songMid: track.songMid,
            mediaMid: track.mediaMid,
            quality: nil
        )
    }

    /// Fetch audio, cover and lyrics into `stagingDirectory`.
    ///
    /// The caller imports the staged audio; this actor never touches the
    /// main-actor library session.
    func download(
        _ track: QQMusicOnlineTrack,
        stagingDirectory: URL,
        progressHandler: (@Sendable (QQMusicDownloadPhase) -> Void)? = nil
    ) async throws -> QQMusicStagedDownload {
        if let existing = inFlight[track.songMid] {
            return try await existing.value
        }
        let task = Task<QQMusicStagedDownload, Error> {
            try await performDownload(track, stagingDirectory: stagingDirectory, progressHandler: progressHandler)
        }
        inFlight[track.songMid] = task
        defer { inFlight[track.songMid] = nil }
        return try await task.value
    }

    // MARK: - Implementation

    private func record(
        _ phase: QQMusicDownloadPhase,
        for songMid: String,
        handler: (@Sendable (QQMusicDownloadPhase) -> Void)?
    ) {
        phases[songMid] = phase
        handler?(phase)
    }

    private func performDownload(
        _ track: QQMusicOnlineTrack,
        stagingDirectory: URL,
        progressHandler: (@Sendable (QQMusicDownloadPhase) -> Void)?
    ) async throws -> QQMusicStagedDownload {
        let songMid = track.songMid
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        record(.resolving, for: songMid, handler: progressHandler)
        let resolution: QQMusicStreamResolution
        do {
            resolution = try await helper.resolveSongURL(
                songMid: songMid,
                mediaMid: track.mediaMid,
                quality: nil
            )
        } catch {
            record(.failed(error.localizedDescription), for: songMid, handler: progressHandler)
            throw QQMusicDownloadError.downloadFailed(error.localizedDescription)
        }

        guard resolution.playable, let urlString = resolution.url, let url = URL(string: urlString) else {
            let reason = resolution.restriction ?? "url_unavailable"
            record(.failed(reason), for: songMid, handler: progressHandler)
            throw QQMusicDownloadError.notPlayable(reason: reason)
        }

        let ext = resolution.extensionName ?? "mp3"
        let audioURL = stagingDirectory.appendingPathComponent("\(songMid).\(ext)")
        do {
            try await downloadFile(from: url, to: audioURL, songMid: songMid, handler: progressHandler)
        } catch {
            record(.failed(error.localizedDescription), for: songMid, handler: progressHandler)
            throw error
        }

        // Cover and lyrics are best-effort: a missing cover or lyric must not
        // discard an otherwise good download.
        record(.fetchingExtras, for: songMid, handler: progressHandler)
        async let artwork = fetchArtwork(for: track)
        async let lyrics = fetchLyrics(for: track)
        let (artworkData, lyricPayload) = await (artwork, lyrics)

        record(.done, for: songMid, handler: progressHandler)
        return QQMusicStagedDownload(
            audioURL: audioURL,
            track: track,
            quality: resolution.quality ?? "",
            artworkData: artworkData,
            lyricText: lyricPayload?.lyric,
            translatedLyricText: lyricPayload?.translation
        )
    }

    /// Cover for an online track, served from the QQ Music cache when possible.
    private func fetchArtwork(for track: QQMusicOnlineTrack) async -> Data? {
        guard let urlString = track.imageURL, let url = URL(string: urlString) else { return nil }
        if let cached = await cacheStore?.artwork(for: urlString) {
            return cached
        }
        var request = URLRequest(url: url)
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        await cacheStore?.storeArtwork(data, for: urlString)
        return data
    }

    private func fetchLyrics(for track: QQMusicOnlineTrack) async -> QQMusicLyricPayload? {
        if let cachedData = await cacheStore?.lyrics(songMid: track.songMid),
           let cached = try? JSONDecoder().decode(QQMusicLyricPayload.self, from: cachedData),
           !(cached.lyric ?? "").isEmpty {
            return cached
        }
        let payload = try? await helper.fetchLyric(songMid: track.songMid, songId: track.songId)
        if let payload, let encoded = try? JSONEncoder().encode(payload) {
            await cacheStore?.storeLyrics(encoded, songMid: track.songMid)
        }
        guard let payload, !(payload.lyric ?? "").isEmpty else { return nil }
        return payload
    }

    /// Stream the audio to disk, reporting fractional progress.
    ///
    /// The CDN advertises `Content-Length` and supports range requests, so
    /// counting bytes gives real progress instead of an indeterminate spinner.
    private func downloadFile(
        from url: URL,
        to destination: URL,
        songMid: String,
        handler: (@Sendable (QQMusicDownloadPhase) -> Void)?
    ) async throws {
        var request = URLRequest(url: url)
        // The CDN rejects requests that arrive without a QQ Music referer.
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(QQMusicDownloadService.browserUserAgent, forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw QQMusicDownloadError.downloadFailed("HTTP \(code)")
        }

        let expected = http.expectedContentLength
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw QQMusicDownloadError.downloadFailed("无法创建文件")
        }

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(Self.chunkSize)
        var lastReported = 0.0

        for try await byte in bytes {
            buffer.append(byte)
            guard buffer.count >= Self.chunkSize else { continue }
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            if expected > 0 {
                let fraction = Double(written) / Double(expected)
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    record(.downloading(fraction: min(fraction, 1)), for: songMid, handler: handler)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        guard written > 0 else { throw QQMusicDownloadError.emptyAudio }
    }

    private static let chunkSize = 256 * 1024
    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}
