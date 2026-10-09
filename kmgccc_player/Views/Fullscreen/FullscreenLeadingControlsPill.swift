import MotionKit
import SwiftUI

/// Which buttons the leading capsule carries.
///
/// The bottom-controls geometry reserves the capsule's width from this, so the
/// layout and the view cannot disagree. They did: the reservation was a fixed two
/// or three buttons, and the online favourite and the translation toggle made the
/// capsule wider than its slot — it overlapped the mini player, hovered or not.
struct FullscreenLeadingControlsAvailability: Equatable {
    /// The lyrics-visibility button. Skins can switch it off.
    var showsLyrics = true
    /// The online favourite, for a track that has an upstream id to write to.
    var showsLike = false
    /// The translation toggle, for a surface that renders lyrics at all.
    var showsTranslation = false
    /// Skin scenes may keep the quick-panel button on screen while collapsed.
    var pinsQuickPanel = false

    /// How many buttons the capsule shows in the given state.
    func buttonCount(expanded: Bool) -> Int {
        1  // exit
            + (showsLyrics ? 1 : 0)
            + (showsLike ? 1 : 0)
            + (showsTranslation ? 1 : 0)
            + ((expanded || pinsQuickPanel) ? 1 : 0)
    }
}

/// Shared left capsule. The native player uses this exact view; authors may also place it alone.
struct FullscreenLeadingControlsPill: View {
    let size: CGFloat
    let presentation: FullscreenBottomBarPresentation
    let actions: FullscreenBottomBarActions
    @Bindable var controls: FullscreenBottomControlsCoordinator
    var isFullscreen = true
    var availability = FullscreenLeadingControlsAvailability()
    var onHoverStateChanged: ((Bool) -> Void)? = nil

    /// The online-source favourite, reachable from the player's own bar.
    ///
    /// The window's playback bar already carried this button; the fullscreen
    /// player — the page the listener actually watches — had no way to reach it.
    /// Optional lookups: the pill is also placed by skins, whose scenes may not
    /// carry these services, and a missing one must not crash the surface.
    @Environment(QQMusicOnlineCoordinator.self) private var qqMusicCoordinator: QQMusicOnlineCoordinator?
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator: PlaybackCoordinator?
    @Environment(AppSettings.self) private var settings: AppSettings?
    @AppStorage("lyricsShowTranslation") private var showsTranslation = true

    var body: some View {
        let controlColorScheme = presentation.glassStyle.colorScheme
        let foregroundProfile = presentation.miniPlayerForegroundProfile
        let likeTrack = availability.showsLike ? likeableOnlineTrack : nil
        let quickPanelVisible = availability.pinsQuickPanel || controls.isLeftActionsExpanded

        return HStack(spacing: 0) {
            leadingControlButton(size: size, help: isFullscreen ? "fullscreen.exit" : "全屏播放") {
                Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(presentation.primaryColor)
                    .compositingGroup()
                    .blendMode(presentation.iconBlendMode)
                    .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
            } action: {
                actions.exitFullscreen()
            }

            if availability.showsLyrics { lyricsVisibilityButton(size: size) }

            if let track = likeTrack, let coordinator = qqMusicCoordinator {
                likeButton(size: size, track: track, coordinator: coordinator)
            }

            if availability.showsTranslation { translationButton(size: size) }

            quickAppearanceButton(size: size)
                .opacity(quickPanelVisible ? 1 : 0)
                .allowsHitTesting(quickPanelVisible)
                .accessibilityHidden(!quickPanelVisible)
        }
        .frame(
            width: size * CGFloat(availability.buttonCount(expanded: controls.isLeftActionsExpanded)),
            height: size,
            alignment: .leading
        )
        .contentShape(Capsule())
        .skinControlRegion()
        .liquidGlassPill(
            colorScheme: controlColorScheme,
            accentColor: nil as Color?,
            prominence: .standard,
            materialStyle: presentation.glassStyle.materialStyle,
            isFloating: true
        )
        .animation(nil, value: foregroundProfile)
        .environment(\.colorScheme, controlColorScheme)
        .onHover { hovering in
            if let onHoverStateChanged { onHoverStateChanged(hovering) }
            else { actions.leadingHoverChanged(hovering) }
        }
    }

