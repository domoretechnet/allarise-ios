//
//  AppLifecycleMonitor.swift
//  HaWake Alarm V2
//
//  Monitors app lifecycle and warns user when app closes with background refresh disabled
//

import AVFoundation
import Combine
import SwiftUI
import UserNotifications

@MainActor
class AppLifecycleMonitor: ObservableObject {
    static let shared = AppLifecycleMonitor()

    static let forceCloseNotificationID = "app_force_close_warning"
    static let forceCloseReminderNotificationID = "app_force_close_reminder"

    @Published var isAppActive = true
    private var hasActiveAlarms = false

    /// True while the system audio session is interrupted by another app (phone
    /// call, Siri, FaceTime, alarm from another app). During an interruption the
    /// force-close notifications are cancelled and no new ones are scheduled —
    /// otherwise the user would see the "App is no Longer Running!" banner every
    /// time they take a phone call that lasts longer than 60 seconds, even
    /// though the app wasn't actually force-closed.
    private var audioInterrupted = false
    
    /// Non-isolated accessor for use from applicationWillTerminate
    /// (which runs on the main thread but outside @MainActor context).
    nonisolated var hasActiveAlarmsForTermination: Bool {
        MainActor.assumeIsolated { hasActiveAlarms }
    }
    
    // MARK: - Foreground Timestamp Persistence
    
    private let foregroundTimestampsKey = "AppLifecycleMonitor.foregroundTimestamps"
    private let foregroundRollingWindowDays = 7
    
    /// Persisted foreground timestamps (rolling 7-day window)
    private(set) var storedForegroundTimestamps: [Date] = []
    
    private init() {
        loadForegroundTimestamps()
        observeAudioInterruptions()
    }

