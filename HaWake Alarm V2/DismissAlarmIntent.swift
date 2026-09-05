//
//  DismissAlarmIntent.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import Foundation
import AppIntents
import SwiftData
import AlarmKit
import AVFoundation


/// Stores pending alarm data so the app can show the mission when it opens
/// Uses UserDefaults for persistence (survives app termination)
/// Also holds in-memory pending alarm info for lock screen → unlock transitions
class PendingAlarmStore {
    static let shared = PendingAlarmStore()
    
    private let userDefaults = UserDefaults.standard
    private let pendingAlarmKey = "HaWakeAlarm.pendingAlarmID"
    
    // MARK: - In-memory pending alarm for lock screen transitions
    // (UIApplication.shared.delegate cannot be cast to AppDelegate when using @UIApplicationDelegateAdaptor,
    //  so we store pending alarm state here where both AppDelegate and AlarmWindowManager can access it)

    struct PendingAlarmInfo {
        let alarmID: Int
        let label: String
        let missionType: MissionType
        let soundID: String
        let volumeLevel: Double?  // Per-alarm volume override (nil = use global default)
    }

    /// The most recently pending alarm (used for lock-screen → unlock transition).
    /// When multiple alarms fire while locked, the AlarmWindowManager queue handles
    /// overflow — this stores the latest one for `checkAndShowPendingAlarm()`.
    var pendingAlarm: PendingAlarmInfo?
    
    // MARK: - UserDefaults-based pending alarm (for intent/app termination scenarios)
    
    private let pendingLabelKey = "HaWakeAlarm.pendingAlarmLabel"
    private let pendingMissionKey = "HaWakeAlarm.pendingAlarmMission"
    private let pendingSoundKey = "HaWakeAlarm.pendingAlarmSound"
    private let pendingVolumeKey = "HaWakeAlarm.pendingAlarmVolume"
    
    /// Store a pending alarm ID (called from intent BEFORE app opens)
    func setPendingAlarm(_ alarmID: Int) {
        userDefaults.set(alarmID, forKey: pendingAlarmKey)
        userDefaults.synchronize()
        print("PendingAlarmStore: Stored pending alarm ID: \(alarmID)")
    }
    
    /// Store full alarm info for the AlarmKit → app handoff
    func setPendingAlarmFull(alarmID: Int, label: String, missionType: String, soundID: String, volumeLevel: Double?) {
        userDefaults.set(alarmID, forKey: pendingAlarmKey)
        userDefaults.set(label, forKey: pendingLabelKey)
        userDefaults.set(missionType, forKey: pendingMissionKey)
        userDefaults.set(soundID, forKey: pendingSoundKey)
        if let vol = volumeLevel {
            userDefaults.set(vol, forKey: pendingVolumeKey)
        } else {
            userDefaults.removeObject(forKey: pendingVolumeKey)
        }
        userDefaults.synchronize()
        print("PendingAlarmStore: Stored full pending alarm: \(label), mission: \(missionType)")
    }
    
    /// Get and clear the pending alarm (called when app activates)
    @discardableResult
    func consumePendingAlarm() -> PendingAlarmInfo? {
        guard let alarmID = userDefaults.object(forKey: pendingAlarmKey) as? Int else {
            return nil
        }
        
        let label = userDefaults.string(forKey: pendingLabelKey) ?? "Alarm"
        let missionRaw = userDefaults.string(forKey: pendingMissionKey) ?? "None"
        let soundID = userDefaults.string(forKey: pendingSoundKey) ?? "Alarm_Clock"
        let volume: Double? = userDefaults.object(forKey: pendingVolumeKey) as? Double
        let missionType = MissionType(rawValue: missionRaw) ?? .none
        
        // Clear all keys
        userDefaults.removeObject(forKey: pendingAlarmKey)
        userDefaults.removeObject(forKey: pendingLabelKey)
        userDefaults.removeObject(forKey: pendingMissionKey)
        userDefaults.removeObject(forKey: pendingSoundKey)
        userDefaults.removeObject(forKey: pendingVolumeKey)
        userDefaults.synchronize()
        
        let info = PendingAlarmInfo(
            alarmID: alarmID,
            label: label,
            missionType: missionType,
            soundID: soundID,
            volumeLevel: volume
        )
        print("PendingAlarmStore: Consumed pending alarm: \(label), mission: \(missionRaw)")
        return info
    }
    
