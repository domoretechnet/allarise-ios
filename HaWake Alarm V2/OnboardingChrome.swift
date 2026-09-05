//
//  OnboardingChrome.swift
//  HaWake Alarm V2
//
//  The shared look of the first-run screens — the blurred-wallpaper backdrop,
//  the centred icon-and-title hero, the Liquid Glass cards, and the
//  "highlight the thing you skipped" nudge.
//
//  Extracted so the permissions screen (`OnboardingView`) and the data
//  preferences screen (`DataPreferencesView`) are the same screen wearing
//  different content, rather than two screens that merely resemble each other
//  until one of them is edited.
//

import SwiftUI
import UIKit

// MARK: - Backdrop

/// Wallpaper, BLURRED, under a scrim that ramps to nearly solid.
///
/// A first attempt kept the image sharp under an even ~0.7 scrim and the result
/// was washed out: body text sat on busy, high-contrast imagery, and in light
/// mode grey `.secondary` type over a pale hazy field had almost no contrast.
/// Two fixes, both needed:
///
///  • BLUR removes the high-frequency detail that competes with text while
///    keeping the wallpaper's color and mood — the same reason iOS blurs
///    artwork behind Now Playing rather than dimming it.
///  • The scrim RAMPS: light at the very top where only the icon and a bold
///    large title sit (both survive over imagery), then near-solid from the body
///    copy down. Text gets a calm field; the picture still reads.
struct OnboardingBackdrop: View {
    let accent: Color
    let isDark: Bool

    /// The home wallpaper for the current appearance — the same image and
    /// resolution path the alarm list uses. AppDelegate seeds the built-in
    /// presets before any of this renders, so it exists on first launch.
    static func wallpaper(for settings: DeviceSettings, isDark: Bool) -> UIImage? {
        guard settings.homeWallpaperEnabled else { return nil }
        return settings.loadWallpaper(for: settings.activeHomeWallpaperKey(forDark: isDark))
    }

    var wallpaper: UIImage?

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                if let wallpaper {
                    Image(uiImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: 24, opaque: true)
                } else {
                    LinearGradient(
                        colors: [accent.opacity(0.55), accent.opacity(0.2),
                                 isDark ? .black : .white],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .ignoresSafeArea()

            LinearGradient(
                stops: isDark
                    ? [.init(color: .black.opacity(0.30), location: 0.00),
                       .init(color: .black.opacity(0.62), location: 0.22),
                       .init(color: .black.opacity(0.88), location: 0.45),
                       .init(color: .black.opacity(0.94), location: 1.00)]
                    // LIGHT mode runs thinner than dark: a white scrim washes a
                    // pale wallpaper out to near-nothing long before it stops
                    // being legible, so the picture is left more visible here
                    // and legibility is bought back with darker text
                    // (`onboardingSecondary`) instead of more white.
                    : [.init(color: .white.opacity(0.28), location: 0.00),
                       .init(color: .white.opacity(0.60), location: 0.22),
                       .init(color: .white.opacity(0.80), location: 0.45),
                       .init(color: .white.opacity(0.88), location: 1.00)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

// MARK: - Text colors

/// Secondary copy on the onboarding screens.
///
/// `.secondary` is roughly 60% of the label colour, which is fine on a flat
/// background but too faint over a wallpaper — especially in light mode, where
/// the scrim is deliberately thin. Dark mode keeps the system colour; light mode
/// goes darker than `.secondary` so the thinner scrim doesn't cost readability.
func onboardingSecondary(_ isDark: Bool) -> Color {
    isDark ? Color.secondary : Color.black.opacity(0.78)
}

// MARK: - Hero

/// Centred app icon, title and subtitle. Centred hero over left-aligned cards:
/// the icon and title are the screen's one focal point and belong on the axis,
/// while the card copy is reading material and belongs ranged left.
struct OnboardingHero: View {
    let title: String
    let subtitle: String
    var iconSize: CGFloat = 88
    let isDark: Bool

    var body: some View {
        VStack(spacing: 14) {
            // The OPPOSITE variant to the current appearance. AppIconDisplay
            // ships light/dark luminosity appearances, and each one disappears
            // against a backdrop of its own tone — the black-backed icon vanishes
            // into a dark scrim, the white-backed one into a light one. Inverting
            // keeps it reading as a physical app tile in both modes. Forcing the
            // environment's colorScheme is what picks the variant; it affects
            // nothing else in this subtree.
            Image("AppIconDisplay")
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.227, style: .continuous))
                .environment(\.colorScheme, isDark ? .light : .dark)
                .shadow(color: .black.opacity(isDark ? 0.5 : 0.18), radius: 12, y: 6)

            VStack(spacing: 8) {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(onboardingSecondary(isDark))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Glass card

extension View {
    /// Liquid Glass, rounded like a Lock Screen notification — the same
    /// `.glassEffect` the Notes command squares and player bubbles use, so these
    /// are the app's existing glass rather than a new material.
    func onboardingGlassCard(isDark: Bool) -> some View {
        self
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .shadow(color: .black.opacity(isDark ? 0.35 : 0.12), radius: 10, y: 4)
    }

    /// The "you skipped this" emphasis: a restrained tint and border, no color,
    /// no glow. Used for the required terms row and for the optional analytics
    /// card — see `NudgeState` for why the two behave differently.
    func onboardingAttention(_ active: Bool, cornerRadius: CGFloat = 12) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(active ? 0.08 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(active ? 0.38 : 0), lineWidth: 1)
                )
        )
    }
}

// The terms row's highlight-and-shake lives in OnboardingView, where it belongs:
// terms are REQUIRED, so that nudge repeats and never lets Continue through.
// The optional analytics prompt deliberately does NOT share it — an explainer
// dialog with two equal one-tap choices replaced the shake there, so declining
// costs no more effort than accepting. See DataPreferencesView.
