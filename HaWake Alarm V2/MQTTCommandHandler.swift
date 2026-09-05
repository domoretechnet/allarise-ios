//
//  MQTTCommandHandler.swift
//  HaWake Alarm V2
//
//  Handles inbound MQTT commands from Home Assistant:
//  - Security alerts (immediate full-screen alarm)
//  - Dismiss/snooze active alarms
//

import Foundation
import AVFoundation
import UIKit
import UserNotifications
import SwiftData

@MainActor
final class MQTTCommandHandler {
    static let shared = MQTTCommandHandler()
    
    /// Timestamp of the most recent SwiftData alarm deletion.
    /// The iCloud reconciliation handler checks this to avoid accessing
    /// stale/detached alarm objects whose backing data has been invalidated.
    private(set) var lastDeleteTimestamp: Date = .distantPast
    
    /// Synchronous suppression flag — set to `true` BEFORE `context.delete()`
    /// and cleared after a delay. While true, ALL code that iterates alarm
    /// objects and accesses lazy properties (recurringDays, etc.) MUST bail out.
    ///
    /// This flag is checked synchronously (no async) so it catches SwiftUI's
    /// `.onChange(of: alarms)` which fires on the same run-loop turn as the
    /// save that triggered the persistent-store merge.
    private(set) var isSuppressingAlarmAccess: Bool = false
    
    private init() {}
    
    /// Normalize a volume value from MQTT.
    /// HACS services send 0–100 (int), but the iOS app uses 0.0–1.0.
    /// Values > 1.0 are treated as percentages and divided by 100.
    /// `internal` rather than `private` so the MQTT payload tests can exercise
    /// the translation directly. Pure — no side effects, no persistence.
    func normalizeVolume(_ raw: Double) -> Double {
        let v = raw > 1.0 ? raw / 100.0 : raw
        return min(max(v, 0.0), 1.0)
    }

    /// Accepted range for `snooze_duration`, matching the editor's stepper
    /// (`SnoozeSectionView.swift`, `in: 1...30`).
    static let snoozeDurationRange = 1...30
    /// Accepted range for `max_snooze_count`, matching the editor's stepper
    /// (`SnoozeSectionView.swift`, `in: 0...20`). 0 keeps its "unlimited" meaning —
    /// `LocalNotificationScheduler` reads `maxSnoozes == 0 ? Int.max : …`.
    static let maxSnoozeCountRange = 0...20

    /// Read an integer field from an MQTT payload and clamp it into `range`.
    ///
    /// Clamp-and-warn, never reject: an automation written against an older app
    /// keeps working verbatim, and an out-of-range value is named in the log
    /// rather than silently applied. Unclamped these fields are dangerous —
    /// `snoozeDuration * 60` is Int arithmetic and traps on a huge value, and a
    /// negative duration schedules the re-wake in the past (a silent no-op), while
    /// a negative `max_snooze_count` resolves to zero remaining snoozes.
    ///
    /// Returns nil when the key is absent so the caller's default is preserved.
    /// `internal` so the payload tests can exercise it directly. Pure apart from logging.
    static func clampedInt(_ payload: [String: Any], key: String, range: ClosedRange<Int>) -> Int? {
        guard let number = payload[key] as? NSNumber else { return nil }
        // Via Double so a value beyond Int's range is bounded before conversion.
        let raw = number.doubleValue
        let clamped = Int(min(max(raw, Double(range.lowerBound)), Double(range.upperBound)))
        if Double(clamped) != raw {
            print("⚠️ MQTT \(key)=\(number) outside \(range.lowerBound)…\(range.upperBound) — clamped to \(clamped)")
            AppLogger.shared.log("MQTT \(key)=\(number) outside \(range.lowerBound)…\(range.upperBound), clamped to \(clamped)", category: .mqtt)
        }
        return clamped
    }

    /// Ceiling on how many alarms `create_alarm` will ever have inserted
    /// (`source == "mqtt"`). iOS's own scheduling budget is roughly 64 pending
    /// alarms/notifications and the app has to leave room for the ones the user
    /// created by hand, plus their snooze failsafes — so MQTT gets a clear
    /// majority of it and no more. Hand-made alarms are NOT counted and are never
    /// refused; nothing existing is deleted when the cap is hit.
    static let maxMQTTCreatedAlarms = 50

    /// Accepted range for `snooze_hold_duration` / `skip_hold_duration` in
    /// seconds, matching every hold-duration slider in the editor and Settings
    /// (`SnoozeSectionView.swift`, `SkipAlarmSectionView.swift`, …: `0.5...30`).
    static let holdDurationRange: ClosedRange<Double> = 0.5...30

    /// `clampedInt`'s Double sibling, for the hold durations. These were
    /// lower-bounded at 0.5 with NO upper bound, so a payload could ask the user
    /// to hold the button for an hour — unreachable, and indistinguishable from
    /// a broken control.
    ///
    /// Returns nil when the key is absent so the caller's default is preserved.
    static func clampedDouble(_ payload: [String: Any], key: String, range: ClosedRange<Double>) -> Double? {
        guard let number = payload[key] as? NSNumber else { return nil }
        let raw = number.doubleValue
        // NaN would slip through min/max unchanged; treat it as "not supplied".
        guard raw.isFinite else {
            print("⚠️ MQTT \(key)=\(number) is not a finite number — ignored")
            AppLogger.shared.log("MQTT \(key)=\(number) is not a finite number, ignored", category: .mqtt)
            return nil
        }
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        if clamped != raw {
            print("⚠️ MQTT \(key)=\(number) outside \(range.lowerBound)…\(range.upperBound) — clamped to \(clamped)")
            AppLogger.shared.log("MQTT \(key)=\(number) outside \(range.lowerBound)…\(range.upperBound), clamped to \(clamped)", category: .mqtt)
        }
        return clamped
    }

    /// Parse the `days` array permissively, element by element.
    ///
    /// The previous `payload["days"] as? [Int]` was all-or-nothing: a mixed array
    /// such as `[1, 2, "3"]` — trivially produced by HA/YAML templating — failed the
    /// whole cast, leaving `recurringDays` empty and silently degrading a recurring
    /// alarm to one-shot (the `al-d44` failure mode). Numbers and numeric strings are
    /// both accepted; the existing 1–7 range filter is unchanged.
    ///
    /// Returns nil when the key is absent or is not an array, so callers can tell
    /// "no days sent" from "days sent, none valid".
    static func parsedDays(from payload: [String: Any]) -> Set<Int>? {
        guard let rawDays = payload["days"] as? [Any] else { return nil }
        let parsed: [Int] = rawDays.compactMap { element in
            if let number = element as? NSNumber { return number.intValue }
            if let string = element as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        if parsed.count != rawDays.count {
            print("⚠️ MQTT days: \(rawDays.count - parsed.count) element(s) were not numeric and were ignored")
        }
        return Set(parsed.filter { $0 >= 1 && $0 <= 7 })
    }

    // MARK: - Security Alert (Alert Mission)
    
    /// Deterministic alarm ID for alert alarms. Uses a hash of the title so
    /// concurrent alerts with different titles get different IDs.
    ///
    /// Uses `AlertIdentity.stableHash` rather than `Swift.Hasher`: `Hasher` is
    /// seeded per process, so the same title produced a DIFFERENT id on every
    /// cold start. That broke every cross-launch use of this id — the
    /// `HaWakeAlarm.alert.<id>.*` blobs written by one run were unreachable from
    /// the next (and never cleaned up), and `AlertContentView`, which recomputes
    /// the id from the label, could not find the media info for an alert
    /// restored from a notification tapped after a relaunch. The value changes
    /// with this build; nothing outside the device ever sees it (alert alarms
    /// publish a nil `active_alarm_index`), and the notification-tap path reads
    /// the id out of `userInfo` rather than recomputing it, so notifications
    /// delivered by an older build keep working.
    static func alertAlarmID(title: String) -> Int {
        return AlertIdentity.stableHash("alert\u{1F}" + title)
    }

    /// Read the optional `alert_id` field. Permissive by design: a string, or a
    /// number an automation template produced, both mean the same thing.
    /// `internal` so the payload tests can exercise it directly.
    static func explicitAlertID(from payload: [String: Any]) -> String? {
        if let string = payload["alert_id"] as? String { return string }
        if let number = payload["alert_id"] as? NSNumber { return number.stringValue }
        return nil
    }
    
    func handleSecurityAlert(payload: [String: Any]) async {
        guard let message = payload["message"] as? String else {
            print("❌ Security alert missing required 'message' field")
            return
        }
        
        let title = payload["title"] as? String ?? "Security Alert"
        // Sound priority: payload field → alertDefaultSound setting → global default sound
        let defaultAlertSoundID = DeviceSettings.shared.alertDefaultSound.isEmpty
            ? AlarmSoundManager.shared.getDefaultSound().id
            : DeviceSettings.shared.alertDefaultSound
        let soundID = payload["sound"] as? String ?? defaultAlertSoundID
        let volumeLevel = (payload["volume"] as? NSNumber).map { normalizeVolume($0.doubleValue) }
        let alarmID = Self.alertAlarmID(title: title)

        // Stable identity for this alert, used to tell a stale notification
        // (one the user already dismissed) from a genuinely new alert that
        // happens to carry the same words. See AlertDeliveryLedger.swift.
        //
        // `alert_id` is OPTIONAL and ADDITIVE: every payload that worked before
        // still works, and an integration that never sends it falls back to the
        // content identity, which is derived from title + message and therefore
        // always available — including from a notification posted by an older
        // build. Accepts a string or a number so `alert_id: 42` is not a silent
        // no-op.
        let explicitIdentity = Self.explicitAlertID(from: payload).flatMap(AlertIdentity.explicit)
        let alertIdentity = explicitIdentity
            ?? AlertIdentity.content(title: title, message: message)
        let sentAt = Date()
        // Re-sending the same `alert_id` replaces the pending notification
        // instead of stacking a second one ("overwrite if pending"). Without an
        // `alert_id`, the id keys on the title, which is the behaviour that has
        // always been in place.
        let notificationID = explicitIdentity != nil
            ? "mqtt-alert-id-\(AlertIdentity.stableHash(alertIdentity))"
            : "mqtt-alert-\(alarmID)"

        // Fade-in: accepts true (default 30s), false/omitted (no fade), or a number of seconds
        let fadeInDuration: TimeInterval?
        if let fadeInNumber = payload["fade_in"] as? NSNumber {
            // Could be a bool (true/false) or a numeric duration
            if fadeInNumber === kCFBooleanTrue {
                fadeInDuration = 30.0
            } else if fadeInNumber === kCFBooleanFalse {
                fadeInDuration = nil
            } else {
                // Numeric value — clamp to reasonable range (5s to 300s)
                let seconds = fadeInNumber.doubleValue
                fadeInDuration = seconds > 0 ? min(max(seconds, 5.0), 300.0) : nil
            }
        } else {
            fadeInDuration = nil
        }
        
        // Rich media fields
        let mediaURL = payload["media_url"] as? String
        let imageURL = payload["image_url"] as? String
        let videoURL = payload["video_url"] as? String
        let linkURL = payload["link_url"] as? String
        // `link_url` is documented as opening in the browser, so only http/https
        // are honoured. A rejected scheme is logged by name and the link button is
        // simply not offered — the rest of the alert still shows.
        if let blockedScheme = AlertLinkPolicy.rejectedScheme(linkURL) {
            AppLogger.shared.log(
                "Alert link_url ignored — scheme '\(blockedScheme)' is not allowed (http/https only)",
                category: .mqtt
            )
        }
        // play_sound defaults to true, but forced false when media_url is present
        let playSound: Bool
        if mediaURL != nil {
            playSound = false
        } else {
            playSound = (payload["play_sound"] as? Bool) ?? true
        }
        
        print("🚨 Alert received: \(title) - \(message) (alarmID=\(alarmID), playSound=\(playSound), hasMedia=\(mediaURL != nil))")
        AppLogger.shared.log("MQTT alert received: \(title) - \(message)", category: .mqtt)
        
        // 1. Store alert info in PendingAlarmStore so the alarm view can read it.
        //    Persist to BOTH in-memory AND UserDefaults so the alarm survives
        //    scenePhase transitions and stale-pending-alarm cleanup.
        let store = PendingAlarmStore.shared
        store.storeAlertInfo(alarmID: alarmID, title: title, message: message)
        // Remember how this alert was identified and which notification carries
        // it, so dismissing it can retire both. Stored for foreground alerts
        // too: a notification from an EARLIER background delivery of the same
        // alert may still be sitting in Notification Center.
        store.storeAlertDelivery(
            alarmID: alarmID,
            identity: alertIdentity,
            notificationID: notificationID,
            sentAt: sentAt
        )
        store.storeAlertMediaInfo(
            alarmID: alarmID,
            mediaURL: mediaURL,
            imageURL: imageURL,
            videoURL: videoURL,
            linkURL: linkURL,
            playSound: playSound
        )
        store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
            alarmID: alarmID,
            label: title,
            missionType: .alert,
            soundID: playSound ? soundID : "silent",
            volumeLevel: volumeLevel
        )
        store.setPendingAlarmFull(
            alarmID: alarmID,
            label: title,
            missionType: MissionType.alert.rawValue,
            soundID: playSound ? soundID : "silent",
            volumeLevel: volumeLevel
        )
        
        let settings = DeviceSettings.shared
        
        // 2. Configure audio session BEFORE playing sound
        if playSound {
            do {
                try AppAudioSession.setCategory(.playAndRecord, mode: .default, options: AppAudioSession.alarmFireCategoryOptions())
                try AppAudioSession.setActive(true)
            } catch {
                print("❌ Failed to configure audio session for alert: \(error)")
            }

            await VolumeManager.shared.ensureReady()
        }
        
        // Media alerts (TTS/media_url) default to mediaAlertVolume;
        // regular alarm alerts default to alarmVolumeLevel.
        let defaultVolume = (mediaURL != nil) ? settings.mediaAlertVolume : settings.alarmVolumeLevel
        let effectiveVolume = min(max(volumeLevel ?? defaultVolume, 0.0), 1.0)
        print("🔊 Alert volume: requested=\(volumeLevel.map { String($0) } ?? "nil"), effective=\(effectiveVolume), fadeIn=\(fadeInDuration.map { "\(Int($0))s" } ?? "off")")
        
        // 3. Unlock the sound player — a new alert is a legitimate alarm trigger
        AlarmSoundPlayer.shared.unlock()
        
        // 4. Set volume and start sound
        if playSound {
            // One path for "instant" and fade alike (al-1hz). The system-volume
            // write goes through a hidden MPVolumeView slider and takes up to
            // ~1s to reach the hardware, so a full-volume start plays at the
            // stale level and then jumps. Waiting for the write BEFORE playback
            // was tried and regressed in the field — the write raced the
            // player's own audio-session activation and sometimes never landed.
            // Instead: start the player first (session fully active), then let
            // fadeInVolume apply the system volume while ramping the player up
            // from silence — whenever the write lands, nothing wrong was
            // audible. An alert without fade_in just uses a ~1s ramp, which
            // reads as instant; a requested fade keeps its duration.
            let rampDuration = fadeInDuration ?? 1.0
            await AlarmSoundPlayer.shared.play(soundID: soundID, initialVolume: 0.05)
            VolumeManager.shared.fadeInVolume(to: Float(effectiveVolume), duration: rampDuration)
        }
        
        // 4. Route based on app state
        let appState = UIApplication.shared.applicationState
        
        if appState == .active {
            // FOREGROUND: Show alert screen directly, skip notification
            AlarmWindowManager.shared.showAlarm(
                alarmID: alarmID,
                label: title,
                missionType: .alert,
                soundID: playSound ? soundID : "silent"
            )
            print("🚨 Alert shown directly (app foregrounded)")
        } else {
            // BACKGROUND: Fire local notification, show alert when user taps it
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.categoryIdentifier = "MQTT_ALERT"
            // Alerts are urgent but they are not alarms: time-sensitive (not
            // critical) breaks through Focus where the user allows it, and a
            // dedicated thread keeps HA alerts grouped together in Notification
            // Center instead of interleaving with alarm-backup notifications.
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "ha-alerts"
            
            // Notification sound. In the normal case the in-app player is
            // already ringing at the payload/alarm volume — an inbound MQTT
            // alert implies the app is alive (App Persistence), and the sound
            // starts above, before this routing. A chime here would replay the
            // alert on top at ringer volume, which is why home-screen alerts
            // sounded louder than foreground ones (al-7mz). Stay silent when
            // playback really started; keep the chime when it did not (e.g.
            // audio session unavailable moments after backgrounding) so the
            // failure mode is double audio, never a silent alert.
            let inAppAudioStarted = playSound && AlarmSoundPlayer.shared.isPlaying
            if inAppAudioStarted {
                content.sound = nil
            } else if let sound = AlarmSoundManager.shared.getSound(id: soundID) {
                let soundFileName = sound.id + ".wav"
                content.sound = UNNotificationSound(named: UNNotificationSoundName(soundFileName))
            } else {
                content.sound = .default
            }
            // Future critical alert:
            // content.sound = .criticalSoundNamed(UNNotificationSoundName(soundFileName), withAudioVolume: Float(volumeLevel ?? settings.alarmVolumeLevel))
            
            content.userInfo = [
                "alertAlarmID": alarmID,
                "soundID": soundID,
                "volumeLevel": volumeLevel ?? settings.alarmVolumeLevel,
                "playSound": playSound,
                // Identity + send time let the tap handler recognise a
                // notification for an alert that has since been dismissed.
                // Both are additive; a notification without them still works,
                // the handler just derives identity from title/body and falls
                // back to UNNotification.date.
                AlertDeliveryLedger.identityUserInfoKey: alertIdentity,
                AlertDeliveryLedger.sentAtUserInfoKey: sentAt.timeIntervalSince1970
            ]

            let request = UNNotificationRequest(
                identifier: notificationID,
                content: content,
                trigger: nil  // Deliver immediately
            )
            
            do {
                try await UNUserNotificationCenter.current().add(request)
                print("🔔 Alert notification scheduled (app backgrounded)")
            } catch {
                print("❌ Failed to schedule alert notification: \(error)")
            }
            
            // Also try showing the alarm UI — will succeed if the app
            // comes to foreground before the notification is tapped
            AlarmWindowManager.shared.showAlarm(
                alarmID: alarmID,
                label: title,
                missionType: .alert,
                soundID: playSound ? soundID : "silent"
            )
        }

        // 4. Publish state to MQTT
        HAIntegrationRouter.shared.publishAlarmState(.ringing, settings: settings)
        HAIntegrationRouter.shared.activeAlarmIndex = nil
        HAIntegrationRouter.shared.publishActiveAlarmIndex(nil, settings: settings)
        HAIntegrationRouter.shared.publishActiveAlarmName(title, settings: settings)
        HAIntegrationRouter.shared.publishActiveAlarmMission("alert", settings: settings)
        HAIntegrationRouter.shared.publishActiveAlarmDays("none", settings: settings)
    }
    