    /// Check if there's a pending alarm without consuming it
    func hasPendingAlarm() -> Bool {
        return userDefaults.object(forKey: pendingAlarmKey) != nil
    }
    
    /// Clear the persisted pending alarm keys without returning data.
    /// Called when the alarm is dismissed or snoozed so a force-close + reopen
    /// doesn't re-trigger the alarm after it was already resolved.
    func clearPersistedPendingAlarm() {
        userDefaults.removeObject(forKey: pendingAlarmKey)
        userDefaults.removeObject(forKey: pendingLabelKey)
        userDefaults.removeObject(forKey: pendingMissionKey)
        userDefaults.removeObject(forKey: pendingSoundKey)
        userDefaults.removeObject(forKey: pendingVolumeKey)
        userDefaults.synchronize()
    }

    /// Clear the persisted pending alarm ONLY when it is the alarm named.
    ///
    /// The unguarded version above is a blunt instrument: the pending keys are
    /// the recovery signal for whatever alarm is currently pending, which may be
    /// a real, ringing, snoozed-and-about-to-re-fire alarm. Anything acting on a
    /// stale MQTT alert notification must not be able to wipe that, so it goes
    /// through here instead.
    func clearPersistedPendingAlarm(ifAlarmID alarmID: Int) {
        guard let pendingID = userDefaults.object(forKey: pendingAlarmKey) as? Int,
              pendingID == alarmID else { return }
        clearPersistedPendingAlarm()
    }
    
    // MARK: - Active Ringing Alarm (independent recovery key)
    // This key is set whenever the alarm screen is presented and is ONLY
    // cleared on explicit dismiss or snooze. Unlike the pending alarm keys
    // (which are consumed by checkAndShowPendingAlarm), this key persists
    // through multiple force-close cycles.

    private let activeRingingAlarmKey = "HaWakeAlarm.activeRingingAlarmID"

    /// Mark an alarm as actively ringing (set in presentAlarmWindow).
    func setActiveRingingAlarm(_ alarmID: Int) {
        userDefaults.set(alarmID, forKey: activeRingingAlarmKey)
        userDefaults.synchronize()
        print("[ALARM-STATE] PendingAlarmStore: set activeRingingAlarm=\(alarmID)")
    }

    /// Clear the active ringing alarm (called on dismiss or snooze only).
    func clearActiveRingingAlarm() {
        userDefaults.removeObject(forKey: activeRingingAlarmKey)
        userDefaults.synchronize()
        print("[ALARM-STATE] PendingAlarmStore: cleared activeRingingAlarm")
    }

    /// Get the active ringing alarm ID, or nil if no alarm is ringing.
    func activeRingingAlarmID() -> Int? {
        guard userDefaults.object(forKey: activeRingingAlarmKey) != nil else { return nil }
        let value = userDefaults.integer(forKey: activeRingingAlarmKey)
        return value != 0 ? value : nil
    }

    // MARK: - Pre-stored alarm info (set at schedule time, used by intent)

    private let storedInfoPrefix = "HaWakeAlarm.storedInfo."
    
    /// Store comprehensive alarm data at schedule time for instant cold-start display.
    /// Includes the full Mission JSON blob and all per-alarm overrides that ActiveAlarmView
    /// needs, so the alarm screen can be shown without waiting for SwiftData.
    func storeFullAlarmInfo(alarmID: Int, alarm: Alarm) {
        let key = "\(storedInfoPrefix)\(alarmID)"
        var info: [String: Any] = [
            // Backward-compatible with retrieveAlarmInfo()
            "label": alarm.label,
            "missionType": alarm.mission.type.rawValue,
            "soundID": alarm.soundName,
            // Full mission data (JSON blob)
            "missionData": alarm.missionData.base64EncodedString(),
            // Snooze config
            "snoozeDuration": alarm.snoozeDuration,
            "snoozeCount": alarm.snoozeCount,
            // MQTT
            "alarmIndex": alarm.alarmIndex,
            // Ephemeral (quick alarm) — must persist so reconstructed alarms can be deleted
            "isEphemeral": alarm.isEphemeral
        ]
        // Optional per-alarm overrides (nil = use global defaults)
        if let vol = alarm.customVolumeLevel { info["volumeLevel"] = vol }
        if let maxSnooze = alarm.maxSnoozeCount { info["maxSnoozeCount"] = maxSnooze }
        if let holdDur = alarm.customSnoozeHoldDuration { info["customSnoozeHoldDuration"] = holdDur }
        if let snoozeMode = alarm.snoozeModeRaw { info["snoozeModeRaw"] = snoozeMode }
        if let gracePeriod = alarm.customGracePeriod { info["customGracePeriod"] = gracePeriod }
        if let vibration = alarm.customVibrationEnabled { info["customVibrationEnabled"] = vibration }
        if let fadeIn = alarm.customFadeInEnabled { info["customFadeInEnabled"] = fadeIn }
        if let fadeInDur = alarm.customFadeInDuration { info["customFadeInDuration"] = fadeInDur }
        // Slots 2..5 of a multi-mission sequence, so a cold-start reconstruction
        // shows the WHOLE sequence. NO progress is stored — reconstruction always
        // restarts at slot 0 (force-kill may demand more work, never less).
        if let extra = alarm.extraMissionsData { info["extraMissionsData"] = extra.base64EncodedString() }

        userDefaults.set(info, forKey: key)
        userDefaults.synchronize()
        print("📦 storeFullAlarmInfo: cached alarm '\(alarm.label)' (id=\(alarmID))")
    }
    
