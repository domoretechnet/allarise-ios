//
//  AlarmLiveActivityManager.swift
//  HaWake Alarm V2
//
//  Manages recurring alarm notifications for lock-screen presence,
//  system vibration, and Apple Watch haptic mirroring while an alarm
//  is ringing.
//
//  A single notification serves all three purposes:
//  - Lock-screen banner (keeps the alarm visible)
//  - Silent sound triggers Apple Watch notification mirroring → haptic
//  - Phone vibration via AudioServicesPlaySystemSound
//
//  Notifications use two alternating IDs ("even"/"odd") so each delivery
//  appears as a new notification to Watch (triggering a fresh haptic),
//  while the previous one is removed to prevent pileup.
//

import AudioToolbox
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class AlarmLiveActivityManager {
    static let shared = AlarmLiveActivityManager()

    /// Whether the current alarm's vibration is enabled.
    /// When true, system vibration fires on every tick.
    /// When false, only silent lock-screen notifications are sent.
    var vibrationEnabled: Bool = true

    /// When true, lock-screen notifications are suppressed but vibration still fires.
    /// Set in AlarmKit primary mode — AlarmKit provides its own persistent system notification,
    /// so additional recurring notifications are redundant and create noise.
    var suppressLockScreenNotifications: Bool = false

    /// Tracked for notification content.
    private var currentAlarmLabel: String = ""
    private var currentAlarmID: Int = 0

    /// Notification timer — fires recurring local notifications for lock-screen presence.
    private var notificationTimer: Timer?
    private var notificationCounter: Int = 0

    /// Two alternating notification IDs. Each tick removes the previous and adds the
    /// next, so Watch sees a "new" notification (→ haptic) without pileup.
    private static let notificationIDs = ["alarm_notif_even", "alarm_notif_odd"]

    /// Name of the silent WAV in Library/Sounds used for Watch haptic mirroring.
    private static let silentSoundFileName = "watch-haptic-silent.wav"

    /// Whether alarm notifications are currently running.
    var hasActiveNotifications: Bool {
        notificationTimer != nil
    }

    private init() {
        createSilentSoundIfNeeded()
    }

    // MARK: - Public API

    /// Start sending recurring alarm notifications for lock-screen presence
    /// and system vibration.
    /// Call when an alarm starts ringing or when snooze ends.
    func startAlarmNotifications(alarmLabel: String, alarmID: Int) {
        // Don't start if already running
        guard notificationTimer == nil else {
            print("🔔 Alarm notifications already running")
            return
        }

        // AlarmKit is failsafe-only — always show lock-screen notifications.

        currentAlarmLabel = alarmLabel
        currentAlarmID = alarmID
        notificationCounter = 0
        print("🔔 Starting alarm notifications for: \(alarmLabel) (suppress=\(suppressLockScreenNotifications))")
        AppLogger.shared.log("Alarm notifications STARTED: '\(alarmLabel)' alarmID=\(alarmID) suppress=\(suppressLockScreenNotifications)", category: .notification)

        // Send first notification immediately
        sendAlarmNotification()

        // Vibrate immediately
        tickVibration()

        // Then every 6 seconds — handles both notifications and vibration.
        // 6s is frequent enough for haptic feedback without flooding notification center.
        let timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in

                // Stop if alarm is no longer showing
                if !AlarmWindowManager.shared.isShowingAlarm {
                    print("🔔 Alarm notifications: alarm no longer showing — stopping")
                    AppLogger.shared.log("Alarm notifications auto-stopped: alarm no longer showing", category: .notification)
                    self.stopAlarmNotifications()
                    return
                }

                AppLogger.shared.log("Alarm notification tick #\(self.notificationCounter + 1): '\(self.currentAlarmLabel)' isShowing=\(AlarmWindowManager.shared.isShowingAlarm)", category: .notification)
                self.sendAlarmNotification()
                self.tickVibration()

                // Watchdog: recover alarm audio that an interruption silenced
                // without delivering .ended (observed on the iOS 27 beta when
                // notification sounds play over the alarm session).
                AlarmSoundPlayer.shared.resumeIfSilenced(reason: "notification tick #\(self.notificationCounter)")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        notificationTimer = timer
    }

    /// Stop alarm notifications and clean up delivered notifications.
    func stopAlarmNotifications() {
        notificationTimer?.invalidate()
        notificationTimer = nil
        notificationCounter = 0
        suppressLockScreenNotifications = false

        // Remove both alternating notification IDs (pending + delivered)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: Self.notificationIDs)
        center.removePendingNotificationRequests(withIdentifiers: Self.notificationIDs)
        print("🔔 Alarm notifications stopped")
        AppLogger.shared.log("Alarm notifications STOPPED", category: .notification)
    }

    /// Convenience for synchronous call sites (dismiss/snooze closures).
    func stopAlarmNotificationsInBackground() {
        stopAlarmNotifications()
    }

    // MARK: - Vibration

    /// Trigger system vibration if conditions are met.
    /// Uses AudioServicesPlaySystemSound which works reliably from the
    /// lock screen when an audio session (.playAndRecord) is active.
    private func tickVibration() {
        guard vibrationEnabled else { return }

        // Respect grace period — no vibration while mission screen is muted
        if AlarmWindowManager.shared.isGracePeriodMuted { return }

        // kSystemSoundID_Vibrate (4095) triggers the Taptic Engine.
        // Works from background/lock screen when .playAndRecord audio session is active.
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        print("📳 System vibration triggered")
    }

    // MARK: - Private (Notifications)

    /// Send a single alarm notification for lock-screen presence and Watch haptic mirroring.
    /// Uses alternating IDs so Watch treats each as a new notification (triggering a haptic)
    /// while the previous one is removed to prevent pileup.
    private func sendAlarmNotification() {
        notificationCounter += 1

        let center = UNUserNotificationCenter.current()

        // Remove the PREVIOUS notification before adding the new one.
        // Alternating between two IDs ensures Watch sees each as "new".
        let previousID = Self.notificationIDs[(notificationCounter + 1) % 2]
        let currentID = Self.notificationIDs[notificationCounter % 2]
        center.removeDeliveredNotifications(withIdentifiers: [previousID])
        center.removePendingNotificationRequests(withIdentifiers: [previousID])

        let message = LiveAlarmScheduler.randomNotificationMessage(alarmLabel: currentAlarmLabel)
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = "ALARM_CATEGORY"
        content.userInfo = ["alarmID": currentAlarmID, "isWatchHaptic": true]

        // Silent sound triggers Watch notification mirroring → haptic buzz.
        // The WAV is inaudible on iPhone. Skippable via Diagnostics because a
        // notification sound can interrupt the alarm's audio session on the
        // iOS 27 beta.
        let soundAttached = !DeviceSettings.shared.notifTickSoundDisabled
        if soundAttached {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: Self.silentSoundFileName))
        }

        let request = UNNotificationRequest(
            identifier: currentID,
            content: content,
            trigger: nil  // Deliver immediately
        )

        let counter = notificationCounter
        let label = currentAlarmLabel
        center.add(request) { error in
            if let error {
                print("🔔 Alarm notification #\(counter): failed — \(error.localizedDescription)")
                Task { @MainActor in
                    AppLogger.shared.log("Alarm notification #\(counter) FAILED: \(error.localizedDescription)", category: .notification)
                }
            } else {
                print("🔔 Alarm notification #\(counter): sent for \(label)")
                Task { @MainActor in
                    AppLogger.shared.log("Alarm notification #\(counter) sent (sound=\(soundAttached))", category: .notification)
                }
            }
        }
    }

    // MARK: - Silent Sound Setup

    /// Write a minimal silent WAV to Library/Sounds so UNNotificationSound can find it.
    /// This triggers Watch notification mirroring without audible sound on iPhone.
    private func createSilentSoundIfNeeded() {
        guard let libraryURL = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first else { return }

        let soundsDir = libraryURL.appendingPathComponent("Sounds")
        let soundFile = soundsDir.appendingPathComponent(Self.silentSoundFileName)
        guard !FileManager.default.fileExists(atPath: soundFile.path) else { return }

        try? FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)

        // Minimal silent WAV: 8 kHz, 16-bit, mono, 0.1 s
        let sampleRate:   UInt32 = 8000
        let numSamples:   UInt32 = 800
        let numChannels:  UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = numSamples * UInt32(numChannels) * UInt32(bitsPerSample / 8)

        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
            withUnsafeBytes(of: v.littleEndian, Array.init)
        }

        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        wav.append(contentsOf: le(dataSize + 36))
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(contentsOf: le(UInt32(16)))
        wav.append(contentsOf: le(UInt16(1)))
        wav.append(contentsOf: le(numChannels))
        wav.append(contentsOf: le(sampleRate))
        wav.append(contentsOf: le(sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)))
        wav.append(contentsOf: le(numChannels * (bitsPerSample / 8)))
        wav.append(contentsOf: le(bitsPerSample))
        wav.append(contentsOf: "data".utf8)
        wav.append(contentsOf: le(dataSize))
        wav.append(Data(count: Int(dataSize)))

        try? wav.write(to: soundFile)
    }

    // MARK: - Helper

    /// Format an alarm time for display.
    static func formatAlarmTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
