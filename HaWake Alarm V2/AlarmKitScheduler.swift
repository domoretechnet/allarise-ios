//
//  AlarmKitScheduler.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import Foundation
import AlarmKit
import SwiftUI
import SwiftData
import AppIntents
import ActivityKit
import AVFoundation

// Type alias to disambiguate between our Alarm model and AlarmKit's Alarm
typealias AppAlarm = HaWake_Alarm_V2.Alarm
typealias SystemAlarm = AlarmKit.Alarm

final class AlarmKitScheduler: AlarmScheduler {
    static let shared = AlarmKitScheduler()
    
    private let alarmManager = AlarmManager.shared
    
    // Track UUID to alarm hash mapping (persisted to UserDefaults so it
    // survives app termination — needed when AlarmKit fires after app is killed)
    private var uuidToHashMap: [UUID: Int] = [:] {
        didSet { persistUUIDMap() }
    }
    
    /// Track the fire date each UUID was last scheduled for.
    /// Used by deduplication to detect when the fire time changes (e.g. after a skip)
    /// and force a cancel+re-schedule even though the UUID already exists in AlarmKit.
    private var uuidToScheduledFire: [UUID: Date] = [:]
    
    /// Alarm hash currently being processed by handleAlarmAlerting.
    /// Set synchronously before any async work to prevent rapid-fire duplicates.
    private var handlingAlarmHash: Int?
    
    /// UUID of the AlarmKit alarm that is currently in the .alerting state.
    /// Stored so we can call stop(id:) when the user snoozes — otherwise iOS
    /// keeps showing the system alarm notification even after the window is hidden.
    private var currentAlertingAlarmUUID: UUID?

    /// Clear the handling flag when the alarm is dismissed or snoozed,
    /// allowing a new alarm to be processed.
    func clearHandlingAlarm() {
        handlingAlarmHash = nil
    }

    /// Stop the currently alerting AlarmKit alarm (transitions it out of .alerting state).
    /// Must be called when snoozing so iOS dismisses its system notification UI.
    func stopCurrentAlertingAlarm() {
        guard let uuid = currentAlertingAlarmUUID else {
            print("[ALARM-STATE] stopCurrentAlertingAlarm: no alerting UUID stored — skipping")
            return
        }
        do {
            try alarmManager.stop(id: uuid)
            print("[ALARM-STATE] stopCurrentAlertingAlarm: stopped uuid=\(uuid)")
            AppLogger.shared.log("AlarmKit alerting alarm stopped: uuid=\(uuid)", category: .alarm)
        } catch {
            print("[ALARM-STATE] stopCurrentAlertingAlarm: stop failed (may already be stopped): \(error)")
        }
        currentAlertingAlarmUUID = nil
    }
    
    private let uuidMapKey = "HaWakeAlarm.uuidToHashMap"
    private let lastGuardAlarmIDKey = "HaWakeAlarm.lastRingingGuardAlarmID"

    private init() {
        // Restore persisted map
        loadUUIDMap()

        // Diagnostic: dump AlarmKit state on cold start
        let lastGuardID = UserDefaults.standard.integer(forKey: lastGuardAlarmIDKey)
        print("[ALARM-STATE] AlarmKitScheduler.init: uuidToHashMap=\(uuidToHashMap.count) entries, lastGuardAlarmID=\(lastGuardID)")
        if let allAlarms = try? alarmManager.alarms {
            print("[ALARM-STATE] AlarmKitScheduler.init: \(allAlarms.count) AlarmKit alarms on cold start:")
            for a in allAlarms {
                let hash = uuidToHashMap[a.id]
                print("[ALARM-STATE]   init: uuid=\(a.id), state=\(a.state), hash=\(hash.map(String.init) ?? "unmapped")")
            }
        }

        // Start observing alarm updates
        Task {
            await observeAlarmUpdates()
        }
    }
    
