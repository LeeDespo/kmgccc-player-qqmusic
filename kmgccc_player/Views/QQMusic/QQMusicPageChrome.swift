//
//  QQMusicPageChrome.swift
//  kmgccc_player
//
//  The layout primitives the online pages share with the library's own pages.
//
//  Every number here is copied from the library view it matches, and named
//  after it, because the point is that a card, a row and a section title in the
//  online surface be *the same object* as in the local one. Inventing values
//  that merely look close is what made the online surface read as a separate
//  tool before.
//
//  Sources:
//    - section title   → HomeView.homeSection (mode.sectionTitleFontSize)
//    - card            → HomeAlbumsSection.HomeAlbumCard
//    - rail            → HomeAlbumsSection.carousel (HorizontalFadeScrollContainer)
//    - list row        → AllPlaylistsView.PlaylistListRow / AllAlbumsView.AlbumListRow
//    - track row       → Views/Library/TrackRowView (via Constants.Layout.TrackRow)
//    - detail header   → LibraryDetailHeaderView (220pt artwork, play capsule)
//

import AppKit
import SwiftUI

// MARK: - Page canvas

/// Where the content column sits inside the window.
///
/// The canvas spans the window, so a page has to be told where the center column
/// is before it can align anything with it. `pad(_:)` is the whole point: the
/// library's own pages use fixed horizontal padding *inside the center pane*,
/// so the equivalent for a full-window page is the pane's inset plus that same
/// padding — which is exactly how `HomeView` aligns its sections.
struct QQMusicColumnInsets: Equatable {
    var left: CGFloat
    var right: CGFloat

    /// Distance from the window edge to a column-aligned element with the given
    /// inner padding.
    func pad(_ inner: CGFloat) -> (left: CGFloat, right: CGFloat) {
        (left + inner, right + inner)
    }
}

/// Shared canvas for every online page.
///
/// Mirrors `HomeView.scrollContent`: the same ambient background behind the
/// content, the same top inset that clears the unified toolbar, and the same
/// bottom gap that keeps the floating Mini Player off the last row.
///
/// The layout numbers come from `HomeWindowLayoutState.discreteSnapshot`, which
/// is how Home itself learns where the center column is. That is the mechanism
/// that lets a full-window page align its content with the center column while
/// letting a card rail travel under the sidebar/lyrics glass.
struct QQMusicPageCanvas<Content: View>: View {

    /// Scroll offset feed for the ambient background's parallax.
    ///
    /// A closure rather than a binding: the ambient motion state publishes on
    /// every scroll frame, and observing it from a page body would invalidate
    /// the whole page on each tick. Only the AppKit layer behind the content
    /// subscribes.
    var onScroll: ((CGFloat) -> Void)?
    @ViewBuilder var content: (_ insets: QQMusicColumnInsets, _ mode: HomeLayoutMode) -> Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Observed rather than read from the singleton directly: the ambient
    /// background is driven by the current palette, so it has to be rebuilt when
    /// the palette changes (switching tracks re-extracts it).
    @ObservedObject private var themeStore = ThemeStore.shared

    private var layout = HomeWindowLayoutState.shared

    var body: some View {
        let snap = layout.discreteSnapshot
        let mode = HomeLayoutMode.from(snap.mode)
        let insets = QQMusicColumnInsets(
            left: CGFloat(snap.leftInset),
            right: CGFloat(snap.rightInset)
        )

        ZStack(alignment: .topLeading) {
            if snap.hasValidLayout {
                HomeAmbientShapesBackground(
                    sourceColor: themeStore.semanticPalette.ambientSurface,
                    sourceAnalysis: themeStore.semanticPalette.analysis,
                    colorScheme: colorScheme,
                    reduceMotion: reduceMotion
                )

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: mode.sectionSpacing) {
                        content(insets, mode)
                    }
                    // Clears the unified titlebar/toolbar, exactly as Home's
                    // own scroll content does.
                    .padding(.top, 56)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, newValue in
                    onScroll?(newValue)
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Blank space below the last row of every list.
    ///
    /// The playback bar floats over the content, so without this the final row
    /// sits underneath it and cannot be read or clicked. Matches the app's own
    /// detail lists, which reserve the same gap.
    static var listBottomInset: CGFloat { GlassStyleTokens.miniPlayerHeight + 70 }
}

// MARK: - Section header

/// A section title with the library's own type scale, optionally with the
/// trailing "查看全部" affordance the home rails use.
struct QQMusicSectionHeader: View {

    let title: String
    var mode: HomeLayoutMode = .wide
    var seeAllTitle: String?
    var onSeeAll: (() -> Void)?
    var subtitle: String?
    /// Column-aligned padding. Pass `insets.pad(24)` for a header that should
    /// line up with the library's own 24pt content padding.
    var leadingPad: CGFloat = 0
    var trailingPad: CGFloat = 0

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: mode.sectionTitleFontSize, weight: .semibold))
                .foregroundStyle(themeStore.appForegroundPalette.primaryColor)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
            }

            Spacer(minLength: 8)

            if let onSeeAll, let seeAllTitle {
                Button(action: onSeeAll) {
                    HStack(spacing: 2) {
                        Text(seeAllTitle)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, leadingPad)
        .padding(.trailing, trailingPad)
    }
}

