//
//  CommandPalette.swift
//  HaWake Alarm V2
//
//  The command form's icon and color PALETTE: what is offered, what the user
//  reached for last, and the pieces both grids are built from.
//
//  Three rules shape this file.
//
//  1. RECENTS ARE THEIR OWN GROUP. The form shows a small "Recent" row of the
//     user's own last choices, then a short slice of the catalog beneath it.
//     The slice deliberately EXCLUDES whatever Recent is already showing, so no
//     tile appears twice on the collapsed screen.
//
//  2. EVERYTHING ELSE IS ONE TAP DOWN, NOT ONE SCREEN AWAY. The full catalog
//     (~160 symbols, 36 named colors, the custom color well) expands INLINE
//     under a "More" row shaped like the Home Assistant section's expander in
//     Settings. There used to be two pushed pickers here; they were replaced
//     because a Form row that navigates draws a stray disclosure chevron next
//     to its label (ROCK18), and because a second screen hid the catalog behind
//     a decision the user had to make before they could look.
//
//  3. NOTHING HERE IS A CONTRACT. Recents are a convenience stored in
//     UserDefaults; losing them costs the user one extra tap. What IS a
//     contract — the twelve original color names, the stored RGB triple, the
//     free-form `icon` string — lives in `MQTTCommand` and is untouched by any
//     of this. See the notes on `MQTTCommand.presetColors`.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Recents

/// Most-recently-used icon and color memory for the command form.
///
/// Split into a pure ordering half (`pushed`, `visibleRecents`, `inlineSlice` —
/// no storage, fully testable) and a thin UserDefaults half. Both halves take
/// their storage as a parameter so tests never touch the user's real defaults.
enum CommandPaletteRecents {

    /// How many recent choices are remembered per kind. A little more than the
    /// Recent row can show (five icons, six colors), so a choice that scrolls
    /// off the row is still remembered if the one in front of it is re-picked.
    static let memoryLimit = 8

    // MARK: Persisted keys
    //
    // Both are plain `[String]` arrays: SF Symbol names for icons, preset color
    // NAMES for colors. Names rather than RGB so a stored recent survives any
    // future tweak to a preset's exact triple, and so an unknown entry is
    // trivially filtered out rather than rendering as a mystery swatch.

    /// UserDefaults key — recent SF Symbol names, most recent first.
    static let iconsKey = "commandPaletteRecentIcons"
    /// UserDefaults key — recent preset color names, most recent first.
    static let colorsKey = "commandPaletteRecentColors"
    /// UserDefaults key — recent colors as `RRGGBB` hex, most recent first.
    ///
    /// Added alongside `colorsKey` (never replacing it) so a CUSTOM color the
    /// user mixed — which has no preset name to key by — is remembered too. Hex
    /// rather than name because the whole point is that a nameless color survives
    /// here; the name list stays for anything that still reads it. Like the name
    /// list this is a convenience, not a contract (see the file header).
    static let colorHexKey = "commandPaletteRecentColorHex"

    // MARK: - Pure ordering

