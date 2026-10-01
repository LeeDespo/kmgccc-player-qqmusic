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
//  Whether a track can be fetched is upstream's answer, not ours: resolving the
//  playback url is a helper call that walks a quality ladder from the credential
//  the user signed in with. A track it refuses comes back `playable == false`
//  with a reason, which the row shows on its own artwork rather than pretending
//  the tap worked.
//

import Foundation

nonisolated enum QQMusicDownloadError: LocalizedError, Sendable {
    case notPlayable(reason: String)
    case downloadFailed(String)
    case emptyAudio
    /// The user cancelled this download; the caller stops rather than retrying.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "已取消"
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

}

/// Everything a downloaded track needs to be imported.
/// A track handed to the engine, and where its file will land.
nonisolated struct QQMusicQueuedDownload: Sendable {
    let songMid: String
    /// The engine's handle, or nil when it was fetched without an engine.
    let gid: String?
    let audioURL: URL
    /// The name shown in the download list, and the name the import sees.
    let fileName: String
    /// True when there was no engine and the bytes are already on disk.
    let finishedLocally: Bool
}

nonisolated struct QQMusicStagedDownload: Sendable {
    let audioURL: URL
    let track: QQMusicOnlineTrack
    /// Album cover, fetched separately because the CDN audio carries no APIC frame.
    let artworkData: Data?
    /// Raw LRC text; the import path converts it to TTML.
    ///
    /// When the component has the word-level track this is **that** — an LRC with a
    /// timestamp before every word — because the import path turns any LRC into
    /// TTML, and word-level tags are what make the result word-level. The
    /// whole-line text is then only a fallback for songs without one.
    let lyricText: String?
    let translatedLyricText: String?
}

