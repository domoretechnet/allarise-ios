//
//  ThemeAccentStore.swift
//  HaWake Alarm V2
//
//  The user's chosen accent color, remembered PER THEME and PER APPEARANCE.
//
//  Three things shape this file.
//
//  1. IT IS A SIDECAR, NOT PART OF THE THEME. Applying a wallpaper preset
//     overwrites `DeviceSettings.homeColorCustomization` wholesale
//     (`applyPreset` → `preset.lightColorCustomization ?? .default`), so an
//     accent stored *inside* that struct would be wiped the next time the same
//     theme was re-tapped. Keeping the overrides in their own dictionary means
//     switching away to another theme and back returns the accent the user
//     picked for it — which is exactly what "persistent for each theme it's set
//     on" has to mean.
//
//  2. ABSENCE MEANS "UNCHANGED". No entry for a key resolves to the theme's own
//     accent (`HomeColorCustomization.resolvedAccentColor`), so an existing user
//     who never opens the picker sees precisely what they saw before. There is
//     no migration and no default value written at launch.
//
//  3. THE KEY IS NEW. `themeAccentByTheme` has never existed; nothing else reads
//     or writes it. Per the persisted-keys rule in CLAUDE.md this is an addition
//     alongside `homeColorCustomization` / `homeColorCustomizationDark`, never a
//     repurposing of either.
//

import Foundation
import SwiftUI

/// Per-theme, per-appearance accent overrides.
///
/// Storage is one JSON dictionary keyed `"<themeID>|light"` / `"<themeID>|dark"`,
/// where `<themeID>` is the applied home preset's UUID string. Both halves take
/// their `UserDefaults` as a parameter so tests never touch `.standard`.
enum ThemeAccentStore {

    /// UserDefaults key — the whole override map, JSON-encoded. Additive: no
    /// previous build wrote this key, so an older app simply ignores it and a
    /// newer app finds nothing and falls back to the theme accent.
    static let defaultsKey = "themeAccentByTheme"

    /// Stands in for `appliedHomePresetID` when no saved theme is applied — the
    /// user has been hand-editing wallpapers, or reset the theme. Their accent
    /// choice still has to persist, so "no theme" is a theme slot of its own
    /// rather than a case where the picker silently forgets.
    static let unsavedThemeID = "custom"

    // MARK: - Key mapping

    /// The storage key for one (theme, appearance) pair.
    ///
    /// A nil, empty, or whitespace-only preset ID collapses to `unsavedThemeID`
    /// so those three can never produce three different buckets for what the
    /// user experiences as one state.
    static func storageKey(presetID: String?, isDark: Bool) -> String {
        let trimmed = presetID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let theme = trimmed.isEmpty ? unsavedThemeID : trimmed
        return "\(theme)|\(isDark ? "dark" : "light")"
    }

    /// Convenience over `storageKey(presetID:isDark:)` for call sites that hold a
    /// `ColorScheme` rather than a Bool.
    static func storageKey(presetID: String?, colorScheme: ColorScheme) -> String {
        storageKey(presetID: presetID, isDark: colorScheme == .dark)
    }

    // MARK: - Pure lookup

    /// The override for one (theme, appearance) pair inside an already-loaded map.
    /// Split out from storage so the fallback rule is testable without defaults.
    static func accent(in map: [String: CodableColor], presetID: String?, isDark: Bool) -> CodableColor? {
        map[storageKey(presetID: presetID, isDark: isDark)]
    }

    /// `map` with `color` set for the pair, or the entry removed when `color` is
    /// nil — the "reset to theme default" case. Removal rather than storing the
    /// theme's current accent, so a later edit to the theme still shows through.
    static func setting(_ color: CodableColor?,
                        in map: [String: CodableColor],
                        presetID: String?,
                        isDark: Bool) -> [String: CodableColor] {
        var result = map
        let key = storageKey(presetID: presetID, isDark: isDark)
        if let color {
            result[key] = color
        } else {
            result.removeValue(forKey: key)
        }
        return result
    }

    // MARK: - Storage

    static func load(defaults: UserDefaults = .standard) -> [String: CodableColor] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: CodableColor].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// Writes the map, removing the key entirely when it is empty so a user who
    /// resets every theme leaves no residue behind.
    static func save(_ map: [String: CodableColor], defaults: UserDefaults = .standard) {
        guard !map.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(map) else {
            // A silent return here would drop the user's pick on the floor
            // (al-b9k) — make the failure findable in the app log. No success
            // log: with the live custom well this runs per drag tick.
            let count = map.count
            Task { @MainActor in
                AppLogger.shared.log("Theme accent save FAILED to encode \(count) entries", category: .general)
            }
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Wipes every override. Called by "Reset All Settings".
    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
