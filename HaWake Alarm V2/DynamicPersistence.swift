//
//  DynamicPersistence.swift
//  HaWake Alarm V2
//
//  The "Dynamic" App Persistence mode: keep the app resident only when it is
//  free (device charging) or about to matter (inside the pre-alarm window),
//  instead of holding the silent keep-alive audio session all night.
//
//  AlarmKit is the correctness floor. DualAlarmCoordinator schedules the
//  AlarmKit failsafe unconditionally in every mode, so nothing in this file
//  can cause a missed alarm — residency only decides whether the alarm gets
//  the *good* path (in-app timer, custom volume, radio) without the all-night
//  battery cost of mode .on.
//
//  Three cooperating pieces:
//  - `AppPersistenceMode` — the stored three-way setting (see DeviceSettings).
//  - `PersistenceResidencyResolution` — pure decision logic, unit-tested.
//  - `DynamicPersistenceController` — observes charging / alarm-schedule /
//    ladder wakes, stamps `DeviceSettings.dynamicResidentNow`, and starts or
//    stops `BackgroundAudioKeepAlive` on transitions.
//

import Foundation
import UIKit
import SwiftData

// MARK: - Mode

/// The three-way App Persistence setting. Replaces the old boolean as the
/// source of truth; `DeviceSettings.backgroundKeepAliveEnabled` remains as a
/// mirrored legacy key (`mode != .off`) so a downgraded build still behaves
/// sanely. Raw values are persisted under "appPersistenceMode" — do not rename.
enum AppPersistenceMode: String, CaseIterable, Identifiable {
    case on
    case off
    case dynamic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .on: return "On"
        case .off: return "Off"
        case .dynamic: return "Dynamic"
        }
    }
}

// MARK: - Pure decision logic

/// Pure, testable resolution of "should the app be resident right now" and
/// "when should the BGAppRefreshTask ladder next run". No side effects, no
/// singletons — mirror of the AlarmOverrideResolution precedent so both
/// directions are unit-testable.
enum PersistenceResidencyResolution {

    /// How long before the next alarm the app should become resident.
    /// 75 minutes per the hybrid-persistence plan; generous enough that a
    /// slow BG-task draw still lands inside the window.
    static let leadTime: TimeInterval = 75 * 60

    /// First ladder submission aims this far ahead of the alarm so the
    /// scheduler has several opportunities before the window opens.
    static let firstSubmissionLead: TimeInterval = 3.5 * 60 * 60

    /// Heartbeat interval used while resident (matches the historical +15 min
    /// refresh for mode .on) and the soonest any submission may ask for.
    static let heartbeatInterval: TimeInterval = 15 * 60

    /// Resubmission interval when Dynamic has no upcoming alarm to aim at.
    static let idleResubmitInterval: TimeInterval = 4 * 60 * 60

    /// Whether the keep-alive session should be running right now.
    ///
    /// `armed` is the effective Alarm-Control state (the widget's Alarm Control
    /// exists and Home Assistant reports it armed); `residencyWhenArmed` is the
    /// user's opt-out. Both only matter under `.dynamic` — an armed house should
    /// keep the app awake so inbound HA commands still land, just as a pending
    /// alarm does. On/Off never consult them.
    static func residentNow(
        mode: AppPersistenceMode,
        isCharging: Bool,
        alarmRinging: Bool,
        nextFireDate: Date?,
        armed: Bool = false,
        residencyWhenArmed: Bool = true,
        now: Date = Date()
    ) -> Bool {
        switch mode {
        case .on:
            return true
        case .off:
            return false
        case .dynamic:
            if alarmRinging { return true }
            if isCharging { return true }
            if armed && residencyWhenArmed { return true }
            guard let fire = nextFireDate else { return false }
            return now >= fire.addingTimeInterval(-leadTime) && now <= fire
        }
    }

