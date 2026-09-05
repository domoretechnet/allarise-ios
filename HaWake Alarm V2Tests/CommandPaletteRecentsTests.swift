//
//  CommandPaletteRecentsTests.swift
//  HaWake Alarm V2Tests
//
//  The command form's icon/color memory and the inline-grid window it feeds.
//
//  These are pure-function tests plus a few against an isolated `UserDefaults`
//  suite — never `.standard`, so running them can't reorder the developer's own
//  recent icons.
//
//  What they pin down:
//    • MRU semantics: newest first, deduplicated, capped.
//    • The Recent row: stored order, filtered to the catalog, capped at one row.
//    • The slice rule: the Recent row's contents are removed from the catalog
//      slice beneath it (nothing appears twice), and the CURRENT selection
//      always keeps a slot somewhere — that last one is what stops a color
//      picked from the expanded catalog from vanishing when it collapses again.
//    • The additive palette guarantees: the original twelve color names still
//      resolve to their original RGB, and the original 35 icons still lead the
//      catalog.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

// MARK: - MRU push

struct CommandPaletteRecentsPushTests {

    @Test("A new value goes to the front")
    func newestFirst() {
        let result = CommandPaletteRecents.pushed("star.fill", onto: ["heart.fill", "bolt.fill"])
        #expect(result == ["star.fill", "heart.fill", "bolt.fill"])
    }

    @Test("Re-choosing an existing value moves it up rather than duplicating it")
    func dedupesAndPromotes() {
        let result = CommandPaletteRecents.pushed("bolt.fill", onto: ["heart.fill", "bolt.fill", "star.fill"])
        #expect(result == ["bolt.fill", "heart.fill", "star.fill"])
    }

    @Test("The list is capped, dropping the oldest entry")
    func capped() {
        let existing = ["a", "b", "c", "d", "e", "f", "g", "h"]
        #expect(existing.count == CommandPaletteRecents.memoryLimit)
        let result = CommandPaletteRecents.pushed("new", onto: existing)
        #expect(result.count == CommandPaletteRecents.memoryLimit)
        #expect(result.first == "new")
        #expect(!result.contains("h"))
    }

    @Test("A blank value is never stored")
    func ignoresBlank() {
        #expect(CommandPaletteRecents.pushed("", onto: ["a"]) == ["a"])
        #expect(CommandPaletteRecents.pushed("   ", onto: ["a"]) == ["a"])
    }

    @Test("Surrounding whitespace is trimmed before storing")
    func trimsWhitespace() {
        #expect(CommandPaletteRecents.pushed("  star.fill ", onto: []) == ["star.fill"])
    }
}

// MARK: - The Recent row

struct CommandPaletteVisibleRecentsTests {

    private let catalog = ["one", "two", "three", "four", "five", "six"]

    @Test("Stored order is kept — most recent first")
    func keepsStoredOrder() {
        let result = CommandPaletteRecents.visibleRecents(["five", "two"], catalog: catalog, limit: 5)
        #expect(result == ["five", "two"])
    }

    @Test("The row is capped at its width")
    func cappedAtRowWidth() {
        let result = CommandPaletteRecents.visibleRecents(["six", "five", "four", "three"],
                                                          catalog: catalog,
                                                          limit: 2)
        #expect(result == ["six", "five"])
    }

    @Test("A recent that is no longer in the catalog is skipped, not rendered")
    func unknownRecentsDropped() {
        let result = CommandPaletteRecents.visibleRecents(["gone.from.this.os", "six"],
                                                          catalog: catalog,
                                                          limit: 5)
        #expect(result == ["six"])
    }

    @Test("Duplicated recents don't waste slots")
    func duplicatesCollapse() {
        let result = CommandPaletteRecents.visibleRecents(["four", "four", "two"],
                                                          catalog: catalog,
                                                          limit: 3)
        #expect(result == ["four", "two"])
    }

    @Test("No recents, or no room, yields nothing rather than an empty header")
    func emptyCases() {
        #expect(CommandPaletteRecents.visibleRecents([], catalog: catalog, limit: 5).isEmpty)
        #expect(CommandPaletteRecents.visibleRecents(["one"], catalog: catalog, limit: 0).isEmpty)
        #expect(CommandPaletteRecents.visibleRecents(["one"], catalog: catalog, limit: -3).isEmpty)
    }
}

// MARK: - The collapsed catalog slice

struct CommandPaletteInlineSliceTests {

    private let catalog = ["one", "two", "three", "four", "five", "six"]

