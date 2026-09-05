//
//  DualAlarmCoordinator.swift
//  HaWake Alarm V2
//
//  Coordinates between LocalNotificationScheduler (primary) and
//  AlarmKitScheduler (failsafe on iOS 26+). All alarm scheduling
//  calls should go through this coordinator.
//

import Foundation
import AlarmKit

final class DualAlarmCoordinator: AlarmScheduler {
    static let shared = DualAlarmCoordinator()
    
    private let primary = LocalNotificationScheduler.shared
    private let failsafe = AlarmKitScheduler.shared
    
    /// Whether AlarmKit failsafe is available (iOS 26+)
    private var alarmKitAvailable: Bool {
        if #available(iOS 26, *) {
            return true
        }
        return false
    }
    
    private init() {}
    
    func requestAuthorization() async -> Bool {
        let primaryAuth = await primary.requestAuthorization()
        
        // Also request AlarmKit authorization on iOS 26+
        if alarmKitAvailable {
            let failsafeAuth = await failsafe.requestAuthorization()
            print("🔔 AlarmKit authorization: \(failsafeAuth ? "granted" : "denied")")
        }
        
        return primaryAuth
    }
    
    @MainActor
    func scheduleAlarm(_ alarm: Alarm, delay: TimeInterval = 0) async {
        // Note: `delay` parameter satisfies protocol but is ignored here.
        // Timer fires at exact time, AlarmKit is +5s failsafe backup.
        AppLogger.shared.log("Schedule alarm: '\(alarm.label)' enabled=\(alarm.isEnabled) nextFire=\(alarm.nextFireDate().map(String.init(describing:)) ?? "nil")", category: .coordinator)

        await primary.scheduleAlarm(alarm, delay: 0)
        if alarmKitAvailable {
            // An overdue fire date (≤60 s past — e.g. a Kids Sleep "bed now"
            // alarm, al-is5q) makes the primary ring DURING the call above; its
            // cancelFailsafe ran before any failsafe existed, so arming one now
            // would blast the system sound over the already-ringing alarm ~5 s
            // in. Ringing IS delivery — the failsafe has nothing left to back up.
            if PendingAlarmStore.shared.activeRingingAlarmID() == alarm.stableHash {
                AppLogger.shared.log("Skip AlarmKit failsafe: '\(alarm.label)' already rang via overdue path", category: .coordinator)
            } else {
                await failsafe.scheduleAlarm(alarm, delay: 5)
            }
        }
        NotificationCenter.default.post(name: .alarmScheduleDidChange, object: nil)
    }

    /// Schedule alarm during reconciliation (app foregrounding).
    /// The Live Activity is pre-scheduled via `scheduleAlarmActivity()` with
    /// AlertConfiguration for reliable expanded Dynamic Island presentation.
    /// At fire time, `startAlarmActivity()` deduplicates (keeps the existing one).
    @MainActor
    func scheduleAlarmForReconciliation(_ alarm: Alarm) async {
        await primary.scheduleAlarm(alarm, delay: 0)
        if alarmKitAvailable {
            await failsafe.scheduleAlarm(alarm, delay: 5)
        }
        NotificationCenter.default.post(name: .alarmScheduleDidChange, object: nil)
    }

    @MainActor
    func cancelAlarm(_ alarm: Alarm) async {
        AppLogger.shared.log("Cancel alarm: '\(alarm.label)'", category: .coordinator)
        // Cancel any pending snooze — covers the case where a snoozed alarm is deleted
        // before the snooze fires. Without this, the snooze timer and AlarmKit failsafe
        // would still fire on an alarm that no longer exists.
        cancelSnooze(for: alarm)
        // Cancel from both systems
        await primary.cancelAlarm(alarm)

        if alarmKitAvailable {
            await failsafe.cancelAlarm(alarm)
        }
        NotificationCenter.default.post(name: .alarmScheduleDidChange, object: nil)
    }

    func cancelAllAlarms() async {
        AppLogger.shared.log("Cancel all alarms", category: .coordinator)
        await primary.cancelAllAlarms()

        if alarmKitAvailable {
            await failsafe.cancelAllAlarms()
        }
        NotificationCenter.default.post(name: .alarmScheduleDidChange, object: nil)
    }
    
    /// Cancel snooze (delegates to primary — AlarmKit handles its own snooze)
    func cancelSnooze(for alarm: Alarm) {
        AppLogger.shared.log("Cancel snooze requested: '\(alarm.label)'", category: .coordinator)
        primary.cancelSnooze(for: alarm)
    }
    
    /// Remove AlarmKit alarms that no longer have a matching SwiftData alarm.
    /// Call on app launch with the set of enabled alarm hashes from the database.
    func cleanupStaleAlarms(validAlarmHashes: Set<Int>) {
        guard alarmKitAvailable else { return }
        failsafe.cleanupStaleAlarms(validAlarmHashes: validAlarmHashes)
    }

    /// Cancel the AlarmKit failsafe for a specific alarm (called when primary timer fires successfully)
    @MainActor
    func cancelFailsafe(for alarmIDHash: Int) {
        guard alarmKitAvailable else { return }
        
        let uuid = failsafe.alarmIDToUUID(alarmIDHash)
        // stop() first: if the failsafe already reached .alerting (recurring
        // same-minute race, or the system had already queued it for delivery),
        // stop() is the only call that silences it — cancel() is a no-op on an
        // alerting alarm. On a still-.scheduled failsafe stop() throws
        // harmlessly and the cancel() below removes it. Trying both covers all
        // states (same pattern as cancelRingingGuard).
        do { try AlarmManager.shared.stop(id: uuid) } catch {}
        do {
            try AlarmManager.shared.cancel(id: uuid)
            print("✅ Cancelled AlarmKit failsafe (primary timer fired successfully)")
            AppLogger.shared.log("AlarmKit failsafe cancelled (primary fired): hash=\(alarmIDHash)", category: .coordinator)
        } catch {
            let nsError = error as NSError
            if nsError.code != 0 {
                print("⚠️ Failed to cancel AlarmKit failsafe: \(error)")
            }
        }
        // Also drop the second-tier weekly backup (recurring alarms) for this
        // occurrence — it is re-armed by the post-dismissal reschedule and by
        // reconciliation.
        failsafe.cancelWeeklyBackup(forAlarmHash: alarmIDHash)
    }
    
    /// Schedule a ringing guard when the app enters background while an alarm is actively ringing.
    /// If the user force-kills the app, AlarmKit re-fires within seconds.
    func scheduleRingingGuard(alarm: Alarm, alarmID: Int) async {
        guard alarmKitAvailable else { return }
        await failsafe.scheduleRingingGuard(alarm: alarm, alarmID: alarmID)
    }

    /// Schedule a ringing guard using stored alarm info (no full Alarm object needed).
    /// Used when AlarmKit fires and the DB alarm hasn't been loaded yet.
    func scheduleRingingGuardFromInfo(alarmID: Int, label: String, requiresMission: Bool, soundID: String) async {
        guard alarmKitAvailable else { return }
        await failsafe.scheduleRingingGuardFromInfo(alarmID: alarmID, label: label, requiresMission: requiresMission, soundID: soundID)
    }

    /// Cancel the ringing guard (called when alarm is dismissed, snoozed, or app returns to foreground).
    func cancelRingingGuard(forAlarmHash alarmID: Int) {
        guard alarmKitAvailable else { return }
        failsafe.cancelRingingGuard(forAlarmHash: alarmID)
    }
}