    // MARK: - Dismiss Active Alarm
    
    func handleDismissCommand(payload: [String: Any]) {
        guard AlarmWindowManager.shared.isShowingAlarm else {
            print("⚠️ No active alarm to dismiss")
            return
        }
        
        print("📥 MQTT dismiss command received")
        AppLogger.shared.log("MQTT dismiss command received", category: .mqtt)
        
        // Post notification for ActiveAlarmView to handle (works for all mission types including .alert)
        NotificationCenter.default.post(name: NSNotification.Name("MQTTDismissAlarm"), object: nil)
    }
    
    // MARK: - Snooze Active Alarm
    
    func handleSnoozeCommand(payload: [String: Any]) {
        guard AlarmWindowManager.shared.isShowingAlarm else {
            print("⚠️ No active alarm to snooze")
            return
        }
        
        print("📥 MQTT snooze command received")
        AppLogger.shared.log("MQTT snooze command received", category: .mqtt)
        NotificationCenter.default.post(name: NSNotification.Name("MQTTSnoozeAlarm"), object: nil)
    }
    
    // MARK: - Per-Alarm Commands
    
    func handlePerAlarmDismiss(alarmIndex: Int) {
        guard AlarmWindowManager.shared.isShowingAlarm else {
            print("⚠️ No active alarm to dismiss (per-alarm dismiss for index \(alarmIndex))")
            return
        }
        
        guard let currentAlarm = AlarmWindowManager.shared.currentAlarm else {
            print("⚠️ No current alarm object available")
            return
        }
        
        guard currentAlarm.alarmIndex == alarmIndex else {
            print("⚠️ Per-alarm dismiss: index mismatch (ringing=\(currentAlarm.alarmIndex), requested=\(alarmIndex))")
            return
        }
        
        print("📥 Per-alarm dismiss command for alarm index: \(alarmIndex)")
        NotificationCenter.default.post(name: NSNotification.Name("MQTTDismissAlarm"), object: nil)
    }
    
    func handlePerAlarmSnooze(alarmIndex: Int) {
        guard AlarmWindowManager.shared.isShowingAlarm else {
            print("⚠️ No active alarm to snooze (per-alarm snooze for index \(alarmIndex))")
            return
        }
        
        guard let currentAlarm = AlarmWindowManager.shared.currentAlarm else {
            print("⚠️ No current alarm object available")
            return
        }
        
        guard currentAlarm.alarmIndex == alarmIndex else {
            print("⚠️ Per-alarm snooze: index mismatch (ringing=\(currentAlarm.alarmIndex), requested=\(alarmIndex))")
            return
        }
        
        print("📥 Per-alarm snooze command for alarm index: \(alarmIndex)")
        NotificationCenter.default.post(name: NSNotification.Name("MQTTSnoozeAlarm"), object: nil)
    }
    
    // MARK: - Skip / Kill Snoozed Alarm (operate on non-ringing alarms)
    
    /// Fetch an alarm from SwiftData by its stable MQTT index.
    /// Uses the container's mainContext (the same context SwiftUI views use)
    /// so reads always reflect the latest in-memory state — no stale data.
    private func fetchAlarm(byIndex alarmIndex: Int) -> (alarm: Alarm, context: ModelContext)? {
        guard let container = AlarmWindowManager.shared.modelContainer else {
            print("⚠️ MQTTCommandHandler: no ModelContainer available")
            return nil
        }
        let context = container.mainContext
        guard let alarms = try? context.fetch(FetchDescriptor<Alarm>()) else {
            print("⚠️ MQTTCommandHandler: failed to fetch alarms")
            return nil
        }
        guard let alarm = alarms.first(where: { !$0.isDetached && $0.alarmIndex == alarmIndex }) else {
            print("⚠️ MQTTCommandHandler: no alarm found with index \(alarmIndex)")
            return nil
        }
        return (alarm, context)
    }

    /// The alarm previously created for this `mqtt_id`, if any. Only alarms that
    /// came in over MQTT carry one, so this can never collide with a hand-made
    /// alarm. Ties are broken by lowest index — the first one created.
    private func fetchAlarm(byMQTTID mqttID: String) -> Alarm? {
        guard let container = AlarmWindowManager.shared.modelContainer,
              let alarms = try? container.mainContext.fetch(FetchDescriptor<Alarm>()) else { return nil }
        return alarms
            .filter { !$0.isDetached && $0.mqttID == mqttID }
            .min(by: { $0.alarmIndex < $1.alarmIndex })
    }

    /// How many MQTT-created alarms exist right now, or nil when the store can't
    /// be read (in which case the cap can't be enforced and isn't guessed at).
    private func mqttCreatedAlarmCount() -> Int? {
        guard let container = AlarmWindowManager.shared.modelContainer,
              let alarms = try? container.mainContext.fetch(FetchDescriptor<Alarm>()) else { return nil }
        return alarms.filter { !$0.isDetached && $0.source == "mqtt" }.count
    }

    private func fetchAlarm(byLabel label: String) -> (alarm: Alarm, context: ModelContext)? {
        guard let container = AlarmWindowManager.shared.modelContainer else {
            print("⚠️ MQTTCommandHandler: no ModelContainer available")
            return nil
        }
        let context = container.mainContext
        guard let alarms = try? context.fetch(FetchDescriptor<Alarm>()) else {
            print("⚠️ MQTTCommandHandler: failed to fetch alarms")
            return nil
        }
        let lowerLabel = label.lowercased()
        guard let alarm = alarms.first(where: { !$0.isDetached && $0.label.lowercased() == lowerLabel }) else {
            print("⚠️ MQTTCommandHandler: no alarm found with label '\(label)'")
            return nil
        }
        return (alarm, context)
    }
    
    /// Dashboard "Unskip Alarm" — finds the first skipped alarm and unskips it.
    func handleUnskipNextAlarm() {
        guard let container = AlarmWindowManager.shared.modelContainer else {
            print("⚠️ Unskip next alarm: no ModelContainer available")
            return
        }
        let context = container.mainContext
        guard let alarms = try? context.fetch(FetchDescriptor<Alarm>()) else {
            print("⚠️ Unskip next alarm: failed to fetch alarms")
            return
        }

        // Find the skipped alarm with the earliest skippedFireDate
        let nextSkipped = alarms
            .filter { !$0.isDetached && $0.isEnabled && $0.isSkipped }
            .compactMap { alarm -> (alarm: Alarm, date: Date)? in
                guard let date = alarm.skippedFireDate else { return nil }
                return (alarm, date)
            }
            .min(by: { $0.date < $1.date })

        guard let (alarm, _) = nextSkipped else {
            print("⚠️ Unskip next alarm: no skipped alarm found")
            return
        }

        print("📥 Dashboard unskip: targeting alarm \(alarm.alarmIndex) (\(alarm.label))")
        AppLogger.shared.log("MQTT unskip command: alarm \(alarm.alarmIndex) (\(alarm.label))", category: .mqtt)
        handlePerAlarmUnskip(alarmIndex: alarm.alarmIndex)
    }

    /// Dashboard "Skip Alarm" — finds the next upcoming enabled alarm and skips it.
    func handleSkipNextAlarm() {
        guard let container = AlarmWindowManager.shared.modelContainer else {
            print("⚠️ Skip next alarm: no ModelContainer available")
            return
        }
        let context = container.mainContext
        guard let alarms = try? context.fetch(FetchDescriptor<Alarm>()) else {
            print("⚠️ Skip next alarm: failed to fetch alarms")
            return
        }
        
        // Find the next enabled, non-skipped alarm by fire date
        let nextAlarm = alarms
            .filter { !$0.isDetached && $0.isEnabled && !$0.isSkipped && !$0.isSnoozed }
            .compactMap { alarm -> (alarm: Alarm, date: Date)? in
                guard let date = alarm.nextFireDate() else { return nil }
                return (alarm, date)
            }
            .min(by: { $0.date < $1.date })
        
        guard let (alarm, _) = nextAlarm else {
            print("⚠️ Skip next alarm: no upcoming alarm found")
            return
        }
        
        print("📥 Dashboard skip: targeting alarm \(alarm.alarmIndex) (\(alarm.label))")
        AppLogger.shared.log("MQTT skip command: alarm \(alarm.alarmIndex) (\(alarm.label))", category: .mqtt)
        handlePerAlarmSkip(alarmIndex: alarm.alarmIndex)
    }
    
    func handlePerAlarmSkip(alarmIndex: Int) {
        guard let (alarm, context) = fetchAlarm(byIndex: alarmIndex) else { return }
        
        let settings = DeviceSettings.shared
        
        guard alarm.isEnabled else {
            print("⚠️ Per-alarm skip: alarm \(alarmIndex) is disabled")
            return
        }
        
        guard !alarm.isSnoozed else {
            print("⚠️ Per-alarm skip: alarm \(alarmIndex) is snoozed, cannot skip")
            return
        }
        
        if alarm.isSkipped {
            // Unskip: clear the skipped fire date
            alarm.skippedFireDate = nil
            print("📥 Per-alarm unskip: alarm \(alarmIndex) (\(alarm.label))")
        } else {
            // Skip: requires skip mode enabled
            guard alarm.effectiveSkipMode(settings: settings) != .disabled else {
                print("⚠️ Per-alarm skip: skip mode disabled for alarm \(alarmIndex)")
                return
            }
            
            if alarm.isRecurring {
                // Recurring: skip next occurrence
                alarm.skippedFireDate = alarm.nextFireDate()
                print("📥 Per-alarm skip: alarm \(alarmIndex) (\(alarm.label)), skipping \(alarm.skippedFireDate?.description ?? "nil")")
            } else {
                // One-time: disable the alarm (equivalent to "turn off" in the app)
                alarm.isEnabled = false
                print("📥 Per-alarm skip (one-time): alarm \(alarmIndex) (\(alarm.label)), disabling")
            }
        }
        
        try? context.save()
        
        Task {
            await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
            
            // Update MQTT state
            if settings.mqttEnabled {
                HAIntegrationRouter.shared.publishPerAlarmState(alarm: alarm, settings: settings)
            }
            
            // Trigger full state refresh (next alarm time, counts, etc.)
            NotificationCenter.default.post(name: NSNotification.Name("AlarmStateChanged"), object: nil)
        }
    }
    
    /// Unskip a per-alarm (clear skippedFireDate).
    func handlePerAlarmUnskip(alarmIndex: Int) {
        guard let (alarm, context) = fetchAlarm(byIndex: alarmIndex) else { return }

        guard alarm.isSkipped else {
            print("⚠️ Per-alarm unskip: alarm \(alarmIndex) is not skipped")
            return
        }

        alarm.skippedFireDate = nil
        print("📥 Per-alarm unskip: alarm \(alarmIndex) (\(alarm.label))")
        try? context.save()

        let settings = DeviceSettings.shared
        Task {
            await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
            if settings.mqttEnabled {
                HAIntegrationRouter.shared.publishPerAlarmState(alarm: alarm, settings: settings)
            }
            NotificationCenter.default.post(name: NSNotification.Name("AlarmStateChanged"), object: nil)
        }
    }

