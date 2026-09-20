//
//  QQMusicWebAPI.swift
//  kmgccc_player
//
//  Direct HTTP access to the QQ Music web endpoints.
//
//  The Python helper spawns a process and pays for a fresh client per request,
//  which measures around 1.3s per call. The same endpoints answer a plain
//  `POST https://u.y.qq.com/cgi-bin/musicu.fcg` in roughly 0.3s, so read paths
//  that are hit often are worth doing here instead.
//
//  This is deliberately narrow for now: one endpoint, "我喜欢", as a pilot. The
//  helper keeps every other capability, and login stays entirely with it — this
//  client only reads the credential the helper already persisted.
//
//  What the calls need (verified against the live upstream):
//
//    * two cookies, `uin` (the numeric music id) and `qm_keyst`
//    * `g_tk = hash33(qm_keyst)`, the same algorithm the helper uses
//    * a JSON body; form encoding is rejected with 500001
//
//  No request signature is involved: the modules used here are served by
//  `musicu.fcg`, and only a few unrelated ones (dislike list, uploads) require
//  the signed `musics.fcg` variant. Batched requests are possible too — several
//  `req_N` entries in one round trip — which is the main reason this is worth
//  having.
//

import Foundation

/// A credential read from the helper's on-disk store.
nonisolated struct QQMusicWebCredential: Sendable, Equatable {
    let musicID: String
    let musicKey: String

    var isUsable: Bool { !musicID.isEmpty && !musicKey.isEmpty }

    /// QQ Music's `g_tk`: the same `hash33` the upstream library computes.
    var gtK: Int {
        var hash = 5381
        for scalar in musicKey.unicodeScalars {
            hash = hash &+ (hash << 5) &+ Int(scalar.value)
        }
        return hash & 0x7FFF_FFFF
    }
}

nonisolated enum QQMusicWebAPIError: Error, LocalizedError {
    case noCredential
    case transport(String)
    case upstream(code: Int, message: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .noCredential:
            return "需要登录后才能读取"
        case .transport(let detail):
            return "网络请求失败：\(detail)"
        case .upstream(let code, let message):
            return message.isEmpty ? "上游返回错误（\(code)）" : "\(message)（\(code)）"
        case .malformedResponse:
            return "上游返回的数据无法解析"
        }
    }
}

