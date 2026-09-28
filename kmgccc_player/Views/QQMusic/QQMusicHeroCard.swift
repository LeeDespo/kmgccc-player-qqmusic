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
//  none of that until it has been downloaded.
//
//  Everything the eye reads is the app's:
//
//    * the **backdrop** is `CoverGradientBlurRenderer` with `HomeHeroView`'s
//      config — a full-bleed blurred cover with a crisp leading square and a
//      colour overlay — rather than a photo behind a scrim, which is what makes
//      the app's hero read as a surface;
//    * the **ink adapts to that backdrop**: the app analyses the artwork, builds
//      a luminance map of the rendered composite, samples the three regions
//      where text actually falls (title block, buttons, stats), and picks the
//      Plus Lighter / Plus Darker text profile that survives them. Hence white
//      text on a dark cover and dark text on a pale one, decided by measurement
//      rather than by assuming a cover is dark;
//    * the **stats line** bottom-trailing — duration, then how often the library
//      has played it — exactly as the app's hero reports its own;
//    * the **buttons** use the hero's own glass capsule / circle chrome, shared
//      with `HomeHeroView` rather than redrawn (one definition of that surface);
//    * title, artist line and the catalogue's 简介 sit where the app puts them,
//      the description drawn with the app's `AppKitFullTextScrollView` and a
//      click that opens the full 歌曲描述 reader.
//
//  The two actions are what make sense for a track that exists online: 播放 and
//  换一首.
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
    @Environment(AppSettings.self) private var appSettings

    @State private var description: String?
    @State private var playCount = 0
    @State private var isHovering = false

    // Backdrop and its readability inputs, in the app's shape: the composite,
    // the luminance map built from it, and the artwork analysis behind the
    // palette the candidate foregrounds come from.
    @State private var backdrop: CGImage?
    @State private var readabilityMap: RenderedBackdropReadabilityMap?
    @State private var backdropLayoutSize: CGSize = .zero
    @State private var artworkAnalysis: ArtworkColorAnalysis?

    /// The palette this card's own artwork produced.
    ///
    /// Cached rather than computed in `body`: the factory derives 13+ semantic
    /// role colours per call, and the foreground accessors below are read many
    /// times per body run, so a per-body call would melt the CPU during a live
    /// resize. Recomputed only from the `onChange` guards at the end of `body`.
    @State private var paletteCache: SemanticPalette = SemanticPaletteFactory.make(
        from: .neutralFallback,
        scheme: .light,
        userFallbackAccent: .systemBlue,
        useArtworkTint: false
    )

    /// Local polarity of the rendered composite, and the decision behind it.
    /// Nil until the first map exists, which is why the fallback is light ink:
    /// an unmeasured card must not flash dark text over a dark cover.
    @State private var localPolarity: ArtworkForegroundPolarity?
    @State private var localDecision: LocalForegroundDecision?

    // MARK: - Metrics (HomeHeroView's)

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

    /// How far past the wide layout's floor this card has grown, `0...1`.
    /// `HomeHeroView` scales its type, its top padding and its buttons by this,
    /// so a wide window gets a proportionally bigger banner instead of a thin
    /// strip with small text on it.
    private var wideExpansion: CGFloat {
        guard mode == .wide else { return 0 }
        return min(max((containerWidth - 920) / 520, 0), 1)
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
        case .wide: return 36 + wideExpansion * 8
        case .medium: return 36
        case .compact: return 28
        case .narrow: return 24
        }
    }

    private var titleFontSize: CGFloat {
        let extra = wideExpansion * 5
        switch mode {
        case .wide: return 31 + extra
        case .medium: return 27
        case .compact: return 23
        case .narrow: return 20
        }
    }

    private var subtitleFontSize: CGFloat { mode == .narrow ? 12 : 14 }

    private var actionBottomPadding: CGFloat {
        switch mode {
        case .wide, .medium: return 8
        case .compact: return 6
        case .narrow: return 4
        }
    }

    private var heroButtonHeight: CGFloat {
        switch mode {
        case .wide: return 36 + wideExpansion * 8
        case .medium: return 36
        case .compact: return 34
        case .narrow: return 32
        }
    }

    private var heroButtonHorizontalPadding: CGFloat {
        switch mode {
        case .wide: return 16 + wideExpansion * 4
        case .medium: return 16
        case .compact: return 14
        case .narrow: return 13
        }
    }

    private var heroButtonIconSize: CGFloat {
        switch mode {
        case .wide: return 12 + wideExpansion * 2
        case .medium: return 12
        case .compact: return 11
        case .narrow: return 10.5
        }
    }

    private var heroButtonTextSize: CGFloat {
        switch mode {
        case .wide: return 13 + wideExpansion * 1.5
        case .medium: return 13
        case .compact, .narrow: return 12
        }
    }

    /// The hero always reserves a square, full-height artwork column — the
    /// composite keeps that square crisp and ramps the blur past its right edge,
    /// so the text starts after it.
    private var artworkLeadingWidth: CGFloat { heroHeight }

    private var cornerRadius: CGFloat { 22 }

    private var statsTrailingPadding: CGFloat { heroPadding + 6 }
    private var statsBottomPadding: CGFloat { heroPadding + actionBottomPadding + 4 }

    /// Width of the card as laid out, falling back to the layout hint. The
    /// measured value keeps the display-side aspect fill from cropping the
    /// artwork vertically at particular window widths.
    private var layoutWidth: CGFloat {
        backdropLayoutSize.width > 1 ? backdropLayoutSize.width : max(1, containerWidth)
    }

    /// Render target matching the card's own aspect ratio, so the cover area is
    /// not cropped by a mismatched fixed size.
    private var backdropTargetSize: CGSize {
        let aspect = layoutWidth / max(1, heroHeight)
        let targetHeight: CGFloat = 380
        return CGSize(width: max(1, round(targetHeight * aspect)), height: targetHeight)
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdropLayer
                .allowsHitTesting(false)

            content
                .zIndex(1)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(GlassStyleTokens.highlightGradient, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        // The app's own hero treatment: a whisper of scale on hover, nothing else.
        .scaleEffect(isHovering ? 1.005 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .task(id: track.songMid) { await loadArtworkAndBackdrop() }
        .task(id: track.songMid) {
            description = nil
            description = await coordinator.songDescription(for: track)
            playCount = coordinator.localPlayCount(for: track.songMid)
        }
        .onAppear { recomputePalette() }
        .onChange(of: artworkAnalysis) { _, _ in recomputePalette() }
        .onChange(of: colorScheme) { _, _ in recomputePalette() }
        .onChange(of: appSettings.accentColor) { _, _ in recomputePalette() }
        .onChange(of: appSettings.globalArtworkTintEnabled) { _, _ in recomputePalette() }
        // Polarity depends on the rendered map, the candidate foregrounds (which
        // live in the palette) and the layout the sampling rectangles are built
        // from. None of those is a per-frame signal, so re-scoring here is cheap.
        .onChange(of: paletteCache) { _, _ in updateLocalPolarity() }
        .onChange(of: containerWidth) { _, _ in updateLocalPolarity() }
        .onChange(of: mode) { _, _ in updateLocalPolarity() }
    }

    // MARK: - Content

    private var content: some View {
        ZStack(alignment: .topLeading) {
            trackInfo
                .padding(.top, heroTopPadding)
                .padding(.leading, heroPadding + artworkLeadingWidth)
                .padding(.trailing, heroPadding)
                .padding(.bottom, heroPadding)
                .contentShape(Rectangle())
                .onTapGesture(perform: onPlay)
                .zIndex(1)

            statsLine
                .padding(.trailing, statsTrailingPadding)
                .padding(.bottom, statsBottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
                .zIndex(2)

            actionButtons
                .padding(.leading, heroPadding + artworkLeadingWidth)
                .padding(.bottom, heroPadding + actionBottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .zIndex(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(track.title)
                .font(.system(size: titleFontSize, weight: .semibold))
                .lineLimit(2)
                .foregroundStyle(textProfile.primaryColor)
                .compositingGroup()
                .blendMode(textProfile.blendMode)

            Text(subtitleLine)
                .font(.system(size: subtitleFontSize, weight: .medium))
                .foregroundStyle(textProfile.secondaryColor)
                .lineLimit(1)
                .compositingGroup()
                .blendMode(textProfile.blendMode)

            descriptionLine
        }
    }

    /// The catalogue's prose, drawn as the app's hero draws its description: the
    /// app's own scrolling text view, ultra-light, and tall enough to hold a few
    /// lines above the buttons.
    @ViewBuilder
    private var descriptionLine: some View {
        let text = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, descriptionScrollHeight > 0 {
            AppKitFullTextScrollView(
                text: text,
                font: NSFont.systemFont(ofSize: descriptionFontSize, weight: .ultraLight),
                textColor: NSColor(textProfile.secondaryColor),
                lineSpacing: 1.5,
                showsVerticalScroller: false,
                onClick: { coordinator.showTrackDescription(track) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: descriptionScrollHeight, alignment: .top)
            .compositingGroup()
            .blendMode(textProfile.blendMode)
            .clipped()
            .padding(.top, descriptionTopPadding)
        }
    }

    private var statsLine: some View {
        HStack(spacing: 0) {
            Text(formattedDuration)
            if playCount > 0 {
                Text(" \u{00B7} ")
                Text("\(playCount) 次播放")
            }
        }
        .font(.caption)
        .foregroundStyle(textProfile.tertiaryColor)
        .compositingGroup()
        .blendMode(textProfile.blendMode)
    }

    /// 播放 and 换一首, on the hero's own glass chrome — the same capsule and
    /// circle `HomeHeroView` builds its buttons from, and the same ink.
    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: heroButtonIconSize, weight: .semibold))
                        .foregroundStyle(buttonForeground)
                    Text("播放")
                        .font(.system(size: heroButtonTextSize, weight: .medium))
                        .foregroundStyle(textProfile.primaryColor)
                }
                .padding(.horizontal, heroButtonHorizontalPadding)
                .frame(height: heroButtonHeight)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .homeHeroHeaderGlassCapsule(colorScheme: colorScheme)
            .transaction { $0.animation = nil }

            Button(action: onSwitch) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: heroButtonIconSize, weight: .semibold))
                    .foregroundStyle(buttonForeground)
                    .frame(width: heroButtonHeight, height: heroButtonHeight, alignment: .center)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .homeHeroHeaderGlassCircle(colorScheme: colorScheme)
            .help("换一首")
            .transaction { $0.animation = nil }
        }
    }

    private var subtitleLine: String {
        var parts: [String] = [track.artist.isEmpty ? "未知歌手" : track.artist]
        if let album = track.album, !album.isEmpty { parts.append(album) }
        return parts.joined(separator: " · ")
    }

    private var formattedDuration: String {
        guard let duration = track.duration, duration > 0 else { return "--:--" }
        return String(format: "%d:%02d", duration / 60, duration % 60)
    }

    // MARK: - Description geometry

    private var descriptionFontSize: CGFloat { mode == .narrow ? 11.5 : 13 }

    private var descriptionTopPadding: CGFloat { 4 }

    /// One line's height for the current size, measured rather than assumed so
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

    /// How tall the prose block is.
    ///
    /// `HomeHeroView` fixes a line count per layout, because its action row sits
    /// below the text block. This card's buttons are on the *same* baseline as
    /// the block's last line, so the count is derived instead: whatever is left
    /// between the artist line and the top of the buttons, divided by a line's
    /// stride. The same shape as the app's (`lines × line height`, plus the
    /// inter-line spacing), with the two-line title assumed even when the title
    /// fits on one — the same worst case the app's readability regions assume.
    private var descriptionScrollHeight: CGFloat {
        let topOfButtons = heroHeight - (heroPadding + actionBottomPadding + heroButtonHeight)
        let usedAbove = heroTopPadding
            + ceil(titleFontSize * 1.2) * 2
            + 6
            + ceil(subtitleFontSize * 1.3)
            + 6
            + descriptionTopPadding
        let lineSpacing: CGFloat = 1.5
        let stride = descriptionLineHeight + lineSpacing
        let lines = Int(max(0, (topOfButtons - usedAbove) / stride))
        guard lines > 0 else { return 0 }
        return ceil(stride * CGFloat(lines) - lineSpacing + 1)
    }

    // MARK: - Readability (HomeHeroView's, measured on this card's composite)

    private var resolvedPolarity: ArtworkForegroundPolarity {
        localPolarity ?? .lightOnDarkBackground
    }

    /// The ink profile for the artwork the text actually sits on. Both variants
    /// are precomputed in the palette; this only selects one.
    private var textProfile: PlusBlendTextForegroundProfile {
        paletteCache.plusBlendText.profile(for: resolvedPolarity)
    }

    private var readabilityProfile: ArtworkReadabilityProfile {
        paletteCache.readabilityCandidates.profile(for: resolvedPolarity)
    }

    /// Icon ink, from the same readability decision as the text.
    private var buttonForeground: Color {
        ColorRenderingAdapter.makeSwiftUIColor(readabilityProfile.foregroundPrimary)
    }

    private func recomputePalette() {
        paletteCache = SemanticPaletteFactory.make(
            from: artworkAnalysis ?? .neutralFallback,
            scheme: colorScheme,
            userFallbackAccent: NSColor(appSettings.accentColor),
            useArtworkTint: appSettings.globalArtworkTintEnabled && artworkAnalysis != nil
        )
        updateLocalPolarity()
    }

    /// The three view-space rectangles where adaptive ink actually renders —
    /// track info, buttons, stats — mapped through the leading-aligned aspect
    /// fill into normalized regions of the composite.
    private var readabilityRegions: [NormalizedReadabilityRegion] {
        let viewSize = CGSize(width: layoutWidth, height: heroHeight)
        let imageSize = backdropTargetSize
        let expansion = ColorSystemTokens.ReadabilityForeground.regionExpansionPoints
        var regions: [NormalizedReadabilityRegion] = []

        func expandAndMap(_ rect: CGRect) {
            guard rect.width > 0, rect.height > 0 else { return }
            let expanded = rect.insetBy(dx: -expansion, dy: -expansion)
            if let mapped = AspectFillReadabilityMapping.map(
                viewRect: expanded,
                viewSize: viewSize,
                imageSize: imageSize,
                horizontalAlignment: .leading,
                verticalAlignment: .center
            ) {
                regions.append(mapped)
            }
        }

        let trackLeading = heroPadding + artworkLeadingWidth
        let trackWidth = max(0, layoutWidth - trackLeading - heroPadding)
        let titleHeight = ceil(titleFontSize * 1.2) * 2
        let artistHeight = ceil(subtitleFontSize * 1.3)
        let trackHeight = titleHeight + 6 + artistHeight + 6 + descriptionScrollHeight + descriptionTopPadding
        expandAndMap(CGRect(x: trackLeading, y: heroTopPadding, width: trackWidth, height: trackHeight))

        let actionBottom = heroHeight - (heroPadding + actionBottomPadding)
        let playWidth = heroButtonIconSize + 6 + 28 + 2 * heroButtonHorizontalPadding
        let actionWidth = playWidth + heroButtonHeight + 20
        expandAndMap(CGRect(
            x: trackLeading,
            y: actionBottom - heroButtonHeight,
            width: actionWidth,
            height: heroButtonHeight
        ))

        let statsWidth: CGFloat = 112
        let statsHeight: CGFloat = 16
        expandAndMap(CGRect(
            x: layoutWidth - statsTrailingPadding - statsWidth,
            y: heroHeight - statsBottomPadding - statsHeight,
            width: statsWidth,
            height: statsHeight
        ))

        return regions
    }

    /// Re-score the local polarity from the rendered map, the candidate colours
    /// and the layout. No-op until the map exists, which leaves the light-ink
    /// default in place.
    private func updateLocalPolarity() {
        guard let readabilityMap else { return }
        let regions = readabilityRegions
        guard !regions.isEmpty else { return }
        let candidates = paletteCache.readabilityCandidates
        let decision = RenderedBackdropReadability.decide(
            darkForeground: candidates.darkOnLightBackground.foregroundPrimary,
            lightForeground: candidates.lightOnDarkBackground.foregroundPrimary,
            samples: [(readabilityMap, regions)]
        )
        localDecision = decision
        // No implicit animation: blend-mode and colour tiers must not
        // interpolate through a grey middle state when the polarity flips.
        withTransaction(Transaction(animation: nil)) {
            localPolarity = decision.polarity
        }
    }

    // MARK: - Backdrop

    @ViewBuilder
    private var backdropLayer: some View {
        GeometryReader { geometry in
            Group {
                if let backdrop {
                    Image(decorative: backdrop, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                        .clipped()
                } else {
                    // Nothing rendered yet: the cover itself in the leading
                    // square, on a quiet fill — the shape the composite will
                    // have, so the card does not jump when the render lands.
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.06))
                        QQMusicArtworkView(
                            urlString: track.imageURL,
                            size: heroHeight,
                            cornerRadius: 0
                        )
                    }
                }
            }
            .onAppear { updateBackdropLayoutSize(geometry.size) }
            .onChange(of: geometry.size) { _, newSize in updateBackdropLayoutSize(newSize) }
        }
    }

    private func updateBackdropLayoutSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        guard abs(size.width - backdropLayoutSize.width) > 0.5
                || abs(size.height - backdropLayoutSize.height) > 0.5 else { return }
        backdropLayoutSize = size
    }

    private func loadArtworkAndBackdrop() async {
        backdrop = nil
        readabilityMap = nil
        artworkAnalysis = nil
        localPolarity = nil
        localDecision = nil
        guard let url = track.imageURL, !url.isEmpty, let loader = artworkLoader else { return }
        guard let data = await loader.artwork(for: url) else { return }
        guard !Task.isCancelled else { return }

        let targetSize = backdropTargetSize
        let key = "\(track.songMid)-\(Int(targetSize.width))x\(Int(targetSize.height))-qqmusic-hero-v2"
        let artifact: QQMusicHeroBackdrop?
        if let cached = QQMusicHeroBackdropCache.shared.artifact(for: key) {
            artifact = cached
        } else {
            artifact = await Task.detached(priority: .utility) { () -> QQMusicHeroBackdrop? in
                autoreleasepool {
                    guard let prepared = CoverGradientBlurRenderer.preparedArtworkImage(
                        artworkData: data,
                        artworkImage: nil,
                        targetSize: targetSize
                    ) else { return nil }
                    guard let image = CoverGradientBlurRenderer.render(
                        artworkCGImage: prepared,
                        targetSize: targetSize,
                        dominantColor: nil,
                        config: Self.blurConfig
                    ) else { return nil }
                    // The map is built here, off the main thread, from the
                    // *rendered* composite — it is that surface the ink has to
                    // survive, not the source cover.
                    return QQMusicHeroBackdrop(
                        image: image,
                        readabilityMap: RenderedBackdropReadabilityMap.make(from: image)
                    )
                }
            }.value
            if let artifact {
                QQMusicHeroBackdropCache.shared.store(artifact, for: key)
            }
        }
        guard !Task.isCancelled, let artifact else { return }

        // The palette's source: the cover's own colours, analysed off the main
        // thread because the extractor decodes and samples pixels.
        artworkAnalysis = await Task.detached(priority: .userInitiated) {
            ArtworkColorExtractor.analyze(from: data)
        }.value

        backdrop = artifact.image
        readabilityMap = artifact.readabilityMap
        recomputePalette()
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
}

