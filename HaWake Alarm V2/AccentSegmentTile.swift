//
//  AccentSegmentTile.swift
//  HaWake Alarm V2
//
//  THE app's segmented chooser: equal-width accent tiles, each with a glyph and
//  a label, standing at the same height as the mission / snooze / skip mode
//  tiles. Used wherever a screen offers two or three mutually exclusive modes.
//
//  Extracted because four screens had independently grown their own version of
//  this control — the command picker's Home Assistant / Shortcuts filter, the
//  command form's type tabs, the Sound Manager's Alarm Tones / Sleep Sounds
//  categories (a stock `.segmented` Picker, which also silently drops Label
//  icons), and the radio browser's Top / Near You scopes. They matched in
//  spirit and differed in height, padding, and font, which is exactly the kind
//  of drift a shared component prevents.
//
//  `selectableTile` still owns the selected/unselected background so these stay
//  in the same pastel-tile family as the rest of the app.
//

import SwiftUI

struct AccentSegmentTile: View {
    let title: String
    /// SF Symbol shown before the title. nil for choosers whose options don't
    /// have a meaningful glyph (Arm / Disarm / Toggle).
    var systemImage: String? = nil
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    /// Shared height — the same 58pt the mission, snooze, and skip mode tiles
    /// use, so every mode chooser in the app stands the same height. Callers
    /// that need to reserve space (a grid row, a fixed-height container) should
    /// read this rather than hardcoding a number.
    static let height: CGFloat = 58

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.footnote)
                }
                Text(title)
                    .font(.callout.weight(.semibold))
                    // The long ones ("Home Assistant", "Shortcut / Link") shrink
                    // rather than wrap or truncate.
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? accent : Color.primary)
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .selectableTile(isSelected: isSelected, accent: accent, cornerRadius: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Standard spacing for a row of `AccentSegmentTile`s, so the gap between tiles
/// is the same on every screen too.
struct AccentSegmentRow<Content: View>: View {
    @ViewBuilder var content: Content

    static var spacing: CGFloat { 8 }

    var body: some View {
        HStack(spacing: Self.spacing) {
            content
        }
    }
}
