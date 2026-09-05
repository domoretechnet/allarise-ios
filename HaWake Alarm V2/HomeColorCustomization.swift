//
//  HomeColorCustomization.swift
//  HaWake Alarm V2
//
//  Color customization model for home screen alarm card elements.
//

import Foundation
import SwiftUI

// MARK: - Codable Color (RGBA)

struct CodableColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
    
    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
    
    init(_ color: Color) {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.alpha = Double(a)
    }
    
    var color: Color {
        Color(red: red, green: green, blue: blue).opacity(alpha)
    }
    
    // Common defaults
    static let blue = CodableColor(red: 0.0, green: 0.478, blue: 1.0)
    static let purple = CodableColor(red: 0.686, green: 0.322, blue: 0.871)
    static let indigo = CodableColor(red: 0.345, green: 0.337, blue: 0.839)
    static let orange = CodableColor(red: 1.0, green: 0.584, blue: 0.0)
    static let red = CodableColor(red: 1.0, green: 0.231, blue: 0.188)
    static let green = CodableColor(red: 0.298, green: 0.851, blue: 0.392)
    static let white = CodableColor(red: 1.0, green: 1.0, blue: 1.0)
}

// MARK: - Gradient Stop

struct GradientStop: Codable, Equatable, Identifiable {
    let id: UUID
    var color: CodableColor
    var position: Double  // 0.0 ... 1.0
    
    init(id: UUID = UUID(), color: CodableColor, position: Double) {
        self.id = id
        self.color = color
        self.position = position
    }
}

// MARK: - Home Color Customization

/// Stores optional color overrides for home screen alarm card elements.
/// `nil` values mean "use the default color."
struct HomeColorCustomization: Codable, Equatable {
    /// Bell icon + "time until" text color (default: system blue)
    var bellIconColor: CodableColor?
    
    /// Snooze countdown icon + text color (default: purple)
    var snoozeColor: CodableColor?
    
    /// Snooze "remaining" icon + text color (default: indigo)
    var snoozeRemainingColor: CodableColor?
    
    /// Skip/Turn Off button foreground color (default: orange)
    var skipButtonColor: CodableColor?
    
    /// Skip hold gradient stops (3 stops, default: orange tones)
    var skipGradientStops: [GradientStop]?
    
    /// Skip hold gradient outline line width (default: 5)
    var skipGradientLineWidth: Double?
    
    /// Skip hold gradient outline opacity (default: 1.0)
    var skipGradientOpacity: Double?
    
    /// Whether the skip gradient outline uses liquid glass (default: false)
    var skipGradientUsesGlass: Bool?
    
    /// Toggle tint when alarm is on (default: system green/nil)
    var toggleOnTint: CodableColor?
    
    /// Toggle tint when alarm is snoozed (default: purple)
    var toggleSnoozeTint: CodableColor?
    
    /// Toggle tint when alarm is skipped (default: orange)
    var toggleSkippedTint: CodableColor?
    
    // MARK: - Alarm Card Display
    
    /// Alarm time text color (default: .primary)
    var alarmTimeColor: CodableColor?
    
    /// Alarm label / title text color (default: .secondary)
    var alarmLabelColor: CodableColor?
    
    /// Mission type icon color (default: .secondary)
    var missionIconColor: CodableColor?
    
    // MARK: - Toolbar Colors
    
    /// Toolbar text/icon color (gear, title, plus) — default: white
    var toolbarColor: CodableColor?
    
    /// MQTT pill text color — default: white
    var mqttTextColor: CodableColor?
    
    // MARK: - Home Assistant Widget (Alarm Mode)
    
    /// Banner icon color in alarm mode (default: .primary)
    var armButtonIconColor: CodableColor?
    
    /// Banner text color in alarm mode (default: .primary)
    var armButtonTextColor: CodableColor?
    
    /// Arm/Disarm hold button foreground color (default: red)
    var armButtonColor: CodableColor?
    
    /// Armed border gradient stops (3-color, matches skip/snooze pattern)
    var armButtonGradientStops: [GradientStop]?
    
    /// Armed border gradient line width (default: 5.0)
    var armButtonGradientLineWidth: Double?
    
    /// Armed border gradient opacity (default: 1.0)
    var armButtonGradientOpacity: Double?
    
