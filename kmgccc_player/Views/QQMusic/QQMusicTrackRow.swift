//
//  QQMusicTrackRow.swift
//  kmgccc_player
//
//  One online track, drawn with the library's own row geometry.
//
//  This replaces the previous hand-rolled row (38pt artwork, 13pt title, a
//  trailing progress readout and a heart sitting in the layout). That row was
//  recognisably a different list: different artwork size, different type scale,
//  and controls that were always on screen.
//
//  The geometry now comes from `Constants.Layout.TrackRow` — the same numbers
//  `TrackRowView` uses — so an online list and a local list line up column for
//  column. The online-only state (download progress, the like toggle, the
//  failure detail) is folded into the places the library row already reserves:
//    - download progress overlays the artwork, which is the only element with
//      room for it and is where the artwork itself is being fetched;
//    - the like toggle and the ellipsis menu sit in the trailing glyph column
//      and fade in on hover, matching `TrackRowView`'s own `0.4 → 1` treatment;
//    - the failure detail moves into a click-through popover attached to the
//      artwork, so a long upstream message never lands in the row.
//
//  `TrackRowView` itself was not reused because its menu contract is a library
//  `Track` (`TrackActionMenuContent`, playlist membership, deletion), and an
//  online row has no library track until it has been downloaded. The numbers
//  are shared, which is what the eye reads.
//

import AppKit
import SwiftUI

struct QQMusicTrackRow: View {