    /// Update the cached snooze count for an alarm so that reconstructAlarm()
    /// returns the correct count after a force-kill recovery.
    /// Called when scheduling the snooze failsafe (after the user snoozes).
    func updateStoredSnoozeCount(alarmID: Int, snoozeCount: Int) {
        let key = "\(storedInfoPrefix)\(alarmID)"
        guard var info = userDefaults.dictionary(forKey: key) else {
            print("⚠️ updateStoredSnoozeCount: no cached info for alarm \(alarmID)")
            return
        }
        info["snoozeCount"] = snoozeCount
        userDefaults.set(info, forKey: key)
        userDefaults.synchronize()
        print("📦 updateStoredSnoozeCount: alarm \(alarmID) → snoozeCount=\(snoozeCount)")
    }
    
    /// Reconstruct a synthetic Alarm from cached data for instant cold-start display.
    /// Returns nil if cache is missing or corrupt.
    func reconstructAlarm(alarmID: Int) -> Alarm? {
        let key = "\(storedInfoPrefix)\(alarmID)"
        guard let info = userDefaults.dictionary(forKey: key),
              let label = info["label"] as? String,
              let soundID = info["soundID"] as? String,
              let missionDataB64 = info["missionData"] as? String,
              let missionData = Data(base64Encoded: missionDataB64) else {
            return nil
        }
        
        let snoozeDuration = info["snoozeDuration"] as? Int ?? 9
        let snoozeCount = info["snoozeCount"] as? Int ?? 0
        
        // Create a transient Alarm (not inserted into any ModelContext)
        let alarm = Alarm(
            label: label,
            soundName: soundID,
            snoozeDuration: snoozeDuration,
            snoozeCount: snoozeCount,
            maxSnoozeCount: info["maxSnoozeCount"] as? Int,
            customSnoozeHoldDuration: info["customSnoozeHoldDuration"] as? Double,
            snoozeModeRaw: info["snoozeModeRaw"] as? String
        )
        // Set mission data directly (the computed `mission` property decodes it)
        alarm.missionData = missionData
        // Restore the full multi-mission sequence (slots 2..5). Progress is never
        // cached, so the reconstructed alarm always starts at slot 0.
        if let extraB64 = info["extraMissionsData"] as? String,
           let extraData = Data(base64Encoded: extraB64) {
            alarm.extraMissionsData = extraData
        }
        // Per-alarm overrides
        alarm.customVolumeLevel = info["volumeLevel"] as? Double
        alarm.customGracePeriod = info["customGracePeriod"] as? Double
        alarm.customVibrationEnabled = info["customVibrationEnabled"] as? Bool
        alarm.customFadeInEnabled = info["customFadeInEnabled"] as? Bool
        alarm.customFadeInDuration = info["customFadeInDuration"] as? Int
        alarm.alarmIndex = info["alarmIndex"] as? Int ?? 0
        alarm.isEphemeral = info["isEphemeral"] as? Bool ?? false

        print("📦 reconstructAlarm: rebuilt alarm '\(label)' from cache (id=\(alarmID))")
        return alarm
    }
    
