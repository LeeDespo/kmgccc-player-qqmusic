//
//  QQMusicHeroCard.swift
//  kmgccc_player
//
//  The 精选 card at the top of the online home.
//
//  Every number, the layer order and the backdrop pipeline are `HomeHeroView`'s —
//  the app's own hero — because the ask was that the online home look like the
//  app's home, and a hero of one's own invention is exactly what would stop it.
//  What differs is the content model: `HomeHeroView` is built around a library
//  `Track` (playback queue, edit sheets, context menu), and an online track has
//  none of that until it has been downloaded. So this draws the same card with an
//  online track: title, artist line, and the catalogue's 简介 beneath them — the
//  app's hero shows a description there too, from the user's own note or the
//  album's — then the two actions that make sense for an online track: 播放 and
//  换一首. The description block is `HomeHeroView`'s: the app's own
//  `AppKitFullTextScrollView`, ultra-light ink, one line shorter per layout, and
//  a click that opens the full 歌曲描述 reader.
//
//  The backdrop is rendered by the app's own `CoverGradientBlurRenderer` with
//  `HomeHeroView`'s config — a full-bleed blurred cover with a crisp leading
//  square and a colour overlay — rather than a plain image behind a scrim, which
//  is what makes the app's hero read as a surface instead of as a photo.
//

import AppKit
import SwiftUI

struct QQMusicHeroCard: View {

    let track: QQMusicOnlineTrack
    /// Width of the content column, which the wide layout's height follows.
    let containerWidth: CGFloat
    let mode: HomeLayoutMode
    let onPlay: () -> Void
    let onSwitch: () -> Void

    @Environment(\.qqMusicArtworkLoader) private var artworkLoader
    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme

    @State private var backdrop: NSImage?
    @State private var description: String?
    @State private var isHovering = false

    // MARK: - Metrics (copied from HomeHeroView)

    private var baseHeroHeight: CGFloat {
        switch mode {
        case .wide: return 320
        case .medium: return 295
        case .compact: return 270
        case .narrow: return 250
        }
    }

    private var heroHeight: CGFloat {
        guard mode == .wide else { return baseHeroHeight }
        return min(max(containerWidth / 3.05, baseHeroHeight), 520)
    }

    private var heroPadding: CGFloat {
        switch mode {
        case .wide, .medium: return 20
        case .compact: return 16
        case .narrow: return 14
        }
    }

    private var heroTopPadding: CGFloat {
        switch mode {
        case .wide, .medium: return 36
        case .compact: return 28
        case .narrow: return 24
        }
    }

    private var titleFontSize: CGFloat {
        switch mode {
        case .wide: return 31
        case .medium: return 27
        case .compact: return 23
        case .narrow: return 20
        }
    }

    private var subtitleFontSize: CGFloat { mode == .narrow ? 12 : 14 }

    /// The hero always reserves a square, full-height artwork column — the
    /// composite keeps that square crisp and ramps the blur past its right edge,
    /// so the text starts after it.
    private var artworkLeadingWidth: CGFloat { heroHeight }

    private var cornerRadius: CGFloat { 22 }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdropLayer

