//
//  MQTTCommand.swift
//  HaWake Alarm V2
//
//  Reusable custom command model. Each command publishes its name
//  as an HA sensor value and can optionally arm/disarm/toggle the alarm.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct MQTTCommand: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var icon: String = "terminal"
    var iconColorRed: Double = 0.0
    var iconColorGreen: Double = 0.47
    var iconColorBlue: Double = 1.0
    var armAction: ArmAction = .none
    var showInList: Bool = true

    /// When non-nil, this command opens a URL/URI (e.g. shortcuts://…) instead of
    /// publishing a Home Assistant action. nil = Home Assistant command (default).
    var actionURL: String? = nil

    var iconColor: Color {
        Color(red: iconColorRed, green: iconColorGreen, blue: iconColorBlue)
    }

    /// True when this is a URL command rather than a Home Assistant action.
    var isURLCommand: Bool { actionURL != nil }

    /// The trimmed URL string, or nil if empty/not a URL command.
    var resolvedActionURL: String? {
        guard let url = actionURL?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return nil }
        return url
    }

    /// Preset color options for the icon picker.
    ///
    /// **PUBLISHED CONTRACT — do not reorder, rename, or re-value these twelve.**
    /// `create_command`'s `color` field is matched against these names
    /// (`MQTTCommandHandler.applyCommandFields`), and every command already saved
    /// on a phone stores the RGB triple, not the name. Additions go in
    /// `extendedColors`; `allPresetColors` is the union that the name lookup and
    /// the pickers read.
    static let presetColors: [(name: String, color: Color, r: Double, g: Double, b: Double)] = [
        ("Blue", .blue, 0.0, 0.47, 1.0),
        ("Red", .red, 1.0, 0.23, 0.19),
        ("Green", .green, 0.2, 0.78, 0.35),
        ("Orange", .orange, 1.0, 0.58, 0.0),
        ("Purple", .purple, 0.69, 0.32, 0.87),
        ("Pink", .pink, 1.0, 0.18, 0.33),
        ("Teal", .teal, 0.19, 0.69, 0.78),
        ("Yellow", .yellow, 1.0, 0.84, 0.04),
        ("Indigo", .indigo, 0.35, 0.34, 0.84),
        ("Mint", .mint, 0.0, 0.78, 0.75),
        ("Brown", .brown, 0.64, 0.52, 0.37),
        ("Gray", .gray, 0.56, 0.56, 0.58),
    ]

    /// Colors added AFTER the original twelve. Purely additive: nothing here
    /// shadows a name in `presetColors`, so an automation that has always sent
    /// `"color": "Blue"` still resolves to exactly the same RGB it always did.
    ///
    /// Every entry is a literal RGB triple rather than a system color, because
    /// that triple is what gets persisted on the command — a dynamic color would
    /// be flattened at save time anyway.
    static let extendedColors: [(name: String, color: Color, r: Double, g: Double, b: Double)] = {
        let raw: [(String, Double, Double, Double)] = [
            // Blues
            ("Sky Blue",  0.35, 0.78, 0.98),
            ("Cyan",      0.13, 0.80, 0.96),
            ("Navy",      0.11, 0.21, 0.44),
            ("Midnight",  0.10, 0.12, 0.22),
            // Greens
            ("Sea Green", 0.18, 0.55, 0.45),
            ("Forest",    0.13, 0.42, 0.24),
            ("Lime",      0.62, 0.87, 0.20),
            ("Olive",     0.45, 0.50, 0.20),
            // Warms
            ("Amber",     1.00, 0.75, 0.20),
            ("Gold",      0.85, 0.68, 0.20),
            ("Peach",     1.00, 0.72, 0.55),
            ("Coral",     1.00, 0.50, 0.40),
            ("Copper",    0.72, 0.45, 0.20),
            ("Sand",      0.85, 0.78, 0.62),
            // Reds & pinks
            ("Crimson",   0.79, 0.09, 0.24),
            ("Maroon",    0.50, 0.11, 0.18),
            ("Rose",      0.95, 0.55, 0.66),
            ("Magenta",   0.90, 0.20, 0.75),
            // Purples
            ("Lavender",  0.72, 0.64, 0.94),
            ("Violet",    0.48, 0.16, 0.72),
            ("Plum",      0.55, 0.29, 0.45),
            // Neutrals
            ("Slate",     0.36, 0.42, 0.50),
            ("Steel",     0.55, 0.62, 0.68),
            ("Charcoal",  0.22, 0.24, 0.27),
        ]
        return raw.map { ($0.0, Color(red: $0.1, green: $0.2, blue: $0.3), $0.1, $0.2, $0.3) }
    }()

    /// Every named color the app knows about — the original twelve FIRST, so any
    /// name lookup keeps resolving to the historical entry, and so the pickers
    /// fall back to the familiar palette before reaching for the additions.
    static let allPresetColors: [(name: String, color: Color, r: Double, g: Double, b: Double)] =
        presetColors + extendedColors

    /// Named-color lookup, case-insensitive. Used by the MQTT `color` field.
    static func presetColor(named name: String) -> (name: String, color: Color, r: Double, g: Double, b: Double)? {
        allPresetColors.first { $0.name.lowercased() == name.lowercased() }
    }

    /// The preset name matching an RGB triple, or nil when the command carries a
    /// custom color (which `color_r`/`color_g`/`color_b` has always allowed).
    /// The tolerance matches the picker's own checkmark test.
    static func presetColorName(red: Double, green: Double, blue: Double, tolerance: Double = 0.01) -> String? {
        allPresetColors.first {
            abs($0.r - red) < tolerance && abs($0.g - green) < tolerance && abs($0.b - blue) < tolerance
        }?.name
    }

    enum ArmAction: String, Codable, CaseIterable, Identifiable {
        case none = "None"
        case arm = "Arm"
        case disarm = "Disarm"
        case toggle = "Toggle"

        var id: String { rawValue }

        var label: String { rawValue }
    }

    /// The ORIGINAL curated 35. Kept exactly as shipped, in order: these are the
    /// icons the inline grid has always offered, and `allAvailableIcons` puts
    /// them first so a form the user has opened a hundred times still leads with
    /// the same faces. New icons live in `iconCatalog`, never here.
    static let availableIcons: [String] = [
        // General
        "terminal", "command", "bolt.fill", "power", "gearshape.fill",
        // Home / Automation
        "house.fill", "lightbulb.fill", "fan.fill", "lamp.desk.fill", "spigot.fill",
        // Security
        "lock.fill", "lock.open.fill", "shield.fill", "shield.lefthalf.filled", "eye.fill",
        // Media
        "play.fill", "pause.fill", "speaker.wave.2.fill", "tv.fill", "music.note",
        // Environment
        "thermometer.medium", "drop.fill", "sun.max.fill", "moon.fill", "cloud.fill",
        // Actions
        "bell.fill", "hand.raised.fill", "figure.walk", "car.fill", "bed.double.fill",
        // Misc
        "star.fill", "heart.fill", "flag.fill", "tag.fill", "paperplane.fill"
    ]

    /// One browsable group of icons in the full picker.
    struct IconCategory: Identifiable, Equatable {
        let name: String
        let icons: [String]
        var id: String { name }
    }

    /// The FULL icon set, grouped for browsing. Each group opens with the
    /// original icons from that group (see `availableIcons`) so the categories
    /// read as an expansion of the old list rather than a replacement.
    ///
    /// `icon` on the MQTT side has always accepted any SF Symbol name — this
    /// catalog is a UI convenience, not a whitelist, and nothing validates
    /// against it.
    static let iconCatalog: [IconCategory] = [
        IconCategory(name: "General", icons: [
            "terminal", "command", "bolt.fill", "power", "gearshape.fill",
            "wand.and.stars", "sparkles", "arrow.triangle.2.circlepath",
            "checkmark.circle.fill", "xmark.circle.fill", "questionmark.circle.fill",
            "ellipsis.circle.fill", "slider.horizontal.3", "switch.2",
            "square.grid.2x2.fill"
        ]),
        IconCategory(name: "Home & Automation", icons: [
            "house.fill", "lightbulb.fill", "fan.fill", "lamp.desk.fill", "spigot.fill",
            "lightbulb.2.fill", "lamp.floor.fill", "lamp.ceiling.fill", "chandelier.fill",
            "door.left.hand.open", "door.garage.open", "window.shade.open",
            "blinds.horizontal.open", "washer.fill", "dryer.fill", "refrigerator.fill",
            "oven.fill", "dishwasher.fill", "microwave.fill",
            "sprinkler.and.droplets.fill", "powerplug.fill", "poweroutlet.type.b.fill",
            "air.purifier.fill", "humidifier.fill", "stairs"
        ]),
        IconCategory(name: "Security", icons: [
            "lock.fill", "lock.open.fill", "shield.fill", "shield.lefthalf.filled", "eye.fill",
            "lock.shield.fill", "key.fill", "key.horizontal.fill", "video.fill",
            "web.camera.fill", "bell.badge.fill", "exclamationmark.triangle.fill",
            "sensor.fill", "sensor.tag.radiowaves.forward.fill", "person.crop.circle.fill",
            "person.2.fill", "hand.raised.slash.fill", "eye.slash.fill",
            "figure.walk.motion", "light.beacon.max.fill"
        ]),
        IconCategory(name: "Media", icons: [
            "play.fill", "pause.fill", "speaker.wave.2.fill", "tv.fill", "music.note",
            "stop.fill", "forward.fill", "backward.fill", "speaker.slash.fill",
            "speaker.wave.3.fill", "hifispeaker.fill", "homepod.fill", "airplayaudio",
            "airplayvideo", "headphones", "film.fill", "photo.fill",
            "play.rectangle.fill", "music.note.list", "dot.radiowaves.left.and.right"
        ]),
        IconCategory(name: "Weather & Climate", icons: [
            "thermometer.medium", "drop.fill", "sun.max.fill", "moon.fill", "cloud.fill",
            "snowflake", "flame.fill", "wind", "humidity.fill", "leaf.fill",
            "cloud.rain.fill", "cloud.sun.fill", "cloud.moon.fill",
            "thermometer.sun.fill", "thermometer.snowflake", "sun.haze.fill",
            "moon.stars.fill", "aqi.medium", "sunrise.fill", "sunset.fill"
        ]),
        IconCategory(name: "Daily Life", icons: [
            "bell.fill", "hand.raised.fill", "figure.walk", "car.fill", "bed.double.fill",
            "alarm.fill", "timer", "powersleep", "figure.run", "cup.and.saucer.fill",
            "fork.knife", "cart.fill", "bag.fill", "briefcase.fill", "airplane",
            "bicycle", "bus.fill", "tram.fill", "dumbbell.fill", "shower.fill",
            "bathtub.fill", "toilet.fill"
        ]),
        IconCategory(name: "Devices & Network", icons: [
            "iphone", "ipad", "macbook", "applewatch", "desktopcomputer", "display",
            "printer.fill", "network", "server.rack", "externaldrive.fill", "wifi",
            "antenna.radiowaves.left.and.right", "battery.100",
            "bolt.batteryblock.fill", "cable.connector", "app.badge.fill",
            "square.and.arrow.up.fill"
        ]),
        IconCategory(name: "Symbols", icons: [
            "star.fill", "heart.fill", "flag.fill", "tag.fill", "paperplane.fill",
            "bookmark.fill", "gift.fill", "pin.fill", "mappin.and.ellipse",
            "location.fill", "phone.fill", "envelope.fill", "message.fill",
            "calendar", "clock.fill", "arrow.up.arrow.down", "text.bubble.fill",
            "list.bullet", "note.text", "hands.clap.fill", "face.smiling.fill",
            "pawprint.fill", "dog.fill", "cat.fill", "bolt.horizontal.fill"
        ])
    ]

    /// `iconCatalog` with any symbol this OS doesn't know about removed, so a
    /// picker can never render a blank tile — a missing SF Symbol draws nothing
    /// at all, which looks like a broken app rather than a missing glyph.
    /// Resolved once, lazily.
    static let resolvedIconCatalog: [IconCategory] = iconCatalog.compactMap { category in
        let icons = category.icons.filter(symbolExists)
        return icons.isEmpty ? nil : IconCategory(name: category.name, icons: icons)
    }

    /// Every icon the pickers offer, deduplicated, with the original 35 first.
    /// Order matters: the inline grid fills from the front, so the icons that
    /// have always been on screen stay on screen.
    static let allAvailableIcons: [String] = {
        var seen = Set<String>()
        var result: [String] = []
        for icon in availableIcons + resolvedIconCatalog.flatMap(\.icons)
        where symbolExists(icon) && seen.insert(icon).inserted {
            result.append(icon)
        }
        return result
    }()

    /// Whether this OS ships the named SF Symbol.
    static func symbolExists(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil
        #else
        return true
        #endif
    }
}
