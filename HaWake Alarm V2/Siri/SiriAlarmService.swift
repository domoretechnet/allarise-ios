//
//  SiriAlarmService.swift
//  HaWake Alarm V2
//
//  Shared service for the Siri / App Intents layer. All intents (custom and
//  iOS 27 clock-schema) call through here; this class delegates to the same
//  machinery MQTT and the UI use (DualAlarmCoordinator, MQTTCommandHandler
//  cores, AlarmWindowManager) so a Siri-created alarm is indistinguishable
//  from any other. Policy predicates enforce the mission-bypass rules —
//  Siri must never dismiss, delete, or disable a mission alarm out from
//  under its mission.
//

import Foundation
import SwiftData

@MainActor
final class SiriAlarmService {
    static let shared = SiriAlarmService()
    private init() {}

    // MARK: - Fetching

    private var context: ModelContext? {
        AlarmWindowManager.shared.modelContainer?.mainContext
    }

    /// All live alarms (saved + quick), excluding deleted/detached rows.
    func fetchAllAlarms() -> [Alarm] {
        guard let context else { return [] }
        let all = (try? context.fetch(FetchDescriptor<Alarm>())) ?? []
        return all.filter { !$0.isDetached }
    }

    /// Saved (non-ephemeral) alarms — what the alarm entity exposes.
    func fetchSavedAlarms() -> [Alarm] {
        fetchAllAlarms().filter { !$0.isEphemeral }
    }

    /// Quick alarms — what the timer entity exposes.
    func fetchQuickAlarms() -> [Alarm] {
        fetchAllAlarms().filter { $0.isEphemeral }
    }

    /// The canonical entity identifier: stableID UUID string, with the
    /// stableHash string as a legacy fallback. Never a second identity.
    func entityID(for alarm: Alarm) -> String {
        alarm.stableID?.uuidString ?? String(alarm.stableHash)
    }

    func alarm(forEntityID id: String) -> Alarm? {
        fetchAllAlarms().first { entityID(for: $0) == id }
    }