    /// Retrieve pre-stored alarm info
    func retrieveAlarmInfo(alarmID: Int) -> (label: String, missionType: String, soundID: String, volumeLevel: Double?)? {
        let key = "\(storedInfoPrefix)\(alarmID)"
        guard let info = userDefaults.dictionary(forKey: key) else { return nil }
        guard let label = info["label"] as? String,
              let missionType = info["missionType"] as? String,
              let soundID = info["soundID"] as? String else { return nil }
        let volumeLevel = info["volumeLevel"] as? Double
        return (label, missionType, soundID, volumeLevel)
    }
    
    // MARK: - Alert Info (for MQTT alert mission type)
    
    private let alertInfoPrefix = "HaWakeAlarm.alert."
    
    /// Store alert-specific info (title + message) for a transient alert alarm
    func storeAlertInfo(alarmID: Int, title: String, message: String) {
        userDefaults.set(title, forKey: "\(alertInfoPrefix)\(alarmID).title")
        userDefaults.set(message, forKey: "\(alertInfoPrefix)\(alarmID).message")
        userDefaults.synchronize()
    }
    
    /// Retrieve alert-specific info
    func retrieveAlertInfo(alarmID: Int) -> (title: String, message: String)? {
        guard let title = userDefaults.string(forKey: "\(alertInfoPrefix)\(alarmID).title"),
              let message = userDefaults.string(forKey: "\(alertInfoPrefix)\(alarmID).message") else {
            return nil
        }
        return (title, message)
    }
    
    /// Clear alert-specific info
    func clearAlertInfo(alarmID: Int) {
        userDefaults.removeObject(forKey: "\(alertInfoPrefix)\(alarmID).title")
        userDefaults.removeObject(forKey: "\(alertInfoPrefix)\(alarmID).message")
        userDefaults.synchronize()
    }

    // MARK: - Alert Delivery Record (identity + notification, for dedupe)

    private let alertDeliveryPrefix = "HaWakeAlarm.alertDelivery."

    /// Record how an inbound alert was identified and which local notification
    /// is carrying it. Read on dismissal so the alert can be marked resolved in
    /// `AlertDeliveryLedger` and its notification pulled out of Notification
    /// Center. Absence is not an error — an alert delivered by an older build
    /// simply has its identity re-derived from title + message.
    func storeAlertDelivery(alarmID: Int, identity: String, notificationID: String, sentAt: Date) {
        userDefaults.set(
            [
                "identity": identity,
                "notificationID": notificationID,
                "sentAt": sentAt.timeIntervalSince1970
            ] as [String: Any],
            forKey: "\(alertDeliveryPrefix)\(alarmID)"
        )
        userDefaults.synchronize()
    }