    /// Enable or disable a per-alarm from HA.
    func handlePerAlarmEnabled(alarmIndex: Int, enabled: Bool) {
        guard let (alarm, context) = fetchAlarm(byIndex: alarmIndex) else { return }

        alarm.isEnabled = enabled
        print("📥 Per-alarm enabled: alarm \(alarmIndex) (\(alarm.label)) → \(enabled ? "on" : "off")")
        try? context.save()

        let settings = DeviceSettings.shared
        Task {
            await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
            if settings.mqttEnabled {
                HAIntegrationRouter.shared.publishPerAlarmState(alarm: alarm, settings: settings)
            }
            NotificationCenter.default.post(name: NSNotification.Name("AlarmStateChanged"), object: nil)
        }
    }

    // MARK: - Command CRUD

    /// Locate a saved command by the name an automation used.
    ///
    /// **Exact match first**, which is the behaviour every existing automation
    /// relies on and the reason two commands deliberately named "Lights" and
    /// "lights" keep resolving to themselves. Only when nothing matches exactly
    /// do we retry on the normalised key, which forgives what a name picks up in
    /// transit: a trailing space pasted into the automation editor, a
    /// non-breaking space copied off a web page, a case change from a dropdown
    /// that title-cased it. A name that resolved before resolves to the same
    /// command; a name that used to silently resolve to nothing now gets a
    /// second chance instead of the command button quietly not appearing.
    ///
    /// `static` and taking the list explicitly so the payload tests can exercise
    /// it without `DeviceSettings`. Pure — no side effects, no persistence.
    static func commandIndex(named name: String, in commands: [MQTTCommand]) -> Int? {
        if let exact = commands.firstIndex(where: { $0.name == name }) { return exact }
        let key = MQTTStrings.matchKey(name)
        guard !key.isEmpty else { return nil }
        return commands.firstIndex { MQTTStrings.matchKey($0.name) == key }
    }

    /// `commandIndex` as a lookup. Same exact-then-tolerant order.
    static func command(named name: String, in commands: [MQTTCommand]) -> MQTTCommand? {
        commandIndex(named: name, in: commands).map { commands[$0] }
    }

    /// Create or update an MQTTCommand from an MQTT JSON payload.
    /// Required field: `name`. Optional: `icon` (SF Symbol), `color` (preset name),
    /// `arm_action` (none/arm/disarm/toggle), `show_in_list` (bool).
    /// If a command with the same name already exists, it will be updated.
    func handleCreateCommand(payload: [String: Any]) {
        // Trim the ends and drop control characters before storing. A name that
        // is nothing BUT whitespace used to pass the `!isEmpty` check and create
        // a command with a blank label, no usable topic slug and no way to
        // delete it by name; it is now rejected with a reason in the log rather
        // than accepted into an unusable state. Internal spacing is untouched —
        // see `MQTTStrings.trimmedForStorage`.
        let rawName = (payload["name"] as? String) ?? ""
        let name = MQTTStrings.trimmedForStorage(rawName)
        guard !name.isEmpty else {
            print("❌ create_command: missing or blank required 'name' field")
            return
        }

        let settings = DeviceSettings.shared

        // The name the STORED command carries, which is not always the name the
        // payload used — `commandIndex` falls back to a tolerant match, so
        // "Lights On" can resolve to a command stored as "Lights  On". The topic
        // slug must come from the stored name or we would seed a status topic
        // Home Assistant never hears from again.
        let storedName: String

        // Check if command with this name already exists → update it
        if let existingIndex = Self.commandIndex(named: name, in: settings.mqttCommands) {
            var cmd = settings.mqttCommands[existingIndex]
            applyCommandFields(to: &cmd, from: payload)
            settings.mqttCommands[existingIndex] = cmd
            storedName = cmd.name
            print("📥 MQTT create_command: updated existing '\(name)'")
        } else {
            // Create new command
            var cmd = MQTTCommand(name: name)
            applyCommandFields(to: &cmd, from: payload)
            settings.mqttCommands.append(cmd)
            storedName = cmd.name
            print("📥 MQTT create_command: created '\(name)'")
        }

        AppLogger.shared.log("MQTT create_command: '\(name)'", category: .mqtt)

        // Seed the command's status topic and refresh the count, mirroring what
        // `handleDeleteCommand` does on the way out.
        //
        // Without this a command created over MQTT had NO sensor in Home
        // Assistant until the app next reconnected and `publishOnlineState`
        // re-seeded every command — so the automation that just created it could
        // not see it, and the user had no way to know why. `applyCommandFields`
        // never rewrites `name`, so this is a seed, never a rename: an existing
        // command keeps the slug (and therefore the entity_id) it already has.
        publishCommandInventory(named: storedName, settings: settings)
    }

    /// Publish a command's status topic (seeded to `idle`) plus the commands
    /// count sensor. Safe to call for an existing command — re-publishing `idle`
    /// on a retained topic that already reads `idle` changes nothing.
    private func publishCommandInventory(named storedName: String, settings: DeviceSettings) {
        guard settings.mqttEnabled else { return }
        let prefix = settings.mqttTopicPrefix
        let deviceName = settings.sanitizedDeviceName
        let slug = MQTTStrings.commandTopicSlug(storedName)
        MQTTManager.shared.publish(
            topic: "\(prefix)/\(deviceName)/command/\(slug)/status",
            payload: "idle",
            retain: settings.mqttPublishRetained
        )
        MQTTManager.shared.publish(
            topic: "\(prefix)/\(deviceName)/sensor/commands_count",
            payload: "\(settings.mqttCommands.count)",
            retain: settings.mqttPublishRetained
        )
    }
    
    /// Delete an MQTTCommand by name.
    /// Required field: `name`.
    func handleDeleteCommand(payload: [String: Any]) {
        guard let rawName = payload["name"] as? String,
              !MQTTStrings.trimmedForStorage(rawName).isEmpty else {
            print("❌ delete_command: missing or blank required 'name' field")
            return
        }
        let name = MQTTStrings.trimmedForStorage(rawName)

        let settings = DeviceSettings.shared

        // Tolerant lookup, so a command created before the trim above (stored
        // with a stray leading space) is still deletable by the clean name, and
        // vice versa.
        guard let index = Self.commandIndex(named: name, in: settings.mqttCommands) else {
            print("⚠️ delete_command: no command found with name '\(name)'")
            return
        }
        
        settings.mqttCommands.remove(at: index)
        print("📥 MQTT delete_command: removed '\(name)'")
        AppLogger.shared.log("MQTT delete_command: '\(name)'", category: .mqtt)
        
        // Update the commands count sensor
        if settings.mqttEnabled {
            let prefix = settings.mqttTopicPrefix
            let deviceName = settings.sanitizedDeviceName
            MQTTManager.shared.publish(
                topic: "\(prefix)/\(deviceName)/sensor/commands_count",
                payload: "\(settings.mqttCommands.count)",
                retain: settings.mqttPublishRetained
            )
        }
    }
    
    /// Apply optional fields from a create_command/update payload to an MQTTCommand.
    private func applyCommandFields(to cmd: inout MQTTCommand, from payload: [String: Any]) {
        // Icon (SF Symbol name)
        if let icon = payload["icon"] as? String, !icon.isEmpty {
            cmd.icon = icon
        }
        
        // Color — accept a preset name or explicit RGB.
        //
        // `allPresetColors` leads with the original twelve, so every name that
        // has ever worked still resolves to the exact same RGB; the extended
        // names are additions on the end. An unrecognised name still falls
        // through to "leave the color alone", as it always has.
        if let colorName = payload["color"] as? String {
            if let preset = MQTTCommand.presetColor(named: colorName) {
                cmd.iconColorRed = preset.r
                cmd.iconColorGreen = preset.g
                cmd.iconColorBlue = preset.b
            }
        }
        if let r = (payload["color_r"] as? NSNumber)?.doubleValue {
            cmd.iconColorRed = min(max(r, 0.0), 1.0)
        }
        if let g = (payload["color_g"] as? NSNumber)?.doubleValue {
            cmd.iconColorGreen = min(max(g, 0.0), 1.0)
        }
        if let b = (payload["color_b"] as? NSNumber)?.doubleValue {
            cmd.iconColorBlue = min(max(b, 0.0), 1.0)
        }
        
        // Arm action
        if let actionStr = payload["arm_action"] as? String {
            switch actionStr.lowercased() {
            case "arm": cmd.armAction = .arm
            case "disarm": cmd.armAction = .disarm
            case "toggle": cmd.armAction = .toggle
            default: cmd.armAction = .none
            }
        }
        
        // Show in list
        if let showInList = payload["show_in_list"] as? Bool {
            cmd.showInList = showInList
        }
    }
    
    // MARK: - Alarm CRUD Commands
    
    /// Create a new alarm from an MQTT JSON payload.
    /// Required field: `time` (HH:mm). All others optional with sensible defaults.
    func handleCreateAlarm(payload: [String: Any]) async {
        guard let timeString = payload["time"] as? String else {
            print("❌ create_alarm: missing required 'time' field (HH:mm)")
            return
        }

        // UPSERT on `mqtt_id`. The id was stored on every created alarm but never
        // read back, so an automation that re-published its alarm — a restart, a
        // retried script, a loop — added a duplicate every time. Re-running the
        // same `create_alarm` now edits the alarm it created before, which is what
        // an `mqtt_id` was always for. No `mqtt_id`, no change in behaviour.
        if let mqttID = (payload["mqtt_id"] as? String)?.trimmingCharacters(in: .whitespaces),
           !mqttID.isEmpty,
           let existing = fetchAlarm(byMQTTID: mqttID) {
            print("📥 MQTT create_alarm: mqtt_id '\(mqttID)' already exists (index=\(existing.alarmIndex)) — updating in place instead of inserting a duplicate")
            AppLogger.shared.log("MQTT create_alarm upsert: mqtt_id '\(mqttID)' → update_alarm index=\(existing.alarmIndex)", category: .mqtt)
            // Route through update_alarm so one body owns field application.
            // `index` wins over `name` there, so the target is unambiguous even
            // when the payload also renames the alarm.
            var merged = payload
            merged["index"] = NSNumber(value: existing.alarmIndex)
            await handleUpdateAlarm(payload: merged)
            return
        }

        // Flood cap. A looping automation or a hostile publisher could otherwise
        // insert without bound and burn iOS's ~64-alarm scheduling budget, which
        // starves the alarms the user actually set. This is a deliberate
        // rejection — the only one here — so it is loud rather than silent.
        if let count = mqttCreatedAlarmCount(), count >= Self.maxMQTTCreatedAlarms {
            print("🛑 create_alarm REFUSED: \(count) MQTT-created alarms already exist and the cap is \(Self.maxMQTTCreatedAlarms). Delete some (delete_alarm) or reuse `mqtt_id` to update instead of creating.")
            AppLogger.shared.log("MQTT create_alarm REFUSED — cap of \(Self.maxMQTTCreatedAlarms) MQTT-created alarms reached (\(count) exist)", category: .mqtt)
            return
        }


        // Parse HH:mm time
        let formatter = DateFormatter()
        // Strip seconds if present (HA time selector sends HH:mm:ss)
        let trimmedTime = timeString.count > 5 ? String(timeString.prefix(5)) : timeString
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let parsedTime = formatter.date(from: trimmedTime) else {
            print("❌ create_alarm: invalid time format '\(timeString)' (expected HH:mm or HH:mm:ss)")
            return
        }
        
        // Build the fire date using today's date with the parsed hour/minute
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        let timeComponents = calendar.dateComponents([.hour, .minute], from: parsedTime)
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        components.second = 0
        guard let fireDate = calendar.date(from: components) else {
            print("❌ create_alarm: failed to construct fire date")
            return
        }
        
        let settings = DeviceSettings.shared
        let label = (payload["name"] as? String) ?? (payload["label"] as? String) ?? "Alarm"
        let enabled = (payload["enabled"] as? Bool) ?? true
        
        // Recurring days
        var recurringDays: Set<Int> = []
        if let days = Self.parsedDays(from: payload) {
            recurringDays = days
        }
        
        // Sound — look up by ID, fall back to default.
        // Store the sound ID (file name), never the display name: playback and
        // AlarmKit resolve alarm.soundName via getSound(id:)/fileURL by ID.
        var soundName = AlarmSoundManager.shared.getDefaultSound().id
        if let soundID = payload["sound"] as? String,
           let sound = AlarmSoundManager.shared.getSound(id: soundID) {
            soundName = sound.id
        }
        
        // Snooze config
        let snoozeDuration = Self.clampedInt(payload, key: "snooze_duration", range: Self.snoozeDurationRange) ?? settings.defaultSnoozeDuration
        let maxSnoozeCount: Int? = Self.clampedInt(payload, key: "max_snooze_count", range: Self.maxSnoozeCountRange)
        
        // Build the mission sequence. `missions` (array) gives the full sequence;
        // otherwise the single `mission` field supplies slot 1 alone.
        let missionSequence = buildMissionSequence(from: payload) ?? [buildMission(from: payload)]
        let mission = missionSequence.first ?? Mission()
        let extraMissions = Array(missionSequence.dropFirst())
        
        // Snooze mode
        var snoozeModeRaw: String? = nil
        if let modeStr = payload["snooze_mode"] as? String {
            snoozeModeRaw = mapSnoozeMode(modeStr)
        }
        
        // Skip mode
        var skipAlarmModeRaw: String? = nil
        if let modeStr = payload["skip_mode"] as? String {
            skipAlarmModeRaw = mapSkipMode(modeStr)
        }
        
        // Create the alarm
        let alarm = Alarm(
            time: fireDate,
            label: label,
            isEnabled: enabled,
            recurringDays: recurringDays,
            soundName: soundName,
            snoozeDuration: snoozeDuration,
            mission: mission,
            maxSnoozeCount: maxSnoozeCount,
            snoozeModeRaw: snoozeModeRaw,
            skipAlarmModeRaw: skipAlarmModeRaw
        )
        // Slots 2..5, when the payload supplied a `missions` array.
        alarm.extraMissions = extraMissions

        // Hold durations (only meaningful when mode is "hold")
        if let holdDur = Self.clampedDouble(payload, key: "snooze_hold_duration", range: Self.holdDurationRange) {
            alarm.customSnoozeHoldDuration = holdDur
        }
        if let holdDur = Self.clampedDouble(payload, key: "skip_hold_duration", range: Self.holdDurationRange) {
            alarm.skipHoldDuration = holdDur
        }
        
        // Per-alarm overrides (nil = use global default)
        if let volume = (payload["volume"] as? NSNumber)?.doubleValue {
            alarm.customVolumeLevel = normalizeVolume(volume)
        }
        if let vibrate = payload["vibrate"] as? Bool {
            alarm.customVibrationEnabled = vibrate
        }
        applyFadeIn(payload: payload, to: alarm)
        
        if let morningWeather = payload["morning_weather"] as? Bool {
            alarm.showWeatherAfterAlarm = morningWeather
        }

        // App links opened after dismiss/snooze (URL string, e.g. shortcuts://...)
        if let dismissURI = payload["dismiss_app_uri"] as? String {
            alarm.dismissAppURI = dismissURI.isEmpty ? nil : dismissURI
        }
        if let snoozeURI = payload["snooze_app_uri"] as? String {
            alarm.snoozeAppURI = snoozeURI.isEmpty ? nil : snoozeURI
        }

        // Wake-up radio station (favourite name/uuid, {url,…} object, or "" to clear)
        applyRadioStation(from: payload, to: alarm)

        // Explicit after-alarm order. Runs AFTER the config fields above so a
        // payload carrying both `notes` and `after_alarm_actions` ends up with
        // the text set and the order the automation asked for.
        applyAfterAlarmActions(from: payload, to: alarm)

        // Swipe command assignments (by name; exact match first, then tolerant)
        if let leftCmd = payload["swipe_left_command"] as? String {
            alarm.swipeLeftCommandID = Self.command(named: leftCmd, in: settings.mqttCommands)?.id.uuidString
        }
        if let rightCmd = payload["swipe_right_command"] as? String {
            alarm.swipeRightCommandID = Self.command(named: rightCmd, in: settings.mqttCommands)?.id.uuidString
        }

        // Notes after-alarm page: notes text + up to 4 command buttons (by
        // name). Setting either surfaces the `.notes` step via the
        // `afterAlarmActions` read-time reconciliation — no order write needed.
        if let notes = payload["notes"] as? String {
            alarm.alarmScreenNotes = notes
        }
        if let commandNames = payload["alarm_screen_commands"] as? [String] {
            applyNotesCommandSlots(commandNames, to: alarm, settings: settings)
        }

        // Single-action toggles (`verse_of_day`, `morning_weather`). LAST, so the
        // derived order they read already reflects the notes text set above.
        applyAfterAlarmToggles(from: payload, to: alarm)

        // MQTT tracking
        alarm.alarmIndex = settings.assignNextAlarmIndex()
        alarm.source = "mqtt"
        alarm.mqttID = payload["mqtt_id"] as? String
        alarm.isEphemeral = (payload["ephemeral"] as? Bool) ?? false
        
        // Insert into SwiftData
        guard let container = AlarmWindowManager.shared.modelContainer else {
            print("❌ create_alarm: no ModelContainer available")
            return
        }
        let context = container.mainContext
        context.insert(alarm)
        try? context.save()
        
        print("📥 MQTT create_alarm: '\(alarm.label)' index=\(alarm.alarmIndex) time=\(timeString) days=\(recurringDays) mission=\(mission.type.rawValue)")
        AppLogger.shared.log("MQTT create_alarm: '\(alarm.label)' index=\(alarm.alarmIndex) time=\(timeString)", category: .mqtt)
        
        // Schedule
        await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
        
        // Publish MQTT state
        if settings.mqttEnabled {
            HAIntegrationRouter.shared.publishPerAlarmState(alarm: alarm, settings: settings)
        }
        
        NotificationCenter.default.post(name: NSNotification.Name("AlarmStateChanged"), object: nil)
    }
    
