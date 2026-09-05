//
//  DynamicModeNotice.swift
//  HaWake Alarm V2
//
//  A one-time, local notice telling every user that App Persistence is now
//  three-way and that their install has been placed on `.dynamic`.
//
//  WHO GETS THIS
//  ------------
//  Only installs that PREDATE the Dynamic default (shipped 2026-08-01). The
//  default moved for updaters — including people who had deliberately chosen
//  Off — so their behaviour changed underneath them, and a silent behaviour
//  change is the worst failure this project can have (see CLAUDE.md,
//  "Backwards compatibility"). A brand-new install, by contrast, has ALWAYS
//  been Dynamic: nothing changed under it, so telling it "we moved you" would
//  be a lie. The eligibility check is `AppDefaults.wasInstalledBeforeDynamicPersistence`
//  — the same install-date gating the rest of the app's defaults use.
//
//  WHY IT IS NOT A `WhatsNewStore` ANNOUNCEMENT
//  -------------------------------------------
//  Same three reasons as the NWS notice: `WhatsNewStore` is gated on
//  `productUpdatesOptIn` (this is not marketing and must reach opted-out
//  users), it is push-driven via Firebase (this is a build-time fact known
//  locally), and every announcement opens a URL (there is no page for this).
//
//  WHO STOPS SEEING IT
//  -------------------
//  Three ways out, all permanent:
//    1. The ✕ — an explicit acknowledgement.
//    2. Choosing On or Off in Settings ▸ Reliability. The notice exists to say
//       "your mode changed and you did not pick it"; a user who has since
//       picked a mode has answered it, so that counts as an implicit dismissal
//       and is latched so returning to Dynamic later cannot resurrect it.
//    3. Never having been on `.dynamic` at all — the same code path as (2).
//
//  WHY ACCENT AND NOT ORANGE
//  -------------------------
//  Orange on the home screen means "your alarms may not ring right now" and
//  that monopoly is worth keeping. Alarms ring in every persistence mode —
//  AlarmKit is scheduled unconditionally (see DynamicPersistence.swift). What
//  changed is *reachability*, which is a fact to state once, not a malfunction.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class DynamicModeNotice {
    static let shared = DynamicModeNotice()

    private static let dismissedKey = "dynamicModeNoticeDismissed"
    private static let debugForceKey = "debugForceDynamicModeNotice"

    private var dismissed: Bool

    /// DEBUG-only force-show. Declared unconditionally and stored (rather than
    /// wrapped in `#if DEBUG`) so the `@Observable` macro never has to reason
    /// about a conditionally-compiled stored property; it is only ever *read*
    /// or *written* under `#if DEBUG`, and is left false in release builds.
    var debugForceShow: Bool {
        didSet { UserDefaults.standard.set(debugForceShow, forKey: Self.debugForceKey) }
    }

    private init() {
        dismissed = UserDefaults.standard.bool(forKey: Self.dismissedKey)
        #if DEBUG
        debugForceShow = UserDefaults.standard.bool(forKey: Self.debugForceKey)
        #else
        debugForceShow = false
        #endif
    }

    /// True when the banner should render. Read from the view, so both a mode
    /// change and a debug toggle update it live.
    ///
    /// Not a pure getter: a non-`.dynamic` mode latches the dismissal (see
    /// "who stops seeing it" above). The persist happens inline — UserDefaults
    /// is not observed, so it cannot disturb a view update — while the
    /// observable mirror is deferred to the next main-actor turn so we never
    /// mutate observed state *during* a view update.
    var shouldShow: Bool {
        #if DEBUG
        // Force-show wins over a previous dismissal, so the notice can be
        // re-tested without reinstalling.
        if debugForceShow { return true }
        #endif
        if dismissed { return false }
        // A fresh install has always been Dynamic — nothing changed under it, so
        // it is never offered the migration notice. No latch here: there is
        // nothing to dismiss, and the check is cheap to re-evaluate.
        guard AppDefaults.wasInstalledBeforeDynamicPersistence else { return false }
        guard DeviceSettings.shared.appPersistenceMode == .dynamic else {
            latchImplicitDismissal()
            return false
        }
        return true
    }

    /// The user has answered the question this notice asks by picking a mode
    /// in Settings. Latched so a later return to Dynamic — now a deliberate
    /// choice — does not bring the banner back.
    private func latchImplicitDismissal() {
        guard !UserDefaults.standard.bool(forKey: Self.dismissedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.dismissedKey)
        Task { @MainActor [weak self] in
            self?.dismissed = true
        }
        AppLogger.shared.log(
            "Dynamic mode notice: implicitly dismissed (user has chosen a persistence mode)",
            category: .general
        )
    }

    func dismiss() {
        dismissed = true
        UserDefaults.standard.set(true, forKey: Self.dismissedKey)
        #if DEBUG
        // Otherwise the force-show toggle would keep the banner glued to the
        // screen and the ✕ would look broken.
        debugForceShow = false
        #endif
        AppLogger.shared.log("Dynamic mode notice: dismissed by user", category: .general)
    }

    #if DEBUG
    /// Returns the install to "never seen it".
    func debugReset() {
        dismissed = false
        debugForceShow = false
        UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
        UserDefaults.standard.removeObject(forKey: Self.debugForceKey)
    }

    var debugDismissed: Bool { dismissed }
    #endif
}

// MARK: - Banner

/// Sits with the other home banners, below the safety warnings and above
/// What's New. Display-only: like `NWSRemovalBanner` and
/// `RadioPersistenceBanner`, the body is not tappable — no existing home
/// banner deep-links, and a banner that looks tappable but is not is worse
/// than a plain one. The copy names the destination in words instead.
struct DynamicModeBanner: View {
    @State private var notice = DynamicModeNotice.shared
    @State private var settings = DeviceSettings.shared

    /// MQTT users lose something concrete under Dynamic — inbound Home
    /// Assistant commands only land while the app is awake — so they get the
    /// consequence spelled out rather than the general statement.
    private var message: String {
        if settings.mqttEnabled {
            return "Home Assistant commands now reach the app only while it's awake — charging, near an alarm, or while the Alarm & Command Widget is armed. Switch App Persistence to On for always-on control."
        }
        return "The app now sleeps on battery and wakes for alarms and charging. Alarms always ring. Choose a different mode in Settings ▸ Reliability."
    }

    /// `bolt.badge.automatic.fill` is the same glyph Settings uses for the
    /// App Persistence row, but it is not on every OS version we support — a
    /// missing SF Symbol draws nothing at all, which reads as a broken app.
    private var iconName: String {
        MQTTCommand.symbolExists("bolt.badge.automatic.fill")
            ? "bolt.badge.automatic.fill"
            : "gauge.with.needle.fill"
    }

    var body: some View {
        if notice.shouldShow {
            HomeNoticeBanner(
                systemImage: iconName,
                title: "App Persistence is now Dynamic",
                message: message,
                onDismiss: { notice.dismiss() }
            )
        }
    }
}