    func retrieveAlertDelivery(alarmID: Int) -> (identity: String, notificationID: String, sentAt: Date)? {
        guard let info = userDefaults.dictionary(forKey: "\(alertDeliveryPrefix)\(alarmID)"),
              let identity = info["identity"] as? String,
              let notificationID = info["notificationID"] as? String else {
            return nil
        }
        let sentAt = (info["sentAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        return (identity, notificationID, sentAt)
    }

    func clearAlertDelivery(alarmID: Int) {
        userDefaults.removeObject(forKey: "\(alertDeliveryPrefix)\(alarmID)")
        userDefaults.synchronize()
    }
    
    // MARK: - Alert Media Info (for rich media alerts)
    
    private let alertMediaPrefix = "HaWakeAlarm.alertMedia."
    
    /// Store rich media URLs for an alert alarm
    func storeAlertMediaInfo(alarmID: Int, mediaURL: String?, imageURL: String?, videoURL: String?, linkURL: String?, playSound: Bool) {
        var info: [String: Any] = ["playSound": playSound]
        if let mediaURL { info["mediaURL"] = mediaURL }
        if let imageURL { info["imageURL"] = imageURL }
        if let videoURL { info["videoURL"] = videoURL }
        if let linkURL { info["linkURL"] = linkURL }
        userDefaults.set(info, forKey: "\(alertMediaPrefix)\(alarmID)")
        userDefaults.synchronize()
    }
    
    /// Retrieve rich media URLs for an alert alarm
    func retrieveAlertMediaInfo(alarmID: Int) -> (mediaURL: String?, imageURL: String?, videoURL: String?, linkURL: String?, playSound: Bool)? {
        guard let info = userDefaults.dictionary(forKey: "\(alertMediaPrefix)\(alarmID)") else { return nil }
        return (
            mediaURL: info["mediaURL"] as? String,
            imageURL: info["imageURL"] as? String,
            videoURL: info["videoURL"] as? String,
            linkURL: info["linkURL"] as? String,
            playSound: info["playSound"] as? Bool ?? true
        )
    }
    
    /// Clear rich media info for an alert alarm
    func clearAlertMediaInfo(alarmID: Int) {
        userDefaults.removeObject(forKey: "\(alertMediaPrefix)\(alarmID)")
        userDefaults.synchronize()
    }

}

/// Intent that runs when user interacts with the AlarmKit system alarm UI.
///
/// Used as both stopIntent (X button) and secondaryIntent ("Open App" button).
///
/// For the X/Stop button: The system automatically stops the alarm. This intent
/// runs as an ADDITIONAL action. It stores the pending alarm so the app can show
/// the mission screen when opened.
///
/// For the "Open App" button (.custom behavior): The system displays an "Open"
/// action that launches the app. This intent runs when that button is tapped,
/// ensuring the pending alarm is ready for display.
///
/// Note: handleAlarmAlerting() in AlarmKitScheduler already stores the pending
/// alarm via the alarmUpdates observer when the alarm first enters .alerting
/// state. This intent provides a redundant storage path to handle edge cases
/// where the observer hasn't fired yet (e.g., very fast tap on cold launch).
struct CompleteMissionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Complete Mission"
    static var description: LocalizedStringResource = "Complete the mission to dismiss alarm"
    
    // MUST be foreground-only. If .background is included, the system may choose
    // to run the intent in the background instead of opening the app — which defeats
    // the purpose. The working version used .foreground(.immediate) exclusively.
    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }
    
    @Parameter(title: "Alarm ID")
    var alarmID: Int
    
    @Parameter(title: "Alarm UUID")
    var alarmUUID: String
    
    init() {
        self.alarmID = 0
        self.alarmUUID = ""
    }
    
    init(alarmID: Int, alarmUUID: UUID) {
        self.alarmID = alarmID
        self.alarmUUID = alarmUUID.uuidString
    }
    
    @MainActor
    func perform() async throws -> some IntentResult {
        // Live Activity / Dynamic Island button. The intent name is OUR
        // vocabulary, so it is safe to log — unlike a user-authored
        // Shortcuts name, which never leaves the device.
        Task { @MainActor in Analytics.shared.log(.appIntentInvoked(intentName: "complete_mission")) }

        print("[ALARM-STATE] ━━━ CompleteMissionIntent.perform() ━━━")
        print("[ALARM-STATE] CompleteMissionIntent: alarmID=\(alarmID), alarmUUID=\(alarmUUID)")
        AppLogger.shared.log("CompleteMissionIntent: alarmID=\(alarmID)", category: .alarm)
        print("[ALARM-STATE] CompleteMissionIntent: isShowingAlarm=\(AlarmWindowManager.shared.isShowingAlarm), isPlaying=\(AlarmSoundPlayer.shared.isPlaying)")

        // STEP 1: Store pending alarm in UserDefaults FIRST.
        let store = PendingAlarmStore.shared
        let info = store.retrieveAlarmInfo(alarmID: alarmID)
        if let info {
            store.setPendingAlarmFull(
                alarmID: alarmID,
                label: info.label,
                missionType: info.missionType,
                soundID: info.soundID,
                volumeLevel: info.volumeLevel
            )
            store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                alarmID: alarmID,
                label: info.label,
                missionType: MissionType(rawValue: info.missionType) ?? .none,
                soundID: info.soundID,
                volumeLevel: info.volumeLevel
            )
            print("[ALARM-STATE] CompleteMissionIntent: stored pending alarm: \(info.label), mission=\(info.missionType), sound=\(info.soundID)")
        } else {
            store.setPendingAlarm(alarmID)
            print("[ALARM-STATE] CompleteMissionIntent: ⚠️ no pre-stored info, stored ID only: \(alarmID)")
        }

        // STEP 2: Stop alarm notifications
        print("[ALARM-STATE] CompleteMissionIntent: stopping alarm notifications")
        AlarmLiveActivityManager.shared.stopAlarmNotifications()

