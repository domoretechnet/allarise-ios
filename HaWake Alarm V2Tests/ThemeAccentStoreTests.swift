//
//  ThemeAccentStoreTests.swift
//  HaWake Alarm V2Tests
//
//  The per-theme, per-appearance accent override introduced for Punchlist GEAR54.
//
//  These are pure-function tests plus a few against an isolated `UserDefaults`
//  suite — never `.standard`, so running them can't recolor the developer's own
//  app.
//
//  What they pin down:
//    • Light and dark are SEPARATE slots for the same theme, and two themes are
//      separate slots for the same appearance. That four-way independence is the
//      whole feature.
//    • Absence means "use the theme's own accent" — the guarantee that an
//      existing user who never opens the picker sees no visual change.
//    • Reset REMOVES the entry rather than freezing today's theme color into it,
//      so a later edit to the theme still shows through.
//    • nil / empty / whitespace preset IDs collapse to one bucket, so "no saved
//      theme applied" can't fan out into three different accents.
//    • An empty map leaves no residue in UserDefaults.
//

import Foundation
import SwiftUI
import UIKit
import Testing
@testable import HaWake_Alarm_V2

// MARK: - Key mapping

struct ThemeAccentStoreKeyTests {

    @Test("Light and dark are different keys for the same theme")
    func appearanceSplitsTheKey() {
        let theme = "1B4A0C9E-0000-0000-0000-000000000001"
        let light = ThemeAccentStore.storageKey(presetID: theme, isDark: false)
        let dark = ThemeAccentStore.storageKey(presetID: theme, isDark: true)
        #expect(light != dark)
        #expect(light == "\(theme)|light")
        #expect(dark == "\(theme)|dark")
    }

    @Test("Different themes are different keys for the same appearance")
    func themeSplitsTheKey() {
        let a = ThemeAccentStore.storageKey(presetID: "theme-a", isDark: true)
        let b = ThemeAccentStore.storageKey(presetID: "theme-b", isDark: true)
        #expect(a != b)
    }

    @Test("No applied theme collapses to one bucket, however it is expressed")
    func unsavedThemeCollapses() {
        let fromNil = ThemeAccentStore.storageKey(presetID: nil, isDark: false)
        let fromEmpty = ThemeAccentStore.storageKey(presetID: "", isDark: false)
        let fromBlank = ThemeAccentStore.storageKey(presetID: "   ", isDark: false)
        #expect(fromNil == fromEmpty)
        #expect(fromNil == fromBlank)
        #expect(fromNil == "\(ThemeAccentStore.unsavedThemeID)|light")
    }

    @Test("The ColorScheme overload agrees with the Bool one")
    func colorSchemeOverloadMatches() {
        #expect(ThemeAccentStore.storageKey(presetID: "t", colorScheme: .dark)
                == ThemeAccentStore.storageKey(presetID: "t", isDark: true))
        #expect(ThemeAccentStore.storageKey(presetID: "t", colorScheme: .light)
                == ThemeAccentStore.storageKey(presetID: "t", isDark: false))
    }
}

// MARK: - Lookup and mutation

struct ThemeAccentStoreLookupTests {

    private let themeA = "theme-a"
    private let themeB = "theme-b"

    @Test("An empty map has no override — the caller falls back to the theme accent")
    func absenceMeansDefault() {
        let map: [String: CodableColor] = [:]
        #expect(ThemeAccentStore.accent(in: map, presetID: themeA, isDark: false) == nil)
        #expect(ThemeAccentStore.accent(in: map, presetID: themeA, isDark: true) == nil)
    }

    @Test("Setting light leaves dark untouched")
    func lightDoesNotLeakIntoDark() {
        let map = ThemeAccentStore.setting(.red, in: [:], presetID: themeA, isDark: false)
        #expect(ThemeAccentStore.accent(in: map, presetID: themeA, isDark: false) == .red)
        #expect(ThemeAccentStore.accent(in: map, presetID: themeA, isDark: true) == nil)
    }

    @Test("Setting one theme leaves another theme untouched")
    func themesAreIndependent() {
        let map = ThemeAccentStore.setting(.red, in: [:], presetID: themeA, isDark: true)
        #expect(ThemeAccentStore.accent(in: map, presetID: themeB, isDark: true) == nil)
    }