    /// Observes audio session interruptions so the force-close notifications
    /// can be suppressed during phone calls, Siri sessions, FaceTime, etc.
    private func observeAudioInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleAudioInterruption(notification)
            }
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            // Phone call, Siri, FaceTime, another app's alarm, etc. The app is
            // still alive but iOS has taken the audio session from us. Clear
            // pending force-close notifications so they don't fire during the
            // interruption, and set a flag so the reschedule timer stops
            // pushing new ones until the interruption ends.
            audioInterrupted = true
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [
                Self.forceCloseNotificationID,
                Self.forceCloseReminderNotificationID
            ])
            print("📱 Force-close heartbeat: paused (audio interruption began — likely phone call)")
            AppLogger.shared.log("Force-close heartbeat paused (audio interruption began)", category: .general)
        case .ended:
            audioInterrupted = false
            // If the heartbeat timer is still running, the app is still
            // backgrounded. Push a fresh set of notifications so the timer's
            // normal rhythm resumes. If the timer isn't running (app was
            // foregrounded while interrupted), do nothing — returning to the
            // foreground will have cancelled everything already.
            if forceCloseRescheduleTimer != nil {
                pushForceCloseNotification()
                print("📱 Force-close heartbeat: resumed (audio interruption ended)")
                AppLogger.shared.log("Force-close heartbeat resumed (audio interruption ended)", category: .general)
            }
        @unknown default:
            break
        }
    }
    
    /// Call this when scene phase changes
    func handleScenePhase(_ phase: ScenePhase, hasAlarms: Bool) {
        hasActiveAlarms = hasAlarms
        
        switch phase {
        case .active:
            isAppActive = true
            print("📱 App became active")
            AppLogger.shared.log("App became active", category: .general)
            
            // Record foreground timestamp for sleep detection
            recordForegroundTimestamp()
            
            // Cancel the force-close warning — app is running again
            cancelForceCloseNotification()
            
        case .inactive:
            isAppActive = false
            print("📱 App became inactive")
            AppLogger.shared.log("App became inactive", category: .general)
            
        case .background:
            isAppActive = false
            print("📱 App entered background")
            AppLogger.shared.log("App entered background", category: .general)
            
            // Check if background refresh is disabled and we have active alarms
            Task {
                await checkBackgroundRefreshAndWarn()
            }
            
            // Arm (or stand down) the force-close warning that fires if the
            // app is killed while it should have stayed resident
            reconcileForceCloseHeartbeat()
            
        @unknown default:
            break
        }
    }
    
    /// Check background refresh status and send notification if disabled
    private func checkBackgroundRefreshAndWarn() async {
        // Background App Refresh powers the BGAppRefreshTask ladder — Dynamic's
        // pre-alarm wake-up and On's force-kill recovery. With persistence Off
        // alarms are pure AlarmKit, which doesn't need it, so "Alarms May Not
        // Ring" would be false. Mode, not keepAliveNeeded: Dynamic needs the
        // ladder precisely while NON-resident.
        if DeviceSettings.shared.appPersistenceMode == .off {
            print("⚠️ Background refresh warning: skipped (App Persistence is off — AlarmKit doesn't need it)")
            return
        }

        let backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
        
        // Enhanced debug logging
        print("═══════════════════════════════════════")
        print("🔍 BACKGROUND REFRESH CHECK")
        print("═══════════════════════════════════════")
        print("📊 Status: \(backgroundRefreshStatus.description)")
        print("📊 Raw Value: \(backgroundRefreshStatus.rawValue)")
        print("📊 Has Active Alarms: \(hasActiveAlarms)")
        
        // Detailed status breakdown
        switch backgroundRefreshStatus {
        case .available:
            print("✅ Background Refresh: ENABLED")
            print("💡 No warning needed - alarms will work")
        case .denied:
            print("❌ Background Refresh: DENIED by user")
            print("⚠️ Alarms may not work reliably!")
        case .restricted:
            print("🔒 Background Refresh: RESTRICTED (parental controls)")
            print("⚠️ Alarms may not work reliably!")
        @unknown default:
            print("❓ Background Refresh: UNKNOWN status")
        }
        
        print("═══════════════════════════════════════")
        
        // Only warn if:
        // 1. Background refresh is disabled
        // 2. User has active alarms
        guard backgroundRefreshStatus != .available, hasActiveAlarms else {
            if backgroundRefreshStatus == .available {
                print("✅ Background refresh is available - no warning needed")
            } else {
                print("⚠️ Background refresh disabled but no active alarms - skipping warning")
            }
            return
        }
        
        print("🚨 SENDING BACKGROUND REFRESH WARNING NOTIFICATION")
        // Send local notification warning
        await sendBackgroundRefreshWarningNotification()
    }
    
    /// Send a notification warning about background refresh being disabled
    private func sendBackgroundRefreshWarningNotification() async {
        print("⚠️ Sending background refresh warning notification")
        
        let content = UNMutableNotificationContent()
        content.title = "⚠️ Alarms May Not Ring"
        content.body = "Background App Refresh is disabled. Your alarms may not work reliably. Tap to enable it in Settings."
        content.sound = .default
        content.categoryIdentifier = "BACKGROUND_REFRESH_WARNING"
        content.interruptionLevel = .timeSensitive
        
        // Add action to open settings
        content.userInfo = ["action": "openSettings"]
        
        // Deliver immediately
        let request = UNNotificationRequest(
            identifier: "background_refresh_warning",
            content: content,
            trigger: nil  // Deliver immediately
        )
        
        do {
            // Remove any previous warnings first
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: ["background_refresh_warning"]
            )
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: ["background_refresh_warning"]
            )
            
            // Add new warning
            try await UNUserNotificationCenter.current().add(request)
            print("✅ Background refresh warning notification sent")
        } catch {
            print("❌ Failed to send warning notification: \(error)")
        }
    }
    
    // MARK: - Force-Close Warning
    
    /// Timer that keeps pushing the force-close notification into the future
    /// while the app is alive. When the app is force-killed, the timer stops
    /// and the pending notification fires after its delay expires.
    private var forceCloseRescheduleTimer: Timer?
    
    /// How far into the future to schedule the notification.
    /// The timer reschedules every half this interval, so the notification
    /// only fires if the app has been dead for at least ~30s.
    private static let forceCloseDelay: TimeInterval = 60
    
    /// Pure gate for arming the force-close heartbeat (al-s96g). Order matters
    /// only for the log lines; the result is a plain conjunction.
    nonisolated static func shouldArmHeartbeat(suppressed: Bool,
                                               keepAliveNeeded: Bool,
                                               debugOverride: Bool,
                                               alarmRinging: Bool) -> Bool {
        if suppressed { return false }
        if !keepAliveNeeded && !debugOverride { return false }
        if alarmRinging { return false }
        return true
    }

    /// Reconcile the force-close heartbeat against the authoritative gate:
    /// arm it when `shouldArmHeartbeat` says so, stand it down (cancelling any
    /// armed timer and pending notifications) when it says not to. Armed, it
    /// schedules a delayed notification and keeps pushing it forward while the
    /// app is alive (via background audio); if the app is force-killed the
    /// timer dies and the notification fires. Every caller — backgrounding,
    /// residency transitions — funnels through this one decision so the arm
    /// and cancel paths can never disagree about the DEBUG override again
    /// (al-y7vc).
    private func reconcileForceCloseHeartbeat() {
        // Respect the suppress toggle (shared with background refresh warning).
        let suppressed = DeviceSettings.shared.suppressBackgroundRefreshWarning
        let keepAliveNeeded = DeviceSettings.shared.keepAliveNeeded
        // forceCloseWarningDebugOverride, not the raw toggle: its UI is DEBUG-only
        // so a stale persisted `true` must not re-arm the warning in release
        // builds (al-s96g).
        let debugOverride = DeviceSettings.shared.forceCloseWarningDebugOverride
        // If an alarm is currently ringing, the backup alarm notification
        // and AlarmKit ringing guard handle recovery. Don't send the generic warning.
        let isAlarmRinging = AlarmSoundPlayer.shared.isPlaying
            || PendingAlarmStore.shared.pendingAlarm != nil
            || PendingAlarmStore.shared.hasPendingAlarm()

        // shouldArmHeartbeat is the authoritative (unit-tested) gate; these
        // branches only narrate which of its clauses stood the heartbeat down.
        if suppressed {
            print("📱 Force-close notification: skipped (warnings suppressed)")
        } else if !keepAliveNeeded && !debugOverride {
            // App Persistence OFF means the app is SUPPOSED to be suspended. This
            // heartbeat only survives because background audio keeps the app alive;
            // without it the reschedule timer stops as soon as iOS suspends us and
            // the notification fires — warning the user about the exact behaviour
            // they just chose. It fired on every backgrounding, which is noise that
            // trains people to ignore a warning that matters when persistence is on.
            print("📱 Force-close notification: skipped (App Persistence is off — suspension is expected)")
        } else if isAlarmRinging {
            print("📱 Force-close heartbeat: skipped (alarm is ringing — backup notification handles this)")
        }

        guard Self.shouldArmHeartbeat(suppressed: suppressed,
                                      keepAliveNeeded: keepAliveNeeded,
                                      debugOverride: debugOverride,
                                      alarmRinging: isAlarmRinging) else {
            // Reconcile, don't just decline: a heartbeat armed under an earlier
            // truth (e.g. resident then residency ended, override off) must be
            // torn down here, or its pending notifications fire falsely.
            cancelForceCloseNotification()
            return
        }

        // App must be running for timer-based alarms to fire reliably.
        // Schedule the initial notification
        pushForceCloseNotification()
        
        // Start a repeating timer that keeps rescheduling the notification
        // further into the future. As long as the app is alive (background
        // audio keep-alive), this timer fires and the notification never
        // reaches its trigger time. When the user force-quits, the timer
        // stops and the notification fires after the remaining delay.
        forceCloseRescheduleTimer?.invalidate()
        forceCloseRescheduleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.forceCloseDelay / 2,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pushForceCloseNotification()
            }
        }
        print("📱 Force-close heartbeat: started")
    }
    
    /// Schedule (or reschedule) the force-close notification with a fresh delay.
    private func pushForceCloseNotification() {
        // Re-check the suppress flag on every push, not just at schedule time.
        // The 30s re-push timer and the interruption-ended resume path both land
        // here, so a suppress flipped mid-heartbeat (a settings change while
        // backgrounded) must stand the warning down here too (al-s96g).
        if DeviceSettings.shared.suppressBackgroundRefreshWarning {
            return
        }

        // Skip while an audio interruption is active — the app isn't force-closed,
        // it's just been paused by iOS for a phone call / Siri / FaceTime / etc.
        // The interruption-end handler will call this again to resume the rhythm.
        if audioInterrupted {
            return
        }

        let content = UNMutableNotificationContent()
        
        content.title = "Allarise stopped running"
        content.body = "Alarms still ring at your ringtone volume. Re-open Allarise to restore Home Assistant commands."
        
        content.sound = .default
        content.categoryIdentifier = "APP_CLOSED_WARNING"
        content.interruptionLevel = .timeSensitive
        
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: Self.forceCloseDelay,
            repeats: false
        )
        
        let request = UNNotificationRequest(
            identifier: Self.forceCloseNotificationID,
            content: content,
            trigger: trigger
        )
        
        // Second notification: reminder 60 seconds after the first
        let reminderContent = UNMutableNotificationContent()
        reminderContent.title = "Allarise is still closed"
        reminderContent.body = "Alarms still ring at ringtone volume, but Allarise won't respond to Home Assistant commands until it's re-opened."
        reminderContent.sound = .default
        reminderContent.categoryIdentifier = "APP_CLOSED_WARNING"
        reminderContent.interruptionLevel = .timeSensitive
        
        let reminderTrigger = UNTimeIntervalNotificationTrigger(
            timeInterval: Self.forceCloseDelay + 60,
            repeats: false
        )
        
        let reminderRequest = UNNotificationRequest(
            identifier: Self.forceCloseReminderNotificationID,
            content: reminderContent,
            trigger: reminderTrigger
        )
        
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [
            Self.forceCloseNotificationID,
            Self.forceCloseReminderNotificationID
        ])
        
        center.add(request) { error in
            if let error {
                print("❌ Failed to schedule force-close notification: \(error)")
            }
        }
        center.add(reminderRequest) { error in
            if let error {
                print("❌ Failed to schedule force-close reminder: \(error)")
            }
        }
    }
    
    /// Stop the heartbeat and cancel the pending notification.
    /// Called when app returns to foreground.
    private func cancelForceCloseNotification() {
        forceCloseRescheduleTimer?.invalidate()
        forceCloseRescheduleTimer = nil
        let ids = [Self.forceCloseNotificationID, Self.forceCloseReminderNotificationID]
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        print("📱 Force-close heartbeat: stopped")
    }

    /// DynamicPersistenceController calls this on every keep-alive start/stop
    /// transition. Residency ending while backgrounded means suspension is now
    /// the DESIGNED next step — the armed heartbeat would otherwise fire a false
    /// "Allarise stopped running" the moment iOS suspends us (al-s96g).
    /// Residency beginning while backgrounded re-arms the protection the
    /// .background scene hook armed too early or not at all.
    ///
    /// Both directions route through the reconcile so every clause of
    /// `shouldArmHeartbeat` is honored symmetrically: residency ending with the
    /// DEBUG "warn regardless of persistence" override ON keeps the heartbeat
    /// armed instead of silently tearing it down — an unconditional cancel here
    /// is exactly how the override was defeated (al-y7vc). `keepAliveNeeded`
    /// already reflects the new residency, so the parameter needs no direct use.
    func residencyDidChange(resident: Bool) {
        // Foreground never carries a heartbeat; the .active scene hook owns
        // cancellation there and backgrounding will reconcile again.
        guard !isAppActive else { return }
        reconcileForceCloseHeartbeat()
    }

    /// Public entry point for the "Hide App Closure Warnings" toggle: flipping it
    /// ON must cancel an already-armed heartbeat and clear its pending/delivered
    /// notifications immediately, not just stop future schedules (al-s96g).
    func warningsSuppressed() {
        cancelForceCloseNotification()
    }

    /// Check if there are any enabled alarms (call from view)
    func updateAlarmStatus(hasActiveAlarms: Bool) {
        self.hasActiveAlarms = hasActiveAlarms
    }
    
    // MARK: - Foreground Timestamp API
    
    /// Record that the app came to foreground
    private func recordForegroundTimestamp() {
        let now = Date()
        storedForegroundTimestamps.append(now)
        pruneForegroundTimestamps()
        saveForegroundTimestamps()
    }
    
    /// Get foreground timestamps within a time range (for sleep detection)
    func foregroundTimestamps(from start: Date, to end: Date) -> [Date] {
        storedForegroundTimestamps.filter { $0 >= start && $0 <= end }
    }
    
    /// Most recent foreground timestamp before a given date
    func lastForegroundTimestamp(before date: Date, lookbackHours: Double) -> Date? {
        let cutoff = date.addingTimeInterval(-lookbackHours * 3600)
        return storedForegroundTimestamps
            .filter { $0 >= cutoff && $0 < date }
            .max()
    }
    
    private func saveForegroundTimestamps() {
        let intervals = storedForegroundTimestamps.map { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(intervals, forKey: foregroundTimestampsKey)
    }
    
    private func loadForegroundTimestamps() {
        guard let intervals = UserDefaults.standard.array(forKey: foregroundTimestampsKey) as? [TimeInterval] else { return }
        storedForegroundTimestamps = intervals.map { Date(timeIntervalSince1970: $0) }
        pruneForegroundTimestamps()
    }
    
    private func pruneForegroundTimestamps() {
        let cutoff = Date().addingTimeInterval(-Double(foregroundRollingWindowDays) * 24 * 3600)
        storedForegroundTimestamps.removeAll { $0 < cutoff }
    }
}

// MARK: - UIBackgroundRefreshStatus Extension for Logging

extension UIBackgroundRefreshStatus {
    var description: String {
        switch self {
        case .available:
            return "Available"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        @unknown default:
            return "Unknown"
        }
    }
}