    /// Whether armed border uses liquid glass overlay
    var armButtonGradientUsesGlass: Bool?
    
    // MARK: - Home Assistant Widget (HA-only mode, no alarm control)
    
    /// Widget icon color in HA mode (default: .blue)
    var hassWidgetIconColor: CodableColor?
    
    /// Widget text color in HA mode (default: .primary)
    var hassWidgetTextColor: CodableColor?
    
    // MARK: - Defaults
    
    static let `default` = HomeColorCustomization()
    
    /// Default skip gradient: 3 orange-toned stops
    static let defaultSkipGradientStops: [GradientStop] = [
        GradientStop(color: .orange, position: 0.0),
        GradientStop(color: CodableColor(red: 1.0, green: 0.7, blue: 0.15), position: 0.5),
        GradientStop(color: CodableColor(red: 0.9, green: 0.45, blue: 0.0), position: 1.0)
    ]
    
    static let defaultSkipGradientLineWidth: Double = 5.0
    
    mutating func resetToDefaults() {
        self = .default
    }
    
    /// Whether any customization is set (not all nil)
    var hasCustomizations: Bool {
        bellIconColor != nil ||
        snoozeColor != nil ||
        snoozeRemainingColor != nil ||
        skipButtonColor != nil ||
        skipGradientStops != nil ||
        skipGradientLineWidth != nil ||
        skipGradientOpacity != nil ||
        skipGradientUsesGlass != nil ||
        toggleOnTint != nil ||
        toggleSnoozeTint != nil ||
        toggleSkippedTint != nil ||
        alarmTimeColor != nil ||
        alarmLabelColor != nil ||
        missionIconColor != nil ||
        toolbarColor != nil ||
        mqttTextColor != nil ||
        armButtonIconColor != nil ||
        armButtonTextColor != nil ||
        armButtonColor != nil ||
        armButtonGradientStops != nil ||
        armButtonGradientLineWidth != nil ||
        armButtonGradientOpacity != nil ||
        armButtonGradientUsesGlass != nil ||
        hassWidgetIconColor != nil ||
        hassWidgetTextColor != nil
    }
    
    // MARK: - Resolved Colors (return custom or default)
    
    var resolvedBellColor: Color { bellIconColor?.color ?? .blue }
    var resolvedSnoozeColor: Color { snoozeColor?.color ?? .purple }
    var resolvedSnoozeRemainingColor: Color { snoozeRemainingColor?.color ?? .indigo }
    var resolvedSkipButtonColor: Color { skipButtonColor?.color ?? .orange }
    var resolvedToggleSnoozeTint: Color { toggleSnoozeTint?.color ?? .purple }
    var resolvedToggleSkippedTint: Color { toggleSkippedTint?.color ?? .orange }

    /// The single app-wide accent — toggles, media player, Settings, nav, and the
    /// default `.tint` all follow this. Driven by `toggleOnTint` (the color the
    /// media/status rows already use), falling back to system blue.
    var resolvedAccentColor: Color { toggleOnTint?.color ?? .blue }
    
    var resolvedAlarmTimeColor: Color? { alarmTimeColor?.color }
    var resolvedAlarmLabelColor: Color? { alarmLabelColor?.color }
    var resolvedMissionIconColor: Color? { missionIconColor?.color }
    
    var resolvedToolbarColor: Color { toolbarColor?.color ?? .white }
    var resolvedMQTTTextColor: Color { mqttTextColor?.color ?? .white }
    
    var resolvedSkipGradientColors: [Color] {
        let stops = skipGradientStops ?? Self.defaultSkipGradientStops
        return stops.sorted(by: { $0.position < $1.position }).map { $0.color.color }
    }
    
    var resolvedSkipGradientLineWidth: Double {
        skipGradientLineWidth ?? Self.defaultSkipGradientLineWidth
    }
    
    var resolvedSkipGradientOpacity: Double {
        skipGradientOpacity ?? 1.0
    }
    
    var resolvedSkipGradientUsesGlass: Bool {
        skipGradientUsesGlass ?? false
    }
    
    // MARK: - Resolved Widget Colors
    
    static let defaultArmButtonColor = CodableColor.red
    static let defaultArmButtonGradientLineWidth: Double = 5.0
    