    /// The `earliestBeginDate` for the next BGAppRefreshTask submission, or
    /// nil when no task should be submitted (mode .off). The ladder is
    /// submitted *unconditionally* for .dynamic — charging and Low Power Mode
    /// are never inputs here: submission is free, and an unsubmitted task
    /// cannot fire when conditions later improve (LPM clearing at 80% on the
    /// charger is exactly the recovery this preserves).
    static func ladderEarliestBeginDate(
        mode: AppPersistenceMode,
        nextFireDate: Date?,
        now: Date = Date()
    ) -> Date? {
        switch mode {
        case .off:
            return nil
        case .on:
            return now.addingTimeInterval(heartbeatInterval)
        case .dynamic:
            guard let fire = nextFireDate, fire > now else {
                return now.addingTimeInterval(idleResubmitInterval)
            }
            let windowStart = fire.addingTimeInterval(-leadTime)
            let firstAim = fire.addingTimeInterval(-firstSubmissionLead)
            let floorDate = now.addingTimeInterval(heartbeatInterval)
            if now >= windowStart {
                // Already inside the window (we are presumably resident) —
                // fall back to the heartbeat cadence.
                return floorDate
            }
            // Aim for the earlier of "well out" and the window start, but
            // never sooner than the heartbeat floor. As wakes land "too
            // early", handleLadderWake resubmits stepping toward windowStart.
            return max(floorDate, min(firstAim < now ? windowStart : firstAim, windowStart))
        }
    }

    /// Outcome classification for a ladder wake, mirroring the plan's
    /// activated / resubmitted / tooLate vocabulary.
    enum LadderWakeAction: Equatable {
        /// Inside the window — activate persistence now.
        case activate
        /// Before the window — resubmit for the given date.
        case resubmit(Date)
        /// No enabled upcoming alarm — resubmit on the idle cadence.
        case idle(Date)
    }

    static func ladderWakeAction(
        nextFireDate: Date?,
        isCharging: Bool = false,
        armed: Bool = false,
        residencyWhenArmed: Bool = true,
        now: Date = Date()
    ) -> LadderWakeAction {
        // Charging (or an armed house with residency opted in) means resident
        // NOW under Dynamic, window or not — mirror residentNow. A wake that
        // lands while these hold is the only recovery path after a background
        // kill: the battery/arm observers that would have noticed died with
        // the process, so resubmitting here strands a charging phone
        // non-resident until the pre-alarm window or a manual launch (al-q4fr).
        if isCharging || (armed && residencyWhenArmed) {
            return .activate
        }
        guard let fire = nextFireDate, fire > now else {
            return .idle(now.addingTimeInterval(idleResubmitInterval))
        }
        let windowStart = fire.addingTimeInterval(-leadTime)
        if now >= windowStart {
            return .activate
        }
        return .resubmit(max(now.addingTimeInterval(heartbeatInterval), windowStart))
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted by DualAlarmCoordinator whenever the alarm schedule changes, so
    /// the controller can re-aim the ladder and re-evaluate residency.
    static let alarmScheduleDidChange = Notification.Name("AlarmScheduleDidChange")
}

// MARK: - Controller

/// Owns the Dynamic-mode machinery: charging observation, residency
/// re-evaluation, keep-alive start/stop on transitions, and ladder
/// resubmission. Inert until `activate()` — called from AppDelegate at launch
/// and again on any mode change (activation is idempotent).
@MainActor
final class DynamicPersistenceController {
    static let shared = DynamicPersistenceController()

    private var activated = false
    private var windowEntryTimer: Timer?
    /// Coalesces bursts of schedule-change notifications (reconciliation
    /// reschedules every alarm in a loop) into one re-evaluation.
    private var pendingReevaluate: Task<Void, Never>?

    private init() {}

    // MARK: Activation