    @Test("With nothing excluded the slice is just the catalog's own order")
    func catalogOrder() {
        let result = CommandPaletteRecents.inlineSlice(catalog: catalog,
                                                       excluding: [],
                                                       selected: nil,
                                                       limit: 4)
        #expect(result == ["one", "two", "three", "four"])
    }

    @Test("Anything the Recent row is showing is left out of the slice")
    func excludesRecents() {
        let result = CommandPaletteRecents.inlineSlice(catalog: catalog,
                                                       excluding: ["five", "three"],
                                                       selected: nil,
                                                       limit: 3)
        #expect(result == ["one", "two", "four"])
    }

    @Test("The selection takes the last slot rather than falling off the end")
    func selectionAlwaysVisible() {
        let result = CommandPaletteRecents.inlineSlice(catalog: catalog,
                                                       excluding: [],
                                                       selected: "six",
                                                       limit: 3)
        #expect(result == ["one", "two", "six"])
    }

    @Test("A selection the Recent row already shows leaves the slice alone")
    func selectionShownInRecents() {
        let result = CommandPaletteRecents.inlineSlice(catalog: catalog,
                                                       excluding: ["six"],
                                                       selected: "six",
                                                       limit: 3)
        #expect(result == ["one", "two", "three"])
    }

    @Test("A selection outside the catalog is simply ignored")
    func unknownSelectionIgnored() {
        let result = CommandPaletteRecents.inlineSlice(catalog: catalog,
                                                       excluding: [],
                                                       selected: "not.a.symbol",
                                                       limit: 3)
        #expect(result == ["one", "two", "three"])
    }

    @Test("A zero or negative limit yields nothing rather than crashing")
    func nonPositiveLimit() {
        #expect(CommandPaletteRecents.inlineSlice(catalog: catalog,
                                                  excluding: [],
                                                  selected: "one",
                                                  limit: 0).isEmpty)
        #expect(CommandPaletteRecents.inlineSlice(catalog: catalog,
                                                  excluding: [],
                                                  selected: "one",
                                                  limit: -3).isEmpty)
    }

    @Test("The slice never exceeds the limit, and never repeats a tile")
    func neverExceedsLimitOrRepeats() {
        for limit in 1...8 {
            let result = CommandPaletteRecents.inlineSlice(catalog: catalog,
                                                           excluding: ["six"],
                                                           selected: "five",
                                                           limit: limit)
            #expect(result.count == min(limit, catalog.count - 1))
            #expect(Set(result).count == result.count)
            #expect(!result.contains("six"))
            #expect(result.contains("five"))
        }
    }
}

// MARK: - Storage round-trip

struct CommandPaletteRecentsStorageTests {

    /// A throwaway suite so nothing here touches the real app's defaults.
    private func makeDefaults() -> UserDefaults {
        let name = "CommandPaletteRecentsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Icons round-trip, most recent first")
    func iconRoundTrip() {
        let defaults = makeDefaults()
        #expect(CommandPaletteRecents.recentIcons(defaults: defaults).isEmpty)

        CommandPaletteRecents.recordIcon("bolt.fill", defaults: defaults)
        CommandPaletteRecents.recordIcon("house.fill", defaults: defaults)
        CommandPaletteRecents.recordIcon("bolt.fill", defaults: defaults)

        #expect(CommandPaletteRecents.recentIcons(defaults: defaults) == ["bolt.fill", "house.fill"])
    }

    @Test("Colors round-trip by preset name")
    func colorRoundTrip() {
        let defaults = makeDefaults()
        CommandPaletteRecents.recordColorName("Teal", defaults: defaults)
        CommandPaletteRecents.recordColorName("Crimson", defaults: defaults)
        #expect(CommandPaletteRecents.recentColorNames(defaults: defaults) == ["Crimson", "Teal"])
    }

    @Test("Colors round-trip by hex, most recent first")
    func colorHexRoundTrip() {
        let defaults = makeDefaults()
        CommandPaletteRecents.recordColorHex(red: 0.0, green: 0.47, blue: 1.0, defaults: defaults) // Blue
        CommandPaletteRecents.recordColorHex(red: 0.123, green: 0.456, blue: 0.789, defaults: defaults) // custom
        CommandPaletteRecents.recordColorHex(red: 0.0, green: 0.47, blue: 1.0, defaults: defaults) // Blue again → front
        let hexes = CommandPaletteRecents.recentColorHexes(defaults: defaults)
        // Blue promoted to front, custom kept, no duplicate Blue.
        #expect(hexes.first == commandColorHex(red: 0.0, green: 0.47, blue: 1.0))
        #expect(hexes.count == 2)
    }