    /// Default armed border gradient: 3 red-toned stops
    static let defaultArmButtonGradientStops: [GradientStop] = [
        GradientStop(color: .red, position: 0.0),
        GradientStop(color: CodableColor(red: 1.0, green: 0.4, blue: 0.3), position: 0.5),
        GradientStop(color: CodableColor(red: 0.8, green: 0.1, blue: 0.1), position: 1.0)
    ]
    
    /// Banner icon color (alarm mode)
    var resolvedArmButtonIconColor: Color {
        armButtonIconColor?.color ?? .primary
    }
    
    /// Banner text color (alarm mode)
    var resolvedArmButtonTextColor: Color {
        armButtonTextColor?.color ?? .primary
    }
    
    /// Arm/Disarm hold button foreground color
    var resolvedArmButtonColor: Color {
        armButtonColor?.color ?? Self.defaultArmButtonColor.color
    }
    
    /// Armed border gradient colors (3-stop)
    var resolvedArmButtonGradientColors: [Color] {
        let stops = armButtonGradientStops ?? Self.defaultArmButtonGradientStops
        return stops.sorted(by: { $0.position < $1.position }).map { $0.color.color }
    }
    
    var resolvedArmButtonGradientLineWidth: Double {
        armButtonGradientLineWidth ?? Self.defaultArmButtonGradientLineWidth
    }
    
    var resolvedArmButtonGradientOpacity: Double {
        armButtonGradientOpacity ?? 1.0
    }
    
    var resolvedArmButtonGradientUsesGlass: Bool {
        armButtonGradientUsesGlass ?? false
    }
    
    // MARK: - Resolved HA Widget Colors (HA-only mode)
    
    var resolvedHassWidgetIconColor: Color {
        hassWidgetIconColor?.color ?? .blue
    }
    
    var resolvedHassWidgetTextColor: Color {
        hassWidgetTextColor?.color ?? .primary
    }
}

// MARK: - Alarm Color Customization

/// Stores optional color overrides for the alarm screen (ActiveAlarmView + missions).
/// `nil` values mean "use the default color."
struct AlarmColorCustomization: Codable, Equatable {
    
    // MARK: - Snooze Button
    
    /// Snooze hold progress gradient stops (3 stops, default: purple tones)
    var snoozeGradientStops: [GradientStop]?
    
    /// Snooze hold gradient outline line width (default: 5)
    var snoozeGradientLineWidth: Double?
    
    /// Snooze hold gradient outline opacity (default: 1.0)
    var snoozeGradientOpacity: Double?
    
    /// Whether the snooze gradient outline uses liquid glass (default: false)
    var snoozeGradientUsesGlass: Bool?
    
    // MARK: - Grace Period
    
    /// Grace period icon + countdown text color (default: yellow)
    var gracePeriodColor: CodableColor?
    
    // MARK: - Shake Mission
    
    /// Shake progress bar tint color (default: green)
    var shakeProgressColor: CodableColor?
    
    /// Shake "Move the phone to start timer" idle text color (default: orange)
    var shakeIdleColor: CodableColor?
    
    // MARK: - Math Mission
    
    /// Math Dismiss / Submit button tint (default: blue)
    var mathSubmitColor: CodableColor?
    
    /// Math backspace button tint (default: gray)
    var mathBackspaceColor: CodableColor?
    
    // MARK: - Home Assistant Mission
    
    /// HA house.fill icon color (default: blue)
    var haIconColor: CodableColor?
    
    // MARK: - Alarm Display
    
    /// Clock time color (default: white)
    var timeColor: CodableColor?
    
    /// Alarm label text color (default: white)
    var labelColor: CodableColor?
    
    /// Mission title + icon color (e.g. "Shake to Dismiss", phone icon) (default: white)
    var missionTitleColor: CodableColor?
    
    // MARK: - Alarm Screen Widget Card
    
    /// Notes text color (default: .secondary / light gray)
    var widgetNotesColor: CodableColor?
    
    /// Command button label text color (default: .secondary)
    var widgetCommandLabelColor: CodableColor?
    
    /// Card glass variant: 0 = regular, 1 = clear, 2 = tinted (default: 2 with black tint)
    var widgetGlassVariant: Int?
    
