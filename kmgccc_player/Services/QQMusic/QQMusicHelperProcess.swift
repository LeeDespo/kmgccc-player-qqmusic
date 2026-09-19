//
//  QQMusicHelperProcess.swift
//  myPlayer2
//
//  On-demand stdio JSON IPC process manager for the bundled QQMusic helper.
//

import Foundation

nonisolated struct QQMusicArtworkCandidate: Codable, Equatable, Sendable {
    var source: String
    var title: String?
    var artist: String?
    var album: String?
    var artistName: String?
    var singerMid: String?
    var songMid: String?
    var albumMid: String?
    var imageURL: String?
    var duration: Int?
    var confidence: Double?
}

nonisolated enum MetadataDetailSource: String, Codable, Sendable {
    case qqmusic
}

nonisolated struct QQMusicMetadataDetail: Codable, Equatable, Sendable {
    var source: String
    var title: String?
    var artist: String?
    var album: String?
    var artistName: String?
    var singerMid: String?
    var songMid: String?
    var albumMid: String?
    var imageURL: String?
    var description: String?
    var genreTags: [String]?
    var region: String?
    var foreignName: String?
    var releaseYear: Int?
    var releaseDate: Date?
    var albumType: String?
    var language: String?
    var labelOrCompany: String?
    var duration: Int?
    var metadataSource: String?
    var metadataFetchedAt: Date?
    var metadataConfidence: Double?
    var confidence: Double?
}

nonisolated struct ArtistMetadataDetail: Equatable, Sendable {
    var source: MetadataDetailSource
    var artistName: String?
    var description: String?
    var genreTags: [String]
    var region: String?
    var foreignName: String?
    var qqMusicSingerMid: String?
    var imageURL: String?
    var fetchedAt: Date?
    var confidence: Double
}

nonisolated struct AlbumMetadataDetail: Equatable, Sendable {
    var source: MetadataDetailSource
    var album: String?
    var artist: String?
    var description: String?
    var releaseYear: Int?
    var releaseDate: Date?
    var albumType: String?
    var genreTags: [String]
    var language: String?
    var labelOrCompany: String?
    var qqMusicAlbumMid: String?
    var imageURL: String?
    var fetchedAt: Date?
    var confidence: Double
}

nonisolated struct TrackMetadataDetail: Equatable, Sendable {
    var source: MetadataDetailSource
    var title: String?
    var artist: String?
    var album: String?
    var description: String?
    var genreTags: [String]
    var language: String?
    var labelOrCompany: String?
    var releaseDate: Date?
    var qqMusicSongMid: String?
    var qqMusicAlbumMid: String?
    var imageURL: String?
    var duration: Int?
    var fetchedAt: Date?
    var confidence: Double
}

nonisolated struct MetadataApplyResult<Value>: Sendable where Value: Sendable {
    let value: Value
    let changed: Bool
}

// MARK: - Online catalog payloads

/// One song from an online QQ Music browse surface (search, radio, playlist).
///
/// This is a *catalog* representation, deliberately separate from `Track`:
/// a catalog row has no local file, no bookmark and no locator. It becomes a
/// `Track` only after the audio has been downloaded into the library.
nonisolated struct QQMusicOnlineTrack: Codable, Equatable, Sendable, Identifiable {
    var songId: Int?
    var songMid: String
    var mediaMid: String?
    var title: String
    var artist: String
    var album: String?
    var albumMid: String?
    var imageURL: String?
    var duration: Int?
    /// `0` means the CDN is expected to grant a playback url. `1` marks a
    /// gated track, which is the signal the UI uses to grey a row out instead
    /// of letting the user tap into a guaranteed failure.
    var payPlay: Int?
    var songType: Int?
    var size320: Int?
    var sizeFlac: Int?
    var size128: Int?
    var singerMid: String?
    /// Album release date, present when the source supplied it (artist "最新"
    /// ordering attaches it).
    var releaseDate: String?

    var id: String { songMid }

    /// Heuristic gate used to pre-disable rows; the authoritative answer still
    /// comes from `resolveSongURL`.
    var isExpectedPlayable: Bool { (payPlay ?? 1) == 0 }
}

nonisolated struct QQMusicOnlinePlaylist: Codable, Equatable, Sendable, Identifiable {
    var id: Int
    var title: String
    var coverURL: String?
    var creator: String?
    var songCount: Int?
    var playCount: Int?
}

nonisolated struct QQMusicToplistGroup: Codable, Equatable, Sendable {
    var id: Int?
    var name: String
    var toplists: [QQMusicToplist]
}

nonisolated struct QQMusicToplist: Codable, Equatable, Sendable, Identifiable {
    var id: Int
    var name: String
}

nonisolated struct QQMusicLyricPayload: Codable, Equatable, Sendable {
    var lyric: String?
    var translation: String?
    var romanization: String?
}

/// Outcome of asking the upstream for a playback url.
nonisolated struct QQMusicStreamResolution: Codable, Equatable, Sendable {
    var songMid: String
    var url: String?
    var quality: String?
    var extensionName: String?
    var filename: String?
    var expiration: Int?
    var playable: Bool
    /// `paid_required` / `device_restricted` / `url_unavailable` when blocked.
    var restriction: String?
    var tried: [String]?

    enum CodingKeys: String, CodingKey {
        case songMid, url, quality, filename, expiration, playable, restriction, tried
        case extensionName = "extension"
    }
}

/// Account state reported by the helper.
nonisolated struct QQMusicLoginStatus: Codable, Equatable, Sendable {
    var loggedIn: Bool
    var musicId: Int?
    var nickname: String?
    var vipType: Int?
    var expired: Bool?
    /// QR poll event: `SCAN` / `CONF` / `DONE` / `TIMEOUT` / `REFUSE`.
    var event: String?
    /// Whether a playback ticket (`qm_keyst`) is present. Without it the
    /// upstream answers `104003` even for tracks the account may play.
    var hasPlaybackKey: Bool?

    var isVip: Bool { (vipType ?? 0) > 0 }
}

/// A login QR code to display, plus the values needed to poll it.
nonisolated struct QQMusicLoginQRCode: Codable, Equatable, Sendable {
    var identifier: String
    var loginType: String
    var mimetype: String
    var imageBase64: String
}

/// The helper's own version and capabilities, so the app can stay compatible
/// with builds it did not ship.
nonisolated struct QQMusicHelperInfo: Codable, Equatable, Sendable {
    var helperVersion: String
    var protocolVersion: Int
    var libraryVersion: String
    var methods: [String]
    var credentialDir: Bool

    func supports(_ method: String) -> Bool { methods.contains(method) }
}

/// An album in the user's favorites.
nonisolated struct QQMusicOnlineAlbum: Codable, Equatable, Sendable, Identifiable {
    var id: Int
    var title: String
    var albumMid: String?
    var coverURL: String?
    var artist: String?
    var releaseDate: String?

    /// `id` is a numeric album id, unique per album.
    var identity: String { albumMid ?? String(id) }
}

/// A radio station ("电台").
nonisolated struct QQMusicRadioStation: Codable, Equatable, Sendable, Identifiable {
    var id: Int
    var title: String
    var coverURL: String?
    var listenerCount: Int?
}

/// A radio group (心情 / 主题 / 场景 …).
nonisolated struct QQMusicRadioGroup: Codable, Equatable, Sendable, Identifiable {
    var id: Int?
    var name: String
    var stations: [QQMusicRadioStation]

    var identity: String { "\(id ?? -1)-\(name)" }
}

/// Artist biography and basic facts.
nonisolated struct QQMusicArtistDetail: Codable, Equatable, Sendable {
    var singerMid: String
    var description: String?
    var foreignName: String?
    var region: String?
    var genreTags: [String]?
}

/// An artist in search results, with counts for display.
nonisolated struct QQMusicOnlineArtist: Codable, Equatable, Sendable, Identifiable {
    var singerMid: String
    var name: String
    var coverURL: String?
    var songCount: Int?
    var albumCount: Int?

    var id: String { singerMid }
}

