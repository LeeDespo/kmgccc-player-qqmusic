//
//  QQMusicNavigationTests.swift
//  kmgccc_playerTests
//
//  The online page stack. These cover the behaviour the toolbar depends on
//  (can-go-back / can-go-forward) and the two decisions that are easy to get
//  wrong and invisible when wrong:
//    - `replaceTop` must not grow the stack, or "back" would step through every
//      filter value the user tried instead of leaving the page;
//    - `push` must clear the forward stack, or forward would jump into a branch
//      the user has already abandoned.
//

import XCTest
@testable import kmgccc_player

@MainActor
final class QQMusicNavigationTests: XCTestCase {

    func testStartsOnLandingPageWithNoHistory() {
        let navigation = QQMusicNavigation()

        XCTAssertEqual(navigation.displayed, .home)
        XCTAssertNil(navigation.current)
        XCTAssertFalse(navigation.canGoBack)
        XCTAssertFalse(navigation.canGoForward)
    }

    func testPushThenBackReturnsToLandingPage() {
        let navigation = QQMusicNavigation()

        navigation.push(.likedSongs)
        XCTAssertEqual(navigation.displayed, .likedSongs)
        XCTAssertTrue(navigation.canGoBack)

        navigation.goBack()
        XCTAssertEqual(navigation.displayed, .home)
        XCTAssertFalse(navigation.canGoBack)
        XCTAssertTrue(navigation.canGoForward)
    }

    func testForwardReplaysAPoppedPage() {
        let navigation = QQMusicNavigation()
        navigation.push(.userPlaylists)
        navigation.push(.likedAlbums)

        navigation.goBack()
        XCTAssertEqual(navigation.displayed, .userPlaylists)

        navigation.goForward()
        XCTAssertEqual(navigation.displayed, .likedAlbums)
        XCTAssertFalse(navigation.canGoForward)
    }

    /// Drilling somewhere new abandons the forward branch, as a browser does.
    func testPushClearsForwardStack() {
        let navigation = QQMusicNavigation()
        navigation.push(.likedSongs)
        navigation.push(.userPlaylists)
        navigation.goBack()
        XCTAssertTrue(navigation.canGoForward)

        navigation.push(.toplists)

        XCTAssertFalse(navigation.canGoForward)
        XCTAssertEqual(navigation.displayed, .toplists)
    }

    /// A filter change stays one page deep, so back leaves the page rather than
    /// stepping through each value the user tried.
    func testReplaceTopDoesNotGrowTheStack() {
        let navigation = QQMusicNavigation()
        navigation.push(.search(.songs))

        navigation.replaceTop(with: .search(.artists))
        navigation.replaceTop(with: .search(.playlists))

        XCTAssertEqual(navigation.displayed, .search(.playlists))
        navigation.goBack()
        XCTAssertEqual(navigation.displayed, .home, "back must leave the search page")
    }

    func testReplaceTopOnEmptyStackPushes() {
        let navigation = QQMusicNavigation()

        navigation.replaceTop(with: .newSongs(.japan))

        XCTAssertEqual(navigation.displayed, .newSongs(.japan))
        XCTAssertTrue(navigation.canGoBack)
    }

    func testPopToRootClearsBothStacks() {
        let navigation = QQMusicNavigation()
        navigation.push(.likedSongs)
        navigation.push(.userPlaylists)
        navigation.goBack()

        navigation.popToRoot()

        XCTAssertEqual(navigation.displayed, .home)
        XCTAssertFalse(navigation.canGoBack)
        XCTAssertFalse(navigation.canGoForward)
    }

    func testPushingTheCurrentPageIsIgnored() {
        let navigation = QQMusicNavigation()
        navigation.push(.likedSongs)

        navigation.push(.likedSongs)

        XCTAssertEqual(navigation.stack.count, 1)
    }

    /// Entity pages carry their title so a header can be drawn before the
    /// network answers.
    func testEntityPageTitleComesFromThePageValue() {
        let page = QQMusicPage.playlist(id: 42, title: "深夜爵士")
        XCTAssertEqual(page.title, "深夜爵士")
        XCTAssertEqual(page.loadKey, "playlist:42")
    }

    /// Only finite lists offer batch download/select-all, so this predicate is
    /// what stops a "全选" appearing on an endless feed.
    func testEndlessListsAreNotFinite() {
        XCTAssertFalse(QQMusicPage.recommend.isFiniteList)
        XCTAssertFalse(QQMusicPage.radio.isFiniteList)
        XCTAssertFalse(QQMusicPage.artist(QQMusicArtistRef(singerMid: "x", name: "X")).isFiniteList)
        XCTAssertTrue(QQMusicPage.likedSongs.isFiniteList)
        XCTAssertTrue(QQMusicPage.playlist(id: 1, title: "P").isFiniteList)
    }

    func testDisplayKeyDistinguishesPages() {
        XCTAssertNotEqual(
            QQMusicPage.search(.songs).loadKey,
            QQMusicPage.search(.artists).loadKey,
            "the two searches are different pages and must reload"
        )
        XCTAssertNotEqual(
            QQMusicPage.newSongs(.japan).loadKey,
            QQMusicPage.newSongs(.korea).loadKey
        )
    }
}