/// Reads the credential the helper persisted, and calls the web endpoints.
nonisolated struct QQMusicWebAPI: Sendable {

    static let shared = QQMusicWebAPI()

    private static let endpoint = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!

    /// "我喜欢" lives in the reserved folder with this id.
    private static let likedSongsDirectoryID = 201

    // MARK: - Credential

    /// Load the credential from the helper's credential directory.
    ///
    /// Re-read every call rather than cached: the file is how login survives the
    /// helper's idle shutdown, so it can change underneath us (web login, QR
    /// login, logout, or a refresh that rewrites the ticket).
    func loadCredential() -> QQMusicWebCredential? {
        let file = QQMusicHelperProcess.credentialDirectory
            .appendingPathComponent("qqmusic-credential.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // `str_musicid` is the string form the library prefers; fall back to the
        // numeric one. Both are present in practice.
        let musicID = (object["str_musicid"] as? String)
            ?? (object["musicid"].map { String(describing: $0) } ?? "")
        let musicKey = (object["musickey"] as? String) ?? ""
        let credential = QQMusicWebCredential(musicID: musicID, musicKey: musicKey)
        return credential.isUsable ? credential : nil
    }

    // MARK: - Requests

    /// Fetch one page of the account's "我喜欢".
    ///
    /// `total` is the folder's own count, which is what lets the caller page
    /// without guessing and decide whether a list is complete.
    func fetchLikedSongs(page: Int, limit: Int) async throws -> QQMusicLikedSongs {
        guard let credential = loadCredential() else {
            throw QQMusicWebAPIError.noCredential
        }

        let begin = max(0, (page - 1) * limit)
        let request = makeRequest(
            credential: credential,
            module: "music.srfDissInfo.DissInfo",
            method: "CgiGetDiss",
            param: [
                "disstid": 0,
                "dirid": Self.likedSongsDirectoryID,
                "tag": true,
                "song_begin": begin,
                "song_num": limit,
                "userinfo": true,
                "orderlist": true,
            ]
        )

        let payload = try await send(request)
        return try Self.decodeLikedSongs(payload)
    }

    /// Favorited albums.
    ///
    /// Goes through the legacy `c.y.qq.com` endpoint rather than a `musicu.fcg`
    /// module: the modern candidates answer 80000 for this account, and the
    /// helper reached the same conclusion (see its `fetch_user_playlists` note,
    /// which records 40000 for the module it tried).
    func fetchLikedAlbums(limit: Int = 30) async throws -> [QQMusicOnlineAlbum] {
        let data = try await fetchProfileAssets(reqtype: 2, limit: limit)
        let raw = data["albumlist"] as? [[String: Any]] ?? []
        return raw.compactMap { entry in
            guard let id = Self.parseInt(entry["albumid"]) else { return nil }
            return QQMusicOnlineAlbum(
                id: id,
                title: (entry["albumname"] as? String) ?? "未知专辑",
                albumMid: entry["albummid"] as? String,
                coverURL: Self.albumCoverURL(mid: entry["albummid"] as? String),
                artist: entry["singername"] as? String,
                releaseDate: Self.parseTimestamp(entry["pubtime"])
            )
        }
    }

    /// The account's own playlists (created and favorited).
    func fetchUserPlaylists(limit: Int = 100) async throws -> [QQMusicOnlinePlaylist] {
        let data = try await fetchProfileAssets(reqtype: 3, limit: limit)
        let raw = data["cdlist"] as? [[String: Any]] ?? []
        return raw.compactMap { entry in
            // This endpoint mixes in the reserved folders (the liked-songs
            // folder answers `dirid: 201` with no `dissid`), so an entry without
            // a real playlist id is skipped rather than shown as a playlist.
            guard let id = Self.parseInt(entry["dissid"]), id > 0 else { return nil }
            return QQMusicOnlinePlaylist(
                id: id,
                title: (entry["dissname"] as? String) ?? "未命名歌单",
                coverURL: Self.normalizedArtworkURL(entry["logo"] as? String),
                creator: (entry["nickname"] as? String) ?? "",
                songCount: Self.parseInt(entry["songnum"]),
                playCount: Self.parseInt(entry["listennum"])
            )
        }
    }

    /// One page of a playlist's tracks, plus the list's own total.
    ///
    /// A playlist routinely holds more than the upstream's per-request cap, so
    /// the caller needs the total to know whether to keep paging. Returning it
    /// with the page keeps that decision here rather than making the caller
    /// guess by fetching until a short page.
    func fetchPlaylistTracks(
        songlistId: Int,
        offset: Int,
        limit: Int
    ) async throws -> (tracks: [QQMusicOnlineTrack], total: Int) {
        guard let credential = loadCredential() else {
            throw QQMusicWebAPIError.noCredential
        }
        let request = makeRequest(
            credential: credential,
            module: "music.srfDissInfo.DissInfo",
            method: "CgiGetDiss",
            param: [
                "disstid": songlistId,
                "tag": true,
                "song_begin": offset,
                "song_num": limit,
                "userinfo": true,
            ]
        )
        let data = try Self.payload(try await send(request))
        let tracks = (data["songlist"] as? [[String: Any]] ?? []).compactMap(Self.decodeTrack)
        let total = Self.parseInt((data["dirinfo"] as? [String: Any])?["songnum"]) ?? tracks.count
        return (tracks, total)
    }

    /// One page of a ranking's tracks, plus the ranking's own total.
    ///
    /// A separate call because rankings live on a different module and return a
    /// differently shaped payload (an offset-based window rather than a folder
    /// listing). The total sits under `data.data.totalNum`.
    func fetchToplistTracks(
        topId: Int,
        offset: Int,
        limit: Int
    ) async throws -> (tracks: [QQMusicOnlineTrack], total: Int) {
        guard let credential = loadCredential() else {
            throw QQMusicWebAPIError.noCredential
        }
        let request = makeRequest(
            credential: credential,
            module: "musicToplist.ToplistInfoServer",
            method: "GetDetail",
            param: ["topid": topId, "offset": offset, "num": limit, "period": ""]
        )
        let data = try Self.payload(try await send(request))
        let nested = data["data"] as? [String: Any]
        // The rows under `data.data.song` are a *presentation* list: rank, title
        // and a cover, but no song mid — so they cannot be played or downloaded.
        // `songInfoList` carries the real track payload (mid, singers, album,
        // file sizes), so that is the one to read. Verified against a live
        // ranking, where the presentation rows decoded to nothing.
        let rows = data["songInfoList"] as? [[String: Any]] ?? []
        let total = Self.parseInt(nested?["totalNum"]) ?? rows.count
        return (rows.compactMap(Self.decodeTrack), total)
    }

    /// Lyrics for a track, plus translation and romanization when the upstream
    /// has them.
    ///
    /// `crypt: 0` asks for the plaintext base64 form. The alternative
    /// (`crypt: 1`) returns a triple-DES payload that would have to be
    /// decrypted here; the plaintext path avoids porting that algorithm.
    func fetchLyric(songMid: String, translation: Bool = true) async throws -> QQMusicLyricPayload {
        guard let credential = loadCredential() else {
            throw QQMusicWebAPIError.noCredential
        }
        let request = makeRequest(
            credential: credential,
            module: "music.musichallSong.PlayLyricInfo",
            method: "GetPlayLyricInfo",
            param: [
                "songMID": songMid,
                "songID": 0,
                "format": "json",
                "crypt": 0,
                "qrc": 0,
                "trans": translation ? 1 : 0,
                "roma": translation ? 1 : 0,
            ]
        )
        let data = try Self.payload(try await send(request))
        return QQMusicLyricPayload(
            lyric: Self.decodeBase64Text(data["lyric"]),
            translation: Self.decodeBase64Text(data["trans"]),
            romanization: Self.decodeBase64Text(data["roma"])
        )
    }

    /// Shared call to the legacy profile-assets endpoint used by favourites.
    ///
    /// `reqtype` selects the collection: 2 is albums, 3 is playlists. This is
    /// the endpoint the helper also uses, and its numeric fields come back as
    /// strings (`songnum: "241"`), which `parseInt` handles.
    private func fetchProfileAssets(reqtype: Int, limit: Int) async throws -> [String: Any] {
        guard let credential = loadCredential() else {
            throw QQMusicWebAPIError.noCredential
        }
        var components = URLComponents(string: "https://c.y.qq.com/fav/fcgi-bin/fcg_get_profile_order_asset.fcg")!
        components.queryItems = [
            URLQueryItem(name: "ct", value: "20"),
            URLQueryItem(name: "cid", value: "205360956"),
            URLQueryItem(name: "userid", value: credential.musicID),
            URLQueryItem(name: "reqtype", value: String(reqtype)),
            URLQueryItem(name: "sin", value: "0"),
            URLQueryItem(name: "ein", value: String(limit)),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.cookieHeader(credential), forHTTPHeaderField: "Cookie")

        let response = try await send(request)
        // This endpoint nests everything under `data` and reports failures with
        // `code`, so an empty `data` is the thing to reject.
        guard let data = response["data"] as? [String: Any], !data.isEmpty else {            throw QQMusicWebAPIError.upstream(
                code: Self.parseInt(response["code"]) ?? -1,
                message: (response["subcode"] as? String) ?? ""
            )
        }
        return data
    }

    // MARK: - Request construction

    private func makeRequest(
        credential: QQMusicWebCredential,
        module: String,
        method: String,
        param: [String: Any]
    ) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Sent because the upstream is known to vary its response (and has
        // returned an obfuscated payload) by caller identity.
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.cookieHeader(credential), forHTTPHeaderField: "Cookie")

        let body: [String: Any] = [
            "comm": [
                "cv": 4747474,
                "ct": 24,
                "format": "json",
                "inCharset": "utf-8",
                "outCharset": "utf-8",
                "notice": 0,
                "platform": "yqq.json",
                "needNewCode": 1,
                "uin": credential.musicID,
                "g_tk": credential.gtK,
            ],
            "req_0": [
                "module": module,
                "method": method,
                "param": param,
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Both cookie spellings, because the upstream reads the legacy `uin` on one
    /// path and `qqmusic_uin` on another.
    private static func cookieHeader(_ credential: QQMusicWebCredential) -> String {
        "uin=\(credential.musicID); qm_keyst=\(credential.musicKey)"
            + "; qqmusic_key=\(credential.musicKey); qqmusic_uin=\(credential.musicID)"
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QQMusicWebAPIError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw QQMusicWebAPIError.transport("HTTP \(http.statusCode)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QQMusicWebAPIError.malformedResponse
        }
        return object
    }

    // MARK: - Decoding

    /// Pull the requested payload out of a batched response, or surface why not.
    private static func payload(_ response: [String: Any], slot: String = "req_0") throws -> [String: Any] {
        guard let envelope = response[slot] as? [String: Any] else {
            throw QQMusicWebAPIError.malformedResponse
        }
        let code = (envelope["code"] as? Int) ?? 0
        // The wrapper's code can be non-zero while still carrying usable data
        // (the like-write endpoint answers 80105 for a successful add), so the
        // payload is preferred over the code and the code only fails the call
        // when there is nothing to read.
        guard let data = envelope["data"] as? [String: Any], !data.isEmpty else {
            throw QQMusicWebAPIError.upstream(
                code: code,
                message: (envelope["msg"] as? String) ?? ""
            )
        }
        return data
    }

    private static func decodeLikedSongs(_ response: [String: Any]) throws -> QQMusicLikedSongs {
        let data = try payload(response)
        let directory = data["dirinfo"] as? [String: Any]
        let rawTracks = data["songlist"] as? [[String: Any]] ?? []
        let tracks = rawTracks.compactMap(decodeTrack)
        let total = parseInt(directory?["songnum"]) ?? tracks.count
        let title = (directory?["title"] as? String) ?? "我喜欢"
        return QQMusicLikedSongs(title: title, total: total, tracks: tracks)
    }

    /// Map one upstream song entry onto `QQMusicOnlineTrack`.
    ///
    /// Field names differ from what the helper's library returns, so this is
    /// written against the raw CGI shape: `mid`/`name`/`interval`, singers as a
    /// list, and file sizes keyed by code (`size320`, `sizeflac` lowercase).
    private static func decodeTrack(_ raw: [String: Any]) -> QQMusicOnlineTrack? {
        guard let songMid = (raw["mid"] as? String) ?? (raw["songmid"] as? String),
              !songMid.isEmpty
        else { return nil }

        let singers = raw["singer"] as? [[String: Any]] ?? []
        let artist = singers
            .compactMap { $0["name"] as? String }
            .joined(separator: " / ")

        let album = raw["album"] as? [String: Any]
        let file = raw["file"] as? [String: Any]

        // The album cover follows a stable URL pattern from the album mid, which
        // saves a second request per track just to obtain artwork. Run through
        // the normalizer like every other cover, so a future change to this
        // pattern cannot reintroduce an http:// URL that ATS would refuse.
        let albumMid = album?["mid"] as? String
        let imageURL = Self.normalizedArtworkURL(
            albumMid.map { "https://y.gtimg.cn/music/photo_new/T002R800x800M000\($0).jpg" }
        )

        // `pay` is a nested object in the CGI payload (`pay.pay_play`), not a
        // flat key, so the nested form is checked first and the flat one is
        // kept only as a fallback for the other response shape.
        let pay = raw["pay"] as? [String: Any]
        let payPlay = parseInt(pay?["pay_play"]) ?? parseInt(raw["pay_play"])

        return QQMusicOnlineTrack(
            songId: parseInt(raw["id"]),
            songMid: songMid,
            mediaMid: (raw["media_mid"] as? String) ?? (file?["media_mid"] as? String),
            title: (raw["name"] as? String) ?? (raw["title"] as? String) ?? "未知歌曲",
            artist: artist.isEmpty ? "未知艺人" : artist,
            album: album?["name"] as? String,
            albumMid: albumMid,
            imageURL: imageURL,
            duration: parseInt(raw["interval"]),
            payPlay: payPlay,
            songType: parseInt(raw["type"]),
            size320: parseInt(file?["size_320mp3"]),
            sizeFlac: parseInt(file?["size_flac"]),
            size128: parseInt(file?["size_128mp3"]),
            singerMid: singers.first?["mid"] as? String,
            releaseDate: nil
        )
    }

    /// CGI numbers arrive as either `Int` or `String` depending on the module.
    private static func parseInt(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text)
        default: return nil
        }
    }

    /// Lyrics arrive base64-encoded even in plaintext mode. A payload that does
    /// not decode is treated as absent rather than surfaced as a failure: a
    /// track without lyrics is normal, and the caller shows an empty panel.
    private static func decodeBase64Text(_ value: Any?) -> String? {
        guard let encoded = value as? String, !encoded.isEmpty else { return nil }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        let text = String(data: data, encoding: .utf8)
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// Album covers follow a fixed pattern from the album mid, which is how the
    /// liked-songs path already builds them. Falls back to nil so the view can
    /// use its placeholder.
    private static func albumCoverURL(mid: String?) -> String? {
        guard let mid, !mid.isEmpty else { return nil }
        return "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(mid).jpg"
    }

    /// Force artwork URLs onto HTTPS.
    ///
    /// The upstream hands back `http://y.gtimg.cn/...` and `http://qpic.y.qq.com/...`
    /// and both hosts serve the same image over TLS. The app has no App Transport
    /// Security exception, so an `http://` URL is refused outright and the cover
    /// silently stays blank — which is exactly how playlist covers were broken
    /// while the (already-https) album covers worked.
    private static func normalizedArtworkURL(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("https://") { return value }
        if value.hasPrefix("http://") {
            return "https://" + value.dropFirst("http://".count)
        }
        // Protocol-relative, as the upstream also emits for some CDN hosts.
        if value.hasPrefix("//") { return "https:" + value }
        return value
    }

    /// Exposed so the cover normalisation can be tested directly. Behaviour is
    /// identical to `normalizedArtworkURL`.
    nonisolated static func normalizedArtworkURLForTesting(_ value: String?) -> String? {
        normalizedArtworkURL(value)
    }

    /// The album list reports `pubtime` as a Unix timestamp; the app displays a
    /// plain date string.
    private static func parseTimestamp(_ value: Any?) -> String? {
        guard let seconds = parseInt(value), seconds > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}