            // Title, artist line and the catalogue's 简介, stacked exactly as
            // `HomeHeroView.trackInfoView` stacks them — the description sits
            // under the artist line and above the buttons, and is absent (taking
            // its space with it) for the many songs that have none.
            VStack(alignment: .leading, spacing: 6) {
                Text(track.title)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(subtitleLine)
                    .font(.system(size: subtitleFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)

                descriptionLine
            }
            .padding(.top, heroTopPadding)
            .padding(.leading, heroPadding + artworkLeadingWidth)
            .padding(.trailing, heroPadding)
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
                .padding(.leading, heroPadding + artworkLeadingWidth)
                .padding(.bottom, heroPadding + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(GlassStyleTokens.highlightGradient, lineWidth: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
        }
        // The app's own hero treatment: a whisper of scale on hover, nothing else.
        .scaleEffect(isHovering ? 1.005 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .task(id: track.songMid) { await loadBackdrop() }
        .task(id: track.songMid) {
            description = nil
            description = await coordinator.songDescription(for: track)
        }
    }

    // MARK: - Description

    /// A tall, scrollable block of prose, the app's hero treatment: the app's own
    /// `AppKitFullTextScrollView`, ultra-light ink, and a click that opens the
    /// full 歌曲描述 reader rather than scrolling in a card this size.
    @ViewBuilder
    private var descriptionLine: some View {
        let text = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            AppKitFullTextScrollView(
                text: text,
                font: NSFont.systemFont(ofSize: descriptionFontSize, weight: .ultraLight),
                textColor: NSColor.white.withAlphaComponent(0.78),
                lineSpacing: 1.5,
                showsVerticalScroller: false,
                onClick: { coordinator.showTrackDescription(track) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: descriptionScrollHeight, alignment: .top)
            .clipped()
            .padding(.top, 4)
        }
    }

    /// `HomeHeroView`'s numbers, one line shorter in each layout: this card's
    /// buttons sit on the same row as the description's last line (the app's hero
    /// has a taller content column), so the block is capped where it still clears
    /// them.
    private var descriptionLineCount: Int {
        switch mode {
        case .wide: return 6
        case .medium: return 5
        case .compact: return 4
        case .narrow: return 3
        }
    }

    private var descriptionFontSize: CGFloat {
        mode == .narrow ? 11.5 : 13
    }

    /// One line's height for the current size, measured rather than assumed, so
    /// the block matches the text it holds. Cached by size because building an
    /// `NSLayoutManager` per body evaluation is expensive.
    private static var lineHeightCache: [CGFloat: CGFloat] = [:]

    private var descriptionLineHeight: CGFloat {
        let size = descriptionFontSize
        if let cached = Self.lineHeightCache[size] { return cached }
        let height = NSLayoutManager().defaultLineHeight(
            for: NSFont.systemFont(ofSize: size, weight: .ultraLight)
        )
        Self.lineHeightCache[size] = height
        return height
    }

    private var descriptionScrollHeight: CGFloat {
        let lineSpacing: CGFloat = 1.5
        let lines = CGFloat(descriptionLineCount)
        return ceil(descriptionLineHeight * lines + lineSpacing * max(0, lines - 1) + 1)
    }

    // MARK: - Backdrop

    @ViewBuilder
    private var backdropLayer: some View {
        if let backdrop {
            Image(nsImage: backdrop)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: heroHeight)
                .clipped()
        } else {
            // Nothing rendered yet: the cover itself in the leading square, on a
            // quiet fill — the same shape the composite will have, so the card
            // does not jump when the render lands.
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.06))
                QQMusicArtworkView(
                    urlString: track.imageURL,
                    size: heroHeight,
                    cornerRadius: 0
                )
            }
            .frame(height: heroHeight)
        }
    }

    private func loadBackdrop() async {
        backdrop = nil
        guard let url = track.imageURL, !url.isEmpty, let loader = artworkLoader else { return }
        guard let image = await loader.image(for: url) else { return }
        let width = max(1, containerWidth)
        let height = heroHeight
        let key = "\(track.songMid)-\(Int(width))x\(Int(height))-qqmusic-hero-v1"
        if let cached = QQMusicHeroBackdropCache.shared.image(for: key) {
            backdrop = cached
            return
        }
        let rendered = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let composited = CoverGradientBlurRenderer.render(
                      artworkCGImage: cgImage,
                      targetSize: CGSize(width: width, height: height),
                      dominantColor: nil,
                      config: Self.blurConfig
                  )
            else { return nil }
            return NSImage(cgImage: composited, size: NSSize(width: width, height: height))
        }.value
        guard let rendered else { return }
        QQMusicHeroBackdropCache.shared.store(rendered, for: key)
        backdrop = rendered
    }

    /// `HomeHeroView.heroBlurConfig`, verbatim. Nonisolated because the render
    /// runs off the main actor.
    nonisolated private static let blurConfig = CoverGradientBlurConfig(
        blurRadius: 240,
        colorOverlayOpacity: 0.46,
        transitionDuration: 0.35,
        edgeStripWidth: 3.0,
        blurStartRatio: 0.08,
        blurEndRatio: 0.9,
        overlayOffsetRatio: 0.0,
        blurCurveGamma: 5.0,
        overlayCurveGamma: 3.0,
        overlayStartRatioFromEdge: 0.28,
        edgeFillMode: .pixelStretch,
        blurMaskMode: .progressiveRamp,
        blurStartRatioFromEdge: 0.30,
        blurAlphaCoefficients: (0, 0, 1.8, -0.8),
        extensionFloorStrength: 0.2
    )

    // MARK: - Content

    private var subtitleLine: String {
        var parts: [String] = [track.artist.isEmpty ? "未知歌手" : track.artist]
        if let album = track.album, !album.isEmpty { parts.append(album) }
        if let duration = track.duration, duration > 0 {
            parts.append(String(format: "%d:%02d", duration / 60, duration % 60))
        }
        return parts.joined(separator: " · ")
    }

    /// 播放 and 换一首, laid out as the app's hero lays its buttons out: a glass
    /// capsule for the primary action and a circle for the rest.
    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .semibold))
                    Text("播放").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(
                    Capsule().fill(.white.opacity(colorScheme == .dark ? 0.16 : 0.20))
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onSwitch) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(colorScheme == .dark ? 0.16 : 0.20)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("换一首")
        }
    }
}

/// Small in-memory cache for rendered hero backdrops.
///
/// The render is a multi-pass Core Image job, so scrolling the home page back
/// into view must not pay for it again. Same shape as the app's own
/// `HomeHeroBackdropCache`, smaller because only one card uses it.
@MainActor
private final class QQMusicHeroBackdropCache {
    static let shared = QQMusicHeroBackdropCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 6
        return cache
    }()

    func image(for key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    func store(_ image: NSImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}