    /// `value` moved to the front of `list`, deduplicated, capped at `limit`.
    /// Blank values are ignored rather than stored, so a half-built command
    /// can't put an empty tile at the front of the grid.
    static func pushed(_ value: String, onto list: [String], limit: Int = memoryLimit) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return Array(list.prefix(max(limit, 0))) }
        var result = list.filter { $0 != trimmed }
        result.insert(trimmed, at: 0)
        return Array(result.prefix(limit))
    }

    /// The Recent group's contents: the stored list, filtered to what the
    /// catalog still offers, deduplicated, and capped at the row's width.
    ///
    /// A recent that is no longer in the catalog (a symbol dropped by an OS
    /// update, a color name that went away) is skipped rather than rendered —
    /// a missing SF Symbol draws nothing at all, which reads as a broken app.
    static func visibleRecents(_ recents: [String], catalog: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let known = Set(catalog)
        var seen = Set<String>()
        var result: [String] = []
        for value in recents where known.contains(value) && seen.insert(value).inserted {
            result.append(value)
            if result.count == limit { break }
        }
        return result
    }

    /// The catalog slice shown under the Recent group while the section is
    /// collapsed: the catalog's own order, minus anything Recent is already
    /// showing, truncated to `limit`.
    ///
    /// `selected` is guaranteed a slot whenever the slice is the only place it
    /// could appear, so the current choice always wears its checkmark on the
    /// collapsed screen — including right after it was picked from the expanded
    /// catalog. When Recent is already showing the selection, the slice owes it
    /// nothing and keeps its own order.
    static func inlineSlice(catalog: [String],
                            excluding shown: [String],
                            selected: String?,
                            limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let hidden = Set(shown)
        var seen = Set<String>()
        var pool: [String] = []
        for value in catalog where !hidden.contains(value) && seen.insert(value).inserted {
            pool.append(value)
        }

        let result = Array(pool.prefix(limit))
        guard let selected,
              !hidden.contains(selected),
              pool.contains(selected),
              !result.contains(selected) else { return result }

        // The selection losing its checkmark is worse than the last catalog
        // entry losing its slot.
        return Array(pool.prefix(limit - 1)) + [selected]
    }

    // MARK: - Storage

    static func recentIcons(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: iconsKey) ?? []
    }

    static func recentColorNames(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: colorsKey) ?? []
    }

    /// Recent colors as `RRGGBB` hex, most recent first. This is the list the
    /// pickers actually render — it holds preset picks and custom mixes alike.
    static func recentColorHexes(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: colorHexKey) ?? []
    }

    static func recordIcon(_ icon: String, defaults: UserDefaults = .standard) {
        defaults.set(pushed(icon, onto: recentIcons(defaults: defaults)), forKey: iconsKey)
    }

    static func recordColorName(_ name: String, defaults: UserDefaults = .standard) {
        defaults.set(pushed(name, onto: recentColorNames(defaults: defaults)), forKey: colorsKey)
    }

    /// Remembers a color by its RGB, whether or not it is a named preset. The
    /// custom color well and the theme accent picker both feed this so a mixed
    /// color the user liked is one tap away next time.
    static func recordColorHex(red: Double, green: Double, blue: Double,
                               defaults: UserDefaults = .standard) {
        let hex = commandColorHex(red: red, green: green, blue: blue)
        defaults.set(pushed(hex, onto: recentColorHexes(defaults: defaults)), forKey: colorHexKey)
    }

    /// Records the color a command actually used. The hex list remembers EVERY
    /// color, custom included (that is the whole reason it exists); the older
    /// name list is still kept for a named preset so anything reading it keeps
    /// working.
    static func record(icon: String,
                       colorRed: Double,
                       colorGreen: Double,
                       colorBlue: Double,
                       defaults: UserDefaults = .standard) {
        recordIcon(icon, defaults: defaults)
        recordColorHex(red: colorRed, green: colorGreen, blue: colorBlue, defaults: defaults)
        if let name = MQTTCommand.presetColorName(red: colorRed, green: colorGreen, blue: colorBlue) {
            recordColorName(name, defaults: defaults)
        }
    }

    /// Wipes every list. Called by "Reset All Settings" — a user who wiped the
    /// app shouldn't still be shown the icons or colors of the commands they
    /// deleted.
    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: iconsKey)
        defaults.removeObject(forKey: colorsKey)
        defaults.removeObject(forKey: colorHexKey)
    }

    // MARK: - Recent color rendering

    /// One remembered color, resolved from stored hex for a picker to draw. The
    /// preset `name` is filled in when the hex lands on a named color, so a
    /// remembered "Teal" still reads as Teal while a custom mix reads as custom.
    struct RecentColor: Identifiable {
        let hex: String
        let color: Color
        let r: Double
        let g: Double
        let b: Double
        let name: String?
        var id: String { hex }
    }

    /// The recent-color row's contents: each hex parsed, normalised, and
    /// deduplicated in stored order, capped at the row width. Unparseable or
    /// repeated entries are skipped rather than drawn, the same way a dropped SF
    /// Symbol is skipped in `visibleRecents`.
    static func recentColors(_ hexes: [String], limit: Int) -> [RecentColor] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var result: [RecentColor] = []
        for raw in hexes {
            guard let parsed = commandColorFromHex(raw) else { continue }
            let key = commandColorHex(red: parsed.r, green: parsed.g, blue: parsed.b)
            guard seen.insert(key).inserted else { continue }
            let name = MQTTCommand.presetColorName(red: parsed.r, green: parsed.g, blue: parsed.b)
            result.append(RecentColor(hex: key, color: parsed.color,
                                      r: parsed.r, g: parsed.g, b: parsed.b, name: name))
            if result.count == limit { break }
        }
        return result
    }
}

