//
//  AlarmKitConfigResolution.swift
//  HaWake Alarm V2
//
//  The parts of "what configuration does this AlarmKit backup tier get?" that
//  can be decided without an AlarmKit session, pulled out of
//  `AlarmKitScheduler` so they can be tested and so a failure can name the
//  shape that failed.
//
//  Why this file exists (al-6hh, 2026-08-05)
//  -----------------------------------------
//  `AlarmManager.schedule` reports every rejection as the same opaque
//  `com.apple.AlarmKit.Alarm Code=0 "(null)"`. For months the comment at the
//  weekly-backup failure site guessed at a per-app quota. That guess was
//  MEASURED WRONG: bead `al-bee.4`, iOS 26.6, a real AlarmKit harness — 500
//  concurrently scheduled `.fixed` alarms in one app produced 500 successes and
//  0 errors, eight times this app's worst realistic case (15 alarms x 4 UUIDs).
//  There is no quota at any count Allarise can reach.
//
//  The same harness named two configuration shapes that DO throw Code=0:
//
//    1. A `countdown` presentation on a fixed-date `.alarm`. A fixed alarm has
//       no countdown to present, so the configuration is rejected outright.
//       Allarise has never attached one — every tier is alert-only — and
//       `isSupported(...)` below exists to keep it that way.
//    2. Re-using an id that is still resident and `.alerting`. A fired but
//       unattended alarm stays in `AlarmManager.alarms` as `.alerting`
//       indefinitely — across app death and across a reboot — and
//       `cancel(id:)` THROWS on an `.alerting` alarm. Swallowing that throw
//       and then scheduling the same deterministic id is the shape that
//       actually reached production; see `clearResidentAlarm` in
//       `AlarmKitScheduler`.
//
//  Measurement caveat: all of the above was measured on iOS 26.6. Production
//  targets iOS 27, one minor version ahead. Nothing here should be treated as
//  re-verified on 27 without a fresh run of the harness
//  (`~/Desktop/App Dev/AlarmKitLab/FINDINGS.md`).
//

import Foundation

/// The four AlarmKit alarms Allarise arms per alarm hash. Each has its own
/// deterministic UUID — see `Documents/16-FORCE-KILL-RECOVERY.md`.
enum AlarmKitTier: String, CaseIterable, Sendable {
    /// One-shot `.fixed` at the alarm's next fire + 5s.
    case mainFailsafe
    /// `.relative` weekly at the alarm's time + 2 min, recurring alarms only.
    case weeklyBackup
    /// One-shot `.fixed` at now + 15s, rolled forward while the app is alive.
    case ringingGuard
    /// One-shot `.fixed` at the snooze end + 5s.
    case snoozeFailsafe
}

/// The AlarmKit schedule shapes Allarise builds.
enum AlarmKitScheduleKind: String, Sendable {
    case fixedDate
    case relativeWeekly
}

/// The AlarmKit presentation shapes. Allarise only ever builds `alertOnly`;
/// `countdown` is modelled solely so the invalid pairing can be asserted
/// against in a test rather than discovered on a user's device.
enum AlarmKitPresentationKind: String, Sendable {
    case alertOnly
    case countdown
}

enum AlarmKitConfigResolution {

    /// The schedule shape each tier is built with. Changing a tier's schedule
    /// in `AlarmKitScheduler` without changing this is caught by the tests.
    static func scheduleKind(for tier: AlarmKitTier) -> AlarmKitScheduleKind {
        switch tier {
        case .mainFailsafe, .ringingGuard, .snoozeFailsafe:
            return .fixedDate
        case .weeklyBackup:
            return .relativeWeekly
        }
    }

    /// The presentation shape each tier is built with. Every Allarise tier is
    /// alert-only — the user must see the alarm's label when a backup fires,
    /// and none of these schedules has a countdown to show.
    static func presentationKind(for tier: AlarmKitTier) -> AlarmKitPresentationKind {
        .alertOnly
    }

    /// Whether AlarmKit will accept this pairing. A `countdown` presentation on
    /// a fixed-date schedule throws `com.apple.AlarmKit.Alarm Code=0`; there is
    /// nothing to count down to. `countdown` is only valid for a `.timer`, or an
    /// alarm carrying a `countdownDuration` — neither of which Allarise builds.
    static func isSupported(schedule: AlarmKitScheduleKind, presentation: AlarmKitPresentationKind) -> Bool {
        if presentation == .countdown { return false }
        return true
    }

    /// Convert Allarise's stored weekday numbers (1 = Sunday … 7 = Saturday) to
    /// `Locale.Weekday`, dropping anything out of range.
    ///
    /// Out-of-range values are not hypothetical: `recurringDaysRaw` is a plain
    /// persisted string and `AlarmBackupStore` restores it verbatim from JSON,
    /// so a corrupt or hand-edited backup can leave `isRecurring == true` with
    /// no mappable day in it.
    static func weekdays(from days: Set<Int>) -> [Locale.Weekday] {
        days.sorted().compactMap { dayNumber in
            switch dayNumber {
            case 1: return .sunday
            case 2: return .monday
            case 3: return .tuesday
            case 4: return .wednesday
            case 5: return .thursday
            case 6: return .friday
            case 7: return .saturday
            default: return nil
            }
        }
    }

    /// Whether a weekly backup can be built for these days at all. An empty
    /// weekday list has no occurrence to schedule; arming it is a guaranteed
    /// Code=0 with no diagnostic, so the caller refuses it and says why.
    static func canArmWeekly(days: Set<Int>) -> Bool {
        !weekdays(from: days).isEmpty
    }

    /// The alert title for a tier. The label is what the user sees when a
    /// backup fires while the app is dead, so it must never be blank — an
    /// alert with no title is a contentless alert.
    static func alertTitle(for label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Alarm" : trimmed
    }

    /// One-line description of the configuration that was handed to
    /// `AlarmManager.schedule`, for the failure log. Code=0 carries no reason,
    /// so the log has to carry the shape instead.
    static func describe(tier: AlarmKitTier, title: String, weekdays days: Set<Int>? = nil) -> String {
        let schedule = scheduleKind(for: tier)
        let presentation = presentationKind(for: tier)
        var parts = [
            "tier=\(tier.rawValue)",
            "schedule=\(schedule.rawValue)",
            "presentation=\(presentation.rawValue)",
            "supported=\(isSupported(schedule: schedule, presentation: presentation))",
            "titleChars=\(title.count)"
        ]
        if let days {
            parts.append("weekdays=\(days.sorted().map(String.init).joined(separator: ","))")
            parts.append("mappedWeekdays=\(weekdays(from: days).count)")
        }
        return parts.joined(separator: " ")
    }
}