    /// Update an existing alarm from an MQTT JSON payload.
    /// Target by `index` (Int) OR `name`/`label` (String, case-insensitive). Only provided fields are updated (partial update).
    func handleUpdateAlarm(payload: [String: Any]) async {
        let fetched: (alarm: Alarm, context: ModelContext)?
        if let index = (payload["index"] as? NSNumber)?.intValue {
            fetched = fetchAlarm(byIndex: index)
        } else if let nameStr = (payload["name"] as? String) ?? (payload["label"] as? String), !nameStr.isEmpty {
            fetched = fetchAlarm(byLabel: nameStr)
        } else {
            print("❌ update_alarm: provide 'index' (Int) or 'name' (String)")
            return
        }
        
        guard let (alarm, context) = fetched else { return }
        
        let settings = DeviceSettings.shared
        
        // Alarm name rename — accept both "name" and "label".
        // When targeting by name this is a no-op (sets same value); only meaningful when targeting by index.
        if let label = (payload["name"] as? String) ?? (payload["label"] as? String) {
            alarm.label = label
        }
        
        // Time
        if let timeString = payload["time"] as? String {
            let formatter = DateFormatter()
            // Strip seconds if present (HA's time selector sends HH:mm:ss), the
            // same way create_alarm does. Without this an "HH:mm:ss" time simply
            // failed to parse and the alarm kept its old time with no warning —
            // and create_alarm's upsert now routes such payloads through here.
            let trimmedTime = timeString.count > 5 ? String(timeString.prefix(5)) : timeString
            formatter.dateFormat = "HH:mm"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let parsedTime = formatter.date(from: trimmedTime) {
                let calendar = Calendar.current
                var components = calendar.dateComponents([.year, .month, .day], from: Date())
                let timeComponents = calendar.dateComponents([.hour, .minute], from: parsedTime)
                components.hour = timeComponents.hour
                components.minute = timeComponents.minute
                components.second = 0
                if let fireDate = calendar.date(from: components) {
                    alarm.time = fireDate
                }
            }
        }
        
        // Enabled
        if let enabled = payload["enabled"] as? Bool {
            alarm.isEnabled = enabled
        }
        
        // Recurring days
        if let days = Self.parsedDays(from: payload) {
            alarm.recurringDays = days
        }
        
        // Sound (store the ID — playback resolves soundName by ID)
        if let soundID = payload["sound"] as? String,
           let sound = AlarmSoundManager.shared.getSound(id: soundID) {
            alarm.soundName = sound.id
        }
        
        // Volume
        if let volume = (payload["volume"] as? NSNumber)?.doubleValue {
            alarm.customVolumeLevel = normalizeVolume(volume)
        }
        
        // Vibrate
        if let vibrate = payload["vibrate"] as? Bool {
            alarm.customVibrationEnabled = vibrate
        }
        
        applyFadeIn(payload: payload, to: alarm)
        
        // Snooze duration
        if let snoozeDuration = Self.clampedInt(payload, key: "snooze_duration", range: Self.snoozeDurationRange) {
            alarm.snoozeDuration = snoozeDuration
        }

        // Max snooze count
        if let maxSnooze = Self.clampedInt(payload, key: "max_snooze_count", range: Self.maxSnoozeCountRange) {
            alarm.maxSnoozeCount = maxSnooze
        }
        
        // Snooze mode
        if let modeStr = payload["snooze_mode"] as? String {
            alarm.snoozeModeRaw = mapSnoozeMode(modeStr)
        }
        
        // Skip mode
        if let modeStr = payload["skip_mode"] as? String {
            alarm.skipAlarmModeRaw = mapSkipMode(modeStr)
        }
        
        // Hold durations (only meaningful when mode is "hold")
        if let holdDur = Self.clampedDouble(payload, key: "snooze_hold_duration", range: Self.holdDurationRange) {
            alarm.customSnoozeHoldDuration = holdDur
        }
        if let holdDur = Self.clampedDouble(payload, key: "skip_hold_duration", range: Self.holdDurationRange) {
            alarm.skipHoldDuration = holdDur
        }

        // Missions. `missions` (array) replaces the whole sequence; `mission`
        // (single) replaces slot 1 and clears the extras.
        applyMissions(from: payload, to: alarm)

        // Swipe commands (by name; "" still clears, as it always has)
        if let leftCmd = payload["swipe_left_command"] as? String {
            alarm.swipeLeftCommandID = leftCmd.isEmpty ? nil : Self.command(named: leftCmd, in: settings.mqttCommands)?.id.uuidString
        }
        if let rightCmd = payload["swipe_right_command"] as? String {
            alarm.swipeRightCommandID = rightCmd.isEmpty ? nil : Self.command(named: rightCmd, in: settings.mqttCommands)?.id.uuidString
        }
        
        // Morning weather card
        if let morningWeather = payload["morning_weather"] as? Bool {
            alarm.showWeatherAfterAlarm = morningWeather
        }

        // App links opened after dismiss/snooze ("" = clear)
        if let dismissURI = payload["dismiss_app_uri"] as? String {
            alarm.dismissAppURI = dismissURI.isEmpty ? nil : dismissURI
        }
        if let snoozeURI = payload["snooze_app_uri"] as? String {
            alarm.snoozeAppURI = snoozeURI.isEmpty ? nil : snoozeURI
        }

        // Wake-up radio station (favourite name/uuid, {url,…} object, or "" to clear)
        applyRadioStation(from: payload, to: alarm)

        // Explicit after-alarm order. Runs AFTER the config fields above so a
        // payload carrying both `notes` and `after_alarm_actions` ends up with
        // the text set and the order the automation asked for.
        applyAfterAlarmActions(from: payload, to: alarm)

        // Notes after-alarm page ("" clears the text, [] clears the buttons;
        // clearing both drops the `.notes` step via read-time reconciliation)
        if let notes = payload["notes"] as? String {
            alarm.alarmScreenNotes = notes
        }
        // `append_notes` adds a line instead of replacing the whole text — V1's
        // behaviour, restored. Automations that build a morning briefing up over
        // several steps depend on it, and a replace-only API makes them re-send
        // the entire note every time (and race with anything else writing to it).
        // Runs AFTER `notes` so a payload carrying both replaces, then appends.
        if let appendNotes = payload["append_notes"] as? String, !appendNotes.isEmpty {
            appendToNotes(appendNotes, on: alarm)
        }
        if let commandNames = payload["alarm_screen_commands"] as? [String] {
            applyNotesCommandSlots(commandNames, to: alarm, settings: settings)
        }

        // Single-action toggles (`verse_of_day`, `morning_weather`). LAST, so the
        // order they read already reflects the notes text set above.
        applyAfterAlarmToggles(from: payload, to: alarm)

        // If this alarm's Notes page is on screen right now, push the change to
        // it — otherwise the edit is invisible until the alarm next fires.
        AfterAlarmNotesLive.shared.apply(
            hash: alarm.stableHash,
            notes: alarm.alarmScreenNotes,
            commandIDs: alarm.alarmScreenCommandIDs
        )

        try? context.save()
        
        print("📥 MQTT update_alarm: index=\(alarm.alarmIndex) '\(alarm.label)'")
        AppLogger.shared.log("MQTT update_alarm: index=\(alarm.alarmIndex) '\(alarm.label)'", category: .mqtt)
        
        // Reschedule
        await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
        
        if settings.mqttEnabled {
            HAIntegrationRouter.shared.publishPerAlarmState(alarm: alarm, settings: settings)
        }
        
        NotificationCenter.default.post(name: NSNotification.Name("AlarmStateChanged"), object: nil)
    }
    
    /// Delete an alarm by its MQTT index.
    /// Required field: `index`.
    /// Dashboard "Delete Next Alarm" — deletes whatever alarm is at the top of the queue.
    func handleDeleteNextAlarm() async {
        guard let container = AlarmWindowManager.shared.modelContainer else {
            print("⚠️ Delete next alarm: no ModelContainer available")
            return
        }
        let context = container.mainContext
        guard let alarms = try? context.fetch(FetchDescriptor<Alarm>()) else {
            print("⚠️ Delete next alarm: failed to fetch alarms")
            return
        }

        // Use the same sort order as the queue display, excluding ephemeral (quick) alarms.
        // This covers enabled, disabled, and fired one-time alarms — whatever is first in the queue.
        let regularAlarms = alarms.filter { !$0.isDetached && !$0.isEphemeral }
        let sorted = MQTTManager.sortAlarmsForDisplay(regularAlarms)

        guard let alarm = sorted.first else {
            print("⚠️ Delete next alarm: no alarms found")
            return
        }

        let index = alarm.alarmIndex
        print("📥 Dashboard delete next alarm: targeting alarm \(index) (\(alarm.label))")
        AppLogger.shared.log("MQTT delete_next_alarm: index=\(index) '\(alarm.label)'", category: .mqtt)
        // Use NSNumber to guarantee the [String: Any] cast succeeds in handleDeleteAlarm
        await handleDeleteAlarm(payload: ["index": NSNumber(value: index)])
    }

    func handleDeleteAlarm(payload: [String: Any]) async {
        // Support targeting by numeric index OR display label (case-insensitive)
        let fetched: (alarm: Alarm, context: ModelContext)?
        if let index = (payload["index"] as? NSNumber)?.intValue {
            fetched = fetchAlarm(byIndex: index)
        } else if let labelStr = (payload["name"] as? String) ?? (payload["label"] as? String), !labelStr.isEmpty {
            fetched = fetchAlarm(byLabel: labelStr)
        } else {
            print("❌ delete_alarm: provide 'index' (Int) or 'name' (String)")
            return
        }
        guard let (alarm, context) = fetched else { return }
        let index = alarm.alarmIndex
        
        let settings = DeviceSettings.shared
        let label = alarm.label
        
        // Cancel scheduling first (while the alarm is still valid)
        await DualAlarmCoordinator.shared.cancelAlarm(alarm)
        
        // CRITICAL: Set the suppression flag synchronously BEFORE the delete.
        // When context.delete() + context.save() runs, SwiftData's @Query
        // emits a change notification on the SAME run-loop turn. SwiftUI's
        // .onChange(of: alarms) fires immediately, calling updateMQTTStatus()
        // → publishCurrentAlarmState() → sortAlarmsForDisplay(). If that code
        // accesses lazy properties (recurringDays) on the now-invalidated
        // backing data, it crashes. The flag prevents all such access.
        isSuppressingAlarmAccess = true
        lastDeleteTimestamp = Date()
        
        // Delete from SwiftData BEFORE publishing MQTT cleanup,
        // so @Query-based views drop the alarm before any state refresh.
        context.delete(alarm)
        try? context.save()
        
        print("📥 MQTT delete_alarm: index=\(index) '\(label)'")
        AppLogger.shared.log("MQTT delete_alarm: index=\(index) '\(label)'", category: .mqtt)
        
        // Clear all retained MQTT data for this alarm from the broker.
        // Done after SwiftData delete so any triggered state refresh
        // won't try to access the deleted alarm's properties.
        if settings.mqttEnabled {
            MQTTManager.shared.clearDeletedAlarm(alarmIndex: index, settings: settings)
        }
        
        // Delay before posting the state-change notification so @Query
        // has time to reflect the deletion — matches the pattern used
        // by AlarmListView's own delete logic.
        try? await Task.sleep(for: .milliseconds(150))
        
        // Clear suppression flag — by now @Query has updated and
        // the deleted object is no longer in fetch results.
        isSuppressingAlarmAccess = false
        
        NotificationCenter.default.post(name: NSNotification.Name("AlarmStateChanged"), object: nil)
    }
    
