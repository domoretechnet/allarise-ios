//
//  DeviceSettings.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import Compression
import Foundation
import Observation
import SwiftUI
import UIKit

enum SnoozeMode: String, Codable, CaseIterable, Identifiable {
    case tap = "Tap to Snooze"
    case hold = "Hold to Snooze"
    case homeAssistant = "Home Assistant"
    case disabled = "Snooze Disabled"
    
    var id: String { rawValue }
    
    /// Modes available in the standard snooze picker (excludes HA — that's auto-selected)
    static var standardCases: [SnoozeMode] {
        [.tap, .hold, .disabled]
    }
    
    /// All modes including Home Assistant (shown when mission is HA)
    static var allWithHA: [SnoozeMode] {
        [.tap, .hold, .homeAssistant, .disabled]
    }
}

enum SkipAlarmMode: String, CaseIterable, Identifiable {
    case tap = "Tap to Skip Alarm"
    case hold = "Hold to Skip Alarm"
    case disabled = "Skip Alarm Disabled"
    
    var id: String { rawValue }
}

@Observable
final class DeviceSettings {
    static let shared = DeviceSettings()
    
    // Device Identity
    var deviceName: String {
        didSet {
            UserDefaults.standard.set(deviceName, forKey: "deviceName")
            KeychainHelper.shared.save(deviceName, forKey: "kc.deviceName")
        }
    }
    
    var sanitizedDeviceName: String {
        deviceName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
    }
    
    // MQTT Connection
    var mqttEnabled: Bool {
        didSet { UserDefaults.standard.set(mqttEnabled, forKey: "mqttEnabled") }
    }
    
    var mqttInternalHost: String {
        didSet {
            UserDefaults.standard.set(mqttInternalHost, forKey: "mqttInternalHost")
            KeychainHelper.shared.save(mqttInternalHost, forKey: "kc.mqttInternalHost")
        }
    }
    
    var mqttInternalPort: Int {
        didSet {
            UserDefaults.standard.set(mqttInternalPort, forKey: "mqttInternalPort")
            KeychainHelper.shared.save("\(mqttInternalPort)", forKey: "kc.mqttInternalPort")
        }
    }
    
    var mqttExternalHost: String {
        didSet {
            UserDefaults.standard.set(mqttExternalHost, forKey: "mqttExternalHost")
            KeychainHelper.shared.save(mqttExternalHost, forKey: "kc.mqttExternalHost")
        }
    }
    
    var mqttExternalPort: Int {
        didSet {
            UserDefaults.standard.set(mqttExternalPort, forKey: "mqttExternalPort")
            KeychainHelper.shared.save("\(mqttExternalPort)", forKey: "kc.mqttExternalPort")
        }
    }
    
    var mqttUseTLS: Bool {
        didSet {
            UserDefaults.standard.set(mqttUseTLS, forKey: "mqttUseTLS")
            KeychainHelper.shared.save(mqttUseTLS ? "true" : "false", forKey: "kc.mqttUseTLS")
        }
    }
    
    /// True when the last write of an MQTT credential to the Keychain failed.
    /// The credential is still held in memory for this session, but it will not
    /// survive a relaunch — the Authentication section surfaces this so the user
    /// finds out at the moment of the action rather than at the next cold start.
    /// Not persisted: it describes this session's write, nothing more.
    var mqttCredentialSaveFailed: Bool = false

    var mqttUsername: String {
        didSet {
            if !KeychainHelper.shared.save(mqttUsername, forKey: "mqttUsername") {
                mqttCredentialSaveFailed = true
                AppLogger.shared.log("Keychain write failed for MQTT username", category: .mqtt)
            } else if mqttCredentialSaveFailed {
                mqttCredentialSaveFailed = false
            }
            // Remove any legacy UserDefaults copy so credentials aren't stored twice
            UserDefaults.standard.removeObject(forKey: "mqttUsername")
        }
    }

    var mqttPassword: String {
        didSet {
            if !KeychainHelper.shared.save(mqttPassword, forKey: "mqttPassword") {
                mqttCredentialSaveFailed = true
                AppLogger.shared.log("Keychain write failed for MQTT password", category: .mqtt)
            } else if mqttCredentialSaveFailed {
                mqttCredentialSaveFailed = false
            }
        }
    }
    
    var mqttTopicPrefix: String {
        didSet {
            UserDefaults.standard.set(mqttTopicPrefix, forKey: "mqttTopicPrefix")
            KeychainHelper.shared.save(mqttTopicPrefix, forKey: "kc.mqttTopicPrefix")
        }
    }
    
    var homeSSIDs: [String] {
        didSet {
            UserDefaults.standard.set(homeSSIDs, forKey: "homeSSIDs")
            if let json = try? JSONEncoder().encode(homeSSIDs),
               let str = String(data: json, encoding: .utf8) {
                KeychainHelper.shared.save(str, forKey: "kc.homeSSIDs")
            }
        }
    }
    
    // Debug: Force assume on home network (bypasses WiFi detection)
    var debugForceHomeNetwork: Bool {
        didSet { UserDefaults.standard.set(debugForceHomeNetwork, forKey: "debugForceHomeNetwork") }
    }
    
    // Always use external connection (bypass home network detection)
    var forceExternalConnection: Bool {
        didSet { UserDefaults.standard.set(forceExternalConnection, forKey: "forceExternalConnection") }
    }
    
    // MQTT Publish Settings — retained is always on for Home Assistant compatibility
    var mqttPublishRetained: Bool { true }
    
    // MQTT Inbound Commands
    var mqttAllowInboundCommands: Bool {
        didSet { UserDefaults.standard.set(mqttAllowInboundCommands, forKey: "mqttAllowInboundCommands") }
    }
    
    var skipAlarmMode: SkipAlarmMode {
        didSet { saveAndSync(skipAlarmMode.rawValue, forKey: "skipAlarmMode") }
    }
    
    var skipAlarmHoldDuration: Double {
        didSet { saveAndSync(skipAlarmHoldDuration, forKey: "skipAlarmHoldDuration") }
    }
    
    // Legacy computed properties for backward compatibility with existing code
    var enableSkipToday: Bool {
        skipAlarmMode != .disabled
    }
    
    var skipTodayHoldDuration: Double {
        skipAlarmHoldDuration
    }
    
    var defaultSnoozeDuration: Int {
        didSet { saveAndSync(defaultSnoozeDuration, forKey: "defaultSnoozeDuration") }
    }
    
    var defaultMaxSnoozeCount: Int {
        didSet { saveAndSync(defaultMaxSnoozeCount, forKey: "defaultMaxSnoozeCount") }
    }
    
    var snoozeMode: SnoozeMode {
        didSet { saveAndSync(snoozeMode.rawValue, forKey: "snoozeMode") }
    }
    
    var snoozeHoldDuration: Double {
        didSet { saveAndSync(snoozeHoldDuration, forKey: "snoozeHoldDuration") }
    }
    
    // Legacy computed property for backward compatibility with existing code
    var snoozeRequiresHold: Bool {
        snoozeMode == .hold
    }
    
    var defaultMissionType: MissionType {
        didSet { saveAndSync(defaultMissionType.rawValue, forKey: "defaultMissionType") }
    }

    // Default Tap (missionless) dismiss configuration. A default of single tap
    // (mode .tap, count 1) keeps new alarms missionless; count>1 or hold makes
    // them real missions — all resolved through `defaultMission(for: .none)`.
    var defaultTapDismissMode: TapDismissMode {
        didSet { saveAndSync(defaultTapDismissMode.rawValue, forKey: "defaultTapDismissMode") }
    }
    var defaultTapCount: Int {
        didSet { saveAndSync(defaultTapCount, forKey: "defaultTapCount") }
    }
    var defaultTapHoldDuration: Double {
        didSet { saveAndSync(defaultTapHoldDuration, forKey: "defaultTapHoldDuration") }
    }

    // Default mission configuration options
    var defaultShakeMode: ShakeMode {
        didSet { saveAndSync(defaultShakeMode.rawValue, forKey: "defaultShakeMode") }
    }
    var defaultShakeDuration: Int {
        didSet { saveAndSync(defaultShakeDuration, forKey: "defaultShakeDuration") }
    }
    var defaultShakeCount: Int {
        didSet { saveAndSync(defaultShakeCount, forKey: "defaultShakeCount") }
    }
    var defaultShakeIntensity: ShakeIntensity {
        didSet { saveAndSync(defaultShakeIntensity.rawValue, forKey: "defaultShakeIntensity") }
    }
    var defaultMathProblemCount: Int {
        didSet { saveAndSync(defaultMathProblemCount, forKey: "defaultMathProblemCount") }
    }
    var defaultMathDifficulty: MathDifficulty {
        didSet { saveAndSync(defaultMathDifficulty.rawValue, forKey: "defaultMathDifficulty") }
    }
    var defaultBalanceDifficulty: BalanceDifficulty {
        didSet { saveAndSync(defaultBalanceDifficulty.rawValue, forKey: "defaultBalanceDifficulty") }
    }
    /// Global Balance overrides layered on the difficulty preset (0 = use the
    /// preset). Mirror the per-mission balance*Override fields.
    var defaultBalanceHold: Double {
        didSet { saveAndSync(defaultBalanceHold, forKey: "defaultBalanceHold") }
    }
    var defaultBalanceZoneRadius: Double {
        didSet { saveAndSync(defaultBalanceZoneRadius, forKey: "defaultBalanceZoneRadius") }
    }
    var defaultBalanceZoneDwell: Double {
        didSet { saveAndSync(defaultBalanceZoneDwell, forKey: "defaultBalanceZoneDwell") }
    }
    var defaultBlockDropDifficulty: BlockDropDifficulty {
        didSet { saveAndSync(defaultBlockDropDifficulty.rawValue, forKey: "defaultBlockDropDifficulty") }
    }
    var defaultMeteorDifficulty: MeteorDifficulty {
        didSet { saveAndSync(defaultMeteorDifficulty.rawValue, forKey: "defaultMeteorDifficulty") }
    }
    // Global Meteor fine-tune overrides layered on the difficulty preset
    // (0 = no override, use the preset — same pattern as defaultBalance*).
    var defaultMeteorTargets: Int {
        didSet { saveAndSync(defaultMeteorTargets, forKey: "defaultMeteorTargets") }
    }
    var defaultMeteorFireInterval: Double {
        didSet { saveAndSync(defaultMeteorFireInterval, forKey: "defaultMeteorFireInterval") }
    }
    // Global Block Drop fine-tune overrides layered on the difficulty preset
    // (mirrors the defaultBalance* overrides). 0 = no override — except
    // garbage rows and gaps-aligned, where 0 is a real value, so -1 = no override
    // (gaps-aligned is stored as an Int: -1 preset / 0 false / 1 true).
    var defaultBlockDropLines: Int {
        didSet { saveAndSync(defaultBlockDropLines, forKey: "defaultBlockDropLines") }
    }
    var defaultBlockDropInterval: Double {
        didSet { saveAndSync(defaultBlockDropInterval, forKey: "defaultBlockDropInterval") }
    }
    var defaultBlockDropGarbageRows: Int {
        didSet { saveAndSync(defaultBlockDropGarbageRows, forKey: "defaultBlockDropGarbageRows") }
    }
    var defaultBlockDropGapWidth: Int {
        didSet { saveAndSync(defaultBlockDropGapWidth, forKey: "defaultBlockDropGapWidth") }
    }
    var defaultBlockDropGapsAligned: Int {
        didSet { saveAndSync(defaultBlockDropGapsAligned, forKey: "defaultBlockDropGapsAligned") }
    }
    var defaultHASnoozeMode: HASnoozeMode {
        didSet { saveAndSync(defaultHASnoozeMode.rawValue, forKey: "defaultHASnoozeMode") }
    }
    var defaultHAFallbackMission: MissionType {
        didSet { saveAndSync(defaultHAFallbackMission.rawValue, forKey: "defaultHAFallbackMission") }
    }
    
    // Dismiss fallback config defaults
    var defaultHAFallbackShakeMode: ShakeMode {
        didSet { saveAndSync(defaultHAFallbackShakeMode.rawValue, forKey: "defaultHAFallbackShakeMode") }
    }
    var defaultHAFallbackShakeDuration: Int {
        didSet { saveAndSync(defaultHAFallbackShakeDuration, forKey: "defaultHAFallbackShakeDuration") }
    }
    var defaultHAFallbackShakeCount: Int {
        didSet { saveAndSync(defaultHAFallbackShakeCount, forKey: "defaultHAFallbackShakeCount") }
    }
    var defaultHAFallbackShakeIntensity: ShakeIntensity {
        didSet { saveAndSync(defaultHAFallbackShakeIntensity.rawValue, forKey: "defaultHAFallbackShakeIntensity") }
    }
    var defaultHAFallbackMathProblemCount: Int {
        didSet { saveAndSync(defaultHAFallbackMathProblemCount, forKey: "defaultHAFallbackMathProblemCount") }
    }
    var defaultHAFallbackMathDifficulty: MathDifficulty {
        didSet { saveAndSync(defaultHAFallbackMathDifficulty.rawValue, forKey: "defaultHAFallbackMathDifficulty") }
    }
    var defaultHAFallbackGracePeriod: Double {
        didSet { saveAndSync(defaultHAFallbackGracePeriod, forKey: "defaultHAFallbackGracePeriod") }
    }
    
    // Snooze fallback defaults (snooze mode when MQTT offline and haSnoozeMode == .homeAssistant)
    var defaultHASnoozeFallback: SnoozeMode {
        didSet { saveAndSync(defaultHASnoozeFallback.rawValue, forKey: "defaultHASnoozeFallback") }
    }
    var defaultHASnoozeFallbackHoldDuration: Double {
        didSet { saveAndSync(defaultHASnoozeFallbackHoldDuration, forKey: "defaultHASnoozeFallbackHoldDuration") }
    }
    
    /// Build a Mission struct from the current default settings (uses `defaultMissionType`)
    var defaultMission: Mission {
        defaultMission(for: defaultMissionType)
    }
    
    /// Build a Mission preset for a specific type.
    ///
    /// If the requested type matches `defaultMissionType`, the user's global
    /// settings for that type are used. Otherwise, hardcoded app defaults are
    /// returned so every mission type starts with sensible values.
    func defaultMission(for type: MissionType) -> Mission {
        var m = Mission()
        m.type = type
        
        switch type {
        case .none:
            // Tap defaults are global (unlike the other types, they're not gated on
            // `defaultMissionType == .none`): the Tap dismiss config applies to every
            // alarm's Tap slot, and a single-tap default still yields a missionless
            // alarm downstream via Mission.tapDismissIsMission.
            m.tapDismissMode = defaultTapDismissMode
            m.tapCount = defaultTapCount
            m.tapHoldDuration = defaultTapHoldDuration

        case .shake:
            if defaultMissionType == .shake {
                // User has configured Shake globally — use their settings
                m.shakeMode = defaultShakeMode
                m.shakeDuration = defaultShakeDuration
                m.shakeCount = defaultShakeCount
                m.shakeIntensity = defaultShakeIntensity
            } else {
                // App defaults for Shake
                m.shakeMode = .duration
                m.shakeDuration = 10
                m.shakeCount = 20
                m.shakeIntensity = .medium
            }
            
        case .math:
            if defaultMissionType == .math {
                // User has configured Math globally — use their settings
                m.mathProblemCount = defaultMathProblemCount
                m.mathDifficulty = defaultMathDifficulty
            } else {
                // App defaults for Math
                m.mathProblemCount = 3
                m.mathDifficulty = .easy
            }

        case .balanceBall:
            if defaultMissionType == .balanceBall {
                // User has configured Balance Ball globally — use their settings,
                // including any hold/target overrides layered on the preset.
                m.balanceDifficulty = defaultBalanceDifficulty
                m.balanceHoldOverride = defaultBalanceHold > 0 ? defaultBalanceHold : nil
                m.balanceZoneRadiusOverride = defaultBalanceZoneRadius > 0 ? defaultBalanceZoneRadius : nil
                m.balanceZoneDwellOverride = defaultBalanceZoneDwell > 0 ? defaultBalanceZoneDwell : nil
            } else {
                // App default for Balance Ball
                m.balanceDifficulty = .medium
            }

        case .blockDrop:
            if defaultMissionType == .blockDrop {
                // User has configured Block Drop globally — use their settings,
                // including any fine-tune overrides layered on the preset.
                m.blockDropDifficulty = defaultBlockDropDifficulty
                m.blockDropLinesOverride = defaultBlockDropLines > 0 ? defaultBlockDropLines : nil
                m.blockDropIntervalOverride = defaultBlockDropInterval > 0 ? defaultBlockDropInterval : nil
                m.blockDropGarbageRowsOverride = defaultBlockDropGarbageRows >= 0 ? defaultBlockDropGarbageRows : nil
                m.blockDropGapWidthOverride = defaultBlockDropGapWidth > 0 ? defaultBlockDropGapWidth : nil
                m.blockDropGapsAlignedOverride = defaultBlockDropGapsAligned >= 0 ? (defaultBlockDropGapsAligned == 1) : nil
            } else {
                // App default for Block Drop
                m.blockDropDifficulty = .medium
            }

        case .meteor:
            if defaultMissionType == .meteor {
                // User has configured Meteor globally — use their settings,
                // including any targets/fire-rate overrides on the preset.
                m.meteorDifficulty = defaultMeteorDifficulty
                m.meteorTargetsOverride = defaultMeteorTargets > 0 ? defaultMeteorTargets : nil
                m.meteorFireIntervalOverride = defaultMeteorFireInterval > 0 ? defaultMeteorFireInterval : nil
            } else {
                // App default for Meteor
                m.meteorDifficulty = .medium
            }

        case .homeAssistant:
            if defaultMissionType == .homeAssistant {
                // User has configured HA globally — use their settings
                m.haSnoozeMode = defaultHASnoozeMode
                m.haFallbackMission = defaultHAFallbackMission
                m.haFallbackShakeMode = defaultHAFallbackShakeMode
                m.haFallbackShakeDuration = defaultHAFallbackShakeDuration
                m.haFallbackShakeCount = defaultHAFallbackShakeCount
                m.haFallbackShakeIntensity = defaultHAFallbackShakeIntensity
                m.haFallbackMathProblemCount = defaultHAFallbackMathProblemCount
                m.haFallbackMathDifficulty = defaultHAFallbackMathDifficulty
                m.haFallbackGracePeriod = defaultHAFallbackGracePeriod
                m.haSnoozeFallback = defaultHASnoozeFallback
                m.haSnoozeFallbackHoldDuration = defaultHASnoozeFallbackHoldDuration
            } else {
                // App defaults for Home Assistant
                m.haSnoozeMode = .normal
                m.haFallbackMission = .none
                m.haFallbackShakeMode = .duration
                m.haFallbackShakeDuration = 10
                m.haFallbackShakeCount = 20
                m.haFallbackShakeIntensity = .medium
                m.haFallbackMathProblemCount = 3
                m.haFallbackMathDifficulty = .easy
                m.haFallbackGracePeriod = 0
                m.haSnoozeFallback = .hold
                m.haSnoozeFallbackHoldDuration = 1.5
            }
            
        case .alert:
            break
        }

        return m
    }

    /// Inverse of `defaultMission(for:)`: decompose an edited Mission back into
    /// the per-type global default fields. Used by the Alarm Defaults screen,
    /// which now edits the default mission through the same MissionSlotEditorSheet
    /// the alarm editor uses. Home Assistant / Alert can't be global defaults and
    /// are ignored. Only the chosen type's fields are written — the other types'
    /// stored defaults are left alone.
    func applyDefaultMission(_ m: Mission) {
        switch m.type {
        case .none:
            defaultTapDismissMode = m.tapDismissMode
            defaultTapCount = m.tapCount
            defaultTapHoldDuration = m.tapHoldDuration
        case .shake:
            defaultShakeMode = m.shakeMode
            defaultShakeDuration = m.shakeDuration
            defaultShakeCount = m.shakeCount
            defaultShakeIntensity = m.shakeIntensity
        case .math:
            defaultMathProblemCount = m.mathProblemCount
            defaultMathDifficulty = m.mathDifficulty
        case .balanceBall:
            defaultBalanceDifficulty = m.balanceDifficulty
            defaultBalanceHold = m.balanceHoldOverride ?? 0
            defaultBalanceZoneRadius = m.balanceZoneRadiusOverride ?? 0
            defaultBalanceZoneDwell = m.balanceZoneDwellOverride ?? 0
        case .blockDrop:
            defaultBlockDropDifficulty = m.blockDropDifficulty
            defaultBlockDropLines = m.blockDropLinesOverride ?? 0
            defaultBlockDropInterval = m.blockDropIntervalOverride ?? 0
            defaultBlockDropGarbageRows = m.blockDropGarbageRowsOverride ?? -1
            defaultBlockDropGapWidth = m.blockDropGapWidthOverride ?? 0
            defaultBlockDropGapsAligned = m.blockDropGapsAlignedOverride.map { $0 ? 1 : 0 } ?? -1
        case .meteor:
            defaultMeteorDifficulty = m.meteorDifficulty
            defaultMeteorTargets = m.meteorTargetsOverride ?? 0
            defaultMeteorFireInterval = m.meteorFireIntervalOverride ?? 0
        case .homeAssistant, .alert:
            return
        }
        defaultMissionType = m.type
    }

    // Mission Grace Period — mute alarm sound while mission is active, resume after timeout
    var enableMissionGracePeriod: Bool {
        didSet { saveAndSync(enableMissionGracePeriod, forKey: "enableMissionGracePeriod") }
    }
    
    // Custom override for the grace period duration (0 = use dynamic formula)
    var defaultGracePeriodOverride: Double {
        didSet { saveAndSync(defaultGracePeriodOverride, forKey: "defaultGracePeriodOverride") }
    }

    // Combine the missions of alarms the user slept through (al-bee.7).
    //
    var defaultAlarmSound: String {
        didSet { saveAndSync(defaultAlarmSound, forKey: "defaultAlarmSound") }
    }

    // Default wake-up radio station applied to new alarms (nil = none).
    // The alarm tone above remains the guaranteed fallback — see 24-RADIO.md.
    var defaultRadioStation: RadioStation? {
        didSet {
            if let station = defaultRadioStation, let data = try? JSONEncoder().encode(station) {
                UserDefaults.standard.set(data, forKey: "defaultRadioStation")
            } else {
                UserDefaults.standard.removeObject(forKey: "defaultRadioStation")
            }
        }
    }
    
    // Alarm volume level (0.0 to 1.0), default is 1.0 (100%)
    var alarmVolumeLevel: Double {
        didSet { saveAndSync(alarmVolumeLevel, forKey: "alarmVolumeLevel") }
    }
    
    // Media alert volume level (0.0 to 1.0), default is 0.75 (75%).
    // Used as the default volume for HA-initiated media/TTS alerts.
    // Can be overridden per-alert via the MQTT "volume" field, or
    // set from Home Assistant via media_player.volume_set.
    var mediaAlertVolume: Double {
        didSet { saveAndSync(mediaAlertVolume, forKey: "mediaAlertVolume") }
    }
    
    // MARK: - Alert Configuration (HA Alert Alarms)
    
    // Default sound ID for HA-triggered alert alarms. Empty string = use global default sound.
    var alertDefaultSound: String {
        didSet { UserDefaults.standard.set(alertDefaultSound, forKey: "alertDefaultSound") }
    }
    
    // Whether HA alert alarms vibrate the phone
    var alertVibrationEnabled: Bool {
        didSet { UserDefaults.standard.set(alertVibrationEnabled, forKey: "alertVibrationEnabled") }
    }
    
    // Whether media_url audio loops continuously during HA alert alarms
    var alertLoopMedia: Bool {
        didSet { UserDefaults.standard.set(alertLoopMedia, forKey: "alertLoopMedia") }
    }
    
    // Seconds to wait between loops of media_url audio (0 = immediate)
    var alertLoopDelay: Double {
        didSet { UserDefaults.standard.set(alertLoopDelay, forKey: "alertLoopDelay") }
    }
    
    // MARK: - NWS Weather Alerts (Experimental)