/// The rendered composite plus the luminance map built from it, produced in one
/// detached task and cached together so the polarity pass never waits for the
/// map after the image is already on screen.
private struct QQMusicHeroBackdrop: @unchecked Sendable {
    let image: CGImage
    let readabilityMap: RenderedBackdropReadabilityMap?
}

/// Small in-memory cache for rendered hero backdrops.
///
/// The render is a multi-pass Core Image job, so scrolling the home page back
/// into view must not pay for it again. Same shape as the app's own
/// `HomeHeroBackdropCache`, smaller because only one card uses it.
@MainActor
private final class QQMusicHeroBackdropCache {
    static let shared = QQMusicHeroBackdropCache()

    private final class Box {
        let image: CGImage
        let readabilityMap: RenderedBackdropReadabilityMap?
        init(_ image: CGImage, _ readabilityMap: RenderedBackdropReadabilityMap?) {
            self.image = image
            self.readabilityMap = readabilityMap
        }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 6
        return cache
    }()

    func artifact(for key: String) -> QQMusicHeroBackdrop? {
        guard let box = cache.object(forKey: key as NSString) else { return nil }
        return QQMusicHeroBackdrop(image: box.image, readabilityMap: box.readabilityMap)
    }

    func store(_ artifact: QQMusicHeroBackdrop, for key: String) {
        let cost = max(1, artifact.image.bytesPerRow * artifact.image.height)
        cache.setObject(
            Box(artifact.image, artifact.readabilityMap),
            forKey: key as NSString,
            cost: cost
        )
    }
}