    /// Append a line to an alarm's notes, V1-style: prefixed with `HA:` so the
    /// user can tell automation-written lines from their own, and separated from
    /// existing text by a divider. An empty notes field is simply seeded.
    ///
    /// The `HA:` prefix and `⸻` divider are kept byte-identical to V1 so
    /// automations that were written against the old behaviour (and any HA
    /// template that parses the result back out) keep working unchanged.
    private func appendToNotes(_ text: String, on alarm: Alarm) {
        let prefixed = "HA: \(text)"
        if alarm.alarmScreenNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alarm.alarmScreenNotes = prefixed
        } else {
            alarm.alarmScreenNotes += "\n⸻\n\(prefixed)"
        }
    }

    /// Map an ordered list of command NAMES onto the alarm's four notes-page
    /// command slots. Names that don't match a saved command are skipped (so
    /// slots stay dense); anything past four is dropped; unfilled slots clear.
    private func applyNotesCommandSlots(_ names: [String], to alarm: Alarm, settings: DeviceSettings) {
        let ids = names.compactMap { name in
            Self.command(named: name, in: settings.mqttCommands)?.id.uuidString
        }
        alarm.alarmScreenCommandID1 = ids.count > 0 ? ids[0] : nil
        alarm.alarmScreenCommandID2 = ids.count > 1 ? ids[1] : nil
        alarm.alarmScreenCommandID3 = ids.count > 2 ? ids[2] : nil
        alarm.alarmScreenCommandID4 = ids.count > 3 ? ids[3] : nil
    }

    // MARK: - Mission Builder

    /// The app's hard cap on missions per alarm (slot 1 + four extras).
    static let maxMissionSlots = 5

    // MARK: - After-alarm actions

    /// Apply `after_alarm_actions` — the ordered list of steps that run once the
    /// alarm is fully dismissed: `"notes"`, `"verse"`, `"weather"`, `"appLink"`.
    ///
    /// ADDITIVE BY DESIGN. Sending the array writes an explicit order; NOT
    /// sending it leaves the alarm exactly as it was. That distinction is what
    /// protects existing automations: `notes` and `morning_weather` have always
    /// been plain config fields, and `Alarm.afterAlarmActions` infers the step
    /// list from them when no explicit order exists. An automation written a
    /// year ago that sends only `{"notes": "..."}` still gets a Notes step,
    /// because this never runs for it.
    ///
    /// Two things follow from that, both deliberate:
    ///   • `.appLink` is forced last and duplicates are dropped by
    ///     `normalizeAfterAlarm`, matching what the app's editor enforces —
    ///     the open-app step leaves Allarise, so nothing can follow it.
    ///   • Omitting an action here does NOT switch it off if its config field
    ///     still has content. `Alarm.afterAlarmActions`' getter reconciles on
    ///     read and re-appends `.notes` when notes text exists, or `.appLink`
    ///     when a dismiss URI does. That reconciliation is what keeps
    ///     config-only automations working, so it wins on purpose — to remove
    ///     the Notes step, clear the text (`"notes": ""`); to remove the app
    ///     link, clear the URI. `.verse` and `.weather` have no such pull:
    ///     verse has no config field, and weather is driven by its own flag.
    ///
    /// `verse` is only settable here. Unlike the others it has no config field
    /// of its own; its presence in the list IS its enablement.
    ///
    /// Applies the alarm's fade-in settings from `fade_in_duration` / `fade_in`.
    ///
    /// The app's own picker runs 0…15, where 0 is a 30-second fade rather than
    /// "off" — the on/off state lives in a separate toggle. MQTT historically had
    /// only the duration, so 0 meant off and 30 seconds was unreachable. The
    /// optional `fade_in` boolean closes that gap without changing what existing
    /// payloads do:
    ///
    ///   - `fade_in_duration: 1…15`         → on, that many minutes (as before)
    ///   - `fade_in_duration: 0`            → off (as before)
    ///   - `fade_in_duration: 0` + `fade_in: true` → on, 30 seconds (new)
    ///   - `fade_in` alone                  → flips the toggle, duration untouched
    ///
    /// Returns true when the payload carried either key.
    @discardableResult
    func applyFadeIn(payload: [String: Any], to alarm: Alarm) -> Bool {
        let flag = payload["fade_in"] as? Bool

        if let minutes = (payload["fade_in_duration"] as? NSNumber)?.intValue {
            if minutes > 0 {
                alarm.customFadeInEnabled = true
                alarm.customFadeInDuration = min(minutes, 15)
            } else if flag == true {
                // 0 with the flag on is the picker's "30 sec" position.
                alarm.customFadeInEnabled = true
                alarm.customFadeInDuration = 0
            } else {
                alarm.customFadeInEnabled = false
                alarm.customFadeInDuration = nil
            }
            return true
        }

        if let flag {
            alarm.customFadeInEnabled = flag
            if !flag { alarm.customFadeInDuration = nil }
            return true
        }

        return false
    }

    /// Returns true when the payload carried the key.
    @discardableResult
    private func applyAfterAlarmActions(from payload: [String: Any], to alarm: Alarm) -> Bool {
        guard let raw = payload["after_alarm_actions"] else { return false }

        // Explicit empty array / null → no after-alarm steps at all. Recorded as
        // an empty ORDER rather than by clearing the config fields, so the
        // notes text and app links survive being switched off.
        if raw is NSNull {
            alarm.afterAlarmActions = []
            return true
        }
        guard let ids = raw as? [Any] else {
            AppLogger.shared.log("MQTT after_alarm_actions: expected an array of ids", category: .mqtt)
            return true
        }

        let parsed: [AfterAlarmAction] = ids.compactMap { element in
            guard let name = element as? String else { return nil }
            // Accept snake_case as well as the raw camelCase ids — an
            // automation author writing "app_link" alongside "morning_weather"
            // is making a reasonable guess, not a mistake.
            switch name.lowercased().replacingOccurrences(of: "_", with: "") {
            case "notes":   return .notes
            case "verse":   return .verse
            case "weather": return .weather
            case "applink": return .appLink
            default:
                AppLogger.shared.log("MQTT after_alarm_actions: unknown action '\(name)' ignored", category: .mqtt)
                return nil
            }
        }
        alarm.afterAlarmActions = parsed
        return true
    }

    /// Apply the per-action after-alarm TOGGLES — the single-boolean form of
    /// `after_alarm_actions`, for automations that want to switch one step on or
    /// off without having to restate the whole ordered list.
    ///
    /// `morning_weather` has always been that toggle for the weather card. This
    /// adds `verse_of_day` for the Verse of the Day step (`verse` accepted as an
    /// alias, matching the id used in `after_alarm_actions`), and closes a gap in
    /// the weather one.
    ///
    /// Runs AFTER `applyAfterAlarmActions` and after the config fields, so a
    /// payload carrying both an ordered list and a toggle gets the list it asked
    /// for with that one action adjusted — the more specific instruction wins.
    ///
    /// **Verse** has no config field of its own; its presence in the ordered list
    /// IS its enablement, so the toggle has to write the order. Enabling it on an
    /// alarm that never had an explicit order therefore freezes today's DERIVED
    /// list into an explicit one — which is why the weather half below exists.
    ///
    /// **Weather** already sets `showWeatherAfterAlarm` upstream, and the legacy
    /// derivation reads that flag. But an alarm with an explicit order (anything
    /// saved in the app's editor, anything that ever received
    /// `after_alarm_actions`, and now anything that received `verse_of_day`)
    /// ignores the flag: `Alarm.afterAlarmActions` reconciles `.notes` and
    /// `.appLink` against their config fields on read, but never `.weather`. So
    /// `morning_weather: true` on such an alarm set a flag nothing read — a
    /// silent no-op of exactly the kind this project has been bitten by before.
    /// Mirroring the flag into the order fixes that.
    ///
    /// Deliberately only when an explicit order ALREADY exists: writing one for a
    /// config-only automation would convert its alarm from derived to explicit
    /// behind its back, which is the one thing `applyAfterAlarmActions` is
    /// careful not to do.
    ///
    /// Returns true when the payload carried any toggle.
    @discardableResult
    private func applyAfterAlarmToggles(from payload: [String: Any], to alarm: Alarm) -> Bool {
        var carried = false

        if let verse = (payload["verse_of_day"] as? Bool) ?? (payload["verse"] as? Bool) {
            setAfterAlarmStep(.verse, enabled: verse, on: alarm)
            carried = true
        }

        if let weather = payload["morning_weather"] as? Bool, alarm.afterAlarmOrderData != nil {
            setAfterAlarmStep(.weather, enabled: weather, on: alarm)
            carried = true
        }

        return carried
    }

    /// Add or remove one step from the alarm's after-alarm order, leaving the
    /// rest of the sequence (and its ordering) alone. No-ops when the step is
    /// already in the requested state, so a repeated payload never rewrites the
    /// order data.
    private func setAfterAlarmStep(_ step: AfterAlarmAction, enabled: Bool, on alarm: Alarm) {
        var actions = alarm.afterAlarmActions
        if enabled {
            guard !actions.contains(step) else { return }
            actions.append(step)
        } else {
            guard actions.contains(step) else { return }
            actions.removeAll { $0 == step }
        }
        // The setter normalises (duplicates dropped, `.appLink` forced last).
        alarm.afterAlarmActions = actions
    }

    // MARK: - Radio station resolution (shared by create_alarm / update_alarm)

    /// Find a favourited station by the name or UUID an automation supplied.
    ///
    /// Three passes, most specific first, so nothing that resolved before can
    /// resolve differently:
    ///   1. case-insensitive exact name — the original behaviour
    ///   2. station UUID — the original behaviour
    ///   3. normalised name (`MQTTStrings.matchKey`)
    ///
    /// Pass 3 is the new one and it exists because the name does not survive the
    /// round trip unchanged. Station names come out of an open directory full of
    /// trailing spaces, doubled spaces, embedded newlines and zero-width
    /// characters; the app cleans them before publishing them to Home Assistant
    /// so the dropdown is usable, which means the value Home Assistant sends
    /// back is the CLEANED name, not the one stored in the favourite. Without
    /// this pass, picking a station from the dropdown the integration built for
    /// you would silently do nothing.
    ///
    /// `static` and pure so the payload tests can exercise the matching rules
    /// against a fixed list.
    static func favourite(matching needle: String, in favourites: [RadioStation]) -> RadioStation? {
        guard !needle.isEmpty else { return nil }
        if let byName = favourites.first(where: { $0.name.caseInsensitiveCompare(needle) == .orderedSame }) {
            return byName
        }
        if let byID = favourites.first(where: { $0.id == needle }) {
            return byID
        }
        let key = MQTTStrings.matchKey(needle)
        guard !key.isEmpty else { return nil }
        return favourites.first { MQTTStrings.matchKey($0.name) == key }
    }

    static func favourite(matching needle: String) -> RadioStation? {
        favourite(matching: needle, in: RadioPlayerManager.shared.favorites)
    }

    /// Resolve a `radio_station` payload value into the alarm's three stored
    /// fields, or clear them.
    ///
    /// Three accepted forms, resolved in this order:
    ///   1. **String** — the name of a favourited station (case-insensitive), or
    ///      a station UUID matched against favourites. Mirrors the by-name
    ///      pattern `swipe_left_command` already uses.
    ///   2. **Object with `url`** (plus optional `uuid` / `name`) — stored
    ///      verbatim, so Home Assistant can send any stream without it having to
    ///      be favourited first.
    ///   3. **`""` or `null`** — clears all three fields.
    ///
    /// Returns false when the payload carried no `radio_station` key at all, so
    /// callers can keep partial-update semantics.
    @discardableResult
    private func applyRadioStation(from payload: [String: Any], to alarm: Alarm) -> Bool {
        guard payload.keys.contains("radio_station") else { return false }
        let raw = payload["radio_station"]

        // Form 3 — explicit clear. A string of nothing but whitespace counts:
        // it used to fall through to the name lookup, match nothing and leave
        // the station alone, which is not what anyone typing a space into a
        // Home Assistant field meant.
        if raw == nil || raw is NSNull
            || (raw as? String).map({ MQTTStrings.trimmedForStorage($0).isEmpty }) == true {
            alarm.radioStationID = nil
            alarm.radioStationName = nil
            alarm.radioStationURL = nil
            AppLogger.shared.log("MQTT radio_station: cleared for '\(alarm.label)'", category: .mqtt)
            return true
        }

        // Form 1 — favourite by name or UUID.
        if let needle = raw as? String {
            guard let station = Self.favourite(matching: needle) else {
                // Deliberately non-fatal: the alarm is still created/updated, it
                // just keeps whatever station it had. A typo in an automation
                // should not cost you the alarm.
                AppLogger.shared.log(
                    "MQTT radio_station: no favourite matched '\(needle)' — station unchanged",
                    category: .mqtt
                )
                return true
            }
            alarm.radioStationID = station.id
            alarm.radioStationName = station.name
            alarm.radioStationURL = station.streamURL
            return true
        }

        // Form 2 — explicit object. `url` is the only required key.
        if let dict = raw as? [String: Any] {
            guard let url = (dict["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else {
                AppLogger.shared.log("MQTT radio_station: object form needs a non-empty `url`", category: .mqtt)
                return true
            }
            alarm.radioStationURL = url
            alarm.radioStationID = (dict["uuid"] as? String) ?? url
            alarm.radioStationName = (dict["name"] as? String) ?? "Radio"
            return true
        }

        AppLogger.shared.log("MQTT radio_station: unrecognised value type", category: .mqtt)
        return true
    }

    /// Build the FULL mission sequence from a `missions` array, or nil when the
    /// payload doesn't carry one.
    ///
    /// An alarm can require up to five missions in order, but MQTT could only
    /// ever describe the first — `mission` writes slot 1 and says nothing about
    /// the rest. That made `update_alarm` quietly wrong on any multi-mission
    /// alarm: setting `"mission": "math"` left the user's other slots in place,
    /// so the alarm still demanded three missions while HA reported one.
    ///
    /// Two accepted element shapes, so simple automations stay simple:
    ///   • a bare string — `"missions": ["math", "shake"]`
    ///   • an object in the same shape as the single-mission payload —
    ///     `"missions": [{"mission": "math", "mission_config": {…}}, …]`
    /// Elements past `maxMissionSlots` are dropped (logged, never silently
    /// truncated). An explicitly empty array means "no missions" and yields a
    /// single default Tap mission, which is how a missionless alarm is stored.
    /// `internal` rather than `private` so the MQTT payload tests can exercise
    /// the translation directly. Pure — no side effects, no persistence.
    func buildMissionSequence(from payload: [String: Any]) -> [Mission]? {
        guard let raw = payload["missions"] as? [Any] else { return nil }

        if raw.isEmpty { return [Mission()] }

        if raw.count > Self.maxMissionSlots {
            let dropped = raw.count - Self.maxMissionSlots
            AppLogger.shared.log(
                "MQTT missions: \(raw.count) supplied, using first \(Self.maxMissionSlots), dropped \(dropped)",
                category: .mqtt
            )
        }

        return raw.prefix(Self.maxMissionSlots).map { element in
            if let name = element as? String {
                return buildMission(from: ["mission": name])
            }
            if let dict = element as? [String: Any] {
                // Accept `type` as an alias for `mission` — an array element
                // reading `{"type": "math"}` is the more natural shape, and
                // rejecting it would be a pointless papercut.
                var normalized = dict
                if normalized["mission"] == nil, let type = dict["type"] {
                    normalized["mission"] = type
                }
                return buildMission(from: normalized)
            }
            return Mission()
        }
    }

    /// Apply a payload's mission fields to an alarm, covering both forms:
    ///   • `missions` (array) — replaces the ENTIRE sequence.
    ///   • `mission` (single) — replaces slot 1 AND clears slots 2..5.
    ///
    /// The single form clearing the extras is deliberate. "Set this alarm's
    /// mission to X" is what the field reads like from Home Assistant, it is what
    /// the `…/mission` state topic reports back, and leaving invisible extra
    /// slots behind produced an alarm that could not be dismissed the way the
    /// automation said it could. Automations that want to keep a multi-mission
    /// sequence should send `missions`.
    ///
    /// Returns true when the payload carried either field.
    @discardableResult
    /// `internal` rather than `private` so the MQTT payload tests can exercise
    /// the translation directly. Pure — no side effects, no persistence.
    func applyMissions(from payload: [String: Any], to alarm: Alarm) -> Bool {
        if let sequence = buildMissionSequence(from: payload), let first = sequence.first {
            alarm.mission = first
            alarm.extraMissions = Array(sequence.dropFirst())
            return true
        }
        if payload["mission"] != nil {
            alarm.mission = buildMission(from: payload)
            alarm.extraMissions = []
            return true
        }
        return false
    }

    /// Build a Mission struct from MQTT payload fields.
    /// `internal` rather than `private` so the MQTT payload tests can exercise
    /// the translation directly. Pure — no side effects, no persistence.
    func buildMission(from payload: [String: Any]) -> Mission {
        let missionTypeStr = (payload["mission"] as? String) ?? "none"
        let config = payload["mission_config"] as? [String: Any] ?? [:]
        
        var mission = Mission()
        
        switch missionTypeStr.lowercased() {
        case "shake":
            mission.type = .shake
            if let mode = config["shake_mode"] as? String {
                mission.shakeMode = mode.lowercased() == "count" ? .count : .duration
            }
            if let duration = (config["shake_duration"] as? NSNumber)?.intValue {
                mission.shakeDuration = duration
            }
            if let count = (config["shake_count"] as? NSNumber)?.intValue {
                mission.shakeCount = count
            }
            if let intensity = config["shake_intensity"] as? String {
                mission.shakeIntensity = mapShakeIntensity(intensity)
            }
            
        case "math":
            mission.type = .math
            if let count = (config["math_count"] as? NSNumber)?.intValue {
                mission.mathProblemCount = count
            }
            if let difficulty = config["math_difficulty"] as? String {
                mission.mathDifficulty = mapMathDifficulty(difficulty)
            }

        case "balance_ball":
            mission.type = .balanceBall
            if let difficulty = config["balance_difficulty"] as? String {
                mission.balanceDifficulty = mapBalanceDifficulty(difficulty)
            }
            if let hold = (config["balance_hold_duration"] as? NSNumber)?.doubleValue {
                mission.balanceHoldOverride = min(max(hold, 3), 120)
            }
            if let radius = (config["balance_zone_radius"] as? NSNumber)?.doubleValue {
                mission.balanceZoneRadiusOverride = min(max(radius, 24), 60)
            }
            if let dwell = (config["balance_zone_dwell"] as? NSNumber)?.doubleValue {
                mission.balanceZoneDwellOverride = min(max(dwell, 2), 10)
            }

        case "block_drop":
            mission.type = .blockDrop
            if let difficulty = config["block_drop_difficulty"] as? String {
                mission.blockDropDifficulty = mapBlockDropDifficulty(difficulty)
            }
            if let lines = (config["block_drop_lines"] as? NSNumber)?.intValue {
                mission.blockDropLinesOverride = min(max(lines, 1), 12)
            }
            if let interval = (config["block_drop_drop_interval"] as? NSNumber)?.doubleValue {
                mission.blockDropIntervalOverride = min(max(interval, 0.2), 1.5)
            }
            if let rows = (config["block_drop_prefilled_rows"] as? NSNumber)?.intValue {
                mission.blockDropGarbageRowsOverride = min(max(rows, 0), 8)
            }
            if let width = (config["block_drop_gap_width"] as? NSNumber)?.intValue {
                mission.blockDropGapWidthOverride = min(max(width, 1), 4)
            }
            if let aligned = config["block_drop_gaps_aligned"] as? Bool {
                mission.blockDropGapsAlignedOverride = aligned
            }

        case "meteor":
            mission.type = .meteor
            if let difficulty = config["meteor_difficulty"] as? String {
                mission.meteorDifficulty = MeteorDifficulty(rawValue: difficulty.capitalized) ?? .medium
            }
            if let targets = (config["meteor_targets"] as? NSNumber)?.intValue {
                mission.meteorTargetsOverride = min(max(targets, 3), 40)
            }
            if let interval = (config["meteor_fire_interval"] as? NSNumber)?.doubleValue {
                mission.meteorFireIntervalOverride = min(max(interval, 0.25), 1.5)
            }

        case "home_assistant":
            mission.type = .homeAssistant
            if let snoozeMode = config["ha_snooze_mode"] as? String {
                mission.haSnoozeMode = mapHASnoozeMode(snoozeMode)
            }
            // Dismiss fallback
            if let fallback = config["fallback_mission"] as? String {
                switch fallback.lowercased() {
                case "shake": mission.haFallbackMission = .shake
                case "math": mission.haFallbackMission = .math
                case "balance_ball": mission.haFallbackMission = .balanceBall
                case "block_drop": mission.haFallbackMission = .blockDrop
                case "meteor": mission.haFallbackMission = .meteor
                default: mission.haFallbackMission = .none
                }
            }
            // Fallback shake config
            if let mode = config["fallback_shake_mode"] as? String {
                mission.haFallbackShakeMode = mode.lowercased() == "count" ? .count : .duration
            }
            if let duration = (config["fallback_shake_duration"] as? NSNumber)?.intValue {
                mission.haFallbackShakeDuration = duration
            }
            if let count = (config["fallback_shake_count"] as? NSNumber)?.intValue {
                mission.haFallbackShakeCount = count
            }
            if let intensity = config["fallback_shake_intensity"] as? String {
                mission.haFallbackShakeIntensity = mapShakeIntensity(intensity)
            }
            // Fallback math config
            if let count = (config["fallback_math_count"] as? NSNumber)?.intValue {
                mission.haFallbackMathProblemCount = count
            }
            if let difficulty = config["fallback_math_difficulty"] as? String {
                mission.haFallbackMathDifficulty = mapMathDifficulty(difficulty)
            }
            // Fallback balance config
            if let difficulty = config["fallback_balance_difficulty"] as? String {
                mission.haFallbackBalanceDifficulty = mapBalanceDifficulty(difficulty)
            }
            // Fallback Bricks / Meteor config. Both are newly eligible as
            // fallbacks; each keeps its own difficulty so the fallback doesn't
            // silently run at the type's default.
            if let difficulty = config["fallback_block_drop_difficulty"] as? String {
                mission.haFallbackBlockDropDifficulty = mapBlockDropDifficulty(difficulty)
            }
            if let difficulty = config["fallback_meteor_difficulty"] as? String {
                mission.haFallbackMeteorDifficulty = MeteorDifficulty(rawValue: difficulty.capitalized) ?? .medium
            }
            // Fallback Tap config. A Tap fallback used to be a single tap with no
            // way to change it, even though the primary Tap mission has all three
            // knobs — so "tap 10 times" was configurable as a mission but not as
            // a backup.
            if let mode = config["fallback_tap_dismiss_mode"] as? String {
                mission.haFallbackTapDismissMode = mode.lowercased() == "hold" ? .hold : .tap
            }
            if let count = (config["fallback_tap_count"] as? NSNumber)?.intValue {
                mission.haFallbackTapCount = min(max(count, 1), 50)
            }
            if let hold = (config["fallback_tap_hold_duration"] as? NSNumber)?.doubleValue {
                mission.haFallbackTapHoldDuration = min(max(hold, 1), 10)
            }
            // Per-type fallback overrides, clamped to the SAME ranges as their
            // primary-mission counterparts above — anything settable on a mission
            // in the app is settable on a fallback over MQTT.
            if let lines = (config["fallback_block_drop_lines"] as? NSNumber)?.intValue {
                mission.haFallbackBlockDropLinesOverride = min(max(lines, 1), 12)
            }
            if let interval = (config["fallback_block_drop_drop_interval"] as? NSNumber)?.doubleValue {
                mission.haFallbackBlockDropIntervalOverride = min(max(interval, 0.2), 1.5)
            }
            if let rows = (config["fallback_block_drop_prefilled_rows"] as? NSNumber)?.intValue {
                mission.haFallbackBlockDropGarbageRowsOverride = min(max(rows, 0), 8)
            }
            if let width = (config["fallback_block_drop_gap_width"] as? NSNumber)?.intValue {
                mission.haFallbackBlockDropGapWidthOverride = min(max(width, 1), 4)
            }
            if let aligned = config["fallback_block_drop_gaps_aligned"] as? Bool {
                mission.haFallbackBlockDropGapsAlignedOverride = aligned
            }
            if let targets = (config["fallback_meteor_targets"] as? NSNumber)?.intValue {
                mission.haFallbackMeteorTargetsOverride = min(max(targets, 3), 40)
            }
            if let interval = (config["fallback_meteor_fire_interval"] as? NSNumber)?.doubleValue {
                mission.haFallbackMeteorFireIntervalOverride = min(max(interval, 0.25), 1.5)
            }
            if let hold = (config["fallback_balance_hold"] as? NSNumber)?.doubleValue {
                mission.haFallbackBalanceHoldOverride = min(max(hold, 1), 30)
            }
            // Grace period
            if let grace = (config["fallback_grace_period"] as? NSNumber)?.doubleValue {
                mission.haFallbackGracePeriod = grace
            }
            // Snooze fallback
            if let snoozeFallback = config["snooze_fallback"] as? String {
                mission.haSnoozeFallback = mapSnoozeMode(snoozeFallback).flatMap { SnoozeMode(rawValue: $0) } ?? .hold
            }
            if let holdDuration = (config["snooze_fallback_hold_duration"] as? NSNumber)?.doubleValue {
                mission.haSnoozeFallbackHoldDuration = holdDuration
            }
            
        default:
            mission.type = .none
            // Tap-dismiss params only apply to the Tap ("none") mission.
            if let mode = config["tap_dismiss_mode"] as? String {
                mission.tapDismissMode = mode.lowercased() == "hold" ? .hold : .tap
            }
            if let count = (config["tap_count"] as? NSNumber)?.intValue {
                mission.tapCount = min(max(count, 1), 50)
            }
            if let hold = (config["tap_hold_duration"] as? NSNumber)?.doubleValue {
                mission.tapHoldDuration = min(max(hold, 1), 10)
            }
        }

        return mission
    }
    
    // MARK: - Value Mappers
    
    /// `internal` rather than `private` so the MQTT payload tests can exercise
    /// the translation directly. Pure — no side effects, no persistence.
    func mapSnoozeMode(_ str: String) -> String? {
        switch str.lowercased() {
        case "tap": return SnoozeMode.tap.rawValue
        case "hold": return SnoozeMode.hold.rawValue
        case "home_assistant": return SnoozeMode.homeAssistant.rawValue
        case "disabled": return SnoozeMode.disabled.rawValue
        default: return nil
        }
    }
    
    /// `internal` rather than `private` so the MQTT payload tests can exercise
    /// the translation directly. Pure — no side effects, no persistence.
    func mapSkipMode(_ str: String) -> String? {
        switch str.lowercased() {
        case "tap": return SkipAlarmMode.tap.rawValue
        case "hold": return SkipAlarmMode.hold.rawValue
        case "disabled": return SkipAlarmMode.disabled.rawValue
        default: return nil
        }
    }
    
    /// `internal` rather than `private` so the MQTT payload tests can exercise
    /// the translation directly. Pure — no side effects, no persistence.
    func mapShakeIntensity(_ str: String) -> ShakeIntensity {
        switch str.lowercased() {
        case "light": return .light
        case "vigorous": return .vigorous
        default: return .medium
        }
    }
    
    /// `internal` rather than `private` so the MQTT payload tests can exercise
    /// the translation directly. Pure — no side effects, no persistence.
    func mapMathDifficulty(_ str: String) -> MathDifficulty {
        switch str.lowercased() {
        case "super_easy": return .superEasy
        case "medium": return .medium
        case "hard": return .hard
        default: return .easy
        }
    }
    
    private func mapBalanceDifficulty(_ str: String) -> BalanceDifficulty {
        switch str.lowercased() {
        case "easy": return .easy
        case "hard": return .hard
        default: return .medium
        }
    }

    private func mapBlockDropDifficulty(_ str: String) -> BlockDropDifficulty {
        switch str.lowercased() {
        case "easy": return .easy
        case "hard": return .hard
        default: return .medium
        }
    }

    private func mapHASnoozeMode(_ str: String) -> HASnoozeMode {
        switch str.lowercased() {
        case "math": return .math
        case "shake": return .shake
        case "home_assistant": return .homeAssistant
        default: return .normal
        }
    }
    
    // MARK: - Kill Snoozed Alarm
    
    func handlePerAlarmKillSnoozed(alarmIndex: Int) {
        guard let (alarm, context) = fetchAlarm(byIndex: alarmIndex) else { return }
        
        guard alarm.isSnoozed else {
            print("⚠️ Per-alarm kill_snoozed: alarm \(alarmIndex) is not snoozed")
            return
        }
        
        let settings = DeviceSettings.shared
        print("📥 Per-alarm kill_snoozed: alarm \(alarmIndex) (\(alarm.label))")
        
        // 1. Cancel snooze timer + AlarmKit snooze failsafe
        DualAlarmCoordinator.shared.cancelSnooze(for: alarm)
        
        // 2. Stop alarm notifications
        AlarmLiveActivityManager.shared.stopAlarmNotificationsInBackground()
        
        // 3. Reset snooze model state
        alarm.isSnoozed = false
        alarm.snoozeUntil = nil
        alarm.snoozeCount = 0
        
        // 4. For one-time alarms that already fired, disable them
        if !alarm.isRecurring {
            alarm.isEnabled = false
        }
        
        try? context.save()
        
        Task {
            // 5. Reschedule for next regular occurrence
            if alarm.isRecurring && alarm.isEnabled {
                await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
                print("📥 Cancel snooze: recurring alarm \(alarmIndex) rescheduled")
            } else if !alarm.isRecurring {
                await DualAlarmCoordinator.shared.cancelAlarm(alarm)
                print("📥 Cancel snooze: one-time alarm \(alarmIndex) disabled")
            }
            
            // 6. Update per-alarm MQTT state
            if settings.mqttEnabled {
                HAIntegrationRouter.shared.publishPerAlarmStateTransition(
                    alarmIndex: alarmIndex,
                    state: .idle,
                    snoozeAllowed: false,
                    settings: settings
                )
                HAIntegrationRouter.shared.publishPerAlarmSnoozesRemaining(
                    alarmIndex: alarmIndex,
                    remaining: 0,
                    settings: settings
                )
                HAIntegrationRouter.shared.publishPerAlarmSnoozeFireTime(
                    alarmIndex: alarmIndex,
                    snoozeUntil: nil,
                    settings: settings
                )
                
                // 7. Clear global state if this was the snoozed alarm
                if HAIntegrationRouter.shared.currentAlarmState == .snoozed {
                    HAIntegrationRouter.shared.publishAlarmState(.idle, settings: settings)
                    HAIntegrationRouter.shared.activeAlarmIndex = nil
                    HAIntegrationRouter.shared.publishActiveAlarmIndex(nil, settings: settings)
                    HAIntegrationRouter.shared.publishActiveAlarmName(nil, settings: settings)
                    HAIntegrationRouter.shared.publishActiveAlarmDays("none", settings: settings)
                    HAIntegrationRouter.shared.publishActiveAlarmFireTime(nil, settings: settings)
                    HAIntegrationRouter.shared.publishActiveAlarmSnoozeFireTime(nil, settings: settings)
                    HAIntegrationRouter.shared.publishActiveAlarmMission("none", settings: settings)
                    HAIntegrationRouter.shared.publishSnoozeCount(0, settings: settings)
                    HAIntegrationRouter.shared.publishSnoozesRemaining(0, settings: settings)
                }
            }
            
            // 8. Trigger full state refresh
            NotificationCenter.default.post(name: NSNotification.Name("AlarmStateChanged"), object: nil)
        }
    }
    
    // MARK: - Delete Quick Alarm
    
    /// Handle `delete_quick_alarm` command from HA.
    /// Deletes the next-to-fire pending quick (ephemeral) alarm.
    /// If multiple quick alarms are queued, only the soonest one is removed.
    func handleDeleteQuickAlarm() {
        guard let container = AlarmWindowManager.shared.modelContainer else {
            print("⚠️ delete_quick_alarm: no ModelContainer available")
            return
        }
        let context = container.mainContext
        guard let alarms = try? context.fetch(FetchDescriptor<Alarm>()) else {
            print("⚠️ delete_quick_alarm: failed to fetch alarms")
            return
        }
        
        // Find the soonest pending quick alarm
        let nextQuick = alarms
            .filter { !$0.isDetached && $0.isEphemeral && $0.isEnabled }
            .compactMap { alarm -> (alarm: Alarm, date: Date)? in
                guard let date = alarm.nextFireDate() else { return nil }
                return (alarm, date)
            }
            .min(by: { $0.date < $1.date })
        
        guard let (alarm, _) = nextQuick else {
            print("⚠️ delete_quick_alarm: no pending quick alarm found")
            return
        }
        
        print("📥 MQTT delete_quick_alarm: cancelling '\(alarm.label)'")
        AppLogger.shared.log("MQTT delete_quick_alarm: '\(alarm.label)'", category: .mqtt)
        
        isSuppressingAlarmAccess = true
        Task {
            await DualAlarmCoordinator.shared.cancelAlarm(alarm)
            await MainActor.run {
                context.delete(alarm)
                try? context.save()
                isSuppressingAlarmAccess = false
                lastDeleteTimestamp = Date()
                NotificationCenter.default.post(name: NSNotification.Name("AlarmStateChanged"), object: nil)
            }
        }
    }
    
    // MARK: - Set Theme

    /// Handle `set_theme` command.
    /// Payload keys:
    ///   - `theme`      (String) — theme name, case-insensitive (e.g. "Neon Silk", "coastal waters")
    ///   - `appearance` (String, optional) — "light", "dark", or "system"
    func handleSetTheme(payload: [String: Any]) {
        let settings = DeviceSettings.shared

        if let appearanceStr = payload["appearance"] as? String {
            let mapped: String
            switch appearanceStr.lowercased() {
            case "light": mapped = "light"
            case "dark": mapped = "dark"
            default: mapped = "system"
            }
            settings.appAppearance = mapped
            print("📥 MQTT set_theme: appearance → \(mapped)")
            AppLogger.shared.log("MQTT set_theme: appearance=\(mapped)", category: .mqtt)
        }

        guard let themeName = payload["theme"] as? String, !themeName.isEmpty else {
            return
        }

        let homePresets = settings.loadPresets()
        guard let homePreset = homePresets.first(where: { $0.name.lowercased() == themeName.lowercased() }) else {
            print("⚠️ MQTT set_theme: no theme named '\(themeName)'")
            AppLogger.shared.log("MQTT set_theme: unknown theme '\(themeName)'", category: .mqtt)
            return
        }

        settings.applyPreset(homePreset)

        let alarmPresets = settings.loadAlarmPresets()
        if let alarmPreset = alarmPresets.first(where: { $0.name.lowercased() == homePreset.name.lowercased() }) {
            settings.applyAlarmPreset(alarmPreset)
        }

        print("📥 MQTT set_theme: applied '\(homePreset.name)'")
        AppLogger.shared.log("MQTT set_theme: applied '\(homePreset.name)'", category: .mqtt)
        NotificationCenter.default.post(name: NSNotification.Name("AlarmStateChanged"), object: nil)
    }

    // MARK: - Media Alert Volume

    /// Handle `set_media_alert_volume` command from HA (e.g. media_player.volume_set).
    /// Payload: `{"volume": 0.75}` where volume is 0.0–1.0 (or 0–100).
    func handleSetMediaAlertVolume(payload: [String: Any]) {
        guard let volume = (payload["volume"] as? NSNumber)?.doubleValue else {
            print("⚠️ set_media_alert_volume: missing 'volume' field")
            return
        }
        let clamped = normalizeVolume(volume)
        DeviceSettings.shared.mediaAlertVolume = clamped
        print("📥 MQTT set_media_alert_volume: \(Int(clamped * 100))%")
        
        // Republish so the HACS sensor stays in sync
        let settings = DeviceSettings.shared
        if settings.mqttEnabled {
            MQTTManager.shared.publishMediaAlertVolume(clamped, settings: settings)
        }
    }
    
    // MARK: - Alert Configuration Commands
    
    /// Handle `alert_vibrate` switch command from HA. Payload: "ON" or "OFF".
    func handleAlertVibrateCommand(enabled: Bool) {
        DeviceSettings.shared.alertVibrationEnabled = enabled
        print("📥 MQTT alert_vibrate: \(enabled ? "on" : "off")")
        let settings = DeviceSettings.shared
        if settings.mqttEnabled {
            HAIntegrationRouter.shared.publishAlertVibrationEnabled(enabled, settings: settings)
        }
    }
    
    /// Handle `alert_loop_media` switch command from HA. Payload: "ON" or "OFF".
    func handleAlertLoopMediaCommand(enabled: Bool) {
        DeviceSettings.shared.alertLoopMedia = enabled
        print("📥 MQTT alert_loop_media: \(enabled ? "on" : "off")")
        let settings = DeviceSettings.shared
        if settings.mqttEnabled {
            HAIntegrationRouter.shared.publishAlertLoopMedia(enabled, settings: settings)
        }
    }
    
    // MARK: - App Persistence

    /// Parse a permissive on/off value.
    ///
    /// Accepts a JSON bool, a 0/1 number, and the string spellings that
    /// automations actually produce: a Home Assistant switch publishes `ON`, a
    /// template that stringifies a bool gives `True`, YAML turns a bare `on:`
    /// into `true`, and someone hand-writing a payload will type `1`. All of
    /// them plainly mean the same thing, and rejecting the wrong half would be
    /// a silent no-op — the exact failure `days` shipped with for months.
    ///
    /// Anything else returns `nil` so the caller can log and ignore rather than
    /// guess. Guessing is worse: an unrecognised value resolved to `false` would
    /// silently switch persistence OFF, which is the one direction the phone
    /// cannot recover from on its own.
    ///
    /// `internal` rather than `private` so the payload tests can exercise it
    /// directly, and `nonisolated` because `MQTTManager`'s message callback is
    /// not on the main actor and needs the answer before deciding whether to hop
    /// there. Pure — no side effects, no persistence.
    nonisolated static func parseOnOff(_ raw: Any?) -> Bool? {
        // A JSON `true`/`false` arrives as a bridged boolean and lands here.
        if let bool = raw as? Bool { return bool }
        // A JSON number arrives as NSNumber, and so does a Swift Int boxed into
        // `Any` by in-process callers — `as? Bool` bridges the first but not the
        // second, so the numeric case is handled explicitly rather than relying
        // on which of the two the value happened to come from. Compared against
        // 1 and 0 exactly: 2 is not "very on", it is a mistake, and a mistake
        // must resolve to nil.
        if let number = raw as? NSNumber {
            if number.doubleValue == 1 { return true }
            if number.doubleValue == 0 { return false }
            return nil
        }
        guard let string = raw as? String else { return nil }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on", "true", "1", "yes", "y", "enable", "enabled":
            return true
        case "off", "false", "0", "no", "n", "disable", "disabled":
            return false
        default:
            return nil
        }
    }

    /// Parse a three-way App Persistence value.
    ///
    /// STRICTLY ADDITIVE over `parseOnOff`: every payload that meant on or off
    /// before still resolves to `.on` / `.off` through exactly that function,
    /// so no accepted spelling changes meaning. Only after the on/off parse
    /// declines is `dynamic` considered — which is the only new word in the
    /// contract, matched case-insensitively and whitespace-trimmed like the
    /// rest.
    ///
    /// Anything else is still `nil`, for the same reason `parseOnOff` returns
    /// `nil`: an unrecognised value resolved to `.off` would suspend the app,
    /// and a suspended app cannot receive the command that would undo it.
    ///
    /// `internal` + `nonisolated` for the same reasons as `parseOnOff`. Pure —
    /// no side effects, no persistence.
    nonisolated static func parseAppPersistenceMode(_ raw: Any?) -> AppPersistenceMode? {
        // The existing on/off contract wins first and unchanged.
        if let onOff = parseOnOff(raw) { return onOff ? .on : .off }
        guard let string = raw as? String else { return nil }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "dynamic":
            return .dynamic
        default:
            return nil
        }
    }

    /// Handle `app_persistence` in its JSON form.
    ///
    /// Keys are tried in order: `enabled`, `state`, `value`, `app_persistence`,
    /// `persistence`. Several spellings because there is no cost to accepting
    /// the obvious synonyms and a real cost to picking the wrong one — the bare
    /// `ON`/`OFF` payload the HACS switch sends never reaches here at all
    /// (`MQTTManager` handles it before JSON parsing), so this path is
    /// hand-written automations, where people guess at key names.
    ///
    /// Each key's value goes through `parseAppPersistenceMode`, so the same
    /// shapes that carried `ON`/`OFF` now also carry `DYNAMIC`; nothing that
    /// worked before parses differently.
    func handleAppPersistenceCommand(payload: [String: Any]) {
        for key in ["enabled", "state", "value", "app_persistence", "persistence"] {
            if let desired = Self.parseAppPersistenceMode(payload[key]) {
                handleAppPersistenceCommand(mode: desired)
                return
            }
        }
        print("⚠️ MQTT app_persistence: no usable on/off/dynamic value in payload")
        AppLogger.shared.log(
            "MQTT app_persistence: no usable on/off/dynamic value in payload — ignoring",
            category: .mqtt
        )
        // Republish the current value anyway. A malformed command still deserves
        // an answer, and the honest answer is "nothing changed" — an automation
        // watching the state topic then sees the unchanged value instead of
        // timing out with no idea whether the phone heard anything at all.
        let settings = DeviceSettings.shared
        if settings.mqttEnabled {
            HAIntegrationRouter.shared.publishAppPersistence(
                settings.keepAliveNeeded, settings: settings
            )
            // Same acknowledgement, for an automation watching the raw mode
            // instead of effective residency.
            HAIntegrationRouter.shared.publishAppPersistenceMode(
                settings.appPersistenceMode, settings: settings
            )
        }
    }

    /// The boolean entry point, kept verbatim in meaning: `true` is `.on`,
    /// `false` is `.off`. Delegates so there is exactly one apply path.
    func handleAppPersistenceCommand(enabled: Bool) {
        handleAppPersistenceCommand(mode: enabled ? .on : .off)
    }

    /// Apply an App Persistence change requested from Home Assistant.
    ///
    /// Deliberately unconditional: assigning the value it already had still
    /// fires `DeviceSettings`' `didSet`, which republishes the state topic. That
    /// republish IS the acknowledgement — without it an automation cannot tell
    /// "already on" from "the phone never heard me", and those two need very
    /// different follow-up.
    ///
    /// The radio notice is re-armed on an on→off transition exactly as the
    /// Settings tiles do. Someone whose radio alarms just lost their station
    /// should be told, and it should not matter which surface turned persistence
    /// off — turning it off from a dashboard is if anything the case where the
    /// consequence is least visible.
    ///
    /// Keep-alive is applied from `settings.keepAliveNeeded` rather than from
    /// the mode directly, because under `.dynamic` residency is a property of
    /// charging and the pre-alarm window, not of the command —
    /// `DynamicPersistenceController.activate()` (kicked by the `didSet`) then
    /// settles it.
    func handleAppPersistenceCommand(mode: AppPersistenceMode) {
        let settings = DeviceSettings.shared
        if mode == .off && settings.appPersistenceMode != .off {
            settings.radioPersistenceNoticeAcknowledged = false
        }
        settings.appPersistenceMode = mode
        BackgroundAudioKeepAlive.shared.applyPersistenceChange(enabled: settings.keepAliveNeeded)
        print("📥 MQTT app_persistence: \(mode.rawValue)")
        AppLogger.shared.log("MQTT app_persistence: \(mode.rawValue)", category: .mqtt)
    }

    func handleAlertLoopDelayCommand(seconds: Double) {
        let clamped = min(max(seconds, 0), 60)
        DeviceSettings.shared.alertLoopDelay = clamped
        print("📥 MQTT alert_loop_delay: \(Int(clamped))s")
        let settings = DeviceSettings.shared
        if settings.mqttEnabled {
            HAIntegrationRouter.shared.publishAlertLoopDelay(clamped, settings: settings)
        }
    }
    
    #if DEBUG
    /// Test seam for `applyAfterAlarmActions`, which stays private because it
    /// mutates a model object. Exercised by MQTTAfterAlarmActionsTests.
    func handleAfterAlarmActionsForTesting(payload: [String: Any], alarm: Alarm) {
        applyAfterAlarmActions(from: payload, to: alarm)
    }

    /// Test seam for `applyAfterAlarmToggles`. Runs the array first and then the
    /// toggles, which is the order both `create_alarm` and `update_alarm` use —
    /// testing the toggle alone would miss the interaction that matters.
    func handleAfterAlarmTogglesForTesting(payload: [String: Any], alarm: Alarm) {
        if let morningWeather = payload["morning_weather"] as? Bool {
            alarm.showWeatherAfterAlarm = morningWeather
        }
        applyAfterAlarmActions(from: payload, to: alarm)
        applyAfterAlarmToggles(from: payload, to: alarm)
    }
    #endif

    #if DEBUG
    /// Test seam for `applyRadioStation`, which stays private because it mutates
    /// a model object. Exercised by MQTTRadioTests.
    func handleRadioStationForTesting(payload: [String: Any], alarm: Alarm) {
        applyRadioStation(from: payload, to: alarm)
    }
    #endif

    // MARK: - Radio Commands

    /// Resolve a `station` payload value the same three ways `radio_station`
    /// does on create/update: favourite name, favourite UUID, or an object with
    /// a `url`. Returns nil when nothing usable was supplied.
    private func resolveRadioStation(from payload: [String: Any]) -> RadioStation? {
        let raw = payload["station"]

        if let needle = raw as? String, !needle.isEmpty {
            return Self.favourite(matching: needle)
        }

        if let dict = raw as? [String: Any],
           let url = (dict["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty {
            return RadioStation(
                id: (dict["uuid"] as? String) ?? url,
                name: (dict["name"] as? String) ?? "Radio",
                streamURL: url,
                faviconURL: nil,
                country: "",
                tags: "",
                codec: "",
                bitrate: 0
            )
        }
        return nil
    }

    /// `radio_start` — begin playback, optionally with a sleep timer.
    ///
    /// Payload keys:
    ///   - `station`           (String|Object) — favourite name/uuid, or `{url, uuid?, name?}`
    ///   - `volume`            (Number 0–100)  — system volume, optional
    ///   - `duration_minutes`  (Number)        — stop after N minutes (max 720)
    ///   - `until_next_alarm`  (Bool)          — play until the next alarm fires
    ///   - `fade_out_minutes` / `fade_out_seconds` (Number) — fade before stopping
    func handleRadioStart(payload: [String: Any]) {
        guard let station = resolveRadioStation(from: payload) else {
            AppLogger.shared.log("radio_start: no usable `station` in payload", category: .mqtt)
            return
        }

        // `volume` is the PLAYER level and `system_volume` the hardware level —
        // the same split `sleep_sound_start` uses. They were reversed here, so a
        // `volume` meant for the stream moved the device's media slider instead.
        //
        // With no volume supplied, adopt the sleep-sound level rather than
        // leaving RadioPlayerManager on its 1.0 default: the two are one
        // "sleep audio" level to the user, and starting a station from Home
        // Assistant used to blast at 100% while sleep sounds started at 50%.
        let playerVolume: Double
        if let raw = (payload["volume"] as? NSNumber)?.doubleValue {
            playerVolume = normalizeVolume(raw)
        } else {
            playerVolume = SleepSoundManager.shared.volume
        }
        RadioPlayerManager.shared.setVolume(Float(playerVolume))

        if let rawSystem = (payload["system_volume"] as? NSNumber)?.doubleValue {
            VolumeManager.shared.setSystemVolumeQuietly(to: Float(normalizeVolume(rawSystem)))
        }

        // `play` refuses while an alarm is ringing (its own `shouldBePlaying`
        // guard); honour that rather than fighting it.
        guard RadioPlayerManager.shared.play(station: station) else {
            AppLogger.shared.log("radio_start: refused — '\(station.name)' (alarm ringing?)", category: .mqtt)
            return
        }
        AppLogger.shared.log("radio_start: '\(station.name)'", category: .mqtt)

        // Keep Home Assistant's Sleep Volume in step — it is the same control.
        if DeviceSettings.shared.mqttEnabled {
            HAIntegrationRouter.shared.publishSleepSoundVolume(playerVolume, settings: DeviceSettings.shared)
        }

        let (end, fadeOut) = Self.sleepTimerSpec(from: payload)
        if end != nil || fadeOut > 0 {
            RadioPlayerManager.shared.setSleepTimer(end: end, fadeOut: fadeOut)
        }
        publishRadioStateIfEnabled()
    }

    func handleRadioStop(payload: [String: Any]) {
        RadioPlayerManager.shared.stop()
        AppLogger.shared.log("radio_stop", category: .mqtt)
        publishRadioStateIfEnabled()
    }

    func handleRadioPause(payload: [String: Any]) {
        RadioPlayerManager.shared.pause()
        AppLogger.shared.log("radio_pause", category: .mqtt)
        publishRadioStateIfEnabled()
    }

    func handleRadioResume(payload: [String: Any]) {
        RadioPlayerManager.shared.resume()
        AppLogger.shared.log("radio_resume", category: .mqtt)
        publishRadioStateIfEnabled()
    }

    private func publishRadioStateIfEnabled() {
        let settings = DeviceSettings.shared
        guard settings.mqttEnabled else { return }
        HAIntegrationRouter.shared.publishRadioState(settings: settings)
    }

    /// Shared duration / until-next-alarm / fade parsing.
    ///
    /// Extracted rather than copied from `handleSleepSoundStart`: the two
    /// commands take the same three shapes, and the plan called this out
    /// specifically so the sleep-sound contract and the radio one can't drift.
    /// Returns the stop date (nil = indefinite) and the fade-out in seconds.
    static func sleepTimerSpec(from payload: [String: Any]) -> (end: Date?, fadeOut: TimeInterval) {
        var fadeOut: TimeInterval = 0
        if let v = (payload["fade_out_seconds"] as? NSNumber)?.doubleValue {
            fadeOut = max(v, 0)
        } else if let v = (payload["fade_out_minutes"] as? NSNumber)?.doubleValue {
            fadeOut = max(v, 0) * 60
        }

        if let untilNext = payload["until_next_alarm"] as? Bool, untilNext {
            if let container = AlarmWindowManager.shared.modelContainer {
                let alarms = (try? container.mainContext.fetch(FetchDescriptor<Alarm>())) ?? []
                let next = alarms
                    .filter { !$0.isDetached && $0.isEnabled && !$0.isSkipped && !$0.isSnoozed }
                    .compactMap { $0.nextFireDate() }
                    .min()
                return (next, fadeOut)
            }
            return (nil, fadeOut)
        }

        if let minutes = (payload["duration_minutes"] as? NSNumber)?.doubleValue, minutes > 0 {
            return (Date().addingTimeInterval(min(minutes, 720) * 60), fadeOut)
        }
        return (nil, fadeOut)
    }

    // MARK: - Sleep Sound Commands
    
    /// Handle `sleep_sound_start` command.
    /// Payload keys:
    ///   - `sound`            (String)  — sound file name without extension (e.g. "Brown_Noise")
    ///   - `volume`           (Number)  — 0–100; controls sleep sound playback volume only
    ///   - `system_volume`    (Number)  — 0–100 (optional); sets the iOS device system/media volume
    ///   - `duration_minutes` (Number)  — play for N minutes (max 720 = 12 h); omit for indefinite
    ///   - `until_next_alarm` (Bool)    — if true, play until the next scheduled alarm fires
    ///   - `fade_out_minutes` (Number)  — fade-out duration in minutes (converted to seconds)
    ///   - `fade_out_seconds` (Number)  — fade-out duration in seconds (takes precedence over minutes if both supplied)
    ///   - `sync_interval`    (Number)  — each phone independently computes the next N-second
    ///                                    boundary and starts there. Phones agree as long as both
    ///                                    receive the command within the same N-second window.
    ///                                    Use an interval larger than the expected gap between
    ///                                    triggers (e.g. 120 for manual triggering ~1 min apart).
    ///
    /// Note: `volume` controls only the sleep sound level within the app. `system_volume` controls
    /// the hardware media volume (shared with music, podcasts, etc.) and is independent of `volume`.
    func handleSleepSoundStart(payload: [String: Any]) {
        // --- Sound name ---
        let soundName: String
        if let s = payload["sound"] as? String, !s.isEmpty {
            // Try resolving as a custom sleep sound MQTT name (e.g. "My_Rain_Mix")
            if let custom = CustomSoundManager.shared.soundByMQTTName(s, category: .sleepSound) {
                soundName = custom.id
            } else {
                soundName = s
            }
        } else {
            // Default to first available sound
            let available = SleepSoundManager.availableSounds()
            guard !available.isEmpty else {
                print("⚠️ sleep_sound_start: no sounds available")
                return
            }
            soundName = available[0]
        }
        
        // --- Volume (always 0–100 scale to match mqtt-builder) ---
        let clampedVolume: Double
        if let raw = (payload["volume"] as? NSNumber)?.doubleValue {
            clampedVolume = min(max(raw / 100.0, 0.0), 1.0)
        } else {
            clampedVolume = 0.5
        }
        
        // --- Fade-out duration ---
        var fadeOutSeconds: TimeInterval = 0
        if let fos = payload["fade_out_seconds"] as? Double {
            fadeOutSeconds = max(fos, 0)
        } else if let fos = payload["fade_out_seconds"] as? Int {
            fadeOutSeconds = TimeInterval(fos)
        } else if let fom = payload["fade_out_minutes"] as? Double {
            fadeOutSeconds = max(fom, 0) * 60
        } else if let fom = payload["fade_out_minutes"] as? Int {
            fadeOutSeconds = TimeInterval(fom) * 60
        }
        
        // --- Mode ---
        let mode: SleepSoundMode
        
        if let untilNext = payload["until_next_alarm"] as? Bool, untilNext {
            // Find the next upcoming enabled alarm
            if let container = AlarmWindowManager.shared.modelContainer {
                let context = container.mainContext
                let alarms = (try? context.fetch(FetchDescriptor<Alarm>())) ?? []
                let nextAlarm = alarms
                    .filter { !$0.isDetached && $0.isEnabled && !$0.isSkipped && !$0.isSnoozed }
                    .compactMap { alarm -> (alarm: Alarm, date: Date)? in
                        guard let date = alarm.nextFireDate() else { return nil }
                        return (alarm, date)
                    }
                    .min(by: { $0.date < $1.date })
                if let (_, date) = nextAlarm {
                    mode = .until(date)
                    print("📥 sleep_sound_start: until next alarm at \(date)")
                } else {
                    mode = .indefinite
                    print("📥 sleep_sound_start: no upcoming alarm found, playing indefinitely")
                }
            } else {
                mode = .indefinite
                print("⚠️ sleep_sound_start: no ModelContainer for until_next_alarm, playing indefinitely")
            }
        } else if let minutes = payload["duration_minutes"] as? Double, minutes > 0 {
            let clamped = min(minutes, 720) // max 12 hours
            mode = .duration(clamped * 60)
            print("📥 sleep_sound_start: \(soundName) for \(Int(clamped)) min")
        } else if let minutes = payload["duration_minutes"] as? Int, minutes > 0 {
            let clamped = min(Double(minutes), 720)
            mode = .duration(clamped * 60)
            print("📥 sleep_sound_start: \(soundName) for \(Int(clamped)) min")
        } else {
            mode = .indefinite
            print("📥 sleep_sound_start: \(soundName) indefinitely")
        }
        
        // --- System Volume (optional) ---
        if let rawSysVol = (payload["system_volume"] as? NSNumber)?.doubleValue {
            let clampedSysVol = Float(min(max(rawSysVol / 100.0, 0.0), 1.0))
            VolumeManager.shared.setSystemVolumeQuietly(to: clampedSysVol)
            AppLogger.shared.log("sleep_sound_start: system volume set to \(Int(min(max(rawSysVol, 0), 100)))%", category: .audio)
        }

        // --- Sync start (optional) ---
        // sync_interval: each phone independently picks the next N-second boundary.
        // Both phones agree when triggered within the same N-second window — use N
        // larger than the expected gap between triggers (120 s for manual triggering).
        // Uses floor(now/N)+1 so the target is always a full interval ahead,
        // avoiding the near-zero prep-time edge case that ceil() can produce.
        let scheduledStart: Date?
        if let intervalSecs = (payload["sync_interval"] as? NSNumber)?.doubleValue, intervalSecs >= 5 {
            let now = Date().timeIntervalSince1970
            let boundary = (floor(now / intervalSecs) + 1) * intervalSecs
            scheduledStart = Date(timeIntervalSince1970: boundary)
            AppLogger.shared.log("sleep_sound_start: sync_interval=\(Int(intervalSecs))s, target in \(String(format: "%.1f", boundary - now))s", category: .audio)
        } else {
            scheduledStart = nil
        }

        SleepSoundManager.shared.start(
            soundName: soundName,
            volume: clampedVolume,
            mode: mode,
            fadeOutDuration: fadeOutSeconds,
            scheduledStart: scheduledStart
        )
    }
    
    /// Handle `sleep_sound_stop` command.
    func handleSleepSoundStop() {
        print("📥 sleep_sound_stop")
        SleepSoundManager.shared.stop()
    }
    
    /// Handle `sleep_sound_pause` command.
    func handleSleepSoundPause() {
        print("📥 sleep_sound_pause")
        SleepSoundManager.shared.pause()
    }
    
    /// Handle `sleep_sound_resume` command.
    func handleSleepSoundResume() {
        print("📥 sleep_sound_resume")
        SleepSoundManager.shared.resume()
    }
    
    /// Handle `sleep_sound_set_volume` command.
    /// Payload keys:
    ///   - `volume` (Number) — 0–100 scale
    func handleSleepSoundSetVolume(payload: [String: Any]) {
        guard let raw = (payload["volume"] as? NSNumber)?.doubleValue else {
            print("⚠️ sleep_sound_set_volume: missing volume field")
            return
        }
        let clamped = min(max(raw / 100.0, 0.0), 1.0)
        print("📥 sleep_sound_set_volume: \(Int(clamped * 100))%")

        // Route to whatever is actually playing. Sleep sounds and radio are two
        // sources for one "sleep audio" slider — the in-app slider has always
        // driven both (SleepSoundSetupView picks by `isActive`), but this
        // command only ever reached SleepSoundManager, so Home Assistant could
        // not change the volume of a playing station at all.
        if RadioPlayerManager.shared.isActive {
            RadioPlayerManager.shared.setVolume(Float(clamped))
        } else {
            SleepSoundManager.shared.setVolume(clamped)
        }

        if DeviceSettings.shared.mqttEnabled {
            HAIntegrationRouter.shared.publishSleepSoundVolume(clamped, settings: DeviceSettings.shared)
        }
    }

    /// Handle `set_system_volume` command — sets the iOS device's media output volume.
    /// Payload keys:
    ///   - `volume` (Number) — 0–100 scale
    func handleSetSystemVolume(payload: [String: Any]) {
        guard let raw = (payload["volume"] as? NSNumber)?.doubleValue else {
            print("⚠️ set_system_volume: missing volume field")
            return
        }
        let clamped = min(max(raw / 100.0, 0.0), 1.0)
        print("📥 set_system_volume: \(Int(clamped * 100))%")
        VolumeManager.shared.setSystemVolumeQuietly(to: Float(clamped))
    }
    
    /// Handle `sleep_sound_change` command — cross-fades to a new sound without stopping.
    /// Payload keys:
    ///   - `sound` (String) — sound file name without extension
    func handleSleepSoundChange(payload: [String: Any]) {
        guard let s = payload["sound"] as? String, !s.isEmpty else {
            print("⚠️ sleep_sound_change: missing sound field")
            return
        }
        // Resolve custom sleep sound by MQTT name if needed
        let soundName: String
        if let custom = CustomSoundManager.shared.soundByMQTTName(s, category: .sleepSound) {
            soundName = custom.id
        } else {
            soundName = s
        }
        print("📥 sleep_sound_change: \(soundName)")
        SleepSoundManager.shared.changeSound(to: soundName)
    }
    
}
