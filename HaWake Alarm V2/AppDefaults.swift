//
//  AppDefaults.swift
//  HaWake Alarm V2
//
//  Install-date-gated default values for settings. When a default ships a new
//  value for new users, existing users continue to experience the value that
//  was shipping on the day they first installed the app — nothing they saw
//  working before silently changes under them.
//
//  See Documents/21-APP-DEFAULTS.md for the full workflow and rationale.
//

import Foundation

/// Central registry of setting defaults that are gated by the user's first-install date.
///
/// When a default value is changed over time, each historical value is preserved here and
/// selected based on when the user first installed the app. Callers ask for
/// `AppDefaults.<setting>` and receive whichever value was current at that user's
/// install moment — new users get the latest curated default; existing users keep seeing
/// the original default they were familiar with, even if they never explicitly set it.
///
/// ## Adding a new default change
/// 1. Add a new `v<N>_<shortName>` cutoff constant with the day the new default ships.
/// 2. Update the computed property for that setting to return the new value when
///    `installDate >= cutoff`, and the old value otherwise.
/// 3. Never rename, delete, or change a previously-shipped cutoff constant — doing so
///    would retroactively alter the experience for users already placed in its bucket.
///
/// See `Documents/21-APP-DEFAULTS.md` for a step-by-step walkthrough.
enum AppDefaults {

    // MARK: - Install Date Lookup

    /// The user's first-install date, as recorded by `StoreManager` in the Keychain.
    /// Respects the debug install-date override when one is set, so the
    /// Settings → Testing date picker can simulate any historical install date for
    /// default-bucket testing without touching source code.
    ///
    /// If no date has been written yet (extremely brief window on first launch, before
    /// `StoreManager.recordFirstInstallDateIfNeeded()` runs), we fall back to "now" —
    /// treating the user as a brand-new install who receives the latest defaults. This
    /// is safe because the real install date gets recorded almost immediately and any
    /// subsequent default lookups will resolve against it.
    private static var installDate: Date {
        StoreManager.effectiveFirstInstallDate ?? Date()
    }

    // MARK: - Version Cutoffs
    //
    // Each constant marks the day a new default value was shipped. A user whose install
    // date is BEFORE the cutoff keeps the previous default; a user installed ON or AFTER
    // the cutoff gets the new one.
    //
    // Naming convention: `v<N>_<shortDescription>` — the version suffix keeps cutoffs
    // sorted chronologically and makes log output easy to scan.
    //
    // Once shipped to real users, a cutoff constant is effectively immutable — changing
    // its date would reshuffle users between old/new buckets unpredictably.

    /// Day the default snooze interaction mode changed from `.hold` to `.tap`.
    /// Users installed before this date keep hold-to-snooze; installs on or after
    /// get tap-to-snooze as the out-of-the-box default.
    private static let v2_snoozeModeTap = makeDate(2026, 4, 10)

    /// Day the three-way App Persistence default (`.dynamic`) first shipped —
    /// the commit that moved every install onto Dynamic landed 2026-08-01. Used
    /// ONLY to gate `DynamicModeNotice`: an install from before this day was
    /// switched underneath the user and is told once; an install on or after it
    /// has always been Dynamic, so nothing changed and the notice would be a lie.
    /// The mode default itself stays unconditional — see the note below.
    private static let v3_dynamicPersistence = makeDate(2026, 8, 1)

    /// Day the muted appearance became the out-of-the-box look. Users installed
    /// before this date keep the Classic Colorful style they've always seen;
    /// installs on or after get the calmer muted look. If the release containing
    /// this cutoff ships later than this date, bump the date to the actual ship day.

    // MARK: - Default Values
    //
    // One computed property per setting that uses install-date gating. Callers read
    // `AppDefaults.<settingName>` in `DeviceSettings.init` as the fallback when the
    // UserDefaults key is missing. See `DeviceSettings.alarmVolumeLevel` for an example.

    /// Initial alarm volume (0.0 – 1.0) applied to new alarms when the user hasn't
    /// explicitly overridden it. Shipped at 0.5 since v1.
    static var alarmVolumeLevel: Double {
        // No cutoff yet — every user gets 0.5. When you want to bump this (e.g. to 0.8)
        // for new installs only, add a cutoff and branch here. See the accompanying docs.
        return 0.5
    }

    /// Default snooze duration in minutes applied to new alarms. Matches the iOS
    /// Clock app convention. No cutoff yet — every user gets 9.
    static var defaultSnoozeDuration: Int {
        return 9
    }

    /// Default maximum number of times an alarm can be snoozed before it must be
    /// dismissed. No cutoff yet — every user gets 3.
    static var defaultMaxSnoozeCount: Int {
        return 3
    }

    /// Default snooze interaction mode for newly-installed users.
    ///
    /// - Pre-`v2_snoozeModeTap`: `.hold` (original shipping default — press and hold
    ///   the snooze button to dismiss, protects against accidental taps).
    /// - On or after `v2_snoozeModeTap`: `.tap` (single tap to snooze, friendlier
    ///   for half-asleep users who struggle with the hold gesture).
    static var snoozeMode: SnoozeMode {
        if installDate < v2_snoozeModeTap {
            return .hold
        }
        return .tap
    }

    /// Default mission type applied to new alarms. `.none` means no mission is
    /// required to dismiss — the user can tap dismiss and be done. No cutoff yet.
    static var defaultMissionType: MissionType {
        return .none
    }

    /// Default alarm sound ID assigned to new alarms. `Solarpsychedelic` is the
    /// curated out-of-the-box wake-up tone. No cutoff yet.
    static var defaultAlarmSound: String {
        return "Solarpsychedelic"
    }

    /// Default app appearance preference. `"system"` follows the device's light/dark
    /// setting. Valid values are `"system"`, `"light"`, `"dark"`. No cutoff yet.
    static var appAppearance: String {
        return "system"
    }

    // App Persistence: the old boolean default (`backgroundKeepAliveEnabled`,
    // shipped ON since v1) was superseded 2026-07-29 by the three-way
    // `appPersistenceMode`, whose default is `.dynamic` for EVERY user —
    // deliberately unconditional rather than install-date-gated, because the
    // migration decision was "move everyone to Dynamic". See
    // DynamicPersistence.swift and Documents/21-APP-DEFAULTS.md.
    //
    // The *notice* about that move, however, IS install-date-gated: only a user
    // who installed before Dynamic shipped had a behaviour to change. A brand-new
    // install has always been Dynamic, so it must not be shown the "we moved you"
    // banner (it would be a lie). `DynamicModeNotice` reads the flag below.

    /// Whether this install predates the Dynamic App Persistence default, i.e.
    /// the user was migrated rather than starting on Dynamic. Drives whether
    /// `DynamicModeNotice` is offered at all.
    static var wasInstalledBeforeDynamicPersistence: Bool {
        installDate < v3_dynamicPersistence
    }

    // MARK: - Helpers

    /// Convenience for building a `Date` from year/month/day components.
    /// Falls back to `.distantFuture` on invalid input so a malformed cutoff puts every
    /// user into the "old defaults" bucket — a strictly safer failure mode than silently
    /// opting everyone into an untested new value.
    private static func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components) ?? .distantFuture
    }
}