    @Test("Saving a command records its icon, its hex, and (for a preset) its name")
    func recordFromCommandValues() {
        let defaults = makeDefaults()
        // Green, exactly as the preset defines it.
        CommandPaletteRecents.record(icon: "lightbulb.fill",
                                     colorRed: 0.2, colorGreen: 0.78, colorBlue: 0.35,
                                     defaults: defaults)
        #expect(CommandPaletteRecents.recentIcons(defaults: defaults) == ["lightbulb.fill"])
        #expect(CommandPaletteRecents.recentColorNames(defaults: defaults) == ["Green"])
        #expect(CommandPaletteRecents.recentColorHexes(defaults: defaults)
                == [commandColorHex(red: 0.2, green: 0.78, blue: 0.35)])
    }

    @Test("A custom RGB is remembered by hex, though it still has no name to store")
    func customColorRememberedByHex() {
        let defaults = makeDefaults()
        CommandPaletteRecents.record(icon: "fan.fill",
                                     colorRed: 0.123, colorGreen: 0.456, colorBlue: 0.789,
                                     defaults: defaults)
        #expect(CommandPaletteRecents.recentIcons(defaults: defaults) == ["fan.fill"])
        // No preset name for a custom mix — that list stays empty.
        #expect(CommandPaletteRecents.recentColorNames(defaults: defaults).isEmpty)
        // But the hex list DOES remember it, which is the whole point.
        #expect(CommandPaletteRecents.recentColorHexes(defaults: defaults)
                == [commandColorHex(red: 0.123, green: 0.456, blue: 0.789)])
    }

    @Test("Clearing wipes every list")
    func clearAll() {
        let defaults = makeDefaults()
        CommandPaletteRecents.recordIcon("star.fill", defaults: defaults)
        CommandPaletteRecents.recordColorName("Blue", defaults: defaults)
        CommandPaletteRecents.recordColorHex(red: 0.0, green: 0.47, blue: 1.0, defaults: defaults)
        CommandPaletteRecents.clearAll(defaults: defaults)
        #expect(CommandPaletteRecents.recentIcons(defaults: defaults).isEmpty)
        #expect(CommandPaletteRecents.recentColorNames(defaults: defaults).isEmpty)
        #expect(CommandPaletteRecents.recentColorHexes(defaults: defaults).isEmpty)
    }
}

// MARK: - Hex round-trip and recent-color rendering

struct CommandPaletteHexTests {

    @Test("A triple survives a hex round-trip within a rounding step")
    func hexRoundTrip() {
        let hex = commandColorHex(red: 0.2, green: 0.78, blue: 0.35)
        let parsed = commandColorFromHex(hex)
        #expect(parsed != nil)
        #expect(abs((parsed?.r ?? -1) - 0.2) < 0.01)
        #expect(abs((parsed?.g ?? -1) - 0.78) < 0.01)
        #expect(abs((parsed?.b ?? -1) - 0.35) < 0.01)
    }

    @Test("A leading # is accepted; garbage is rejected")
    func hexParsingTolerance() {
        #expect(commandColorFromHex("#0077FF") != nil)
        #expect(commandColorFromHex("0077FF") != nil)
        #expect(commandColorFromHex("nope") == nil)
        #expect(commandColorFromHex("0077F") == nil)   // five digits
        #expect(commandColorFromHex("") == nil)
    }

    @Test("Recent colors are deduplicated in stored order and capped")
    func recentColorsDedupeAndCap() {
        let blue = commandColorHex(red: 0.0, green: 0.47, blue: 1.0)
        let green = commandColorHex(red: 0.2, green: 0.78, blue: 0.35)
        let recents = CommandPaletteRecents.recentColors([blue, green, blue, "garbage"], limit: 6)
        #expect(recents.map(\.hex) == [blue, green])
    }

    @Test("A recent that lands on a preset carries its name; a custom one carries nil")
    func recentColorsAttachNames() {
        let blue = commandColorHex(red: 0.0, green: 0.47, blue: 1.0)
        let custom = commandColorHex(red: 0.11, green: 0.22, blue: 0.33)
        let recents = CommandPaletteRecents.recentColors([blue, custom], limit: 6)
        #expect(recents.first?.name == "Blue")
        #expect(recents.last?.name == nil)
    }