// MARK: - Ring reporting (telemetry only)

/// Bookkeeping for ONE alarm ring, so telemetry can answer the only question
/// that matters for this app's reliability: WHICH tier delivered the alarm
/// (see Documents/16-FORCE-KILL-RECOVERY.md).
///
/// It exists because no single function knows the whole story. The tier that
/// fires (in-app timer / AlarmKit +5s failsafe / weekly backup / ringing guard
/// / launch reconciliation) is one place, the alarm's shape (mission count,
/// radio) is another, and playback confirmation is a third — and their order
/// differs per path: the primary timer presents the window before starting
/// audio, while the snooze re-fire and the AlarmKit handler confirm audio
/// first. Each site reports only what it knows; this type turns that into
/// exactly one `alarmFired` per ring, paired with one `alarmEnded`.
///
/// STRICTLY OBSERVATION. Nothing here is read by scheduling, audio, or
/// recovery code, and every method is safe to call out of order or twice.
@MainActor
final class AlarmRingReporter {
    static let shared = AlarmRingReporter()

    /// A tier has claimed the next ring but the window isn't up yet.
    private struct Claim {
        let path: AlarmDeliveryPath
        /// When the alarm was SUPPOSED to ring, or nil when unknowable (a
        /// recovery can't know how long the alarm sat overdue).
        let expectedFire: Date?
    }