/// Circuit-breaker state, surfaced in QQ Music settings.
nonisolated enum QQMusicCircuitState: Sendable, Equatable {
    case closed
    case open(until: Date, reason: String)
    case disabled

    var isOpen: Bool {
        if case .open = self { return true }
        return false
    }
}

/// Result of a like/unlike request.
nonisolated struct QQMusicLikeResult: Codable, Equatable, Sendable {
    var songId: Int
    var liked: Bool
    /// Whether the upstream accepted the write. The change still lands
    /// asynchronously, so this reports acceptance rather than a visible result.
    var ok: Bool?
}

/// "我喜欢" contents plus the folder's own total, so the list can page.
nonisolated struct QQMusicLikedSongs: Codable, Equatable, Sendable {
    var title: String
    var total: Int
    var tracks: [QQMusicOnlineTrack]
}

/// Region filter for the new-song radio.
nonisolated enum QQMusicNewSongRegion: String, Sendable, CaseIterable {
    case latest
    case mainland
    case europeUS = "europe_us"
    case japan
    case korea
    case hongkongTaiwan = "hongkong_taiwan"

    var displayName: String {
        switch self {
        case .latest: return "最新"
        case .mainland: return "内地"
        case .europeUS: return "欧美"
        case .japan: return "日本"
        case .korea: return "韩国"
        case .hongkongTaiwan: return "港台"
        }
    }
}

/// Which QR login flow to start.
nonisolated enum QQMusicLoginType: String, Sendable, CaseIterable {
    case qq
    case wx
    case mobile

    var displayName: String {
        switch self {
        case .qq: return "QQ"
        case .wx: return "微信"
        case .mobile: return "手机 QQ"
        }
    }
}

nonisolated enum MetadataDetailApplicator {
    static func applyMissingFields(
        _ detail: ArtistMetadataDetail,
        to entry: ArtistEntry,
        minimumConfidence: Double = 0.70
    ) -> MetadataApplyResult<ArtistEntry> {
        guard detail.confidence >= minimumConfidence else {
            return MetadataApplyResult(value: entry, changed: false)
        }

        var updated = entry
        var changed = false

        fillString(&updated.description, with: detail.description, changed: &changed)
        fillStringArray(&updated.genreTags, with: detail.genreTags, changed: &changed)
        fillString(&updated.region, with: detail.region, changed: &changed)
        fillString(&updated.foreignName, with: detail.foreignName, changed: &changed)
        fillOptionalString(&updated.qqMusicSingerMid, with: detail.qqMusicSingerMid, changed: &changed)

        if changed {
            applyMetadataStamp(
                source: detail.source.rawValue,
                fetchedAt: detail.fetchedAt,
                confidence: detail.confidence,
                metadataSource: &updated.metadataSource,
                metadataFetchedAt: &updated.metadataFetchedAt,
                metadataConfidence: &updated.metadataConfidence
            )
            updated.updatedAt = Date()
        }
        return MetadataApplyResult(value: updated, changed: changed)
    }

    static func applyMissingFields(
        _ detail: AlbumMetadataDetail,
        to entry: AlbumEntry,
        minimumConfidence: Double = 0.70
    ) -> MetadataApplyResult<AlbumEntry> {
        guard detail.confidence >= minimumConfidence else {
            return MetadataApplyResult(value: entry, changed: false)
        }

        var updated = entry
        var changed = false

        fillString(&updated.description, with: detail.description, changed: &changed)
        fillOptionalInt(&updated.releaseYear, with: detail.releaseYear, changed: &changed)
        fillOptionalDate(&updated.releaseDate, with: detail.releaseDate, changed: &changed)
        fillString(&updated.albumType, with: detail.albumType, changed: &changed)
        fillStringArray(&updated.genreTags, with: detail.genreTags, changed: &changed)
        fillString(&updated.language, with: detail.language, changed: &changed)
        fillString(&updated.labelOrCompany, with: detail.labelOrCompany, changed: &changed)
        fillOptionalString(&updated.qqMusicAlbumMid, with: detail.qqMusicAlbumMid, changed: &changed)
        if updated.year == nil, let releaseYear = updated.releaseYear {
            updated.year = releaseYear
            changed = true
        }

        if changed {
            applyMetadataStamp(
                source: detail.source.rawValue,
                fetchedAt: detail.fetchedAt,
                confidence: detail.confidence,
                metadataSource: &updated.metadataSource,
                metadataFetchedAt: &updated.metadataFetchedAt,
                metadataConfidence: &updated.metadataConfidence
            )
            updated.updatedAt = Date()
        }
        return MetadataApplyResult(value: updated, changed: changed)
    }

    static func applyMissingFields(
        _ detail: TrackMetadataDetail,
        to track: Track,
        minimumConfidence: Double = 0.70
    ) -> Bool {
        guard detail.confidence >= minimumConfidence else { return false }

        var changed = false
        fillMissingAlbum(&track.album, with: detail.album, changed: &changed)
        fillString(&track.userDescription, with: detail.description, changed: &changed)
        fillStringArray(&track.genreTags, with: detail.genreTags, changed: &changed)
        fillString(&track.language, with: detail.language, changed: &changed)
        fillString(&track.labelOrCompany, with: detail.labelOrCompany, changed: &changed)
        fillOptionalDate(&track.releaseDate, with: detail.releaseDate, changed: &changed)
        fillOptionalString(&track.qqMusicSongMid, with: detail.qqMusicSongMid, changed: &changed)

        if changed {
            applyMetadataStamp(
                source: detail.source.rawValue,
                fetchedAt: detail.fetchedAt,
                confidence: detail.confidence,
                metadataSource: &track.metadataSource,
                metadataFetchedAt: &track.metadataFetchedAt,
                metadataConfidence: &track.metadataConfidence
            )
        }
        return changed
    }

    static func shouldFillMissingAlbum(_ album: String) -> Bool {
        LibraryNormalization.isUnknownAlbum(album)
    }

    private static func fillMissingAlbum(_ target: inout String, with candidate: String?, changed: inout Bool) {
        guard shouldFillMissingAlbum(target),
              let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              !LibraryNormalization.isUnknownAlbum(candidate)
        else { return }
        target = candidate
        changed = true
    }

    private static func fillString(_ target: inout String, with candidate: String?, changed: inout Bool) {
        guard target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty
        else { return }
        target = candidate
        changed = true
    }

    private static func fillStringArray(_ target: inout [String], with candidate: [String], changed: inout Bool) {
        guard target.isEmpty, !candidate.isEmpty else { return }
        target = candidate
        changed = true
    }

    private static func fillOptionalString(_ target: inout String?, with candidate: String?, changed: inout Bool) {
        guard (target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty
        else { return }
        target = candidate
        changed = true
    }

    private static func fillOptionalInt(_ target: inout Int?, with candidate: Int?, changed: inout Bool) {
        guard target == nil, let candidate else { return }
        target = candidate
        changed = true
    }

    private static func fillOptionalDate(_ target: inout Date?, with candidate: Date?, changed: inout Bool) {
        guard target == nil, let candidate else { return }
        target = candidate
        changed = true
    }

    private static func applyMetadataStamp(
        source: String,
        fetchedAt: Date?,
        confidence: Double,
        metadataSource: inout String?,
        metadataFetchedAt: inout Date?,
        metadataConfidence: inout Double?
    ) {
        if metadataSource?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            metadataSource = source
        }
        if metadataFetchedAt == nil {
            metadataFetchedAt = fetchedAt ?? Date()
        }
        if metadataConfidence == nil {
            metadataConfidence = confidence
        }
    }
}

nonisolated enum MetadataDetailError: LocalizedError, Sendable {
    case noResults

    var errorDescription: String? {
        switch self {
        case .noResults:
            return "No metadata detail results"
        }
    }
}

protocol MetadataDetailProvider: Sendable {
    func fetchArtistDetail(name: String, singerMid: String?) async throws -> ArtistMetadataDetail?
    func fetchAlbumDetail(album: String, artist: String, albumMid: String?) async throws -> AlbumMetadataDetail?
    func fetchTrackDetail(
        title: String,
        artist: String,
        album: String,
        songMid: String?,
        duration: Int?
    ) async throws -> TrackMetadataDetail?
}

