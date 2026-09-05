//
//  AnalyticsService.swift
//  HaWake Alarm V2
//
//  THE analytics entry point. Call sites only ever say:
//
//      Analytics.shared.log(.alarmFired(path: .primaryTimer, ...))
//
//  Everything else — consent, buffering, backends — is decided here, once.
//
//  THREE INVARIANTS, in priority order:
//
//  1. CONSENT GATES EVERYTHING. With `analyticsOptIn` false, nothing is logged,
//     nothing is buffered, and no backend is even started. In the EU consent
//     must precede collection, so a backend that starts and is switched off
//     later is not good enough — `AnalyticsBackend.start()` is the first thing
//     that ever runs, and it only runs after opt-in.
//
//  2. ZERO BACKGROUND WORK. This app deliberately stays resident overnight so
//     its alarm timer can fire, and it is already close to the background CPU
//     budget — the previous release fixed a background-CPU kill. Telemetry that
//     uploaded while resident would raise the odds of the very jetsam it exists
//     to measure. So events logged while inactive are BUFFERED in memory and
//     flushed only once the app is active again. Nothing queued in the
//     background means nothing to upload in the background.
//
//  3. NOTHING IDENTIFYING. Enforced by `AnalyticsEvent` having no String
//     parameters rather than by reviewer discipline.
//
//  The default backend is a no-op, so the app (and an open-source checkout with
//  no Firebase project) behaves identically minus the upload.
//

import Foundation
import UIKit

// MARK: - Backend

/// What a telemetry provider must offer. Firebase implements this later; the
/// app never imports Firebase directly, so swapping or removing it touches one
/// file and the open-source build works with no provider at all.
protocol AnalyticsBackend: AnyObject {
    /// Called ONCE, only after consent. Configure the SDK here — not at launch.
    func start()
    /// Called on withdrawal: stop collection AND delete what's already gathered.
    /// GDPR Art. 7 withdrawal has to actually undo something.
    func stopAndPurge()
    /// Called at launch when consent is absent. Crash reports queued during an
    /// earlier consented run must not sit on disk waiting for collection to be
    /// re-enabled; `stopAndPurge` only covers the in-session withdrawal.
    func discardUnsentDiagnostics()
    func log(name: String, parameters: [String: Any])
    func setUserProperty(_ value: String?, forName name: String)
}

extension AnalyticsBackend {
    /// Optional — a provider with nothing queued on disk need not implement it.
    func discardUnsentDiagnostics() {}
}

/// The default. Also what ships in a build with no analytics provider.
final class NoopAnalyticsBackend: AnalyticsBackend {
    func start() {}
    func stopAndPurge() {}
    func log(name: String, parameters: [String: Any]) {}
    func setUserProperty(_ value: String?, forName name: String) {}
}

// MARK: - Service

@MainActor
final class Analytics {
    static let shared = Analytics()

    /// Swap in a real backend at launch (before `refreshConsent`). Left as the
    /// no-op when no provider is configured.
    private var backend: AnalyticsBackend = NoopAnalyticsBackend()
    private var backendStarted = false

    /// Events recorded while the app wasn't active. Flushed on activation.
    private var pending: [(name: String, parameters: [String: Any])] = []
    /// Hard cap: a device that never returns to the foreground must not grow
    /// this without bound. Oldest are dropped — recent events matter more.
    private static let maxBuffered = 200

    private var isActive = true
    private var observers: [NSObjectProtocol] = []

    private var settings: DeviceSettings { .shared }
    private var hasConsent: Bool { settings.analyticsOptIn }

    private init() {}

    // MARK: Lifecycle

