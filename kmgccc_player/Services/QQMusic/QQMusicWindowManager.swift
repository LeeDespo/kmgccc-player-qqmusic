//
//  QQMusicWindowManager.swift
//  kmgccc_player
//
//  Presentation state for the QQ Music window.
//
//  The app presents its own settings as a SwiftUI `.sheet` — borderless, no
//  window controls, close button drawn inside the content. Presenting this
//  feature as a titled NSWindow made it look like a separate application, so
//  this manager only tracks state and lets the sidebar host the sheet through
//  the same mechanism the gear button uses.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class QQMusicWindowManager {

    static let shared = QQMusicWindowManager()

    /// Drives the sheet presented from `SidebarView`.
    var isPresented = false

    /// Coordinator handed to the page so it can report and clear the cache.
    weak var coordinator: QQMusicOnlineCoordinator?

    private init() {}

    func present() {
        guard !isPresented else { return }
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }
}
