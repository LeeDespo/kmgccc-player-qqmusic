//
//  QQMusicBrowseEnvironmentTests.swift
//  kmgccc_playerTests
//
//  Guards the online browse surface's environment.
//
//  The surface reuses library components, and some of them read the environment
//  *non-optionally* — the shared glass card
//  (`HomeUnifiedGlassCardModifier`) declares `@Environment(AppSettings.self)`.
//  A card drawn without it traps with "No Observable object of type AppSettings
//  found", which takes down the entire surface rather than degrading one view.
//
//  Since a missing environment object cannot be checked by reading it (reading
//  is what traps), the check is a real layout pass in an `NSHostingView`: if a
//  required value is missing, the trap happens here, in a test, instead of on
//  the user's first click. The environment is applied through the same
//  `qqMusicBrowseEnvironment` modifier production uses, so removing a value
//  from that composition fails this test.
//

import AppKit
import SwiftUI
import XCTest
@testable import kmgccc_player

@MainActor
final class QQMusicBrowseEnvironmentTests: XCTestCase {

    /// A card is the component that pulls in the glass modifier, so it is the
    /// one that proves `AppSettings` is reachable.
    func testCardRendersUnderTheBrowseEnvironment() throws {
        let (coordinator, navigation, selection) = makeDependencies()

        let hosted = NSHostingView(rootView: AnyView(
            QQMusicCard(
                title: "深夜爵士",
                subtitle: "42 首",
                size: 146,
                titleColor: .primary,
                subtitleColor: .secondary,
                onOpen: {}
            ) {
                Color.gray
            }
            .qqMusicBrowseEnvironment(
                coordinator: coordinator,
                navigation: navigation,
                selection: selection
            )
            .frame(width: 200, height: 200)
        ))
        hosted.frame = CGRect(x: 0, y: 0, width: 200, height: 200)

        // Forces a full body evaluation and layout pass.
        hosted.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosted.fittingSize.width, 0)
    }

    /// A track row: the other component with a required environment value
    /// (the coordinator, which it reads non-optionally for download state).
    func testTrackRowRendersUnderTheBrowseEnvironment() throws {
        let (coordinator, navigation, selection) = makeDependencies()

        let track = QQMusicOnlineTrack(
            songMid: "001abc",
            title: "Test",
            artist: "Someone",
            album: "Album",
            duration: 200
        )

        let hosted = NSHostingView(rootView: AnyView(
            QQMusicTrackRow(track: track, onPlay: {})
                .qqMusicBrowseEnvironment(
                    coordinator: coordinator,
                    navigation: navigation,
                    selection: selection
                )
                .frame(width: 600, height: 60)
        ))
        hosted.frame = CGRect(x: 0, y: 0, width: 600, height: 60)

        hosted.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosted.fittingSize.width, 0)
    }

    /// The detail header, which the health check for the entity pages rests on.
    func testDetailHeaderRendersUnderTheBrowseEnvironment() throws {
        let (coordinator, navigation, selection) = makeDependencies()

        let hosted = NSHostingView(rootView: AnyView(
            QQMusicDetailHeader(
                title: "我喜欢的音乐",
                subtitle: "QQ 音乐收藏",
                metadata: "471 首歌曲 · 31 小时 12 分",
                artworkURL: nil,
                placeholderSystemImage: "heart.fill",
                onPlay: {},
                canPlay: true
            ) {
                EmptyView()
            }
            .qqMusicBrowseEnvironment(
                coordinator: coordinator,
                navigation: navigation,
                selection: selection
            )
            .frame(width: 900, height: 260)
        ))
        hosted.frame = CGRect(x: 0, y: 0, width: 900, height: 260)

        hosted.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosted.fittingSize.width, 0)
    }

    private func makeDependencies() -> (
        QQMusicOnlineCoordinator,
        QQMusicNavigation,
        QQMusicSelectionModel
    ) {
        let coordinator = QQMusicOnlineCoordinator()
        return (coordinator, coordinator.navigation, QQMusicSelectionModel())
    }

    // MARK: - Row interaction

    /// The entity items of a row's 更多 menu appear only when we hold a handle
    /// for the page they open.
    ///
    /// 查看艺人 needs the singer's mid and 查看专辑 needs the album's numeric id —
    /// the mid only yields a cover. An item offered without one would open an
    /// empty page, so the row's menu asks these first, the way the library's menu
    /// hides navigation it cannot honour.
    func testEntityItemsNeedSomethingToOpen() {
        let bare = QQMusicOnlineTrack(songMid: "001", title: "歌", artist: "谁")
        XCTAssertFalse(bare.hasArtistPage, "no singer mid, no artist page")
        XCTAssertFalse(bare.hasAlbumPage, "no album id, no album page")

        var withArtist = bare
        withArtist.singerMid = "singer-mid"
        XCTAssertTrue(withArtist.hasArtistPage)

        var withAlbum = bare
        withAlbum.albumId = 0
        XCTAssertFalse(withAlbum.hasAlbumPage, "an id of 0 is not an album")
        withAlbum.albumId = 1234
        XCTAssertTrue(withAlbum.hasAlbumPage)
    }

    /// A duet's 查看艺人 has to be a question, not a guess.
    ///
    /// The helper reports every singer now; `singerMid` is only the first, so
    /// using it silently opened one member of the duet. The row turns more than
    /// one into a submenu, and this is the data behind it — including the
    /// fallback that keeps an un-updated helper working.
    func testEverySingerIsOfferedForTheArtistPage() {
        var track = QQMusicOnlineTrack(songMid: "001", title: "合唱", artist: "甲, 乙")
        track.singerMid = "mid-甲"

        // No list (an older helper): the single mid it does report is the answer.
        XCTAssertEqual(track.openableArtists.map(\.mid), ["mid-甲"])
        XCTAssertEqual(track.openableArtists.map(\.name), ["甲, 乙"])

        track.singers = [
            QQMusicSinger(mid: "mid-甲", name: "甲"),
            QQMusicSinger(mid: "mid-乙", name: "乙"),
        ]
        XCTAssertEqual(track.openableArtists.map(\.mid), ["mid-甲", "mid-乙"])
        XCTAssertEqual(track.openableArtists.map(\.name), ["甲", "乙"])

        // A singer with no mid cannot be opened, so it is not offered; a singer
        // with a mid but no name falls back to the row's own artist text.
        track.singers = [
            QQMusicSinger(mid: nil, name: "无名氏"),
            QQMusicSinger(mid: "mid-丙", name: nil),
        ]
        XCTAssertEqual(track.openableArtists.map(\.mid), ["mid-丙"])
        XCTAssertEqual(track.openableArtists.map(\.name), ["甲, 乙"])

        // Nothing to open at all: the item is absent rather than dead.
        track.singers = []
        track.singerMid = nil
        XCTAssertFalse(track.hasArtistPage)
    }

    /// The two channels must describe a track the same way.
    ///
    /// The web decoder joined singers with " / " and kept only the first mid
    /// while the helper joined with ", " and reported them all — so the same duet
    /// What the helper's track row must carry, and what a row does with it.
    ///
    /// The helper is the only source of these rows, so this pins the wire shape
    /// it answers with: every credited singer (a duet's 查看艺人 used to pick one
    /// silently) and the album's *numeric* id (查看专辑 needs it; the mid only
    /// gets a cover).
    func testHelperTrackRowCarriesEverySingerAndTheAlbumId() throws {
        let reply = """
        {
          "id": "1", "ok": true,
          "tracks": [{
            "songMid": "song-1",
            "songId": 4321,
            "title": "合唱",
            "artist": "甲, 乙",
            "album": "专辑名",
            "albumMid": "album-mid",
            "albumId": 4321,
            "duration": 215,
            "payPlay": 0,
            "imageURL": "https://y.gtimg.cn/a.jpg",
            "singerMid": "mid-a",
            "singers": [
              {"mid": "mid-a", "name": "甲"},
              {"mid": "mid-b", "name": "乙"}
            ]
          }]
        }
        """
        let envelope = try JSONDecoder().decode(HelperTrackEnvelope.self, from: Data(reply.utf8))
        let track = try XCTUnwrap(envelope.tracks?.first)
        XCTAssertEqual(track.artist, "甲, 乙")
        XCTAssertEqual(track.openableArtists.map(\.mid), ["mid-a", "mid-b"])
        XCTAssertEqual(track.openableArtists.map(\.name), ["甲", "乙"])
        XCTAssertEqual(track.albumId, 4321, "查看专辑 needs the numeric id")
        XCTAssertTrue(track.hasAlbumPage)

        // No album id on the row: the item is absent rather than dead.
        let withoutAlbum = try JSONDecoder().decode(
            QQMusicOnlineTrack.self,
            from: Data("""
            {"songMid": "song-2", "title": "歌", "artist": "甲",
             "singers": [{"mid": "mid-a", "name": "甲"}]}
            """.utf8)
        )
        XCTAssertFalse(withoutAlbum.hasAlbumPage)
        XCTAssertEqual(withoutAlbum.openableArtists.map(\.mid), ["mid-a"])
    }

    /// The envelope the helper replies with, as far as these tests need it.
    private struct HelperTrackEnvelope: Decodable {
        let ok: Bool
        let tracks: [QQMusicOnlineTrack]?
    }

    /// 查看详情 says what the catalogue and the library actually know.
    ///
    /// The library's own detail sheet resolves a *description*; an online track
    /// has none, so the facts take the body. What matters for the test is that
    /// each fact is stated and that absent ones are left out rather than shown
    /// blank.
    func testTrackDetailStatesTheOnlineFacts() {
        var track = QQMusicOnlineTrack(
            songMid: "0039MnYb0qxYhV",
            title: "夜曲",
            artist: "周杰伦",
            album: "十一月的萧邦",
            duration: 227
        )
        track.payPlay = 0

        let playable = QQMusicTrackDetail.content(for: track, libraryState: .userDownload)
        XCTAssertEqual(playable.title, "歌曲详情")
        XCTAssertEqual(playable.subtitle, "夜曲 - 周杰伦")
        XCTAssertTrue(playable.text.contains("专辑：十一月的萧邦"))
        XCTAssertTrue(playable.text.contains("时长：3:47"))
        XCTAssertTrue(playable.text.contains("可直接播放"))
        XCTAssertTrue(playable.text.contains("已在曲库（手动下载）"))
        XCTAssertTrue(playable.text.contains("0039MnYb0qxYhV"))

        // A gated track is described as a likelihood, not a promise: `payPlay` is
        // a heuristic and the authoritative answer only arrives on playback.
        track.payPlay = 1
        XCTAssertTrue(
            QQMusicTrackDetail.content(for: track, libraryState: .notDownloaded)
                .text.contains("可能需要会员")
        )

        // Nothing to state: no album, no length, nothing in the library.
        let bare = QQMusicOnlineTrack(songMid: "001", title: "歌", artist: "谁")
        let text = QQMusicTrackDetail.content(for: bare, libraryState: .notDownloaded).text
        XCTAssertFalse(text.contains("专辑："))
        XCTAssertFalse(text.contains("时长："))
        XCTAssertTrue(text.contains("未下载"))
    }

    // MARK: - Selection

    /// A run of selected rows merges; the ends of the run keep their rounding.
    ///
    /// This is what makes the selection read as one block instead of a stack of
    /// capsules, and it is the row's *neighbours* that decide it — so the list has
    /// to answer, and it has to answer from the order actually on screen.
    func testSelectionContinuityMergesARunOfRows() {
        let selection = QQMusicSelectionModel()
        selection.begin()
        let mids = ["a", "b", "c", "d"]
        selection.toggle("b")
        selection.toggle("c")

        // The pair merges where they touch — 'b' squares its bottom, 'c' its top
        // — and keeps its rounding at the outer ends.
        XCTAssertEqual(
            selection.continuity(at: 1, in: mids),
            TrackRowSelectionContinuity(connectsToPrevious: false, connectsToNext: true)
        )
        XCTAssertEqual(
            selection.continuity(at: 2, in: mids),
            TrackRowSelectionContinuity(connectsToPrevious: true, connectsToNext: false)
        )

        // A lone selected row has nothing to merge with, which is the case that
        // matters for a one-row selection.
        selection.cancel()
        selection.begin()
        selection.toggle("a")
        XCTAssertEqual(selection.continuity(at: 0, in: mids), .isolated)

        // Out of range is not a row, so it must not claim a merge either.
        XCTAssertEqual(selection.continuity(at: 9, in: mids), .isolated)
    }

    // MARK: - The batch-download control

    /// Entering selection mode must widen the control.
    ///
    /// This is the property the toolbar depends on: the item sizes itself from
    /// this view, so if the four actions did not make it wider they would be
    /// clipped — and the failure would be invisible until someone clicked it.
    func testDownloadControlGrowsWhenSelectionBegins() async throws {
        let (coordinator, navigation, selection) = makeDependencies()

        let host = NSHostingView(rootView: AnyView(
            QQMusicDownloadControl()
                .qqMusicBrowseEnvironment(
                    coordinator: coordinator,
                    navigation: navigation,
                    selection: selection
                )
        ))
        host.sizingOptions = [.intrinsicContentSize]

        /// Let SwiftUI render and the shape animation settle; the width springs
        /// over ~0.34s, so measuring immediately would always read the old value.
        func settledWidth() async -> CGFloat {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(700))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }

        let idleWidth = await settledWidth()
        XCTAssertGreaterThan(idleWidth, 0, "the control must have a size to be laid out in a toolbar")

        selection.begin()
        let selectingWidth = await settledWidth()

        XCTAssertGreaterThan(
            selectingWidth,
            idleWidth,
            "全选/反选/取消/下载所选 needs more room than one glyph"
        )

        // And back again, so the item does not stay wide after cancelling.
        selection.cancel()
        let cancelledWidth = await settledWidth()
        XCTAssertEqual(
            cancelledWidth,
            idleWidth,
            accuracy: 1,
            "cancelling must return the control to a single glyph"
        )
    }

    /// The toolbar item exists only when there is a session to act on, and hosts
    /// a view when there is.
    func testFactoryBuildsTheControlOnlyWithASession() throws {
        let factory = AppKitMainToolbarItemFactory()
        let actions = makeActions()

        func context(coordinator: QQMusicOnlineCoordinator?) -> AppKitMainToolbarItemFactory.Context {
            AppKitMainToolbarItemFactory.Context(
                isSidebarVisible: true,
                isLyricsVisible: false,
                isPlaybackHistoryMode: false,
                isMultiselectMode: false,
                generation: 0,
                splitView: nil,
                qqMusicCoordinator: coordinator
            )
        }

        let withoutSession = factory.makeItem(
            identifier: AppKitMainToolbarController.Identifier.qqDownloadControl,
            context: context(coordinator: nil),
            actions: actions,
            sortMenu: NSMenu(),
            searchBridge: AppKitMainToolbarSearchBridge()
        )
        XCTAssertNil(withoutSession, "no session means no list to download")

        let coordinator = QQMusicOnlineCoordinator()
        let item = try XCTUnwrap(factory.makeItem(
            identifier: AppKitMainToolbarController.Identifier.qqDownloadControl,
            context: context(coordinator: coordinator),
            actions: actions,
            sortMenu: NSMenu(),
            searchBridge: AppKitMainToolbarSearchBridge()
        ))

        let view = try XCTUnwrap(item.view, "the control is a hosted view, not a button")
        XCTAssertGreaterThan(view.fittingSize.width, 0)
    }

    /// The refresh item is a plain toolbar button, like the ones beside it.
    ///
    /// The material is the point. An item carrying an `NSImage` and no view is
    /// drawn by AppKit in the toolbar's own style; handing it a hosted SwiftUI
    /// control instead is what produced the white halo the batch-download button
    /// had. This pins the cheap shape of the refresh button.
    func testReloadItemIsAnImageBackedToolbarButton() throws {
        let factory = AppKitMainToolbarItemFactory()
        let item = try XCTUnwrap(factory.makeItem(
            identifier: AppKitMainToolbarController.Identifier.qqReloadControl,
            context: AppKitMainToolbarItemFactory.Context(
                isSidebarVisible: true,
                isLyricsVisible: false,
                isPlaybackHistoryMode: false,
                isMultiselectMode: false,
                generation: 0,
                splitView: nil,
                qqMusicCoordinator: QQMusicOnlineCoordinator()
            ),
            actions: makeActions(),
            sortMenu: NSMenu(),
            searchBridge: AppKitMainToolbarSearchBridge()
        ))

        XCTAssertNil(item.view, "an image-backed item is drawn by AppKit, which is the point")
        XCTAssertNotNil(item.image, "icon-only, so the image is the whole button")
        XCTAssertEqual(item.action, #selector(NSObject.description))
    }

    // MARK: - Reload

    /// Pressing refresh has to be a distinct event every time.
    ///
    /// The pages re-fetch by watching this value, so a flag would make the second
    /// press a no-op — and the toolbar gives no other feedback, so the button
    /// would look broken.
    func testEachReloadRequestIsDistinct() {
        let coordinator = QQMusicOnlineCoordinator()
        let first = coordinator.reloadToken
        coordinator.requestReload()
        let second = coordinator.reloadToken
        coordinator.requestReload()

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(second, coordinator.reloadToken)
    }

    /// Whether the batch control applies to a page is a property of the page.
    ///
    /// This is what the toolbar control is gated on, and the reason it has to
    /// ignore whether rows have arrived: gating on `canSelectTracks` dimmed the
    /// button while each page's first request was in flight and brightened it
    /// when the data landed, so it appeared to disappear and reappear on every
    /// navigation.
    func testBatchDownloadAppliesToTrackListsOnly() {
        let coordinator = QQMusicOnlineCoordinator()

        for page in [
            QQMusicPage.likedSongs,
            .newSongs(.latest),
            .playlist(id: 1, title: "歌单"),
            .album(id: 2, title: "专辑"),
            .toplist(id: 3, title: "排行榜")
        ] {
            XCTAssertTrue(coordinator.offersBatchDownload(page), "\(page) is a track list")
        }

        for page in [
            QQMusicPage.home,
            .userPlaylists,
            .likedAlbums,
            .toplists,
            .radio,
            .recommend,
            .search(.songs),
            .radioStation(id: 4, title: "电台"),
            .artist(QQMusicArtistRef(singerMid: "mid", name: "歌手"))
        ] {
            XCTAssertFalse(coordinator.offersBatchDownload(page), "\(page) has no list to select")
        }
    }

    /// The two gates answer different questions, and the stricter one still
    /// refuses an empty list.
    ///
    /// `canSelectTracks` is what the router uses to drop a selection stranded by
    /// a page change, so it has to keep requiring rows; only the toolbar's own
    /// availability check may ignore them.
    func testSelectionStillRequiresRows() {
        let coordinator = QQMusicOnlineCoordinator()
        let page = QQMusicPage.playlist(id: 7, title: "空歌单")

        XCTAssertTrue(coordinator.offersBatchDownload(page))
        XCTAssertTrue(coordinator.tracks(for: page).isEmpty)
        XCTAssertFalse(coordinator.canSelectTracks(for: page), "nothing to select without rows")
    }

    /// The song's 简介, as `查看歌曲描述` and the featured card read it.
    ///
    /// The prose of a song is the helper's `detail.description`, and **an absent
    /// description is an empty string, not a failure**: most songs have none, and
    /// treating that as "the read failed" would send every one of them round the
    /// fallback path again.
    func testSongDescriptionComesFromTheDetailPayload() throws {
        let withProse = """
        {"id": "1", "ok": true, "detail": {"songMid": "song-1",
         "description": "第一段\\n第二段", "source": "qqmusic"}}
        """
        let envelope = try JSONDecoder().decode(HelperDetailEnvelope.self, from: Data(withProse.utf8))
        XCTAssertEqual(envelope.detail?.description, "第一段\n第二段")

        // A song the catalogue has no prose for: the field is simply absent.
        let withoutProse = """
        {"id": "2", "ok": true, "detail": {"songMid": "song-2", "source": "qqmusic"}}
        """
        let empty = try JSONDecoder().decode(HelperDetailEnvelope.self, from: Data(withoutProse.utf8))
        XCTAssertNil(empty.detail?.description)
    }

    /// The envelope a textual read replies with, as far as these tests need it.
    private struct HelperDetailEnvelope: Decodable {
        let ok: Bool
        let detail: QQMusicMetadataDetail?
    }

    private func makeActions() -> AppKitMainToolbarItemFactory.Actions {
        .init(
            target: NSObject(),
            sidebarToggle: #selector(NSObject.description),
            homeNavigation: #selector(NSObject.description),
            pillGroup: #selector(NSObject.description),
            homePillGroup: #selector(NSObject.description),
            qqReload: #selector(NSObject.description),
            lyricsToggle: #selector(NSObject.description)
        )
    }
}