    @Test("All four slots hold their own value at once")
    func fourWayIndependence() {
        var map: [String: CodableColor] = [:]
        map = ThemeAccentStore.setting(.red, in: map, presetID: themeA, isDark: false)
        map = ThemeAccentStore.setting(.green, in: map, presetID: themeA, isDark: true)
        map = ThemeAccentStore.setting(.blue, in: map, presetID: themeB, isDark: false)
        map = ThemeAccentStore.setting(.orange, in: map, presetID: themeB, isDark: true)

        #expect(ThemeAccentStore.accent(in: map, presetID: themeA, isDark: false) == .red)
        #expect(ThemeAccentStore.accent(in: map, presetID: themeA, isDark: true) == .green)
        #expect(ThemeAccentStore.accent(in: map, presetID: themeB, isDark: false) == .blue)
        #expect(ThemeAccentStore.accent(in: map, presetID: themeB, isDark: true) == .orange)
        #expect(map.count == 4)
    }

    @Test("Re-setting a slot replaces rather than accumulates")
    func setReplaces() {
        var map = ThemeAccentStore.setting(.red, in: [:], presetID: themeA, isDark: false)
        map = ThemeAccentStore.setting(.purple, in: map, presetID: themeA, isDark: false)
        #expect(ThemeAccentStore.accent(in: map, presetID: themeA, isDark: false) == .purple)
        #expect(map.count == 1)
    }

    @Test("Reset removes the entry instead of storing the current color")
    func resetRemovesTheEntry() {
        var map = ThemeAccentStore.setting(.red, in: [:], presetID: themeA, isDark: false)
        map = ThemeAccentStore.setting(nil, in: map, presetID: themeA, isDark: false)
        #expect(map.isEmpty)
        #expect(ThemeAccentStore.accent(in: map, presetID: themeA, isDark: false) == nil)
    }

    @Test("Reset touches only the slot it was asked about")
    func resetIsScoped() {
        var map = ThemeAccentStore.setting(.red, in: [:], presetID: themeA, isDark: false)
        map = ThemeAccentStore.setting(.green, in: map, presetID: themeA, isDark: true)
        map = ThemeAccentStore.setting(nil, in: map, presetID: themeA, isDark: false)
        #expect(ThemeAccentStore.accent(in: map, presetID: themeA, isDark: false) == nil)
        #expect(ThemeAccentStore.accent(in: map, presetID: themeA, isDark: true) == .green)
    }

    @Test("An accent set with no theme applied is found again under the same bucket")
    func unsavedThemeRoundTrips() {
        let map = ThemeAccentStore.setting(.red, in: [:], presetID: nil, isDark: false)
        #expect(ThemeAccentStore.accent(in: map, presetID: "", isDark: false) == .red)
    }
}

// MARK: - Storage

struct ThemeAccentStorePersistenceTests {

    /// An isolated suite so these never touch the developer's real accent.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ThemeAccentStoreTests.\(name)")!
        defaults.removePersistentDomain(forName: "ThemeAccentStoreTests.\(name)")
        return defaults
    }

    @Test("Nothing stored reads back as no overrides")
    func emptyByDefault() {
        let defaults = makeDefaults("empty")
        #expect(ThemeAccentStore.load(defaults: defaults).isEmpty)
    }

    @Test("A saved map round-trips through UserDefaults")
    func roundTrip() {
        let defaults = makeDefaults("roundtrip")
        var map: [String: CodableColor] = [:]
        map = ThemeAccentStore.setting(.red, in: map, presetID: "t", isDark: false)
        map = ThemeAccentStore.setting(.blue, in: map, presetID: "t", isDark: true)
        ThemeAccentStore.save(map, defaults: defaults)

        let loaded = ThemeAccentStore.load(defaults: defaults)
        #expect(ThemeAccentStore.accent(in: loaded, presetID: "t", isDark: false) == .red)
        #expect(ThemeAccentStore.accent(in: loaded, presetID: "t", isDark: true) == .blue)
    }

    @Test("Saving an empty map removes the key rather than leaving an empty blob")
    func emptySaveClearsTheKey() {
        let defaults = makeDefaults("emptysave")
        ThemeAccentStore.save(ThemeAccentStore.setting(.red, in: [:], presetID: "t", isDark: false),
                              defaults: defaults)
        #expect(defaults.data(forKey: ThemeAccentStore.defaultsKey) != nil)

        ThemeAccentStore.save([:], defaults: defaults)
        #expect(defaults.data(forKey: ThemeAccentStore.defaultsKey) == nil)
        #expect(ThemeAccentStore.load(defaults: defaults).isEmpty)
    }

    @Test("clearAll wipes every theme's accent")
    func clearAllWipes() {
        let defaults = makeDefaults("clearall")
        var map: [String: CodableColor] = [:]
        map = ThemeAccentStore.setting(.red, in: map, presetID: "a", isDark: false)
        map = ThemeAccentStore.setting(.blue, in: map, presetID: "b", isDark: true)
        ThemeAccentStore.save(map, defaults: defaults)

        ThemeAccentStore.clearAll(defaults: defaults)
        #expect(ThemeAccentStore.load(defaults: defaults).isEmpty)
    }

    @Test("Garbage under the key degrades to no overrides rather than throwing")
    func corruptDataFailsSoft() {
        let defaults = makeDefaults("corrupt")
        defaults.set(Data("not json".utf8), forKey: ThemeAccentStore.defaultsKey)
        #expect(ThemeAccentStore.load(defaults: defaults).isEmpty)
    }

    @Test("The storage key is the new, additive one")
    func keyIsNew() {
        // Guards the CLAUDE.md persisted-keys rule: this must not collide with
        // the color customization keys it sits alongside.
        #expect(ThemeAccentStore.defaultsKey == "themeAccentByTheme")
        #expect(ThemeAccentStore.defaultsKey != "homeColorCustomization")
        #expect(ThemeAccentStore.defaultsKey != "homeColorCustomizationDark")
    }
}

