//
//  QQMusicTrackRow.swift
//  kmgccc_player
//
//  One online track, drawn with the library's own row geometry **and its own
//  interaction**.
//
//  The geometry comes from `Constants.Layout.TrackRow` — the same numbers
//  `TrackRowView` uses — so an online list and a local list line up column for
//  column, and the interaction is `TrackRowView`'s too:
//
//    - a **single click on the row plays it** (no play button, no double click);
//    - the trailing glyph is the app's **ellipsis menu**, at the same
//      `trailingMenuHitSize`, offering 播放 / 下一首播放 / 查看详情 / 查看艺人 /
//      查看专辑 — the entity items open the online pages for them;
//    - in selection mode the ellipsis goes quiet and the same click toggles the
//      row instead, exactly as the library's rows behave in multiselect;
//    - **selection is a row colour, not a tick**: the fill and the
//      corner-merging shape are `TrackRowView`'s own
//      (`TrackRowSelectionBackgroundShape` with a continuity from the list
//      around it), so a run of selected rows reads as one rounded block.
//
//  `TrackRowView` itself is still not reused: its menu contract is a library
//  `Track` (playlist membership, deletion, metadata editing) and an online row
//  has no library track until it has been downloaded. The numbers and the
//  interaction are shared, which is what the eye and the hand read.
//
//  The online-only state is folded into the places the library row already
//  reserves:
//    - download progress overlays the artwork, which is the only element with
//      room for it and is where the artwork itself is being fetched;
//    - the like toggle sits beside the ellipsis and fades in on hover, matching
//      the ellipsis's own quiet-until-hovered treatment;
//    - the failure detail moves into a click-through popover attached to the
//      artwork, so a long upstream message never lands in the row.
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
    /// Whether the rows above and below this one are selected too, so the
    /// selection fill merges into one block instead of a stack of capsules.
    /// Computed from the *displayed* order, which is what is on screen.
    var selectionContinuity: TrackRowSelectionContinuity = .isolated
    var onToggleSelection: (() -> Void)?
    /// True when the user already downloaded this themselves.
    ///
    /// It only changes how the row looks while a download selection is being
    /// made: there, the track cannot be selected, so it is dimmed to show that.
    /// In every other mode the list is simply a list, and a track the user owns
    /// is drawn like any other — dimming it there made a normal list look like
    /// it had disabled entries in it.
    var isOwnedByUser: Bool = false

    /// Whether the row is unselectable in a selection in progress.
    private var isBlockedFromSelection: Bool { isSelecting && isOwnedByUser }

    /// Whether the trailing menu is live. The library's rows drop theirs to a
    /// static glyph while a selection is being made, because the row's click
    /// belongs to the selection then.
    private var areRowActionsEnabled: Bool { !isSelecting }

    /// The failure detail, shown only when the warning glyph is clicked.
    @State private var isShowingErrorDetail = false
    @State private var isHovering = false

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @Environment(QQMusicNavigation.self) private var navigation
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var phase: QQMusicDownloadPhase { coordinator.phase(for: track.songMid) }
    private var isImported: Bool { coordinator.isImported(track.songMid) }
    private var isPlaying: Bool { coordinator.isPlaying(track.songMid) }
    private var isLiked: Bool { coordinator.isLiked(songMid: track.songMid) }
    private var isLikePending: Bool { coordinator.isLikePending(songMid: track.songMid) }

    var body: some View {
        HStack(spacing: Constants.Layout.TrackRow.horizontalSpacing) {
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

            trailingMenu
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
        // One click, one meaning: play normally, select while selecting. Kept to
        // this view (`.including: .gesture`) so a click on the heart or the
        // ellipsis does not also start playback — the library's own row does the
        // same, for the same reason.
        .gesture(
            TapGesture().onEnded {
                if isSelecting {
                    guard !isOwnedByUser else { return }
                    onToggleSelection?()
                } else {
                    onPlay()
                }
            },
            including: .gesture
        )
        .opacity(isBlockedFromSelection ? 0.45 : 1)
        .contextMenu {
            if areRowActionsEnabled {
                menuContent
            }
        }
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

    // MARK: - Row background

    @ViewBuilder
    private var rowBackground: some View {
        let radius = Constants.Layout.TrackRow.cornerRadius
        if isSelected {
            // The library's own shape: the corners facing a neighbouring selected
            // row are squared off, so a run of them reads as one block.
            TrackRowSelectionBackgroundShape(
                continuity: selectionContinuity,
                cornerRadius: radius
            )
            .fill(backgroundFill)
            .padding(.top, selectionContinuity.connectsToPrevious ? -0.75 : 0)
            .padding(.bottom, selectionContinuity.connectsToNext ? -0.75 : 0)
        } else {
            RoundedRectangle(cornerRadius: radius)
                .fill(backgroundFill)
        }
    }

    /// The same three washes `TrackRowView` uses, in the same order of priority.
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

    /// The like toggle, in the glyph column beside the ellipsis.
    ///
    /// The heart only appears on hover for a track that is not liked, which is
    /// the same treatment the ellipsis gets: the column stays quiet until the
    /// pointer is on it, but a liked track keeps its filled heart visible so the
    /// list can be read at a glance.
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

    /// The trailing menu, at the library's own `trailingMenuHitSize` of 30pt and
    /// with the library's own glyph and menu style.
    @ViewBuilder
    private var trailingMenu: some View {
        if areRowActionsEnabled {
            Menu {
                menuContent
            } label: {
                trailingMenuGlyph
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
        } else {
            trailingMenuGlyph
                .opacity(0.72)
                .allowsHitTesting(false)
        }
    }

    private var trailingMenuGlyph: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: Constants.Layout.TrackRow.trailingMenuGlyphSize, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(
                width: Constants.Layout.TrackRow.trailingMenuHitSize,
                height: Constants.Layout.TrackRow.trailingMenuHitSize
            )
            .contentShape(Rectangle())
    }

    /// What the ellipsis offers — the five items the library's rows carry for a
    /// track, adapted to what is reachable online:
    ///
    ///   播放 · 下一首播放 ｜ 查看详情 · 查看艺人 · 查看专辑
    ///
    /// 查看艺人 / 查看专辑 appear only when we hold something to open (a singer
    /// mid / an album id), which is how the library hides navigation too: an
    /// item that cannot be honoured is absent rather than present and dead.
    @ViewBuilder
    private var menuContent: some View {
        Button(action: onPlay) {
            Label("播放", systemImage: "play")
        }

        Button {
            Task { await coordinator.playNext(track) }
        } label: {
            Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Divider()

        Button {
            coordinator.showTrackDetail(track)
        } label: {
            Label("查看详情", systemImage: "doc.text")
        }

        if track.hasArtistPage {
            Button {
                navigation.push(.artist(QQMusicArtistRef(
                    singerMid: track.singerMid ?? "",
                    name: artistText
                )))
            } label: {
                Label("查看艺人", systemImage: "person.crop.circle")
            }
        }

        if track.hasAlbumPage, let albumId = track.albumId {
            Button {
                navigation.push(.album(id: albumId, title: track.album ?? track.title))
            } label: {
                Label("查看专辑", systemImage: "rectangle.stack")
            }
        }
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
}