actor QQMusicMetadataProvider: MetadataDetailProvider {
    static let shared = QQMusicMetadataProvider()

    private let helper: QQMusicHelperProcess

    init(helper: QQMusicHelperProcess = .shared) {
        self.helper = helper
    }

    func fetchArtistDetail(name: String, singerMid: String? = nil) async throws -> ArtistMetadataDetail? {
        let detail = try await helper.fetchArtistDetail(name: name, singerMid: singerMid)
        return ArtistMetadataDetail(
            source: .qqmusic,
            artistName: detail.artistName,
            description: nonEmpty(detail.description),
            genreTags: normalizedTags(detail.genreTags),
            region: nonEmpty(detail.region),
            foreignName: nonEmpty(detail.foreignName),
            qqMusicSingerMid: nonEmpty(detail.singerMid),
            imageURL: nonEmpty(detail.imageURL),
            fetchedAt: detail.metadataFetchedAt,
            confidence: normalizedConfidence(detail)
        )
    }

    func fetchAlbumDetail(album: String, artist: String, albumMid: String? = nil) async throws -> AlbumMetadataDetail? {
        let detail = try await helper.fetchAlbumDetail(album: album, artist: artist, albumMid: albumMid)
        return AlbumMetadataDetail(
            source: .qqmusic,
            album: nonEmpty(detail.album),
            artist: nonEmpty(detail.artist),
            description: nonEmpty(detail.description),
            releaseYear: detail.releaseYear,
            releaseDate: detail.releaseDate,
            albumType: nonEmpty(detail.albumType),
            genreTags: normalizedTags(detail.genreTags),
            language: nonEmpty(detail.language),
            labelOrCompany: nonEmpty(detail.labelOrCompany),
            qqMusicAlbumMid: nonEmpty(detail.albumMid),
            imageURL: nonEmpty(detail.imageURL),
            fetchedAt: detail.metadataFetchedAt,
            confidence: normalizedConfidence(detail)
        )
    }

    func fetchTrackDetail(
        title: String,
        artist: String,
        album: String,
        songMid: String? = nil,
        duration: Int? = nil
    ) async throws -> TrackMetadataDetail? {
        let finalSongMid: String
        let computedConfidence: Double

        if let mid = songMid, !mid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finalSongMid = mid
            computedConfidence = 0.90
        } else {
            // No songMid, search candidates first to prevent mismatch
            let candidates = try await helper.searchTrackArtwork(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                limit: 5
            )

            var bestCandidate: QQMusicArtworkCandidate? = nil
            var bestScore: Double = -1.0

            for candidate in candidates {
                let helperConfidence = min(max(candidate.confidence ?? 0.70, 0), 1)

                // 1. Title validation
                let sourceTitle = ExternalPlaybackTextNormalizer.normalize(title)
                let candidateTitle = ExternalPlaybackTextNormalizer.normalize(candidate.title)
                let titleScore = ExternalPlaybackTextNormalizer.stringSimilarity(sourceTitle, candidateTitle)
                guard ExternalPlaybackTextNormalizer.titleAccepted(
                    source: sourceTitle,
                    candidate: candidateTitle
                ) else { continue }

                // 2. Artist validation
                let sourceArtist = ExternalPlaybackTextNormalizer.normalizeArtist(artist)
                let candidateArtist = ExternalPlaybackTextNormalizer.normalizeArtist(candidate.artist ?? candidate.artistName)
                let artistScore = ExternalPlaybackTextNormalizer.artistSimilarity(sourceArtist, candidateArtist)
                guard artistScore >= 0.22 else { continue }

                // 3. Duration/obvious conflict validation
                if let duration, duration > 0, let candDuration = candidate.duration, candDuration > 0 {
                    if ExternalPlaybackTextNormalizer.hasObviousConflict(
                        titleScore: titleScore,
                        artistScore: artistScore,
                        sourceDuration: Double(duration),
                        candidateDuration: Double(candDuration)
                    ) {
                        continue
                    }
                }

                // 4. Scoring
                let sourceAlbum = ExternalPlaybackTextNormalizer.normalize(album)
                let candidateAlbum = ExternalPlaybackTextNormalizer.normalize(candidate.album)
                let albumScore = sourceAlbum.compact.isEmpty || candidateAlbum.compact.isEmpty
                    ? 0.5
                    : ExternalPlaybackTextNormalizer.stringSimilarity(sourceAlbum, candidateAlbum)

                let durationScore: Double
                if let duration, duration > 0, let candDuration = candidate.duration, candDuration > 0 {
                    durationScore = ExternalPlaybackTextNormalizer.durationScore(source: Double(duration), candidate: Double(candDuration))
                } else {
                    durationScore = 0.5
                }

                let score = titleScore * 0.46
                    + artistScore * 0.28
                    + durationScore * 0.18
                    + albumScore * 0.06
                    + helperConfidence * 0.02

                if score > bestScore {
                    bestScore = score
                    bestCandidate = candidate
                }
            }

            guard let selected = bestCandidate, let mid = selected.songMid else {
                throw MetadataDetailError.noResults
            }
            finalSongMid = mid
            computedConfidence = bestScore
        }

        var detail = try await helper.fetchSongDetail(
            title: title,
            artist: artist,
            album: album,
            songMid: finalSongMid,
            duration: duration
        )
        detail.confidence = computedConfidence

        return TrackMetadataDetail(
            source: .qqmusic,
            title: nonEmpty(detail.title),
            artist: nonEmpty(detail.artist),
            album: nonEmpty(detail.album),
            description: nonEmpty(detail.description),
            genreTags: normalizedTags(detail.genreTags),
            language: nonEmpty(detail.language),
            labelOrCompany: nonEmpty(detail.labelOrCompany),
            releaseDate: detail.releaseDate,
            qqMusicSongMid: nonEmpty(detail.songMid),
            qqMusicAlbumMid: nonEmpty(detail.albumMid),
            imageURL: nonEmpty(detail.imageURL),
            duration: detail.duration,
            fetchedAt: detail.metadataFetchedAt,
            confidence: normalizedConfidence(detail)
        )
    }

    private nonisolated func normalizedConfidence(_ detail: QQMusicMetadataDetail) -> Double {
        min(max(detail.confidence ?? detail.metadataConfidence ?? 0, 0), 1)
    }

    private nonisolated func normalizedTags(_ values: [String]?) -> [String] {
        var seen = Set<String>()
        return (values ?? []).compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private nonisolated func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

@MainActor
final class MetadataDetailCoordinator {
    static let shared = MetadataDetailCoordinator()

    private let providers: [any MetadataDetailProvider]

    init(providers: [any MetadataDetailProvider] = [QQMusicMetadataProvider.shared]) {
        self.providers = providers
    }

    func fetchArtistDetail(name: String, singerMid: String? = nil) async throws -> ArtistMetadataDetail {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || (singerMid?.isEmpty == false) else {
            throw MetadataDetailError.noResults
        }
        for provider in providers {
            if let detail = try await provider.fetchArtistDetail(name: name, singerMid: singerMid) {
                return detail
            }
        }
        throw MetadataDetailError.noResults
    }

    func fetchAlbumDetail(album: String, artist: String, albumMid: String? = nil) async throws -> AlbumMetadataDetail {
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !album.isEmpty || (albumMid?.isEmpty == false) else {
            throw MetadataDetailError.noResults
        }
        for provider in providers {
            if let detail = try await provider.fetchAlbumDetail(album: album, artist: artist, albumMid: albumMid) {
                return detail
            }
        }
        throw MetadataDetailError.noResults
    }

    func fetchTrackDetail(
        title: String,
        artist: String,
        album: String,
        songMid: String? = nil,
        duration: Int? = nil
    ) async throws -> TrackMetadataDetail {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || (songMid?.isEmpty == false) else {
            throw MetadataDetailError.noResults
        }
        for provider in providers {
            if let detail = try await provider.fetchTrackDetail(
                title: title,
                artist: artist,
                album: album,
                songMid: songMid,
                duration: duration
            ) {
                return detail
            }
        }
        throw MetadataDetailError.noResults
    }

    func applyMissingFields(
        _ detail: ArtistMetadataDetail,
        to entry: ArtistEntry,
        minimumConfidence: Double = 0.70
    ) -> MetadataApplyResult<ArtistEntry> {
        MetadataDetailApplicator.applyMissingFields(detail, to: entry, minimumConfidence: minimumConfidence)
    }

    func applyMissingFields(
        _ detail: AlbumMetadataDetail,
        to entry: AlbumEntry,
        minimumConfidence: Double = 0.70
    ) -> MetadataApplyResult<AlbumEntry> {
        MetadataDetailApplicator.applyMissingFields(detail, to: entry, minimumConfidence: minimumConfidence)
    }

    func applyMissingFields(
        _ detail: TrackMetadataDetail,
        to track: Track,
        minimumConfidence: Double = 0.70
    ) -> Bool {
        MetadataDetailApplicator.applyMissingFields(detail, to: track, minimumConfidence: minimumConfidence)
    }
}

nonisolated enum QQMusicHelperError: LocalizedError, Sendable {
    case helperUnavailable(String)
    case circuitOpen(until: Date)
    case requestWriteFailed(String)
    case requestTimedOut(seconds: TimeInterval)
    case requestFailed(String)
    case invalidResponse(String)
    case processTerminated(Int32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let message):
            return "QQMusic helper unavailable: \(message)"
        case .circuitOpen(let until):
            return "QQMusic helper circuit open until \(until)"
        case .requestWriteFailed(let message):
            return "QQMusic helper request write failed: \(message)"
        case .requestTimedOut(let seconds):
            return "QQMusic helper request timed out after \(Int(seconds)) seconds"
        case .requestFailed(let message):
            return "QQMusic helper request failed: \(message)"
        case .invalidResponse(let message):
            return "QQMusic helper returned invalid response: \(message)"
        case .processTerminated(let code):
            return "QQMusic helper terminated with exit code \(code)"
        case .cancelled:
            return "QQMusic helper request cancelled"
        }
    }
}