// MARK: - Rail

/// A horizontally scrolling rail of cards, laid out exactly as the home rails
/// are: first card at the center column's left edge, viewport spanning the
/// whole window so cards travel under the sidebar/lyrics glass.
struct QQMusicCardRail<Card: View>: View {

    var mode: HomeLayoutMode = .wide
    let centerLeftPad: CGFloat
    let centerRightPad: CGFloat
    private let cardSize: CGFloat
    private let spacing: CGFloat
    @ViewBuilder var cards: () -> Card

    init(
        mode: HomeLayoutMode = .wide,
        centerLeftPad: CGFloat,
        centerRightPad: CGFloat,
        cardSize: CGFloat? = nil,
        spacing: CGFloat? = nil,
        @ViewBuilder cards: @escaping () -> Card
    ) {
        self.mode = mode
        self.centerLeftPad = centerLeftPad
        self.centerRightPad = centerRightPad
        self.cardSize = cardSize ?? Self.cardSize(for: mode)
        self.spacing = spacing ?? Self.spacing(for: mode)
        self.cards = cards
    }

    /// Copied from `HomeAlbumsSection.cardSize`.
    static func cardSize(for mode: HomeLayoutMode) -> CGFloat {
        switch mode {
        case .wide:    return 164
        case .medium:  return 146
        case .compact: return 124
        case .narrow:  return 110
        }
    }

    /// Copied from `HomeAlbumsSection.rowSpacing`.
    static func spacing(for mode: HomeLayoutMode) -> CGFloat {
        switch mode {
        case .wide:    return 18
        case .medium:  return 14
        case .compact: return 12
        case .narrow:  return 10
        }
    }

    var body: some View {
        HorizontalFadeScrollContainer(
            spacing: spacing,
            fadeWidth: 0,
            verticalPadding: 22,
            leadingScrollPadding: centerLeftPad + 4,
            trailingScrollPadding: max(4, centerRightPad - 8),
            showsEdgeFade: false,
            showsScrollButtons: true,
            scrollButtonLeadingInset: centerLeftPad + 8,
            scrollButtonTrailingInset: max(12, centerRightPad + 8)
        ) {
            cards()
        }
    }
}

// MARK: - Card

/// A rail card: artwork above two lines of text, on the library's glass card.
///
/// A copy of `HomeAlbumCard` rather than a reuse of it: that card's identity,
/// taps and context menu all resolve to a local `AlbumEntry`, and there is no
/// online equivalent to hand it. The geometry is therefore copied deliberately,
/// down to the concentric corner radii (`innerR = outerR − inset`).
struct QQMusicCard<Artwork: View>: View {

    let title: String
    var subtitle: String?
    var size: CGFloat
    var titleColor: Color
    var subtitleColor: Color
    var onOpen: (() -> Void)?
    var menuItems: (() -> AnyView)?
    @ViewBuilder var artwork: () -> Artwork

    @Environment(\.colorScheme) private var colorScheme

    private let outerCornerRadius: CGFloat = 18
    private let cardInset: CGFloat = 10

    private var coverCornerRadius: CGFloat {
        max(0, outerCornerRadius - cardInset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            artwork()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: coverCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(titleColor)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                }
            }
        }
        .padding(cardInset)
        .frame(width: size + cardInset * 2, alignment: .leading)
        // `isFloating: false` matches the home rails, which drop the per-card
        // drop shadow because a long rail of floating cards reads as noise.
        .homeUnifiedGlassCard(
            cornerRadius: outerCornerRadius,
            colorScheme: colorScheme,
            isFloating: false
        )
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .contextMenu {
            if let menuItems {
                menuItems()
            }
        }
    }
}