    /// Label lookup for "my Work alarm" phrasing: exact match first, then
    /// prefix, then contains — mirroring MQTTCommandHandler.fetchAlarm(byLabel:)
    /// but ranked so "work" prefers "Work" over "Workout backup".
    func alarms(matchingLabel query: String) -> [Alarm] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty, q != "alarm" else { return [] }
        let saved = fetchSavedAlarms()
        let exact = saved.filter { $0.label.lowercased() == q }
        if !exact.isEmpty { return exact }
        let prefix = saved.filter { $0.label.lowercased().hasPrefix(q) }
        if !prefix.isEmpty { return prefix }
        return saved.filter { $0.label.lowercased().contains(q) }
    }

    // MARK: - Ringing state

    /// Whether this alarm is ringing right now, on either presentation path:
    /// the persisted active-ringing key (survives force-kill; cleared
    /// synchronously on dismiss/snooze) or the live in-app alarm window.
    func isRinging(_ alarm: Alarm) -> Bool {
        let hash = alarm.stableHash
        if PendingAlarmStore.shared.activeRingingAlarmID() == hash { return true }
        if AlarmWindowManager.shared.isShowingAlarm,
           AlarmWindowManager.shared.currentAlarmID == hash { return true }
        return false
    }

    func hasMission(_ alarm: Alarm) -> Bool {
        // missionSequence (not mission.type != .none) so a multi-tap/hold Tap alarm
        // — a real mission — also blocks Siri delete/disable bypass while ringing.
        !alarm.missionSequence.isEmpty
    }

    // MARK: - Policy predicates (nil = allowed)

    /// Snooze gates, checked in order. Stricter than the in-app MQTT snooze
    /// observer (which trusts HA): Siri must respect HA-only snooze modes
    /// and the snooze count limit.
    func snoozeRefusal(for alarm: Alarm, settings: DeviceSettings) -> AllariseIntentError? {
        if alarm.isSnoozed { return .alreadySnoozed }
        guard isRinging(alarm) else { return .notRinging }

        let mode = alarm.effectiveSnoozeMode(settings: settings)
        if mode == .disabled { return .snoozeDisabled }
        if mode == .homeAssistant { return .snoozeHomeAssistantOnly }
        if alarm.mission.type == .homeAssistant,
           alarm.mission.haSnoozeMode == .homeAssistant {
            return .snoozeHomeAssistantOnly
        }

        let maxSnoozes = alarm.maxSnoozeCount ?? settings.defaultMaxSnoozeCount
        if maxSnoozes != 0 && alarm.snoozeCount >= maxSnoozes { return .snoozeExhausted }
        return nil
    }

    /// Delete is a mission-bypass vector while the mission is pending
    /// (ringing or snoozed) — refuse in those states.
    func deleteRefusal(for alarm: Alarm) -> AllariseIntentError? {
        if hasMission(alarm) && (isRinging(alarm) || alarm.isSnoozed) {
            return .missionBlocksDelete
        }
        return nil
    }

    /// Disabling mirrors the UI toggle's protections (can't disable while
    /// snoozed) plus the mission-bypass rule while ringing.
    func disableRefusal(for alarm: Alarm) -> AllariseIntentError? {
        if hasMission(alarm) && (isRinging(alarm) || alarm.isSnoozed) {
            return .missionBlocksDisable
        }
        if isRinging(alarm) { return .ringingBlocksDisable }
        if alarm.isSnoozed { return .snoozedBlocksDisable }
        return nil
    }

    // MARK: - Skip / Unskip

    enum SkipOutcome {
        /// Recurring alarm: its next occurrence was skipped.
        case skippedRecurring(alarm: Alarm, nextRing: Date?)
        /// One-time alarm: skipping means turning it off (existing UI semantics).
        case disabledOneTime(alarm: Alarm)
    }

    /// Skip the next upcoming enabled alarm. Mirrors the selection of
    /// MQTTCommandHandler.handleSkipNextAlarm and the mutation semantics of
    /// AlarmListView.skipNextAlarm (recurring -> skippedFireDate; one-time ->
    /// disable + cancel), then the standard save/schedule/publish/notify trailer.
    func skipNextAlarm() async throws -> SkipOutcome {
        let next = fetchSavedAlarms()
            .filter { $0.isEnabled && !$0.isSkipped && !$0.isSnoozed }
            .compactMap { alarm -> (Alarm, Date)? in
                guard let date = alarm.nextFireDate() else { return nil }
                return (alarm, date)
            }
            .min(by: { $0.1 < $1.1 })

        guard let (alarm, _) = next else { throw AllariseIntentError.noUpcomingAlarms }

        let settings = DeviceSettings.shared
        guard alarm.effectiveSkipMode(settings: settings) != .disabled else {
            throw AllariseIntentError.skipDisabled
        }

        let outcome: SkipOutcome
        if alarm.isRecurring {
            alarm.skippedFireDate = alarm.nextFireDate()
            AppLogger.shared.log("Alarm skipped via Siri: '\(alarm.label)' skipping \(alarm.skippedFireDate.map(String.init(describing:)) ?? "nil")", category: .alarm)
            try? context?.save()
            await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
            outcome = .skippedRecurring(alarm: alarm, nextRing: alarm.nextFireDate())
        } else {
            alarm.isEnabled = false
            AppLogger.shared.log("Alarm skipped via Siri (one-time disabled): '\(alarm.label)'", category: .alarm)
            try? context?.save()
            await DualAlarmCoordinator.shared.cancelAlarm(alarm)
            outcome = .disabledOneTime(alarm: alarm)
        }

        publishStateChange(for: alarm, settings: settings)
        return outcome
    }

    /// Un-skip the skipped alarm with the earliest skipped fire date
    /// (mirrors MQTTCommandHandler.handleUnskipNextAlarm + handlePerAlarmUnskip).
    func unskipAlarm() async throws -> Alarm {
        let nextSkipped = fetchSavedAlarms()
            .filter { $0.isEnabled && $0.isSkipped }
            .compactMap { alarm -> (Alarm, Date)? in
                guard let date = alarm.skippedFireDate else { return nil }
                return (alarm, date)
            }
            .min(by: { $0.1 < $1.1 })

        guard let (alarm, _) = nextSkipped else { throw AllariseIntentError.noSkippedAlarms }

        alarm.skippedFireDate = nil
        AppLogger.shared.log("Alarm unskipped via Siri: '\(alarm.label)'", category: .alarm)
        try? context?.save()
        await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
        publishStateChange(for: alarm, settings: DeviceSettings.shared)
        return alarm
    }

    // MARK: - Create / Update (iOS 27 clock schema)

    /// Alarm creation gate for every Siri path. In the free support model there is no
    /// alarm-count limit (`featuresUnlocked` is always true), so this never refuses. The
    /// check is retained so paid gating can be restored by flipping one switch.
    func createRefusal() -> AllariseIntentError? {
        if !StoreManager.shared.featuresUnlocked && fetchSavedAlarms().count >= 2 {
            return .freeLimitReached
        }
        return nil
    }

    /// Create a saved alarm and run the same insert/schedule/publish trailer
    /// as the UI add flow and MQTT create_alarm. `weekdays` uses
    /// Calendar.component(.weekday) numbering (1 = Sunday … 7 = Saturday).
    func createAlarm(
        hour: Int,
        minute: Int,
        label: String?,
        weekdays: Set<Int>,
        canSnooze: Bool
    ) async throws -> Alarm {
        guard let context else { throw AllariseIntentError.storageUnavailable }
        if let refusal = createRefusal() { throw refusal }

        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        components.second = 0
        let time = calendar.date(from: components) ?? Date()

        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Seed the same user defaults as NewAlarmEditorView: sound, snooze
        // duration, and default mission. Fade-in/volume/vibration need nothing
        // here — their per-alarm overrides stay nil, which means "use global".
        let settings = DeviceSettings.shared
        let alarm = Alarm(
            time: time,
            label: trimmed.isEmpty ? "Alarm" : trimmed,
            recurringDays: weekdays,
            soundName: settings.defaultAlarmSound,
            snoozeDuration: settings.defaultSnoozeDuration,
            mission: settings.defaultMission
        )
        if !canSnooze { alarm.alarmSnoozeMode = .disabled }
        alarm.alarmIndex = settings.assignNextAlarmIndex()

        context.insert(alarm)
        try? context.save()
        AppLogger.shared.log("Alarm created via Siri: '\(alarm.label)' \(hour):\(String(format: "%02d", minute)) days=\(weekdays.sorted())", category: .alarm)

        await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
        publishStateChange(for: alarm, settings: DeviceSettings.shared)
        return alarm
    }

    /// Partial update from UpdateAlarmIntent. nil fields are left unchanged.
    struct AlarmChanges {
        var isEnabled: Bool?
        var hour: Int?
        var minute: Int?
        var label: String?
        var weekdays: Set<Int>?
        var allowsSnooze: Bool?
    }

    /// Apply a partial update, then the standard save/schedule/publish
    /// trailer. Disabling goes through disableRefusal (mission-bypass rule);
    /// everything else mirrors the UI edit semantics.
    func updateAlarm(_ alarm: Alarm, applying changes: AlarmChanges) async throws -> Alarm {
        guard let context else { throw AllariseIntentError.storageUnavailable }

        if changes.isEnabled == false, let refusal = disableRefusal(for: alarm) {
            throw refusal
        }

        if let hour = changes.hour, let minute = changes.minute {
            let calendar = Calendar.current
            var components = calendar.dateComponents([.year, .month, .day], from: alarm.time)
            components.hour = hour
            components.minute = minute
            components.second = 0
            if let newTime = calendar.date(from: components) { alarm.time = newTime }
            // A rescheduled one-time alarm should fire again, and a pending
            // skip refers to the old time — clear both.
            if !alarm.isRecurring { alarm.lastFireDate = nil }
            alarm.skippedFireDate = nil
        }

        if let label = changes.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            alarm.label = label
        }

        if let weekdays = changes.weekdays {
            alarm.recurringDays = weekdays
        }

        if let allowsSnooze = changes.allowsSnooze {
            if allowsSnooze {
                // Only override when snooze is currently off; otherwise keep
                // the user's tap/hold/HA mode.
                if alarm.effectiveSnoozeMode(settings: DeviceSettings.shared) == .disabled {
                    alarm.alarmSnoozeMode = .tap
                }
            } else {
                alarm.alarmSnoozeMode = .disabled
            }
        }

        if let isEnabled = changes.isEnabled {
            // Mirror the UI toggle: re-enabling a fired one-time alarm clears
            // lastFireDate so it becomes schedulable again.
            if isEnabled && !alarm.isRecurring && alarm.lastFireDate != nil {
                alarm.lastFireDate = nil
            }
            alarm.isEnabled = isEnabled
        }

        try? context.save()
        AppLogger.shared.log("Alarm updated via Siri: '\(alarm.label)' enabled=\(alarm.isEnabled)", category: .alarm)

        if alarm.isEnabled {
            await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
        } else {
            await DualAlarmCoordinator.shared.cancelAlarm(alarm)
        }
        publishStateChange(for: alarm, settings: DeviceSettings.shared)
        return alarm
    }

    /// Standard post-mutation trailer used by every MQTT handler: per-alarm
    /// MQTT publish (when applicable) + the app-wide state-changed signal.
    private func publishStateChange(for alarm: Alarm, settings: DeviceSettings) {
        if settings.mqttEnabled && alarm.alarmIndex > 0 {
            HAIntegrationRouter.shared.publishPerAlarmState(alarm: alarm, settings: settings)
        }
        NotificationCenter.default.post(name: NSNotification.Name("AlarmStateChanged"), object: nil)
    }
}
