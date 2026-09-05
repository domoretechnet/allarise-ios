//
//  ThemedContentCard.swift
//  HaWake Alarm V2
//
//  The shared "content on a card, theme photo around it" surface, plus the shared
//  full-width primary action button.
//
//  Introduced on the MQTT alert screen and lifted here so the after-alarm Notes
//  page and the Home Assistant screens paint the same thing. The alternative the
//  app used before — text sitting DIRECTLY on the wallpaper under a heavy dark
//  scrim — meant every one of those screens had to dim its own wallpaper into
//  mud to keep white text legible. A card lets the photo stay bright around the
//  edges and carries the text on an opaque surface instead.
//

import SwiftUI

// MARK: - Card surface

/// The card's background: an opaque fill, a faint accent wash, a thin accent
/// border, and — in dark mode only — an outside accent glow.
///
/// Glow is a dark-mode device: a halo needs darkness around it to read as light.
/// On the light theme the same halo just smears the accent across a pale surface,
/// so light mode goes completely flat.
struct ThemedCardSurface: View {
    let accent: Color
    var cornerRadius: CGFloat = 24

    @Environment(\.colorScheme) private var colorScheme

    /// The card's opaque fill. Light mode gets a flat, desaturated grey rather
    /// than the near-white `.secondarySystemBackground`, which read as a bright
    /// glossy panel punched out of the wallpaper. Dark mode keeps the system
    /// surface.
    ///
    /// Exposed as a static so content that needs to punch a hole in itself — a
    /// badge knocked out of a glyph — can match the card exactly instead of
    /// guessing at `systemBackground`.
    static func fill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground)
            : Color(white: 0.88)
    }

    private var glowsEnabled: Bool { colorScheme == .dark }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(Self.fill(for: colorScheme))
            .overlay(shape.fill(accent.opacity(glowsEnabled ? 0.10 : 0.04)))
            .overlay(shape.strokeBorder(accent.opacity(glowsEnabled ? 0.45 : 0.30), lineWidth: 1.5))
            // Restrained on purpose. At 0.30/18 the halo spilled well past the
            // card and read as the card leaking light into the wallpaper,
            // especially in the gap above the primary button.
            .shadow(
                color: glowsEnabled ? accent.opacity(0.16) : .clear,
                radius: glowsEnabled ? 10 : 0,
                y: glowsEnabled ? 3 : 0
            )
    }
}

extension View {
    /// Puts this content on a `ThemedCardSurface`. The content is clipped to the
    /// card shape but the SURFACE is not, so the dark-mode glow still spills
    /// outside the edge.
    func themedCard(accent: Color, cornerRadius: CGFloat = 24) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(ThemedCardSurface(accent: accent, cornerRadius: cornerRadius))
    }
}

// MARK: - Primary action button

/// The app's full-width primary action button — the alert screen's Dismiss, the
/// Notes page's Continue, the HA fallback's manual Dismiss.
///
/// The hairline rim and drop shadow are load-bearing: the theme's button color
/// and its wallpaper come from the same preset, so they usually sit in the same
/// hue family. Fill alone leaves the button no edge to read against.
struct PrimaryActionLabel: View {
    let title: String
    let fill: Color

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            )
    }
}