        // STEP 4: Stop the AlarmKit alarm.
        if let uuid = UUID(uuidString: alarmUUID) {
            do {
                // cancel() works on any alarm state; stop() only on .alerting.
                // Using cancel() is safer against state races.
                try AlarmManager.shared.cancel(id: uuid)
                print("[ALARM-STATE] CompleteMissionIntent: ✅ cancelled AlarmKit alarm uuid=\(uuid)")
            } catch {
                print("[ALARM-STATE] CompleteMissionIntent: ❌ failed to cancel alarm: \(error)")
            }
        } else {
            print("[ALARM-STATE] CompleteMissionIntent: ⚠️ invalid UUID string: \(alarmUUID)")
        }

        print("[ALARM-STATE] CompleteMissionIntent: complete, app will open via .foreground(.immediate)")
        return .result()
    }
}

/// Intent for the stop/X button on the AlarmKit system alarm UI.
///
/// Opens the app so the in-app alarm UI takes over. This prevents users from
/// silencing the alarm without engaging with the app (completing a mission,
/// snoozing, etc.). The system stops the AlarmKit alarm automatically; this
/// intent handles the handoff to the in-app experience.
struct DefaultStopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Alarm"

    // MUST be foreground-only. Opening the app is the penalty — the user cannot
    // dismiss an AlarmKit alarm without being forced into the app.
    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }

    @Parameter(title: "Alarm ID")
    var alarmID: Int

    @Parameter(title: "Alarm UUID")
    var alarmUUID: String

    init() {
        self.alarmID = 0
        self.alarmUUID = ""
    }

    init(alarmID: Int, alarmUUID: UUID) {
        self.alarmID = alarmID
        self.alarmUUID = alarmUUID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Live Activity / Dynamic Island button. The intent name is OUR
        // vocabulary, so it is safe to log — unlike a user-authored
        // Shortcuts name, which never leaves the device.
        Task { @MainActor in Analytics.shared.log(.appIntentInvoked(intentName: "default_stop")) }

        print("[ALARM-STATE] ━━━ DefaultStopIntent.perform() ━━━")
        print("[ALARM-STATE] DefaultStopIntent: alarmID=\(alarmID), alarmUUID=\(alarmUUID)")
        AppLogger.shared.log("DefaultStopIntent: alarmID=\(alarmID)", category: .alarm)
        print("[ALARM-STATE] DefaultStopIntent: isShowingAlarm=\(AlarmWindowManager.shared.isShowingAlarm), isPlaying=\(AlarmSoundPlayer.shared.isPlaying)")

        // STEP 1: Store pending alarm so the app shows the alarm UI when it opens.
        let store = PendingAlarmStore.shared
        let info = store.retrieveAlarmInfo(alarmID: alarmID)
        if let info {
            store.setPendingAlarmFull(
                alarmID: alarmID,
                label: info.label,
                missionType: info.missionType,
                soundID: info.soundID,
                volumeLevel: info.volumeLevel
            )
            store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                alarmID: alarmID,
                label: info.label,
                missionType: MissionType(rawValue: info.missionType) ?? .none,
                soundID: info.soundID,
                volumeLevel: info.volumeLevel
            )
            print("[ALARM-STATE] DefaultStopIntent: stored pending alarm: \(info.label), mission=\(info.missionType), sound=\(info.soundID)")
        } else {
            store.setPendingAlarm(alarmID)
            print("[ALARM-STATE] DefaultStopIntent: ⚠️ no pre-stored info, stored ID only: \(alarmID)")
        }

        // STEP 2: Stop alarm notifications
        AlarmLiveActivityManager.shared.stopAlarmNotifications()
        print("[ALARM-STATE] DefaultStopIntent: stopped alarm notifications")

        // STEP 4: Stop the AlarmKit alarm.
        if let uuid = UUID(uuidString: alarmUUID) {
            do {
                try AlarmManager.shared.cancel(id: uuid)
                print("[ALARM-STATE] DefaultStopIntent: ✅ cancelled AlarmKit alarm uuid=\(uuid)")
            } catch {
                print("[ALARM-STATE] DefaultStopIntent: ❌ failed to cancel: \(error)")
            }
        } else {
            print("[ALARM-STATE] DefaultStopIntent: ⚠️ invalid UUID string: \(alarmUUID)")
        }

        print("[ALARM-STATE] DefaultStopIntent: complete, app will open via .foreground(.immediate)")
        return .result()
    }
}


