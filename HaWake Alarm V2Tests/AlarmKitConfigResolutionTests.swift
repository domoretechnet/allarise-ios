//
//  AlarmKitConfigResolutionTests.swift
//  HaWake Alarm V2Tests
//
//  Locks in the configuration rules behind AlarmKit's contentless
//  `com.apple.AlarmKit.Alarm Code=0 "(null)"` (al-6hh).
//
//  For months the failure site guessed at a per-app quota. Measured wrong
//  (`al-bee.4`, iOS 26.6): 500 concurrently scheduled `.fixed` alarms produced
//  500 successes and 0 errors. The real, reproducible causes are configuration
//  shapes — and shapes are exactly what a unit test can hold still.
//
//  What is NOT provable here, and only on device: that AlarmKit actually
//  accepts these configurations, the `.alerting` residency behaviour, and the
//  stop-then-cancel id reclaim in `AlarmKitScheduler.clearResidentAlarm`. All
//  of those need a real `AlarmManager`.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

@Suite("AlarmKit configuration resolution")
struct AlarmKitConfigResolutionTests {

    // MARK: - The countdown-on-fixed-date rule

    @Test("No Allarise tier ever gets a countdown presentation")
    func everyTierIsAlertOnly() {
        for tier in AlarmKitTier.allCases {
            #expect(
                AlarmKitConfigResolution.presentationKind(for: tier) == .alertOnly,
                "\(tier.rawValue) must stay alert-only — a countdown presentation on a schedule with no countdown throws Code=0"
            )
        }
    }

    @Test("Every tier's schedule + presentation pairing is one AlarmKit accepts")
    func everyTierPairingIsSupported() {
        for tier in AlarmKitTier.allCases {
            let schedule = AlarmKitConfigResolution.scheduleKind(for: tier)
            let presentation = AlarmKitConfigResolution.presentationKind(for: tier)
            #expect(
                AlarmKitConfigResolution.isSupported(schedule: schedule, presentation: presentation),
                "\(tier.rawValue) builds an unsupported pairing: \(schedule.rawValue) + \(presentation.rawValue)"
            )
        }
    }

    @Test("The three fixed-date tiers are fixed-date, and only the weekly tier is relative")
    func scheduleKindsMatchTheDesign() {
        #expect(AlarmKitConfigResolution.scheduleKind(for: .mainFailsafe) == .fixedDate)
        #expect(AlarmKitConfigResolution.scheduleKind(for: .ringingGuard) == .fixedDate)
        #expect(AlarmKitConfigResolution.scheduleKind(for: .snoozeFailsafe) == .fixedDate)
        #expect(AlarmKitConfigResolution.scheduleKind(for: .weeklyBackup) == .relativeWeekly)
    }

    @Test("A countdown presentation is rejected on every schedule shape we build")
    func countdownIsNeverSupported() {
        #expect(!AlarmKitConfigResolution.isSupported(schedule: .fixedDate, presentation: .countdown))
        #expect(!AlarmKitConfigResolution.isSupported(schedule: .relativeWeekly, presentation: .countdown))
    }

    // MARK: - Weekday mapping

    @Test("1…7 map to Sunday…Saturday in order")
    func weekdaysMapInOrder() {
        let mapped = AlarmKitConfigResolution.weekdays(from: [1, 2, 3, 4, 5, 6, 7])
        #expect(mapped == [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday])
    }

    @Test("A weekday set is order-independent")
    func weekdayMappingIsSorted() {
        #expect(AlarmKitConfigResolution.weekdays(from: [6, 2]) == [.monday, .friday])
    }

    @Test("Out-of-range day numbers are dropped, not mapped to something wrong")
    func outOfRangeDaysAreDropped() {
        #expect(AlarmKitConfigResolution.weekdays(from: [0, 2, 8, -3]) == [.monday])
    }

    @Test("A day set with nothing mappable cannot arm a weekly backup")
    func unmappableDaysCannotArm() {
        // Reachable: `isRecurring` only tests that `recurringDaysRaw` is
        // non-empty, and AlarmBackupStore restores that raw string verbatim.
        #expect(!AlarmKitConfigResolution.canArmWeekly(days: []))
        #expect(!AlarmKitConfigResolution.canArmWeekly(days: [0]))
        #expect(!AlarmKitConfigResolution.canArmWeekly(days: [8, 99]))
    }

    @Test("A real weekday set can arm a weekly backup")
    func realDaysCanArm() {
        #expect(AlarmKitConfigResolution.canArmWeekly(days: [2, 3, 4, 5, 6]))
        #expect(AlarmKitConfigResolution.canArmWeekly(days: [1]))
    }

    // MARK: - Alert title

    @Test("A blank label never reaches AlarmKit as a blank alert title")
    func blankTitlesFallBack() {
        // What the user sees when a backup fires while the app is dead. An
        // empty title is a contentless alert, not a quieter one.
        #expect(AlarmKitConfigResolution.alertTitle(for: "") == "Alarm")
        #expect(AlarmKitConfigResolution.alertTitle(for: "   ") == "Alarm")
        #expect(AlarmKitConfigResolution.alertTitle(for: "\n\t") == "Alarm")
    }

    @Test("A real label is preserved, trimmed")
    func realTitlesArePreserved() {
        #expect(AlarmKitConfigResolution.alertTitle(for: "Wake Up") == "Wake Up")
        #expect(AlarmKitConfigResolution.alertTitle(for: "  Work  ") == "Work")
    }

    // MARK: - Failure description

    @Test("The failure description names the shape a Code=0 log needs")
    func describeCarriesTheShape() {
        let text = AlarmKitConfigResolution.describe(
            tier: .weeklyBackup,
            title: "Wake Up",
            weekdays: [2, 8]
        )
        #expect(text.contains("tier=weeklyBackup"))
        #expect(text.contains("schedule=relativeWeekly"))
        #expect(text.contains("presentation=alertOnly"))
        #expect(text.contains("supported=true"))
        #expect(text.contains("mappedWeekdays=1"))
    }

    @Test("The failure description omits weekdays for the fixed-date tiers")
    func describeOmitsWeekdaysWhenIrrelevant() {
        let text = AlarmKitConfigResolution.describe(tier: .mainFailsafe, title: "Wake Up")
        #expect(text.contains("tier=mainFailsafe"))
        #expect(text.contains("schedule=fixedDate"))
        #expect(!text.contains("weekdays="))
    }
}