    /// Call once from app launch. Registers the backend and begins observing
    /// activation, but does NOT start collection — `refreshConsent()` does that,
    /// and only if consent exists.
    func bootstrap(backend: AnalyticsBackend? = nil) {
        if let backend { self.backend = backend }

        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in self.handleBecameActive() } })

        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in self.isActive = false } })

        // Buffered events must survive the process, or the buffer silently
        // becomes a shredder for exactly the events worth having. By the time
        // `willTerminate` runs the app is already inactive, so anything logged
        // there — `terminatedWithAlarmPending` above all — is buffered into a
        // process about to die. Persisting on background/terminate means it is
        // waiting at next launch instead.
        //
        // A SIGKILL (force-quit, jetsam) still calls neither, which is precisely
        // the gap MetricKit's exit counts fill.
        for name in [UIApplication.didEnterBackgroundNotification,
                     UIApplication.willTerminateNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in Task { @MainActor in self.persistPending() } })
        }

        restorePending()
        refreshConsent()
    }

    // MARK: Buffer persistence

    private static let pendingKey = "analyticsPendingEvents"

    /// Every parameter value is String / Int / Bool by construction (see
    /// AnalyticsEvent), so the buffer is plist-encodable with no conversion.
    private func persistPending() {
        guard hasConsent, !pending.isEmpty else { return }
        let encoded: [[String: Any]] = pending.map { ["n": $0.name, "p": $0.parameters] }
        UserDefaults.standard.set(encoded, forKey: Self.pendingKey)
    }

    private func restorePending() {
        defer { UserDefaults.standard.removeObject(forKey: Self.pendingKey) }
        // Consent may have been withdrawn since these were written — in that
        // case they are dropped unread rather than uploaded late.
        guard hasConsent,
              let stored = UserDefaults.standard.array(forKey: Self.pendingKey) as? [[String: Any]]
        else { return }

        for entry in stored {
            guard let name = entry["n"] as? String,
                  let parameters = entry["p"] as? [String: Any] else { continue }
            pending.append((name: name, parameters: parameters))
        }
        if pending.count > Self.maxBuffered {
            pending.removeFirst(pending.count - Self.maxBuffered)
        }
    }

    /// Re-reads `analyticsOptIn`. Call after onboarding and whenever the
    /// Settings toggle changes.
    func refreshConsent() {
        if hasConsent {
            if !backendStarted {
                backend.start()
                backendStarted = true
            }
            refreshUserProperties()
            flushIfPossible()
        } else if backendStarted {
            // Withdrawal deletes, it doesn't just stop.
            backend.stopAndPurge()
            backendStarted = false
            pending.removeAll()
        } else {
            // Never started; make sure nothing accumulated while opted out —
            // including a crash report queued before consent was withdrawn.
            pending.removeAll()
            backend.discardUnsentDiagnostics()
        }
    }

    private func handleBecameActive() {
        isActive = true
        flushIfPossible()
    }

    // MARK: Logging

    func log(_ event: AnalyticsEvent) {
        guard hasConsent, backendStarted else { return }

        let entry = (name: event.name, parameters: event.parameters)

        // Buffer rather than hand to the backend while inactive — see invariant 2.
        guard isActive else {
            pending.append(entry)
            if pending.count > Self.maxBuffered {
                pending.removeFirst(pending.count - Self.maxBuffered)
            }
            return
        }

        backend.log(name: entry.name, parameters: entry.parameters)
    }

    private func flushIfPossible() {
        guard hasConsent, backendStarted, isActive, !pending.isEmpty else { return }
        let queued = pending
        pending.removeAll()
        for entry in queued {
            backend.log(name: entry.name, parameters: entry.parameters)
        }
    }

    // MARK: User properties

    /// A snapshot of how the app is CONFIGURED, refreshed on activation rather
    /// than logged as events. Configuration questions ("how many people use
    /// MQTT?") are segmentation, not moments in time — sending them as events
    /// would spam the event stream and still answer the question worse.
    func refreshUserProperties(alarmCount: Int? = nil,
                               customToneCount: Int? = nil,
                               customSleepSoundCount: Int? = nil) {
        guard hasConsent, backendStarted else { return }

        set("pro_status", StoreManager.shared.effectiveIsPro ? "pro" : "free")
        set("persistence_enabled", String(settings.appPersistenceMode != .off))
        set("persistence_mode", settings.appPersistenceMode.rawValue)
        set("mqtt_enabled", String(settings.mqttEnabled))
        set("widget_enabled", String(settings.armButtonEnabled))
        set("alarm_control_enabled", String(settings.hassWidgetAlarmEnabled))
        set("default_mission", settings.defaultMissionType.analyticsName)
        set("command_count", Bucket.count(settings.mqttCommands.count))
        set("product_updates_opt_in", String(settings.productUpdatesOptIn))

        if let alarmCount { set("alarm_count", Bucket.count(alarmCount)) }
        if let customToneCount { set("custom_tone_count", Bucket.count(customToneCount)) }
        if let customSleepSoundCount { set("custom_sleep_count", Bucket.count(customSleepSoundCount)) }
    }

    private func set(_ name: String, _ value: String?) {
        backend.setUserProperty(value, forName: name)
    }
}