    private func leadingControlButton<Label: View>(
        size: CGFloat,
        help: LocalizedStringKey,
        @ViewBuilder label: () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            actions.interaction()
            action()
        } label: {
            label()
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func quickAppearanceButton(size: CGFloat) -> some View {
        let icon = controls.isQuickAppearancePanelPresented ? "paintpalette.fill" : "paintpalette"
        return leadingControlButton(size: size, help: "快速外观") {
            Image(systemName: icon)
                .id(icon)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(presentation.primaryColor)
                .compositingGroup()
                .blendMode(presentation.iconBlendMode)
                .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
                .contentTransition(
                    .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
                )
                .motionAnimation(.microInteraction, value: icon)
        } action: {
            actions.setQuickAppearancePanelPresented(!controls.isQuickAppearancePanelPresented)
        }
    }

    private func lyricsVisibilityButton(size: CGFloat) -> some View {
        let icon = presentation.isShowingLyrics ? "quote.bubble.fill" : "quote.bubble"
        let helpText: LocalizedStringKey = presentation.isShowingLyrics ? "Hide Lyrics" : "Show Lyrics"
        return leadingControlButton(size: size, help: helpText) {
            Image(systemName: icon)
                .id(icon)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(presentation.primaryColor.opacity(presentation.hasTrack ? 1 : 0.45))
                .compositingGroup()
                .blendMode(presentation.iconBlendMode)
                .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
                .contentTransition(
                    .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
                )
                .motionAnimation(.microInteraction, value: icon)
        } action: {
            actions.toggleLyrics()
        }
        .disabled(!presentation.hasTrack)
    }

    /// The track the online favourite applies to, or nil when this bar should not
    /// offer the button: a local-only track has no upstream id to write to, and
    /// the QQ Music setting can hide the button entirely.
    private var likeableOnlineTrack: Track? {
        guard settings?.qqMusicShowLikeButton == true, qqMusicCoordinator != nil else { return nil }
        guard let presentation = playbackCoordinator?.stablePresentation,
              presentation.source == .local,
              let track = presentation.localTrack,
              track.qqMusicSongMid?.isEmpty == false
        else { return nil }
        return track
    }

    /// The same write the window's playback bar performs, from the page itself.
    private func likeButton(size: CGFloat, track: Track, coordinator: QQMusicOnlineCoordinator) -> some View {
        let isLiked = coordinator.isLiked(track)
        let isPending = coordinator.isLikePending(track)
        let icon = isLiked ? "heart.fill" : "heart"
        return leadingControlButton(size: size, help: isLiked ? "取消收藏" : "收藏到「我喜欢」") {
            Group {
                if isPending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .id(icon)
                        .font(.system(size: size * 0.32, weight: .semibold))
                        .foregroundStyle(isLiked ? ThemeStore.shared.accentColor : presentation.primaryColor)
                        .compositingGroup()
                        .blendMode(presentation.iconBlendMode)
                        .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
                        .contentTransition(
                            .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
                        )
                        .motionAnimation(.microInteraction, value: icon)
                }
            }
        } action: {
            Task { await coordinator.toggleLike(track) }
        }
        .disabled(isPending)
    }

    /// Show or hide lyric translations.
    ///
    /// Live: the lyric surfaces rebuild their configuration from the setting, so
    /// this needs neither a component reload nor a track change — which is why it
    /// lives here rather than in the settings window.
    private func translationButton(size: CGFloat) -> some View {
        let helpText: LocalizedStringKey = showsTranslation ? "隐藏歌词翻译" : "显示歌词翻译"
        return leadingControlButton(size: size, help: helpText) {
            Image(systemName: "translate")
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(presentation.primaryColor.opacity(showsTranslation ? 1 : 0.45))
                .compositingGroup()
                .blendMode(presentation.iconBlendMode)
                .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
                .motionAnimation(.microInteraction, value: showsTranslation)
        } action: {
            showsTranslation.toggle()
            NativeLyricsConfigurationMapper.applyTranslationVisibility(showsTranslation)
        }
    }
}