    private func persistUUIDMap() {
        // Convert [UUID: Int] to [String: Int] for UserDefaults
        let stringMap = Dictionary(uniqueKeysWithValues: uuidToHashMap.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(stringMap, forKey: uuidMapKey)
        // Force flush to disk — critical for surviving force-close.
        // Without this, UserDefaults may not write to disk before the process
        // is terminated, causing the map to be lost on the next cold start.
        UserDefaults.standard.synchronize()
    }
    
    private func loadUUIDMap() {
        guard let stringMap = UserDefaults.standard.dictionary(forKey: uuidMapKey) as? [String: Int] else { return }
        let restored = Dictionary(uniqueKeysWithValues: stringMap.compactMap { key, value -> (UUID, Int)? in
            guard let uuid = UUID(uuidString: key) else { return nil }
            return (uuid, value)
        })
        // Assign directly to backing storage to avoid triggering didSet (which would re-persist)
        uuidToHashMap = restored
        print("✅ Restored AlarmKit UUID map: \(restored.count) entries")
    }
    
    /// Returns true if at least one AlarmKit alarm is currently scheduled.
    var hasScheduledAlarms: Bool {
        guard let alarms = try? alarmManager.alarms else { return false }
        return alarms.contains { $0.state == .scheduled }
    }

    /// Returns true if any AlarmKit alarm is currently alerting (ringing).
    /// Used to prevent the foreground reconciliation from interfering with
    /// a guard that just fired and is being processed by handleAlarmAlerting.
    var hasAlertingAlarm: Bool {
        guard let alarms = try? alarmManager.alarms else { return false }
        return alarms.contains { $0.state == .alerting }
    }
    
    func requestAuthorization() async -> Bool {
        do {
            let state = try await alarmManager.requestAuthorization()
            return state == .authorized
        } catch {
            print("Failed to request AlarmKit authorization: \(error)")
            return false
        }
    }

    /// Whether AlarmKit alarm permission is currently DENIED. Read-only — it inspects the
    /// existing authorization and does NOT present a prompt, so it's safe to poll for the
    /// "alarms can't be scheduled" warning banner.
    var isAuthorizationDenied: Bool {
        alarmManager.authorizationState == .denied
    }
    
    @MainActor
    func scheduleAlarm(_ alarm: AppAlarm, delay: TimeInterval = 5) async {
        let hash = alarm.stableHash
        let uuid = alarmIDToUUID(hash)
        print("[ALARM-STATE] scheduleAlarm called: label=\(alarm.label), hash=\(hash), uuid=\(uuid), enabled=\(alarm.isEnabled), mission=\(alarm.mission.type.rawValue), delay=\(delay)")

        guard alarm.isEnabled else {
            print("[ALARM-STATE] scheduleAlarm: alarm disabled, cancelling instead")
            await cancelAlarm(alarm)
            return
        }

        guard let nextFire = alarm.nextFireDate() else {
            print("[ALARM-STATE] scheduleAlarm: no next fire date, cancelling")
            await cancelAlarm(alarm)
            return
        }

        print("[ALARM-STATE] scheduleAlarm: nextFire=\(nextFire) (in \(Int(nextFire.timeIntervalSinceNow))s)")

        // Deduplication: if an AlarmKit alarm is already scheduled for this UUID
        // AND the fire time hasn't changed, skip the cancel+re-schedule cycle.
        // This prevents reconciliation from churning AlarmKit alarms on every
        // foreground/background transition, while still allowing re-scheduling
        // when the fire time changes (e.g. after a skip moves it to the next day).
        let desiredFire = nextFire.addingTimeInterval(delay)
        let existingAlarms = try? alarmManager.alarms
        if existingAlarms?.first(where: { $0.id == uuid && $0.state == .scheduled }) != nil {
            if let previousFire = uuidToScheduledFire[uuid],
               abs(previousFire.timeIntervalSince(desiredFire)) < 1.0 {
                print("[ALARM-STATE] scheduleAlarm: already scheduled at same time (uuid=\(uuid)), skipping re-schedule")
                return
            }
            print("[ALARM-STATE] scheduleAlarm: fire time changed (was \(uuidToScheduledFire[uuid].map(String.init(describing:)) ?? "unknown") → now \(desiredFire)), re-scheduling")
        }

        do {
            // Cancel existing alarm first
            await cancelAlarm(alarm)

            // For recurring alarms, use .relative() which is wall-clock aware —
            // if the user changes timezone, the alarm still fires at the correct
            // local time (e.g., 7:30 AM stays 7:30 AM). For one-time/ephemeral
            // alarms, .fixed() is correct (fire at the scheduled absolute moment).
            // The +5s delay ensures AlarmKit only fires if the primary timer fails.
            // The main failsafe is ALWAYS a one-shot fixed date at nextFire+5s.
            // Recurring alarms previously used .relative(.weekly), but that is
            // minute-granular: it fired in the same minute as the primary
            // timer, and cancel() cannot stop an alarm the system has already
            // queued for delivery — producing a full-volume system-sound burst
            // that interrupts the app player (observed in device logs on
            // iOS 27 beta). The fixed +5s date restores primary-first ordering
            // with a reliable cancellation margin. Multi-day coverage while
            // the app is dead comes from the second-tier weekly backup
            // (+2 min offset) scheduled below — see scheduleWeeklyBackup().
            // Skip-next: nextFireDate() already excludes the skipped
            // occurrence, so the fixed date is skip-safe by construction; the
            // weekly tier is withheld while a skip is active.
            let schedule: SystemAlarm.Schedule = .fixed(desiredFire)
            if alarm.isRecurring && alarm.isSkipped {
                print("[ALARM-STATE] scheduleAlarm: skip active — failsafe pinned to .fixed(\(desiredFire)), weekly tier withheld")
            }
            
            // AlarmKit serves as a FAILSAFE — fires even when the app is killed,
            // phone is muted, or DND is on. When the alarm has a mission, tapping
            // Stop opens the app and hands off to the full mission UI.
            // No secondary (snooze) button — snooze is handled in-app. Removing it
            // prevents users from accidentally opening the app a second time via
            // the snooze button on the AlarmKit system UI.
            let alertContent = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: AlarmKitConfigResolution.alertTitle(for: alarm.label))
            )

            let presentation = AlarmPresentation(alert: alertContent)

            let uuid = alarmIDToUUID(alarm.stableHash)

            // Both Stop and Mission buttons open the app — the user cannot dismiss
            // an AlarmKit alarm without being forced into the in-app alarm UI.
            // If the alarm has a mission, CompleteMissionIntent handles it;
            // otherwise DefaultStopIntent opens the app and shows the alarm screen.
            // CompleteMissionIntent whenever the alarm requires ANY mission (the
            // whole sequence, not just slot 1) so the app is forced open to run it;
            // DefaultStopIntent only when the sequence is empty (no mission at all).
            let stopIntent: any LiveActivityIntent
            if alarm.missionSequence.isEmpty {
                stopIntent = DefaultStopIntent(
                    alarmID: alarm.stableHash,
                    alarmUUID: uuid
                )
            } else {
                stopIntent = CompleteMissionIntent(
                    alarmID: alarm.stableHash,
                    alarmUUID: uuid
                )
            }
            // Resolve the alarm sound for AlarmKit
            // AlertConfiguration.AlertSound.named() looks in the app's main bundle,
            // so we pass the bundle-relative path (e.g., "AlarmSounds/Alarm_Clock.wav").
            let alarmSound: AlertConfiguration.AlertSound
            if let sound = AlarmSoundManager.shared.getSound(id: alarm.soundName),
               let soundName = sound.notificationSoundName {
                alarmSound = .named(soundName)
            } else {
                alarmSound = .default
            }

            // Create metadata structure
            struct AlarmMetadataContent: AlarmMetadata {
                let alarmID: Int
            }

            let configuration = AlarmManager.AlarmConfiguration(
                schedule: schedule,
                attributes: AlarmAttributes(
                    presentation: presentation,
                    metadata: AlarmMetadataContent(
                        alarmID: alarm.stableHash
                    ),
                    tintColor: Color.blue
                ),
                stopIntent: stopIntent,
                sound: alarmSound
            )
            
            // Store the mapping for later retrieval
            uuidToHashMap[uuid] = alarm.stableHash
            
            // Pre-store full alarm data in UserDefaults so the app can show
            // the alarm screen instantly on cold start without waiting for SwiftData.
            // Also backward-compatible with CompleteMissionIntent's retrieveAlarmInfo().
            PendingAlarmStore.shared.storeFullAlarmInfo(
                alarmID: alarm.stableHash,
                alarm: alarm
            )
            
            _ = try await alarmManager.schedule(id: uuid, configuration: configuration)

            // Track the scheduled fire date for deduplication comparison
            uuidToScheduledFire[uuid] = desiredFire

            // Second-tier weekly backup for recurring alarms (+2 min offset).
            await scheduleWeeklyBackup(for: alarm, hash: alarm.stableHash)

            // Log all currently scheduled AlarmKit alarms
            let allAlarms = try? alarmManager.alarms
            let alarmCount = allAlarms?.count ?? -1
            let stopType = alarm.missionSequence.isEmpty ? "DefaultStopIntent" : "CompleteMissionIntent"
            print("[ALARM-STATE] ✅ Scheduled AlarmKit alarm: label=\(alarm.label), uuid=\(uuid), fire=\(nextFire), stopIntent=\(stopType), totalAlarmKitAlarms=\(alarmCount)")
            AppLogger.shared.log("AlarmKit scheduled: '\(alarm.label)' fires at \(nextFire) (uuid=\(uuid) stopIntent=\(stopType))", category: .alarm)
        } catch {
            // The MAIN failsafe failing is the most serious AlarmKit outcome in
            // the app, and until al-6hh it was a bare print() — invisible in an
            // exported diagnostic log. AlarmKit's Code=0 carries no reason, so
            // record the configuration shape and the resident inventory; see
            // the notes in armWeeklyBackup's catch for what Code=0 does and does
            // not mean (it is NOT a quota — measured, al-bee.4).
            let shape = AlarmKitConfigResolution.describe(
                tier: .mainFailsafe,
                title: AlarmKitConfigResolution.alertTitle(for: alarm.label)
            )
            let count = (try? alarmManager.alarms.count) ?? -1
            print("[ALARM-STATE] ❌ Failed to schedule AlarmKit alarm: \(error) [\(shape)] (residentAlarmKitAlarms=\(count))")
            AppLogger.shared.log("AlarmKit MAIN failsafe FAILED: '\(alarm.label)' fire=\(desiredFire) — \(error) [\(shape)] (residentAlarms=\(count), auth=\(alarmManager.authorizationState))", category: .alarm)
        }
    }
    
    // MARK: - Second-Tier Weekly Backup (recurring alarms)

    /// UUID for the second-tier weekly backup, distinct from main/snooze/guard.
    private func weeklyBackupUUID(forAlarmHash hash: Int) -> UUID {
        // Mask ("WKLY" in hex) lives in AlarmKitAlarmIdentity.
        AlarmKitAlarmIdentity.weeklyBackupUUID(forAlarmHash: hash)
    }

    /// Per-alarm arm generation for the weekly backup tier. Bumped on every
    /// (re)arm and cancel so a DEFERRED arm (the detached inside-slot-window
    /// task in scheduleWeeklyBackup) can detect that the alarm was edited,
    /// rescheduled, or cancelled while it slept — and skip arming a schedule
    /// built from stale time/day values. Without this, editing an alarm during
    /// the ~3-minute deferral window left a weekly AlarmKit alarm ringing at
    /// the OLD time every week, invisible to the app.
    private var weeklyArmGeneration: [Int: Int] = [:]

    /// Convert recurringDays (1=Sun…7=Sat) to Locale.Weekday values.
    /// Lives in `AlarmKitConfigResolution` so it can be tested without an
    /// AlarmKit session — including the empty-result case, which cannot be
    /// scheduled at all.
    private func localeWeekdays(from days: Set<Int>) -> [Locale.Weekday] {
        AlarmKitConfigResolution.weekdays(from: days)
    }

    /// Remove a resident AlarmKit alarm for `id`, whatever state it is in,
    /// before re-using that id.
    ///
    /// `cancel(id:)` THROWS on an `.alerting` alarm (measured, `al-bee.4`), and
    /// a fired-but-unattended alarm stays resident as `.alerting` indefinitely —
    /// it survives the app process dying and survives a reboot. Allarise's tier
    /// UUIDs are deterministic per alarm hash, so the id being re-armed is
    /// frequently the very id left `.alerting` by the last unattended fire.
    /// Calling only `cancel` there swallows the throw, leaves the alarm
    /// resident, and the following `schedule(id:)` on a live id is one of the
    /// shapes that reports the opaque `Code=0`.
    ///
    /// `stop` then `cancel` covers every state without querying first: on a
    /// `.scheduled` alarm `stop` is the no-op and `cancel` does the work; on an
    /// `.alerting` one `stop` does the work and `cancel` is the no-op. This is
    /// the pattern `cancelRingingGuard` has always used; the other sites simply
    /// never adopted it.
    @discardableResult
    private func clearResidentAlarm(id: UUID) -> Bool {
        var wasAlerting = false
        if let resident = try? alarmManager.alarms.first(where: { $0.id == id }) {
            wasAlerting = resident.state == .alerting
        }
        do { try alarmManager.stop(id: id) } catch {}
        do { try alarmManager.cancel(id: id) } catch {}
        if wasAlerting {
            print("[ALARM-STATE] clearResidentAlarm: uuid=\(id) was .alerting (unattended fire) — stopped before re-use")
            AppLogger.shared.log("AlarmKit id reclaimed from .alerting before re-arm: uuid=\(id)", category: .alarm)
        }
        return wasAlerting
    }

    /// Schedule the second-tier backup for a recurring alarm: a `.weekly`
    /// AlarmKit schedule at the alarm's time **+2 minutes**.
    ///
    /// Purpose: multi-day coverage while the app is dead. The main failsafe is
    /// a one-shot fixed date (+5s) — raceless, but it only protects the next
    /// occurrence. This weekly tier protects every later occurrence, and only
    /// ever alerts when the app is dead AND the user missed the +5s backup.
    /// The +2 min offset gives the alive app a huge cancellation margin, so it
    /// can never race the primary the way the old same-minute weekly did.
    ///
    /// Deferral: re-arming a weekly pattern while "today's" +2 min slot is
    /// still ahead (e.g. rescheduling seconds after a dismissal) would alert
    /// ~2 minutes after the user dismissed. If we're inside that window, the
    /// arm is deferred until the slot has passed. The deferral task dies with
    /// the process (unarmed = silent), and reconciliation re-arms on next
    /// launch — no spurious fire either way.
    private func scheduleWeeklyBackup(for alarm: AppAlarm, hash: Int) async {
        guard alarm.isRecurring else { return }
        let uuid = weeklyBackupUUID(forAlarmHash: hash)

        // Invalidate any deferred arm still sleeping from a previous call —
        // its captured time/day values are stale now.
        let myGeneration = (weeklyArmGeneration[hash] ?? 0) + 1
        weeklyArmGeneration[hash] = myGeneration

        // Always clear the previous tier before (re)arming or withholding.
        // stop-then-cancel: this tier is the one that fires while the app is
        // dead, so its id is the one most likely to still be resident and
        // .alerting from an unattended fire — and cancel() alone throws there.
        clearResidentAlarm(id: uuid)

        // While a skip is active, withhold the tier entirely — its pattern
        // would contain the skipped weekday and fire on it if the app died.
        // Re-armed by the next scheduleAlarm call once the skip clears.
        guard !alarm.isSkipped else { return }

        // Capture plain values — the arm may run in a detached task and
        // SwiftData models must not cross that boundary.
        let label = alarm.label
        let requiresMission = !alarm.missionSequence.isEmpty
        let soundName = alarm.soundName
        let days = alarm.safeRecurringDays
        let cal = Calendar.current
        let backupTime = alarm.time.addingTimeInterval(120)
        let comps = cal.dateComponents([.hour, .minute], from: backupTime)
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0

        // Deferral window check for today's slot.
        let todayWeekday = cal.component(.weekday, from: Date())
        if days.contains(todayWeekday),
           let todaysSlot = cal.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) {
            let untilSlot = todaysSlot.timeIntervalSinceNow
            if untilSlot > 0 && untilSlot < 180 {
                print("[ALARM-STATE] scheduleWeeklyBackup: inside today's slot window — deferring arm by \(Int(untilSlot + 60))s")
                Task.detached { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64((untilSlot + 60) * 1_000_000_000))
                    guard let self else { return }
                    // The alarm may have been edited/cancelled while we slept —
                    // a newer scheduleWeeklyBackup/cancelWeeklyBackup bumped the
                    // generation and owns the tier now. Arming here would install
                    // a weekly schedule with STALE time/days.
                    let stillCurrent = await MainActor.run { self.weeklyArmGeneration[hash] == myGeneration }
                    guard stillCurrent else {
                        print("[ALARM-STATE] scheduleWeeklyBackup: deferred arm superseded — skipping")
                        await MainActor.run {
                            AppLogger.shared.log("Weekly backup deferred arm superseded: '\(label)' — skipped", category: .alarm)
                        }
                        return
                    }
                    await self.armWeeklyBackup(hash: hash, uuid: uuid, label: label, requiresMission: requiresMission, soundName: soundName, days: days, hour: hour, minute: minute)
                }
                return
            }
        }

        await armWeeklyBackup(hash: hash, uuid: uuid, label: label, requiresMission: requiresMission, soundName: soundName, days: days, hour: hour, minute: minute)
    }

    private func armWeeklyBackup(hash: Int, uuid: UUID, label: String, requiresMission: Bool, soundName: String, days: Set<Int>, hour: Int, minute: Int) async {
        // A weekly schedule with no mappable weekday has no occurrence at all.
        // AlarmKit rejects it with the same contentless Code=0 as everything
        // else, so refuse it here and say WHY instead. Reachable because
        // `isRecurring` only tests that `recurringDaysRaw` is non-empty, while
        // `AlarmBackupStore` restores that raw string verbatim from JSON.
        guard AlarmKitConfigResolution.canArmWeekly(days: days) else {
            print("[ALARM-STATE] ❌ Weekly second-tier backup NOT armed: '\(label)' hash=\(hash) has no mappable weekday (days=\(days.sorted()))")
            AppLogger.shared.log("Weekly backup tier NOT armed: '\(label)' — recurring days \(days.sorted()) contain no valid weekday (1–7); the +5s fixed failsafe still covers the next occurrence", category: .alarm)
            return
        }

        let alertContent = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: AlarmKitConfigResolution.alertTitle(for: label))
        )
        let presentation = AlarmPresentation(alert: alertContent)

        // requiresMission (from missionSequence) so a multi-tap/hold Tap alarm
        // gets CompleteMissionIntent and opens the app.
        let stopIntent: any LiveActivityIntent
        if !requiresMission {
            stopIntent = DefaultStopIntent(alarmID: hash, alarmUUID: uuid)
        } else {
            stopIntent = CompleteMissionIntent(alarmID: hash, alarmUUID: uuid)
        }

        let alarmSound: AlertConfiguration.AlertSound
        if let sound = AlarmSoundManager.shared.getSound(id: soundName),
           let notifName = sound.notificationSoundName {
            alarmSound = .named(notifName)
        } else {
            alarmSound = .default
        }

        struct AlarmMetadataContent: AlarmMetadata {
            let alarmID: Int
        }

        let configuration = AlarmManager.AlarmConfiguration(
            schedule: .relative(
                SystemAlarm.Schedule.Relative(
                    time: SystemAlarm.Schedule.Relative.Time(hour: hour, minute: minute),
                    repeats: .weekly(localeWeekdays(from: days))
                )
            ),
            attributes: AlarmAttributes(
                presentation: presentation,
                metadata: AlarmMetadataContent(alarmID: hash),
                tintColor: Color.blue
            ),
            stopIntent: stopIntent,
            sound: alarmSound
        )

        uuidToHashMap[uuid] = hash

        do {
            _ = try await alarmManager.schedule(id: uuid, configuration: configuration)
            print("[ALARM-STATE] ✅ Weekly second-tier backup armed: '\(label)' hash=\(hash) at \(hour):\(String(format: "%02d", minute)) uuid=\(uuid)")
            AppLogger.shared.log("Weekly backup tier armed: '\(label)' at \(hour):\(String(format: "%02d", minute)) (+2min offset)", category: .alarm)
        } catch {
            // AlarmKit reports every rejection as the same contentless
            // `com.apple.AlarmKit.Alarm Code=0 "(null)"`, so this block has to
            // supply the reason the framework won't.
            //
            // NOT a quota. That was the standing guess here for months and it
            // is MEASURED WRONG: bead `al-bee.4`, 2026-08-05, iOS 26.6 under a
            // real AlarmKit harness — 500 concurrently scheduled `.fixed`
            // alarms in one app gave 500 successes and 0 errors. That is 8x
            // this app's worst realistic case (15 alarms x 4 UUIDs = 60).
            // `alarmCount` is still logged, but as inventory, not as a ceiling.
            // (Caveat: measured on 26.6; production targets 27, one minor
            // version ahead. A `.relative`/weekly-specific limit is unmeasured.)
            //
            // The shapes that ARE known to throw Code=0:
            //   - a `countdown` presentation on a fixed-date `.alarm` (this
            //     tier is alert-only, asserted in AlarmKitConfigResolutionTests);
            //   - re-using an id that is still resident and `.alerting`
            //     (handled by clearResidentAlarm before every arm);
            //   - a `.weekly` schedule with an empty weekday list (refused
            //     above with a named reason).
            // So log the configuration SHAPE — that is what identifies which.
            let count = (try? alarmManager.alarms.count) ?? -1
            let shape = AlarmKitConfigResolution.describe(
                tier: .weeklyBackup,
                title: AlarmKitConfigResolution.alertTitle(for: label),
                weekdays: days
            )
            print("[ALARM-STATE] ❌ Weekly second-tier backup failed: \(error) [\(shape)] (residentAlarmKitAlarms=\(count), auth=\(alarmManager.authorizationState))")
            AppLogger.shared.log("Weekly backup tier FAILED: '\(label)' — \(error) [\(shape)] (residentAlarms=\(count), auth=\(alarmManager.authorizationState))", category: .alarm)
            // Dump the resident inventory at failure time. This is NOT evidence
            // of a full quota — it shows whether OUR OWN id is sitting there in
            // a state that blocks re-use, which is the actual failure mode.
            if let residents = try? alarmManager.alarms {
                for a in residents {
                    let h = uuidToHashMap[a.id]
                    let isThisTier = a.id == uuid ? " ←THIS TIER" : ""
                    AppLogger.shared.log("AlarmKit inventory (at fail): uuid=\(a.id) state=\(a.state) hash=\(h.map(String.init) ?? "unmapped")\(isThisTier)", category: .alarm)
                }
            }
            // Retry once for a transient IPC failure, reclaiming the id first —
            // if the first attempt failed because the id was still live, an
            // identical retry would fail identically.
            clearResidentAlarm(id: uuid)
            try? await Task.sleep(nanoseconds: 500_000_000)
            do {
                _ = try await alarmManager.schedule(id: uuid, configuration: configuration)
                print("[ALARM-STATE] ✅ Weekly second-tier backup armed on retry: '\(label)'")
                AppLogger.shared.log("Weekly backup tier armed on retry: '\(label)'", category: .alarm)
            } catch {
                let count2 = (try? alarmManager.alarms.count) ?? -1
                print("[ALARM-STATE] ❌ Weekly second-tier backup retry failed: \(error) [\(shape)] (residentAlarmKitAlarms=\(count2))")
                AppLogger.shared.log("Weekly backup tier retry FAILED: '\(label)' — \(error) [\(shape)] (residentAlarms=\(count2))", category: .alarm)
            }
        }
    }

    /// Cancel the second-tier weekly backup (called from cancelFailsafe when
    /// the primary confirms playback, and from cancelAlarm).
    func cancelWeeklyBackup(forAlarmHash alarmID: Int) {
        let uuid = weeklyBackupUUID(forAlarmHash: alarmID)
        // Kill any deferred arm still sleeping for this alarm — cancelling the
        // tier must also cancel a pending re-arm with stale values.
        weeklyArmGeneration[alarmID] = (weeklyArmGeneration[alarmID] ?? 0) + 1
        do { try alarmManager.stop(id: uuid) } catch {}
        do {
            try alarmManager.cancel(id: uuid)
            print("[ALARM-STATE] cancelWeeklyBackup: ✅ cancelled weekly tier uuid=\(uuid)")
        } catch {
            // Not an error — tier may not exist
        }
    }

    @MainActor
    func cancelAlarm(_ alarm: AppAlarm) async {
        let hash = alarm.stableHash
        let uuid = alarmIDToUUID(hash)
        print("[ALARM-STATE] cancelAlarm called: label=\(alarm.label), hash=\(hash), uuid=\(uuid)")
        cancelWeeklyBackup(forAlarmHash: hash)
        do {
            // Remove from mappings
            uuidToHashMap.removeValue(forKey: uuid)
            uuidToScheduledFire.removeValue(forKey: uuid)

            // stop() first: cancel() throws on an .alerting alarm, and an
            // unattended fire leaves this id resident and .alerting forever.
            do { try alarmManager.stop(id: uuid) } catch {}
            try alarmManager.cancel(id: uuid)
            let remaining = (try? alarmManager.alarms.count) ?? -1
            print("[ALARM-STATE] ✅ Cancelled AlarmKit alarm: label=\(alarm.label), uuid=\(uuid), remainingAlarmKitAlarms=\(remaining)")
            AppLogger.shared.log("AlarmKit cancelled: '\(alarm.label)' uuid=\(uuid)", category: .alarm)
        } catch {
            let nsError = error as NSError
            if nsError.code != 0 {
                print("[ALARM-STATE] ⚠️ Failed to cancel AlarmKit alarm: label=\(alarm.label), error=\(error)")
            } else {
                print("[ALARM-STATE] cancelAlarm: alarm not found (already cancelled or never scheduled), label=\(alarm.label)")
            }
        }
    }
    
    func cancelAllAlarms() async {
        print("[ALARM-STATE] cancelAllAlarms called")
        do {
            let allAlarms = try alarmManager.alarms
            print("[ALARM-STATE] cancelAllAlarms: found \(allAlarms.count) AlarmKit alarms to cancel")
            for alarm in allAlarms {
                print("[ALARM-STATE] cancelAllAlarms: cancelling uuid=\(alarm.id), state=\(alarm.state)")
                // Never AlarmManager.cancelAll() — it throws unconditionally for
                // a third-party app (measured, al-bee.4). Per-id, and stop-first
                // because cancel() throws on an .alerting alarm and would abort
                // the whole loop, leaving the rest of the alarms resident.
                do { try alarmManager.stop(id: alarm.id) } catch {}
                do { try alarmManager.cancel(id: alarm.id) } catch {}
            }
            uuidToHashMap.removeAll()
            print("[ALARM-STATE] ✅ Cancelled all \(allAlarms.count) AlarmKit alarms, cleared UUID map")
        } catch {
            print("[ALARM-STATE] ❌ Failed to cancel all alarms: \(error)")
        }
    }

    /// Remove AlarmKit alarms that have no matching SwiftData alarm.
    /// Call on app launch after fetching the current set of enabled alarm hashes.
    func cleanupStaleAlarms(validAlarmHashes: Set<Int>) {
        print("[ALARM-STATE] cleanupStaleAlarms called with \(validAlarmHashes.count) valid hashes")
        do {
            let allSystemAlarms = try alarmManager.alarms
            // Include main alarm UUIDs, snooze failsafe UUIDs, and ringing guard UUIDs as valid
            var validUUIDs = Set(validAlarmHashes.map { alarmIDToUUID($0) })
            for hash in validAlarmHashes {
                validUUIDs.insert(snoozeAlarmUUID(forAlarmHash: hash))
                validUUIDs.insert(ringingGuardUUID(forAlarmHash: hash))
                validUUIDs.insert(weeklyBackupUUID(forAlarmHash: hash))
            }

            print("[ALARM-STATE] cleanupStaleAlarms: \(allSystemAlarms.count) AlarmKit alarms, \(validUUIDs.count) valid UUIDs")

            // Log every AlarmKit alarm and its state — to AppLogger, not just
            // print: the exported diagnostics previously had NO view of what is
            // resident system-side, which made "phantom ring, nothing in the
            // app" reports (a stale weekly tier ringing at an old time)
            // undiagnosable from a log export.
            for systemAlarm in allSystemAlarms {
                let hash = uuidToHashMap[systemAlarm.id]
                let isValid = validUUIDs.contains(systemAlarm.id)
                print("[ALARM-STATE]   AlarmKit alarm: uuid=\(systemAlarm.id), state=\(systemAlarm.state), hash=\(hash.map(String.init) ?? "unknown"), valid=\(isValid)")
                AppLogger.shared.log("AlarmKit inventory: uuid=\(systemAlarm.id) state=\(systemAlarm.state) hash=\(hash.map(String.init) ?? "unmapped") valid=\(isValid)", category: .alarm)
            }

            var cancelledCount = 0
            for systemAlarm in allSystemAlarms {
                if systemAlarm.state == .alerting || systemAlarm.state == .countdown {
                    print("[ALARM-STATE]   SKIPPING active alarm: uuid=\(systemAlarm.id), state=\(systemAlarm.state)")
                    continue
                }

                if !validUUIDs.contains(systemAlarm.id) {
                    try alarmManager.cancel(id: systemAlarm.id)
                    uuidToHashMap.removeValue(forKey: systemAlarm.id)
                    cancelledCount += 1
                    print("[ALARM-STATE]   REMOVED stale alarm: uuid=\(systemAlarm.id)")
                    AppLogger.shared.log("AlarmKit stale alarm REMOVED: uuid=\(systemAlarm.id)", category: .alarm)
                }
            }

            print("[ALARM-STATE] cleanupStaleAlarms complete: removed=\(cancelledCount), remaining=\(allSystemAlarms.count - cancelledCount)")
            AppLogger.shared.log("AlarmKit cleanup: \(allSystemAlarms.count) resident, \(cancelledCount) stale removed", category: .alarm)
        } catch {
            print("[ALARM-STATE] ❌ cleanupStaleAlarms failed: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
    private func observeAlarmUpdates() async {
        print("[ALARM-STATE] observeAlarmUpdates: started listening for AlarmKit updates")
        for await alarms in alarmManager.alarmUpdates {
            print("[ALARM-STATE] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("[ALARM-STATE] alarmUpdates fired: \(alarms.count) total AlarmKit alarms at \(Date())")

            // Log complete state of all alarms
            for alarm in alarms {
                let hash = uuidToHashMap[alarm.id]
                let hashStr = hash.map(String.init) ?? "unmapped"
                let info = hash.flatMap { PendingAlarmStore.shared.retrieveAlarmInfo(alarmID: $0) }
                let label = info?.label ?? "unknown"
                print("[ALARM-STATE]   uuid=\(alarm.id), state=\(alarm.state), hash=\(hashStr), label=\(label)")
            }

            // Process state changes
            for alarm in alarms {
                switch alarm.state {
                case .alerting:
                    let hash = uuidToHashMap[alarm.id]
                    print("[ALARM-STATE] 🔔 ALERTING: uuid=\(alarm.id), hash=\(hash.map(String.init) ?? "unmapped")")
                    handleAlarmAlerting(alarm)

                case .countdown:
                    let hash = uuidToHashMap[alarm.id]
                    print("[ALARM-STATE] 😴 COUNTDOWN (snoozed): uuid=\(alarm.id), hash=\(hash.map(String.init) ?? "unmapped")")
                    AppLogger.shared.log("AlarmKit state COUNTDOWN: uuid=\(alarm.id) hash=\(hash.map(String.init) ?? "unmapped")", category: .alarm)
                    handleAlarmSnoozed(alarm)

                case .paused:
                    let hash = uuidToHashMap[alarm.id]
                    print("[ALARM-STATE] ⏸️ PAUSED: uuid=\(alarm.id), hash=\(hash.map(String.init) ?? "unmapped")")
                    AppLogger.shared.log("AlarmKit state PAUSED: uuid=\(alarm.id) hash=\(hash.map(String.init) ?? "unmapped")", category: .alarm)

                case .scheduled:
                    let hash = uuidToHashMap[alarm.id]
                    print("[ALARM-STATE] ⏰ SCHEDULED: uuid=\(alarm.id), hash=\(hash.map(String.init) ?? "unmapped")")

                @unknown default:
                    print("[ALARM-STATE] ❓ UNKNOWN STATE: uuid=\(alarm.id), state=\(alarm.state)")
                }
            }
            print("[ALARM-STATE] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        }
        print("[ALARM-STATE] observeAlarmUpdates: async sequence ended (unexpected)")
    }
    
    private func handleAlarmAlerting(_ alarm: SystemAlarm) {
        var alarmHash = uuidToHashMap[alarm.id]

        // Fallback: if the UUID map lost this entry (e.g., UserDefaults didn't flush
        // before force-close), try the last-known ringing guard alarm ID.
        if alarmHash == nil {
            let lastGuardID = UserDefaults.standard.integer(forKey: lastGuardAlarmIDKey)
            if lastGuardID != 0 {
                // Verify this UUID could be a ringing guard for lastGuardID
                let expectedGuardUUID = ringingGuardUUID(forAlarmHash: lastGuardID)
                let expectedSnoozeUUID = snoozeAlarmUUID(forAlarmHash: lastGuardID)
                let expectedMainUUID = alarmIDToUUID(lastGuardID)
                if alarm.id == expectedGuardUUID || alarm.id == expectedSnoozeUUID || alarm.id == expectedMainUUID {
                    print("[ALARM-STATE] handleAlarmAlerting: UUID map miss — RECOVERED via lastRingingGuardAlarmID=\(lastGuardID)")
                    alarmHash = lastGuardID
                    // Re-add to map for future lookups
                    uuidToHashMap[alarm.id] = lastGuardID
                } else {
                    print("[ALARM-STATE] handleAlarmAlerting: UUID map miss — lastGuardID=\(lastGuardID) doesn't match uuid=\(alarm.id)")
                }
            }
        }

        guard let alarmHash else {
            print("[ALARM-STATE] ⚠️ handleAlarmAlerting: NO hash found for uuid=\(alarm.id) — uuidToHashMap has \(uuidToHashMap.count) entries, lastGuardID=\(UserDefaults.standard.integer(forKey: lastGuardAlarmIDKey))")
            return
        }

        // SKIP GUARD: AlarmKit cancel() is not guaranteed once the system has already
        // queued the alarm for delivery. If the alarm was skipped within the last 5 minutes,
        // silently stop it instead of ringing — the main notification was already cancelled
        // and rescheduled to the next occurrence when the skip was applied.
        if let container = AlarmWindowManager.shared.modelContainer,
           let alarms = try? container.mainContext.fetch(FetchDescriptor<AppAlarm>()),
           let dbAlarm = alarms.first(where: { $0.stableHash == alarmHash }),
           let skipped = dbAlarm.skippedFireDate,
           abs(Date().timeIntervalSince(skipped)) < 300 {
            let skipLabel = dbAlarm.label
            AppLogger.shared.log("AlarmKit SKIP suppressed: '\(skipLabel)' hash=\(alarmHash) — skippedFireDate=\(skipped), stopping AlarmKit", category: .alarm)
            do { try alarmManager.stop(id: alarm.id) } catch {}
            dbAlarm.skippedFireDate = nil
            return
        }

        // RECENT-FIRE GUARD: the second-tier weekly backup (+2 min) exists only
        // for the app-dead case. If this alarm was already handled within the
        // last 10 minutes and nothing is ringing for it (e.g. a re-armed tier
        // caught today's slot despite the deferral), silence it instead of
        // re-ringing a dismissed alarm.
        if alarm.id == weeklyBackupUUID(forAlarmHash: alarmHash),
           PendingAlarmStore.shared.activeRingingAlarmID() != alarmHash,
           let container = AlarmWindowManager.shared.modelContainer,
           let dbAlarms = try? container.mainContext.fetch(FetchDescriptor<AppAlarm>()),
           let dbAlarm = dbAlarms.first(where: { $0.stableHash == alarmHash }),
           let lastFire = dbAlarm.lastFireDate,
           Date().timeIntervalSince(lastFire) < 600 {
            AppLogger.shared.log("AlarmKit weekly-tier suppressed: '\(dbAlarm.label)' fired \(Int(Date().timeIntervalSince(lastFire)))s ago — stopping", category: .alarm)
            do { try alarmManager.stop(id: alarm.id) } catch {}
            return
        }

        let store = PendingAlarmStore.shared
        let info = store.retrieveAlarmInfo(alarmID: alarmHash)
        let label = info?.label ?? "unknown"
        let mission = info?.missionType ?? "unknown"

        print("[ALARM-STATE] handleAlarmAlerting: hash=\(alarmHash), uuid=\(alarm.id), label=\(label), mission=\(mission)")
        print("[ALARM-STATE] handleAlarmAlerting: isShowingAlarm=\(AlarmWindowManager.shared.isShowingAlarm), isPlaying=\(AlarmSoundPlayer.shared.isPlaying), hasPendingAlarm=\(store.hasPendingAlarm())")
        AppLogger.shared.log("AlarmKit FIRED: '\(label)' mission=\(mission) actualTime=\(Date()) uuid=\(alarm.id)", category: .alarm)

        // DUPLICATE GUARD: Prevent the same alarm hash from firing multiple times.
        // Multiple AlarmKit alarms (main, snooze failsafe, ringing guard) can all
        // transition to .alerting for the same alarm hash. Without this guard,
        // each one starts sound, schedules another ringing guard, creates a new window, etc.
        //
        // Two checks:
        // 1. handlingAlarmHash — set synchronously, catches rapid-fire duplicates
        //    before any async UI work has completed.
        // 2. activeRingingAlarmID + isShowingAlarm/isPlaying — catches duplicates
        //    that arrive after the UI is already up.
        // 3. The alarm WINDOW's own identity (al-0j7) — when a second alarm
        //    fires it takes over activeRingingAlarmID, so check 2 stopped
        //    recognising the still-showing FIRST alarm and its late ringing
        //    guard re-ran the entire fire path over the live session (al-anx).
        //    The decision itself lives in RingingGuardResolution so it can be
        //    tested; it keeps the ring-if-in-doubt bias — window identity alone
        //    never suppresses, only identity of the window actually on screen.
        let currentlyRinging = store.activeRingingAlarmID()
        let alreadyHandling = handlingAlarmHash == alarmHash
        // fadeActiveSnapshot covers the window where the player volume is ramping
        // but isPlaying may momentarily read false (audio-session reconfigure on
        // foreground) — without it, re-entry would re-run the whole fade from silence.
        // (Snapshots because this runs in the non-MainActor observeAlarmUpdates loop.)
        let alreadyShowing = RingingGuardResolution.isDuplicateAlerting(
            alarmHash: alarmHash,
            handlingAlarmHash: nil,  // reported separately as `alreadyHandling`
            activeRingingAlarmID: currentlyRinging,
            showingAlarmID: AlarmWindowManager.currentAlarmIDSnapshot,
            isShowingAlarm: AlarmWindowManager.shared.isShowingAlarm,
            isAudioPlaying: AlarmSoundPlayer.shared.isPlaying,
            isFadeActive: VolumeManager.fadeActiveSnapshot
        )
        if alreadyHandling || alreadyShowing {
            print("[ALARM-STATE] handleAlarmAlerting: DUPLICATE — alarm hash=\(alarmHash) (handling=\(alreadyHandling), showing=\(alreadyShowing)), stopping this AlarmKit alarm")
            AppLogger.shared.log("AlarmKit DUPLICATE suppressed: '\(label)' hash=\(alarmHash) handling=\(alreadyHandling) showing=\(alreadyShowing)", category: .alarm)
            // Must use stop() for .alerting alarms — cancel() on an alerting alarm
            // causes AlarmKit to re-fire it ~2s later (iOS 26 behavior), creating an
            // infinite loop of system alert banners for ringing guard duplicates.
            do { try alarmManager.stop(id: alarm.id) } catch {}
            // NOTE: no re-arm here. The ringing guard is kept alive by the
            // rolling mechanism (startGuardRolling) which pushes it forward
            // every 10s while still .scheduled — it should never reach
            // .alerting while the app is alive. If one slips through anyway,
            // the roll timer re-arms it on its next tick.
            return
        }
        
        // Mark this alarm hash as being handled (cleared when alarm is dismissed/snoozed)
        handlingAlarmHash = alarmHash
        // Store the alerting UUID so snoozeAlarm() can call stop(id:) to dismiss the system notification
        currentAlertingAlarmUUID = alarm.id

        // Telemetry: which recovery tier is delivering this ring? The firing
        // UUID is the only reliable signal — each tier has its own
        // deterministic UUID (see Documents/16-FORCE-KILL-RECOVERY.md). The
        // expected fire time is the tier's own designed offset, which is
        // exactly what the schedule was built from: +5s for the main/snooze
        // failsafe, +2 min for the weekly backup, and "now" for the ringing
        // guard (it is armed relative to the ring, not to a clock time).
        // Claimed BEFORE the audio work below, which can confirm playback.
        let deliveredPath: AlarmDeliveryPath
        let tierOffset: TimeInterval
        if alarm.id == weeklyBackupUUID(forAlarmHash: alarmHash) {
            deliveredPath = .alarmKitWeeklyBackup
            tierOffset = 120
        } else if alarm.id == ringingGuardUUID(forAlarmHash: alarmHash) {
            deliveredPath = .ringingGuard
            tierOffset = 0
        } else {
            deliveredPath = .alarmKitFailsafe
            tierOffset = 5
        }
        let expectedFire = Date().addingTimeInterval(-tierOffset)
        Task { @MainActor in
            AlarmRingReporter.shared.willDeliver(path: deliveredPath, expectedFire: expectedFire)
        }

        // AlarmKit failsafe fired — cancel the primary timer to prevent double-fire.
        LocalNotificationScheduler.shared.cancelTimer(for: alarmHash)

        if let info {
            store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                alarmID: alarmHash,
                label: info.label,
                missionType: MissionType(rawValue: info.missionType) ?? .none,
                soundID: info.soundID,
                volumeLevel: info.volumeLevel
            )
            store.setPendingAlarmFull(
                alarmID: alarmHash,
                label: info.label,
                missionType: info.missionType,
                soundID: info.soundID,
                volumeLevel: info.volumeLevel
            )
            print("[ALARM-STATE] handleAlarmAlerting: stored pending alarm (in-memory + UserDefaults): \(info.label)")
        } else {
            // No pre-stored info — try to recover from SwiftData
            var recovered = false
            if let container = AlarmWindowManager.shared.modelContainer {
                let ctx = container.mainContext
                if let alarms = try? ctx.fetch(FetchDescriptor<AppAlarm>()),
                   let dbAlarm = alarms.first(where: { $0.stableHash == alarmHash }) {
                    let mType = dbAlarm.mission.type
                    store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                        alarmID: alarmHash,
                        label: dbAlarm.label,
                        missionType: mType,
                        soundID: dbAlarm.soundName,
                        volumeLevel: dbAlarm.customVolumeLevel
                    )
                    store.setPendingAlarmFull(
                        alarmID: alarmHash,
                        label: dbAlarm.label,
                        missionType: mType.rawValue,
                        soundID: dbAlarm.soundName,
                        volumeLevel: dbAlarm.customVolumeLevel
                    )
                    // Re-cache for future recoveries
                    PendingAlarmStore.shared.storeFullAlarmInfo(alarmID: alarmHash, alarm: dbAlarm)
                    recovered = true
                    print("[ALARM-STATE] handleAlarmAlerting: recovered alarm info from DB: '\(dbAlarm.label)' sound=\(dbAlarm.soundName)")
                }
            }
            if !recovered {
                store.setPendingAlarm(alarmHash)
                print("[ALARM-STATE] handleAlarmAlerting: ⚠️ no pre-stored info for hash=\(alarmHash), stored ID only")
            }
        }

        // Set the independent "active ringing alarm" key — survives
        // any number of force-close cycles until explicit dismiss/snooze.
        store.setActiveRingingAlarm(alarmHash)
        
        // Start alarm sound
        if let info {
            let settings = DeviceSettings.shared
            let volume = info.volumeLevel ?? settings.alarmVolumeLevel
            // Resolve fade settings per-alarm when the alarm is in the DB so we
            // honor customFadeInDuration and the 0→30s rule (effectiveFadeInDurationSeconds).
            // Fall back to the global setting otherwise. Previously this used
            // `settings.alarmFadeInDuration * 60` directly, which ignored per-alarm
            // fades and turned a stored 0 ("30 seconds") into a 0-second instant ramp.
            // Resolve the alarm for its per-alarm fade/volume settings. The DB is
            // the first choice, but a miss here must NOT fall through to the
            // global setting: `settings.alarmFadeInEnabled` is off for an alarm
            // whose fade is configured per-alarm, and this handler would then
            // start the ring at FULL VOLUME (or stomp a ramp the timer path had
            // armed) — the "fade-in isn't working" bug. The recovery blob carries
            // customFadeInEnabled/Duration, so it is a faithful second source.
            let fadeAlarm: AppAlarm? = {
                if let container = AlarmWindowManager.shared.modelContainer,
                   let alarms = try? container.mainContext.fetch(FetchDescriptor<AppAlarm>()),
                   let match = alarms.first(where: { $0.stableHash == alarmHash }) {
                    return match
                }
                let reconstructed = PendingAlarmStore.shared.reconstructAlarm(alarmID: alarmHash)
                if reconstructed != nil {
                    AppLogger.shared.log("AlarmKit alerting: alarm not in DB — fade/volume resolved from the recovery blob", category: .audio)
                }
                return reconstructed
            }()
            let fadeInEnabled = fadeAlarm?.effectiveFadeInEnabled(settings: settings) ?? settings.alarmFadeInEnabled
            let fadeInDurationSeconds = fadeAlarm?.effectiveFadeInDurationSeconds(settings: settings)
                ?? (settings.alarmFadeInDuration == 0 ? 30 : TimeInterval(settings.alarmFadeInDuration * 60))
            let radioStationID = fadeAlarm?.radioStationID
            let radioStationName = fadeAlarm?.radioStationName
            let radioStationURL = fadeAlarm?.radioStationURL
            print("[ALARM-STATE] handleAlarmAlerting: starting sound=\(info.soundID), volume=\(volume), fadeIn=\(fadeInEnabled ? "\(Int(fadeInDurationSeconds))s" : "off")")
            Task { @MainActor in
                // Configure audio session BEFORE setting volume. Changing to
                // .playAndRecord re-routes audio which can cause a brief
                // volume spike if volume is already set to a low fade-in level.
                do {
                    try AppAudioSession.setCategory(.playAndRecord, mode: .default, options: AppAudioSession.alarmFireCategoryOptions())
                    try AppAudioSession.setActive(true)
                } catch {
                    print("[ALARM-STATE] handleAlarmAlerting: audio session error: \(error)")
                }

                // Set system volume and await confirmation before starting audio.
                // setSystemVolumeBeforePlayback: waits for slider to be ready,
                // sets volume, then waits 150ms for the OS to process the slider
                // action. This prevents the alarm starting at the wrong volume
                // on cold-start / background wakeup when the slider isn't ready yet.
                if fadeInEnabled {
                    VolumeManager.shared.prepareForFadeIn(to: Float(volume))
                } else {
                    await VolumeManager.shared.setSystemVolumeBeforePlayback(to: Float(volume))
                }

                // Guard: if snooze/dismiss already ran, don't restart sound.
                // unlockIfRinging() checks activeRingingAlarmID (cleared synchronously
                // by snooze/dismiss) so it catches the race where the Task executes
                // after stop() but before the window is hidden.
                guard AlarmSoundPlayer.shared.unlockIfRinging() else {
                    print("[ALARM-STATE] handleAlarmAlerting: sound task skipped — alarm already snoozed/dismissed")
                    return
                }
                // Always start at player volume 0 — 1-second silent entry regardless of fade-in setting
                await AlarmSoundPlayer.shared.play(soundID: info.soundID, initialVolume: 0.0)
                // Playback outcome for this ring. This path has no retry, so a
                // miss here is a silent start — reported only while the alarm
                // is still ringing (a dismiss during play isn't a failure).
                if AlarmSoundPlayer.shared.isPlaying {
                    AlarmRingReporter.shared.audioStarted()
                } else if PendingAlarmStore.shared.activeRingingAlarmID() != nil {
                    AlarmRingReporter.shared.audioFailed()
                }
                // Re-check after play — snooze may have run during the await.
                // Use activeRingingAlarmID (set at fire, cleared only on dismiss/snooze)
                // rather than isShowingAlarm: on a locked-device fire the alarm window
                // is created asynchronously and often isn't up yet here. The old
                // isShowingAlarm-only check stopped the sound before the fade ramp armed,
                // and recovery then restarted it at full volume — defeating the fade.
                guard AlarmWindowManager.shared.isShowingAlarm
                    || PendingAlarmStore.shared.activeRingingAlarmID() != nil else {
                    print("[ALARM-STATE] handleAlarmAlerting: alarm dismissed during play — stopping")
                    AlarmSoundPlayer.shared.stop()
                    return
                }
                // Radio layer: start the stream attempt during the silent
                // entry so a healthy stream cuts in before the tone is heard;
                // the capped grace below keeps the tone guaranteed (see
                // RadioAlarmStreamer). Never affects failsafe/backup logic.
                RadioAlarmStreamer.shared.beginAttempt(
                    stationID: radioStationID,
                    stationName: radioStationName,
                    urlString: radioStationURL
                )
                try? await Task.sleep(for: .seconds(1))
                if radioStationURL != nil {
                    // Tiered by how far along the stream already is — see
                    // RadioAlarmStreamer.confirmationGrace.
                    await RadioAlarmStreamer.shared.waitForConfirmation(
                        upTo: RadioAlarmStreamer.shared.confirmationGrace
                    )
                }
                // The awaits above (1s silent entry + radio grace) are long
                // enough for the user to dismiss — a fast tap-dismiss on device
                // was observed arming a 240s fade 30ms AFTER teardown, leaving
                // stale fade state for the next ring. Never raise volume or arm
                // a ramp for a ring that no longer exists.
                guard PendingAlarmStore.shared.activeRingingAlarmID() != nil else {
                    AppLogger.shared.log("AlarmKit alerting: dismissed during silent entry — skipping fade/volume raise", category: .audio)
                    return
                }
                if fadeInEnabled {
                    // …IfNeeded: the timer path may already be mid-ramp for this
                    // same ring, and restarting would drop it back to silence.
                    VolumeManager.shared.startPlayerFadeInIfNeeded(duration: fadeInDurationSeconds)
                } else if VolumeManager.shared.fadeActive {
                    // A fade is ALREADY running for this ring — the in-app timer
                    // path armed it — and this handler disagreed about whether one
                    // was wanted. That happens whenever the DB lookup above misses
                    // (`fadeAlarm == nil`), because the fallback is the GLOBAL
                    // alarmFadeInEnabled, which is off for an alarm whose fade is
                    // set per-alarm. Slamming 1.0 here was audible as "the fade
                    // isn't working": silence for ~5s, then full volume the moment
                    // the AlarmKit failsafe alerted. The running ramp is the
                    // authority; just keep it ticking.
                    AppLogger.shared.log("AlarmKit alerting: fade already in flight — keeping the ramp, not jumping to full", category: .audio)
                    VolumeManager.shared.ensureFadeRunning()
                } else {
                    AlarmSoundPlayer.shared.setPlayerVolume(1.0)
                }
                print("[ALARM-STATE] handleAlarmAlerting: sound playback started")
            }
        }

        // Publish MQTT state — unless the alarm is MQTT-hidden (al-5a94): this
        // failsafe path must stay as silent toward HA as the primary ring path.
        let settings = DeviceSettings.shared
        let mqttHidden: Bool = {
            guard let container = AlarmWindowManager.shared.modelContainer,
                  let alarms = try? container.mainContext.fetch(FetchDescriptor<AppAlarm>()) else { return false }
            return alarms.first(where: { $0.stableHash == alarmHash })?.excludeFromMQTT ?? false
        }()
        if !mqttHidden {
            HAIntegrationRouter.shared.publishAlarmState(.ringing, settings: settings)
            if let info {
                HAIntegrationRouter.shared.publishActiveAlarmName(info.label, settings: settings)
                let missionType = MissionType(rawValue: info.missionType) ?? .none
                HAIntegrationRouter.shared.publishActiveAlarmMission(missionType.rawValue.lowercased(), settings: settings)
            }
        }

        // Start alarm notifications for lock-screen presence and vibration
        Task { @MainActor in
            let label = info?.label ?? "Alarm"

            print("[ALARM-STATE] handleAlarmAlerting: starting alarm notifications for \(label)")
            // When fade-in is active, always vibrate — audio starts quiet but
            // the user still needs tactile feedback.
            let settings = DeviceSettings.shared
            AlarmLiveActivityManager.shared.vibrationEnabled = settings.alarmVibrationEnabled || settings.alarmFadeInEnabled
            // In AlarmKit mode, AlarmKit provides its own persistent system notification.
            // Suppress the recurring lock-screen notifications but keep vibration active.
            AlarmLiveActivityManager.shared.suppressLockScreenNotifications = true
            AlarmLiveActivityManager.shared.startAlarmNotifications(
                alarmLabel: label,
                alarmID: alarmHash
            )
        }

        // Proactively schedule a ringing guard BEFORE any async UI work.
        // If the user kills the app before the alarm window is fully presented
        // (before currentAlarm is set), the background handler's ringing guard
        // path won't fire. This ensures a follow-up AlarmKit alarm exists.
        let guardLabel = info?.label ?? "Alarm"
        let guardMission = MissionType(rawValue: info?.missionType ?? "") ?? .none
        let guardSound = info?.soundID ?? "default"
        // Resolve "does this alarm require a mission?" from the full stored blob so a
        // multi-tap/hold Tap alarm (mission type .none but a real mission) still gets
        // CompleteMissionIntent. Fall back to the plain mission-type string if the
        // reconstruction blob is unavailable.
        let guardRequiresMission = PendingAlarmStore.shared.reconstructAlarm(alarmID: alarmHash)
            .map { !$0.missionSequence.isEmpty } ?? (guardMission != .none)
        Task {
            await scheduleRingingGuardFromInfo(
                alarmID: alarmHash,
                label: guardLabel,
                requiresMission: guardRequiresMission,
                soundID: guardSound
            )
        }

        // Try to show the alarm UI immediately
        Task { @MainActor in
            print("[ALARM-STATE] handleAlarmAlerting: calling checkAndShowPendingAlarm()")
            AlarmWindowManager.shared.checkAndShowPendingAlarm()
        }

        print("[ALARM-STATE] handleAlarmAlerting: handler complete for hash=\(alarmHash)")
    }
    
    private func handleAlarmSnoozed(_ alarm: SystemAlarm) {
        guard let alarmHash = uuidToHashMap[alarm.id] else {
            print("[ALARM-STATE] ⚠️ handleAlarmSnoozed: NO hash found for uuid=\(alarm.id)")
            return
        }

        let info = PendingAlarmStore.shared.retrieveAlarmInfo(alarmID: alarmHash)
        let label = info?.label ?? "unknown"
        print("[ALARM-STATE] handleAlarmSnoozed: hash=\(alarmHash), uuid=\(alarm.id), label=\(label)")
        print("[ALARM-STATE] handleAlarmSnoozed: isShowingAlarm=\(AlarmWindowManager.shared.isShowingAlarm), isPlaying=\(AlarmSoundPlayer.shared.isPlaying)")
        AppLogger.shared.log("AlarmKit snoozed (countdown): '\(label)' hash=\(alarmHash)", category: .alarm)

        // Stop in-app alarm sound and restore the user's media volume for the
        // snooze interval (re-raised when the snooze re-fires). No-op if this app
        // never raised the volume (AlarmKit-only snooze while the app was killed).
        Task { @MainActor in
            AlarmSoundPlayer.shared.stop()
            VolumeManager.shared.restoreOriginalVolume()
            print("[ALARM-STATE] handleAlarmSnoozed: stopped alarm sound, restored volume")
        }

        // Publish snoozed state to MQTT — MQTT-hidden alarms stay silent
        // (al-5a94; the AlarmKit sheet can offer snooze even when the in-app
        // alarm disables it, so this path is reachable for them).
        let settings = DeviceSettings.shared
        let snoozedHidden: Bool = {
            guard let container = AlarmWindowManager.shared.modelContainer,
                  let alarms = try? container.mainContext.fetch(FetchDescriptor<AppAlarm>()) else { return false }
            return alarms.first(where: { $0.stableHash == alarmHash })?.excludeFromMQTT ?? false
        }()
        if !snoozedHidden {
            HAIntegrationRouter.shared.publishAlarmState(.snoozed, settings: settings)
        }

        // Post notification to update UI about snooze
        NotificationCenter.default.post(
            name: NSNotification.Name("AlarmSnoozed"),
            object: nil,
            userInfo: ["alarmIDHash": alarmHash]
        )

        print("[ALARM-STATE] handleAlarmSnoozed: posted AlarmSnoozed notification, handler complete")
    }

    // MARK: - Snooze Failsafe

    /// Schedule a one-shot AlarmKit alarm as a failsafe for the snooze re-fire.
    /// Uses `.fixed(Date)` so the alarm fires at the exact snooze end time,
    /// even if the app is killed during the snooze interval.
    /// Returns `true` when the AlarmKit failsafe is confirmed scheduled.
    /// Callers MUST NOT report the failsafe as confirmed on a `false` return —
    /// a swallowed schedule() failure here previously left a silent force-kill
    /// gap for the whole snooze period.
    @discardableResult
    func scheduleSnoozeFailsafe(alarm: AppAlarm, alarmID: Int, snoozeUntil: Date) async -> Bool {
        // Use a distinct UUID for the snooze failsafe so it doesn't collide with
        // the main alarm's UUID. Derived from alarmID + "snooze" suffix.
        let snoozeUUID = snoozeAlarmUUID(forAlarmHash: alarmID)

        // Clear any existing snooze failsafe first — stop-then-cancel. The
        // previous one is USUALLY .scheduled (where stop() is the no-op), but a
        // snooze failsafe that fired unattended stays resident and .alerting,
        // and there cancel() throws and leaves the id live for schedule().
        clearResidentAlarm(id: snoozeUUID)

        let alertContent = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: AlarmKitConfigResolution.alertTitle(for: alarm.label))
        )
        let presentation = AlarmPresentation(alert: alertContent)

        // Stop button opens the app and hands off to the in-app alarm UI.
        // missionSequence.isEmpty (not mission.type == .none) so a multi-tap/hold
        // Tap alarm — a real mission — also gets CompleteMissionIntent.
        let stopIntent: any LiveActivityIntent
        if alarm.missionSequence.isEmpty {
            stopIntent = DefaultStopIntent(alarmID: alarmID, alarmUUID: snoozeUUID)
        } else {
            stopIntent = CompleteMissionIntent(alarmID: alarmID, alarmUUID: snoozeUUID)
        }

        let alarmSound: AlertConfiguration.AlertSound
        if let sound = AlarmSoundManager.shared.getSound(id: alarm.soundName),
           let soundName = sound.notificationSoundName {
            alarmSound = .named(soundName)
        } else {
            alarmSound = .default
        }

        struct AlarmMetadataContent: AlarmMetadata {
            let alarmID: Int
        }

        // Add +5s so the in-app snooze timer fires first; AlarmKit is the failsafe backup.
        let snoozeDelay: TimeInterval = 5
        let failsafeDate = snoozeUntil.addingTimeInterval(snoozeDelay)
        
        let configuration = AlarmManager.AlarmConfiguration(
            schedule: .fixed(failsafeDate),
            attributes: AlarmAttributes(
                presentation: presentation,
                metadata: AlarmMetadataContent(alarmID: alarmID),
                tintColor: Color.blue
            ),
            stopIntent: stopIntent,
            sound: alarmSound
        )

        // Map the snooze UUID back to the same alarm hash
        uuidToHashMap[snoozeUUID] = alarmID

        // Update the cached alarm info with the current snooze count.
        // storeFullAlarmInfo() was called at initial schedule time (count = 0).
        // After snoozing, alarm.snoozeCount has been incremented. Without this
        // update, reconstructAlarm() on cold start would show count = 0.
        PendingAlarmStore.shared.updateStoredSnoozeCount(alarmID: alarmID, snoozeCount: alarm.snoozeCount)

        // Try twice — a transient IPC failure here must not silently cost the
        // user their force-kill backup for the whole snooze period.
        for attempt in 1...2 {
            do {
                let scheduled = try await alarmManager.schedule(id: snoozeUUID, configuration: configuration)
                print("[ALARM-STATE] scheduleSnoozeFailsafe: ✅ scheduled for \(snoozeUntil) (+\(Int(snoozeDelay))s failsafe at \(failsafeDate)), uuid=\(snoozeUUID), state=\(scheduled.state)")
                AppLogger.shared.log("Snooze failsafe scheduled: '\(alarm.label)' fires at \(snoozeUntil) uuid=\(snoozeUUID)", category: .alarm)

                // Fire-and-forget verification — don't block the caller (which needs
                // to dismiss the alarm window ASAP after the schedule() IPC completes).
                let mapSnapshot = uuidToHashMap
                Task.detached {
                    if let allAlarms = try? AlarmManager.shared.alarms {
                        let found = allAlarms.first(where: { $0.id == snoozeUUID })
                        print("[ALARM-STATE] scheduleSnoozeFailsafe: VERIFY — \(allAlarms.count) total AlarmKit alarms, snooze UUID \(found != nil ? "FOUND (state=\(found!.state))" : "NOT FOUND")")
                        for a in allAlarms {
                            let hash = mapSnapshot[a.id]
                            print("[ALARM-STATE]   verify: uuid=\(a.id), state=\(a.state), hash=\(hash.map(String.init) ?? "unmapped")")
                        }
                    }
                }
                return true
            } catch {
                let shape = AlarmKitConfigResolution.describe(
                    tier: .snoozeFailsafe,
                    title: AlarmKitConfigResolution.alertTitle(for: alarm.label)
                )
                print("[ALARM-STATE] scheduleSnoozeFailsafe: ❌ FAILED to schedule (attempt \(attempt)): \(error) [\(shape)]")
                AppLogger.shared.log("Snooze failsafe schedule FAILED (attempt \(attempt)): '\(alarm.label)' — \(error) [\(shape)]", category: .alarm)
                if attempt == 1 {
                    // Reclaim the id before retrying: if the first attempt was
                    // rejected because this snooze id is still resident and
                    // .alerting from an unattended fire, an identical retry
                    // fails identically. cancel() alone throws there.
                    clearResidentAlarm(id: snoozeUUID)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        return false
    }

    /// Cancel any pending snooze failsafe alarm for the given alarm hash.
    func cancelSnoozeFailsafe(forAlarmHash alarmID: Int) {
        let snoozeUUID = snoozeAlarmUUID(forAlarmHash: alarmID)
        do {
            // stop-then-cancel. The failsafe is USUALLY .scheduled, where stop()
            // is the no-op and cancel() does the work — but if it already fired
            // unattended it is resident and .alerting, where cancel() THROWS and
            // the id stays live, poisoning the next schedule() on it.
            do { try alarmManager.stop(id: snoozeUUID) } catch {}
            try alarmManager.cancel(id: snoozeUUID)
            print("[ALARM-STATE] cancelSnoozeFailsafe: ✅ cancelled snooze failsafe uuid=\(snoozeUUID)")
            AppLogger.shared.log("Snooze failsafe cancelled: hash=\(alarmID) uuid=\(snoozeUUID)", category: .alarm)
        } catch {
            // Not an error — snooze failsafe may not exist
        }
        uuidToHashMap.removeValue(forKey: snoozeUUID)
    }

    /// Generate a deterministic UUID for a snooze failsafe alarm.
    /// Distinct from the main alarm UUID by using a different hash base.
    private func snoozeAlarmUUID(forAlarmHash hash: Int) -> UUID {
        // XOR with a constant to create a different but deterministic hash.
        // The mask lives in AlarmKitAlarmIdentity ("SNOOZE" in hex) so the
        // reverse mapping used by slept-through reconciliation cannot drift.
        AlarmKitAlarmIdentity.snoozeUUID(forAlarmHash: hash)
    }

    // MARK: - Ringing Guard
    
    /// Schedule a short-delay AlarmKit alarm as a safety net when the app enters
    /// background while an alarm is actively ringing.  If the user force-kills the
    /// app, this fires within a few seconds and re-presents the AlarmKit system UI.
    func scheduleRingingGuard(alarm: AppAlarm, alarmID: Int) async {
        let guardUUID = ringingGuardUUID(forAlarmHash: alarmID)
        
        // Clear any existing ringing guard first. stop-then-cancel, because a
        // guard that reached .alerting (force-kill, unattended) stays resident
        // and cancel() throws on it — leaving the id live for schedule().
        clearResidentAlarm(id: guardUUID)

        let alertContent = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: AlarmKitConfigResolution.alertTitle(for: alarm.label))
        )
        let presentation = AlarmPresentation(alert: alertContent)
        
        // missionSequence.isEmpty so a multi-tap/hold Tap alarm (a real mission)
        // also opens the app via CompleteMissionIntent.
        let stopIntent: any LiveActivityIntent
        if alarm.missionSequence.isEmpty {
            stopIntent = DefaultStopIntent(alarmID: alarmID, alarmUUID: guardUUID)
        } else {
            stopIntent = CompleteMissionIntent(alarmID: alarmID, alarmUUID: guardUUID)
        }

        let alarmSound: AlertConfiguration.AlertSound
        if let sound = AlarmSoundManager.shared.getSound(id: alarm.soundName),
           let soundName = sound.notificationSoundName {
            alarmSound = .named(soundName)
        } else {
            alarmSound = .default
        }
        
        struct AlarmMetadataContent: AlarmMetadata {
            let alarmID: Int
        }
        
        // Fire 15 seconds from now — long enough that the user can briefly switch
        // apps (check a text, etc.) and return without triggering a ghost AlarmKit
        // alarm, but short enough to catch a force-kill quickly.
        let guardFireDate = Date().addingTimeInterval(15)
        
        let configuration = AlarmManager.AlarmConfiguration(
            schedule: .fixed(guardFireDate),
            attributes: AlarmAttributes(
                presentation: presentation,
                metadata: AlarmMetadataContent(alarmID: alarmID),
                tintColor: Color.blue
            ),
            stopIntent: stopIntent,
            sound: alarmSound
        )
        
        uuidToHashMap[guardUUID] = alarmID
        // Persist the alarm ID separately as a fallback — if the UUID map
        // doesn't survive force-close, handleAlarmAlerting can still recover.
        UserDefaults.standard.set(alarmID, forKey: lastGuardAlarmIDKey)
        UserDefaults.standard.synchronize()

        do {
            let scheduled = try await alarmManager.schedule(id: guardUUID, configuration: configuration)
            print("[ALARM-STATE] scheduleRingingGuard: ✅ scheduled for \(guardFireDate), uuid=\(guardUUID), state=\(scheduled.state)")
            AppLogger.shared.log("Ringing guard scheduled: hash=\(alarmID) fires at \(guardFireDate) uuid=\(guardUUID)", category: .alarm)
            // Race condition fix: snooze/dismiss may have called cancelRingingGuard BEFORE
            // this schedule() call completed (async Task). If the alarm window is no longer
            // showing, immediately cancel the guard so it doesn't fire as a spurious banner.
            let alreadyShowing = await MainActor.run { AlarmWindowManager.shared.isShowingAlarm }
            if !alreadyShowing {
                do { try alarmManager.cancel(id: guardUUID) } catch {}
                print("[ALARM-STATE] scheduleRingingGuard: alarm no longer showing — immediately cancelled guard to prevent spurious banner")
            } else {
                // Keep pushing the guard forward so it never alerts in-process.
                startGuardRolling(alarmID: alarmID, label: alarm.label, requiresMission: !alarm.missionSequence.isEmpty, soundID: alarm.soundName)
            }
        } catch {
            let shape = AlarmKitConfigResolution.describe(
                tier: .ringingGuard,
                title: AlarmKitConfigResolution.alertTitle(for: alarm.label)
            )
            print("[ALARM-STATE] scheduleRingingGuard: ❌ failed: \(error) [\(shape)]")
            AppLogger.shared.log("Ringing guard schedule FAILED: '\(alarm.label)' hash=\(alarmID) — \(error) [\(shape)]", category: .alarm)
        }
    }

    /// Schedule a ringing guard using stored alarm info (no full AppAlarm needed).
    /// Used when AlarmKit fires and the app hasn't fully loaded the alarm from DB yet.
    /// - Parameter keepArmedWhileShowing: post-schedule race policy. `false`
    ///   (default, recovery path): if the alarm window came up while schedule()
    ///   was in flight, presentAlarmWindow's own guard took over — cancel this
    ///   one. `true` (re-arm path): the guard must stay armed exactly BECAUSE
    ///   the window is showing (foreground swipe-kill gives no scenePhase
    ///   callback); only cancel if the window is already gone.
    func scheduleRingingGuardFromInfo(alarmID: Int, label: String, requiresMission: Bool, soundID: String, keepArmedWhileShowing: Bool = false) async {
        let guardUUID = ringingGuardUUID(forAlarmHash: alarmID)

        // Clear any existing ringing guard first — stop-then-cancel, see
        // clearResidentAlarm. This path re-uses the same id every 10s while
        // rolling, so a single .alerting leftover would break every later roll.
        clearResidentAlarm(id: guardUUID)

        let alertContent = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: AlarmKitConfigResolution.alertTitle(for: label))
        )
        let presentation = AlarmPresentation(alert: alertContent)

        // requiresMission (from missionSequence) so a multi-tap/hold Tap alarm
        // opens the app via CompleteMissionIntent.
        let stopIntent: any LiveActivityIntent
        if !requiresMission {
            stopIntent = DefaultStopIntent(alarmID: alarmID, alarmUUID: guardUUID)
        } else {
            stopIntent = CompleteMissionIntent(alarmID: alarmID, alarmUUID: guardUUID)
        }
        
        let alarmSound: AlertConfiguration.AlertSound
        if let sound = AlarmSoundManager.shared.getSound(id: soundID),
           let soundName = sound.notificationSoundName {
            alarmSound = .named(soundName)
        } else {
            alarmSound = .default
        }
        
        struct AlarmMetadataContent: AlarmMetadata {
            let alarmID: Int
        }
        
        let guardFireDate = Date().addingTimeInterval(15)
        
        let configuration = AlarmManager.AlarmConfiguration(
            schedule: .fixed(guardFireDate),
            attributes: AlarmAttributes(
                presentation: presentation,
                metadata: AlarmMetadataContent(alarmID: alarmID),
                tintColor: Color.blue
            ),
            stopIntent: stopIntent,
            sound: alarmSound
        )
        
        uuidToHashMap[guardUUID] = alarmID
        // Persist the alarm ID separately as a fallback — if the UUID map
        // doesn't survive force-close, handleAlarmAlerting can still recover.
        UserDefaults.standard.set(alarmID, forKey: lastGuardAlarmIDKey)
        UserDefaults.standard.synchronize()

        do {
            let scheduled = try await alarmManager.schedule(id: guardUUID, configuration: configuration)
            print("[ALARM-STATE] scheduleRingingGuardFromInfo: ✅ scheduled for \(guardFireDate), uuid=\(guardUUID), state=\(scheduled.state)")
            AppLogger.shared.log("Ringing guard scheduled (from info): '\(label)' hash=\(alarmID) fires at \(guardFireDate)", category: .alarm)

            // Race condition fix — policy depends on the caller (see doc comment):
            // recovery path cancels when the window took over; roll path cancels
            // when the window is gone (alarm resolved while schedule() was in flight).
            let alreadyShowing = await MainActor.run { AlarmWindowManager.shared.isShowingAlarm }
            if keepArmedWhileShowing {
                if !alreadyShowing {
                    do { try alarmManager.cancel(id: guardUUID) } catch {}
                    print("[ALARM-STATE] scheduleRingingGuardFromInfo: alarm no longer showing — cancelled rolled guard")
                    stopGuardRolling()
                }
                // Rolling continues via the existing timer (this call is its tick).
            } else if alreadyShowing {
                do { try alarmManager.cancel(id: guardUUID) } catch {}
                print("[ALARM-STATE] scheduleRingingGuardFromInfo: alarm already showing — immediately cancelled guard to prevent spurious banner")
            } else {
                // Recovery path with no window yet (cold start / background ring):
                // start rolling so this guard also never alerts in-process. It is
                // replaced (guard + roller) when presentAlarmWindow takes over.
                startGuardRolling(alarmID: alarmID, label: label, requiresMission: requiresMission, soundID: soundID)
            }
        } catch {
            let shape = AlarmKitConfigResolution.describe(
                tier: .ringingGuard,
                title: AlarmKitConfigResolution.alertTitle(for: label)
            )
            print("[ALARM-STATE] scheduleRingingGuardFromInfo: ❌ failed: \(error) [\(shape)]")
            AppLogger.shared.log("Ringing guard schedule FAILED (from info): '\(label)' hash=\(alarmID) — \(error) [\(shape)]", category: .alarm)
        }
    }
    
    // MARK: - Rolling Ringing Guard
    // The guard must exist every moment an alarm rings (a foreground
    // swipe-kill gives no scenePhase callback), but letting it reach
    // .alerting fires a full-volume system alert that interrupts the app's
    // audio session — device logs on iOS 27 beta showed repeated guard
    // self-fires leaving the player permanently silent. Solution: roll it
    // forward. Every 10s the timer cancels + reschedules the guard to
    // now+15s while it is still .scheduled (cancel is reliable
    // pre-delivery), so the guard never alerts while the app is alive —
    // yet an alarm ≤15s out is always armed if the process dies, because
    // the roll timer dies with the process.

    private var guardRollTimer: Timer?
    private var guardRollInfo: (alarmID: Int, label: String, requiresMission: Bool, soundID: String)?

    private func startGuardRolling(alarmID: Int, label: String, requiresMission: Bool, soundID: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.guardRollInfo = (alarmID, label, requiresMission, soundID)
            self.guardRollTimer?.invalidate()
            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                guard let self, let info = self.guardRollInfo else { return }
                // Stop rolling once nothing is live for this alarm —
                // dismiss/snooze also cancel the guard explicitly, this is
                // the belt-and-braces path.
                //
                // "Live" is deliberately wider than the global ringing flag
                // (al-kfe): a SECOND alarm firing takes that flag over, and the
                // old `activeRingingAlarmID == info.alarmID` test then stopped
                // the FIRST alarm's roller while its alarm was still on screen.
                // The guard was left armed at its last rolled time and fired
                // over the live session ~6s later, restarting audio and killing
                // the other alarm's radio stream (al-anx, 2026-08-05 06:30:06).
                // Screen and queue membership are read from the non-isolated
                // snapshots because this tick is not on the main actor.
                guard RingingGuardResolution.shouldKeepRolling(
                    rolledAlarmID: info.alarmID,
                    activeRingingAlarmID: PendingAlarmStore.shared.activeRingingAlarmID(),
                    showingAlarmID: AlarmWindowManager.currentAlarmIDSnapshot,
                    queuedAlarmIDs: AlarmWindowManager.queuedAlarmIDsSnapshot
                ) else {
                    self.stopGuardRolling()
                    return
                }
                Task {
                    await self.scheduleRingingGuardFromInfo(
                        alarmID: info.alarmID,
                        label: info.label,
                        requiresMission: info.requiresMission,
                        soundID: info.soundID,
                        keepArmedWhileShowing: true
                    )
                }
            }
            // .common mode so the roll continues during UI tracking; the
            // background-audio keep-alive keeps the run loop serviced while
            // the app rings in the background.
            RunLoop.main.add(timer, forMode: .common)
            self.guardRollTimer = timer
        }
    }

    func stopGuardRolling() {
        DispatchQueue.main.async { [weak self] in
            self?.guardRollTimer?.invalidate()
            self?.guardRollTimer = nil
            self?.guardRollInfo = nil
        }
    }

    /// Cancel any pending ringing guard for the given alarm hash.
    /// The UUID→hash mapping is intentionally KEPT in the map (not removed).
    /// Removing it here caused the second force-close recovery to fail:
    /// presentAlarmWindow cancels the proactive guard and removes the mapping,
    /// then if the UUID map doesn't flush to disk before a force-close, the
    /// next cold start can't look up the alarm hash. Keeping stale entries is
    /// harmless — they get overwritten on the next schedule.
    func cancelRingingGuard(forAlarmHash alarmID: Int) {
        stopGuardRolling()
        let guardUUID = ringingGuardUUID(forAlarmHash: alarmID)
        // Try stop() first — if the guard has already fired (.alerting), cancel() would
        // cause AlarmKit to re-fire it ~2s later. stop() correctly dismisses alerting alarms.
        // If the guard is still .scheduled, stop() throws (silent) and cancel() handles it.
        // Trying both covers all states without needing to query current state first.
        do { try alarmManager.stop(id: guardUUID) } catch {}
        do {
            try alarmManager.cancel(id: guardUUID)
            print("[ALARM-STATE] cancelRingingGuard: ✅ cancelled/stopped ringing guard uuid=\(guardUUID)")
            AppLogger.shared.log("Ringing guard cancelled: hash=\(alarmID) uuid=\(guardUUID)", category: .alarm)
        } catch {
            // Not an error — guard may not exist or was already stopped above
        }
    }
    
    /// Generate a deterministic UUID for a ringing guard alarm.
    private func ringingGuardUUID(forAlarmHash hash: Int) -> UUID {
        // Mask ("RNGUAR" in hex) lives in AlarmKitAlarmIdentity.
        AlarmKitAlarmIdentity.ringingGuardUUID(forAlarmHash: hash)
    }
    
    /// Converts an alarm ID hash to a consistent UUID
    /// Converts an alarm ID hash to a consistent UUID.
    ///
    /// The algorithm itself lives in `AlarmKitAlarmIdentity` so the reverse
    /// mapping used by slept-through reconciliation is provably the inverse of
    /// what we schedule, and so neither copy can drift from the other.
    /// Unchanged behaviour — the same string formatting as before.
    func alarmIDToUUID(_ hashValue: Int) -> UUID {
        AlarmKitAlarmIdentity.uuid(forHash: hashValue)
    }

    // MARK: - Slept-through reconciliation (read-only)

    /// Alarms whose AlarmKit alarms are resident in the `.alerting` state.
    ///
    /// A fired-and-unattended AlarmKit alarm stays `.alerting` indefinitely —
    /// through the app process dying and through a full device reboot
    /// (measured, `al-bee.4`). Reading that inventory back is the only way a
    /// cold start can know an alarm rang with nobody home.
    ///
    /// **This reads and arms nothing.** It calls no scheduling, cancelling or
    /// stopping API, mutates no state on this object, and every failure path
    /// returns an empty set. If it misbehaves, alarms still ring — it runs
    /// after the ring, on the safe seam.
    ///
    /// The four deterministic tier UUIDs per alarm collapse to one hash, so
    /// the caller counts ALARMS, not ring events.
    ///
    /// - Parameter knownHashes: `stableHash` of every alarm the app still
    ///   knows about. The scheduler's own persisted UUID map is unioned in, so
    ///   an alarm whose SwiftData row went away is still recognised rather
    ///   than mis-attributed.
    func alertingAlarmHashes(knownHashes: [Int]) -> Set<Int> {
        guard let residents = try? alarmManager.alarms else { return [] }
        let alertingIDs = residents.filter { $0.state == .alerting }.map { $0.id }
        guard !alertingIDs.isEmpty else { return [] }
        let candidates = Array(Set(knownHashes).union(uuidToHashMap.values))
        return AlarmKitAlarmIdentity.alarmHashes(forAlertingIDs: alertingIDs, knownHashes: candidates)
    }
}