/// Artwork stand-ins for entries whose source supplies no cover.
enum QQMusicCardArtwork {

    /// 我喜欢 has no playlist cover. A heart on the accent colour says what it
    /// is without inventing an image, and matches how the row heart is drawn.
    struct LikedHeart: View {
        let size: CGFloat

        @EnvironmentObject private var themeStore: ThemeStore

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                    .fill(themeStore.accentColor.opacity(0.5))
                Image(systemName: "heart")
                    .font(.system(size: size * 0.32, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: size, height: size)
        }
    }

    /// Regions and rankings carry no cover; the name stands in for one.
    ///
    /// Rendered on the same placeholder the library uses for a missing cover,
    /// so it reads as "no artwork" rather than as a designed poster.
    struct TextCover: View {
        let text: String
        let size: CGFloat
        var systemImage: String = "music.note"

        @EnvironmentObject private var themeStore: ThemeStore

        var body: some View {
            ZStack {
                Rectangle()
                    .fill(themeStore.accentColor.opacity(0.5))
                VStack(spacing: size * 0.04) {
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.2, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(text)
                        .font(.system(size: max(11, size * 0.13), weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                }
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Entity list row

/// One row of an entity list page (playlists, albums, artists).
///
/// A faithful copy of `PlaylistListRow` / `AlbumListRow`: 60pt artwork, a
/// 76pt minimum height, the hover wash, and the trailing ellipsis menu that
/// fades in on hover. The online lists use it so that "more" from a home shelf
/// lands on a page indistinguishable from the library's own.
struct QQMusicEntityRow: View {

    let title: String
    var subtitle: String?
    var meta: String?
    var artworkURL: String?
    var circularArtwork: Bool = false
    var placeholderSystemImage: String = "music.note"
    /// Distance from the *window* edge to this row's content box. The library's
    /// list pages pad their list by 24 inside the center pane, so an equivalent
    /// full-window row is inset by the pane's width plus 24.
    var columnLeftPad: CGFloat = 0
    var columnRightPad: CGFloat = 0
    var onOpen: (() -> Void)?
    /// Right-click menu. Omitted where the online source has no actions.
    var menuItems: (() -> AnyView)?

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isHovering = false

    private let artworkSize: CGFloat = 60
    private let cornerRadius: CGFloat = 10

    var body: some View {
        HStack(spacing: 14) {
            artworkView
            textBlock
            Spacer(minLength: 8)
            trailingActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 76)
        // Rows are full-bleed across the window so their hover wash and their
        // artwork align with the library's list pages; only the content is
        // inset, which is what the library's own rows do inside their pane.
        .padding(.leading, columnLeftPad)
        .padding(.trailing, columnRightPad)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovering
                      ? Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04)
                      : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .onHover { isHovering = $0 }
        .contextMenu {
            if let menuItems {
                menuItems()
            }
        }
    }

    private var artworkView: some View {
        Group {
            if let artworkURL, !artworkURL.isEmpty {
                QQMusicArtworkView(
                    urlString: artworkURL,
                    size: artworkSize,
                    cornerRadius: circularArtwork ? artworkSize / 2 : cornerRadius
                )
            } else {
                ArtworkPlaceholderView(
                    size: artworkSize,
                    cornerRadius: circularArtwork ? artworkSize / 2 : cornerRadius,
                    clipShape: .continuous,
                    iconSize: 22,
                    iconOpacity: 0.4,
                    themeColor: themeStore.accentColor
                )
                .overlay {
                    Image(systemName: placeholderSystemImage)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(clipShape)
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1),
            radius: 4, y: 2
        )
    }

    private var clipShape: AnyShape {
        circularArtwork
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                .lineLimit(1)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                    .lineLimit(1)
            }

            if let meta, !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
                    .lineLimit(1)
            }
        }
    }

    /// Same treatment as the library rows: the glyph sits dimmed until hover.
    @ViewBuilder
    private var trailingActions: some View {
        if let menuItems {
            Menu {
                menuItems()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
            .opacity(isHovering ? 1 : 0.4)
        } else if onOpen != nil {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
                .frame(width: 24, height: 24)
        }
    }
}

// MARK: - Detail header

/// The 220pt header the library's detail pages use, for an online entity.
///
/// Mirrors `LibraryDetailHeaderView`'s composition and constants. It is a copy
/// rather than a reuse for the same reason `QQMusicArtistDetailView` already
/// copied it: the library header's edit affordances write into the local
/// library (`ArtistInfoEditSheet`, artwork autofill, `LibrarySelection`
/// navigation), none of which apply to a catalogue entity.
struct QQMusicDetailHeader<Extra: View>: View {

    let title: String
    var subtitle: String?
    var metadata: String?
    var artworkURL: String?
    var isCircleArtwork: Bool = false
    var placeholderSystemImage: String = "music.note"
    /// Description block (a playlist's intro, an artist's biography). Scrolls
    /// in place, as the library header's description does.
    var description: String?
    var onPlay: (() -> Void)?
    var canPlay: Bool = true
    /// Distance from the *window* edge to the header's content box, so it lines
    /// up with the rows below it. `LibraryDetailHeaderView` pads itself by 24
    /// inside the center pane.
    var columnLeftPad: CGFloat = 0
    var columnRightPad: CGFloat = 0
    /// Trailing controls beside the play capsule (select-download, like).
    @ViewBuilder var trailingControls: () -> Extra

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    /// Copied from `LibraryDetailHeaderView.artworkSide`.
    private static var artworkSide: CGFloat { 220 }
    private static var visibleDescriptionLines: Int { 4 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            artworkColumn
                .frame(width: Self.artworkSide, height: Self.artworkSide)

            headerTextColumn
        }
        .padding(.leading, columnLeftPad + 24)
        .padding(.trailing, columnRightPad + 24)
        .padding(.vertical, 20)
    }

    private var artworkColumn: some View {
        Group {
            if let artworkURL, !artworkURL.isEmpty {
                QQMusicArtworkView(
                    urlString: artworkURL,
                    size: Self.artworkSide,
                    cornerRadius: isCircleArtwork ? Self.artworkSide / 2 : 14
                )
            } else {
                ArtworkPlaceholderView(
                    size: Self.artworkSide,
                    cornerRadius: isCircleArtwork ? Self.artworkSide / 2 : 14,
                    clipShape: isCircleArtwork ? .circle : .continuous,
                    iconSize: max(44, Self.artworkSide * 0.2),
                    iconOpacity: 0.6,
                    themeColor: themeStore.accentColor
                )
                .overlay {
                    Image(systemName: placeholderSystemImage)
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: Self.artworkSide, height: Self.artworkSide)
    }

    private var headerTextColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title)
                    .fontWeight(.bold)
                    .lineLimit(2)
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                        .lineLimit(2)
                }

                if let metadata, !metadata.isEmpty {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
                        .lineLimit(1)
                }

                Spacer().frame(height: 2)

                if let description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                        .lineLimit(Self.visibleDescriptionLines)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: Self.artworkSide - GlassStyleTokens.headerControlHeight - 14,
                alignment: .topLeading
            )
            .clipped()

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if let onPlay {
                    HeaderStylePlayButton(canPlay: canPlay, action: onPlay)
                }
                trailingControls()
            }
        }
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            minHeight: Self.artworkSide,
            maxHeight: Self.artworkSide,
            alignment: .leading
        )
    }
}

/// The accent "播放" capsule, copied from `HeaderPlayButton`.
///
/// Omitted (not drawn disabled) where it does not apply, because a disabled
/// capsule still reads as a control.
struct HeaderStylePlayButton: View {

    let canPlay: Bool
    var title: String = "播放"
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(colorScheme == .dark ? 0.95 : 0.90))
            .padding(.horizontal, 16)
            .frame(height: GlassStyleTokens.headerControlHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .background(Capsule().fill(themeStore.accentColor))
        .background(Capsule().fill(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08)))
        .glassEffect(.clear, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
        .clipShape(Capsule())
    }
}

// MARK: - States

/// Loading, empty and error states, matching the library pages' wording.
struct QQMusicListStateView: View {

    enum Kind {
        case loading(String)
        case empty(String, systemImage: String)
        case error(String, retry: () -> Void)
    }

    let kind: Kind
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        VStack(spacing: 10) {
            switch kind {
            case .loading(let text):
                ProgressView()
                Text(text)
                    .font(.callout)
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
            case .empty(let text, let systemImage):
                Image(systemName: systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
            case .error(let text, let retry):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("重试", action: retry)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