    let track: QQMusicOnlineTrack
    /// Position in the list, shown only when the list is a ranking.
    var rank: Int?
    /// Distance from the *window* edge to this row's content box. The library's
    /// lists pad themselves by 24 inside the center pane, so an equivalent
    /// full-window row is inset by the pane's width plus 24.
    var columnLeftPad: CGFloat = 0
    var columnRightPad: CGFloat = 0
    let onPlay: () -> Void
    /// Selection mode inputs. Defaulted so the row also works where selection
    /// is not offered (radio, artist pages).
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)?
    /// True when the user already downloaded this themselves.
    ///
    /// It only changes how the row looks while a download selection is being
    /// made: there, the track cannot be selected, so it is dimmed to show that.
    /// In every other mode the list is simply a list, and a track the user owns
    /// is drawn like any other — dimming it there made a normal list look like it
    /// had disabled entries in it.
    var isOwnedByUser: Bool = false

    /// Whether the row is unselectable in a selection in progress.
    private var isBlockedFromSelection: Bool { isSelecting && isOwnedByUser }

    /// The failure detail, shown only when the warning glyph is clicked.
    @State private var isShowingErrorDetail = false
    @State private var isHovering = false

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var phase: QQMusicDownloadPhase { coordinator.phase(for: track.songMid) }
    private var isImported: Bool { coordinator.isImported(track.songMid) }
    private var isPlaying: Bool { coordinator.isPlaying(track.songMid) }
    private var isLiked: Bool { coordinator.isLiked(songMid: track.songMid) }
    private var isLikePending: Bool { coordinator.isLikePending(songMid: track.songMid) }

    var body: some View {
        HStack(spacing: Constants.Layout.TrackRow.horizontalSpacing) {
            if isSelecting {
                selectionGlyph
            }

            artworkView

            HStack(alignment: .center, spacing: Constants.Layout.TrackRow.textColumnSpacing) {
                VStack(alignment: .leading, spacing: Constants.Layout.TrackRow.textVerticalSpacing) {
                    Text(track.title)
                        .font(.system(
                            size: Constants.Layout.TrackRow.titleFontSize,
                            weight: isPlaying ? .semibold : .regular
                        ))
                        .foregroundStyle(isPlaying ? themeStore.accentColor : primaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let album = track.album, !album.isEmpty {
                        Text(album)
                            .font(.system(size: Constants.Layout.TrackRow.subtitleFontSize))
                            .foregroundStyle(tertiaryColor)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // The artist column is a fixed width in `TrackRowView`, so the
                // titles of two lists wrap at the same place.
                Text(artistText)
                    .font(.system(size: Constants.Layout.TrackRow.subtitleFontSize))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .frame(width: 164, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let rank {
                Text("\(rank)")
                    .font(.system(size: Constants.Layout.TrackRow.durationFontSize).monospacedDigit())
                    .foregroundStyle(tertiaryColor)
                    .frame(width: 28, alignment: .trailing)
            }

            playingIndicator

            Text(durationText)
                .font(.system(size: Constants.Layout.TrackRow.durationFontSize))
                .foregroundStyle(tertiaryColor)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)

            likeButton

            statusControl
        }
        .padding(.vertical, Constants.Layout.TrackRow.verticalPadding)
        .padding(.horizontal, Constants.Layout.TrackRow.horizontalPadding)
        .frame(height: Constants.Layout.TrackRow.height)
        // Full-bleed across the window so the hover/selection wash and the
        // artwork align with the library's own rows; only the content is inset.
        .padding(.leading, columnLeftPad)
        .padding(.trailing, columnRightPad)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { onPlay() }
        // While selecting, a single tap toggles: the row is the obvious target,
        // and requiring the checkbox itself would be needlessly fiddly.
        .onTapGesture {
            if isSelecting, !isOwnedByUser { onToggleSelection?() }
        }
        .opacity(isBlockedFromSelection ? 0.45 : 1)
        .contextMenu { contextMenuContent }
    }

    // MARK: - Columns

    private var primaryColor: Color {
        isBlockedFromSelection ? .secondary : themeStore.appForegroundPalette.primaryColor
    }

    private var secondaryColor: Color {
        themeStore.appForegroundPalette.secondaryColor
    }

    private var tertiaryColor: Color {
        themeStore.appForegroundPalette.tertiaryColor
    }

    private var artistText: String {
        track.artist.isEmpty ? "未知歌手" : track.artist
    }

    @ViewBuilder
    private var selectionGlyph: some View {
        Image(systemName: isOwnedByUser || isSelected
              ? "checkmark.circle.fill"
              : "circle")
            .font(.system(size: 15))
            .foregroundStyle(
                isOwnedByUser
                    ? Color.secondary
                    : (isSelected ? themeStore.accentColor : Color.secondary)
            )
            .frame(width: 18)
            .contentShape(Rectangle())
    }

    /// Playing indicator / missing-file glyph column, as `TrackRowView` has it.
    @ViewBuilder
    private var playingIndicator: some View {
        if isPlaying {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: Constants.Layout.TrackRow.playingIndicatorFontSize, weight: .medium))
                .foregroundStyle(themeStore.accentColor)
                .frame(width: 20)
        } else {
            Color.clear.frame(width: 20)
        }
    }

    private var durationText: String {
        guard let duration = track.duration, duration > 0 else { return "--:--" }
        return String(format: "%d:%02d", duration / 60, duration % 60)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Constants.Layout.TrackRow.cornerRadius)
            .fill(backgroundFill)
    }

    private var backgroundFill: Color {
        if isSelected {
            return themeStore.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.15)
        }
        if isPlaying {
            return themeStore.accentColor.opacity(colorScheme == .dark ? 0.08 : 0.06)
        }
        return isHovering ? Color.primary.opacity(0.04) : Color.clear
    }

    /// 44pt artwork, with the download state drawn over it.
    ///
    /// The artwork slot is where the download is visible because it is what the
    /// download produces; a spinner elsewhere in the row competed with the play
    /// control for the same glance.
    private var artworkView: some View {
        ZStack {
            QQMusicArtworkView(
                urlString: track.imageURL,
                size: Constants.Layout.TrackRow.artworkSize,
                cornerRadius: Constants.Layout.TrackRow.artworkCornerRadius
            )

            switch phase {
            case .resolving, .fetchingExtras:
                ZStack {
                    Color.black.opacity(0.45)
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                .frame(width: Constants.Layout.TrackRow.artworkSize, height: Constants.Layout.TrackRow.artworkSize)
                .clipShape(RoundedRectangle(
                    cornerRadius: Constants.Layout.TrackRow.artworkCornerRadius,
                    style: .continuous
                ))
            case .downloading(let fraction):
                ZStack {
                    Color.black.opacity(0.45)
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .frame(width: Constants.Layout.TrackRow.artworkSize, height: Constants.Layout.TrackRow.artworkSize)
                .clipShape(RoundedRectangle(
                    cornerRadius: Constants.Layout.TrackRow.artworkCornerRadius,
                    style: .continuous
                ))
            case .failed:
                ZStack {
                    Color.black.opacity(0.45)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                }
                .frame(width: Constants.Layout.TrackRow.artworkSize, height: Constants.Layout.TrackRow.artworkSize)
                .clipShape(RoundedRectangle(
                    cornerRadius: Constants.Layout.TrackRow.artworkCornerRadius,
                    style: .continuous
                ))
                .contentShape(Rectangle())
                .onTapGesture { isShowingErrorDetail = true }
                .popover(isPresented: $isShowingErrorDetail, arrowEdge: .bottom) {
                    errorDetailPopover
                }
                .help("下载失败，点击查看原因")
            case .idle, .done:
                EmptyView()
            }
        }
        .frame(width: Constants.Layout.TrackRow.artworkSize, height: Constants.Layout.TrackRow.artworkSize)
    }

    // MARK: - Trailing controls

    /// The like toggle and the play control, in the trailing glyph column.
    ///
    /// The heart only appears on hover for a track that is not liked, which is
    /// the same treatment the ellipsis gets in the library rows: the column
    /// stays quiet until the pointer is on it, but a liked track keeps its
    /// filled heart visible so the list can be read at a glance.
    @ViewBuilder
    private var likeButton: some View {
        if !track.songMid.isEmpty {
            Button {
                Task { await coordinator.toggleLike(songMid: track.songMid, row: track) }
            } label: {
                Group {
                    if isLikePending {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: isLiked ? "heart.fill" : "heart")
                            .font(.system(size: 12))
                            .foregroundStyle(isLiked ? themeStore.accentColor : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLikePending)
            .opacity(isLiked || isHovering ? 1 : 0)
            .help(isLiked ? "取消收藏" : "收藏到「我喜欢」")
            .animation(.snappy(duration: 0.2), value: isLiked)
        }
    }

    /// The play control, in the trailing glyph column at the library's own
    /// `trailingMenuHitSize` of 30pt.
    ///
    /// The failure case shows the same glyph as every other row and defers the
    /// message to the artwork's popover: a long upstream error text in this
    /// column pushed the glyph out of reach and truncated mid-word.
    private var statusControl: some View {
        Button(action: onPlay) {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.circle")
                .font(.system(size: 15))
                .foregroundStyle(
                    isPlaying
                        ? themeStore.accentColor
                        : (isHovering ? themeStore.accentColor : secondaryColor)
                )
        }
        .buttonStyle(.plain)
        .frame(
            width: Constants.Layout.TrackRow.trailingMenuHitSize,
            height: Constants.Layout.TrackRow.trailingMenuHitSize
        )
        .contentShape(Rectangle())
        .help(helpText)
    }

    private var helpText: String {
        if isPlaying { return "正在播放" }
        if isImported { return "播放（已在曲库）" }
        if track.isExpectedPlayable { return "播放（后台自动下载）" }
        return "需要会员，仍可尝试播放"
    }

    private var errorDetailPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("下载失败")
                    .font(.system(size: 13, weight: .semibold))
            }
            if case .failed(let message) = phase {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    // Selectable so the text can be copied for a bug report.
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button(action: onPlay) {
            Label("播放", systemImage: "play")
        }

        Button {
            Task { await coordinator.playNext(track) }
        } label: {
            Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            Task { await coordinator.downloadOne(track) }
        } label: {
            Label(
                isImported ? "已在曲库（转为手动下载）" : "下载",
                systemImage: "arrow.down.circle"
            )
        }
        .disabled(track.songMid.isEmpty || phase.isBusy)

        Divider()

        Button {
            Task { await coordinator.toggleLike(songMid: track.songMid, row: track) }
        } label: {
            Label(isLiked ? "取消收藏" : "收藏到「我喜欢」",
                  systemImage: isLiked ? "heart.slash" : "heart")
        }
        .disabled(isLikePending || track.songMid.isEmpty)
    }
}
