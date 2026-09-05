//
//  NWSAlertTypes.swift
//  HaWake Alarm V2
//
//  Data models for NWS (National Weather Service) weather alerts.
//

import Foundation
import SwiftUI

// MARK: - Monitored Location

struct NWSMonitoredLocation: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    /// Uses device GPS instead of fixed coordinates.
    var useCurrentLocation: Bool
    /// Per-category alert settings for this location.
    var categorySettings: [String: NWSAlertCategorySettings]

    init(name: String, latitude: Double = 0, longitude: Double = 0, useCurrentLocation: Bool = false) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.useCurrentLocation = useCurrentLocation
        self.categorySettings = NWSAlertCategory.defaultCategorySettings()
    }

    /// Returns the settings for a given category, falling back to defaults.
    func settings(for category: NWSAlertCategory) -> NWSAlertCategorySettings {
        categorySettings[category.rawValue] ?? category.defaultSettings
    }
}

// MARK: - Alert Category

enum NWSAlertCategory: String, Codable, CaseIterable, Identifiable {
    case tornadoWarning = "Tornado Warning"
    case tornadoWatch = "Tornado Watch"
    case severeThunderstormWarning = "Severe Thunderstorm Warning"
    case severeThunderstormWatch = "Severe Thunderstorm Watch"
    case flashFloodWarning = "Flash Flood Warning"
    case floodWarning = "Flood Warning"
    case floodWatch = "Flood Watch"
    case winterStormWarning = "Winter Storm Warning"
    case winterStormWatch = "Winter Storm Watch"
    case blizzardWarning = "Blizzard Warning"
    case iceStormWarning = "Ice Storm Warning"
    case hurricaneWarning = "Hurricane Warning"
    case hurricaneWatch = "Hurricane Watch"
    case tropicalStormWarning = "Tropical Storm Warning"
    case extremeWindWarning = "Extreme Wind Warning"
    case dustStormWarning = "Dust Storm Warning"

    var id: String { rawValue }

    /// NWS API "event" field values that map to this category.
    var nwsEventNames: [String] {
        switch self {
        case .tornadoWarning: return ["Tornado Warning"]
        case .tornadoWatch: return ["Tornado Watch"]
        case .severeThunderstormWarning: return ["Severe Thunderstorm Warning"]
        case .severeThunderstormWatch: return ["Severe Thunderstorm Watch"]
        case .flashFloodWarning: return ["Flash Flood Warning"]
        case .floodWarning: return ["Flood Warning", "Coastal Flood Warning"]
        case .floodWatch: return ["Flood Watch", "Flash Flood Watch", "Coastal Flood Watch"]
        case .winterStormWarning: return ["Winter Storm Warning", "Winter Weather Advisory"]
        case .winterStormWatch: return ["Winter Storm Watch"]
        case .blizzardWarning: return ["Blizzard Warning"]
        case .iceStormWarning: return ["Ice Storm Warning"]
        case .hurricaneWarning: return ["Hurricane Warning"]
        case .hurricaneWatch: return ["Hurricane Watch"]
        case .tropicalStormWarning: return ["Tropical Storm Warning"]
        case .extremeWindWarning: return ["Extreme Wind Warning", "High Wind Warning"]
        case .dustStormWarning: return ["Dust Storm Warning"]
        }
    }

    var sfSymbol: String {
        switch self {
        case .tornadoWarning, .tornadoWatch: return "tornado"
        case .severeThunderstormWarning, .severeThunderstormWatch: return "cloud.bolt.rain.fill"
        case .flashFloodWarning, .floodWarning, .floodWatch: return "water.waves"
        case .winterStormWarning, .winterStormWatch, .blizzardWarning, .iceStormWarning: return "snowflake"
        case .hurricaneWarning, .hurricaneWatch, .tropicalStormWarning: return "hurricane"
        case .extremeWindWarning: return "wind"
        case .dustStormWarning: return "sun.dust.fill"
        }
    }

    var color: Color {
        switch self {
        case .tornadoWarning: return .red
        case .tornadoWatch: return .orange
        case .severeThunderstormWarning: return .orange
        case .severeThunderstormWatch: return .yellow
        case .flashFloodWarning: return .red
        case .floodWarning: return .green
        case .floodWatch: return .teal
        case .winterStormWarning: return .purple
        case .winterStormWatch: return .indigo
        case .blizzardWarning: return .purple
        case .iceStormWarning: return .pink
        case .hurricaneWarning: return .red
        case .hurricaneWatch: return .orange
        case .tropicalStormWarning: return .orange
        case .extremeWindWarning: return .brown
        case .dustStormWarning: return .brown
        }
    }

    /// Whether this category is a warning (vs watch).
    var isWarning: Bool {
        rawValue.contains("Warning")
    }

    var defaultSettings: NWSAlertCategorySettings {
        NWSAlertCategorySettings(enabled: false, soundID: "", volume: 1.0, vibrationEnabled: true)
    }

    /// Build default settings dictionary for all categories.
    static func defaultCategorySettings() -> [String: NWSAlertCategorySettings] {
        var dict: [String: NWSAlertCategorySettings] = [:]
        for category in NWSAlertCategory.allCases {
            dict[category.rawValue] = category.defaultSettings
        }
        return dict
    }

    /// Look up the category for an NWS event name.
    static func category(forEvent event: String) -> NWSAlertCategory? {
        allCases.first { $0.nwsEventNames.contains(event) }
    }
}

// MARK: - Per-Category Settings

struct NWSAlertCategorySettings: Codable, Equatable {
    var enabled: Bool
    /// Empty string = use default alert sound.
    var soundID: String
    var volume: Double
    var vibrationEnabled: Bool
    /// Whether the alert sound should fade in gradually from silence.
    var fadeInEnabled: Bool
    /// Fade-in duration in seconds (5–120). Only used when fadeInEnabled is true.
    var fadeInDuration: Int

    init(enabled: Bool, soundID: String, volume: Double, vibrationEnabled: Bool,
         fadeInEnabled: Bool = false, fadeInDuration: Int = 30) {
        self.enabled = enabled
        self.soundID = soundID
        self.volume = volume
        self.vibrationEnabled = vibrationEnabled
        self.fadeInEnabled = fadeInEnabled
        self.fadeInDuration = fadeInDuration
    }

    // Custom decoder: use decodeIfPresent for the new fade-in fields so that
    // existing saved data (which pre-dates these fields) still decodes cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        soundID = try c.decode(String.self, forKey: .soundID)
        volume = try c.decode(Double.self, forKey: .volume)
        vibrationEnabled = try c.decode(Bool.self, forKey: .vibrationEnabled)
        fadeInEnabled = try c.decodeIfPresent(Bool.self, forKey: .fadeInEnabled) ?? false
        fadeInDuration = try c.decodeIfPresent(Int.self, forKey: .fadeInDuration) ?? 30
    }
}

// MARK: - NWS API Response

struct NWSAlertResponse: Codable {
    let features: [NWSAlertFeature]
}

struct NWSAlertFeature: Codable {
    let id: String
    let properties: NWSAlertProperties
}

struct NWSAlertProperties: Codable {
    let id: String?
    let event: String?
    let headline: String?
    let description: String?
    let severity: String?
    let urgency: String?
    let onset: String?
    let expires: String?
    let senderName: String?
    let areaDesc: String?
}
