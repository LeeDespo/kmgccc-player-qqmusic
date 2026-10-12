//
//  PreferenceStatsExtensions.swift
//  myPlayer2
//
//  Smart Shuffle - Preference Stats Extensions
//  Convenience extensions for accessing and modifying preference stats.
//

import SwiftUI


// MARK: - App Lifecycle Integration

/// Handles saving preference stats on app lifecycle events.
@MainActor
final class PreferenceStatsLifecycleHandler {
    static let shared = PreferenceStatsLifecycleHandler()

    private var autosaveTimer: Timer?
    private weak var statsService: PreferenceStatsService?
    private var trackProvider: ((UUID) -> Track?)?

    private init() {
        setupNotifications()
    }

    func configure(
        statsService: PreferenceStatsService,
        trackProvider: @escaping (UUID) -> Track?
    ) {
        self.statsService = statsService
        self.trackProvider = trackProvider
    }

    func releaseLibrarySession() {
        statsService = nil
        trackProvider = nil
    }

    private func setupNotifications() {
        // Save on app resign active (user switches away).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(savePendingStats),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        // Save on app termination.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(savePendingStats),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        // Periodic save every 5 minutes.
        let timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.savePendingStatsNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autosaveTimer = timer
    }

    @objc private func savePendingStats() {
        savePendingStatsNow()
    }

    private func savePendingStatsNow() {
        statsService?.saveAllPendingNow(trackProvider: trackProvider)
    }

}
