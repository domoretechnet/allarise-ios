//
//  AppAudioSession.swift
//  HaWake Alarm V2
//
//  Thin wrapper around `AVAudioSession.setActive` that maintains a shadow
//  `isActive` flag the rest of the app (and the debug diagnostic) can read.
//
//  `AVAudioSession` deliberately never exposes an `isActive` getter, so the
//  only way to know whether the session is currently active is to track
//  every explicit activation/deactivation AND to observe the iOS
//  notifications that implicitly deactivate it (interruptions, media
//  services reset). This wrapper does both.
//
//  Call `AppAudioSession.installObservers()` once at app launch. After that,
//  every call site that previously called
//  `AVAudioSession.sharedInstance().setActive(…)` should go through
//  `AppAudioSession.setActive(…)` instead so the shadow stays accurate.
//

@preconcurrency import AVFoundation
import Foundation

enum AppAudioSession {

    // MARK: - Shadow State
    //
    // Marked `nonisolated(unsafe)` so the compiler does not infer @MainActor
    // isolation on this enum. `setActive` is called from both the main actor
    // AND background threads (e.g. SleepSoundManager's detached Task), so the
    // enum must stay non-isolated. The small race window on these vars is
    // acceptable for a debug diagnostic tool — we're not making safety-critical
    // decisions based on `isActive`.

    /// True when the app believes the audio session is currently active.
    ///
    /// Maintained by `setActive(_:options:)` and by the interruption / media
    /// services observers installed in `installObservers()`. This is our
    /// best-effort approximation of reality — iOS does not expose a real
    /// `isActive` getter on `AVAudioSession`, so we reconstruct it from the
    /// events we can observe.
    nonisolated(unsafe) private(set) static var isActive: Bool = false

    /// Timestamp of the most recent successful `setActive(true)` call, or nil
    /// if the session has never been activated. Read-only; used by the debug
    /// audio diagnostic for "last activated X seconds ago" style reporting.
    nonisolated(unsafe) private(set) static var lastActivationAt: Date?

    /// Timestamp of the most recent deactivation, whether caused by an
    /// explicit `setActive(false)` call or by an implicit iOS event
    /// (interruption began, media services lost/reset).
    nonisolated(unsafe) private(set) static var lastDeactivationAt: Date?

    /// Human-readable reason for the most recent state change. Useful when
    /// reading the audio diagnostic to understand why `isActive` flipped.
    nonisolated(unsafe) private(set) static var lastStateChangeReason: String = "never changed"

    // MARK: - Public API

    /// Wraps `AVAudioSession.sharedInstance().setActive(_:options:)` and
    /// updates the shadow `isActive` on success. Throws whatever the
    /// underlying call throws — callers handle errors as before.
    @discardableResult
    static func setActive(
        _ active: Bool,
        options: AVAudioSession.SetActiveOptions = []
    ) throws -> Bool {
        try AVAudioSession.sharedInstance().setActive(active, options: options)
        updateShadow(active: active, reason: "setActive(\(active))")
        return active
    }

    /// Wraps `AVAudioSession.sharedInstance().setCategory(_:mode:options:)`
    /// and fires an `AudioDiagnostics.logTransition` on success so every
    /// explicit category change lands in the audio log immediately (not just
    /// on the next 30-second heartbeat). All app code should use this
    /// instead of calling the raw AVAudioSession API directly.
    static func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode = .default,
        options: AVAudioSession.CategoryOptions = []
    ) throws {
        try AVAudioSession.sharedInstance().setCategory(category, mode: mode, options: options)
        let reason = "setCategory(\(category.rawValue))"
        Task { @MainActor in
            AudioDiagnostics.logTransition(reason: reason)
        }
    }

    /// Returns the category options every alarm / alert-fire call site should
    /// use when calling `setCategory`. Always `.mixWithOthers` (required for
    /// background activation while another audio app holds the session) and
    /// `.duckOthers` (so Pandora/Spotify drop in volume while the alarm rings).
    ///
    /// `.defaultToSpeaker` is intentionally OMITTED here. The audio route
    /// (CarPlay vs. built-in speaker) must be decided AFTER `setActive(true)`
    /// because `currentRoute.outputs` is stale or empty until the session is
    /// activated — especially on cold-launch from the background (persistence
    /// mode OFF). Deciding before activation was the root cause of silent
    /// alarms with CarPlay: the pre-activation route didn't show CarPlay, so
    /// `.defaultToSpeaker` was included, the session activated forcing audio
    /// to the iPhone speaker, which iOS physically mutes while CarPlay owns
    /// the audio route.
    ///
    /// Callers that need speaker output must call
    /// `overrideOutputAudioPort(.speaker)` after `setActive(true)`, guarded
    /// by a CarPlay check on `currentRoute.outputs` — `AlarmSoundPlayer.play`
    /// and the interruption-recovery path in `AlarmSound` already do this.
    static func alarmFireCategoryOptions() -> AVAudioSession.CategoryOptions {
        return [.mixWithOthers, .duckOthers]
    }

    /// Installs observers for the three system notifications that can
    /// deactivate the audio session behind our back. Call once at app launch
    /// — subsequent calls are ignored.
    static func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true

        let nc = NotificationCenter.default

        // Interruption began: iOS has handed the audio session to another app
        // (phone call, Siri, FaceTime, alarm from another app, etc.). Our
        // session is effectively inactive for the duration of the
        // interruption. `interruption ended` does NOT flip us back to active
        // on its own — callers must explicitly re-activate, and that call
        // will update the shadow through `setActive`.
        nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let info = notification.userInfo,
                  let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            switch type {
            case .began:
                updateShadow(active: false, reason: "interruption began")
            case .ended:
                // Do not flip active=true here. Our own code must call
                // setActive(true) to resume, and that call updates the shadow.
                break
            @unknown default:
                break
            }
        }

        // Media services were lost: `mediaserverd` died. Every audio session
        // on the device is torn down; we have to rebuild from scratch once
        // the reset notification arrives.
        nc.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: nil,
            queue: .main
        ) { _ in
            updateShadow(active: false, reason: "media services lost")
        }

        // Media services were reset: `mediaserverd` is back. Session is
        // still not active — callers need to reconfigure category and
        // reactivate explicitly.
        nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { _ in
            updateShadow(active: false, reason: "media services reset")
        }

        Task { @MainActor in
            AppLogger.shared.log("AppAudioSession: observers installed", category: .audio)
        }
    }

    // MARK: - Private

    nonisolated(unsafe) private static var observersInstalled = false

    private static func updateShadow(active: Bool, reason: String) {
        let previous = isActive
        isActive = active
        lastStateChangeReason = reason
        if active {
            lastActivationAt = Date()
        } else {
            lastDeactivationAt = Date()
        }
        if previous != active {
            // Fire-and-forget: AppLogger and AudioDiagnostics are @MainActor,
            // but setActive is called from background threads (SleepSoundManager's
            // detached task, etc.). Wrapping in a Task avoids forcing the entire
            // call chain onto main.
            let msg = "AppAudioSession: isActive \(previous) → \(active) (\(reason))"
            Task { @MainActor in
                AppLogger.shared.log(msg, category: .audio)
                AudioDiagnostics.logTransition(reason: reason)
            }
        }
    }
}