actor QQMusicHelperProcess {
    static let shared = QQMusicHelperProcess()

    private struct LaunchCandidate {
        let executableURL: URL
        let currentDirectoryURL: URL
        let environment: [String: String]
    }

    private struct PendingRequest {
        let method: String
        let startedAt: Date
        let continuation: CheckedContinuation<QQMusicHelperResponse, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct QQMusicHelperRequest<Params: Encodable>: Encodable {
        let id: String
        let method: String
        let params: Params
    }

    private struct QQMusicHelperResponse: Decodable, Sendable {
        let id: String?
        let ok: Bool
        let candidates: [QQMusicArtworkCandidate]?
        let detail: QQMusicMetadataDetail?
        let tracks: [QQMusicOnlineTrack]?
        let playlists: [QQMusicOnlinePlaylist]?
        let albums: [QQMusicOnlineAlbum]?
        let likedSongs: QQMusicLikedSongs?
        let like: QQMusicLikeResult?
        let radioGroups: [QQMusicRadioGroup]?
        let artists: [QQMusicOnlineArtist]?
        let artistDetail: QQMusicArtistDetail?
        let toplistGroups: [QQMusicToplistGroup]?
        let lyric: QQMusicLyricPayload?
        let stream: QQMusicStreamResolution?
        let login: QQMusicLoginStatus?
        let qrcode: QQMusicLoginQRCode?
        let helper: QQMusicHelperInfo?
        let error: String?
    }

    private struct ArtistArtworkParams: Encodable, Sendable {
        let name: String
        let limit: Int
    }

    private struct TrackArtworkParams: Encodable, Sendable {
        let title: String
        let artist: String
        let album: String
        let duration: Int?
        let limit: Int
    }

    private struct AlbumArtworkParams: Encodable, Sendable {
        let album: String
        let artist: String
        let limit: Int
    }

    private struct ArtistDetailParams: Encodable, Sendable {
        let name: String?
        let singerMid: String?
    }

    private struct AlbumDetailParams: Encodable, Sendable {
        let album: String?
        let artist: String?
        let albumMid: String?
    }

    private struct SongDetailParams: Encodable, Sendable {
        let title: String?
        let artist: String?
        let album: String?
        let songMid: String?
        let duration: Int?
    }

    private struct SearchSongsParams: Encodable, Sendable {
        let keyword: String
        let limit: Int
        let page: Int
    }

    private struct RecommendFeedParams: Encodable, Sendable {
        let rounds: Int
    }

    private struct RadarParams: Encodable, Sendable {
        let page: Int
    }

    private struct RecommendPlaylistsParams: Encodable, Sendable {
        let page: Int
        let limit: Int
    }

    private struct SetLikedParams: Encodable, Sendable {
        let songMid: String
        let liked: Bool
    }

    private struct RadioTracksParams: Encodable, Sendable {
        let stationId: Int
        let limit: Int
        let firstPlay: Bool
    }

    private struct SearchArtistsParams: Encodable, Sendable {
        let keyword: String
        let limit: Int
    }

    private struct ArtistMidisParams: Encodable, Sendable {
        let singerMid: String
        let limit: Int
        let page: Int
    }

    private struct ArtistSongsParams: Encodable, Sendable {
        let singerMid: String
        let limit: Int
        let page: Int
        let sort: String
    }

    private struct LikedSongsParams: Encodable, Sendable {
        let page: Int
        let limit: Int
    }

    private struct LikedAlbumsParams: Encodable, Sendable {
        let limit: Int
    }

    private struct AlbumTracksParams: Encodable, Sendable {
        let albumId: Int
        let limit: Int
    }

    private struct NewSongsParams: Encodable, Sendable {
        let region: String
    }

    private struct SearchPlaylistsParams: Encodable, Sendable {
        let keyword: String
        let limit: Int
    }

    private struct PlaylistTracksParams: Encodable, Sendable {
        let songlistId: Int?
        let topId: Int?
        let limit: Int
        let page: Int
    }

    private struct LyricParams: Encodable, Sendable {
        let songMid: String
        let songId: Int?
        let translation: Bool
    }

    private struct ResolveSongURLParams: Encodable, Sendable {
        let songMid: String
        let mediaMid: String?
        let quality: String?
    }

    private struct StartLoginParams: Encodable, Sendable {
        let loginType: String
    }

    private struct PollLoginParams: Encodable, Sendable {
        let identifier: String
        let imageBase64: String
        let loginType: String
        let mimetype: String
    }

    private let requestTimeout: TimeInterval = 15

    /// How long the helper process is kept alive while idle.
    ///
    /// Tunable here rather than in the helper so the helper binary stays
    /// swappable for a newer QQMusicAPI build. The value is pushed in from the
    /// main actor (`AppSettings` is main-actor isolated and this is an actor).
    /// Sending one request restarts the countdown, and the process is
    /// relaunched transparently on the next call, so this trades memory for
    /// avoiding a cold start.
    private var idleTimeoutSeconds: TimeInterval = 300

    private var idleTimeout: TimeInterval { max(10, idleTimeoutSeconds) }

    /// Apply the idle-keepalive window. Called from the main actor.
    func applyIdleTimeout(_ seconds: TimeInterval) {
        idleTimeoutSeconds = max(10, seconds)
        scheduleIdleShutdown()
    }

    /// Circuit breaker tunables.
    ///
    /// `AppSettings` is main-actor isolated and this type is an actor, so the
    /// values cannot be read directly here. They are pushed in from the main
    /// actor whenever they change, and mirrored locally so the breaker can
    /// consult them synchronously.
    private struct CircuitConfiguration: Sendable {
        var isEnabled = true
        var threshold = 3
        var failureWindow: TimeInterval = 120
        var openDuration: TimeInterval = 300
    }

    private var circuitConfiguration = CircuitConfiguration()

    /// Apply the user's breaker settings. Called from the main actor.
    func applyCircuitConfiguration(
        isEnabled: Bool,
        threshold: Int,
        failureWindow: TimeInterval,
        openDuration: TimeInterval
    ) {
        circuitConfiguration = CircuitConfiguration(
            isEnabled: isEnabled,
            threshold: max(1, threshold),
            failureWindow: failureWindow,
            openDuration: openDuration
        )
        if !isEnabled {
            // Re-enabling should start from a clean slate rather than resume a
            // circuit that opened before the setting changed.
            circuitOpenUntil = nil
            recentFailureDates.removeAll()
            circuitLastReason = ""
        }
    }

    private var failureWindow: TimeInterval { circuitConfiguration.failureWindow }
    private var circuitOpenDuration: TimeInterval { circuitConfiguration.openDuration }
    private var failureThreshold: Int { max(1, circuitConfiguration.threshold) }
    private var isCircuitBreakerEnabled: Bool { circuitConfiguration.isEnabled }
    private let recentLogLimit = 8_000

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var recentStderr = ""
    private var pendingRequests: [String: PendingRequest] = [:]
    private var idleShutdownTask: Task<Void, Never>?
    private var recentFailureDates: [Date] = []
    private var circuitOpenUntil: Date?
    private var circuitLastReason = ""
    private var lastActivity = Date()
    private var lastLaunchDiagnostics = ""

    private let encoder = JSONEncoder()
    private let decoder = QQMusicHelperProcess.makeDecoder()

    func searchArtistArtwork(name: String, limit: Int = 5) async throws -> [QQMusicArtworkCandidate] {
        try await request(
            method: "search_artist_artwork",
            params: ArtistArtworkParams(name: name, limit: limit)
        )
    }

    func searchTrackArtwork(
        title: String,
        artist: String,
        album: String,
        duration: Int?,
        limit: Int = 5
    ) async throws -> [QQMusicArtworkCandidate] {
        try await request(
            method: "search_track_artwork",
            params: TrackArtworkParams(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                limit: limit
            )
        )
    }

    func searchAlbumArtwork(
        album: String,
        artist: String,
        limit: Int = 5
    ) async throws -> [QQMusicArtworkCandidate] {
        try await request(
            method: "search_album_artwork",
            params: AlbumArtworkParams(album: album, artist: artist, limit: limit)
        )
    }

    func fetchArtistDetail(
        name: String? = nil,
        singerMid: String? = nil
    ) async throws -> QQMusicMetadataDetail {
        try await requestDetail(
            method: "fetch_artist_detail",
            params: ArtistDetailParams(
                name: trimmedOptional(name),
                singerMid: trimmedOptional(singerMid)
            )
        )
    }

    func fetchAlbumDetail(
        album: String? = nil,
        artist: String? = nil,
        albumMid: String? = nil
    ) async throws -> QQMusicMetadataDetail {
        try await requestDetail(
            method: "fetch_album_detail",
            params: AlbumDetailParams(
                album: trimmedOptional(album),
                artist: trimmedOptional(artist),
                albumMid: trimmedOptional(albumMid)
            )
        )
    }

    func fetchSongDetail(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        songMid: String? = nil,
        duration: Int? = nil
    ) async throws -> QQMusicMetadataDetail {
        try await requestDetail(
            method: "fetch_song_detail",
            params: SongDetailParams(
                title: trimmedOptional(title),
                artist: trimmedOptional(artist),
                album: trimmedOptional(album),
                songMid: trimmedOptional(songMid),
                duration: duration
            )
        )
    }

    // MARK: - Online catalog

    /// Send one request and return the raw envelope.
    ///
    /// The existing `request`/`requestDetail` helpers each re-implement the
    /// circuit-breaker, launch, dispatch and error-handling steps for their own
    /// payload type. Online catalog calls return several different shapes, so
    /// they share this one transport and pick their payload out of the envelope.
    /// Send one request, retrying once after a transient failure.
    ///
    /// A cold start or a process that exited between requests shows up as a
    /// launch/termination error rather than an upstream problem; retrying once
    /// absorbs that instead of surfacing it as a failed page load. Cancellation
    /// is never retried — the caller asked to stop.
    private func sendRetrying<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws -> QQMusicHelperResponse {
        do {
            return try await send(method: method, params: params)
        } catch let error as QQMusicHelperError {
            switch error {
            case .cancelled, .circuitOpen, .requestFailed:
                throw error
            case .helperUnavailable, .processTerminated, .requestTimedOut,
                 .requestWriteFailed, .invalidResponse:
                Log.info(
                    "[QQMusicHelperProcess] retrying after \(error) method=\(method)",
                    category: .import
                )
                return try await send(method: method, params: params)
            }
        }
    }

    private func send<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws -> QQMusicHelperResponse {
        try checkCircuitBreaker()
        try await ensureRunning()

        let id = UUID().uuidString
        let startedAt = Date()
        Log.info(
            "[QQMusicHelperProcess] request id=\(id) method=\(method) query=\(querySummary(params))",
            category: .import
        )

        let response: QQMusicHelperResponse
        do {
            response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.enqueueRequest(
                        id: id,
                        method: method,
                        params: params,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task {
                    await self.failPendingRequest(id: id, error: QQMusicHelperError.cancelled)
                }
            }
        } catch {
            Log.warning(
                "[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(error)",
                category: .import
            )
            throw error
        }

        guard response.ok else {
            let message = response.error ?? "unknown helper error"
            recordFailure(reason: message)
            Log.warning(
                "[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(message)",
                category: .import
            )
            throw QQMusicHelperError.requestFailed(message)
        }

        recordSuccess()
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        Log.info(
            "[QQMusicHelperProcess] response id=\(id) method=\(method) durationMs=\(durationMs)",
            category: .import
        )
        return response
    }

    func searchSongs(keyword: String, limit: Int = 20, page: Int = 1) async throws -> [QQMusicOnlineTrack] {
        let response = try await sendRetrying(
            method: "search_songs",
            params: SearchSongsParams(keyword: keyword, limit: limit, page: page)
        )
        return response.tracks ?? []
    }

    /// "猜你喜欢" radio.
    ///
    /// The upstream returns ~5 tracks per round and rounds must be fetched
    /// serially (parallel calls read the same upstream position and return
    /// duplicates), so cost scales with `rounds` at roughly 2.5s each. The
    /// default stays low for a fast first paint; the browse list pages for more
    /// as the user scrolls.
    func fetchRecommendFeed(rounds: Int = 2) async throws -> [QQMusicOnlineTrack] {
        let response = try await sendRetrying(
            method: "fetch_recommend_feed",
            params: RecommendFeedParams(rounds: rounds)
        )
        return response.tracks ?? []
    }

    func fetchRadar(page: Int = 1) async throws -> [QQMusicOnlineTrack] {
        let response = try await send(method: "fetch_radar", params: RadarParams(page: page))
        return response.tracks ?? []
    }

    func fetchRecommendPlaylists(page: Int = 1, limit: Int = 20) async throws -> [QQMusicOnlinePlaylist] {
        let response = try await sendRetrying(
            method: "fetch_recommend_playlists",
            params: RecommendPlaylistsParams(page: page, limit: limit)
        )
        return response.playlists ?? []
    }

    func fetchToplistCategories() async throws -> [QQMusicToplistGroup] {
        let response = try await sendRetrying(
            method: "fetch_toplist_categories",
            params: EmptyParams()
        )
        return response.toplistGroups ?? []
    }

    /// Tracks of a playlist (`songlistId`) or a ranking (`topId`).
    func fetchPlaylistTracks(
        songlistId: Int? = nil,
        topId: Int? = nil,
        limit: Int = 50,
        page: Int = 1
    ) async throws -> [QQMusicOnlineTrack] {
        let response = try await sendRetrying(
            method: "fetch_playlist_tracks",
            params: PlaylistTracksParams(
                songlistId: songlistId,
                topId: topId,
                limit: limit,
                page: page
            )
        )
        return response.tracks ?? []
    }

    /// New-song radio ("推荐新歌"), filterable by region. One call returns far
    /// more tracks than the guess-you-like radio, so it suits a long queue.
    func fetchNewSongs(region: QQMusicNewSongRegion = .latest) async throws -> [QQMusicOnlineTrack] {
        let response = try await sendRetrying(
            method: "fetch_new_songs",
            params: NewSongsParams(region: region.rawValue)
        )
        return response.tracks ?? []
    }

    /// Search playlists by keyword — how category/mood browsing works here.
    func searchPlaylists(keyword: String, limit: Int = 20) async throws -> [QQMusicOnlinePlaylist] {
        let response = try await sendRetrying(
            method: "search_playlists",
            params: SearchPlaylistsParams(keyword: keyword, limit: limit)
        )
        return response.playlists ?? []
    }

    // MARK: - User library (read-only)

    /// Add or remove a track from "我喜欢".
    ///
    /// The upstream applies this asynchronously (a few seconds), so the returned
    /// value is the requested state, not confirmation that it is visible yet.
    /// Takes a song mid rather than the numeric id: the library only stores the
    /// mid, and the helper resolves the id the write endpoint actually wants.
    func setLiked(songMid: String, liked: Bool) async throws -> QQMusicLikeResult {
        let response = try await sendRetrying(
            method: "set_liked",
            params: SetLikedParams(songMid: songMid, liked: liked)
        )
        guard let result = response.like else {
            throw QQMusicHelperError.requestFailed("missing like payload")
        }
        return result
    }

    /// Tracks in "我喜欢", paginated.
    func fetchLikedSongs(page: Int = 1, limit: Int = 50) async throws -> QQMusicLikedSongs {
        let response = try await sendRetrying(
            method: "fetch_liked_songs",
            params: LikedSongsParams(page: page, limit: limit)
        )
        return response.likedSongs ?? QQMusicLikedSongs(title: "我喜欢", total: 0, tracks: [])
    }

    /// Favorited albums, already resolved to names and covers.
    func fetchLikedAlbums(limit: Int = 30) async throws -> [QQMusicOnlineAlbum] {
        let response = try await sendRetrying(
            method: "fetch_liked_albums",
            params: LikedAlbumsParams(limit: limit)
        )
        return response.albums ?? []
    }

    // MARK: - Radio

    /// Grouped radio stations. Station ids come only from this response; nothing
    /// hardcodes one, since the upstream's own ids are not contractual.
    func fetchRadioStations() async throws -> [QQMusicRadioGroup] {
        let response = try await send(method: "fetch_radio_stations", params: EmptyParams())
        return response.radioGroups ?? []
    }

    func fetchRadioTracks(
        stationID: Int,
        limit: Int = 20,
        firstPlay: Bool = true
    ) async throws -> [QQMusicOnlineTrack] {
        let response = try await sendRetrying(
            method: "fetch_radio_tracks",
            params: RadioTracksParams(stationId: stationID, limit: limit, firstPlay: firstPlay)
        )
        return response.tracks ?? []
    }

    // MARK: - Artists

    /// Artist biography. A missing biography is not an error.
    func fetchArtistDetail(singerMid: String) async throws -> QQMusicArtistDetail? {
        let response = try await sendRetrying(
            method: "fetch_artist_biography",
            params: ArtistDetailParams(name: nil, singerMid: singerMid)
        )
        return response.artistDetail
    }

    func searchArtists(keyword: String, limit: Int = 20) async throws -> [QQMusicOnlineArtist] {
        let response = try await sendRetrying(
            method: "search_artists",
            params: SearchArtistsParams(keyword: keyword, limit: limit)
        )
        return response.artists ?? []
    }

    /// `sort` is `hot` (upstream order) or `latest` (by album release date,
    /// computed by the helper because the upstream ignores ordering params).
    func fetchArtistSongs(
        singerMid: String,
        limit: Int = 50,
        page: Int = 1,
        sort: String = "hot"
    ) async throws -> [QQMusicOnlineTrack] {
        let response = try await sendRetrying(
            method: "fetch_artist_songs",
            params: ArtistSongsParams(singerMid: singerMid, limit: limit, page: page, sort: sort)
        )
        return response.tracks ?? []
    }

    func fetchArtistAlbums(
        singerMid: String,
        limit: Int = 50,
        page: Int = 1
    ) async throws -> [QQMusicOnlineAlbum] {
        let response = try await sendRetrying(
            method: "fetch_artist_albums",
            params: ArtistMidisParams(singerMid: singerMid, limit: limit, page: page)
        )
        return response.albums ?? []
    }

    /// Tracks of a favorited album, addressed by its numeric id.
    func fetchAlbumTracks(albumID: Int, limit: Int = 100) async throws -> [QQMusicOnlineTrack] {
        let response = try await sendRetrying(
            method: "fetch_album_tracks",
            params: AlbumTracksParams(albumId: albumID, limit: limit)
        )
        return response.tracks ?? []
    }

    /// The account's own playlists. Requires a login.
    func fetchUserPlaylists() async throws -> [QQMusicOnlinePlaylist] {
        let response = try await send(method: "fetch_user_playlists", params: EmptyParams())
        return response.playlists ?? []
    }

    func fetchLyric(
        songMid: String,
        songId: Int? = nil,
        translation: Bool = true
    ) async throws -> QQMusicLyricPayload {
        let response = try await sendRetrying(
            method: "fetch_lyric",
            params: LyricParams(songMid: songMid, songId: songId, translation: translation)
        )
        return response.lyric ?? QQMusicLyricPayload()
    }

    /// Ask for the best playable url. Returns `playable == false` (rather than
    /// throwing) when the upstream withholds the track, so callers can show a
    /// precise reason instead of a generic failure.
    func resolveSongURL(
        songMid: String,
        mediaMid: String? = nil,
        quality: String? = nil
    ) async throws -> QQMusicStreamResolution {
        let response = try await sendRetrying(
            method: "resolve_song_url",
            params: ResolveSongURLParams(
                songMid: songMid,
                mediaMid: trimmedOptional(mediaMid),
                quality: trimmedOptional(quality)
            )
        )
        guard let stream = response.stream else {
            throw QQMusicHelperError.requestFailed("missing stream payload")
        }
        return stream
    }

    private struct EmptyParams: Encodable, Sendable {}

    // MARK: - Account

    /// Query the helper's own version and capabilities.
    func helperInfo() async throws -> QQMusicHelperInfo {
        let response = try await send(method: "get_helper_info", params: EmptyParams())
        guard let info = response.helper else {
            throw QQMusicHelperError.requestFailed("missing helper info")
        }
        return info
    }

    /// Whether a usable credential is stored, refreshing it if it went stale.
    func loginStatus() async throws -> QQMusicLoginStatus {
        let response = try await send(method: "get_login_status", params: EmptyParams())
        return response.login ?? QQMusicLoginStatus(loggedIn: false)
    }

    /// Create a login QR code for the given flow.
    func startLogin(type: QQMusicLoginType) async throws -> QQMusicLoginQRCode {
        let response = try await sendRetrying(
            method: "start_login",
            params: StartLoginParams(loginType: type.rawValue)
        )
        guard let qr = response.qrcode else {
            throw QQMusicHelperError.requestFailed("missing qrcode payload")
        }
        return qr
    }

    /// Poll a login QR code once. Returns `loggedIn == true` once accepted.
    func pollLogin(_ qr: QQMusicLoginQRCode) async throws -> QQMusicLoginStatus {
        let response = try await sendRetrying(
            method: "poll_login",
            params: PollLoginParams(
                identifier: qr.identifier,
                imageBase64: qr.imageBase64,
                loginType: qr.loginType,
                mimetype: qr.mimetype
            )
        )
        return response.login ?? QQMusicLoginStatus(loggedIn: false)
    }

    /// Forget the stored credential.
    func logout() async throws -> QQMusicLoginStatus {
        let response = try await send(method: "logout", params: EmptyParams())
        return response.login ?? QQMusicLoginStatus(loggedIn: false)
    }

    /// Build a credential from cookies captured by the web login window.
    ///
    /// The upstream authenticates from `uin` + `qm_keyst`, which is exactly the
    /// pair the login page sets, so this is equivalent to completing the QR
    /// flow — including the playback ticket VIP url resolution needs.
    func importCookies(_ cookies: [String: String]) async throws -> QQMusicLoginStatus {
        let response = try await sendRetrying(
            method: "import_cookies",
            params: ImportCookiesParams(cookies: cookies)
        )
        guard let status = response.login else {
            throw QQMusicHelperError.requestFailed("missing login payload")
        }
        return status
    }

    private struct ImportCookiesParams: Encodable, Sendable {
        let cookies: [String: String]
    }

    /// Current breaker state, for the settings page.
    ///
    /// `nil` means closed (requests allowed).
    func circuitState() -> QQMusicCircuitState {
        guard isCircuitBreakerEnabled else { return .disabled }
        guard let until = circuitOpenUntil, Date() < until else { return .closed }
        return .open(until: until, reason: circuitLastReason)
    }

    /// Close the breaker immediately and forget accumulated failures.
    ///
    /// Exposed because the automatic cooldown is a guess: if the user knows the
    /// upstream is reachable again, waiting out the remainder is pointless.
    func resetCircuitBreaker() {
        circuitOpenUntil = nil
        recentFailureDates.removeAll()
        circuitLastReason = ""
        Log.info("[QQMusicHelperProcess] circuit breaker reset by user", category: .import)
    }

    func terminate() {
        stopProcess(failingPendingWith: QQMusicHelperError.cancelled)
    }

    private func request<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws -> [QQMusicArtworkCandidate] {
        try checkCircuitBreaker()
        try await ensureRunning()

        let id = UUID().uuidString
        let startedAt = Date()
        let query = querySummary(params)
        Log.info("[QQMusicHelperProcess] request id=\(id) method=\(method) query=\(query)", category: .import)

        let response: QQMusicHelperResponse
        do {
            response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.enqueueRequest(
                        id: id,
                        method: method,
                        params: params,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task {
                    await self.failPendingRequest(id: id, error: QQMusicHelperError.cancelled)
                }
            }
        } catch {
            Log.warning("[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(error)", category: .import)
            throw error
        }

        guard response.ok else {
            let message = response.error ?? "unknown helper error"
            recordFailure(reason: message)
            Log.warning("[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(message)", category: .import)
            throw QQMusicHelperError.requestFailed(message)
        }

        let candidates = response.candidates ?? []
        recordSuccess()
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let topConfidence = candidates.compactMap(\.confidence).max() ?? 0
        Log.info("[QQMusicHelperProcess] response id=\(id) method=\(method) candidates=\(candidates.count) topConfidence=\(String(format: "%.2f", topConfidence)) durationMs=\(durationMs)", category: .import)
        return candidates
    }

    private func requestDetail<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws -> QQMusicMetadataDetail {
        try checkCircuitBreaker()
        try await ensureRunning()

        let id = UUID().uuidString
        let startedAt = Date()
        let query = querySummary(params)
        Log.info("[QQMusicHelperProcess] request id=\(id) method=\(method) query=\(query)", category: .import)

        let response: QQMusicHelperResponse
        do {
            response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.enqueueRequest(
                        id: id,
                        method: method,
                        params: params,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task {
                    await self.failPendingRequest(id: id, error: QQMusicHelperError.cancelled)
                }
            }
        } catch {
            Log.warning("[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(error)", category: .import)
            throw error
        }

        guard response.ok else {
            let message = response.error ?? "unknown helper error"
            recordFailure(reason: message)
            Log.warning("[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(message)", category: .import)
            throw QQMusicHelperError.requestFailed(message)
        }

        guard let detail = response.detail else {
            let message = "missing metadata detail"
            recordFailure(reason: message)
            Log.warning("[QQMusicHelperProcess] request failed id=\(id) method=\(method) reason=\(message)", category: .import)
            throw QQMusicHelperError.invalidResponse(message)
        }

        recordSuccess()
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let confidence = detail.confidence ?? detail.metadataConfidence ?? 0
        Log.info("[QQMusicHelperProcess] response id=\(id) method=\(method) detail=1 confidence=\(String(format: "%.2f", confidence)) durationMs=\(durationMs)", category: .import)
        return detail
    }

    private func enqueueRequest<Params: Encodable & Sendable>(
        id: String,
        method: String,
        params: Params,
        continuation: CheckedContinuation<QQMusicHelperResponse, Error>
    ) {
        guard let stdinHandle else {
            continuation.resume(
                throwing: QQMusicHelperError.helperUnavailable("stdin pipe is not available")
            )
            return
        }

        let timeout = requestTimeout
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            await self?.failPendingRequest(
                id: id,
                error: QQMusicHelperError.requestTimedOut(seconds: timeout)
            )
        }

        pendingRequests[id] = PendingRequest(
            method: method,
            startedAt: Date(),
            continuation: continuation,
            timeoutTask: timeoutTask
        )

        do {
            let payload = QQMusicHelperRequest(id: id, method: method, params: params)
            var data = try encoder.encode(payload)
            data.append(0x0A)
            try stdinHandle.write(contentsOf: data)
            markActivity()
        } catch {
            timeoutTask.cancel()
            pendingRequests.removeValue(forKey: id)
            recordFailure(reason: "request write failed: \(error.localizedDescription)")
            continuation.resume(
                throwing: QQMusicHelperError.requestWriteFailed(error.localizedDescription)
            )
        }
    }

    private func ensureRunning() async throws {
        if let process, process.isRunning, stdinHandle != nil {
            markActivity()
            return
        }

        stopProcess(failingPendingWith: QQMusicHelperError.processTerminated(-1))

        guard let candidate = findLaunchCandidate() else {
            recordFailure(reason: "helper unavailable")
            throw QQMusicHelperError.helperUnavailable(
                lastLaunchDiagnostics.isEmpty
                    ? "binary missing"
                    : lastLaunchDiagnostics
            )
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = candidate.executableURL
        process.arguments = []
        process.currentDirectoryURL = candidate.currentDirectoryURL
        process.environment = candidate.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                try? handle.close()
                return
            }
            // Pass raw bytes: this handler delivers arbitrary chunks, and a
            // chunk boundary can fall inside a multi-byte character (every CJK
            // track title). Decoding per chunk here would corrupt the stream.
            Task {
                await self?.handleStdout(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                try? handle.close()
                return
            }
            // Diagnostics only, so a lossy decode is acceptable here.
            let text = String(decoding: data, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task {
                await self?.appendStderr(text)
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            Task {
                await self?.handleTermination(terminatedProcess)
            }
        }

        do {
            try process.run()
        } catch {
            let reason = "launch failed: \(error.localizedDescription)"
            recordFailure(reason: reason)
            Log.warning("[QQMusicHelperProcess] \(reason) path=\(candidate.executableURL.path)", category: .import)
            throw QQMusicHelperError.helperUnavailable(reason)
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        stdoutBuffer = Data()
        recentStderr = ""
        markActivity()
        Log.info("[QQMusicHelperProcess] started path=\(candidate.executableURL.path)", category: .import)
    }

    private func handleStdout(_ data: Data) {
        stdoutBuffer.append(data)
        drainStdoutLines()
    }

    /// Split completed lines out of the byte buffer.
    ///
    /// Buffering raw bytes rather than a `String` matters: `readabilityHandler`
    /// delivers arbitrary chunks, so a multi-byte UTF-8 character (every CJK
    /// track title) can straddle a chunk boundary. Decoding each chunk on its
    /// own would yield nil and silently drop the data; scanning for `0x0A` in
    /// bytes and decoding only whole lines cannot split a character.
    private func drainStdoutLines() {
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newlineIndex]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8) else {
                // A line that is not valid UTF-8 is a protocol violation, not a
                // chunk boundary; report it rather than dropping it silently.
                recordFailure(reason: "JSON IPC invalid UTF-8 line")
                Log.warning(
                    "[QQMusicHelperProcess] JSON IPC invalid UTF-8 line bytes=\(lineData.count)",
                    category: .import
                )
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            handleResponseLine(trimmed)
        }
    }

    private func handleResponseLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let response: QQMusicHelperResponse
        do {
            response = try decoder.decode(QQMusicHelperResponse.self, from: data)
        } catch {
            recordFailure(reason: "JSON IPC invalid response")
            Log.warning("[QQMusicHelperProcess] JSON IPC invalid response reason=\(error)", category: .import)
            return
        }

        guard let id = response.id,
              let pending = pendingRequests.removeValue(forKey: id)
        else {
            Log.warning("[QQMusicHelperProcess] JSON IPC unknown response id=\(response.id ?? "nil")", category: .import)
            return
        }

        pending.timeoutTask.cancel()
        markActivity()
        pending.continuation.resume(returning: response)
    }

    private func handleTermination(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        let status = terminatedProcess.terminationStatus
        let stderr = recentStderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = stderr.isEmpty ? "process terminated code=\(status)" : "process terminated code=\(status) stderr=\(stderr)"
        Log.warning("[QQMusicHelperProcess] \(reason)", category: .import)
        stopProcess(failingPendingWith: QQMusicHelperError.processTerminated(status))
        recordFailure(reason: reason)
    }

    private func failPendingRequest(id: String, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
        recordFailure(reason: String(describing: error))
    }

    private func failAllPendingRequests(with error: Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for request in pending.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func stopProcess(failingPendingWith error: Error) {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        failAllPendingRequests(with: error)

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinHandle?.close()
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()

        if let process, process.isRunning {
            process.terminate()
        }

        process = nil
        stdinHandle = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutBuffer = Data()
    }

    private func markActivity() {
        lastActivity = Date()
        scheduleIdleShutdown()
    }

    private func scheduleIdleShutdown() {
        idleShutdownTask?.cancel()
        idleShutdownTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64((self?.idleTimeout ?? 60) * 1_000_000_000))
            } catch {
                return
            }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        guard pendingRequests.isEmpty else {
            scheduleIdleShutdown()
            return
        }
        guard Date().timeIntervalSince(lastActivity) >= idleTimeout else {
            scheduleIdleShutdown()
            return
        }
        Log.info("[QQMusicHelperProcess] idle timeout; stopping helper", category: .import)
        stopProcess(failingPendingWith: QQMusicHelperError.cancelled)
    }

    private func appendStderr(_ text: String) {
        recentStderr.append(text)
        if recentStderr.count > recentLogLimit {
            recentStderr = String(recentStderr.suffix(recentLogLimit))
        }
    }

    private func recordFailure(reason: String) {
        guard isCircuitBreakerEnabled else { return }
        let now = Date()
        recentFailureDates = recentFailureDates.filter {
            now.timeIntervalSince($0) <= failureWindow
        }
        recentFailureDates.append(now)
        circuitLastReason = reason
        if recentFailureDates.count >= failureThreshold {
            circuitOpenUntil = now.addingTimeInterval(circuitOpenDuration)
            Log.warning("[QQMusicHelperProcess] circuit open until=\(circuitOpenUntil!) reason=\(reason)", category: .import)
            stopProcess(failingPendingWith: QQMusicHelperError.requestFailed("circuit opened"))
        }
    }

    private func recordSuccess() {
        recentFailureDates.removeAll()
        circuitOpenUntil = nil
        circuitLastReason = ""
    }

    private func checkCircuitBreaker() throws {
        guard isCircuitBreakerEnabled else {
            // Disabled: clear any state so re-enabling starts fresh rather than
            // resuming a stale open circuit.
            if circuitOpenUntil != nil {
                circuitOpenUntil = nil
                recentFailureDates.removeAll()
                circuitLastReason = ""
            }
            return
        }
        guard let until = circuitOpenUntil else { return }
        if Date() < until {
            Log.warning("[QQMusicHelperProcess] circuit open until=\(until) reason=\(circuitLastReason)", category: .import)
            throw QQMusicHelperError.circuitOpen(until: until)
        }
        circuitOpenUntil = nil
        recentFailureDates.removeAll()
        circuitLastReason = ""
    }

    private func findLaunchCandidate() -> LaunchCandidate? {
        // Prefer a user-installed helper so it can be updated independently of
        // the app; fall back to the bundled copy.
        let external = Self.externalHelperDirectory
            .appendingPathComponent("qqmusic-helper", isDirectory: false)
        let candidates = [external, bundledBinaryURL()]

        for binaryURL in candidates {
            Log.info("[QQMusicHelperProcess] helper candidate path=\(binaryURL.path)", category: .import)

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: binaryURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                continue
            }
            guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
                lastLaunchDiagnostics = "helper not executable: \(binaryURL.path)"
                Log.warning("[QQMusicHelperProcess] \(lastLaunchDiagnostics)", category: .import)
                continue
            }

            lastLaunchDiagnostics = ""
            // Point the helper at a writable, app-owned directory so the login
            // ticket survives the helper's 60s idle shutdown.
            try? FileManager.default.createDirectory(
                at: Self.credentialDirectory,
                withIntermediateDirectories: true
            )
            var environment = ProcessInfo.processInfo.environment
            environment["KMGCCC_QQMUSIC_CREDENTIAL_DIR"] = Self.credentialDirectory.path

            return LaunchCandidate(
                executableURL: binaryURL,
                currentDirectoryURL: binaryURL.deletingLastPathComponent(),
                environment: environment
            )
        }

        lastLaunchDiagnostics = "helper binary missing (checked external and bundled paths)"
        Log.warning("[QQMusicHelperProcess] \(lastLaunchDiagnostics)", category: .import)
        return nil
    }

    private func bundledBinaryURL() -> URL {
        let resources = Bundle.main.resourceURL
            ?? URL(fileURLWithPath: Bundle.main.resourcePath ?? "", isDirectory: true)
        return resources
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("qqmusic-helper", isDirectory: true)
            .appendingPathComponent("qqmusic-helper", isDirectory: false)
    }

    /// Directory holding a user-installed helper, if any.
    ///
    /// The QQ Music endpoints are reverse-engineered and change without notice,
    /// so the helper is versioned independently of the app. A newer build
    /// dropped here is picked up on the next launch without rebuilding the app;
    /// the bundled copy stays as the fallback so the feature always works out
    /// of the box.
    nonisolated static var externalHelperDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("kmgccc.player", isDirectory: true)
            .appendingPathComponent("QQMusicHelper", isDirectory: true)
    }

    /// Root for the persisted QQ Music credential.
    ///
    /// Passed to the helper as `KMGCCC_QQMUSIC_CREDENTIAL_DIR` so the login
    /// ticket survives helper restarts (the helper exits after 60s idle).
    nonisolated static var credentialDirectory: URL {
        externalHelperDirectory.appendingPathComponent("Credential", isDirectory: true)
    }

    private func querySummary<Params: Encodable>(_ params: Params) -> String {
        guard let data = try? encoder.encode(params),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "{}"
        }
        let pairs = object
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let text = pairs.joined(separator: ",")
        return text.count > 240 ? String(text.prefix(240)) : text
    }

    private func trimmedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }
            let value = try container.decode(String.self)
            // Internet datetime with fractional seconds (e.g. "2023-01-15T10:30:45.123Z")
            if let date = try? Date(value, strategy: Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true)) {
                return date
            }
            // Internet datetime without fractional seconds (e.g. "2023-01-15T10:30:45Z")
            if let date = try? Date(value, strategy: Date.ISO8601FormatStyle(timeZoneSeparator: .colon)) {
                return date
            }
            // Date only (e.g. "2023-01-15")
            if let date = QQMusicHelperProcess.parseQQMusicDateOnly(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported QQMusic helper date: \(value)"
            )
        }
        return decoder
    }

    private nonisolated static func parseQQMusicDateOnly(_ string: String) -> Date? {
        let parts = string.split(separator: "-", maxSplits: 2)
        guard parts.count == 3,
              let year = Int(parts[0]), parts[0].count == 4,
              let month = Int(parts[1]), parts[1].count == 2,
              let day = Int(parts[2]), parts[2].count == 2 else { return nil }
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        comps.year = year
        comps.month = month
        comps.day = day
        return comps.date
    }
}
