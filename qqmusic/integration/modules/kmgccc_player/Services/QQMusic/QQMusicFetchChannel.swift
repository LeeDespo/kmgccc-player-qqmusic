//
//  QQMusicFetchChannel.swift
//  kmgccc_player
//
//  Which of the two upstream channels a kind of online content is read through.
//
//  The online source has two ways to talk to QQ Music, and they are good at
//  different things:
//
//    * the **web** client (`QQMusicWebAPI`) answers a plain HTTP `musicu.fcg`
//      request in roughly a third of the time the helper takes, because the
//      helper pays for a process and a fresh client per call;
//    * the **helper** (the Python library) speaks the endpoints that have no web
//      equivalent at all, and for the ones that do overlap it returns *more*:
//      the lyric it fetches can carry word-level timing, the album it resolves
//      carries the numeric id, and so on.
//
//  So neither is "the right one" in general, and the choice belongs to whoever
//  is listening — which is why it is a setting rather than a constant. What is
//  not a choice is the *fallback*: whichever channel is preferred, the other is
//  tried when the first fails. That is what keeps a web regression from breaking
//  a page, and it is why this list only contains subjects both channels can
//  serve: the rest are shown in Settings, greyed, so their absence is
//  information rather than a mystery.
//

import Foundation

/// Which channel serves a kind of online content.
nonisolated enum QQMusicFetchChannel: String, CaseIterable, Identifiable, Sendable {
    case web
    case helper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .web: return "网页"
        case .helper: return "Helper"
        }
    }

    /// What choosing it means, for the settings description.
    var detail: String {
        switch self {
        case .web:
            return "直连上游网页接口，快约三倍。"
        case .helper:
            return "走 helper 组件，慢一些，但返回的内容更详细（歌词带逐字时间等）。"
        }
    }
}

/// Which channel answered a subject's most recent request, and whether it had to
/// be the fallback.
///
/// Surfaced in Settings so the contract above is *visible*: preferring a channel
/// looks identical to working until something fails, and "did choosing Helper
/// break the lyrics?" should be answerable from the page, not from a log.
nonisolated struct QQMusicChannelOutcome: Equatable, Sendable {
    /// The channel whose answer was used.
    let channel: QQMusicFetchChannel
    /// True when the preferred channel failed first and the other one answered.
    let didFallBack: Bool

    /// "明白了" style line for the settings row.
    var summary: String {
        didFallBack
            ? "最近一次由 \(channel.displayName) 兜底回答。"
            : "最近一次由 \(channel.displayName) 回答。"
    }
}

/// A kind of online content whose channel the user can choose.
nonisolated enum QQMusicChannelSubject: String, CaseIterable, Identifiable, Sendable {
    /// 我喜欢 / 收藏专辑 / 收藏歌单.
    case accountLists
    /// A playlist's or a ranking's tracks.
    case trackLists
    /// The lyric fetched when a track is downloaded.
    case lyrics
    /// The song's own 简介, shown on the online home's featured card and behind
    /// 查看歌曲描述.
    case songIntro
    /// 关注的歌手.
    case followedArtists

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accountLists: return "账号列表"
        case .trackLists: return "曲目列表"
        case .lyrics: return "歌词"
        case .songIntro: return "歌曲描述"
        case .followedArtists: return "关注的歌手"
        }
    }

    var scope: String {
        switch self {
        case .accountLists: return "我喜欢、收藏专辑、收藏歌单"
        case .trackLists: return "歌单曲目、排行榜曲目"
        case .lyrics: return "下载歌曲时取回的歌词"
        case .songIntro: return "精选大卡片的简介、「查看歌曲描述」"
        case .followedArtists: return "关注的歌手列表"
        }
    }

    /// What the source ships with, and the reason for each.
    ///
    /// Lists default to the web client: they are fetched on every visit, the two
    /// channels return the same rows, and the web path is several times faster.
    /// Lyrics default to the helper: it is fetched once per download, so its
    /// speed hardly matters, while the extra detail it carries is the whole
    /// point — word-level timing, which the web route's line-level payload does
    /// not have.
    ///
    /// The song's 简介 defaults to the web client for the same reason the lists
    /// do: both channels read the same `get_song_detail` module, so they return
    /// the *same* prose — and this one is fetched while browsing (on every 换一首
    /// on the featured card), which is exactly when the helper's extra second is
    /// felt. Choosing the helper is one click away for anyone who wants the whole
    /// catalogue read from one side.
    var defaultChannel: QQMusicFetchChannel {
        switch self {
        case .accountLists, .trackLists, .songIntro, .followedArtists: return .web
        case .lyrics: return .helper
        }
    }

    /// The fact that decides which channel is the better *default* for this
    /// subject, stated without repeating the fallback rule the row above it
    /// already spells out.
    var channelNote: String {
        switch self {
        case .accountLists, .trackLists, .followedArtists:
            return "两边返回的结果相同。"
        case .lyrics:
            return "Helper 的歌词更完整，可含逐字时间。"
        case .songIntro:
            return "两边读的是同一个上游模块，返回同一份简介。"
        }
    }
}

/// Content only one channel can serve, listed so the settings page can say so.
///
/// These are not failures to fix — the endpoints simply exist on one side only.
/// Shown rather than omitted: a reader who wonders why 专辑曲目 has no choice
/// finds the answer where the choice would be.
nonisolated enum QQMusicLockedContent: String, CaseIterable, Identifiable, Sendable {
    case albumTracks
    case artistDetail
    case discovery
    case franchiseWrite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .albumTracks: return "专辑曲目"
        case .artistDetail: return "歌手资料"
        case .discovery: return "电台 / 新歌 / 搜索 / 推荐 / 排行榜分组"
        case .franchiseWrite: return "收藏与取消收藏"
        }
    }

    var reason: String {
        switch self {
        case .albumTracks:
            return "只有 helper 有这条路由，且它按数字专辑 id 取整张，网页没有对应接口。"
        case .artistDetail:
            return "歌手的歌曲、专辑与简介只有 helper 能取。"
        case .discovery:
            return "这些端点的网页版本要么不存在，要么不接受分页参数（排行榜分组），只能用 helper。"
        case .franchiseWrite:
            return "这是整个在线音源里唯一的写操作，helper 用播放列表成员接口完成，网页那条路不接受写。"
        }
    }
}