    /// Card glass tint color components (when variant == tinted)
    var widgetGlassTintRed: Double?
    var widgetGlassTintGreen: Double?
    var widgetGlassTintBlue: Double?
    
    /// Card glass tint opacity (default: 0.1)
    var widgetGlassTintOpacity: Double?
    
    /// Card glass clear dimming (when variant == clear, default: 0.3)
    var widgetGlassClearDimming: Double?
    
    /// Command button glass variant: 0 = regular, 1 = clear, 2 = tinted (default: 0 regular)
    var widgetCommandGlassVariant: Int?
    
    /// Command button glass tint color components (when variant == tinted)
    var widgetCommandGlassTintRed: Double?
    var widgetCommandGlassTintGreen: Double?
    var widgetCommandGlassTintBlue: Double?
    
    /// Command button glass tint opacity (default: 0.3)
    var widgetCommandGlassTintOpacity: Double?
    
    // MARK: - Defaults
    
    static let `default` = AlarmColorCustomization()

    /// Unified "wake / attention" accent for the alarm screen's default palette.
    /// A warm sunrise amber that echoes the home screen's orange language so the
    /// two screens read as one system. Used for every progress / attention /
    /// confirm accent (grace countdown, shake + balance progress, math submit,
    /// HA icon) instead of the old yellow/green/blue scatter. Per-theme presets
    /// still override each of these individually.
    static let defaultAccent = Color(red: 1.0, green: 0.6, blue: 0.2)

    /// Default snooze gradient: cool blue tones. Snooze means "back to sleep",
    /// so it reads cool (the calm counterpart to the warm wake accent) and
    /// echoes the home screen's blue bell — distinct from the red dismiss.
    static let defaultSnoozeGradientStops: [GradientStop] = [
        GradientStop(color: CodableColor(red: 0.30, green: 0.55, blue: 0.95), position: 0.0),
        GradientStop(color: CodableColor(red: 0.24, green: 0.45, blue: 0.86), position: 0.5),
        GradientStop(color: CodableColor(red: 0.18, green: 0.35, blue: 0.76), position: 1.0)
    ]
    
    static let defaultSnoozeGradientLineWidth: Double = 5.0
    
    mutating func resetToDefaults() {
        self = .default
    }
    
    /// Whether any customization is set (not all nil)
    var hasCustomizations: Bool {
        snoozeGradientStops != nil ||
        snoozeGradientLineWidth != nil ||
        snoozeGradientOpacity != nil ||
        snoozeGradientUsesGlass != nil ||
        gracePeriodColor != nil ||
        shakeProgressColor != nil ||
        shakeIdleColor != nil ||
        mathSubmitColor != nil ||
        mathBackspaceColor != nil ||
        haIconColor != nil ||
        timeColor != nil ||
        labelColor != nil ||
        missionTitleColor != nil ||
        widgetNotesColor != nil ||
        widgetCommandLabelColor != nil ||
        widgetGlassVariant != nil ||
        widgetGlassTintRed != nil ||
        widgetGlassTintGreen != nil ||
        widgetGlassTintBlue != nil ||
        widgetGlassTintOpacity != nil ||
        widgetGlassClearDimming != nil ||
        widgetCommandGlassVariant != nil ||
        widgetCommandGlassTintRed != nil ||
        widgetCommandGlassTintGreen != nil ||
        widgetCommandGlassTintBlue != nil ||
        widgetCommandGlassTintOpacity != nil
    }
    
    // MARK: - Resolved Colors (return custom or default)
    
    // Progress / attention / confirm accents all default to the single unified
    // amber accent so a mission screen no longer looks like a different app.
    var resolvedGracePeriodColor: Color { gracePeriodColor?.color ?? Self.defaultAccent }
    var resolvedShakeProgressColor: Color { shakeProgressColor?.color ?? Self.defaultAccent }
    var resolvedShakeIdleColor: Color { shakeIdleColor?.color ?? Self.defaultAccent }
    var resolvedMathSubmitColor: Color { mathSubmitColor?.color ?? Self.defaultAccent }
    var resolvedMathBackspaceColor: Color { mathBackspaceColor?.color ?? Color(white: 0.5) }
    var resolvedHAIconColor: Color { haIconColor?.color ?? Self.defaultAccent }
    // Time + label sit directly over the wallpaper — keep them bright white and
    // let the view add a shadow for contrast over any image.
    var resolvedTimeColor: Color { timeColor?.color ?? .white }
    var resolvedLabelColor: Color { labelColor?.color ?? .white }
    // Mission title/body text sits on glass cards that adapt to light/dark, so
    // default to .primary (adaptive) — a hardcoded white washed out on the
    // light-appearance glass. Presets can still pin an explicit color.
    var resolvedMissionTitleColor: Color { missionTitleColor?.color ?? .primary }
    
