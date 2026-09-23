//
//  QQMusicDownloadControl.swift
//  kmgccc_player
//
//  The batch-download control, as a window-toolbar item.
//
//  It sits in the toolbar immediately to the right of the 刷新 button, which in
//  turn follows the 后退/前进 pill — the same row as the navigation and search
//  controls. Putting it there rather than inside a page means a list-wide action
//  lives in the one place this app already uses for things that act on the
//  current page.
//
//  One container, two states, so the material cannot drift between them:
//
//    idle      a single download glyph, on nothing at all
//    selecting 全选 · 反选 · 取消 · 下载所选, on one pill
//
//  The idle state is deliberately background-less. The window toolbar already
//  draws the glass this view sits on, so painting a second glass capsule behind
//  the glyph made the button read as a white haze that the neighbouring toolbar
//  items — all plain `NSImage` items — do not have. The expanded state does need
//  a container to read as one segmented control, and uses the neutral fill
//  `GlassToolbarTriplePill` already uses for its `.systemToolbar` variant, which
//  exists for exactly this reason.
//
//  The animation is the app's own idiom for a button that changes meaning: a
//  spring on the width, the two states cross-fading in a `ZStack`,
//  `.numericText()` on the count and `symbolEffect(.replace)` on the glyph — the
//  same treatment `GlassToolbarTriplePill` gives its multiselect toggle,
//  including the `.systemToolbar` surface variant.
//
//  The toolbar sizes itself from this view, so the state change has to drive
//  layout rather than only drawing — hence `sizingOptions = [.intrinsicContentSize]`
//  on the view that hosts it, in `AppKitMainToolbarItemFactory`.
//

import AppKit
import SwiftUI