    @Test("A non-positive limit yields nothing")
    func recentColorsLimitGuard() {
        let blue = commandColorHex(red: 0.0, green: 0.47, blue: 1.0)
        #expect(CommandPaletteRecents.recentColors([blue], limit: 0).isEmpty)
        #expect(CommandPaletteRecents.recentColors([blue], limit: -2).isEmpty)
    }
}

// MARK: - Palette additivity (backwards compatibility)

struct CommandPaletteCompatibilityTests {

    /// The exact twelve names and RGB triples that shipped, and that
    /// `create_command`'s `color` field has always accepted.
    private static let originalColors: [(String, Double, Double, Double)] = [
        ("Blue", 0.0, 0.47, 1.0),
        ("Red", 1.0, 0.23, 0.19),
        ("Green", 0.2, 0.78, 0.35),
        ("Orange", 1.0, 0.58, 0.0),
        ("Purple", 0.69, 0.32, 0.87),
        ("Pink", 1.0, 0.18, 0.33),
        ("Teal", 0.19, 0.69, 0.78),
        ("Yellow", 1.0, 0.84, 0.04),
        ("Indigo", 0.35, 0.34, 0.84),
        ("Mint", 0.0, 0.78, 0.75),
        ("Brown", 0.64, 0.52, 0.37),
        ("Gray", 0.56, 0.56, 0.58),
    ]

    @Test("Every original color name still resolves to its original RGB")
    func originalColorNamesUnchanged() {
        for (name, r, g, b) in Self.originalColors {
            let preset = MQTTCommand.presetColor(named: name)
            #expect(preset != nil, "\(name) no longer resolves")
            #expect(preset?.r == r)
            #expect(preset?.g == g)
            #expect(preset?.b == b)
        }
    }

    @Test("Color names resolve case-insensitively, as the MQTT handler relies on")
    func caseInsensitiveLookup() {
        #expect(MQTTCommand.presetColor(named: "blue")?.name == "Blue")
        #expect(MQTTCommand.presetColor(named: "SKY BLUE")?.name == "Sky Blue")
        #expect(MQTTCommand.presetColor(named: "nope") == nil)
    }

    @Test("The extended palette only ADDS names — no shadowing, no duplicates")
    func extendedColorsAreAdditive() {
        let originals = Set(MQTTCommand.presetColors.map(\.name))
        let extended = MQTTCommand.extendedColors.map(\.name)
        for name in extended {
            #expect(!originals.contains(name), "\(name) shadows an original preset")
        }
        #expect(Set(extended).count == extended.count, "duplicate name in extendedColors")
        // Original twelve first, so name lookup order can never change.
        #expect(Array(MQTTCommand.allPresetColors.prefix(MQTTCommand.presetColors.count)).map(\.name)
                == MQTTCommand.presetColors.map(\.name))
        #expect(MQTTCommand.allPresetColors.count
                == MQTTCommand.presetColors.count + MQTTCommand.extendedColors.count)
    }

    @Test("An RGB triple maps back to its preset name, and a custom one to nil")
    func reverseColorLookup() {
        #expect(MQTTCommand.presetColorName(red: 0.0, green: 0.47, blue: 1.0) == "Blue")
        #expect(MQTTCommand.presetColorName(red: 0.123, green: 0.456, blue: 0.789) == nil)
    }

    @Test("The original 35 icons still lead the catalog, in their original order")
    func originalIconsLeadCatalog() {
        let head = Array(MQTTCommand.allAvailableIcons.prefix(MQTTCommand.availableIcons.count))
        #expect(head == MQTTCommand.availableIcons)
    }

    @Test("The expanded icon catalog has no duplicates and is meaningfully bigger")
    func iconCatalogIsCleanAndBigger() {
        let all = MQTTCommand.allAvailableIcons
        #expect(Set(all).count == all.count, "duplicate icon in allAvailableIcons")
        #expect(all.count > MQTTCommand.availableIcons.count * 2)
    }

    @Test("Every catalog icon exists on this OS, so no tile can render blank")
    func everyCatalogIconResolves() {
        for icon in MQTTCommand.allAvailableIcons {
            #expect(MQTTCommand.symbolExists(icon), "\(icon) is not an SF Symbol on this OS")
        }
    }

    @Test("The default icon and color a new command starts with are still offered")
    func defaultsStillInThePalette() {
        let fresh = MQTTCommand(name: "New")
        #expect(MQTTCommand.allAvailableIcons.contains(fresh.icon))
        #expect(MQTTCommand.presetColorName(red: fresh.iconColorRed,
                                            green: fresh.iconColorGreen,
                                            blue: fresh.iconColorBlue) == "Blue")
    }
}