    /// Master toggle for NWS weather alert monitoring.
    /// Persisted to iCloud KV store so it survives app reinstalls and syncs across devices.
    var nwsAlertsEnabled: Bool {
        didSet {
            NSUbiquitousKeyValueStore.default.set(nwsAlertsEnabled, forKey: "nwsAlertsEnabled")
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    /// NWS weather alerts became a DEBUG-only feature. For production users who
    /// had it enabled, disable it once (so it stops running and the stored state
    /// is clean). The `start()` call sites are also `#if DEBUG`, so this is
    /// belt-and-suspenders. No-op in DEBUG, where NWS remains available.
    func disableNWSForProductionIfNeeded() {
        #if !DEBUG
        guard !UserDefaults.standard.bool(forKey: "nwsProdDisabledMigrationV1") else { return }
        if nwsAlertsEnabled {
            nwsAlertsEnabled = false
            print("[Migration] Disabled NWS weather alerts for production build")
        }
        UserDefaults.standard.set(true, forKey: "nwsProdDisabledMigrationV1")
        #endif
    }

    /// JSON-encoded array of monitored locations.
    /// Persisted to iCloud KV store so locations survive app reinstalls.
    var nwsMonitoredLocationsData: Data {
        didSet {
            NSUbiquitousKeyValueStore.default.set(nwsMonitoredLocationsData, forKey: "nwsMonitoredLocations")
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    /// Typed accessor for monitored locations.
    var nwsMonitoredLocations: [NWSMonitoredLocation] {
        get {
            (try? JSONDecoder().decode([NWSMonitoredLocation].self, from: nwsMonitoredLocationsData)) ?? []
        }
        set {
            nwsMonitoredLocationsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    /// Syncs NWS alert settings from iCloud KV store on a background thread.
    /// Call this from AppDelegate after DeviceSettings has initialised so that
    /// NSUbiquitousKeyValueStore.default (which can block 5-15s on the main thread
    /// while the iCloud daemon starts) never runs during app init.
    /// On reinstall UserDefaults is empty; iCloud has the user's previous values.
    func syncNWSSettingsFromiCloud() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // First access to NSUbiquitousKeyValueStore.default may block briefly —
            // safe here because we're on a background thread.
            let store = NSUbiquitousKeyValueStore.default

            var updatedEnabled: Bool? = nil
            var updatedData: Data? = nil

            if store.object(forKey: "nwsAlertsEnabled") != nil {
                let cloudEnabled = store.bool(forKey: "nwsAlertsEnabled")
                // Only update if different from UserDefaults (avoids spurious didSet writes)
                if cloudEnabled != UserDefaults.standard.bool(forKey: "nwsAlertsEnabled") {
                    updatedEnabled = cloudEnabled
                }
            } else if UserDefaults.standard.object(forKey: "nwsAlertsEnabled") != nil {
                // Migrate local value to iCloud
                let local = UserDefaults.standard.bool(forKey: "nwsAlertsEnabled")
                store.set(local, forKey: "nwsAlertsEnabled")
            }

            let cloudData = store.data(forKey: "nwsMonitoredLocations") ?? Data()
            let localData = UserDefaults.standard.data(forKey: "nwsMonitoredLocations") ?? Data()
            if !cloudData.isEmpty && cloudData != localData {
                updatedData = cloudData
            } else if !localData.isEmpty && cloudData.isEmpty {
                store.set(localData, forKey: "nwsMonitoredLocations")
            }

            // Snapshot to let bindings — Swift 6 disallows capturing var in concurrent closures.
            let finalEnabled = updatedEnabled
            let finalData = updatedData
            guard finalEnabled != nil || finalData != nil else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let v = finalEnabled { self.nwsAlertsEnabled = v }
                if let d = finalData    { self.nwsMonitoredLocationsData = d }
                // AppDelegate's launch-time start() check runs synchronously,
                // before this background iCloud read finishes. Sync the service
                // to the resolved flag so polling matches it (start picks up any
                // newly-synced locations too; start() is idempotent).
                // DEBUG-only: NWS is gated out of production, so never (re)arm it
                // there even if an iCloud value says enabled.
                #if DEBUG
                if self.nwsAlertsEnabled {
                    NWSAlertService.shared.start()
                } else {
                    NWSAlertService.shared.stop()
                }
                #else
                NWSAlertService.shared.stop()
                #endif
            }
        }
    }

    /// Reads mqttUsername and mqttPassword from Keychain on a background thread
    /// and updates the properties on the main actor. Call this from AppDelegate
    /// after DeviceSettings has initialised so SecItemCopyMatching (synchronous
    /// XPC to securityd) never blocks the main thread during app startup.
    func syncMQTTCredentialsFromKeychain() {
        // No [weak self] capture — avoids Swift 6 actor-crossing errors that appear
        // when an @Observable self is captured in Task.detached. The singleton is
        // accessed directly inside MainActor.run instead.
        Task.detached(priority: .utility) {
            let username = KeychainHelper.shared.read(forKey: "mqttUsername") ?? ""
            let password = KeychainHelper.shared.read(forKey: "mqttPassword") ?? ""
            guard !username.isEmpty || !password.isEmpty else { return }
            await MainActor.run {
                // Only set if non-empty to avoid triggering didSet with blank values.
                // didSet writes back to Keychain — idempotent since same value.
                if !username.isEmpty { DeviceSettings.shared.mqttUsername = username }
                if !password.isEmpty { DeviceSettings.shared.mqttPassword = password }
            }
        }
    }

    /// NWS alert IDs that have already been seen (deduplication).
    var nwsSeenAlertIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "nwsSeenAlertIDs") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "nwsSeenAlertIDs") }
    }

    // Whether alarms vibrate the phone (via Live Activity AlertConfiguration sound)
    var alarmVibrationEnabled: Bool {
        didSet { saveAndSync(alarmVibrationEnabled, forKey: "alarmVibrationEnabled") }
    }
    
    // Whether alarm volume fades in gradually (only when vibration is off)
    var alarmFadeInEnabled: Bool {
        didSet { saveAndSync(alarmFadeInEnabled, forKey: "alarmFadeInEnabled") }
    }
    
    // Fade-in duration in minutes (1–15). Converted to seconds when passed to VolumeManager.
    var alarmFadeInDuration: Int {
        didSet { saveAndSync(alarmFadeInDuration, forKey: "alarmFadeInDuration") }
    }
    
    // MARK: - Sleep Sounds

    var lastSleepSoundName: String {
        didSet { UserDefaults.standard.set(lastSleepSoundName, forKey: "lastSleepSoundName") }
    }

    var lastSleepSoundVolume: Double {
        didSet { UserDefaults.standard.set(lastSleepSoundVolume, forKey: "lastSleepSoundVolume") }
    }

    var lastSleepHours: Int {
        didSet { UserDefaults.standard.set(lastSleepHours, forKey: "lastSleepHours") }
    }

    /// Sleep timer duration in minutes (15/30-min presets plus whole hours).
    /// Supersedes `lastSleepHours`, which is kept for migration.
    var lastSleepDurationMinutes: Int {
        didSet { UserDefaults.standard.set(lastSleepDurationMinutes, forKey: "lastSleepDurationMinutes") }
    }

    var lastSleepFadeOutMinutes: Int {
        didSet { UserDefaults.standard.set(lastSleepFadeOutMinutes, forKey: "lastSleepFadeOutMinutes") }
    }

    var lastSleepUntilNextAlarm: Bool {
        didSet { UserDefaults.standard.set(lastSleepUntilNextAlarm, forKey: "lastSleepUntilNextAlarm") }
    }

    /// Whether the last-used sleep source was radio (vs a sleep sound). The
    /// sleep-sound and radio players share one setup sheet; this restores the
    /// source the user last picked so the sheet reopens on the right one.
    var lastSleepSourceWasRadio: Bool {
        didSet { UserDefaults.standard.set(lastSleepSourceWasRadio, forKey: "lastSleepSourceWasRadio") }
    }

    // Suppress the background refresh warning banner
    var suppressBackgroundRefreshWarning: Bool {
        didSet {
            UserDefaults.standard.set(suppressBackgroundRefreshWarning, forKey: "suppressBackgroundRefreshWarning")
            // Flipping this ON mid-heartbeat must take effect NOW, not just at
            // the next schedule time (al-s96g). An armed heartbeat keeps a
            // pending "Allarise stopped running" queued and re-pushes it every
            // 30s; without cancelling here, suppressing the warning would leave
            // that pending notification to fire the moment iOS suspends us.
            if suppressBackgroundRefreshWarning {
                Task { @MainActor in
                    AppLifecycleMonitor.shared.warningsSuppressed()
                }
            }
        }
    }

    /// Dynamic-mode only: when the Alarm & Command Widget's Alarm Control is
    /// Armed (`cachedArmState`, driven by Home Assistant), hold the app resident
    /// exactly as a pending alarm does — so inbound HA commands keep reaching it
    /// while the house is armed. Default on; the user can turn it off in
    /// Settings ▸ Reliability, where the toggle is only shown under Dynamic.
    ///
    /// Consulted ONLY by `PersistenceResidencyResolution` under `.dynamic`; it
    /// has no effect in On (always resident) or Off (never resident). Writing it
    /// kicks the controller so residency follows immediately. Persisted under
    /// "dynamicResidencyWhenArmed" — do not rename.
    var dynamicResidencyWhenArmed: Bool {
        didSet {
            UserDefaults.standard.set(dynamicResidencyWhenArmed, forKey: "dynamicResidencyWhenArmed")
            Task { @MainActor in
                DynamicPersistenceController.shared.reevaluate(
                    reason: "dynamicResidencyWhenArmed=\(dynamicResidencyWhenArmed)"
                )
            }
        }
    }

    /// DEBUG escape hatch: fire the app-close warning even when App Persistence
    /// is off. Normally suppressed, because with persistence off iOS suspending
    /// the app is expected and the warning fired on every backgrounding. Turning
    /// this on restores the old behaviour so the notification path itself can be
    /// exercised without switching persistence back on. Ships default-off.
    var debugForceCloseWarningWhenPersistenceOff: Bool {
        didSet { UserDefaults.standard.set(debugForceCloseWarningWhenPersistenceOff, forKey: "debugForceCloseWarningWhenPersistenceOff") }
    }

    /// What the warning gates actually consult. The toggle's UI is compiled out
    /// of release builds, so honoring a stale persisted `true` there would
    /// re-enable the warning with no way to see or clear it (al-s96g — exactly
    /// how a TestFlight install inherited a debug build's toggle). DEBUG reads
    /// the toggle; release is always false.
    var forceCloseWarningDebugOverride: Bool {
        #if DEBUG
        return debugForceCloseWarningWhenPersistenceOff
        #else
        return false
        #endif
    }

    // Suppress the location permission nag in MQTT settings
    var suppressLocationPermissionNag: Bool {
        didSet { UserDefaults.standard.set(suppressLocationPermissionNag, forKey: "suppressLocationPermissionNag") }
    }
    
    // Onboarding completed — prevents onboarding from showing again
    var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    // MARK: - Data & notification preferences
    //
    // Both default OFF and are NEVER pre-ticked: consent that arrives already
    // granted isn't consent. They are also deliberately NOT synced to iCloud —
    // a choice made on one device shouldn't silently apply to another.

    /// Opt-in to anonymous usage data and crash reports.
    var analyticsOptIn: Bool {
        didSet { UserDefaults.standard.set(analyticsOptIn, forKey: "analyticsOptIn") }
    }

    /// Opt-in to occasional product-update notifications (new features, breaking
    /// changes). Separate from the SYSTEM notification authorization the alarms
    /// require — that permission already exists; this decides whether we're
    /// allowed to use it for announcements.
    var productUpdatesOptIn: Bool {
        didSet { UserDefaults.standard.set(productUpdatesOptIn, forKey: "productUpdatesOptIn") }
    }

    /// Whether the data-preferences prompt has been answered. Tracked separately
    /// from `hasCompletedOnboarding` so users upgrading from a build that predates
    /// the prompt see it exactly once, without being sent through onboarding again.
    var hasAnsweredDataPreferences: Bool {
        didSet { UserDefaults.standard.set(hasAnsweredDataPreferences, forKey: "hasAnsweredDataPreferences") }
    }

    // Terms of Service agreement version tracking.
    // Bump DeviceSettings.currentTermsVersion in the app when terms materially change.
    //
    // v6 (July 2026) — three material changes, all of which alter what the user
    // is agreeing to rather than merely how it is worded:
    //   • the contracting party is now DoMore Tech LLC, a Michigan limited
    //     liability company, not an individual
    //   • optional anonymous usage/crash reporting and optional product-update
    //     push were added, so the privacy policy no longer says "no analytics"
    //   • the NWS Weather Alerts feature and its liability section were removed
    // Note that the agree screen opens `AppLinks.terms` / `AppLinks.privacy`,
    // which resolve to beta.allarise.app on TestFlight — bumping this before the
    // matching site is live would ask for agreement to a document nobody can read.
    static let currentTermsVersion = 6
    var agreedTermsVersion: Int {
        didSet { UserDefaults.standard.set(agreedTermsVersion, forKey: "agreedTermsVersion") }
    }

    /// Whether the user has acknowledged the NWS alerts liability disclaimer.
    var nwsDisclaimerAgreed: Bool {
        didSet { UserDefaults.standard.set(nwsDisclaimerAgreed, forKey: "nwsDisclaimerAgreed") }
    }

    /// The three-way App Persistence setting — the source of truth. `.on`
    /// holds the keep-alive session continuously, `.off` relies on AlarmKit
    /// alone, `.dynamic` is resident only while charging or inside the
    /// pre-alarm window (see DynamicPersistence.swift). Writing this keeps the
    /// legacy boolean mirrored and kicks the controller so keep-alive state,
    /// the BG-task ladder, and the HA topics all follow immediately.
    var appPersistenceMode: AppPersistenceMode {
        didSet {
            UserDefaults.standard.set(appPersistenceMode.rawValue, forKey: "appPersistenceMode")
            // Mirror the legacy key (see backgroundKeepAliveEnabled) — its
            // didSet republishes the HA state topic.
            let legacy = appPersistenceMode != .off
            if backgroundKeepAliveEnabled != legacy {
                backgroundKeepAliveEnabled = legacy
            } else {
                publishAppPersistenceState()
            }
            Task { @MainActor in
                DynamicPersistenceController.shared.activate()
            }
        }
    }

    /// Cached "should the app be resident right now" for `.dynamic`, stamped
    /// by DynamicPersistenceController on every re-evaluation. Not persisted —
    /// recomputed on launch. Meaningless (and unread) for `.on` / `.off`.
    var dynamicResidentNow: Bool = false

    /// LEGACY mirror of `appPersistenceMode != .off`. The pre-3.3 boolean
    /// persisted key — kept written so a downgraded build still behaves
    /// sanely, and kept readable for code that only needs "is persistence
    /// configured at all". New code should read `appPersistenceMode` (for the
    /// user's choice) or `keepAliveNeeded` (for "should keep-alive run NOW").
    var backgroundKeepAliveEnabled: Bool {
        didSet {
            UserDefaults.standard.set(backgroundKeepAliveEnabled, forKey: "backgroundKeepAliveEnabled")
            publishAppPersistenceState()
        }
    }

    /// Mirror App Persistence to Home Assistant.
    ///
    /// Published from `didSet` rather than from each call site because there
    /// are four of them — the Settings tiles, the NWS "App Persistence
    /// Required" prompt, `resetToDefaults()`, and the `app_persistence` MQTT
    /// command — and a missed one would leave Home Assistant showing a switch
    /// that is confidently wrong with no way for anyone to notice.
    ///
    /// It fires even when the value is unchanged, and that is the whole point.
    /// Home Assistant has no other way to tell "the phone was already on" from
    /// "the phone never heard me": the command topic is fire-and-forget, so the
    /// state message *is* the acknowledgement. A no-op that published nothing
    /// would make every `wait_template` in an automation time out.
    ///
    /// Property observers do not run during `init`, so a cold launch does not
    /// publish here — `MQTTManager.publishOnlineState` seeds the topic on
    /// connect instead.
    /// Internal (not private) because DynamicPersistenceController also calls
    /// it on residency transitions — under `.dynamic` the topic reports
    /// EFFECTIVE residency, so existing automations stay truthful.
    func publishAppPersistenceState() {
        guard mqttEnabled else { return }
        HAIntegrationRouter.shared.publishAppPersistence(
            keepAliveNeeded,
            settings: self
        )
        // The raw mode goes out alongside the effective value. Under
        // `.dynamic` the topic above flips with residency all night, so it is
        // the only place Home Assistant can read which mode the user chose.
        HAIntegrationRouter.shared.publishAppPersistenceMode(
            appPersistenceMode,
            settings: self
        )
    }

    /// Whether BackgroundAudioKeepAlive should be running RIGHT NOW. This is
    /// the single residency choke point — every keep-alive start/restart site
    /// reads it, which is what makes `.dynamic` work everywhere at once.
    var keepAliveNeeded: Bool {
        switch appPersistenceMode {
        case .on: return true
        case .off: return false
        case .dynamic: return dynamicResidentNow
        }
    }
    
    // MARK: - MQTT Per-Alarm Index Counter
    /// Auto-incrementing counter for stable per-alarm MQTT IDs. Never decremented.
    var nextAlarmIndex: Int {
        didSet { UserDefaults.standard.set(nextAlarmIndex, forKey: "nextAlarmIndex") }
    }
    
    /// Assign the next available alarm index. Thread-safe via main-actor isolation.
    func assignNextAlarmIndex() -> Int {
        let index = nextAlarmIndex
        nextAlarmIndex = index + 1
        return index
    }
    
    // MARK: - Appearance Settings
    
    /// Whether to show alarm labels on the home screen alarm cards
    var showAlarmNamesOnHome: Bool {
        didSet { saveAndSync(showAlarmNamesOnHome, forKey: "showAlarmNamesOnHome") }
    }
    
    /// Whether alarm rows on the home screen use a larger size (1.2x)
    var biggerAlarmRows: Bool {
        didSet { saveAndSync(biggerAlarmRows, forKey: "biggerAlarmRows") }
    }

    /// Diagnostic: send the while-ringing notifications without their silent sound.
    /// The silent sound exists only to trigger Watch haptic mirroring, but on the
    /// iOS 27 beta a notification sound may interrupt the alarm's audio session.
    var notifTickSoundDisabled: Bool {
        didSet { saveAndSync(notifTickSoundDisabled, forKey: "notifTickSoundDisabled") }
    }
    
    /// App-wide appearance preference: "system" follows device, "light" forces light, "dark" forces dark
    var appAppearance: String {
        didSet { saveAndSync(appAppearance, forKey: "appAppearance") }
    }
    
    /// Home screen color customization (light mode)
    var homeColorCustomization: HomeColorCustomization {
        didSet {
            if let data = try? JSONEncoder().encode(homeColorCustomization) {
                UserDefaults.standard.set(data, forKey: "homeColorCustomization")
                pushToiCloud(key: "homeColorCustomization", value: data)
            }
        }
    }
    
    /// Home screen color customization (dark mode)
    var homeColorCustomizationDark: HomeColorCustomization {
        didSet {
            if let data = try? JSONEncoder().encode(homeColorCustomizationDark) {
                UserDefaults.standard.set(data, forKey: "homeColorCustomizationDark")
                pushToiCloud(key: "homeColorCustomizationDark", value: data)
            }
        }
    }
    
    /// Convenience: resolved color customization for the current color scheme
    func homeColors(for colorScheme: ColorScheme) -> HomeColorCustomization {
        colorScheme == .dark ? homeColorCustomizationDark : homeColorCustomization
    }

    // MARK: - Theme Accent Override

    /// The user's hand-picked accent per (theme, appearance). See
    /// `ThemeAccentStore` for why this is a sidecar rather than a field on
    /// `HomeColorCustomization`: applying a preset replaces that struct wholesale,
    /// which would erase the choice every time the same theme was re-tapped.
    ///
    /// Empty by default and never seeded, so an app that has never opened the
    /// picker resolves exactly the accent it always did.
    var themeAccentOverrides: [String: CodableColor] {
        didSet { ThemeAccentStore.save(themeAccentOverrides) }
    }

    /// The override slot the picker is currently editing: whichever theme is
    /// applied, in whichever appearance is showing.
    func themeAccentKey(for colorScheme: ColorScheme) -> String {
        ThemeAccentStore.storageKey(presetID: appliedHomePresetID, colorScheme: colorScheme)
    }

    /// The accent color each installed theme ships with, for the given
    /// appearance — the "Theme Colors" palette the accent picker offers as its
    /// standard set. Each swatch is labeled with the theme it belongs to, so the
    /// picker is discoverable: the user recognises "Verdant" rather than a bare
    /// green circle.
    ///
    /// Themes with no accent of their own (the plain Default) contribute
    /// nothing, and accents that are the same colour — or so close the eye can't
    /// tell them apart — collapse to a single swatch, kept under the first theme
    /// in list order. Several themes ship nearly the same blue, so an exact-match
    /// dedupe still left the row looking like it repeated the same circle three
    /// times. The literal RGB is carried through rather than the dynamic `Color`,
    /// since that triple is exactly what gets stored as the override.
    func themeAccentSwatches(for colorScheme: ColorScheme) -> [(name: String, color: Color, r: Double, g: Double, b: Double)] {
        let isDark = colorScheme == .dark
        // Squared Euclidean distance in RGB. 0.03 sits in the wide gap between
        // the theme accents that are indistinguishable (≤0.021 apart) and the
        // next-closest genuinely different pair (0.041), so it merges only the
        // look-alikes.
        let mergeThreshold = 0.03 * 0.03
        var result: [(name: String, color: Color, r: Double, g: Double, b: Double)] = []
        for preset in loadPresets() {
            let customization = isDark ? preset.darkColorCustomization : preset.lightColorCustomization
            guard let tint = customization?.toggleOnTint else { continue }
            let alreadyShown = result.contains { existing in
                let dr = existing.r - tint.red, dg = existing.g - tint.green, db = existing.b - tint.blue
                return (dr * dr + dg * dg + db * db) < mergeThreshold
            }
            guard !alreadyShown else { continue }
            result.append((preset.name, tint.color, tint.red, tint.green, tint.blue))
        }
        return result
    }

    /// The user's override for the current theme + appearance, if any.
    func themeAccentOverride(for colorScheme: ColorScheme) -> Color? {
        ThemeAccentStore.accent(in: themeAccentOverrides,
                                presetID: appliedHomePresetID,
                                isDark: colorScheme == .dark)?.color
    }

    /// Whether the current theme + appearance carries a user-picked accent.
    /// Drives whether the reset affordance is offered at all.
    func hasThemeAccentOverride(for colorScheme: ColorScheme) -> Bool {
        themeAccentOverrides[themeAccentKey(for: colorScheme)] != nil
    }

    /// The accent this theme ships with, ignoring any override — what "Reset to
    /// Theme Default" goes back to.
    func themeDefaultAccent(for colorScheme: ColorScheme) -> Color {
        homeColors(for: colorScheme).resolvedAccentColor
    }

    /// Set (or, with nil, clear) the accent for the applied theme in this
    /// appearance. Writing the dictionary is what makes the change land
    /// everywhere at once — every accent call site reads `appAccent(for:)`, and
    /// this property is observed.
    func setThemeAccent(_ color: Color?, for colorScheme: ColorScheme) {
        // No log here: with the live custom well this fires per drag tick.
        themeAccentOverrides = ThemeAccentStore.setting(
            color.map(CodableColor.init),
            in: themeAccentOverrides,
            presetID: appliedHomePresetID,
            isDark: colorScheme == .dark
        )
    }

    /// The single app-wide accent for the current color scheme. Use this for the
    /// root `.tint` and any control/media accent that should follow the theme.
    ///
    /// The user's per-theme override wins; with none set this is unchanged from
    /// what it has always been — the theme's own `resolvedAccentColor`.
    func appAccent(for colorScheme: ColorScheme) -> Color {
        themeAccentOverride(for: colorScheme) ?? homeColors(for: colorScheme).resolvedAccentColor
    }

    // MARK: - Hold-press accents (skip / arm / snooze)
    //
    // `HoldPressStyle` draws one visual language for the arm, skip and snooze
    // buttons: a wash at rest, a fill that rises from the bottom as the hold
    // completes, and a thin frame while the finger is down. Every layer is a
    // different opacity of ONE base color, which is what gives the press its
    // depth — so an override only has to move the base and the whole treatment
    // follows without being flattened.
    //
    // These deliberately do NOT collapse into `appAccent(for:)`. Skip and arm
    // keep their own theme slots (`skipButtonColor`, `armButtonColor`), and with
    // no override set each resolver returns that slot exactly as before — a user
    // who has never opened the accent picker sees no change anywhere.

    /// Base color for the hold-to-skip chip in the alarm list — its label, its
    /// resting wash, the fill that rises during the hold, and the paired Undo
    /// chip. Override wins; otherwise the theme's own skip slot.
    func skipAccent(for colorScheme: ColorScheme) -> Color {
        themeAccentOverride(for: colorScheme) ?? homeColors(for: colorScheme).resolvedSkipButtonColor
    }

    /// Base color for the arm/disarm chip and, on the alarm screen, the primary
    /// buttons that share its hold-press treatment (snooze, dismiss). Override
    /// wins; otherwise the theme's own arm-button slot.
    func armAccent(for colorScheme: ColorScheme) -> Color {
        themeAccentOverride(for: colorScheme) ?? homeColors(for: colorScheme).resolvedArmButtonColor
    }

    /// Glass tint the snooze button takes at the instant its hold completes.
    /// Reads as the same rising fill, so it follows the override too; with none
    /// set it stays the first stop of the theme's snooze gradient.
    func snoozeCompletionAccent(for colorScheme: ColorScheme) -> Color {
        if let override = themeAccentOverride(for: colorScheme) { return override }
        return alarmColors(for: colorScheme).resolvedSnoozeGradientColors.first
            ?? Color(red: 0.3, green: 0.0, blue: 0.5)
    }


    /// Alarm screen color customization (light mode)
    var alarmColorCustomization: AlarmColorCustomization {
        didSet {
            if let data = try? JSONEncoder().encode(alarmColorCustomization) {
                UserDefaults.standard.set(data, forKey: "alarmColorCustomization")
                pushToiCloud(key: "alarmColorCustomization", value: data)
            }
        }
    }
    
    /// Alarm screen color customization (dark mode)
    var alarmColorCustomizationDark: AlarmColorCustomization {
        didSet {
            if let data = try? JSONEncoder().encode(alarmColorCustomizationDark) {
                UserDefaults.standard.set(data, forKey: "alarmColorCustomizationDark")
                pushToiCloud(key: "alarmColorCustomizationDark", value: data)
            }
        }
    }
    
    /// Convenience: resolved alarm color customization for the current color scheme
    func alarmColors(for colorScheme: ColorScheme) -> AlarmColorCustomization {
        colorScheme == .dark ? alarmColorCustomizationDark : alarmColorCustomization
    }
    
    // MARK: - Weather Card Settings

    /// Whether duplicating an alarm automatically opens the editor for the new alarm
    var editDuplicatedAlarms: Bool {
        didSet { saveAndSync(editDuplicatedAlarms, forKey: "editDuplicatedAlarms") }
    }

    
    /// Debug: disable Apple Weather API calls to avoid wasting API quota during GUI testing.
    var debugDisableWeatherAPI: Bool {
        didSet { UserDefaults.standard.set(debugDisableWeatherAPI, forKey: "debugDisableWeatherAPI") }
    }

    /// Show the global wallpaper behind the mission screens. On by default; the debug
    /// menu can toggle it off to preview missions on a plain surface.
    var debugMissionWallpaperEnabled: Bool {
        didSet { UserDefaults.standard.set(debugMissionWallpaperEnabled, forKey: "debugMissionWallpaperEnabled") }
    }

    /// Show a floating debug bubble on the home screen that opens a cycler through
    /// the alarm/mission screens. Off by default.
    var debugAlarmScreenBubbleEnabled: Bool {
        didSet { UserDefaults.standard.set(debugAlarmScreenBubbleEnabled, forKey: "debugAlarmScreenBubbleEnabled") }
    }

    /// Master switch for the home screen's floating test bubbles (weather debug
    /// menu + alarm screen cycler). On by default in DEBUG builds; the Settings
    /// debug section can hide them.
    var debugHomeBubblesEnabled: Bool {
        didSet { UserDefaults.standard.set(debugHomeBubblesEnabled, forKey: "debugHomeBubblesEnabled") }
    }

    /// Whether the user has been told, during the CURRENT persistence-off period,
    /// that radio alarms fall back to their alarm tone.
    ///
    /// Deliberately re-armed on every on→off transition rather than latched
    /// forever: someone who turns persistence back on has fixed the problem, and
    /// if they later turn it off again the consequence is news once more. Within
    /// a single off period they are told exactly once, whichever way they hit it
    /// — flipping persistence off with radio alarms already set, or setting a
    /// radio alarm while it is already off.
    var radioPersistenceNoticeAcknowledged: Bool {
        didSet { UserDefaults.standard.set(radioPersistenceNoticeAcknowledged, forKey: "radioPersistenceNoticeAcknowledged") }
    }

    /// Debug: force the "Weather Alerts Removed" banner to render, ignoring both
    /// eligibility and any previous dismissal. Lets the notice be re-tested
    /// without reinstalling. Cleared automatically when the banner's ✕ is tapped.
    var debugForceNWSRemovalNotice: Bool {
        didSet { UserDefaults.standard.set(debugForceNWSRemovalNotice, forKey: "debugForceNWSRemovalNotice") }
    }

    /// Debug: see the app as a production user does — hides the NWS Weather Alerts
    /// settings section (which is otherwise DEBUG-only-visible) and stops the
    /// service. This is the "user" half of the user/debug switch: flip it on to
    /// check that nothing NWS-related is reachable, flip it off to get the feature
    /// back for development.
    var debugSimulateNWSRemoved: Bool {
        didSet {
            UserDefaults.standard.set(debugSimulateNWSRemoved, forKey: "debugSimulateNWSRemoved")
            if debugSimulateNWSRemoved {
                nwsAlertsEnabled = false
                NWSAlertService.shared.stop()
            }
        }
    }

    // MARK: - Wallpaper Settings
    
    /// Whether a custom home screen wallpaper is enabled
    var homeWallpaperEnabled: Bool {
        didSet { saveAndSync(homeWallpaperEnabled, forKey: "homeWallpaperEnabled") }
    }
    
    /// Whether a custom alarm screen wallpaper is enabled
    var alarmWallpaperEnabled: Bool {
        didSet { saveAndSync(alarmWallpaperEnabled, forKey: "alarmWallpaperEnabled") }
    }
    
    /// Dim overlay opacity for alarm screen wallpaper (0.0–1.0) to keep text readable
    var alarmWallpaperDimming: Double {
        didSet { saveAndSync(alarmWallpaperDimming, forKey: "alarmWallpaperDimming") }
    }
    
    // MARK: Alarm Glass Variant
    
    /// Glass variant for alarm screen mission cards: 0 = regular, 1 = clear, 2 = tinted
    var alarmGlassVariant: Int {
        didSet { saveAndSync(alarmGlassVariant, forKey: "alarmGlassVariant") }
    }
    
    /// Dimming behind clear glass mission cards on alarm screen (0.0–1.0)
    var alarmGlassClearDimming: Double {
        didSet { saveAndSync(alarmGlassClearDimming, forKey: "alarmGlassClearDimming") }
    }
    
    /// Tint color components for alarm screen tinted glass
    var alarmGlassTintRed: Double {
        didSet { saveAndSync(alarmGlassTintRed, forKey: "alarmGlassTintRed") }
    }
    var alarmGlassTintGreen: Double {
        didSet { saveAndSync(alarmGlassTintGreen, forKey: "alarmGlassTintGreen") }
    }
    var alarmGlassTintBlue: Double {
        didSet { saveAndSync(alarmGlassTintBlue, forKey: "alarmGlassTintBlue") }
    }
    var alarmGlassTintOpacity: Double {
        didSet { saveAndSync(alarmGlassTintOpacity, forKey: "alarmGlassTintOpacity") }
    }
    
    // MARK: Liquid Glass Variant
    
    /// Glass variant for home screen cards: 0 = regular, 1 = clear, 2 = tinted
    var homeGlassVariant: Int {
        didSet { saveAndSync(homeGlassVariant, forKey: "homeGlassVariant") }
    }
    
    /// Dimming behind clear glass cards (0.0 = fully transparent, 0.6 max)
    var homeGlassClearDimming: Double {
        didSet { saveAndSync(homeGlassClearDimming, forKey: "homeGlassClearDimming") }
    }
    
    /// Tint color components (RGBA) for the tinted glass variant
    var homeGlassTintRed: Double {
        didSet { saveAndSync(homeGlassTintRed, forKey: "homeGlassTintRed") }
    }
    var homeGlassTintGreen: Double {
        didSet { saveAndSync(homeGlassTintGreen, forKey: "homeGlassTintGreen") }
    }
    var homeGlassTintBlue: Double {
        didSet { saveAndSync(homeGlassTintBlue, forKey: "homeGlassTintBlue") }
    }
    /// Tint opacity for the tinted glass variant (0.0–1.0)
    var homeGlassTintOpacity: Double {
        didSet { saveAndSync(homeGlassTintOpacity, forKey: "homeGlassTintOpacity") }
    }
    
    // MARK: Home Wallpaper Dimming
    
    /// Dim overlay opacity for home screen wallpaper (0.0–1.0) — light mode
    var homeWallpaperDimming: Double {
        didSet { saveAndSync(homeWallpaperDimming, forKey: "homeWallpaperDimming") }
    }
    
    /// Dim overlay opacity for home screen wallpaper (0.0–1.0) — dark mode
    var homeDarkWallpaperDimming: Double {
        didSet { saveAndSync(homeDarkWallpaperDimming, forKey: "homeDarkWallpaperDimming") }
    }
    
    // MARK: Wallpaper Position & Scale
    
    /// Home wallpaper scale (1.0 = fill, max 3.0)
    var homeWallpaperScale: Double {
        didSet { saveAndSync(homeWallpaperScale, forKey: "homeWallpaperScale") }
    }
    /// Home wallpaper X offset (proportional, -1.0 to 1.0)
    var homeWallpaperOffsetX: Double {
        didSet { saveAndSync(homeWallpaperOffsetX, forKey: "homeWallpaperOffsetX") }
    }
    /// Home wallpaper Y offset (proportional, -1.0 to 1.0)
    var homeWallpaperOffsetY: Double {
        didSet { saveAndSync(homeWallpaperOffsetY, forKey: "homeWallpaperOffsetY") }
    }
    
    /// Alarm wallpaper scale (1.0 = fill, max 3.0) — light mode
    var alarmWallpaperScale: Double {
        didSet { saveAndSync(alarmWallpaperScale, forKey: "alarmWallpaperScale") }
    }
    /// Alarm wallpaper X offset — light mode
    var alarmWallpaperOffsetX: Double {
        didSet { saveAndSync(alarmWallpaperOffsetX, forKey: "alarmWallpaperOffsetX") }
    }
    /// Alarm wallpaper Y offset — light mode
    var alarmWallpaperOffsetY: Double {
        didSet { saveAndSync(alarmWallpaperOffsetY, forKey: "alarmWallpaperOffsetY") }
    }
    
    // MARK: Dark Mode Alarm Wallpaper Settings
    
    /// Dark mode alarm wallpaper dimming
    var alarmDarkWallpaperDimming: Double {
        didSet { saveAndSync(alarmDarkWallpaperDimming, forKey: "alarmDarkWallpaperDimming") }
    }
    
    /// Dark mode alarm glass variant
    var alarmDarkGlassVariant: Int {
        didSet { saveAndSync(alarmDarkGlassVariant, forKey: "alarmDarkGlassVariant") }
    }
    var alarmDarkGlassClearDimming: Double {
        didSet { saveAndSync(alarmDarkGlassClearDimming, forKey: "alarmDarkGlassClearDimming") }
    }
    var alarmDarkGlassTintRed: Double {
        didSet { saveAndSync(alarmDarkGlassTintRed, forKey: "alarmDarkGlassTintRed") }
    }
    var alarmDarkGlassTintGreen: Double {
        didSet { saveAndSync(alarmDarkGlassTintGreen, forKey: "alarmDarkGlassTintGreen") }
    }
    var alarmDarkGlassTintBlue: Double {
        didSet { saveAndSync(alarmDarkGlassTintBlue, forKey: "alarmDarkGlassTintBlue") }
    }
    var alarmDarkGlassTintOpacity: Double {
        didSet { saveAndSync(alarmDarkGlassTintOpacity, forKey: "alarmDarkGlassTintOpacity") }
    }
    
    /// Dark mode alarm wallpaper position/scale
    var alarmDarkWallpaperScale: Double {
        didSet { saveAndSync(alarmDarkWallpaperScale, forKey: "alarmDarkWallpaperScale") }
    }
    var alarmDarkWallpaperOffsetX: Double {
        didSet { saveAndSync(alarmDarkWallpaperOffsetX, forKey: "alarmDarkWallpaperOffsetX") }
    }
    var alarmDarkWallpaperOffsetY: Double {
        didSet { saveAndSync(alarmDarkWallpaperOffsetY, forKey: "alarmDarkWallpaperOffsetY") }
    }
    
    // MARK: Dark Mode Home Wallpaper Settings
    
    /// Whether to use the same wallpaper image for both light and dark mode
    var homeWallpaperUseSameForBoth: Bool {
        didSet { saveAndSync(homeWallpaperUseSameForBoth, forKey: "homeWallpaperUseSameForBoth") }
    }
    
    /// Dark mode glass variant: 0 = regular, 1 = clear, 2 = tinted
    var homeDarkGlassVariant: Int {
        didSet { saveAndSync(homeDarkGlassVariant, forKey: "homeDarkGlassVariant") }
    }
    var homeDarkGlassClearDimming: Double {
        didSet { saveAndSync(homeDarkGlassClearDimming, forKey: "homeDarkGlassClearDimming") }
    }
    var homeDarkGlassTintRed: Double {
        didSet { saveAndSync(homeDarkGlassTintRed, forKey: "homeDarkGlassTintRed") }
    }
    var homeDarkGlassTintGreen: Double {
        didSet { saveAndSync(homeDarkGlassTintGreen, forKey: "homeDarkGlassTintGreen") }
    }
    var homeDarkGlassTintBlue: Double {
        didSet { saveAndSync(homeDarkGlassTintBlue, forKey: "homeDarkGlassTintBlue") }
    }
    var homeDarkGlassTintOpacity: Double {
        didSet { saveAndSync(homeDarkGlassTintOpacity, forKey: "homeDarkGlassTintOpacity") }
    }
    
    /// Dark mode wallpaper position/scale
    var homeDarkWallpaperScale: Double {
        didSet { saveAndSync(homeDarkWallpaperScale, forKey: "homeDarkWallpaperScale") }
    }
    var homeDarkWallpaperOffsetX: Double {
        didSet { saveAndSync(homeDarkWallpaperOffsetX, forKey: "homeDarkWallpaperOffsetX") }
    }
    var homeDarkWallpaperOffsetY: Double {
        didSet { saveAndSync(homeDarkWallpaperOffsetY, forKey: "homeDarkWallpaperOffsetY") }
    }
    
    // MARK: - Home Assistant Widget
    
    /// Whether the HA widget is shown on the home screen
    var armButtonEnabled: Bool {
        didSet { UserDefaults.standard.set(armButtonEnabled, forKey: "armButtonEnabled") }
    }
    
    /// Whether the alarm arm/disarm control is shown in the widget
    var hassWidgetAlarmEnabled: Bool {
        didSet { UserDefaults.standard.set(hassWidgetAlarmEnabled, forKey: "hassWidgetAlarmEnabled") }
    }
    
    /// Hold duration in seconds to arm/disarm (default: 2.0)
    var armButtonHoldDuration: Double {
        didSet { saveAndSync(armButtonHoldDuration, forKey: "armButtonHoldDuration") }
    }

    /// The alarm zone name for this device (default: "Home").
    /// Devices sharing the same zone name subscribe to the same MQTT topic and see
    /// the same arm/disarm state from Home Assistant — enabling household-wide awareness.
    var armZone: String {
        didSet { UserDefaults.standard.set(armZone, forKey: "armZone") }
    }

    /// Last known arm state received from Home Assistant, persisted across reconnects.
    /// Used to pre-populate the arm button so it's interactive immediately on MQTT connect,
    /// rather than showing "pending" until a retained MQTT message arrives.
    var cachedArmState: Bool {
        didSet { UserDefaults.standard.set(cachedArmState, forKey: "cachedArmState") }
    }

    /// URL-safe slug derived from armZone: lowercased, spaces → underscores, non-alphanumeric stripped.
    /// Used as the MQTT topic segment: {prefix}/alarm/{armZoneSlug}/state
    var armZoneSlug: String {
        let slug = armZone
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "[^a-z0-9_]", with: "", options: .regularExpression)
        return slug.isEmpty ? "home" : slug
    }
    
    /// Whether the widget uses the larger (1.2x) scale independently of alarm rows
    var biggerWidget: Bool {
        didSet { saveAndSync(biggerWidget, forKey: "biggerWidget") }
    }
    
    // MARK: Widget Glass Variant (Light)
    
    /// Glass variant for widget: 0 = regular, 1 = clear, 2 = tinted
    var widgetGlassVariant: Int {
        didSet {
            UserDefaults.standard.set(widgetGlassVariant, forKey: "widgetGlassVariant")
            pushToiCloud(key: "widgetGlassVariant", value: widgetGlassVariant)
        }
    }
    
    /// Dimming behind clear glass widget (0.0–1.0)
    var widgetGlassClearDimming: Double {
        didSet {
            UserDefaults.standard.set(widgetGlassClearDimming, forKey: "widgetGlassClearDimming")
            pushToiCloud(key: "widgetGlassClearDimming", value: widgetGlassClearDimming)
        }
    }
    
    /// Tint color components for widget tinted glass
    var widgetGlassTintRed: Double {
        didSet {
            UserDefaults.standard.set(widgetGlassTintRed, forKey: "widgetGlassTintRed")
            pushToiCloud(key: "widgetGlassTintRed", value: widgetGlassTintRed)
        }
    }
    var widgetGlassTintGreen: Double {
        didSet {
            UserDefaults.standard.set(widgetGlassTintGreen, forKey: "widgetGlassTintGreen")
            pushToiCloud(key: "widgetGlassTintGreen", value: widgetGlassTintGreen)
        }
    }
    var widgetGlassTintBlue: Double {
        didSet {
            UserDefaults.standard.set(widgetGlassTintBlue, forKey: "widgetGlassTintBlue")
            pushToiCloud(key: "widgetGlassTintBlue", value: widgetGlassTintBlue)
        }
    }
    var widgetGlassTintOpacity: Double {
        didSet {
            UserDefaults.standard.set(widgetGlassTintOpacity, forKey: "widgetGlassTintOpacity")
            pushToiCloud(key: "widgetGlassTintOpacity", value: widgetGlassTintOpacity)
        }
    }
    
    // MARK: Widget Glass Variant (Dark)
    
    /// Dark mode glass variant for widget: 0 = regular, 1 = clear, 2 = tinted
    var widgetDarkGlassVariant: Int {
        didSet {
            UserDefaults.standard.set(widgetDarkGlassVariant, forKey: "widgetDarkGlassVariant")
            pushToiCloud(key: "widgetDarkGlassVariant", value: widgetDarkGlassVariant)
        }
    }
    var widgetDarkGlassClearDimming: Double {
        didSet {
            UserDefaults.standard.set(widgetDarkGlassClearDimming, forKey: "widgetDarkGlassClearDimming")
            pushToiCloud(key: "widgetDarkGlassClearDimming", value: widgetDarkGlassClearDimming)
        }
    }
    var widgetDarkGlassTintRed: Double {
        didSet {
            UserDefaults.standard.set(widgetDarkGlassTintRed, forKey: "widgetDarkGlassTintRed")
            pushToiCloud(key: "widgetDarkGlassTintRed", value: widgetDarkGlassTintRed)
        }
    }
    var widgetDarkGlassTintGreen: Double {
        didSet {
            UserDefaults.standard.set(widgetDarkGlassTintGreen, forKey: "widgetDarkGlassTintGreen")
            pushToiCloud(key: "widgetDarkGlassTintGreen", value: widgetDarkGlassTintGreen)
        }
    }
    var widgetDarkGlassTintBlue: Double {
        didSet {
            UserDefaults.standard.set(widgetDarkGlassTintBlue, forKey: "widgetDarkGlassTintBlue")
            pushToiCloud(key: "widgetDarkGlassTintBlue", value: widgetDarkGlassTintBlue)
        }
    }
    var widgetDarkGlassTintOpacity: Double {
        didSet {
            UserDefaults.standard.set(widgetDarkGlassTintOpacity, forKey: "widgetDarkGlassTintOpacity")
            pushToiCloud(key: "widgetDarkGlassTintOpacity", value: widgetDarkGlassTintOpacity)
        }
    }
    
    /// Custom MQTT commands (published as HA sensors, can optionally arm/disarm, max 10)
    var mqttCommands: [MQTTCommand] {
        didSet {
            if let data = try? JSONEncoder().encode(mqttCommands) {
                UserDefaults.standard.set(data, forKey: "mqttCommands")
                pushToiCloud(key: "mqttCommands", value: data)
                KeychainHelper.shared.save(data.base64EncodedString(), forKey: "kc.mqttCommands")
            }
        }
    }
    
    /// Command assigned to swipe-left on the HA widget banner (nil = no action)
    var widgetSwipeLeftCommandID: UUID? {
        didSet {
            UserDefaults.standard.set(widgetSwipeLeftCommandID?.uuidString, forKey: "widgetSwipeLeftCommandID")
            pushToiCloud(key: "widgetSwipeLeftCommandID", value: widgetSwipeLeftCommandID?.uuidString as Any)
        }
    }
    
    /// Command assigned to swipe-right on the HA widget banner (nil = no action)
    var widgetSwipeRightCommandID: UUID? {
        didSet {
            UserDefaults.standard.set(widgetSwipeRightCommandID?.uuidString, forKey: "widgetSwipeRightCommandID")
            pushToiCloud(key: "widgetSwipeRightCommandID", value: widgetSwipeRightCommandID?.uuidString as Any)
        }
    }
    
    /// Command assigned to double-tap on the HA widget banner (nil = no action)
    var widgetDoubleTapCommandID: UUID? {
        didSet {
            UserDefaults.standard.set(widgetDoubleTapCommandID?.uuidString, forKey: "widgetDoubleTapCommandID")
            pushToiCloud(key: "widgetDoubleTapCommandID", value: widgetDoubleTapCommandID?.uuidString as Any)
        }
    }
    
    /// Whether commands require confirmation before executing
    var confirmCommandsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(confirmCommandsEnabled, forKey: "confirmCommandsEnabled")
            pushToiCloud(key: "confirmCommandsEnabled", value: confirmCommandsEnabled)
        }
    }
    
    // Arm state is owned by Home Assistant — no local persistence needed.
    
    // MARK: - Smart Duplicate Naming
    
    /// Generate a smart duplicate name by incrementing the trailing number.
    /// Given "Alarm 1" and existing names ["Alarm 1", "Alarm 2"], returns "Alarm 3".
    /// Given "My Preset" and existing names ["My Preset"], returns "My Preset 2".
    static func nextDuplicateName(for baseName: String, existingNames: [String]) -> String {
        let existingSet = Set(existingNames)
        
        // Check if baseName ends with a number (e.g., "Alarm 3")
        let pattern = /^(.*?)\s+(\d+)$/
        let stem: String
        let startNumber: Int
        
        if let match = baseName.wholeMatch(of: pattern) {
            stem = String(match.1)
            startNumber = Int(match.2)! + 1
        } else {
            stem = baseName
            startNumber = 2
        }
        
        // Find the next available number
        var number = startNumber
        while existingSet.contains("\(stem) \(number)") {
            number += 1
        }
        return "\(stem) \(number)"
    }
    
    /// Generate a default name for a new item, starting from 1.
    /// Given stem "Wallpaper" and existing ["Wallpaper 1"], returns "Wallpaper 2".
    /// Given stem "Wallpaper" and no existing, returns "Wallpaper 1".
    static func nextDefaultName(stem: String, existingNames: [String]) -> String {
        let existingSet = Set(existingNames)
        var number = 1
        while existingSet.contains("\(stem) \(number)") {
            number += 1
        }
        return "\(stem) \(number)"
    }
    
    // MARK: Wallpaper File Helpers
    
    /// When set, saveWallpaper/loadWallpaper/removeWallpaper for home_light/home_dark
    /// redirect to the preset's own directory instead of the active wallpaper slots.
    /// This keeps preset editing isolated from the user's current home screen wallpaper.
    var editingPresetID: UUID?
    
    /// When set, saveWallpaper/loadWallpaper/removeWallpaper for "alarm"
    /// redirect to the alarm preset's own directory instead of the active alarm wallpaper slot.
    var editingAlarmPresetID: UUID?
    
    /// Tracks which home wallpaper preset is currently applied (for reset-on-delete).
    var appliedHomePresetID: String? {
        didSet { UserDefaults.standard.set(appliedHomePresetID, forKey: "appliedHomePresetID") }
    }
    
    /// Tracks which alarm wallpaper preset is currently applied (for reset-on-delete).
    var appliedAlarmPresetID: String? {
        didSet { UserDefaults.standard.set(appliedAlarmPresetID, forKey: "appliedAlarmPresetID") }
    }
    
    nonisolated private static var wallpaperDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wallpapers", isDirectory: true)
    }
    
    /// Returns the file URL for a given wallpaper key, respecting editingPresetID / editingAlarmPresetID.
    private func wallpaperURL(for key: String) -> URL {
        if let presetID = editingPresetID, key == "home_light" || key == "home_dark" {
            let presetDir = Self.presetsDirectory
                .appendingPathComponent(presetID.uuidString, isDirectory: true)
            let filename = key == "home_light" ? "light.jpg" : "dark.jpg"
            return presetDir.appendingPathComponent(filename)
        }
        if let alarmPresetID = editingAlarmPresetID, key == "alarm_light" || key == "alarm_dark" {
            let presetDir = Self.alarmPresetsDirectory
                .appendingPathComponent(alarmPresetID.uuidString, isDirectory: true)
            let filename = key == "alarm_light" ? "light.jpg" : "dark.jpg"
            return presetDir.appendingPathComponent(filename)
        }
        return Self.wallpaperDirectory.appendingPathComponent("\(key)_wallpaper.jpg")
    }
    
    /// Save a wallpaper image to disk. `key` is "home_light", "home_dark", or "alarm".
    /// When editingPresetID is set, home keys write to the preset directory.
    func saveWallpaper(_ image: UIImage, for key: String) {
        let url = wallpaperURL(for: key)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        // Resize to reasonable max dimension to avoid performance issues
        let maxDimension: CGFloat = 1920
        let resized = image.resizedToFit(maxDimension: maxDimension)
        
        if let data = resized.jpegData(compressionQuality: 0.85) {
            try? data.write(to: url)
        }
    }
    
    /// The largest dimension a full-screen wallpaper is ever displayed at.
    /// Comfortably above the native pixel height of any iPhone or iPad, so
    /// downsampling to this is visually lossless while capping decoded size.
    static let wallpaperMaxDimension: CGFloat = 3000

    /// Copy a wallpaper file from source into the active wallpaper slot,
    /// downsampling anything larger than a screen can display.
    ///
    /// This used to be a byte-for-byte `copyItem`, on the assumption (stated in
    /// the old comment) that preset images "are already optimized." They are
    /// not: BuiltInPresets ships 110 MB of JPGs, several over 30 MEGAPIXELS —
    /// alpine-road-light.jpg is 5171×7239, which decodes to roughly 150 MB of
    /// bitmap. loadWallpaper holds that in app-lifetime @State while
    /// BackgroundAudioKeepAlive deliberately keeps the process resident all
    /// night, which made the app a prime jetsam target — and jetsam kills the
    /// in-app alarm timer.
    func copyWallpaperFile(from sourceURL: URL, for key: String) {
        Self.copyWallpaperFile(from: sourceURL, to: wallpaperURL(for: key))
    }

    /// Copy+downsample implementation, `nonisolated` so it can run off the main
    /// actor (see `applyThemeAsync`). Callers pass an explicit destination URL.
    nonisolated static func copyWallpaperFile(from sourceURL: URL, to destURL: URL) {
        let dir = destURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destURL)

        // Only pay the decode→encode cost when the source actually exceeds the
        // display ceiling; already-reasonable images still get the fast path.
        if let pixelSize = pixelSize(at: sourceURL),
           max(pixelSize.width, pixelSize.height) > wallpaperMaxDimension,
           let downsampled = downsampledImage(at: sourceURL, maxDimension: wallpaperMaxDimension),
           let data = downsampled.jpegData(compressionQuality: 0.9) {
            try? data.write(to: destURL)
            return
        }
        try? FileManager.default.copyItem(at: sourceURL, to: destURL)
    }

    /// Active (non-editing) wallpaper slot URL for a key. `nonisolated` so the
    /// off-main theme apply can resolve destinations without touching
    /// main-actor state. Mirrors `wallpaperURL(for:)` with no editing preset.
    nonisolated static func activeWallpaperURL(for key: String) -> URL {
        wallpaperDirectory.appendingPathComponent("\(key)_wallpaper.jpg")
    }

    /// Copy (or clear) a preset's light/dark wallpapers into the active slots.
    /// `nonisolated` — safe to call from a detached task; performs only file
    /// I/O and image decoding, no @Observable mutation.
    nonisolated static func copyPresetWallpapers(presetID: UUID, isAlarm: Bool, hasLight: Bool, hasDark: Bool) {
        let presetDir = (isAlarm ? alarmPresetsDirectory : presetsDirectory)
            .appendingPathComponent(presetID.uuidString, isDirectory: true)
        let lightKey = isAlarm ? "alarm_light" : "home_light"
        let darkKey = isAlarm ? "alarm_dark" : "home_dark"
        let lightSrc = presetDir.appendingPathComponent("light.jpg")
        let darkSrc = presetDir.appendingPathComponent("dark.jpg")

        if hasLight, FileManager.default.fileExists(atPath: lightSrc.path) {
            copyWallpaperFile(from: lightSrc, to: activeWallpaperURL(for: lightKey))
        } else {
            try? FileManager.default.removeItem(at: activeWallpaperURL(for: lightKey))
        }
        if hasDark, FileManager.default.fileExists(atPath: darkSrc.path) {
            copyWallpaperFile(from: darkSrc, to: activeWallpaperURL(for: darkKey))
        } else {
            try? FileManager.default.removeItem(at: activeWallpaperURL(for: darkKey))
        }
    }

    /// Applies a home preset (and the optional matching alarm preset) with the
    /// potentially-expensive wallpaper copy/downsample performed OFF the main
    /// actor, then applies the (cheap) property mutations on the main actor.
    /// Lets the caller show a live progress indicator that reflects the real
    /// completion of the apply rather than a fixed timer. Several built-in
    /// presets ship 30-megapixel JPGs whose downsample is the slow part; doing
    /// it here keeps the settings screen responsive.
    @MainActor
    func applyThemeAsync(home: WallpaperPreset, alarm: AlarmWallpaperPreset?) async {
        let homeID = home.id
        let homeHasLight = home.hasLightImage
        let homeHasDark = home.hasDarkImage
        let alarmID = alarm?.id
        let alarmHasLight = alarm?.hasLightImage ?? false
        let alarmHasDark = alarm?.hasDarkImage ?? false

        await Task.detached(priority: .userInitiated) {
            Self.copyPresetWallpapers(presetID: homeID, isAlarm: false, hasLight: homeHasLight, hasDark: homeHasDark)
            if let alarmID {
                Self.copyPresetWallpapers(presetID: alarmID, isAlarm: true, hasLight: alarmHasLight, hasDark: alarmHasDark)
            }
        }.value

        // New files may share paths with old ones — drop cached bitmaps so the
        // freshly-copied wallpapers load.
        Self.invalidateWallpaperCache()

        // Files are already in place; skip the copy and just apply properties
        // (+ the applied-ID update that triggers wallpaper reload in the UI).
        applyPreset(home, skipWallpaperCopy: true)
        if let alarm {
            applyAlarmPreset(alarm, skipWallpaperCopy: true)
        }
    }

    /// Pixel dimensions of an image file without decoding it.
    nonisolated static func pixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Decoded-wallpaper cache. NSCache (not a plain dictionary) on purpose:
    /// it evicts automatically under memory pressure, so cached bitmaps are
    /// reclaimable by the system rather than pinned like the old @State copies.
    /// Keyed by file path + mtime so an edited or re-applied wallpaper misses.
    private static let wallpaperCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 4   // home light/dark + alarm light/dark
        return cache
    }()

    nonisolated static func invalidateWallpaperCache() {
        wallpaperCache.removeAllObjects()
    }

    /// Load a wallpaper image from disk. Returns nil if none saved.
    /// When editingPresetID is set, home keys read from the preset directory.
    ///
    /// Downsampled rather than decoded at full resolution: callers hold the
    /// result in SwiftUI @State, so a full-res decode of a legacy
    /// (pre-downsampling) preset file would pin >100 MB.
    func loadWallpaper(for key: String) -> UIImage? {
        let url = wallpaperURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // Include mtime in the key: applying a new preset rewrites the same
        // path, and a path-only key would serve the previous wallpaper forever.
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let cacheKey = "\(url.path)#\(mtime)" as NSString

        if let cached = Self.wallpaperCache.object(forKey: cacheKey) {
            return cached
        }
        guard let image = Self.downsampledImage(at: url, maxDimension: Self.wallpaperMaxDimension)
            ?? UIImage(contentsOfFile: url.path) else { return nil }
        Self.wallpaperCache.setObject(image, forKey: cacheKey)
        return image
    }
    
    /// Load a wallpaper thumbnail downsampled to the given point size.
    /// Uses ImageIO to avoid decoding the full image into memory.
    func loadWallpaperThumbnail(for key: String, maxDimension: CGFloat = 120) -> UIImage? {
        let url = wallpaperURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Self.downsampledImage(at: url, maxDimension: maxDimension)
    }
    
    /// Downsample an image file using ImageIO — avoids decoding the full bitmap into memory.
    nonisolated static func downsampledImage(at url: URL, maxDimension: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension * 3.0  // 3x for modern iPhones
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    
    /// Remove a wallpaper image from disk.
    /// When editingPresetID is set, home keys delete from the preset directory.
    func removeWallpaper(for key: String) {
        let url = wallpaperURL(for: key)
        try? FileManager.default.removeItem(at: url)
    }
    
    /// Reset wallpaper position/scale when a new image is selected.
    /// Keys: "home_light", "home_dark", "alarm_light", "alarm_dark", "alarm"
    func resetWallpaperPosition(for key: String) {
        switch key {
        case "home_light", "home":
            homeWallpaperScale = 1.0
            homeWallpaperOffsetX = 0
            homeWallpaperOffsetY = 0
        case "home_dark":
            homeDarkWallpaperScale = 1.0
            homeDarkWallpaperOffsetX = 0
            homeDarkWallpaperOffsetY = 0
        case "alarm_light", "alarm":
            alarmWallpaperScale = 1.0
            alarmWallpaperOffsetX = 0
            alarmWallpaperOffsetY = 0
        case "alarm_dark":
            alarmDarkWallpaperScale = 1.0
            alarmDarkWallpaperOffsetX = 0
            alarmDarkWallpaperOffsetY = 0
        default:
            break
        }
    }
    
    /// Returns the wallpaper storage key for the active home appearance.
    func activeHomeWallpaperKey(forDark: Bool) -> String {
        return forDark ? "home_dark" : "home_light"
    }
    
    /// Returns the wallpaper storage key for the active alarm appearance.
    func activeAlarmWallpaperKey(forDark: Bool) -> String {
        return forDark ? "alarm_dark" : "alarm_light"
    }
    
    // MARK: - Wallpaper Presets
    
    nonisolated static var presetsDirectory: URL {
        wallpaperDirectory.appendingPathComponent("Presets", isDirectory: true)
    }
    
    static var presetsManifestURL: URL {
        presetsDirectory.appendingPathComponent("presets.json")
    }
    
    /// Load all saved wallpaper presets from the JSON manifest.
    func loadPresets() -> [WallpaperPreset] {
        guard let data = try? Data(contentsOf: Self.presetsManifestURL),
              let manifest = try? JSONDecoder().decode(WallpaperPresetManifest.self, from: data)
        else {
            return []
        }
        return manifest.presets
    }

    /// Whether the currently-applied home preset asks for a light (white) system
    /// status bar. Only meaningful while a wallpaper is active — the flag exists
    /// because some presets ship a dark light-mode wallpaper. Returns false when
    /// no wallpaper is enabled, no preset is applied, or the preset omits the
    /// flag (older manifests / user-created presets), so the default black
    /// status bar is preserved.
    func appliedHomePresetPrefersLightStatusBar() -> Bool {
        guard homeWallpaperEnabled, let id = appliedHomePresetID else { return false }
        return loadPresets().first(where: { $0.id.uuidString == id })?.statusBarPrefersLightContent == true
    }

    /// Save the full presets array back to the JSON manifest.
    private func savePresetsManifest(_ presets: [WallpaperPreset]) {
        let dir = Self.presetsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = WallpaperPresetManifest(presets: presets)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: Self.presetsManifestURL, options: .atomic)
            pushToiCloud(key: "homePresetsManifest", value: data)
        }
    }
    
    /// Update an existing preset in place with the current wallpaper settings.
    /// Keeps the original ID and creation date. Images are already in the preset
    /// directory (via editingPresetID redirecting saveWallpaper), so we just check
    /// if they exist and update the manifest with current settings.
    func updatePreset(_ existing: WallpaperPreset) {
        let presetDir = Self.presetsDirectory
            .appendingPathComponent(existing.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: presetDir, withIntermediateDirectories: true)
        
        // Check which images exist in the preset directory
        let hasLight = FileManager.default.fileExists(atPath: presetDir.appendingPathComponent("light.jpg").path)
        let hasDark = FileManager.default.fileExists(atPath: presetDir.appendingPathComponent("dark.jpg").path)
        
        // Build updated preset keeping original ID, name, and creation date
        let updated = WallpaperPreset(
            id: existing.id,
            name: existing.name,
            createdAt: existing.createdAt,
            lightDimming: homeWallpaperDimming,
            lightGlassVariant: homeGlassVariant,
            lightGlassClearDimming: homeGlassClearDimming,
            lightGlassTintRed: homeGlassTintRed,
            lightGlassTintGreen: homeGlassTintGreen,
            lightGlassTintBlue: homeGlassTintBlue,
            lightGlassTintOpacity: homeGlassTintOpacity,
            lightWallpaperScale: homeWallpaperScale,
            lightWallpaperOffsetX: homeWallpaperOffsetX,
            lightWallpaperOffsetY: homeWallpaperOffsetY,
            darkDimming: homeDarkWallpaperDimming,
            darkGlassVariant: homeDarkGlassVariant,
            darkGlassClearDimming: homeDarkGlassClearDimming,
            darkGlassTintRed: homeDarkGlassTintRed,
            darkGlassTintGreen: homeDarkGlassTintGreen,
            darkGlassTintBlue: homeDarkGlassTintBlue,
            darkGlassTintOpacity: homeDarkGlassTintOpacity,
            darkWallpaperScale: homeDarkWallpaperScale,
            darkWallpaperOffsetX: homeDarkWallpaperOffsetX,
            darkWallpaperOffsetY: homeDarkWallpaperOffsetY,
            hasLightImage: hasLight,
            hasDarkImage: hasDark,
            lightWidgetGlassVariant: widgetGlassVariant,
            lightWidgetGlassClearDimming: widgetGlassClearDimming,
            lightWidgetGlassTintRed: widgetGlassTintRed,
            lightWidgetGlassTintGreen: widgetGlassTintGreen,
            lightWidgetGlassTintBlue: widgetGlassTintBlue,
            lightWidgetGlassTintOpacity: widgetGlassTintOpacity,
            darkWidgetGlassVariant: widgetDarkGlassVariant,
            darkWidgetGlassClearDimming: widgetDarkGlassClearDimming,
            darkWidgetGlassTintRed: widgetDarkGlassTintRed,
            darkWidgetGlassTintGreen: widgetDarkGlassTintGreen,
            darkWidgetGlassTintBlue: widgetDarkGlassTintBlue,
            darkWidgetGlassTintOpacity: widgetDarkGlassTintOpacity,
            lightColorCustomization: homeColorCustomization.hasCustomizations ? homeColorCustomization : nil,
            darkColorCustomization: homeColorCustomizationDark.hasCustomizations ? homeColorCustomizationDark : nil
        )
        
        var all = loadPresets()
        if let idx = all.firstIndex(where: { $0.id == existing.id }) {
            all[idx] = updated
        }
        savePresetsManifest(all)
    }
    
    /// Apply a preset: overwrite current home screen wallpaper images and all settings.
    /// Always writes to the active wallpaper slots regardless of editingPresetID.
    /// - Parameter skipWallpaperCopy: when true, the light/dark image file copy
    ///   is skipped (the caller already performed it, e.g. off the main actor in
    ///   `applyThemeAsync`); only the property mutations run.
    func applyPreset(_ preset: WallpaperPreset, skipIDUpdate: Bool = false, skipWallpaperCopy: Bool = false) {
        print("[Theme] applyPreset START: '\(preset.name)' id=\(preset.id) skipIDUpdate=\(skipIDUpdate) skipWallpaperCopy=\(skipWallpaperCopy)")
        // Ensure we write to the active wallpaper slots, not the preset directory
        let savedEditingID = editingPresetID
        editingPresetID = nil
        defer { editingPresetID = savedEditingID }

        let presetDir = Self.presetsDirectory
            .appendingPathComponent(preset.id.uuidString, isDirectory: true)

        if !skipWallpaperCopy {
            // Copy light image from preset to active wallpaper slot via direct file copy
            let lightURL = presetDir.appendingPathComponent("light.jpg")
            if preset.hasLightImage, FileManager.default.fileExists(atPath: lightURL.path) {
                copyWallpaperFile(from: lightURL, for: "home_light")
                print("[Theme]   Copied light image from \(lightURL.lastPathComponent)")
            } else {
                removeWallpaper(for: "home_light")
                print("[Theme]   Removed light image (hasLight=\(preset.hasLightImage) exists=\(FileManager.default.fileExists(atPath: lightURL.path)))")
            }

            // Copy dark image via direct file copy
            let darkURL = presetDir.appendingPathComponent("dark.jpg")
            if preset.hasDarkImage, FileManager.default.fileExists(atPath: darkURL.path) {
                copyWallpaperFile(from: darkURL, for: "home_dark")
                print("[Theme]   Copied dark image from \(darkURL.lastPathComponent)")
            } else {
                removeWallpaper(for: "home_dark")
                print("[Theme]   Removed dark image (hasDark=\(preset.hasDarkImage) exists=\(FileManager.default.fileExists(atPath: darkURL.path)))")
            }
        }

        // Apply light settings
        homeWallpaperDimming = preset.lightDimming ?? 0
        homeGlassVariant = preset.lightGlassVariant
        homeGlassClearDimming = preset.lightGlassClearDimming
        homeGlassTintRed = preset.lightGlassTintRed
        homeGlassTintGreen = preset.lightGlassTintGreen
        homeGlassTintBlue = preset.lightGlassTintBlue
        homeGlassTintOpacity = preset.lightGlassTintOpacity
        homeWallpaperScale = preset.lightWallpaperScale
        homeWallpaperOffsetX = preset.lightWallpaperOffsetX
        homeWallpaperOffsetY = preset.lightWallpaperOffsetY
        
        // Apply dark settings
        homeDarkWallpaperDimming = preset.darkDimming ?? 0
        homeDarkGlassVariant = preset.darkGlassVariant
        homeDarkGlassClearDimming = preset.darkGlassClearDimming
        homeDarkGlassTintRed = preset.darkGlassTintRed
        homeDarkGlassTintGreen = preset.darkGlassTintGreen
        homeDarkGlassTintBlue = preset.darkGlassTintBlue
        homeDarkGlassTintOpacity = preset.darkGlassTintOpacity
        homeDarkWallpaperScale = preset.darkWallpaperScale
        homeDarkWallpaperOffsetX = preset.darkWallpaperOffsetX
        homeDarkWallpaperOffsetY = preset.darkWallpaperOffsetY
        
        // Apply color customization
        homeColorCustomization = preset.lightColorCustomization ?? .default
        homeColorCustomizationDark = preset.darkColorCustomization ?? .default
        
        // Apply widget glass settings (use defaults if preset doesn't have them — backward compat)
        if let v = preset.lightWidgetGlassVariant { widgetGlassVariant = v }
        if let v = preset.lightWidgetGlassClearDimming { widgetGlassClearDimming = v }
        if let v = preset.lightWidgetGlassTintRed { widgetGlassTintRed = v }
        if let v = preset.lightWidgetGlassTintGreen { widgetGlassTintGreen = v }
        if let v = preset.lightWidgetGlassTintBlue { widgetGlassTintBlue = v }
        if let v = preset.lightWidgetGlassTintOpacity { widgetGlassTintOpacity = v }
        if let v = preset.darkWidgetGlassVariant { widgetDarkGlassVariant = v }
        if let v = preset.darkWidgetGlassClearDimming { widgetDarkGlassClearDimming = v }
        if let v = preset.darkWidgetGlassTintRed { widgetDarkGlassTintRed = v }
        if let v = preset.darkWidgetGlassTintGreen { widgetDarkGlassTintGreen = v }
        if let v = preset.darkWidgetGlassTintBlue { widgetDarkGlassTintBlue = v }
        if let v = preset.darkWidgetGlassTintOpacity { widgetDarkGlassTintOpacity = v }
        
        // Enable wallpaper if either image is present
        homeWallpaperEnabled = preset.hasLightImage || preset.hasDarkImage
        
        // Track which preset is now applied (skip when caller already set this for instant feedback)
        if !skipIDUpdate {
            appliedHomePresetID = preset.id.uuidString
        }
        print("[Theme] applyPreset END: wallpaperEnabled=\(homeWallpaperEnabled) appliedID=\(appliedHomePresetID ?? "nil") lightDim=\(homeWallpaperDimming) darkDim=\(homeDarkWallpaperDimming) lightGlass=\(homeGlassVariant) darkGlass=\(homeDarkGlassVariant)")
    }
    
    /// Load only the settings properties (glass, scale, offsets) from a preset
    /// into DeviceSettings, without copying any images. Used when entering preset
    /// editing mode so the builder UI reflects the preset's configuration.
    func loadPresetSettings(_ preset: WallpaperPreset) {
        homeWallpaperDimming = preset.lightDimming ?? 0
        homeGlassVariant = preset.lightGlassVariant
        homeGlassClearDimming = preset.lightGlassClearDimming
        homeGlassTintRed = preset.lightGlassTintRed
        homeGlassTintGreen = preset.lightGlassTintGreen
        homeGlassTintBlue = preset.lightGlassTintBlue
        homeGlassTintOpacity = preset.lightGlassTintOpacity
        homeWallpaperScale = preset.lightWallpaperScale
        homeWallpaperOffsetX = preset.lightWallpaperOffsetX
        homeWallpaperOffsetY = preset.lightWallpaperOffsetY
        
        homeDarkWallpaperDimming = preset.darkDimming ?? 0
        homeDarkGlassVariant = preset.darkGlassVariant
        homeDarkGlassClearDimming = preset.darkGlassClearDimming
        homeDarkGlassTintRed = preset.darkGlassTintRed
        homeDarkGlassTintGreen = preset.darkGlassTintGreen
        homeDarkGlassTintBlue = preset.darkGlassTintBlue
        homeDarkGlassTintOpacity = preset.darkGlassTintOpacity
        homeDarkWallpaperScale = preset.darkWallpaperScale
        homeDarkWallpaperOffsetX = preset.darkWallpaperOffsetX
        homeDarkWallpaperOffsetY = preset.darkWallpaperOffsetY
        
        // Load color customization
        homeColorCustomization = preset.lightColorCustomization ?? .default
        homeColorCustomizationDark = preset.darkColorCustomization ?? .default
        
        // Load widget glass settings
        if let v = preset.lightWidgetGlassVariant { widgetGlassVariant = v }
        if let v = preset.lightWidgetGlassClearDimming { widgetGlassClearDimming = v }
        if let v = preset.lightWidgetGlassTintRed { widgetGlassTintRed = v }
        if let v = preset.lightWidgetGlassTintGreen { widgetGlassTintGreen = v }
        if let v = preset.lightWidgetGlassTintBlue { widgetGlassTintBlue = v }
        if let v = preset.lightWidgetGlassTintOpacity { widgetGlassTintOpacity = v }
        if let v = preset.darkWidgetGlassVariant { widgetDarkGlassVariant = v }
        if let v = preset.darkWidgetGlassClearDimming { widgetDarkGlassClearDimming = v }
        if let v = preset.darkWidgetGlassTintRed { widgetDarkGlassTintRed = v }
        if let v = preset.darkWidgetGlassTintGreen { widgetDarkGlassTintGreen = v }
        if let v = preset.darkWidgetGlassTintBlue { widgetDarkGlassTintBlue = v }
        if let v = preset.darkWidgetGlassTintOpacity { widgetDarkGlassTintOpacity = v }
        
        homeWallpaperEnabled = preset.hasLightImage || preset.hasDarkImage
    }
    
    /// Delete a preset (remove its directory and entry from the manifest).
    func deletePreset(_ preset: WallpaperPreset) {
        guard !preset.isBuiltIn else { return }
        // If the deleted preset is the currently applied one, reset home wallpaper to defaults
        if appliedHomePresetID == preset.id.uuidString {
            resetHomeWallpaperToDefault()
        }
        
        let presetDir = Self.presetsDirectory
            .appendingPathComponent(preset.id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: presetDir)
        
        var all = loadPresets()
        all.removeAll { $0.id == preset.id }
        savePresetsManifest(all)
    }
    
    /// Reset home wallpaper settings to system defaults (no wallpaper, default glass/colors).
    func resetHomeWallpaperToDefault() {
        removeWallpaper(for: "home_light")
        removeWallpaper(for: "home_dark")
        homeWallpaperEnabled = false
        resetWallpaperPosition(for: "home_light")
        resetWallpaperPosition(for: "home_dark")
        homeWallpaperDimming = 0
        homeDarkWallpaperDimming = 0
        homeGlassVariant = 0
        homeDarkGlassVariant = 0
        homeGlassClearDimming = 0.3
        homeDarkGlassClearDimming = 0.3
        homeGlassTintRed = 0.0
        homeGlassTintGreen = 0.48
        homeGlassTintBlue = 1.0
        homeGlassTintOpacity = 1.0
        homeDarkGlassTintRed = 0.0
        homeDarkGlassTintGreen = 0.48
        homeDarkGlassTintBlue = 1.0
        homeDarkGlassTintOpacity = 1.0
        homeColorCustomization = .default
        homeColorCustomizationDark = .default
        appliedHomePresetID = nil
    }
    
    /// Rename a preset in the manifest.
    func renamePreset(_ preset: WallpaperPreset, to newName: String) {
        guard !preset.isBuiltIn else { return }
        var all = loadPresets()
        if let idx = all.firstIndex(where: { $0.id == preset.id }) {
            all[idx].name = newName
            savePresetsManifest(all)
        }
    }
    
    /// Duplicate an existing preset with a new name, copying its images and settings.
    @discardableResult
    func duplicatePreset(_ source: WallpaperPreset, newName: String) -> WallpaperPreset {
        let newID = UUID()
        let sourceDir = Self.presetsDirectory.appendingPathComponent(source.id.uuidString, isDirectory: true)
        let destDir = Self.presetsDirectory.appendingPathComponent(newID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        // Copy images
        for filename in ["light.jpg", "dark.jpg"] {
            let src = sourceDir.appendingPathComponent(filename)
            let dst = destDir.appendingPathComponent(filename)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        
        // Create new preset with same settings but new ID, name, and date
        let duplicate = WallpaperPreset(
            id: newID,
            name: newName,
            createdAt: Date(),
            lightDimming: source.lightDimming,
            lightGlassVariant: source.lightGlassVariant,
            lightGlassClearDimming: source.lightGlassClearDimming,
            lightGlassTintRed: source.lightGlassTintRed,
            lightGlassTintGreen: source.lightGlassTintGreen,
            lightGlassTintBlue: source.lightGlassTintBlue,
            lightGlassTintOpacity: source.lightGlassTintOpacity,
            lightWallpaperScale: source.lightWallpaperScale,
            lightWallpaperOffsetX: source.lightWallpaperOffsetX,
            lightWallpaperOffsetY: source.lightWallpaperOffsetY,
            darkDimming: source.darkDimming,
            darkGlassVariant: source.darkGlassVariant,
            darkGlassClearDimming: source.darkGlassClearDimming,
            darkGlassTintRed: source.darkGlassTintRed,
            darkGlassTintGreen: source.darkGlassTintGreen,
            darkGlassTintBlue: source.darkGlassTintBlue,
            darkGlassTintOpacity: source.darkGlassTintOpacity,
            darkWallpaperScale: source.darkWallpaperScale,
            darkWallpaperOffsetX: source.darkWallpaperOffsetX,
            darkWallpaperOffsetY: source.darkWallpaperOffsetY,
            hasLightImage: source.hasLightImage,
            hasDarkImage: source.hasDarkImage,
            lightWidgetGlassVariant: source.lightWidgetGlassVariant,
            lightWidgetGlassClearDimming: source.lightWidgetGlassClearDimming,
            lightWidgetGlassTintRed: source.lightWidgetGlassTintRed,
            lightWidgetGlassTintGreen: source.lightWidgetGlassTintGreen,
            lightWidgetGlassTintBlue: source.lightWidgetGlassTintBlue,
            lightWidgetGlassTintOpacity: source.lightWidgetGlassTintOpacity,
            darkWidgetGlassVariant: source.darkWidgetGlassVariant,
            darkWidgetGlassClearDimming: source.darkWidgetGlassClearDimming,
            darkWidgetGlassTintRed: source.darkWidgetGlassTintRed,
            darkWidgetGlassTintGreen: source.darkWidgetGlassTintGreen,
            darkWidgetGlassTintBlue: source.darkWidgetGlassTintBlue,
            darkWidgetGlassTintOpacity: source.darkWidgetGlassTintOpacity,
            lightColorCustomization: source.lightColorCustomization,
            darkColorCustomization: source.darkColorCustomization
        )
        
        var all = loadPresets()
        all.append(duplicate)
        savePresetsManifest(all)
        return duplicate
    }
    
    /// Load a preset's thumbnail image for a given appearance.
    func loadPresetThumbnail(for preset: WallpaperPreset, appearance: WallpaperAppearance) -> UIImage? {
        let hasImage = appearance == .light ? preset.hasLightImage : preset.hasDarkImage
        guard hasImage else { return nil }
        let filename = appearance == .light ? "light.jpg" : "dark.jpg"
        let url = Self.presetsDirectory
            .appendingPathComponent(preset.id.uuidString)
            .appendingPathComponent(filename)
        return Self.downsampledImage(at: url, maxDimension: 120)
    }
    
    // MARK: - Alarm Wallpaper Presets
    
    static var alarmPresetsDirectory: URL {
        wallpaperDirectory.appendingPathComponent("AlarmPresets", isDirectory: true)
    }
    
    static var alarmPresetsManifestURL: URL {
        alarmPresetsDirectory.appendingPathComponent("alarm_presets.json")
    }
    
    /// Load all saved alarm wallpaper presets from the JSON manifest.
    func loadAlarmPresets() -> [AlarmWallpaperPreset] {
        guard let data = try? Data(contentsOf: Self.alarmPresetsManifestURL),
              let manifest = try? JSONDecoder().decode(AlarmWallpaperPresetManifest.self, from: data)
        else {
            return []
        }
        return manifest.presets
    }
    
    /// Save the full alarm presets array back to the JSON manifest.
    private func saveAlarmPresetsManifest(_ presets: [AlarmWallpaperPreset]) {
        let dir = Self.alarmPresetsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = AlarmWallpaperPresetManifest(presets: presets)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: Self.alarmPresetsManifestURL, options: .atomic)
            pushToiCloud(key: "alarmPresetsManifest", value: data)
        }
    }
    
    /// Update an existing alarm preset with the current alarm wallpaper settings.
    func updateAlarmPreset(_ existing: AlarmWallpaperPreset) {
        let presetDir = Self.alarmPresetsDirectory
            .appendingPathComponent(existing.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: presetDir, withIntermediateDirectories: true)
        
        let hasLight = FileManager.default.fileExists(atPath: presetDir.appendingPathComponent("light.jpg").path)
        let hasDark = FileManager.default.fileExists(atPath: presetDir.appendingPathComponent("dark.jpg").path)
        
        let updated = AlarmWallpaperPreset(
            id: existing.id,
            name: existing.name,
            createdAt: existing.createdAt,
            lightDimming: alarmWallpaperDimming,
            lightGlassVariant: alarmGlassVariant,
            lightGlassClearDimming: alarmGlassClearDimming,
            lightGlassTintRed: alarmGlassTintRed,
            lightGlassTintGreen: alarmGlassTintGreen,
            lightGlassTintBlue: alarmGlassTintBlue,
            lightGlassTintOpacity: alarmGlassTintOpacity,
            lightWallpaperScale: alarmWallpaperScale,
            lightWallpaperOffsetX: alarmWallpaperOffsetX,
            lightWallpaperOffsetY: alarmWallpaperOffsetY,
            darkDimming: alarmDarkWallpaperDimming,
            darkGlassVariant: alarmDarkGlassVariant,
            darkGlassClearDimming: alarmDarkGlassClearDimming,
            darkGlassTintRed: alarmDarkGlassTintRed,
            darkGlassTintGreen: alarmDarkGlassTintGreen,
            darkGlassTintBlue: alarmDarkGlassTintBlue,
            darkGlassTintOpacity: alarmDarkGlassTintOpacity,
            darkWallpaperScale: alarmDarkWallpaperScale,
            darkWallpaperOffsetX: alarmDarkWallpaperOffsetX,
            darkWallpaperOffsetY: alarmDarkWallpaperOffsetY,
            lightColorCustomization: alarmColorCustomization.hasCustomizations ? alarmColorCustomization : nil,
            darkColorCustomization: alarmColorCustomizationDark.hasCustomizations ? alarmColorCustomizationDark : nil,
            hasLightImage: hasLight,
            hasDarkImage: hasDark
        )
        
        var all = loadAlarmPresets()
        if let idx = all.firstIndex(where: { $0.id == existing.id }) {
            all[idx] = updated
        }
        saveAlarmPresetsManifest(all)
    }
    
    /// Apply an alarm preset: overwrite the active alarm wallpapers and settings.
    /// - Parameter skipWallpaperCopy: see `applyPreset(_:skipIDUpdate:skipWallpaperCopy:)`.
    func applyAlarmPreset(_ preset: AlarmWallpaperPreset, skipIDUpdate: Bool = false, skipWallpaperCopy: Bool = false) {
        let savedEditingID = editingAlarmPresetID
        editingAlarmPresetID = nil
        defer { editingAlarmPresetID = savedEditingID }

        let presetDir = Self.alarmPresetsDirectory
            .appendingPathComponent(preset.id.uuidString, isDirectory: true)

        if !skipWallpaperCopy {
            // Copy light image via direct file copy
            let lightURL = presetDir.appendingPathComponent("light.jpg")
            if preset.hasLightImage, FileManager.default.fileExists(atPath: lightURL.path) {
                copyWallpaperFile(from: lightURL, for: "alarm_light")
            } else {
                removeWallpaper(for: "alarm_light")
            }

            // Copy dark image via direct file copy
            let darkURL = presetDir.appendingPathComponent("dark.jpg")
            if preset.hasDarkImage, FileManager.default.fileExists(atPath: darkURL.path) {
                copyWallpaperFile(from: darkURL, for: "alarm_dark")
            } else {
                removeWallpaper(for: "alarm_dark")
            }
        }

        // Apply light settings
        alarmWallpaperDimming = preset.lightDimming
        alarmGlassVariant = preset.lightGlassVariant
        alarmGlassClearDimming = preset.lightGlassClearDimming
        alarmGlassTintRed = preset.lightGlassTintRed
        alarmGlassTintGreen = preset.lightGlassTintGreen
        alarmGlassTintBlue = preset.lightGlassTintBlue
        alarmGlassTintOpacity = preset.lightGlassTintOpacity
        alarmWallpaperScale = preset.lightWallpaperScale
        alarmWallpaperOffsetX = preset.lightWallpaperOffsetX
        alarmWallpaperOffsetY = preset.lightWallpaperOffsetY
        
        // Apply dark settings
        alarmDarkWallpaperDimming = preset.darkDimming
        alarmDarkGlassVariant = preset.darkGlassVariant
        alarmDarkGlassClearDimming = preset.darkGlassClearDimming
        alarmDarkGlassTintRed = preset.darkGlassTintRed
        alarmDarkGlassTintGreen = preset.darkGlassTintGreen
        alarmDarkGlassTintBlue = preset.darkGlassTintBlue
        alarmDarkGlassTintOpacity = preset.darkGlassTintOpacity
        alarmDarkWallpaperScale = preset.darkWallpaperScale
        alarmDarkWallpaperOffsetX = preset.darkWallpaperOffsetX
        alarmDarkWallpaperOffsetY = preset.darkWallpaperOffsetY
        
        // Apply color customization
        alarmColorCustomization = preset.lightColorCustomization ?? .default
        alarmColorCustomizationDark = preset.darkColorCustomization ?? .default
        
        alarmWallpaperEnabled = preset.hasLightImage || preset.hasDarkImage
        
        // Track which alarm preset is now applied (skip when caller already set this for instant feedback)
        if !skipIDUpdate {
            appliedAlarmPresetID = preset.id.uuidString
        }
    }
    
    /// Load settings from an alarm preset into DeviceSettings for editing.
    func loadAlarmPresetSettings(_ preset: AlarmWallpaperPreset) {
        alarmWallpaperDimming = preset.lightDimming
        alarmGlassVariant = preset.lightGlassVariant
        alarmGlassClearDimming = preset.lightGlassClearDimming
        alarmGlassTintRed = preset.lightGlassTintRed
        alarmGlassTintGreen = preset.lightGlassTintGreen
        alarmGlassTintBlue = preset.lightGlassTintBlue
        alarmGlassTintOpacity = preset.lightGlassTintOpacity
        alarmWallpaperScale = preset.lightWallpaperScale
        alarmWallpaperOffsetX = preset.lightWallpaperOffsetX
        alarmWallpaperOffsetY = preset.lightWallpaperOffsetY
        
        alarmDarkWallpaperDimming = preset.darkDimming
        alarmDarkGlassVariant = preset.darkGlassVariant
        alarmDarkGlassClearDimming = preset.darkGlassClearDimming
        alarmDarkGlassTintRed = preset.darkGlassTintRed
        alarmDarkGlassTintGreen = preset.darkGlassTintGreen
        alarmDarkGlassTintBlue = preset.darkGlassTintBlue
        alarmDarkGlassTintOpacity = preset.darkGlassTintOpacity
        alarmDarkWallpaperScale = preset.darkWallpaperScale
        alarmDarkWallpaperOffsetX = preset.darkWallpaperOffsetX
        alarmDarkWallpaperOffsetY = preset.darkWallpaperOffsetY
        
        // Load color customization
        alarmColorCustomization = preset.lightColorCustomization ?? .default
        alarmColorCustomizationDark = preset.darkColorCustomization ?? .default
        
        alarmWallpaperEnabled = preset.hasLightImage || preset.hasDarkImage
    }
    
    /// Delete an alarm preset.
    func deleteAlarmPreset(_ preset: AlarmWallpaperPreset) {
        guard !preset.isBuiltIn else { return }
        // If the deleted preset is the currently applied one, reset alarm wallpaper to defaults
        if appliedAlarmPresetID == preset.id.uuidString {
            resetAlarmWallpaperToDefault()
        }
        
        let presetDir = Self.alarmPresetsDirectory
            .appendingPathComponent(preset.id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: presetDir)
        
        var all = loadAlarmPresets()
        all.removeAll { $0.id == preset.id }
        saveAlarmPresetsManifest(all)
    }
    
    /// Reset alarm wallpaper settings to system defaults (no wallpaper, default glass/colors).
    func resetAlarmWallpaperToDefault() {
        removeWallpaper(for: "alarm_light")
        removeWallpaper(for: "alarm_dark")
        alarmWallpaperEnabled = false
        resetWallpaperPosition(for: "alarm_light")
        resetWallpaperPosition(for: "alarm_dark")
        alarmWallpaperDimming = 0.5
        alarmDarkWallpaperDimming = 0.5
        alarmGlassVariant = 0
        alarmDarkGlassVariant = 0
        alarmGlassClearDimming = 0.3
        alarmDarkGlassClearDimming = 0.3
        alarmGlassTintRed = 0.0
        alarmGlassTintGreen = 0.48
        alarmGlassTintBlue = 1.0
        alarmGlassTintOpacity = 1.0
        alarmDarkGlassTintRed = 0.0
        alarmDarkGlassTintGreen = 0.48
        alarmDarkGlassTintBlue = 1.0
        alarmDarkGlassTintOpacity = 1.0
        alarmColorCustomization = .default
        alarmColorCustomizationDark = .default
        appliedAlarmPresetID = nil
    }
    
    /// Reset all user-configurable settings to app defaults.
    /// Preserves: MQTT connection config, device name, alarms, NWS locations,
    /// onboarding/terms state, and nextAlarmIndex.
    func resetAllSettings() {
        // Alarm behavior defaults
        skipAlarmMode = .hold
        skipAlarmHoldDuration = 1.5
        snoozeMode = AppDefaults.snoozeMode
        snoozeHoldDuration = 1.5
        defaultSnoozeDuration = AppDefaults.defaultSnoozeDuration
        defaultMaxSnoozeCount = AppDefaults.defaultMaxSnoozeCount
        defaultMissionType = AppDefaults.defaultMissionType
        defaultTapDismissMode = .tap
        defaultTapCount = 1
        defaultTapHoldDuration = 3
        defaultBalanceHold = 0
        defaultBalanceZoneRadius = 0
        defaultBalanceZoneDwell = 0
        defaultShakeMode = .duration
        defaultShakeDuration = 10
        defaultShakeCount = 20
        defaultShakeIntensity = .medium
        defaultMathProblemCount = 3
        defaultMathDifficulty = .easy
        defaultBalanceDifficulty = .medium
        defaultBlockDropDifficulty = .medium
        defaultBlockDropLines = 0
        defaultBlockDropInterval = 0
        defaultBlockDropGarbageRows = -1
        defaultBlockDropGapWidth = 0
        defaultBlockDropGapsAligned = -1
        defaultMeteorDifficulty = .medium
        defaultMeteorTargets = 0
        defaultMeteorFireInterval = 0
        defaultHASnoozeMode = .normal
        defaultHAFallbackMission = .none
        defaultHAFallbackShakeMode = .duration
        defaultHAFallbackShakeDuration = 10
        defaultHAFallbackShakeCount = 20
        defaultHAFallbackShakeIntensity = .medium
        defaultHAFallbackMathProblemCount = 3
        defaultHAFallbackMathDifficulty = .easy
        defaultHAFallbackGracePeriod = 0
        defaultHASnoozeFallback = .hold
        defaultHASnoozeFallbackHoldDuration = 1.5
        enableMissionGracePeriod = true
        defaultGracePeriodOverride = 0

        // Sound & volume defaults
        defaultAlarmSound = AppDefaults.defaultAlarmSound
        alarmVolumeLevel = AppDefaults.alarmVolumeLevel
        mediaAlertVolume = 0.75
        alertDefaultSound = ""
        alertVibrationEnabled = true
        alertLoopMedia = false
        alertLoopDelay = 0
        alarmVibrationEnabled = true
        alarmFadeInEnabled = false
        alarmFadeInDuration = 5

        // General settings
        appPersistenceMode = .dynamic  // didSet realigns the legacy boolean
        suppressBackgroundRefreshWarning = false
        dynamicResidencyWhenArmed = true
        suppressLocationPermissionNag = false
        showAlarmNamesOnHome = true
        biggerAlarmRows = false
        editDuplicatedAlarms = true
        appAppearance = AppDefaults.appAppearance
        mqttAllowInboundCommands = false
        forceExternalConnection = false

        // Widget settings
        armButtonEnabled = false
        hassWidgetAlarmEnabled = true
        armButtonHoldDuration = 2.0
        armZone = "Home"
        biggerWidget = false
        widgetGlassVariant = 0
        widgetGlassClearDimming = 0.3
        widgetGlassTintRed = 0.0
        widgetGlassTintGreen = 0.48
        widgetGlassTintBlue = 1.0
        widgetGlassTintOpacity = 1.0
        widgetDarkGlassVariant = 0
        widgetDarkGlassClearDimming = 0.3
        widgetDarkGlassTintRed = 0.0
        widgetDarkGlassTintGreen = 0.48
        widgetDarkGlassTintBlue = 1.0
        widgetDarkGlassTintOpacity = 1.0
        widgetSwipeLeftCommandID = nil
        widgetSwipeRightCommandID = nil
        widgetDoubleTapCommandID = nil
        confirmCommandsEnabled = false

        // Consent resets to OFF and un-answered, so a full reset re-asks rather
        // than silently keeping a choice the user just wiped.
        analyticsOptIn = false
        productUpdatesOptIn = false
        hasAnsweredDataPreferences = false

        // Appearance — reset wallpapers and colors
        resetHomeWallpaperToDefault()
        resetAlarmWallpaperToDefault()

        // Force re-seed so Neon Silk gets applied as the active theme
        UserDefaults.standard.set(0, forKey: "builtInPresetSeededVersion")
        seedBuiltInPresetsIfNeeded()

        // Command form's remembered icon/color choices. Convenience only — the
        // commands themselves are untouched here.
        CommandPaletteRecents.clearAll()

        // Hand-picked theme accents, for every theme and both appearances. The
        // dictionary write persists through `didSet`; clearAll then removes the
        // key outright so nothing is left behind.
        themeAccentOverrides = [:]
        ThemeAccentStore.clearAll()

        AppLogger.shared.log("All settings reset to defaults by user", category: .general)
    }

    /// Rename an alarm preset.
    func renameAlarmPreset(_ preset: AlarmWallpaperPreset, to newName: String) {
        guard !preset.isBuiltIn else { return }
        var all = loadAlarmPresets()
        if let idx = all.firstIndex(where: { $0.id == preset.id }) {
            all[idx].name = newName
            saveAlarmPresetsManifest(all)
        }
    }
    
    /// Duplicate an alarm preset.
    @discardableResult
    func duplicateAlarmPreset(_ source: AlarmWallpaperPreset, newName: String) -> AlarmWallpaperPreset {
        let newID = UUID()
        let sourceDir = Self.alarmPresetsDirectory.appendingPathComponent(source.id.uuidString, isDirectory: true)
        let destDir = Self.alarmPresetsDirectory.appendingPathComponent(newID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        // Copy images
        for filename in ["light.jpg", "dark.jpg"] {
            let src = sourceDir.appendingPathComponent(filename)
            let dst = destDir.appendingPathComponent(filename)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        
        let duplicate = AlarmWallpaperPreset(
            id: newID,
            name: newName,
            createdAt: Date(),
            lightDimming: source.lightDimming,
            lightGlassVariant: source.lightGlassVariant,
            lightGlassClearDimming: source.lightGlassClearDimming,
            lightGlassTintRed: source.lightGlassTintRed,
            lightGlassTintGreen: source.lightGlassTintGreen,
            lightGlassTintBlue: source.lightGlassTintBlue,
            lightGlassTintOpacity: source.lightGlassTintOpacity,
            lightWallpaperScale: source.lightWallpaperScale,
            lightWallpaperOffsetX: source.lightWallpaperOffsetX,
            lightWallpaperOffsetY: source.lightWallpaperOffsetY,
            darkDimming: source.darkDimming,
            darkGlassVariant: source.darkGlassVariant,
            darkGlassClearDimming: source.darkGlassClearDimming,
            darkGlassTintRed: source.darkGlassTintRed,
            darkGlassTintGreen: source.darkGlassTintGreen,
            darkGlassTintBlue: source.darkGlassTintBlue,
            darkGlassTintOpacity: source.darkGlassTintOpacity,
            darkWallpaperScale: source.darkWallpaperScale,
            darkWallpaperOffsetX: source.darkWallpaperOffsetX,
            darkWallpaperOffsetY: source.darkWallpaperOffsetY,
            lightColorCustomization: source.lightColorCustomization,
            darkColorCustomization: source.darkColorCustomization,
            hasLightImage: source.hasLightImage,
            hasDarkImage: source.hasDarkImage
        )
        
        var all = loadAlarmPresets()
        all.append(duplicate)
        saveAlarmPresetsManifest(all)
        return duplicate
    }
    
    /// Load an alarm preset's thumbnail image for a given appearance.
    func loadAlarmPresetThumbnail(for preset: AlarmWallpaperPreset, appearance: WallpaperAppearance) -> UIImage? {
        let hasImage = appearance == .light ? preset.hasLightImage : preset.hasDarkImage
        guard hasImage else { return nil }
        let filename = appearance == .light ? "light.jpg" : "dark.jpg"
        let url = Self.alarmPresetsDirectory
            .appendingPathComponent(preset.id.uuidString)
            .appendingPathComponent(filename)
        return Self.downsampledImage(at: url, maxDimension: 120)
    }
    
    // MARK: - Built-in Preset Seeding
    
    /// Current built-in preset bundle version. Increment when adding new presets in future app updates.
    /// v13: alarm-screen accent colors (grace / shake / math / HA / snooze) recolored to match
    /// each theme's home accent, so the alarm and home read as one palette. Re-seeding refreshes
    /// the built-in preset library; a user picks up the new alarm colors on their next theme apply.
    private static let builtInPresetVersion = 15
    
    /// Seed built-in presets from the app bundle if not yet done for this version.
    func seedBuiltInPresetsIfNeeded() {
        let seededVersion = UserDefaults.standard.integer(forKey: "builtInPresetSeededVersion")
        print("[Presets] Seeded version: \(seededVersion), current: \(Self.builtInPresetVersion)")
        guard seededVersion < Self.builtInPresetVersion else {
            print("[Presets] Already seeded, skipping")
            return
        }
        
        print("[Presets] Seeding built-in presets…")
        seedHomePresets()
        seedAlarmPresets()
        
        let neonSilkID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")
        let defaultPresetID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")

        // Apply Neon Silk on first install, or migrate users who had the old Default
        // (plain no-wallpaper) preset applied — it's now hidden from the picker.
        let hadDefault = appliedHomePresetID == defaultPresetID?.uuidString
        if appliedHomePresetID == nil || hadDefault {
            let presets = loadPresets()
            if let neonSilk = presets.first(where: { $0.id == neonSilkID }) {
                applyPreset(neonSilk)
                if let alarmPresets = Optional(loadAlarmPresets()),
                   let neonSilkAlarm = alarmPresets.first(where: { $0.bundleImageSlug == "neon-silk" }) {
                    applyAlarmPreset(neonSilkAlarm)
                }
                print("[Presets] Applied Neon Silk as default theme (hadDefault=\(hadDefault))")
            }
        } else if let appliedID = appliedHomePresetID,
                  let applied = loadPresets().first(where: { $0.id.uuidString == appliedID }) {
            // The version bump refreshed the STORED preset colors above, but the
            // active theme's LIVE color customization was copied at apply-time and
            // is now stale. Re-apply the current theme (without changing which one
            // is applied) so refreshed colors reach the live surfaces.
            applyPreset(applied, skipIDUpdate: true)
            if let alarmApplied = loadAlarmPresets().first(where: { $0.bundleImageSlug == applied.bundleImageSlug }) {
                applyAlarmPreset(alarmApplied, skipIDUpdate: true)
            }
            print("[Presets] Re-applied active theme '\(applied.name)' to refresh colors after version bump")
        }
        
        UserDefaults.standard.set(Self.builtInPresetVersion, forKey: "builtInPresetSeededVersion")
        print("[Presets] Seeding complete, marked version \(Self.builtInPresetVersion)")
    }
    
    /// Locate a bundled resource, trying the `BuiltInPresets/…` subdirectory first
    /// (folder-reference layout) then falling back to the bundle root (flat Xcode groups).
    private func bundleURL(resource: String, ext: String, subdirectory: String) -> URL? {
        Bundle.main.url(forResource: resource, withExtension: ext, subdirectory: subdirectory)
            ?? Bundle.main.url(forResource: resource, withExtension: ext)
    }

    private func seedHomePresets() {
        guard let url = bundleURL(resource: "home_presets", ext: "json", subdirectory: "BuiltInPresets") else {
            print("[Presets] home_presets.json NOT found in bundle")
            return
        }
        print("[Presets] home_presets.json found at \(url.lastPathComponent)")

        guard let data = try? Data(contentsOf: url),
              let bundledPresets = try? JSONDecoder().decode([WallpaperPreset].self, from: data)
        else {
            print("[Presets] Failed to decode home_presets.json")
            return
        }
        print("[Presets] Decoded \(bundledPresets.count) home presets")

        var existing = loadPresets()
        let existingIDs = Set(existing.map(\.id))

        for var preset in bundledPresets {
            preset.isBuiltIn = true

            if existingIDs.contains(preset.id) {
                if let idx = existing.firstIndex(where: { $0.id == preset.id }) {
                    // Ensure existing presets have isBuiltIn flag set
                    if !existing[idx].isBuiltIn {
                        existing[idx].isBuiltIn = true
                    }
                    // Built-ins aren't user-editable (only duplicable), so a
                    // version bump refreshes their color customizations from
                    // the bundle — without this, shipped color fixes never
                    // reach devices that already seeded the preset.
                    existing[idx].lightColorCustomization = preset.lightColorCustomization
                    existing[idx].darkColorCustomization = preset.darkColorCustomization
                    // Same rationale for the status-bar preference: bundle
                    // metadata, not user-editable, so refresh it too — otherwise
                    // the white-status-bar fix never reaches devices that already
                    // seeded these presets.
                    existing[idx].statusBarPrefersLightContent = preset.statusBarPrefersLightContent
                }
                continue
            }

            // Copy images from bundle to preset directory
            let presetDir = Self.presetsDirectory
                .appendingPathComponent(preset.id.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: presetDir, withIntermediateDirectories: true)

            if let slug = preset.bundleImageSlug {
                for (mode, hasImage) in [("light", preset.hasLightImage), ("dark", preset.hasDarkImage)] {
                    guard hasImage else { continue }
                    // Bundle images are named <slug>-light.jpg / <slug>-dark.jpg (flat in bundle root)
                    let bundleResource = "\(slug)-\(mode)"
                    if let imgURL = bundleURL(resource: bundleResource, ext: "jpg", subdirectory: "BuiltInPresets/home/\(slug)") {
                        let destURL = presetDir.appendingPathComponent("\(mode).jpg")
                        try? FileManager.default.copyItem(at: imgURL, to: destURL)
                    }
                }
            }

            existing.append(preset)
        }

        savePresetsManifest(existing)
    }

    private func seedAlarmPresets() {
        guard let url = bundleURL(resource: "alarm_presets", ext: "json", subdirectory: "BuiltInPresets") else {
            print("[Presets] alarm_presets.json NOT found in bundle")
            return
        }
        print("[Presets] alarm_presets.json found at \(url.lastPathComponent)")

        guard let data = try? Data(contentsOf: url),
              let bundledPresets = try? JSONDecoder().decode([AlarmWallpaperPreset].self, from: data)
        else {
            print("[Presets] Failed to decode alarm_presets.json")
            return
        }
        print("[Presets] Decoded \(bundledPresets.count) alarm presets")

        var existing = loadAlarmPresets()
        let existingIDs = Set(existing.map(\.id))

        for var preset in bundledPresets {
            preset.isBuiltIn = true

            if existingIDs.contains(preset.id) {
                if let idx = existing.firstIndex(where: { $0.id == preset.id }) {
                    // Ensure existing presets have isBuiltIn flag set
                    if !existing[idx].isBuiltIn {
                        existing[idx].isBuiltIn = true
                    }
                    // Same contract as seedHomePresets: built-ins aren't
                    // user-editable, so a version bump refreshes their color
                    // customizations from the bundle on existing installs.
                    existing[idx].lightColorCustomization = preset.lightColorCustomization
                    existing[idx].darkColorCustomization = preset.darkColorCustomization
                }
                continue
            }

            let presetDir = Self.alarmPresetsDirectory
                .appendingPathComponent(preset.id.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: presetDir, withIntermediateDirectories: true)

            if let slug = preset.bundleImageSlug {
                for (mode, hasImage) in [("light", preset.hasLightImage), ("dark", preset.hasDarkImage)] {
                    guard hasImage else { continue }
                    let bundleResource = "\(slug)-\(mode)"
                    // Try alarm-specific images, then home images (shared themes)
                    let imgURL = bundleURL(resource: bundleResource, ext: "jpg", subdirectory: "BuiltInPresets/alarm/\(slug)")
                        ?? bundleURL(resource: bundleResource, ext: "jpg", subdirectory: "BuiltInPresets/home/\(slug)")
                    if let imgURL {
                        let destURL = presetDir.appendingPathComponent("\(mode).jpg")
                        try? FileManager.default.copyItem(at: imgURL, to: destURL)
                    }
                }
            }

            existing.append(preset)
        }

        saveAlarmPresetsManifest(existing)
    }
    
    // MARK: - Preset Sharing (Export / Import)
    
    /// Envelope written into every .hawakepreset package so the importer
    /// knows whether it contains a home or alarm preset.
    struct PresetPackage: Codable {
        enum PresetType: String, Codable { case home, alarm }
        let type: PresetType
        let homePreset: WallpaperPreset?
        let alarmPreset: AlarmWallpaperPreset?
        /// Whether this preset should be treated as the system default when bundled with the app.
        var systemDefault: Bool = false
    }
    
    /// Derive a URL-safe slug from a preset name.
    static func slug(from name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
    }
    
    // MARK: Import
    
    /// Result of importing a .hawakepreset file.
    enum PresetImportResult {
        case home(WallpaperPreset)
        case alarm(AlarmWallpaperPreset)
        case failure(String)
    }
    
    /// Import a .hawakepreset file from the given URL.
    /// Unzips, decodes the envelope, copies images, and adds to the manifest.
    func importPreset(from url: URL) -> PresetImportResult {
        let fm = FileManager.default
        let importBase = fm.temporaryDirectory.appendingPathComponent("PresetImport", isDirectory: true)
        let unzipDir = importBase.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.removeItem(at: unzipDir)
        try? fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        
        // Access security-scoped resource if needed (files from other apps)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        
        // Unzip using NSFileCoordinator
        var coordError: NSError?
        var unzipSuccess = false
        NSFileCoordinator().coordinate(writingItemAt: unzipDir, options: .forReplacing, error: &coordError) { destURL in
            // Copy the .hawakepreset file to a temp .zip so we can unzip it
            let tempZip = importBase.appendingPathComponent("import_temp.zip")
            try? fm.removeItem(at: tempZip)
            do {
                try fm.copyItem(at: url, to: tempZip)
                // Use Process/unzip — but on iOS we need to use a different approach.
                // We'll use the built-in decompression: rename to .zip and use
                // FileManager to read as archive via NSFileCoordinator
            } catch {
                return
            }
            // Actually, on iOS the simplest way to unzip is to use the
            // Archive framework or manual approach. Since NSFileCoordinator
            // .forUploading creates zips but doesn't unzip, we'll decompress
            // using the Foundation zip support available in iOS 16+.
            // For robustness, use a manual unzip via zlib.
            unzipSuccess = Self.unzipFile(at: tempZip, to: destURL)
            try? fm.removeItem(at: tempZip)
        }
        
        guard coordError == nil, unzipSuccess else {
            return .failure("Could not unzip preset file.")
        }
        
        // Find preset.json in the unzipped contents (may be nested in a subfolder)
        guard let presetJSON = Self.findFile(named: "preset.json", in: unzipDir) else {
            return .failure("Invalid preset file — no preset.json found.")
        }
        let packageDir = presetJSON.deletingLastPathComponent()
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard let jsonData = try? Data(contentsOf: presetJSON),
              let package = try? decoder.decode(PresetPackage.self, from: jsonData) else {
            return .failure("Could not read preset data.")
        }
        
        switch package.type {
        case .home:
            guard let original = package.homePreset else {
                return .failure("Missing home preset data.")
            }
            return importHomePreset(original, imagesDir: packageDir)
        case .alarm:
            guard let original = package.alarmPreset else {
                return .failure("Missing alarm preset data.")
            }
            return importAlarmPreset(original, imagesDir: packageDir)
        }
    }
    
    /// Returns a unique name by appending " 2", " 3", etc. if the name already exists.
    private func uniqueName(_ name: String, among existing: [String]) -> String {
        guard existing.contains(name) else { return name }
        var counter = 2
        while existing.contains("\(name) \(counter)") { counter += 1 }
        return "\(name) \(counter)"
    }
    
    private func importHomePreset(_ original: WallpaperPreset, imagesDir: URL) -> PresetImportResult {
        let fm = FileManager.default
        let newID = UUID()
        let presetDir = Self.presetsDirectory.appendingPathComponent(newID.uuidString, isDirectory: true)
        try? fm.createDirectory(at: presetDir, withIntermediateDirectories: true)
        
        // Copy images
        for filename in ["light.jpg", "dark.jpg"] {
            let src = imagesDir.appendingPathComponent(filename)
            if fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: presetDir.appendingPathComponent(filename))
            }
        }
        
        // Deduplicate name if a preset with the same name already exists
        let existingNames = loadPresets().map(\.name)
        let finalName = uniqueName(original.name, among: existingNames)
        
        // Create new preset with fresh ID
        let preset = WallpaperPreset(
            id: newID,
            name: finalName,
            createdAt: Date(),
            isBuiltIn: false,
            bundleImageSlug: nil,
            lightDimming: original.lightDimming,
            lightGlassVariant: original.lightGlassVariant,
            lightGlassClearDimming: original.lightGlassClearDimming,
            lightGlassTintRed: original.lightGlassTintRed,
            lightGlassTintGreen: original.lightGlassTintGreen,
            lightGlassTintBlue: original.lightGlassTintBlue,
            lightGlassTintOpacity: original.lightGlassTintOpacity,
            lightWallpaperScale: original.lightWallpaperScale,
            lightWallpaperOffsetX: original.lightWallpaperOffsetX,
            lightWallpaperOffsetY: original.lightWallpaperOffsetY,
            darkDimming: original.darkDimming,
            darkGlassVariant: original.darkGlassVariant,
            darkGlassClearDimming: original.darkGlassClearDimming,
            darkGlassTintRed: original.darkGlassTintRed,
            darkGlassTintGreen: original.darkGlassTintGreen,
            darkGlassTintBlue: original.darkGlassTintBlue,
            darkGlassTintOpacity: original.darkGlassTintOpacity,
            darkWallpaperScale: original.darkWallpaperScale,
            darkWallpaperOffsetX: original.darkWallpaperOffsetX,
            darkWallpaperOffsetY: original.darkWallpaperOffsetY,
            hasLightImage: original.hasLightImage,
            hasDarkImage: original.hasDarkImage,
            lightColorCustomization: original.lightColorCustomization,
            darkColorCustomization: original.darkColorCustomization
        )
        
        var all = loadPresets()
        all.append(preset)
        savePresetsManifest(all)
        return .home(preset)
    }
    
    private func importAlarmPreset(_ original: AlarmWallpaperPreset, imagesDir: URL) -> PresetImportResult {
        let fm = FileManager.default
        let newID = UUID()
        let presetDir = Self.alarmPresetsDirectory.appendingPathComponent(newID.uuidString, isDirectory: true)
        try? fm.createDirectory(at: presetDir, withIntermediateDirectories: true)
        
        for filename in ["light.jpg", "dark.jpg"] {
            let src = imagesDir.appendingPathComponent(filename)
            if fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: presetDir.appendingPathComponent(filename))
            }
        }
        
        // Deduplicate name if a preset with the same name already exists
        let existingNames = loadAlarmPresets().map(\.name)
        let finalName = uniqueName(original.name, among: existingNames)
        
        let preset = AlarmWallpaperPreset(
            id: newID,
            name: finalName,
            createdAt: Date(),
            isBuiltIn: false,
            bundleImageSlug: nil,
            lightDimming: original.lightDimming,
            lightGlassVariant: original.lightGlassVariant,
            lightGlassClearDimming: original.lightGlassClearDimming,
            lightGlassTintRed: original.lightGlassTintRed,
            lightGlassTintGreen: original.lightGlassTintGreen,
            lightGlassTintBlue: original.lightGlassTintBlue,
            lightGlassTintOpacity: original.lightGlassTintOpacity,
            lightWallpaperScale: original.lightWallpaperScale,
            lightWallpaperOffsetX: original.lightWallpaperOffsetX,
            lightWallpaperOffsetY: original.lightWallpaperOffsetY,
            darkDimming: original.darkDimming,
            darkGlassVariant: original.darkGlassVariant,
            darkGlassClearDimming: original.darkGlassClearDimming,
            darkGlassTintRed: original.darkGlassTintRed,
            darkGlassTintGreen: original.darkGlassTintGreen,
            darkGlassTintBlue: original.darkGlassTintBlue,
            darkGlassTintOpacity: original.darkGlassTintOpacity,
            darkWallpaperScale: original.darkWallpaperScale,
            darkWallpaperOffsetX: original.darkWallpaperOffsetX,
            darkWallpaperOffsetY: original.darkWallpaperOffsetY,
            lightColorCustomization: original.lightColorCustomization,
            darkColorCustomization: original.darkColorCustomization,
            hasLightImage: original.hasLightImage,
            hasDarkImage: original.hasDarkImage
        )
        
        var all = loadAlarmPresets()
        all.append(preset)
        saveAlarmPresetsManifest(all)
        return .alarm(preset)
    }
    
    // MARK: - Theme Import (.hawaketheme)
    
    /// Package written into .hawaketheme files — a unified theme containing
    /// paired home + alarm presets.
    struct ThemePackage: Codable {
        let name: String
        let homePreset: WallpaperPreset?
        let alarmPreset: AlarmWallpaperPreset?
    }
    
    enum ThemeImportResult {
        case success(name: String)
        case failure(String)
    }
    
    /// Import a .hawaketheme file from the given URL.
    /// Unzips, decodes the theme envelope, copies images for both home and alarm presets,
    /// and adds them to their respective manifests.
    func importTheme(from url: URL) -> ThemeImportResult {
        let fm = FileManager.default
        let importBase = fm.temporaryDirectory.appendingPathComponent("ThemeImport", isDirectory: true)
        let unzipDir = importBase.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.removeItem(at: unzipDir)
        try? fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        
        var coordError: NSError?
        var unzipSuccess = false
        NSFileCoordinator().coordinate(writingItemAt: unzipDir, options: .forReplacing, error: &coordError) { destURL in
            let tempZip = importBase.appendingPathComponent("theme_import_temp.zip")
            try? fm.removeItem(at: tempZip)
            do {
                try fm.copyItem(at: url, to: tempZip)
            } catch {
                return
            }
            unzipSuccess = Self.unzipFile(at: tempZip, to: destURL)
            try? fm.removeItem(at: tempZip)
        }
        
        guard coordError == nil, unzipSuccess else {
            return .failure("Could not unzip theme file.")
        }
        
        // Find theme.json in the unzipped contents
        guard let themeJSON = Self.findFile(named: "theme.json", in: unzipDir) else {
            // Fall back to preset.json for backward compatibility
            guard let presetJSON = Self.findFile(named: "preset.json", in: unzipDir) else {
                return .failure("Invalid theme file — no theme.json found.")
            }
            // Import as legacy preset
            let packageDir = presetJSON.deletingLastPathComponent()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let jsonData = try? Data(contentsOf: presetJSON),
                  let package = try? decoder.decode(PresetPackage.self, from: jsonData) else {
                return .failure("Could not read preset data.")
            }
            switch package.type {
            case .home:
                guard let original = package.homePreset else { return .failure("Missing home preset data.") }
                let result = importHomePreset(original, imagesDir: packageDir)
                if case .home(let p) = result { return .success(name: p.name) }
                return .failure("Failed to import home preset.")
            case .alarm:
                guard let original = package.alarmPreset else { return .failure("Missing alarm preset data.") }
                let result = importAlarmPreset(original, imagesDir: packageDir)
                if case .alarm(let p) = result { return .success(name: p.name) }
                return .failure("Failed to import alarm preset.")
            }
        }
        
        let packageDir = themeJSON.deletingLastPathComponent()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard let jsonData = try? Data(contentsOf: themeJSON),
              let theme = try? decoder.decode(ThemePackage.self, from: jsonData) else {
            return .failure("Could not read theme data.")
        }
        
        // Import home preset if present
        if let homeOriginal = theme.homePreset {
            // Copy home images: home-light.jpg → light.jpg, home-dark.jpg → dark.jpg
            let homeImagesDir = fm.temporaryDirectory.appendingPathComponent("ThemeHomeImages-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: homeImagesDir, withIntermediateDirectories: true)
            
            for (src, dst) in [("home-light.jpg", "light.jpg"), ("home-dark.jpg", "dark.jpg")] {
                let srcURL = packageDir.appendingPathComponent(src)
                // Also try just "light.jpg"/"dark.jpg" for simpler theme packages
                let altSrcURL = packageDir.appendingPathComponent(dst)
                let dstURL = homeImagesDir.appendingPathComponent(dst)
                if fm.fileExists(atPath: srcURL.path) {
                    try? fm.copyItem(at: srcURL, to: dstURL)
                } else if fm.fileExists(atPath: altSrcURL.path) {
                    try? fm.copyItem(at: altSrcURL, to: dstURL)
                }
            }
            _ = importHomePreset(homeOriginal, imagesDir: homeImagesDir)
            try? fm.removeItem(at: homeImagesDir)
        }
        
        // Import alarm preset if present
        if let alarmOriginal = theme.alarmPreset {
            let alarmImagesDir = fm.temporaryDirectory.appendingPathComponent("ThemeAlarmImages-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: alarmImagesDir, withIntermediateDirectories: true)
            
            for (src, dst) in [("alarm-light.jpg", "light.jpg"), ("alarm-dark.jpg", "dark.jpg")] {
                let srcURL = packageDir.appendingPathComponent(src)
                let altSrcURL = packageDir.appendingPathComponent(dst)
                let dstURL = alarmImagesDir.appendingPathComponent(dst)
                if fm.fileExists(atPath: srcURL.path) {
                    try? fm.copyItem(at: srcURL, to: dstURL)
                } else if fm.fileExists(atPath: altSrcURL.path) {
                    try? fm.copyItem(at: altSrcURL, to: dstURL)
                }
            }
            _ = importAlarmPreset(alarmOriginal, imagesDir: alarmImagesDir)
            try? fm.removeItem(at: alarmImagesDir)
        }
        
        // Clean up
        try? fm.removeItem(at: unzipDir)
        
        NotificationCenter.default.post(name: .presetImported, object: nil)
        return .success(name: theme.name)
    }
    
    /// Recursively find a file by name inside a directory.
    private static func findFile(named name: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        let direct = directory.appendingPathComponent(name)
        if fm.fileExists(atPath: direct.path) { return direct }
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == name { return fileURL }
        }
        return nil
    }
    
    /// Unzip a .zip file to a destination directory using shell-free approach.
    /// Uses Apple's built-in zip support via Process on macOS or manual decompression on iOS.
    private static func unzipFile(at source: URL, to destination: URL) -> Bool {
        // On iOS, NSFileCoordinator can create zips but not unzip.
        // We use the low-level approach: read the zip as data and extract using
        // Apple's Archive framework if available, or fall back to spawning
        // a coordinated read.
        //
        // Simplest reliable approach: copy zip contents using FileManager's
        // built-in zip handling by reading through a coordinated accessor.
        // Actually, the simplest iOS-compatible approach is to use the
        // `compression` framework or just shell out to /usr/bin/ditto.
        //
        // Since we're on iOS where Process is unavailable, we'll use a
        // simple zip reader implementation.
        
        guard let zipData = try? Data(contentsOf: source) else { return false }
        return extractZip(data: zipData, to: destination)
    }
    
    /// Largest uncompressed size accepted for a single zip entry. Preset and theme
    /// packages are a JSON file plus a couple of JPEGs, so 64 MB is generous.
    static let maxZipEntryBytes = 64 * 1024 * 1024
    /// Largest total uncompressed payload accepted across one archive.
    static let maxZipTotalBytes = 128 * 1024 * 1024

    /// Minimal zip extractor — handles the standard zip format used by NSFileCoordinator.
    /// Returns false on any malformed, oversized or escaping entry; a partial extraction
    /// must never be reported as success (the import call sites surface the failure).
    static func extractZip(data rawData: Data, to destination: URL) -> Bool {
        let fm = FileManager.default
        // Normalise to a zero-based buffer — the offset arithmetic below indexes absolutely.
        let data = rawData.startIndex == 0 ? rawData : Data(rawData)

        // Zip local file header signature: PK\x03\x04
        let signature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        let rootPath = destination.standardizedFileURL.path
        var offset = 0
        var entryCount = 0
        var totalUncompressed = 0

        func fail(_ reason: String) -> Bool {
            AppLogger.shared.log("Zip extraction rejected: \(reason)", category: .general)
            return false
        }

        while offset + 30 <= data.count {
            // Check for local file header signature
            let headerBytes = [UInt8](data[offset..<offset+4])
            guard headerBytes == signature else {
                // The central directory (PK\x01\x02 / PK\x05\x06) legitimately follows the
                // last local header. Anything else — including garbage where the first
                // entry should be — is malformed.
                guard entryCount > 0, headerBytes[0] == 0x50, headerBytes[1] == 0x4B else {
                    return fail("bad local header at offset \(offset)")
                }
                break
            }

            let compressionMethod = UInt16(data[offset+8]) | (UInt16(data[offset+9]) << 8)
            let compressedSize = UInt32(data[offset+18]) | (UInt32(data[offset+19]) << 8) | (UInt32(data[offset+20]) << 16) | (UInt32(data[offset+21]) << 24)
            let uncompressedSize = UInt32(data[offset+22]) | (UInt32(data[offset+23]) << 8) | (UInt32(data[offset+24]) << 16) | (UInt32(data[offset+25]) << 24)
            let fileNameLen = Int(UInt16(data[offset+26]) | (UInt16(data[offset+27]) << 8))
            let extraLen = Int(UInt16(data[offset+28]) | (UInt16(data[offset+29]) << 8))

            let fileNameStart = offset + 30
            guard fileNameStart + fileNameLen <= data.count else { return fail("truncated file name") }
            let fileNameData = data[fileNameStart..<fileNameStart+fileNameLen]
            guard let fileName = String(data: fileNameData, encoding: .utf8) else {
                return fail("file name is not valid UTF-8")
            }

            let dataStart = fileNameStart + fileNameLen + extraLen
            let dataEnd = dataStart + Int(compressedSize)
            guard dataEnd <= data.count, dataStart <= dataEnd else { return fail("truncated entry data") }

            // Reject path traversal: absolute paths, home-relative paths, and any `..`
            // segment. A crafted name would otherwise write outside the extraction root.
            let nameComponents = fileName.split(separator: "/", omittingEmptySubsequences: true)
            guard !fileName.hasPrefix("/"), !fileName.hasPrefix("~"),
                  !nameComponents.contains("..") else {
                return fail("entry '\(fileName)' escapes the extraction root")
            }

            let fileURL = destination.appendingPathComponent(fileName)
            let resolvedPath = fileURL.standardizedFileURL.path
            guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
                return fail("entry '\(fileName)' resolves outside the extraction root")
            }

            // Bound the declared uncompressed size before anything is allocated or written.
            guard Int(uncompressedSize) <= Self.maxZipEntryBytes,
                  Int(compressedSize) <= Self.maxZipEntryBytes else {
                return fail("entry '\(fileName)' declares \(uncompressedSize) bytes, over the per-entry limit")
            }
            totalUncompressed += Int(uncompressedSize)
            guard totalUncompressed <= Self.maxZipTotalBytes else {
                return fail("archive exceeds the \(Self.maxZipTotalBytes) byte total limit")
            }

            do {
                if fileName.hasSuffix("/") {
                    // Directory entry
                    try fm.createDirectory(at: fileURL, withIntermediateDirectories: true)
                } else {
                    // Create parent directories
                    try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                    let compressedData = data[dataStart..<dataEnd]

                    if compressionMethod == 0 {
                        // Stored (no compression)
                        try Data(compressedData).write(to: fileURL)
                    } else if compressionMethod == 8 {
                        // Deflate — use NSData decompression
                        // zlib raw deflate needs the data wrapped for NSData.
                        // NSData expects raw zlib format, but zip uses raw deflate (no header).
                        // We need to use the Compression framework instead.
                        guard let decompressed = Self.decompressDeflate(Data(compressedData), expectedSize: Int(uncompressedSize)) else {
                            return fail("entry '\(fileName)' failed to decompress")
                        }
                        try decompressed.write(to: fileURL)
                    } else {
                        return fail("entry '\(fileName)' uses unsupported compression method \(compressionMethod)")
                    }
                }
            } catch {
                return fail("could not write entry '\(fileName)': \(error.localizedDescription)")
            }

            entryCount += 1
            offset = dataEnd
        }

        guard entryCount > 0 else { return fail("archive contains no entries") }
        return true
    }

    /// Decompress raw deflate data using the Compression framework.
    private static func decompressDeflate(_ data: Data, expectedSize: Int) -> Data? {
        import_compression: do {
            // `expectedSize` comes from the archive header, so it is attacker-controlled;
            // extractZip already bounds it, this is the second line of defence.
            let bufferSize = min(max(expectedSize, 1024), Self.maxZipEntryBytes)
            var decompressed = Data(count: bufferSize)
            let result = decompressed.withUnsafeMutableBytes { destBuffer in
                data.withUnsafeBytes { srcBuffer in
                    compression_decode_buffer(
                        destBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        bufferSize,
                        srcBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            guard result > 0 else { return nil }
            decompressed.count = result
            return decompressed
        }
    }
    
    // MARK: - Export Preset as Built-in (DEBUG)
    
    #if DEBUG
    /// Package a home wallpaper preset into a zip file for inclusion in the app's BuiltInPresets bundle.
    /// Returns the zip file URL for sharing via UIActivityViewController.
    func exportPresetAsBuiltIn(_ preset: WallpaperPreset) -> URL? {
        let slug = Self.slug(from: preset.name)
        let exportBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuiltInExport", isDirectory: true)
        let tempRoot = exportBase.appendingPathComponent(slug, isDirectory: true)
        
        try? FileManager.default.removeItem(at: tempRoot)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        
        var exportPreset = preset
        exportPreset.isBuiltIn = true
        exportPreset.bundleImageSlug = slug
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let jsonData = try? encoder.encode(exportPreset) else { return nil }
        try? jsonData.write(to: tempRoot.appendingPathComponent("preset.json"))
        
        let presetDir = Self.presetsDirectory
            .appendingPathComponent(preset.id.uuidString, isDirectory: true)
        for filename in ["light.jpg", "dark.jpg"] {
            let src = presetDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: tempRoot.appendingPathComponent(filename))
            }
        }
        
        let zipURL = exportBase.appendingPathComponent("\(slug).zip")
        try? FileManager.default.removeItem(at: zipURL)
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: tempRoot, options: .forUploading, error: &coordError) { zippedURL in
            try? FileManager.default.copyItem(at: zippedURL, to: zipURL)
        }
        guard coordError == nil, FileManager.default.fileExists(atPath: zipURL.path) else { return nil }
        return zipURL
    }
    
    /// Package an alarm wallpaper preset into a zip file for inclusion in the app's BuiltInPresets bundle.
    func exportAlarmPresetAsBuiltIn(_ preset: AlarmWallpaperPreset) -> URL? {
        let slug = Self.slug(from: preset.name)
        let exportBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuiltInExport", isDirectory: true)
        let tempRoot = exportBase.appendingPathComponent(slug, isDirectory: true)
        
        try? FileManager.default.removeItem(at: tempRoot)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        
        var exportPreset = preset
        exportPreset.isBuiltIn = true
        exportPreset.bundleImageSlug = slug
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let jsonData = try? encoder.encode(exportPreset) else { return nil }
        try? jsonData.write(to: tempRoot.appendingPathComponent("preset.json"))
        
        let presetDir = Self.alarmPresetsDirectory
            .appendingPathComponent(preset.id.uuidString, isDirectory: true)
        for filename in ["light.jpg", "dark.jpg"] {
            let src = presetDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: tempRoot.appendingPathComponent(filename))
            }
        }
        
        let zipURL = exportBase.appendingPathComponent("\(slug).zip")
        try? FileManager.default.removeItem(at: zipURL)
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: tempRoot, options: .forUploading, error: &coordError) { zippedURL in
            try? FileManager.default.copyItem(at: zippedURL, to: zipURL)
        }
        guard coordError == nil, FileManager.default.fileExists(atPath: zipURL.path) else { return nil }
        return zipURL
    }
    #endif
    
    // MARK: - Debug Settings (only used in DEBUG builds)
    
    // Quick alarm fire: override next alarm to fire in N seconds
    var debugQuickAlarmEnabled: Bool {
        didSet { UserDefaults.standard.set(debugQuickAlarmEnabled, forKey: "debugQuickAlarmEnabled") }
    }
    var debugQuickAlarmDelay: Int {
        didSet { UserDefaults.standard.set(debugQuickAlarmDelay, forKey: "debugQuickAlarmDelay") }
    }
    
    // Quick snooze: override snooze duration to N seconds
    var debugQuickSnoozeEnabled: Bool {
        didSet { UserDefaults.standard.set(debugQuickSnoozeEnabled, forKey: "debugQuickSnoozeEnabled") }
    }
    var debugQuickSnoozeDelay: Int {
        didSet { UserDefaults.standard.set(debugQuickSnoozeDelay, forKey: "debugQuickSnoozeDelay") }
    }
    

    
    private init() {
        let _t = Date()
        func elapsed(_ label: String) {
            let ms = Date().timeIntervalSince(_t) * 1000
            print(String(format: "⏱️ [DeviceSettings.init] %@ — %.0f ms", label, ms))
        }
        print("⏱️ [DeviceSettings.init] START")

        // Initialize from UserDefaults or use defaults
        // deviceName: UserDefaults first, then Keychain backup (survives reinstall), then device name
        self.deviceName = UserDefaults.standard.string(forKey: "deviceName")
            ?? KeychainHelper.shared.read(forKey: "kc.deviceName")
            ?? UIDevice.current.name
        elapsed("deviceName")

        self.mqttEnabled = UserDefaults.standard.bool(forKey: "mqttEnabled")

        // MQTT connection settings: UserDefaults first, Keychain backup on fresh install
        self.mqttInternalHost = UserDefaults.standard.object(forKey: "mqttInternalHost") != nil
            ? (UserDefaults.standard.string(forKey: "mqttInternalHost") ?? "")
            : (KeychainHelper.shared.read(forKey: "kc.mqttInternalHost") ?? "")
        elapsed("mqttInternalHost")
        self.mqttInternalPort = UserDefaults.standard.object(forKey: "mqttInternalPort") != nil
            ? UserDefaults.standard.integer(forKey: "mqttInternalPort")
            : (KeychainHelper.shared.read(forKey: "kc.mqttInternalPort").flatMap(Int.init) ?? 1883)
        elapsed("mqttInternalPort")

        self.mqttExternalHost = UserDefaults.standard.object(forKey: "mqttExternalHost") != nil
            ? (UserDefaults.standard.string(forKey: "mqttExternalHost") ?? "")
            : (KeychainHelper.shared.read(forKey: "kc.mqttExternalHost") ?? "")
        elapsed("mqttExternalHost")
        self.mqttExternalPort = UserDefaults.standard.object(forKey: "mqttExternalPort") != nil
            ? UserDefaults.standard.integer(forKey: "mqttExternalPort")
            : (KeychainHelper.shared.read(forKey: "kc.mqttExternalPort").flatMap(Int.init) ?? 8883)
        elapsed("mqttExternalPort")

        // TLS: the flag had no effect before it was wired to the internal broker, so a
        // stored `true` never meant a working TLS setup. One-time reset to false keeps
        // existing plaintext home brokers connecting; TLS is opt-in via Settings.
        if !UserDefaults.standard.bool(forKey: "mqttUseTLSWiredMigration") {
            // "Fresh setup" = no internal broker host has ever been saved, in
            // UserDefaults or in the Keychain backup. Only then do we seed the
            // toggle ON, so a brand-new configuration starts encrypted. Anyone
            // with an existing broker configured keeps their working plaintext
            // connection — flipping that would break every already-set-up user,
            // which is exactly the failure the backwards-compatibility rule names.
            // Read the stored values directly — `self`'s properties are not all
            // initialised yet at this point in `init`.
            let storedInternalHost = UserDefaults.standard.string(forKey: "mqttInternalHost")
                ?? KeychainHelper.shared.read(forKey: "kc.mqttInternalHost")
            let storedExternalHost = UserDefaults.standard.string(forKey: "mqttExternalHost")
                ?? KeychainHelper.shared.read(forKey: "kc.mqttExternalHost")
            let hasExistingBrokerConfig = !(storedInternalHost ?? "").isEmpty
                || !(storedExternalHost ?? "").isEmpty
                || UserDefaults.standard.bool(forKey: "mqttEnabled")
            let seeded = !hasExistingBrokerConfig
            self.mqttUseTLS = seeded
            UserDefaults.standard.set(seeded, forKey: "mqttUseTLS")
            UserDefaults.standard.set(true, forKey: "mqttUseTLSWiredMigration")
        } else if UserDefaults.standard.object(forKey: "mqttUseTLS") != nil {
            self.mqttUseTLS = UserDefaults.standard.bool(forKey: "mqttUseTLS")
        } else if let kcTLS = KeychainHelper.shared.read(forKey: "kc.mqttUseTLS") {
            self.mqttUseTLS = kcTLS == "true"
        } else {
            self.mqttUseTLS = false
        }
        elapsed("mqttUseTLS")

        // Username/password: deferred to syncMQTTCredentialsFromKeychain() so the
        // Keychain XPC round-trip (can take 2-5s per call on cold launch) never blocks
        // the main thread. Start with empty strings; MQTT connection in onAppear waits
        // up to 5s for network resolution, giving the background read ample time to finish.
        if let legacyUsername = UserDefaults.standard.string(forKey: "mqttUsername"), !legacyUsername.isEmpty {
            // One-time migration of username from UserDefaults → Keychain.
            // Do it synchronously here so we never leave it in UserDefaults.
            self.mqttUsername = legacyUsername
            KeychainHelper.shared.save(legacyUsername, forKey: "mqttUsername")
            UserDefaults.standard.removeObject(forKey: "mqttUsername")
        } else {
            self.mqttUsername = ""   // filled in by syncMQTTCredentialsFromKeychain()
        }
        self.mqttPassword = ""       // filled in by syncMQTTCredentialsFromKeychain()
        elapsed("mqttUsername+password (deferred)")

        self.mqttTopicPrefix = UserDefaults.standard.object(forKey: "mqttTopicPrefix") != nil
            ? (UserDefaults.standard.string(forKey: "mqttTopicPrefix") ?? "allarise")
            : (KeychainHelper.shared.read(forKey: "kc.mqttTopicPrefix") ?? "allarise")
        elapsed("mqttTopicPrefix")

        if let ssids = UserDefaults.standard.array(forKey: "homeSSIDs") as? [String] {
            self.homeSSIDs = ssids
        } else if let json = KeychainHelper.shared.read(forKey: "kc.homeSSIDs"),
                  let data = json.data(using: .utf8),
                  let ssids = try? JSONDecoder().decode([String].self, from: data) {
            self.homeSSIDs = ssids
        } else {
            self.homeSSIDs = []
        }
        elapsed("homeSSIDs")
        
        self.debugForceHomeNetwork = UserDefaults.standard.bool(forKey: "debugForceHomeNetwork")
        self.forceExternalConnection = UserDefaults.standard.bool(forKey: "forceExternalConnection")
        
        // mqttPublishRetained is now always true (computed property)
        
        self.mqttAllowInboundCommands = UserDefaults.standard.bool(forKey: "mqttAllowInboundCommands")
        
        // Skip Alarm Mode: migrate from legacy enableSkipToday + skipTodayHoldDuration
        if let savedMode = UserDefaults.standard.string(forKey: "skipAlarmMode"),
           let mode = SkipAlarmMode(rawValue: savedMode) {
            self.skipAlarmMode = mode
        } else if UserDefaults.standard.object(forKey: "enableSkipToday") != nil {
            // Migrate from old settings
            let wasEnabled = UserDefaults.standard.bool(forKey: "enableSkipToday")
            let oldHoldDuration = UserDefaults.standard.object(forKey: "skipTodayHoldDuration") != nil
                ? UserDefaults.standard.double(forKey: "skipTodayHoldDuration") : 1.5
            let migratedSkipMode: SkipAlarmMode
            if !wasEnabled {
                migratedSkipMode = .disabled
            } else if oldHoldDuration == 0 {
                migratedSkipMode = .tap
            } else {
                migratedSkipMode = .hold
            }
            self.skipAlarmMode = migratedSkipMode
            UserDefaults.standard.set(migratedSkipMode.rawValue, forKey: "skipAlarmMode")
        } else {
            // Default: hold to skip
            self.skipAlarmMode = .hold
            UserDefaults.standard.set(SkipAlarmMode.hold.rawValue, forKey: "skipAlarmMode")
        }
        
        self.skipAlarmHoldDuration = UserDefaults.standard.object(forKey: "skipAlarmHoldDuration") != nil
            ? UserDefaults.standard.double(forKey: "skipAlarmHoldDuration")
            : (UserDefaults.standard.object(forKey: "skipTodayHoldDuration") != nil
                ? UserDefaults.standard.double(forKey: "skipTodayHoldDuration") : 1.5)
        
        // Snooze duration + max count: install-date-gated defaults via AppDefaults.
        // See Documents/21-APP-DEFAULTS.md.
        self.defaultSnoozeDuration = UserDefaults.standard.object(forKey: "defaultSnoozeDuration") != nil
            ? UserDefaults.standard.integer(forKey: "defaultSnoozeDuration")
            : AppDefaults.defaultSnoozeDuration

        self.defaultMaxSnoozeCount = UserDefaults.standard.object(forKey: "defaultMaxSnoozeCount") != nil
            ? UserDefaults.standard.integer(forKey: "defaultMaxSnoozeCount")
            : AppDefaults.defaultMaxSnoozeCount
        
        // Snooze Mode: explicit value > legacy migration > install-date-gated default.
        // The plain-default branch intentionally does NOT write back to UserDefaults so
        // that brand-new installs resolve through `AppDefaults.snoozeMode` on every
        // launch (the install-date buckets the user consistently).
        // See Documents/21-APP-DEFAULTS.md.
        if let savedMode = UserDefaults.standard.string(forKey: "snoozeMode"),
           let mode = SnoozeMode(rawValue: savedMode) {
            self.snoozeMode = mode
        } else if UserDefaults.standard.object(forKey: "snoozeRequiresHold") != nil {
            // Legacy migration from the pre-release `snoozeRequiresHold` bool + the
            // old convention where a 0-minute duration meant "snooze disabled".
            let wasHold = UserDefaults.standard.bool(forKey: "snoozeRequiresHold")
            let oldSnoozeDuration = UserDefaults.standard.object(forKey: "defaultSnoozeDuration") != nil
                ? UserDefaults.standard.integer(forKey: "defaultSnoozeDuration") : 9
            let migratedSnoozeMode: SnoozeMode
            if oldSnoozeDuration == 0 {
                migratedSnoozeMode = .disabled
            } else {
                migratedSnoozeMode = wasHold ? .hold : .tap
            }
            self.snoozeMode = migratedSnoozeMode
            UserDefaults.standard.set(migratedSnoozeMode.rawValue, forKey: "snoozeMode")
        } else {
            // Brand-new install. `AppDefaults.snoozeMode` is install-date-gated:
            // users installed before 2026-04-10 get `.hold` (historical default),
            // users on or after get `.tap` (current default).
            self.snoozeMode = AppDefaults.snoozeMode
        }
        
        self.snoozeHoldDuration = UserDefaults.standard.object(forKey: "snoozeHoldDuration") != nil
            ? UserDefaults.standard.double(forKey: "snoozeHoldDuration") : 1.5
        
        // Default mission type: install-date-gated via AppDefaults.
        // See Documents/21-APP-DEFAULTS.md.
        if let savedMissionType = UserDefaults.standard.string(forKey: "defaultMissionType"),
           let mission = MissionType(rawValue: savedMissionType) {
            self.defaultMissionType = mission
        } else {
            self.defaultMissionType = AppDefaults.defaultMissionType
        }
        
        // Default Tap (missionless) dismiss configuration
        self.defaultTapDismissMode = TapDismissMode(rawValue: UserDefaults.standard.string(forKey: "defaultTapDismissMode") ?? "") ?? .tap
        self.defaultTapCount = UserDefaults.standard.object(forKey: "defaultTapCount") != nil
            ? UserDefaults.standard.integer(forKey: "defaultTapCount") : 1
        self.defaultTapHoldDuration = UserDefaults.standard.object(forKey: "defaultTapHoldDuration") != nil
            ? UserDefaults.standard.double(forKey: "defaultTapHoldDuration") : 3

        // Default mission configuration
        self.defaultShakeMode = ShakeMode(rawValue: UserDefaults.standard.string(forKey: "defaultShakeMode") ?? "") ?? .duration
        self.defaultShakeDuration = UserDefaults.standard.object(forKey: "defaultShakeDuration") != nil
            ? UserDefaults.standard.integer(forKey: "defaultShakeDuration") : 10
        self.defaultShakeCount = UserDefaults.standard.object(forKey: "defaultShakeCount") != nil
            ? UserDefaults.standard.integer(forKey: "defaultShakeCount") : 20
        self.defaultShakeIntensity = ShakeIntensity(rawValue: UserDefaults.standard.string(forKey: "defaultShakeIntensity") ?? "") ?? .medium
        self.defaultMathProblemCount = UserDefaults.standard.object(forKey: "defaultMathProblemCount") != nil
            ? UserDefaults.standard.integer(forKey: "defaultMathProblemCount") : 3
        self.defaultMathDifficulty = MathDifficulty(rawValue: UserDefaults.standard.string(forKey: "defaultMathDifficulty") ?? "") ?? .easy
        self.defaultBalanceDifficulty = BalanceDifficulty(rawValue: UserDefaults.standard.string(forKey: "defaultBalanceDifficulty") ?? "") ?? .medium
        self.defaultBalanceHold = UserDefaults.standard.double(forKey: "defaultBalanceHold")
        self.defaultBalanceZoneRadius = UserDefaults.standard.double(forKey: "defaultBalanceZoneRadius")
        self.defaultBalanceZoneDwell = UserDefaults.standard.double(forKey: "defaultBalanceZoneDwell")
        self.defaultBlockDropDifficulty = BlockDropDifficulty(rawValue: UserDefaults.standard.string(forKey: "defaultBlockDropDifficulty") ?? "") ?? .medium
        self.defaultBlockDropLines = UserDefaults.standard.integer(forKey: "defaultBlockDropLines")
        self.defaultBlockDropInterval = UserDefaults.standard.double(forKey: "defaultBlockDropInterval")
        self.defaultBlockDropGarbageRows = UserDefaults.standard.object(forKey: "defaultBlockDropGarbageRows") != nil
            ? UserDefaults.standard.integer(forKey: "defaultBlockDropGarbageRows") : -1
        self.defaultBlockDropGapWidth = UserDefaults.standard.integer(forKey: "defaultBlockDropGapWidth")
        self.defaultBlockDropGapsAligned = UserDefaults.standard.object(forKey: "defaultBlockDropGapsAligned") != nil
            ? UserDefaults.standard.integer(forKey: "defaultBlockDropGapsAligned") : -1
        self.defaultMeteorDifficulty = MeteorDifficulty(rawValue: UserDefaults.standard.string(forKey: "defaultMeteorDifficulty") ?? "") ?? .medium
        self.defaultMeteorTargets = UserDefaults.standard.integer(forKey: "defaultMeteorTargets")
        self.defaultMeteorFireInterval = UserDefaults.standard.double(forKey: "defaultMeteorFireInterval")
        self.defaultHASnoozeMode = HASnoozeMode(rawValue: UserDefaults.standard.string(forKey: "defaultHASnoozeMode") ?? "") ?? .normal
        self.defaultHAFallbackMission = MissionType(rawValue: UserDefaults.standard.string(forKey: "defaultHAFallbackMission") ?? "") ?? .none
        
        // Dismiss fallback config defaults
        self.defaultHAFallbackShakeMode = ShakeMode(rawValue: UserDefaults.standard.string(forKey: "defaultHAFallbackShakeMode") ?? "") ?? .duration
        self.defaultHAFallbackShakeDuration = UserDefaults.standard.object(forKey: "defaultHAFallbackShakeDuration") != nil
            ? UserDefaults.standard.integer(forKey: "defaultHAFallbackShakeDuration") : 10
        self.defaultHAFallbackShakeCount = UserDefaults.standard.object(forKey: "defaultHAFallbackShakeCount") != nil
            ? UserDefaults.standard.integer(forKey: "defaultHAFallbackShakeCount") : 20
        self.defaultHAFallbackShakeIntensity = ShakeIntensity(rawValue: UserDefaults.standard.string(forKey: "defaultHAFallbackShakeIntensity") ?? "") ?? .medium
        self.defaultHAFallbackMathProblemCount = UserDefaults.standard.object(forKey: "defaultHAFallbackMathProblemCount") != nil
            ? UserDefaults.standard.integer(forKey: "defaultHAFallbackMathProblemCount") : 3
        self.defaultHAFallbackMathDifficulty = MathDifficulty(rawValue: UserDefaults.standard.string(forKey: "defaultHAFallbackMathDifficulty") ?? "") ?? .easy
        self.defaultHAFallbackGracePeriod = UserDefaults.standard.double(forKey: "defaultHAFallbackGracePeriod")
        
        // Snooze fallback defaults
        self.defaultHASnoozeFallback = SnoozeMode(rawValue: UserDefaults.standard.string(forKey: "defaultHASnoozeFallback") ?? "") ?? .hold
        self.defaultHASnoozeFallbackHoldDuration = UserDefaults.standard.object(forKey: "defaultHASnoozeFallbackHoldDuration") != nil
            ? UserDefaults.standard.double(forKey: "defaultHASnoozeFallbackHoldDuration") : 1.5
        
        // Mission grace period: default enabled
        if UserDefaults.standard.object(forKey: "enableMissionGracePeriod") != nil {
            self.enableMissionGracePeriod = UserDefaults.standard.bool(forKey: "enableMissionGracePeriod")
        } else {
            self.enableMissionGracePeriod = true
        }
        self.defaultGracePeriodOverride = UserDefaults.standard.double(forKey: "defaultGracePeriodOverride") // 0 = use formula

        // Default alarm sound: install-date-gated via AppDefaults.
        // See Documents/21-APP-DEFAULTS.md.
        self.defaultAlarmSound = UserDefaults.standard.string(forKey: "defaultAlarmSound")
            ?? AppDefaults.defaultAlarmSound

        // Default wake-up radio station for new alarms
        if let data = UserDefaults.standard.data(forKey: "defaultRadioStation"),
           let station = try? JSONDecoder().decode(RadioStation.self, from: data) {
            self.defaultRadioStation = station
        } else {
            self.defaultRadioStation = nil
        }

        // Alarm volume: default value is install-date-gated via AppDefaults so that
        // changing the shipped default for new users never overrides what existing
        // users are currently experiencing. See Documents/21-APP-DEFAULTS.md.
        self.alarmVolumeLevel = UserDefaults.standard.object(forKey: "alarmVolumeLevel") != nil
            ? UserDefaults.standard.double(forKey: "alarmVolumeLevel")
            : AppDefaults.alarmVolumeLevel
        
        // Media alert volume: default to 0.75 (75%) if not set
        self.mediaAlertVolume = UserDefaults.standard.object(forKey: "mediaAlertVolume") != nil
            ? UserDefaults.standard.double(forKey: "mediaAlertVolume") : 0.75
        
        // Alert default sound: empty string = use global default
        self.alertDefaultSound = UserDefaults.standard.string(forKey: "alertDefaultSound") ?? ""
        
        // Alert vibration: default enabled
        if UserDefaults.standard.object(forKey: "alertVibrationEnabled") != nil {
            self.alertVibrationEnabled = UserDefaults.standard.bool(forKey: "alertVibrationEnabled")
        } else {
            self.alertVibrationEnabled = true
        }
        
        // Alert loop media: default disabled
        self.alertLoopMedia = UserDefaults.standard.bool(forKey: "alertLoopMedia")
        
        // Alert loop delay: default 0 seconds (immediate)
        self.alertLoopDelay = UserDefaults.standard.object(forKey: "alertLoopDelay") != nil
            ? UserDefaults.standard.double(forKey: "alertLoopDelay")
            : 0.0
        
        // App Persistence: the three-way mode is the source of truth. Absent
        // key → .dynamic — this is BOTH the new-install default AND the
        // deliberate migration of every existing user (old On and Off alike)
        // onto Dynamic, decided 2026-07-29 with the hybrid-persistence plan.
        // DynamicModeNotice tells migrated users once. The legacy boolean is
        // realigned below so downgraded builds and old readers stay sane.
        let resolvedMode = UserDefaults.standard.string(forKey: "appPersistenceMode")
            .flatMap(AppPersistenceMode.init(rawValue:)) ?? .dynamic
        self.appPersistenceMode = resolvedMode
        self.backgroundKeepAliveEnabled = resolvedMode != .off
        // Property observers don't run during init — persist the resolved
        // mode and the mirrored legacy key explicitly.
        UserDefaults.standard.set(resolvedMode.rawValue, forKey: "appPersistenceMode")
        UserDefaults.standard.set(resolvedMode != .off, forKey: "backgroundKeepAliveEnabled")

        // NWS weather alerts: initialise from local UserDefaults only (non-blocking).
        // NSUbiquitousKeyValueStore.default blocks the main thread for up to 15 seconds
        // on cold launch while the iCloud daemon initialises — accessing it here was the
        // primary cause of slow app startup. syncNWSSettingsFromiCloud() is called from
        // AppDelegate after init to pull in iCloud values on the background thread.
        self.nwsAlertsEnabled = UserDefaults.standard.bool(forKey: "nwsAlertsEnabled")
        self.nwsMonitoredLocationsData = UserDefaults.standard.data(forKey: "nwsMonitoredLocations") ?? Data()

        // Alarm vibration: default to enabled
        if UserDefaults.standard.object(forKey: "alarmVibrationEnabled") != nil {
            self.alarmVibrationEnabled = UserDefaults.standard.bool(forKey: "alarmVibrationEnabled")
        } else {
            self.alarmVibrationEnabled = true
        }
        
        // Alarm fade-in: default to disabled, default duration 5 minutes
        self.alarmFadeInEnabled = UserDefaults.standard.bool(forKey: "alarmFadeInEnabled")
        let storedFadeInDuration = UserDefaults.standard.integer(forKey: "alarmFadeInDuration")
        self.alarmFadeInDuration = storedFadeInDuration > 0 ? storedFadeInDuration : 5
        
        self.lastSleepSoundName = UserDefaults.standard.string(forKey: "lastSleepSoundName") ?? ""
        self.lastSleepSoundVolume = UserDefaults.standard.object(forKey: "lastSleepSoundVolume") != nil
            ? UserDefaults.standard.double(forKey: "lastSleepSoundVolume")
            : 0.5
        let storedSleepHours = UserDefaults.standard.integer(forKey: "lastSleepHours")
        self.lastSleepHours = storedSleepHours > 0 ? storedSleepHours : 8
        let storedSleepMinutes = UserDefaults.standard.integer(forKey: "lastSleepDurationMinutes")
        self.lastSleepDurationMinutes = storedSleepMinutes > 0
            ? storedSleepMinutes
            : (storedSleepHours > 0 ? storedSleepHours : 8) * 60
        self.lastSleepFadeOutMinutes = UserDefaults.standard.integer(forKey: "lastSleepFadeOutMinutes")
        self.lastSleepUntilNextAlarm = UserDefaults.standard.bool(forKey: "lastSleepUntilNextAlarm")
        self.lastSleepSourceWasRadio = UserDefaults.standard.bool(forKey: "lastSleepSourceWasRadio")
        self.suppressBackgroundRefreshWarning = UserDefaults.standard.bool(forKey: "suppressBackgroundRefreshWarning")
        self.dynamicResidencyWhenArmed = UserDefaults.standard.object(forKey: "dynamicResidencyWhenArmed") != nil
            ? UserDefaults.standard.bool(forKey: "dynamicResidencyWhenArmed") : true
        self.debugForceCloseWarningWhenPersistenceOff = UserDefaults.standard.bool(forKey: "debugForceCloseWarningWhenPersistenceOff")
        self.suppressLocationPermissionNag = UserDefaults.standard.bool(forKey: "suppressLocationPermissionNag")
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        self.analyticsOptIn = UserDefaults.standard.bool(forKey: "analyticsOptIn")
        self.productUpdatesOptIn = UserDefaults.standard.bool(forKey: "productUpdatesOptIn")
        self.hasAnsweredDataPreferences = UserDefaults.standard.bool(forKey: "hasAnsweredDataPreferences")
        self.agreedTermsVersion = UserDefaults.standard.integer(forKey: "agreedTermsVersion")
        self.nwsDisclaimerAgreed = UserDefaults.standard.bool(forKey: "nwsDisclaimerAgreed")
        
        // MQTT per-alarm index counter (starts at 1, never decremented)
        let storedIndex = UserDefaults.standard.integer(forKey: "nextAlarmIndex")
        if storedIndex == 0 {
            self.nextAlarmIndex = 1
            UserDefaults.standard.set(1, forKey: "nextAlarmIndex")
        } else {
            self.nextAlarmIndex = storedIndex
        }
        
        // Appearance settings
        if UserDefaults.standard.object(forKey: "showAlarmNamesOnHome") != nil {
            self.showAlarmNamesOnHome = UserDefaults.standard.bool(forKey: "showAlarmNamesOnHome")
        } else {
            self.showAlarmNamesOnHome = true
        }
        self.biggerAlarmRows = UserDefaults.standard.bool(forKey: "biggerAlarmRows")
        self.notifTickSoundDisabled = UserDefaults.standard.bool(forKey: "notifTickSoundDisabled")
        // App appearance: install-date-gated via AppDefaults.
        // See Documents/21-APP-DEFAULTS.md.
        self.appAppearance = UserDefaults.standard.string(forKey: "appAppearance") ?? AppDefaults.appAppearance
        
        // Per-theme accent overrides. Absent by default — see ThemeAccentStore.
        self.themeAccentOverrides = ThemeAccentStore.load()

        // Home color customization (light)
        if let data = UserDefaults.standard.data(forKey: "homeColorCustomization"),
           let decoded = try? JSONDecoder().decode(HomeColorCustomization.self, from: data) {
            self.homeColorCustomization = decoded
        } else {
            self.homeColorCustomization = .default
        }
        
        // Home color customization (dark)
        if let data = UserDefaults.standard.data(forKey: "homeColorCustomizationDark"),
           let decoded = try? JSONDecoder().decode(HomeColorCustomization.self, from: data) {
            self.homeColorCustomizationDark = decoded
        } else {
            self.homeColorCustomizationDark = .default
        }
        
        // Alarm screen color customization (light)
        if let data = UserDefaults.standard.data(forKey: "alarmColorCustomization"),
           let decoded = try? JSONDecoder().decode(AlarmColorCustomization.self, from: data) {
            self.alarmColorCustomization = decoded
        } else {
            self.alarmColorCustomization = .default
        }
        
        // Alarm screen color customization (dark)
        if let data = UserDefaults.standard.data(forKey: "alarmColorCustomizationDark"),
           let decoded = try? JSONDecoder().decode(AlarmColorCustomization.self, from: data) {
            self.alarmColorCustomizationDark = decoded
        } else {
            self.alarmColorCustomizationDark = .default
        }
        
        self.editDuplicatedAlarms = UserDefaults.standard.object(forKey: "editDuplicatedAlarms") != nil
            ? UserDefaults.standard.bool(forKey: "editDuplicatedAlarms") : true
        self.debugDisableWeatherAPI = UserDefaults.standard.bool(forKey: "debugDisableWeatherAPI")
        self.debugMissionWallpaperEnabled = (UserDefaults.standard.object(forKey: "debugMissionWallpaperEnabled") as? Bool) ?? false
        self.debugAlarmScreenBubbleEnabled = UserDefaults.standard.bool(forKey: "debugAlarmScreenBubbleEnabled")
        self.debugHomeBubblesEnabled = (UserDefaults.standard.object(forKey: "debugHomeBubblesEnabled") as? Bool) ?? true
        self.radioPersistenceNoticeAcknowledged = UserDefaults.standard.bool(forKey: "radioPersistenceNoticeAcknowledged")
        self.debugForceNWSRemovalNotice = UserDefaults.standard.bool(forKey: "debugForceNWSRemovalNotice")
        self.debugSimulateNWSRemoved = UserDefaults.standard.bool(forKey: "debugSimulateNWSRemoved")
        
        // Wallpaper settings
        self.homeWallpaperEnabled = UserDefaults.standard.bool(forKey: "homeWallpaperEnabled")
        self.alarmWallpaperEnabled = UserDefaults.standard.bool(forKey: "alarmWallpaperEnabled")
        
        // Home wallpaper dimming (default 0 — no dimming for home screen)
        self.homeWallpaperDimming = UserDefaults.standard.double(forKey: "homeWallpaperDimming")
        self.homeDarkWallpaperDimming = UserDefaults.standard.double(forKey: "homeDarkWallpaperDimming")
        self.alarmWallpaperDimming = UserDefaults.standard.object(forKey: "alarmWallpaperDimming") != nil
            ? UserDefaults.standard.double(forKey: "alarmWallpaperDimming") : 0.5
        
        // Alarm glass variant (default: 0 = regular)
        self.alarmGlassVariant = UserDefaults.standard.integer(forKey: "alarmGlassVariant")
        self.alarmGlassClearDimming = UserDefaults.standard.object(forKey: "alarmGlassClearDimming") != nil
            ? UserDefaults.standard.double(forKey: "alarmGlassClearDimming") : 0.3
        self.alarmGlassTintRed = UserDefaults.standard.object(forKey: "alarmGlassTintRed") != nil
            ? UserDefaults.standard.double(forKey: "alarmGlassTintRed") : 0.0
        self.alarmGlassTintGreen = UserDefaults.standard.object(forKey: "alarmGlassTintGreen") != nil
            ? UserDefaults.standard.double(forKey: "alarmGlassTintGreen") : 0.48
        self.alarmGlassTintBlue = UserDefaults.standard.object(forKey: "alarmGlassTintBlue") != nil
            ? UserDefaults.standard.double(forKey: "alarmGlassTintBlue") : 1.0
        self.alarmGlassTintOpacity = UserDefaults.standard.object(forKey: "alarmGlassTintOpacity") != nil
            ? UserDefaults.standard.double(forKey: "alarmGlassTintOpacity") : 1.0
        
        // Home glass variant (default: 0 = regular)
        self.homeGlassVariant = UserDefaults.standard.integer(forKey: "homeGlassVariant")
        self.homeGlassClearDimming = UserDefaults.standard.object(forKey: "homeGlassClearDimming") != nil
            ? UserDefaults.standard.double(forKey: "homeGlassClearDimming") : 0.3
        self.homeGlassTintRed = UserDefaults.standard.object(forKey: "homeGlassTintRed") != nil
            ? UserDefaults.standard.double(forKey: "homeGlassTintRed") : 0.0
        self.homeGlassTintGreen = UserDefaults.standard.object(forKey: "homeGlassTintGreen") != nil
            ? UserDefaults.standard.double(forKey: "homeGlassTintGreen") : 0.48
        self.homeGlassTintBlue = UserDefaults.standard.object(forKey: "homeGlassTintBlue") != nil
            ? UserDefaults.standard.double(forKey: "homeGlassTintBlue") : 1.0
        self.homeGlassTintOpacity = UserDefaults.standard.object(forKey: "homeGlassTintOpacity") != nil
            ? UserDefaults.standard.double(forKey: "homeGlassTintOpacity") : 1.0
        
        // Wallpaper position/scale
        self.homeWallpaperScale = UserDefaults.standard.object(forKey: "homeWallpaperScale") != nil
            ? UserDefaults.standard.double(forKey: "homeWallpaperScale") : 1.0
        self.homeWallpaperOffsetX = UserDefaults.standard.double(forKey: "homeWallpaperOffsetX")
        self.homeWallpaperOffsetY = UserDefaults.standard.double(forKey: "homeWallpaperOffsetY")
        self.alarmWallpaperScale = UserDefaults.standard.object(forKey: "alarmWallpaperScale") != nil
            ? UserDefaults.standard.double(forKey: "alarmWallpaperScale") : 1.0
        self.alarmWallpaperOffsetX = UserDefaults.standard.double(forKey: "alarmWallpaperOffsetX")
        self.alarmWallpaperOffsetY = UserDefaults.standard.double(forKey: "alarmWallpaperOffsetY")
        
        // Dark mode alarm wallpaper settings
        self.alarmDarkWallpaperDimming = UserDefaults.standard.object(forKey: "alarmDarkWallpaperDimming") != nil
            ? UserDefaults.standard.double(forKey: "alarmDarkWallpaperDimming") : 0.5
        self.alarmDarkGlassVariant = UserDefaults.standard.integer(forKey: "alarmDarkGlassVariant")
        self.alarmDarkGlassClearDimming = UserDefaults.standard.object(forKey: "alarmDarkGlassClearDimming") != nil
            ? UserDefaults.standard.double(forKey: "alarmDarkGlassClearDimming") : 0.3
        self.alarmDarkGlassTintRed = UserDefaults.standard.object(forKey: "alarmDarkGlassTintRed") != nil
            ? UserDefaults.standard.double(forKey: "alarmDarkGlassTintRed") : 0.0
        self.alarmDarkGlassTintGreen = UserDefaults.standard.object(forKey: "alarmDarkGlassTintGreen") != nil
            ? UserDefaults.standard.double(forKey: "alarmDarkGlassTintGreen") : 0.48
        self.alarmDarkGlassTintBlue = UserDefaults.standard.object(forKey: "alarmDarkGlassTintBlue") != nil
            ? UserDefaults.standard.double(forKey: "alarmDarkGlassTintBlue") : 1.0
        self.alarmDarkGlassTintOpacity = UserDefaults.standard.object(forKey: "alarmDarkGlassTintOpacity") != nil
            ? UserDefaults.standard.double(forKey: "alarmDarkGlassTintOpacity") : 1.0
        self.alarmDarkWallpaperScale = UserDefaults.standard.object(forKey: "alarmDarkWallpaperScale") != nil
            ? UserDefaults.standard.double(forKey: "alarmDarkWallpaperScale") : 1.0
        self.alarmDarkWallpaperOffsetX = UserDefaults.standard.double(forKey: "alarmDarkWallpaperOffsetX")
        self.alarmDarkWallpaperOffsetY = UserDefaults.standard.double(forKey: "alarmDarkWallpaperOffsetY")
        
        // Dark mode home wallpaper settings
        if UserDefaults.standard.object(forKey: "homeWallpaperUseSameForBoth") != nil {
            self.homeWallpaperUseSameForBoth = UserDefaults.standard.bool(forKey: "homeWallpaperUseSameForBoth")
        } else {
            self.homeWallpaperUseSameForBoth = true
        }
        self.homeDarkGlassVariant = UserDefaults.standard.integer(forKey: "homeDarkGlassVariant")
        self.homeDarkGlassClearDimming = UserDefaults.standard.object(forKey: "homeDarkGlassClearDimming") != nil
            ? UserDefaults.standard.double(forKey: "homeDarkGlassClearDimming") : 0.3
        self.homeDarkGlassTintRed = UserDefaults.standard.object(forKey: "homeDarkGlassTintRed") != nil
            ? UserDefaults.standard.double(forKey: "homeDarkGlassTintRed") : 0.0
        self.homeDarkGlassTintGreen = UserDefaults.standard.object(forKey: "homeDarkGlassTintGreen") != nil
            ? UserDefaults.standard.double(forKey: "homeDarkGlassTintGreen") : 0.48
        self.homeDarkGlassTintBlue = UserDefaults.standard.object(forKey: "homeDarkGlassTintBlue") != nil
            ? UserDefaults.standard.double(forKey: "homeDarkGlassTintBlue") : 1.0
        self.homeDarkGlassTintOpacity = UserDefaults.standard.object(forKey: "homeDarkGlassTintOpacity") != nil
            ? UserDefaults.standard.double(forKey: "homeDarkGlassTintOpacity") : 1.0
        self.homeDarkWallpaperScale = UserDefaults.standard.object(forKey: "homeDarkWallpaperScale") != nil
            ? UserDefaults.standard.double(forKey: "homeDarkWallpaperScale") : 1.0
        self.homeDarkWallpaperOffsetX = UserDefaults.standard.double(forKey: "homeDarkWallpaperOffsetX")
        self.homeDarkWallpaperOffsetY = UserDefaults.standard.double(forKey: "homeDarkWallpaperOffsetY")
        
        // Migrate old "home" wallpaper file → "home_light" if needed
        let fm = FileManager.default
        let dir = Self.wallpaperDirectory
        let oldPath = dir.appendingPathComponent("home_wallpaper.jpg")
        let newPath = dir.appendingPathComponent("home_light_wallpaper.jpg")
        if fm.fileExists(atPath: oldPath.path) && !fm.fileExists(atPath: newPath.path) {
            try? fm.copyItem(at: oldPath, to: newPath)
            try? fm.removeItem(at: oldPath)
        }
        
        // Migrate old "alarm" wallpaper file → "alarm_light" if needed
        let oldAlarmPath = dir.appendingPathComponent("alarm_wallpaper.jpg")
        let newAlarmPath = dir.appendingPathComponent("alarm_light_wallpaper.jpg")
        if fm.fileExists(atPath: oldAlarmPath.path) && !fm.fileExists(atPath: newAlarmPath.path) {
            try? fm.copyItem(at: oldAlarmPath, to: newAlarmPath)
            try? fm.removeItem(at: oldAlarmPath)
        }
        
        // Applied preset tracking (for reset-on-delete)
        self.appliedHomePresetID = UserDefaults.standard.string(forKey: "appliedHomePresetID")
        self.appliedAlarmPresetID = UserDefaults.standard.string(forKey: "appliedAlarmPresetID")
        
        // Home Assistant Widget
        self.armButtonEnabled = UserDefaults.standard.bool(forKey: "armButtonEnabled")
        self.hassWidgetAlarmEnabled = UserDefaults.standard.object(forKey: "hassWidgetAlarmEnabled") != nil
            ? UserDefaults.standard.bool(forKey: "hassWidgetAlarmEnabled") : true
        self.armButtonHoldDuration = UserDefaults.standard.object(forKey: "armButtonHoldDuration") != nil
            ? UserDefaults.standard.double(forKey: "armButtonHoldDuration") : 2.0
        self.armZone = UserDefaults.standard.string(forKey: "armZone") ?? "Home"
        self.cachedArmState = UserDefaults.standard.bool(forKey: "cachedArmState")
        self.biggerWidget = UserDefaults.standard.bool(forKey: "biggerWidget")
        // Widget glass variant (light) — default: 0 = regular, mirrors home glass defaults
        self.widgetGlassVariant = UserDefaults.standard.integer(forKey: "widgetGlassVariant")
        self.widgetGlassClearDimming = UserDefaults.standard.object(forKey: "widgetGlassClearDimming") != nil
            ? UserDefaults.standard.double(forKey: "widgetGlassClearDimming") : 0.3
        self.widgetGlassTintRed = UserDefaults.standard.object(forKey: "widgetGlassTintRed") != nil
            ? UserDefaults.standard.double(forKey: "widgetGlassTintRed") : 0.0
        self.widgetGlassTintGreen = UserDefaults.standard.object(forKey: "widgetGlassTintGreen") != nil
            ? UserDefaults.standard.double(forKey: "widgetGlassTintGreen") : 0.48
        self.widgetGlassTintBlue = UserDefaults.standard.object(forKey: "widgetGlassTintBlue") != nil
            ? UserDefaults.standard.double(forKey: "widgetGlassTintBlue") : 1.0
        self.widgetGlassTintOpacity = UserDefaults.standard.object(forKey: "widgetGlassTintOpacity") != nil
            ? UserDefaults.standard.double(forKey: "widgetGlassTintOpacity") : 1.0
        
        // Widget glass variant (dark)
        self.widgetDarkGlassVariant = UserDefaults.standard.integer(forKey: "widgetDarkGlassVariant")
        self.widgetDarkGlassClearDimming = UserDefaults.standard.object(forKey: "widgetDarkGlassClearDimming") != nil
            ? UserDefaults.standard.double(forKey: "widgetDarkGlassClearDimming") : 0.3
        self.widgetDarkGlassTintRed = UserDefaults.standard.object(forKey: "widgetDarkGlassTintRed") != nil
            ? UserDefaults.standard.double(forKey: "widgetDarkGlassTintRed") : 0.0
        self.widgetDarkGlassTintGreen = UserDefaults.standard.object(forKey: "widgetDarkGlassTintGreen") != nil
            ? UserDefaults.standard.double(forKey: "widgetDarkGlassTintGreen") : 0.48
        self.widgetDarkGlassTintBlue = UserDefaults.standard.object(forKey: "widgetDarkGlassTintBlue") != nil
            ? UserDefaults.standard.double(forKey: "widgetDarkGlassTintBlue") : 1.0
        self.widgetDarkGlassTintOpacity = UserDefaults.standard.object(forKey: "widgetDarkGlassTintOpacity") != nil
            ? UserDefaults.standard.double(forKey: "widgetDarkGlassTintOpacity") : 1.0
        
        // MQTT Commands — load or migrate, with Keychain backup for reinstalls
        if let data = UserDefaults.standard.data(forKey: "mqttCommands"),
           let commands = try? JSONDecoder().decode([MQTTCommand].self, from: data) {
            self.mqttCommands = commands
        } else if let data = UserDefaults.standard.data(forKey: "armButtonCommands"),
                  let strings = try? JSONDecoder().decode([String].self, from: data) {
            // Migrate [String] → [MQTTCommand]
            self.mqttCommands = strings.map { MQTTCommand(name: $0) }
            UserDefaults.standard.removeObject(forKey: "armButtonCommands")
        } else if let legacy = UserDefaults.standard.string(forKey: "armButtonCustomCommand"), !legacy.isEmpty {
            // Migrate single string → [MQTTCommand]
            self.mqttCommands = [MQTTCommand(name: legacy)]
            UserDefaults.standard.removeObject(forKey: "armButtonCustomCommand")
        } else if let b64 = KeychainHelper.shared.read(forKey: "kc.mqttCommands"),
                  let data = Data(base64Encoded: b64),
                  let commands = try? JSONDecoder().decode([MQTTCommand].self, from: data) {
            // Restore from Keychain after reinstall
            self.mqttCommands = commands
        } else {
            self.mqttCommands = []
        }
        
        // Widget swipe command assignments
        if let leftStr = UserDefaults.standard.string(forKey: "widgetSwipeLeftCommandID") {
            self.widgetSwipeLeftCommandID = UUID(uuidString: leftStr)
        }
        if let rightStr = UserDefaults.standard.string(forKey: "widgetSwipeRightCommandID") {
            self.widgetSwipeRightCommandID = UUID(uuidString: rightStr)
        }
        if let doubleTapStr = UserDefaults.standard.string(forKey: "widgetDoubleTapCommandID") {
            self.widgetDoubleTapCommandID = UUID(uuidString: doubleTapStr)
        }
        self.confirmCommandsEnabled = UserDefaults.standard.bool(forKey: "confirmCommandsEnabled")
        
        // Debug settings
        self.debugQuickAlarmEnabled = UserDefaults.standard.bool(forKey: "debugQuickAlarmEnabled")
        self.debugQuickAlarmDelay = UserDefaults.standard.integer(forKey: "debugQuickAlarmDelay") != 0
            ? UserDefaults.standard.integer(forKey: "debugQuickAlarmDelay") : 10
        self.debugQuickSnoozeEnabled = UserDefaults.standard.bool(forKey: "debugQuickSnoozeEnabled")
        self.debugQuickSnoozeDelay = UserDefaults.standard.integer(forKey: "debugQuickSnoozeDelay") != 0
            ? UserDefaults.standard.integer(forKey: "debugQuickSnoozeDelay") : 30
        
    }
    
    // MARK: - iCloud stubs (sync removed)

    func pushToiCloud(key: String, value: Any?) { }
    func pushAlliCloudKeys() { }

    /// Save a value to UserDefaults.
    private func saveAndSync(_ value: Any, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
    
}

// MARK: - Notification Names

extension Notification.Name {
}

// MARK: - UIImage Resize Helper

extension UIImage {
    func resizedToFit(maxDimension: CGFloat) -> UIImage {
        guard size.width > 0, size.height > 0, maxDimension > 0 else { return self }
        let ratio = max(size.width, size.height) / maxDimension
        guard ratio > 1 else { return self }
        let newSize = CGSize(width: size.width / ratio, height: size.height / ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