struct QQMusicDownloadControl: View {

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @Environment(QQMusicNavigation.self) private var navigation
    @Environment(QQMusicSelectionModel.self) private var selection
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    /// Switching shape mid-animation on a spring; the same response the app uses
    /// for its toolbar pills.
    private var shapeAnimation: Animation {
        .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)
    }

    private var tracks: [QQMusicOnlineTrack] {
        coordinator.tracks(for: navigation.displayed)
    }

    /// Whether the page on screen is one this control applies to at all.
    ///
    /// Asked of the page's *kind*, not of whether its rows have arrived. Gating
    /// on the rows made the control dim while each page's first request was in
    /// flight and brighten when it landed — so it appeared to vanish on arrival
    /// and animate back in a moment later, on every navigation.
    ///
    /// Checked here as well as in `validateToolbarItem`, because AppKit's
    /// `isEnabled` does not reliably reach a custom item view: without this the
    /// control could still be clicked on the landing page and would open a
    /// selection mode with no rows behind it.
    private var isAvailable: Bool {
        coordinator.offersBatchDownload(navigation.displayed)
    }

    private var ownedSongMids: Set<String> {
        Set(tracks.map(\.songMid).filter { coordinator.isUserDownloaded($0) })
    }

    var body: some View {
        // Both states are laid out in the same place and cross-fade, so the
        // change of shape reads as one control re-forming rather than as one
        // control being swapped for another: the pill's width springs out while
        // the glyph hands over to the labels.
        ZStack(alignment: .leading) {
            if selection.isSelecting {
                selectingContent
                    .background(selectionPill)
                    .clipShape(Capsule())
                    .transition(
                        .scale(scale: 0.92, anchor: .leading).combined(with: .opacity)
                    )
            } else {
                idleContent
                    .transition(
                        .scale(scale: 0.92, anchor: .leading).combined(with: .opacity)
                    )
            }
        }
        .frame(height: GlassStyleTokens.headerControlHeight)
        .animation(shapeAnimation, value: selection.isSelecting)
        .animation(shapeAnimation, value: selection.selectedSongMids.count)
        .animation(shapeAnimation, value: selection.isDownloading)
        // Availability is not a transition. The control keeps its shape on every
        // page and only its opacity and behaviour change; without this, whatever
        // animation happens to be in flight when the page changes carries the
        // dimming with it, which reads as the button fading out and back in.
        .animation(nil, value: isAvailable)
    }

    /// The container the expanded state sits on.
    ///
    /// A neutral fill rather than `liquidGlassPill`: the glass is the toolbar's,
    /// and is already behind this view (see the note at the top of the file).
    private var selectionPill: some View {
        Capsule()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045))
            .overlay(
                Capsule().strokeBorder(
                    Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.09),
                    lineWidth: 0.5
                )
            )
    }

    // MARK: - Idle

    /// A single download glyph, as asked for. No label and no background, so the
    /// resting control is as quiet as the other toolbar buttons beside it.
    private var idleContent: some View {
        Button {
            guard isAvailable else { return }
            withAnimation(shapeAnimation) {
                selection.begin()
            }
        } label: {
            Image(systemName: "arrow.down.circle")
                .id("qqdownload-idle")
                .font(.system(size: GlassStyleTokens.headerPrimaryIconSize, weight: .semibold))
                .foregroundStyle(themeStore.accentColor)
                .contentTransition(
                    .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
                )
                .frame(
                    width: GlassStyleTokens.headerControlHeight,
                    height: GlassStyleTokens.headerControlHeight
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.4)
        .help(isAvailable ? "选择下载" : "这个页面没有可下载的列表")
        .accessibilityLabel(Text("选择下载"))
    }

    // MARK: - Selecting

    private var selectingContent: some View {
        HStack(spacing: 0) {
            segment("全选") {
                selection.selectAll(in: tracks, excluding: ownedSongMids)
            }

            divider

            segment("反选") {
                selection.invert(in: tracks, excluding: ownedSongMids)
            }

            divider

            segment("取消") {
                withAnimation(shapeAnimation) {
                    selection.cancel()
                }
            }

            divider

            downloadSelectedSegment
        }
    }

    /// One labelled action. The label is what makes the widened pill readable —
    /// four bare glyphs would be a guessing game.
    private func segment(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(themeStore.accentColor)
                .padding(.horizontal, 12)
                .frame(height: GlassStyleTokens.headerControlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The primary action of the mode, tinted so it reads as the one that
    /// finishes the job rather than as one of four equals.
    private var downloadSelectedSegment: some View {
        Button {
            Task { await downloadSelection() }
        } label: {
            HStack(spacing: 5) {
                if selection.isDownloading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text("下载所选")
                    .font(.system(size: 13, weight: .semibold))
                if selection.selectedSongMids.count > 0 {
                    Text("\(selection.selectedSongMids.count)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .opacity(0.85)
                        // Counted so the number is legible while it changes.
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: selection.selectedSongMids.count)
                }
            }
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 12)
            .frame(height: GlassStyleTokens.headerControlHeight)
            .contentShape(Rectangle())
            .background(themeStore.accentColor.opacity(selection.selectedSongMids.isEmpty ? 0.35 : 1))
        }
        .buttonStyle(.plain)
        .disabled(selection.selectedSongMids.isEmpty || selection.isDownloading)
        .help("下载选中的歌曲")
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 0.5, height: GlassStyleTokens.headerControlHeight - 12)
    }

    // MARK: - Action

    /// Download everything selected, then report what happened.
    ///
    /// A track already on disk from playback is *converted*, not fetched again —
    /// `downloadSelected` counts the two separately so the message does not claim
    /// a download that did not happen.
    private func downloadSelection() async {
        let chosen = tracks.filter { selection.isSelected($0.songMid) }
        guard !chosen.isEmpty else { return }
        selection.setDownloading(true)
        defer { selection.setDownloading(false) }

        let result = await coordinator.downloadSelected(chosen)
        let summary = QQMusicSelectionSummary.text(
            downloaded: result.downloaded,
            converted: result.converted,
            failed: result.failed
        )
        coordinator.report(summary, isError: result.failed > 0)
        if result.failed == 0 {
            withAnimation(shapeAnimation) {
                selection.cancel()
            }
        }
    }
}

/// The wording for a finished batch.
///
/// Pulled out of the view so the phrasing is testable: "已下载" over a track that
/// was merely relabeled is a claim about work that did not happen.
enum QQMusicSelectionSummary {

    static func text(downloaded: Int, converted: Int, failed: Int) -> String {
        var parts: [String] = []
        if downloaded > 0 { parts.append("已下载 \(downloaded) 首") }
        if converted > 0 { parts.append("\(converted) 首转为手动下载") }
        if failed > 0 { parts.append("\(failed) 首失败") }
        return parts.isEmpty ? "没有可处理的项目" : parts.joined(separator: "，")
    }
}
