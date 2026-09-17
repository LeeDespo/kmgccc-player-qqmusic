//
//  QQMusicWindowManager.swift
//  kmgccc_player
//
//  Owns the standalone QQ Music window.
//
//  The online source is additive to the app, so it deliberately does not add a
//  page to the app's own settings scene: an upstream change must never be able
//  to affect the existing settings surface. This window reuses the app's visual
//  language (theme store, glass buttons, settings row styles) without touching
//  those views.
//

import AppKit
import SwiftUI

@MainActor
final class QQMusicWindowManager: NSObject, NSWindowDelegate {

    static let shared = QQMusicWindowManager()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    var isPresented: Bool { window != nil }

    /// Coordinator to hand the page, so it can report and clear the cache.
    /// Assigned by the sidebar before `present()`.
    weak var coordinator: QQMusicOnlineCoordinator?

    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = QQMusicSettingsView(coordinator: coordinator)
            .environment(AppSettings.shared)
            .environmentObject(ThemeStore.shared)
            .tint(ThemeStore.shared.accentColor)
            .accentColor(ThemeStore.shared.accentColor)

        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "QQ 音乐"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 640))
        window.minSize = NSSize(width: 540, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        applyCurrentAppearance(to: window)

        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.close()
        window = nil
    }

    private func applyCurrentAppearance(to window: NSWindow) {
        let settings = AppSettings.shared
        if settings.followSystemAppearance {
            window.appearance = nil
        } else {
            window.appearance = NSAppearance(
                named: settings.manualAppearance == .dark ? .darkAqua : .aqua
            )
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
