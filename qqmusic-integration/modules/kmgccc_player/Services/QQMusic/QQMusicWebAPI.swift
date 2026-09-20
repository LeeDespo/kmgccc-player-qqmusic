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
        // saves a second request per track just to obtain artwork.
        let albumMid = album?["mid"] as? String
        let imageURL = albumMid.map {
            "https://y.gtimg.cn/music/photo_new/T002R800x800M000\($0).jpg"
        }

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
}
