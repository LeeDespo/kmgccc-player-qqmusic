//
//  QQMusicFullWindowRoot.swift
//  kmgccc_player
//
//  Online browse surface, mounted in the same full-window AppKit host as Home.
//
//  Why the full window, and not the center pane: the library's home draws its
//  card rails across the entire window so they can travel under the sidebar and
//  lyrics glass, aligning their first card with the center column by padding
//  rather than by clipping. The online shelves are the same rails, so they need
//  the same canvas — inside the center pane they would stop at the pane's edge
//  and read as a different, narrower page.
//
//  That host (`PassthroughHostingView<HomeFullWindowRoot>`) is shared, and the
//  hit routing that serves it
//  (`HomeRoutingRootView.hitTest` → `CenterPanePassthroughHostingView.hitTest`)
//  is gated on `HomeWindowLayoutState.allowsHomeInteraction`. This root is
//  therefore mounted by `HomeFullWindowRoot` itself, which is where that gate is
//  already read — no change to the window controller or split controller was
//  needed to give the online pages the full window.
//

import SwiftUI

struct QQMusicFullWindowRoot: View {

    @ObservedObject var appSession: AppSessionHost

    var body: some View {
        Group {
            if let coordinator = appSession.qqMusicOnlineCoordinator {
                QQMusicPageRouter()
                    // One shared composition, also applied by
                    // `QQMusicBrowseEnvironmentTests`, so a required value
                    // dropped here fails a test instead of the first click. It
                    // includes `AppSettings`, which the shared glass-card
                    // modifier reads non-optionally.
                    .qqMusicBrowseEnvironment(
                        coordinator: coordinator,
                        navigation: coordinator.navigation,
                        selection: coordinator.selection
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .all)
    }
}