    var resolvedSnoozeGradientColors: [Color] {
        let stops = snoozeGradientStops ?? Self.defaultSnoozeGradientStops
        return stops.sorted(by: { $0.position < $1.position }).map { $0.color.color }
    }
    
    var resolvedSnoozeGradientLineWidth: Double {
        snoozeGradientLineWidth ?? Self.defaultSnoozeGradientLineWidth
    }
    
    var resolvedSnoozeGradientOpacity: Double {
        snoozeGradientOpacity ?? 1.0
    }
    
    var resolvedSnoozeGradientUsesGlass: Bool {
        snoozeGradientUsesGlass ?? false
    }
    
    // MARK: - Resolved Widget Card Colors
    
    var resolvedWidgetNotesColor: Color {
        widgetNotesColor?.color ?? .primary.opacity(0.75)
    }

    var resolvedWidgetCommandLabelColor: Color {
        widgetCommandLabelColor?.color ?? .primary.opacity(0.75)
    }
    
    /// Resolved glass effect for the widget card
    var resolvedWidgetGlass: Glass {
        switch widgetGlassVariant ?? 2 {
        case 1: return .clear
        case 2:
            let tintColor = Color(
                red: widgetGlassTintRed ?? 0,
                green: widgetGlassTintGreen ?? 0,
                blue: widgetGlassTintBlue ?? 0
            ).opacity(widgetGlassTintOpacity ?? 0.1)
            return .regular.tint(tintColor)
        default: return .regular
        }
    }
    
    /// Clear dimming for widget card (when glass variant == clear)
    var resolvedWidgetClearDimming: Double {
        if (widgetGlassVariant ?? 2) == 1 {
            return widgetGlassClearDimming ?? 0.3
        }
        return 0
    }
    
    /// Resolved glass effect for command buttons inside the widget
    var resolvedWidgetCommandGlass: Glass {
        switch widgetCommandGlassVariant ?? 0 {
        case 1: return .clear
        case 2:
            let tintColor = Color(
                red: widgetCommandGlassTintRed ?? 0,
                green: widgetCommandGlassTintGreen ?? 0,
                blue: widgetCommandGlassTintBlue ?? 0
            ).opacity(widgetCommandGlassTintOpacity ?? 0.3)
            return .regular.tint(tintColor)
        default: return .regular
        }
    }
    
    /// Whether the widget card has any customizations (for reset button state)
    var hasWidgetCustomizations: Bool {
        widgetNotesColor != nil ||
        widgetCommandLabelColor != nil ||
        widgetGlassVariant != nil ||
        widgetGlassTintRed != nil ||
        widgetGlassTintGreen != nil ||
        widgetGlassTintBlue != nil ||
        widgetGlassTintOpacity != nil ||
        widgetGlassClearDimming != nil ||
        widgetCommandGlassVariant != nil ||
        widgetCommandGlassTintRed != nil ||
        widgetCommandGlassTintGreen != nil ||
        widgetCommandGlassTintBlue != nil ||
        widgetCommandGlassTintOpacity != nil
    }
    
    mutating func resetWidgetToDefaults() {
        widgetNotesColor = nil
        widgetCommandLabelColor = nil
        widgetGlassVariant = nil
        widgetGlassTintRed = nil
        widgetGlassTintGreen = nil
        widgetGlassTintBlue = nil
        widgetGlassTintOpacity = nil
        widgetGlassClearDimming = nil
        widgetCommandGlassVariant = nil
        widgetCommandGlassTintRed = nil
        widgetCommandGlassTintGreen = nil
        widgetCommandGlassTintBlue = nil
        widgetCommandGlassTintOpacity = nil
    }
}