    /// Idempotent. Safe to call for any mode; observers are cheap and the
    /// resolution itself handles .on/.off. Battery monitoring is only enabled
    /// when the mode can actually use it.
    func activate() {
        let mode = DeviceSettings.shared.appPersistenceMode
        if mode == .dynamic {
            // Constructing the tracker enables battery monitoring and starts
            // recording plug/unplug events (used by the wake telemetry).
            _ = ChargingStateTracker.shared
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        guard !activated else {
            reevaluate(reason: "activate(mode=\(mode.rawValue))")
            return
        }
        activated = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryStateChanged),
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scheduleChanged),
            name: .alarmScheduleDidChange,
            object: nil
        )
        // Arm/disarm from the widget or Home Assistant changes residency under
        // Dynamic (see effectiveArmed / dynamicResidencyWhenArmed). ArmButtonView
        // posts this on every HA-driven arm-state change.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(armStateChanged),
            name: NSNotification.Name("ArmStateChanged"),
            object: nil
        )
        // Observed for the wake telemetry only — Low Power Mode is NEVER an
        // input to submission or residency (see ladderEarliestBeginDate).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateChanged),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )

        reevaluate(reason: "activate(mode=\(mode.rawValue))")
    }

    @objc private func batteryStateChanged(_ note: Notification) {
        Task { @MainActor in
            self.reevaluate(reason: "chargingChanged(\(self.isCharging ? "plugged" : "unplugged"))")
        }
    }

    @objc private func scheduleChanged(_ note: Notification) {
        // Debounce: reconciliation posts once per alarm in a tight loop.
        pendingReevaluate?.cancel()
        pendingReevaluate = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.reevaluate(reason: "alarmScheduleChanged")
        }
    }

    @objc private func armStateChanged(_ note: Notification) {
        Task { @MainActor in
            let armed = (note.userInfo?["armed"] as? Bool) ?? DeviceSettings.shared.cachedArmState
            self.reevaluate(reason: "armStateChanged(\(armed ? "armed" : "disarmed"))")
        }
    }

    @objc private func powerStateChanged(_ note: Notification) {
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        AppLogger.shared.log("DynamicPersistence: Low Power Mode \(lpm ? "ON" : "OFF")", category: .general)
    }

    // MARK: Inputs

    var isCharging: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: return true
        default: return false
        }
    }

    private var alarmRinging: Bool {
        AlarmSoundPlayer.shared.isPlaying
            || PendingAlarmStore.shared.pendingAlarm != nil
            || PendingAlarmStore.shared.hasPendingAlarm()
    }

    /// Effective "the house is armed" for residency purposes. `cachedArmState`
    /// alone is not enough — it can linger from a time the Alarm Control was on,
    /// and it is only meaningful when the widget's Alarm Control is actually
    /// present and MQTT is connected. Gate on the same flags the arm button
    /// itself checks so a disabled or hidden control can never pin the app
    /// resident. Only consulted under `.dynamic`.
    private var effectiveArmed: Bool {
        let settings = DeviceSettings.shared
        return settings.mqttEnabled
            && settings.armButtonEnabled
            && settings.hassWidgetAlarmEnabled
            && settings.cachedArmState
    }

    /// Earliest upcoming fire date across enabled alarms (snoozed alarms have
    /// their own failsafe machinery and are excluded). DB fetch — call from
    /// re-evaluation points, not hot paths; `keepAliveNeeded` reads the cached
    /// `DeviceSettings.dynamicResidentNow` instead.
    func currentNextFireDate(now: Date = Date()) -> Date? {
        guard let container = AlarmWindowManager.shared.modelContainer else { return nil }
        let alarms = (try? container.mainContext.fetch(FetchDescriptor<AppAlarm>())) ?? []
        return alarms
            .filter { $0.isEnabled && !$0.isSnoozed }
            .compactMap { $0.nextFireDate(from: now) }
            .min()
    }

    // MARK: Re-evaluation

    /// Recomputes residency, stamps the cache, and applies keep-alive
    /// transitions. The ladder is (re)submitted here too, so any schedule or
    /// mode change re-aims the pending BG task request.
    func reevaluate(reason: String) {
        let settings = DeviceSettings.shared
        let mode = settings.appPersistenceMode
        let nextFire = currentNextFireDate()
        let resident = PersistenceResidencyResolution.residentNow(
            mode: mode,
            isCharging: isCharging,
            alarmRinging: alarmRinging,
            nextFireDate: nextFire,
            armed: effectiveArmed,
            residencyWhenArmed: settings.dynamicResidencyWhenArmed
        )

        let wasResident = settings.dynamicResidentNow
        settings.dynamicResidentNow = resident

        // All modes flow through here (AppDelegate delegates launch to
        // activate()), so a cold start in .on must start keep-alive too —
        // keepAliveRunning is the effective state, not the stamped cache.
        let shouldRun = settings.keepAliveNeeded
        if shouldRun != BackgroundAudioKeepAlive.shared.isRunning {
            AppLogger.shared.log(
                "DynamicPersistence: keep-alive \(shouldRun ? "starting" : "stopping") — resident \(wasResident) → \(resident) (\(reason))",
                category: .general
            )
            // applyPersistenceChange is the one shared start/stop path — its
            // OFF branch knows not to deactivate a session that sleep sounds
            // or radio own (see its doc comment). The isRunning gate above
            // keeps this from re-firing while another owner holds the session.
            BackgroundAudioKeepAlive.shared.applyPersistenceChange(enabled: shouldRun)
            // The force-close heartbeat's premise ("this app should be resident, so
            // suspension means something went wrong") just changed truth value.
            AppLifecycleMonitor.shared.residencyDidChange(resident: shouldRun)
            // The HA `app_persistence` state topic reports EFFECTIVE
            // residency, so existing automations stay truthful under Dynamic.
            settings.publishAppPersistenceState()
            if shouldRun {
                // Residency without reachability is half a feature: a scene-less
                // start (background audio relaunch, ladder wake) never passes
                // through the foreground hooks that own connect(), so the app can
                // run resident for the whole window while HA shows it offline and
                // the publish above is silently dropped (al-dnyu).
                ensureReachabilityForResidency()
            }
        }

        // Re-aim the ladder (submit() with the same identifier replaces any
        // pending request). Never submitted for .off.
        BackgroundAudioKeepAlive.shared.scheduleBackgroundRefresh()

        armWindowEntryTimerIfNeeded(mode: mode, nextFire: nextFire, resident: resident)
    }

    /// Connect the HA backend when residency begins outside the foreground
    /// paths. Every other connect() call site is scene- or foreground-gated
    /// (HaWake_Alarm_V2App onAppear/scenePhase, MQTTManager's foreground
    /// observers), so a background residency start must bring its own
    /// connection or the app stays unreachable while resident (al-dnyu).
    /// Idempotent: skips when already connected; activates the backend only
    /// when none is installed yet (a scene-less launch never ran activate).
    /// NetworkMonitor may still hold `external` here (SSID is unreadable in
    /// the background) — the NetworkChanged observer in MQTTManager reconnects
    /// toward the internal broker once the probe resolves.
    private func ensureReachabilityForResidency() {
        let settings = DeviceSettings.shared
        guard settings.mqttEnabled else { return }
        // Foreground-bound launches keep their existing flow: the scene hooks
        // connect after NetworkMonitor resolves the SSID, picking the right
        // broker first try. Only a background start has no one else to connect.
        guard UIApplication.shared.applicationState == .background else { return }
        let router = HAIntegrationRouter.shared
        guard !router.isConnected else { return }
        if router.activeBackend == nil {
            router.activate(settings: settings)
        }
        AppLogger.shared.log(
            "DynamicPersistence: residency started without a connection — connecting HA backend",
            category: .general
        )
        router.connect(settings: settings)
    }

    /// While the process is alive but not resident (foreground use, or just
    /// unplugged), a plain timer catches the window opening. When the process
    /// is suspended this timer dies with it — that case belongs to the ladder.
    private func armWindowEntryTimerIfNeeded(mode: AppPersistenceMode, nextFire: Date?, resident: Bool) {
        windowEntryTimer?.invalidate()
        windowEntryTimer = nil
        guard mode == .dynamic, !resident, let fire = nextFire else { return }
        let windowStart = fire.addingTimeInterval(-PersistenceResidencyResolution.leadTime)
        let delay = windowStart.timeIntervalSinceNow
        guard delay > 0 else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            Task { @MainActor in
                DynamicPersistenceController.shared.reevaluate(reason: "windowEntryTimer")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        windowEntryTimer = timer
    }

    // MARK: Ladder wake

    /// Called from the BGAppRefreshTask handler when the mode is .dynamic.
    /// Classifies the wake, activates or resubmits, records the attempt, and
    /// — on activation — re-arms the in-app alarm timers so the primary path
    /// (exact-time fire, custom volume, radio, retry) wins at ring time
    /// instead of the +5s AlarmKit handler.
    func handleLadderWake() async {
        let now = Date()
        let nextFire = currentNextFireDate(now: now)
        let action = PersistenceResidencyResolution.ladderWakeAction(
            nextFireDate: nextFire,
            isCharging: isCharging,
            armed: effectiveArmed,
            residencyWhenArmed: DeviceSettings.shared.dynamicResidencyWhenArmed,
            now: now
        )

        switch action {
        case .activate:
            WakeAttemptStore.shared.recordLadderWake(outcome: "activated", nextFireDate: nextFire)
            reevaluate(reason: "ladderWake(activate)")
            // Await the start directly (idempotent) so keep-alive audio is
            // actually running before the BG task completes — the detached
            // start inside reevaluate() has no such guarantee within the
            // task's ~30s budget.
            await BackgroundAudioKeepAlive.shared.startAsync()
            BackgroundAudioKeepAlive.shared.startHealthCheck()
            // reevaluate() only connects on a keep-alive TRANSITION; a wake that
            // finds keep-alive already flagged running but the connection down
            // (e.g. audio survived, socket didn't) must still restore
            // reachability within the task's budget (al-dnyu).
            ensureReachabilityForResidency()
            await rearmAlarmTimersAfterBackgroundWake()
        case .resubmit(let date):
            WakeAttemptStore.shared.recordLadderWake(outcome: "resubmitted", nextFireDate: nextFire)
            BackgroundAudioKeepAlive.shared.submitBackgroundRefresh(earliestBeginDate: date)
        case .idle(let date):
            WakeAttemptStore.shared.recordLadderWake(outcome: "idle", nextFireDate: nil)
            BackgroundAudioKeepAlive.shared.submitBackgroundRefresh(earliestBeginDate: date)
        }
    }

    /// Minimal timer re-arm after a background (no scene) launch. Deliberately
    /// NOT the full foreground reconciliation from handleScenePhaseChange —
    /// no snooze recovery, no cleanup, no skip-clearing; those need the user
    /// present. Guards mirror HaWake_Alarm_V2App.handleScenePhaseChange so a
    /// ring in progress is never disturbed.
    func rearmAlarmTimersAfterBackgroundWake() async {
        guard !AlarmWindowManager.shared.isShowingAlarm,
              !PendingAlarmStore.shared.hasPendingAlarm(),
              PendingAlarmStore.shared.pendingAlarm == nil,
              !AlarmSoundPlayer.shared.isPlaying,
              !AlarmKitScheduler.shared.hasAlertingAlarm else {
            AppLogger.shared.log("DynamicPersistence: skip timer re-arm (alarm in progress)", category: .alarm)
            return
        }
        guard let container = AlarmWindowManager.shared.modelContainer else {
            AppLogger.shared.log("DynamicPersistence: skip timer re-arm (no model container)", category: .alarm)
            return
        }
        let alarms = (try? container.mainContext.fetch(FetchDescriptor<AppAlarm>())) ?? []
        for alarm in alarms where alarm.isEnabled && !alarm.isSnoozed {
            await DualAlarmCoordinator.shared.scheduleAlarmForReconciliation(alarm)
        }
        AppLogger.shared.log("DynamicPersistence: re-armed timers after background wake", category: .alarm)
    }
}