    private struct Ring {
        let path: AlarmDeliveryPath
        let expectedFire: Date
        let began: Date
        var missionCount: Int
        var usedRadio: Bool
        var firedLogged: Bool
    }

    private var claim: Claim?
    private var ring: Ring?
    /// Playback confirmation that arrived BEFORE the window was presented.
    /// Held until `ringBegan` can pair it with the alarm's shape.
    private var earlyAudioAt: Date?
    private var earlyAudioFailed = false

    private init() {}

    /// A delivery tier is about to ring. Recorded, not emitted — the alarm's
    /// mission/radio shape is only known once the window is presented.
    func willDeliver(path: AlarmDeliveryPath, expectedFire: Date?) {
        claim = Claim(path: path, expectedFire: expectedFire)
        earlyAudioAt = nil
        earlyAudioFailed = false
        // Local wake-ladder telemetry (never leaves the device): pairs the
        // night's ladder records with WHICH tier actually rang. This funnel is
        // claimed by every delivery path, so one hook covers them all.
        WakeAttemptStore.shared.recordAlarmFired(path: String(describing: path))
    }

    /// Same, but never overrides a tier that already claimed this ring. Used by
    /// the recovery funnel, which every other path also flows through.
    func willDeliverIfUnclaimed(path: AlarmDeliveryPath, expectedFire: Date?) {
        guard claim == nil, ring == nil else { return }
        willDeliver(path: path, expectedFire: expectedFire)
    }

    /// The alarm window is up — the one funnel every non-alert delivery path
    /// reaches, and the first point where the alarm's shape is known.
    func ringBegan(missionCount: Int, usedRadio: Bool) {
        guard ring == nil else {
            // Re-presentation of the ring already in flight (unlock, retry).
            ring?.missionCount = missionCount
            ring?.usedRadio = usedRadio
            return
        }
        let claimed = claim
        claim = nil
        ring = Ring(
            path: claimed?.path ?? .launchRecovery,  // unclaimed = found in progress
            expectedFire: claimed?.expectedFire ?? Date(),
            began: Date(),
            missionCount: missionCount,
            usedRadio: usedRadio,
            firedLogged: false
        )
        if let earlyAudioAt {
            logFired(audioAt: earlyAudioAt)
        } else if earlyAudioFailed {
            logSilentStart()
        }
        earlyAudioAt = nil
        earlyAudioFailed = false
    }

    /// Audible playback confirmed (`AlarmSoundPlayer.isPlaying`).
    func audioStarted() {
        guard ring != nil else {
            if earlyAudioAt == nil { earlyAudioAt = Date() }
            return
        }
        logFired(audioAt: Date())
    }

    /// Playback could NOT be confirmed after the retry — the worst failure this
    /// app has, so it gets its own event on top of the ring.
    func audioFailed() {
        guard ring != nil else {
            earlyAudioFailed = true
            return
        }
        logSilentStart()
    }

    /// The ring is over.
    func ringEnded(outcome: AlarmOutcome, snoozeCount: Int) {
        guard let current = ring else { return }
        // Ended with playback never confirmed — same class of failure as a
        // silent start, and the only remaining chance to record this ring.
        if !current.firedLogged { logSilentStart() }
        Analytics.shared.log(.alarmEnded(
            outcome: outcome,
            snoozeCount: snoozeCount,
            secondsRinging: Date().timeIntervalSince(current.began)
        ))
        ring = nil
        earlyAudioAt = nil
        earlyAudioFailed = false
    }

    private func logSilentStart() {
        guard let current = ring else { return }
        logFired(audioAt: Date())
        Analytics.shared.log(.alarmSilentStart(path: current.path))
    }

    private func logFired(audioAt moment: Date) {
        guard var current = ring, !current.firedLogged else { return }
        current.firedLogged = true
        ring = current
        Analytics.shared.log(.alarmFired(
            path: current.path,
            missionCount: current.missionCount,
            usedRadio: current.usedRadio,
            // Clamped: a recovery has no real expected time and falls back to
            // the ring's own start, which audio can narrowly precede.
            secondsToAudio: max(0, moment.timeIntervalSince(current.expectedFire))
        ))
    }
}
