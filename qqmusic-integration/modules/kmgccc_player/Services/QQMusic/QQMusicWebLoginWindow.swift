//
//  QQMusicWebLoginWindow.swift
//  kmgccc_player
//
//  Logs in to QQ Music by loading the official login page in a web view and
//  capturing the resulting cookies.
//
//  Why this exists alongside the QR-code API flow: the upstream library
//  authenticates requests from exactly two cookie values — `uin` and
//  `qm_keyst` (it derives `g_tk = hash33(musickey)` internally). Those are the
//  same cookies the login page sets, and `qm_keyst` doubles as the playback
//  ticket that VIP url resolution needs. So a cookie captured here is
//  interchangeable with a credential produced by the QR flow, while letting the
//  user complete whatever verification the login page itself demands.
//

import AppKit
import SwiftUI
import WebKit

/// Cookies the upstream uses for authentication, in preference order.
private let uinCookieNames = ["uin", "qqmusic_uin", "wxuin", "p_uin"]
private let musicKeyCookieNames = [
    "qm_keyst", "qqmusic_key", "music_key", "p_skey", "skey", "wxskey",
]

@MainActor
final class QQMusicWebLoginWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {

    static let shared = QQMusicWebLoginWindow()

    /// Called with the captured cookies on success.
    var onCookies: (([String: String]) -> Void)?
    var onCancel: (() -> Void)?

    private var window: NSWindow?
    private var webView: WKWebView?
    private var didFinish = false

    private override init() {
        super.init()
    }

    /// The QQ Music login page. It redirects through PTLogin and lands back on
    /// a page whose cookies are readable from our own web view.
    private static let loginURL = URL(string: "https://y.qq.com/#login")!

    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        didFinish = false

        let configuration = WKWebViewConfiguration()
        // A dedicated, non-persistent store keeps the login session from
        // leaking into the app's other web views (the lyrics surface).
        configuration.websiteDataStore = .nonPersistent()
        // Present as a normal desktop browser; the login page rejects some
        // embedded user agents.
        configuration.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15"

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 660),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "登录 QQ 音乐"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.level = .floating

        let container = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)

        let statusLabel = NSTextField(labelWithString: "登录后会自动完成，无需手动关闭窗口")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        window.contentView = container
        self.window = window
        self.webView = webView

        webView.load(URLRequest(url: Self.loginURL))
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.close()
        window = nil
        webView = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await harvestCookies(from: webView, reason: "navigation") }
    }

    private func harvestCookies(from webView: WKWebView, reason: String) async {
        guard !didFinish else { return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        var map: [String: String] = [:]
        for cookie in cookies where cookie.domain.contains("qq.com") {
            map[cookie.name] = cookie.value
        }

        guard Self.pick(map, uinCookieNames) != nil,
              Self.pick(map, musicKeyCookieNames) != nil
        else {
            // Still mid-flow (e.g. the login page has not completed yet); the
            // next navigation will try again.
            return
        }

        didFinish = true
        Log.info("[QQMusicWebLogin] captured cookies reason=\(reason) count=\(map.count)", category: .import)
        onCookies?(map)
        dismiss()
    }

    private static func pick(_ cookies: [String: String], _ names: [String]) -> String? {
        for name in names {
            if let value = cookies[name], !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        let wasFinished = didFinish
        window = nil
        webView = nil
        if !wasFinished {
            onCancel?()
        }
    }
}