// MARK: - Color <-> components

/// The RGB triple behind a SwiftUI `Color`, clamped to 0…1. Used by the custom
/// color well, whose output has to land in the same three stored Doubles that
/// every preset and every `color_r`/`color_g`/`color_b` payload writes.
func commandColorComponents(of color: Color) -> (r: Double, g: Double, b: Double) {
    #if canImport(UIKit)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
        let clamp = { (value: CGFloat) in Double(min(max(value, 0), 1)) }
        return (clamp(r), clamp(g), clamp(b))
    }
    #endif
    return (0.0, 0.47, 1.0)
}

/// An RGB triple as an uppercase `RRGGBB` string — the storage form of a recent
/// color. Rounding to 8 bits per channel is deliberate: two colors that render
/// identically collapse to one recent instead of two near-duplicates.
func commandColorHex(red: Double, green: Double, blue: Double) -> String {
    func channel(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
    return String(format: "%02X%02X%02X", channel(red), channel(green), channel(blue))
}

/// Parses `RRGGBB` (with or without a leading `#`) back into a color and its
/// triple. Returns nil for anything that isn't six hex digits, so a stray stored
/// value is dropped rather than drawn as a mystery swatch.
func commandColorFromHex(_ hex: String) -> (color: Color, r: Double, g: Double, b: Double)? {
    var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if cleaned.hasPrefix("#") { cleaned.removeFirst() }
    guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
    let r = Double((value >> 16) & 0xFF) / 255
    let g = Double((value >> 8) & 0xFF) / 255
    let b = Double(value & 0xFF) / 255
    return (Color(red: r, green: g, blue: b), r, g, b)
}

// MARK: - Shared tiles

/// One icon tile — the same 44pt square whether it is in the Recent row, the
/// inline slice, or the expanded catalog.
struct CommandIconTile: View {
    let icon: String
    let isSelected: Bool
    /// The command's own color, used as the selected background so the tile
    /// previews exactly how the command will render.
    let iconColor: Color

    var body: some View {
        Image(systemName: icon)
            .font(.title3)
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? iconColor : Color(uiColor: .tertiarySystemFill))
            )
            .foregroundStyle(isSelected ? .white : .primary)
    }
}

/// One color swatch — the same 36pt circle in a 44pt tap target everywhere.
struct CommandColorSwatch: View {
    let color: Color
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 36, height: 36)
            .frame(width: 44, height: 44)
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                }
            }
    }
}

/// The small group label inside a palette section — "Recent", "Standard", a
/// category name. A caption rather than a Section header because these all live
/// inside ONE Form section; splitting them into real sections would put a full
/// inset-grouped card around every category.
struct CommandPaletteCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The expand/collapse row that ends each palette grid: a slim, full-width
/// chevron + "More" that reveals the rest of the catalog IN PLACE.
///
/// Deliberately the same shape and weight as `SettingsView.haExpandRow`, which
/// is where the user first meets this affordance — one gesture, one look, two
/// screens.
struct CommandPaletteMoreRow: View {
    let isExpanded: Bool
    /// What the row reveals, for VoiceOver: "icons", "colors".
    let subject: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    // The toggle itself is deliberately un-animated (a Form row
                    // can't animate a full-catalog height change cleanly), so
                    // the chevron carries its own rotation animation.
                    .animation(.smooth(duration: 0.25), value: isExpanded)
                Text(isExpanded ? "Less" : "More")
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            // Explicit height: the glyph needs vertical room, and the whole
            // strip — not just the chevron — has to be the tap target. The
            // extra top padding separates the row from the grid above it;
            // it stays inside the button so it remains tappable.
            .padding(.top, 10)
            .frame(height: 44, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Show fewer \(subject)" : "Show more \(subject)")
    }
}
