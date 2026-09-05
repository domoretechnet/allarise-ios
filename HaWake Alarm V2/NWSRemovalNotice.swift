//
//  NWSRemovalNotice.swift
//  HaWake Alarm V2
//
//  A one-time, local notice telling a user that NWS Weather Alerts were removed.
//
//  WHY THIS IS NOT A `WhatsNewStore` ANNOUNCEMENT
//  ----------------------------------------------
//  `WhatsNewStore` is the right tool for product news, and deliberately the wrong
//  one here on three counts:
//
//  1. It is gated on `productUpdatesOptIn`. We removed a *safety* feature, and a
//     user who switched off marketing-style product updates has not consented to
//     losing that notice too. This one must reach them regardless.
//  2. It is push-driven (Firebase). This is a build-time fact, known locally, and
//     must not depend on a campaign being sent, on push permission, or on the app
//     having `GoogleService-Info.plist` at all.
//  3. Every announcement opens a URL. There is no page for this, by design.
//
//  So this is its own tiny store: local, consent-independent, link-free, once.
//
//  WHO SEES IT
//  -----------
//  Only users who actually had the feature. `nwsDisclaimerAgreed` is the durable
//  marker — the production migration clears `nwsAlertsEnabled` but never touches
//  the disclaimer, so it still identifies the affected users even on installs that
//  already ran that migration in an earlier build. Someone who never enabled NWS
//  (it was US-only and beta-gated) lost nothing and is told nothing.
//
//  Eligibility is LATCHED once, rather than read live, so the banner cannot appear
//  or vanish later because some unrelated code touched the disclaimer flag.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class NWSRemovalNotice {
    static let shared = NWSRemovalNotice()

    /// Set once, the first time we get a chance to look at the user's NWS state.
    /// Absent = "not yet decided"; present = a settled yes/no that never re-runs.
    private static let eligibleKey = "nwsRemovalNoticeEligible"
    private static let dismissedKey = "nwsRemovalNoticeDismissed"

    private var eligible: Bool
    private var dismissed: Bool

    private init() {
        eligible = UserDefaults.standard.bool(forKey: Self.eligibleKey)
        dismissed = UserDefaults.standard.bool(forKey: Self.dismissedKey)
    }

    /// True when the banner should render. Read from the view, so flipping a debug
    /// toggle updates it live.
    var shouldShow: Bool {
        #if DEBUG
        // Force-show wins over both eligibility and a previous dismissal, so the
        // notice can be re-tested without reinstalling.
        if DeviceSettings.shared.debugForceNWSRemovalNotice { return true }
        #endif
        return eligible && !dismissed
    }

    /// Decides — once, permanently — whether this install gets the notice.
    ///
    /// Call from `AppDelegate` right after `disableNWSForProductionIfNeeded()`.
    /// Deliberately keyed on its own flag rather than piggy-backing on
    /// `nwsProdDisabledMigrationV1`: that migration may already have run in an
    /// earlier build, and those users are exactly the ones who had NWS silently
    /// switched off and most need telling.
    func latchEligibilityIfNeeded() {
        guard UserDefaults.standard.object(forKey: Self.eligibleKey) == nil else { return }
        let hadNWS = DeviceSettings.shared.nwsDisclaimerAgreed
        eligible = hadNWS
        UserDefaults.standard.set(hadNWS, forKey: Self.eligibleKey)
        AppLogger.shared.log(
            "NWS removal notice: eligibility latched (\(hadNWS ? "will show" : "user never enabled NWS"))",
            category: .notification
        )
    }

    func dismiss() {
        dismissed = true
        UserDefaults.standard.set(true, forKey: Self.dismissedKey)
        #if DEBUG
        // Otherwise the force-show toggle would keep the banner glued to the
        // screen and the ✕ would look broken.
        DeviceSettings.shared.debugForceNWSRemovalNotice = false
        #endif
        AppLogger.shared.log("NWS removal notice: dismissed by user", category: .notification)
    }

    #if DEBUG
    /// Returns the install to "never seen it" — clears both the dismissal and the
    /// latched decision, so the next `latchEligibilityIfNeeded()` re-derives it
    /// from the current `nwsDisclaimerAgreed`.
    func debugReset() {
        dismissed = false
        eligible = false
        UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
        UserDefaults.standard.removeObject(forKey: Self.eligibleKey)
    }

    /// Re-runs the latch immediately, for the debug panel.
    func debugRelatch() {
        UserDefaults.standard.removeObject(forKey: Self.eligibleKey)
        latchEligibilityIfNeeded()
    }

    var debugEligible: Bool { eligible }
    var debugDismissed: Bool { dismissed }
    #endif
}

// MARK: - Banner

/// Sits with the other home banners. Uses the accent colour rather than orange:
/// the orange banners above it mean "your alarms may not ring right now", and that
/// monopoly is worth keeping. This is not a live malfunction — it is a permanent
/// change the user needs to know about once.
///
/// Unlike `WhatsNewBanner` the body is **not** tappable. There is no page to open,
/// and a tappable banner that does nothing is worse than a plain one.
struct NWSRemovalBanner: View {
    @State private var notice = NWSRemovalNotice.shared

    var body: some View {
        if notice.shouldShow {
            HomeNoticeBanner(
                systemImage: "cloud.bolt.fill",
                title: "Weather Alerts Removed",
                // Says plainly that something protective is gone and that the
                // user should not keep relying on it. No marketing softening.
                message: "NWS weather alerts have been removed from Allarise and are no longer monitored. Please use another source for severe weather warnings.",
                onDismiss: { notice.dismiss() }
            )
        }
    }
}
