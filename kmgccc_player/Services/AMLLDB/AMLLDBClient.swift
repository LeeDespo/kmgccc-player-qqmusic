//
//  AMLLDBClient.swift
//  myPlayer2
//
//  kmgccc_player - AMLLDB HTTP API Client
//  Downloads lyrics index and TTML files from AMLLDB GitHub repository.
//

import Foundation
import os.log

/// HTTP client for AMLLDB lyrics database.
/// Downloads index files and TTML lyrics from GitHub raw content.
actor AMLLDBClient {

    // MARK: - Logger

    private static let logger = Logger(subsystem: "com.kmgccc.player", category: "AMLLDB")

    // MARK: - Constants

    /// GitHub raw content base URL for AMLLDB repository
    private let baseURL = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main"

    /// Timeout for individual lyrics download (10 seconds)
    private let lyricsDownloadTimeout: TimeInterval = 10

    // MARK: - URLSession

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Downloads a specific TTML lyrics file by raw lyric file name.
    /// This is the preferred method for downloading AMLLDB lyrics.
    /// - Parameter rawLyricFile: The raw lyric file name (e.g., "1740814274356-146098469-efb9e56e.ttml")
    /// - Returns: TTML lyrics content as String
    /// - Throws: Network errors, not found errors
    func downloadLyricsByRawFile(_ rawLyricFile: String) async throws -> String {
        let lyricsURL = URL(string: "\(baseURL)/raw-lyrics/\(rawLyricFile)")!

        Self.logger.info("[AMLLDB] Fetching raw lyric file: \(rawLyricFile)")
        Self.logger.info("[AMLLDB] URL: \(lyricsURL.absoluteString)")

        let request = URLRequest(
            url: lyricsURL,
            timeoutInterval: lyricsDownloadTimeout
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AMLLDBError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            guard let ttml = String(data: data, encoding: .utf8) else {
                throw AMLLDBError.parseError("Invalid UTF-8 encoding")
            }
            Self.logger.info("[AMLLDB] TTML download success: \(ttml.count) bytes")
            return ttml

        case 404:
            Self.logger.error("[AMLLDB] TTML download failed: 404 Not Found")
            throw AMLLDBError.notFound("Lyrics not found: \(rawLyricFile)")

        default:
            Self.logger.error("[AMLLDB] TTML download failed: HTTP \(httpResponse.statusCode)")
            throw AMLLDBError.networkError("HTTP \(httpResponse.statusCode)")
        }
    }
}

// MARK: - Errors

enum AMLLDBError: LocalizedError {
    case networkError(String)
    case parseError(String)
    case storageError(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let msg):
            return "网络错误: \(msg)"
        case .parseError(let msg):
            return "解析错误: \(msg)"
        case .storageError(let msg):
            return "存储错误: \(msg)"
        case .notFound(let msg):
            return "未找到: \(msg)"
        }
    }
}