// MARK: - ColorPicker round trip

/// The custom color well hands `setThemeAccent` a `Color` straight from the
/// system ColorPicker, whose wheel produces Display P3 colors — not the sRGB
/// constants every preset swatch uses. These pin the full journey of such a
/// color: Color → CodableColor → JSON → CodableColor → Color, compared through
/// UIKit's own conversion so "the same color" means what the screen means.
struct ThemeAccentColorRoundTripTests {

    /// Extended-sRGB components of a Color, unclamped — exactly what
    /// `CodableColor.init(_:)` captures.
    private func components(of color: Color) -> (r: Double, g: Double, b: Double, a: Double)? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (Double(r), Double(g), Double(b), Double(a))
    }

    private func expectClose(_ x: Double, _ y: Double, tolerance: Double = 0.001,
                             _ comment: Comment) {
        #expect(abs(x - y) <= tolerance, comment)
    }

    @Test("A Display P3 picker color survives store + JSON round trip unchanged")
    func p3ColorRoundTrips() throws {
        // In-gamut P3 color, like a mild ColorPicker pick.
        let picked = Color(uiColor: UIColor(displayP3Red: 0.32, green: 0.65, blue: 0.48, alpha: 1))
        let original = try #require(components(of: picked))

        let stored = CodableColor(picked)
        let data = try JSONEncoder().encode(["k": stored])
        let decoded = try JSONDecoder().decode([String: CodableColor].self, from: data)
        let restored = try #require(components(of: decoded["k"]!.color))

        expectClose(original.r, restored.r, "red drifted across the round trip")
        expectClose(original.g, restored.g, "green drifted across the round trip")
        expectClose(original.b, restored.b, "blue drifted across the round trip")
        expectClose(original.a, restored.a, "alpha drifted across the round trip")
    }

    @Test("A vivid P3 color outside sRGB is preserved, not clamped")
    func wideGamutColorIsNotClamped() throws {
        // Fully saturated P3 red sits OUTSIDE 0…1 in extended sRGB. If any
        // stage clamped, the restored components would all land back in 0…1
        // and the color on screen would visibly dull.
        let picked = Color(uiColor: UIColor(displayP3Red: 1.0, green: 0.0, blue: 0.0, alpha: 1))
        let original = try #require(components(of: picked))
        #expect(original.r > 1.0 || original.g < 0.0 || original.b < 0.0,
                "precondition: P3 red should be out of sRGB gamut")

        let restored = try #require(components(of: CodableColor(picked).color))
        expectClose(original.r, restored.r, "red was clamped or shifted")
        expectClose(original.g, restored.g, "green was clamped or shifted")
        expectClose(original.b, restored.b, "blue was clamped or shifted")
    }

    @Test("Re-storing the restored color is stable — the picker's get/set loop can't drift")
    func secondPassIsStable() throws {
        let picked = Color(uiColor: UIColor(displayP3Red: 0.9, green: 0.2, blue: 0.75, alpha: 1))
        let once = CodableColor(picked)
        let twice = CodableColor(once.color)
        expectClose(once.red, twice.red, tolerance: 0.0001, "red drifts on re-store")
        expectClose(once.green, twice.green, tolerance: 0.0001, "green drifts on re-store")
        expectClose(once.blue, twice.blue, tolerance: 0.0001, "blue drifts on re-store")
        expectClose(once.alpha, twice.alpha, tolerance: 0.0001, "alpha drifts on re-store")
    }
}
