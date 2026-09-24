//
//  QQMusicQualityPreference.swift
//  kmgccc_player
//
//  Download quality ceiling for online QQ Music tracks.
//
//  The upstream grants the best tier the signed-in account is entitled to, so
//  this expresses intent rather than a guarantee: `resolve_song_url` walks the
//  ladder from the requested tier downward and returns whatever is actually
//  authorized. An anonymous session is only ever granted the standard tier.
//

import Foundation

nonisolated enum QQMusicQualityPreference: String, CaseIterable, Sendable {
    /// Let the helper pick: try lossless first, fall back as needed.
    case automatic
    case lossless
    case high
    case standard

    var displayName: String {
        switch self {
        case .automatic: return "自动（优先无损）"
        case .lossless: return "无损 FLAC"
        case .high: return "高品质 320K"
        case .standard: return "标准 128K"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "从无损开始逐级尝试，取账号可用的最高品质。"
        case .lossless:
            return "只接受无损，不可用时逐级降低。需要会员。"
        case .high:
            return "最高 320K MP3，体积与音质较均衡。"
        case .standard:
            return "最高 128K MP3，体积最小。"
        }
    }

    /// Quality label understood by the helper, or nil to use its own default.
    var ladderEntry: String? {
        switch self {
        case .automatic: return nil
        case .lossless: return "flac"
        case .high: return "320"
        case .standard: return "128"
        }
    }
}
