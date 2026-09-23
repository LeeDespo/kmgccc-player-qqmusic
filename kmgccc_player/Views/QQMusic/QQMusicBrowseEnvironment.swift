//
//  QQMusicBrowseEnvironment.swift
//  kmgccc_player
//
//  The environment the online browse surface requires, in one place.
//
//  Why it is extracted rather than written inline at the mount point: the
//  surface reuses library components, and those components read some values
//  from the environment *non-optionally*. `homeUnifiedGlassCard` is the
//  important one — `HomeUnifiedGlassCardModifier` declares
//  `@Environment(AppSettings.self)`, so a card drawn without `AppSettings` in
//  scope traps with "No Observable object of type AppSettings found" the moment
//  the landing page renders. That is a launch-time crash of the whole surface,
//  not a degraded drawing.
//
//  Keeping the list here means the mount point and the regression test apply the
//  same composition, so a value dropped from it fails a test rather than the
//  user's first click.
//

import SwiftUI

struct QQMusicBrowseEnvironmentModifier: ViewModifier {

    let coordinator: QQMusicOnlineCoordinator
    let navigation: QQMusicNavigation
    let selection: QQMusicSelectionModel

    func body(content: Content) -> some View {
        content
            .environment(coordinator)
            .environment(navigation)
            .environment(selection)
            .environment(\.qqMusicArtworkLoader, coordinator.artworkLoader)
            // Required (non-optional) by the shared glass-card modifier.
            .environment(AppSettings.shared)
            .environmentObject(ThemeStore.shared)
            .tint(ThemeStore.shared.accentColor)
            .accentColor(ThemeStore.shared.accentColor)
    }
}

extension View {
    /// Apply everything the online browse surface needs from the environment.
    func qqMusicBrowseEnvironment(
        coordinator: QQMusicOnlineCoordinator,
        navigation: QQMusicNavigation,
        selection: QQMusicSelectionModel
    ) -> some View {
        modifier(QQMusicBrowseEnvironmentModifier(
            coordinator: coordinator,
            navigation: navigation,
            selection: selection
        ))
    }
}
