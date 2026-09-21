//
//  QQMusicShelf.swift
//  kmgccc_player
//
//  Horizontal card shelf for the QQ Music home layout.
//
//  Mirrors the app's own home page so the online browse surface reads as part
//  of the same application rather than a separate tool. The shelf itself is
//  `HorizontalFadeScrollContainer`, which is the same primitive the library's
//  home sections use, so scrolling, edge behaviour and the scroll buttons match
//  without reimplementation.
//
//  Layout numbers are taken from `HomeAlbumsSection` deliberately: matching a
//  neighbouring section's card size and spacing is what makes two pages look
//  like one app, and inventing new values would only approximate that.
//

import SwiftUI

/// A titled row of horizontally scrolling cards, with a "see all" affordance.
struct QQMusicShelf<Card: View>: View {

    let title: String
    /// Destination shown by the trailing button; nil hides it (a shelf whose
    /// content is already complete, or has no list page).
    let seeAllTitle: String?
    let onSeeAll: (() -> Void)?
    let cardCount: Int
    @ViewBuilder var cards: () -> Card

    /// Matches the library's home sections at `medium` width.
    private let cardSize: CGFloat = 146
    private let rowSpacing: CGFloat = 14
    private let horizontalPadding: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if cardCount == 0 {
                placeholder
            } else {
                HorizontalFadeScrollContainer(
                    spacing: rowSpacing,
                    fadeWidth: 0,
                    verticalPadding: 8,
                    leadingScrollPadding: horizontalPadding,
                    trailingScrollPadding: horizontalPadding,
                    showsEdgeFade: false,
                    showsScrollButtons: true,
                    scrollButtonLeadingInset: horizontalPadding - 4,
                    scrollButtonTrailingInset: horizontalPadding - 4
                ) {
                    cards()
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if let onSeeAll, let seeAllTitle {
                Button(action: onSeeAll) {
                    HStack(spacing: 2) {
                        Text(seeAllTitle)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, horizontalPadding)
    }

    /// Shown while a shelf has nothing yet, so the page does not jump as each
    /// section fills in.
    private var placeholder: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("加载中…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(height: cardSize * 0.7)
        .padding(.horizontal, horizontalPadding)
    }
}

/// A shelf card: artwork above, two lines of text below.
///
/// One card type for every shelf, with the artwork supplied by the caller. That
/// is what lets a playlist, an album, a region and the liked-songs entry share
/// a layout while each shows something different in the artwork slot.
struct QQMusicShelfCard<Artwork: View>: View {

    let title: String
    let subtitle: String
    let size: CGFloat
    let onOpen: () -> Void
    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                artwork()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Artwork stand-ins for shelves whose entries have no cover.
enum QQMusicShelfArtwork {

    /// The liked-songs entry has no playlist cover. A hollow heart on a clear
    /// background says "this is your favourites" without inventing an image.
    struct LikedHeart: View {
        let size: CGFloat

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                Image(systemName: "heart")
                    .font(.system(size: size * 0.34, weight: .regular))
                    .foregroundStyle(Color.secondary)
            }
            .frame(width: size, height: size)
        }
    }

    /// A region has no cover either; its name stands in for one.
    struct TextCover: View {
        let text: String
        let size: CGFloat

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                Text(text)
                    .font(.system(size: max(12, size * 0.15), weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.primary)
                    .padding(6)
            }
            .frame(width: size, height: size)
        }
    }
}
