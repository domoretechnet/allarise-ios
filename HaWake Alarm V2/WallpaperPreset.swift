//
//  WallpaperPreset.swift
//  HaWake Alarm V2
//
//  Data model for saved wallpaper pair presets (Light + Dark mode).
//

import Foundation
import SwiftUI

// MARK: - Notification Names

extension Notification.Name {
    static let dismissSettingsSheet = Notification.Name("dismissSettingsSheet")
    static let presetImported = Notification.Name("presetImported")
}

// MARK: - Wallpaper Appearance

/// Appearance mode for wallpaper configuration
enum WallpaperAppearance: String, CaseIterable, Hashable, Identifiable {
    var id: String { rawValue }
    case light
    case dark
    
    var title: String {
        switch self {
        case .light: return "Light Mode"
        case .dark: return "Dark Mode"
        }
    }
    
    var icon: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
    
    /// The storage key for this appearance's wallpaper image
    var wallpaperKey: String {
        switch self {
        case .light: return "home_light"
        case .dark: return "home_dark"
        }
    }
}

struct WallpaperPreset: Codable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    
    /// Whether this preset was shipped with the app (non-deletable, non-renamable)
    var isBuiltIn: Bool = false
    /// Bundle image slug for built-in presets (e.g. "ocean-sunset").
    /// Used during seeding to locate images in the app bundle. nil for user-created presets.
    var bundleImageSlug: String?
    
    // MARK: - Light Mode Settings
    
    var lightDimming: Double?
    var lightGlassVariant: Int
    var lightGlassClearDimming: Double
    var lightGlassTintRed: Double
    var lightGlassTintGreen: Double
    var lightGlassTintBlue: Double
    var lightGlassTintOpacity: Double
    var lightWallpaperScale: Double
    var lightWallpaperOffsetX: Double
    var lightWallpaperOffsetY: Double
    
    // MARK: - Dark Mode Settings
    
    var darkDimming: Double?
    var darkGlassVariant: Int
    var darkGlassClearDimming: Double
    var darkGlassTintRed: Double
    var darkGlassTintGreen: Double
    var darkGlassTintBlue: Double
    var darkGlassTintOpacity: Double
    var darkWallpaperScale: Double
    var darkWallpaperOffsetX: Double
    var darkWallpaperOffsetY: Double
    
    // MARK: - Image Flags
    
    /// Whether a light mode image was saved with this preset
    var hasLightImage: Bool
    /// Whether a dark mode image was saved with this preset
    var hasDarkImage: Bool
    
    // MARK: - Widget Glass Settings (optional for backward compatibility)
    
    var lightWidgetGlassVariant: Int?
    var lightWidgetGlassClearDimming: Double?
    var lightWidgetGlassTintRed: Double?
    var lightWidgetGlassTintGreen: Double?
    var lightWidgetGlassTintBlue: Double?
    var lightWidgetGlassTintOpacity: Double?
    
    var darkWidgetGlassVariant: Int?
    var darkWidgetGlassClearDimming: Double?
    var darkWidgetGlassTintRed: Double?
    var darkWidgetGlassTintGreen: Double?
    var darkWidgetGlassTintBlue: Double?
    var darkWidgetGlassTintOpacity: Double?
    
    // MARK: - Color Customization (optional for backward compatibility)

    var lightColorCustomization: HomeColorCustomization?
    var darkColorCustomization: HomeColorCustomization?

    // MARK: - Status Bar (optional for backward compatibility)

    /// Whether the system status bar (the time / battery text in the safe area
    /// above the app) should use light content — white text — while this home
    /// preset is applied, regardless of the app's light/dark appearance.
    ///
    /// Some presets ship a dark *light-mode* wallpaper (Terminal Drift, Ember
    /// Tide, …) where SwiftUI's default black status-bar text is unreadable.
    /// SwiftUI only lets you flip the status bar by flipping the whole app's
    /// color scheme, so this flag drives a UIKit-level override instead
    /// (`StatusBarStyleController`). nil/false leaves the status bar following
    /// the app's color scheme, which is the correct default for light presets.
    var statusBarPrefersLightContent: Bool?
}

struct WallpaperPresetManifest: Codable {
    var presets: [WallpaperPreset]
}

// MARK: - Alarm Wallpaper Presets

struct AlarmWallpaperPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    
    /// Whether this preset was shipped with the app (non-deletable, non-renamable)
    var isBuiltIn: Bool = false
    /// Bundle image slug for built-in presets (e.g. "deep-red").
    /// Used during seeding to locate images in the app bundle. nil for user-created presets.
    var bundleImageSlug: String?
    
    // MARK: - Light Mode Settings
    
    var lightDimming: Double              // 0.0...0.9
    var lightGlassVariant: Int            // 0 = regular, 1 = clear, 2 = tinted
    var lightGlassClearDimming: Double
    var lightGlassTintRed: Double
    var lightGlassTintGreen: Double
    var lightGlassTintBlue: Double
    var lightGlassTintOpacity: Double
    var lightWallpaperScale: Double       // 1.0...3.0
    var lightWallpaperOffsetX: Double
    var lightWallpaperOffsetY: Double
    
    // MARK: - Dark Mode Settings
    
    var darkDimming: Double
    var darkGlassVariant: Int
    var darkGlassClearDimming: Double
    var darkGlassTintRed: Double
    var darkGlassTintGreen: Double
    var darkGlassTintBlue: Double
    var darkGlassTintOpacity: Double
    var darkWallpaperScale: Double
    var darkWallpaperOffsetX: Double
    var darkWallpaperOffsetY: Double
    
    // MARK: - Color Customization
    
    var lightColorCustomization: AlarmColorCustomization?
    var darkColorCustomization: AlarmColorCustomization?
    
    // MARK: - Image Flags
    
    var hasLightImage: Bool
    var hasDarkImage: Bool
}

struct AlarmWallpaperPresetManifest: Codable {
    var presets: [AlarmWallpaperPreset]
}