actor QQMusicDownloadService {

    private let helper: QQMusicComponentProcess

    /// Gids the user cancelled.
    ///
    /// A cancelled task disappears from the engine, which looks exactly like an
    /// engine restart from the polling side — and the difference matters: a
    /// restart means "fetch it another way", a cancel means "stop". Without this
    /// the fallback would download the file the user just cancelled.
    private var cancelledGids: Set<String> = []

    /// Called by the coordinator when the user cancels.
    func markCancelled(_ gids: [String]) {
        cancelledGids.formUnion(gids)
    }
    private let session: URLSession
    /// Shared with the browse coordinator so artwork fetched once is reused by
    /// both the list rows and the download pipeline.
    private weak var cacheStore: QQMusicCacheStore?
    /// Download ceiling chosen in settings; nil means let the helper decide.
    private var preferredQuality: QQMusicQualityPreference?

    /// Deduplicates concurrent downloads of the same song so a double tap
    /// joins the first attempt instead of fetching twice.
    private var inFlight: [String: Task<QQMusicStagedDownload, Error>] = [:]
    private var phases: [String: QQMusicDownloadPhase] = [:]

    init(
        helper: QQMusicComponentProcess = .shared,
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

    func setPreferredQuality(_ quality: QQMusicQualityPreference) {
        preferredQuality = quality
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
            try await performDownload(
                track,
                stagingDirectory: stagingDirectory,
                progressHandler: progressHandler
            )
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

    // MARK: - Queueing (the batch path)

    /// Resolve a track and hand it to the engine, without waiting for it.
    ///
    /// The batch queues its whole selection this way, so the engine holds the
    /// *queue* and its own `max-concurrent-downloads` decides how many run at
    /// once — which is what the settings page promises. Waiting inside the loop
    /// (what this used to do) meant one download at a time no matter what the
    /// engine was configured for, and a download list that only ever showed the
    /// one task in flight.
    func queue(_ track: QQMusicOnlineTrack, stagingDirectory: URL) async throws -> QQMusicQueuedDownload {
        let songMid = track.songMid
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        record(.resolving, for: songMid, handler: nil)

        let resolution: QQMusicStreamResolution
        do {
            resolution = try await helper.resolveSongURL(
                songMid: songMid,
                mediaMid: track.mediaMid,
                quality: preferredQuality?.ladderEntry
            )
        } catch {
            record(.failed(error.localizedDescription), for: songMid, handler: nil)
            throw QQMusicDownloadError.downloadFailed(error.localizedDescription)
        }
        guard resolution.playable, let urlString = resolution.url, let url = URL(string: urlString) else {
            let reason = resolution.restriction ?? "url_unavailable"
            Log.warning(
                "[QQMusic] \(songMid) not playable (\(reason)); qualities tried: "
                    + "\(resolution.tried?.joined(separator: ", ") ?? "none")",
                category: .import
            )
            record(.failed(reason), for: songMid, handler: nil)
            throw QQMusicDownloadError.notPlayable(reason: reason)
        }

        let ext = resolution.extensionName ?? "mp3"
        // A name the import can recognise, and the same one the list shows.
        let fileName = "\(songMid)-\(UUID().uuidString.prefix(8)).\(ext)"
        let audioURL = stagingDirectory.appendingPathComponent(fileName)
        guard await helper.aria2Status(ensure: true)?.running == true else {
            // No engine: fall back to fetching it here and now, so a queue still
            // works without one.
            try await downloadStreaming(
                from: url,
                to: audioURL,
                songMid: songMid,
                handler: nil
            )
            record(.downloading(fraction: 1), for: songMid, handler: nil)
            return QQMusicQueuedDownload(
                songMid: songMid,
                gid: nil,
                audioURL: audioURL,
                fileName: fileName,
                finishedLocally: true
            )
        }
        let queued = try await helper.aria2Add(url: url.absoluteString, out: fileName)
        guard let gid = queued.gid else {
            throw QQMusicDownloadError.downloadFailed("下载引擎没有返回任务 id")
        }
        record(.downloading(fraction: 0), for: songMid, handler: nil)
        return QQMusicQueuedDownload(
            songMid: songMid,
            gid: gid,
            audioURL: audioURL,
            fileName: fileName,
            finishedLocally: false
        )
    }

    /// Wait for a queued track, then import it like any other download.
    func finishQueued(
        _ queued: QQMusicQueuedDownload,
        track: QQMusicOnlineTrack,
        stagingDirectory: URL
    ) async throws -> QQMusicStagedDownload {
        let songMid = track.songMid
        if !queued.finishedLocally {
            try await waitForEngine(queued: queued, songMid: songMid)
        }
        // Cover and lyrics are best-effort, exactly as on the sequential path.
        record(.fetchingExtras, for: songMid, handler: nil)
        async let artwork = fetchArtwork(for: track)
        async let lyrics = fetchLyrics(for: track)
        let (artworkData, lyricPayload) = await (artwork, lyrics)
        record(.done, for: songMid, handler: nil)
        return QQMusicStagedDownload(
            audioURL: queued.audioURL,
            track: track,
            artworkData: artworkData,
            lyricText: lyricPayload?.preferredLyric,
            translatedLyricText: lyricPayload?.translation
        )
    }

    /// Wait for one engine task to finish and move its file into staging.
    private func waitForEngine(queued: QQMusicQueuedDownload, songMid: String) async throws {
        guard let gid = queued.gid else { return }
        let deadline = Date().addingTimeInterval(600)
        var consecutiveTellFailures = 0
        var lastReported = 0.0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let state: QQMusicAria2Download
            do {
                state = try await helper.aria2Tell(gid: gid)
                consecutiveTellFailures = 0
            } catch {
                if cancelledGids.contains(gid) {
                    record(.failed("已取消"), for: songMid, handler: nil)
                    throw QQMusicDownloadError.cancelled
                }
                consecutiveTellFailures += 1
                if consecutiveTellFailures >= 3 {
                    record(.failed("下载引擎丢失了任务"), for: songMid, handler: nil)
                    throw QQMusicDownloadError.downloadFailed("下载引擎丢失了任务")
                }
                continue
            }
            if state.isFinished {
                guard let path = state.path else {
                    throw QQMusicDownloadError.downloadFailed("引擎没有给出文件路径")
                }
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: queued.audioURL.path) {
                    try? fileManager.removeItem(at: queued.audioURL)
                }
                try fileManager.moveItem(at: URL(fileURLWithPath: path), to: queued.audioURL)
                return
            }
            if state.isFailed {
                record(.failed(state.error ?? "下载失败"), for: songMid, handler: nil)
                throw QQMusicDownloadError.downloadFailed(state.error ?? "下载失败")
            }
            let total = Double(state.total ?? 0)
            guard total > 0 else { continue }
            let fraction = Double(state.completed ?? 0) / total
            if fraction - lastReported >= 0.01 {
                lastReported = fraction
                record(.downloading(fraction: min(fraction, 1)), for: songMid, handler: nil)
            }
        }
        throw QQMusicDownloadError.downloadFailed("下载超时")
    }

    /// Stop a queued task in the engine, without touching the app's own state.
    func cancelQueued(gids: [String]) async {
        markCancelled(gids)
        for gid in gids {
            _ = await helper.aria2Cancel(gid: gid)
        }
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
                quality: preferredQuality?.ladderEntry
            )
        } catch {
            record(.failed(error.localizedDescription), for: songMid, handler: progressHandler)
            throw QQMusicDownloadError.downloadFailed(error.localizedDescription)
        }

        guard resolution.playable, let urlString = resolution.url, let url = URL(string: urlString) else {
            let reason = resolution.restriction ?? "url_unavailable"
            Log.warning(
                "[QQMusic] \(songMid) not playable (\(reason)); qualities tried: "
                    + "\(resolution.tried?.joined(separator: ", ") ?? "none")",
                category: .import
            )
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
            artworkData: artworkData,
            lyricText: lyricPayload?.preferredLyric,
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

    /// The lyric is fetched once, through the component, and written into the
    /// library with the audio — so the payload a downloaded track carries is the
    /// same one the helper would serve at play time.
    private func fetchLyrics(for track: QQMusicOnlineTrack) async -> QQMusicLyricPayload? {
        let payload = try? await helper.fetchLyric(songMid: track.songMid, songId: track.songId)
        guard let payload, !(payload.lyric ?? "").isEmpty else { return nil }
        return payload
    }

    /// Stream the audio to disk, reporting fractional progress.
    ///
    /// The CDN advertises `Content-Length` and supports range requests, so
    /// counting bytes gives real progress instead of an indeterminate spinner.
    /// Move the bytes for one track.
    ///
    /// Aria2 Next (the engine that ships with the component) does this when it is
    /// available: it resumes, splits the file across connections and honours the
    /// user's rate limits, none of which this app should re-implement. The app's
    /// own streaming loop below is the fallback — kept, not deleted, because a
    /// download that cannot happen at all is worse than one that is unsplit, and
    /// because the engine can be absent (an older component install).
    private func downloadFile(
        from url: URL,
        to destination: URL,
        songMid: String,
        handler: (@Sendable (QQMusicDownloadPhase) -> Void)?
    ) async throws {
        if try await downloadViaEngine(from: url, to: destination, songMid: songMid, handler: handler) {
            return
        }
        try await downloadStreaming(from: url, to: destination, songMid: songMid, handler: handler)
    }

    /// Hand the file to Aria2 Next. Returns false when it could not be used, so
    /// the caller falls back rather than failing the download.
    private func downloadViaEngine(
        from url: URL,
        to destination: URL,
        songMid: String,
        handler: (@Sendable (QQMusicDownloadPhase) -> Void)?
    ) async throws -> Bool {
        guard await helper.aria2Status(ensure: true)?.running == true else { return false }
        // The engine writes into its own directory under a name it is given; the
        // app then moves the finished file to staging, so the import pipeline sees
        // exactly what it saw before.
        let out = "\(songMid)-\(UUID().uuidString.prefix(8)).\(destination.pathExtension)"
        let queued: QQMusicAria2Download
        do {
            queued = try await helper.aria2Add(url: url.absoluteString, out: out)
        } catch {
            Log.warning("[QQMusicDownload] aria2 refused the task, streaming instead: \(error)", category: .import)
            return false
        }
        guard let gid = queued.gid else { return false }

        // Poll until it finishes. The engine reports a byte count, which is the
        // same number the streaming path reports as a fraction.
        let deadline = Date().addingTimeInterval(600)
        var lastReported = 0.0
        var consecutiveTellFailures = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let state: QQMusicAria2Download
            do {
                state = try await helper.aria2Tell(gid: gid)
                consecutiveTellFailures = 0
            } catch {
                // The engine forgetting the task is the normal outcome of a
                // restart: every gid it held dies with it. Report that instead of
                // waiting out the deadline, so the download falls back to the app's
                // own path and the user sees it happen.
                if cancelledGids.contains(gid) {
                    Log.info("[QQMusicDownload] \(songMid) cancelled by the user", category: .import)
                    throw QQMusicDownloadError.cancelled
                }
                consecutiveTellFailures += 1
                if consecutiveTellFailures >= 3 {
                    Log.warning(
                        "[QQMusicDownload] the engine lost \(songMid)'s task (restarted?); streaming instead",
                        category: .import
                    )
                    return false
                }
                continue
            }
            if state.isFinished {
                guard let path = state.path else { return false }
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                do {
                    try fileManager.moveItem(at: URL(fileURLWithPath: path), to: destination)
                } catch {
                    Log.warning("[QQMusicDownload] aria2 finished but the move failed: \(error)", category: .import)
                    return false
                }
                record(.downloading(fraction: 1), for: songMid, handler: handler)
                return true
            }
            if state.isFailed {
                Log.warning(
                    "[QQMusicDownload] aria2 reported \(state.error ?? state.status ?? "failure") (\(state.errorCode ?? "-"))",
                    category: .import
                )
                return false
            }
            let total = Double(state.total ?? 0)
            let completed = Double(state.completed ?? 0)
            guard total > 0 else { continue }
            let fraction = completed / total
            if fraction - lastReported >= 0.01 {
                lastReported = fraction
                record(.downloading(fraction: min(fraction, 1)), for: songMid, handler: handler)
            }
        }
        Log.warning("[QQMusicDownload] aria2 timed out on \(songMid)", category: .import)
        return false
    }

    private func downloadStreaming(
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
