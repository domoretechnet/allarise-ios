//
//  SleepSoundAlarmResolutionTests.swift
//  HaWake Alarm V2Tests
//
//  Cover for al-ecf (2026-08-06), which superseded al-3jm. The owner's decision:
//  an alarm going off STOPS the sleep sound, and it stays stopped however the
//  ring ends — snooze, dismiss, or with another alarm queued. No auto-resume in
//  any outcome; the user restarts them manually. al-3jm's resume-on-snooze is
//  gone.
//
//  The one rule carried over from al-3jm and that must never be "fixed" by
//  loosening it: the user-pause one. `pausedByAlarm` exists so a pause the user
//  asked for is never stopped out from under them.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

struct SleepSoundAlarmResolutionTests {

    // MARK: - An alarm always stops the sleep sound (al-ecf)

    @Test("Snoozing stops the sleep sound rather than resuming it — al-ecf")
    func snoozeStops() {
        #expect(SleepSoundAlarmResolution.resolve(
            outcome: .snoozed, pausedByAlarm: true, hasQueuedAlarms: false
        ) == .stop)
    }

    @Test("Dismissing stops the sleep sound — al-ecf")
    func dismissStops() {
        #expect(SleepSoundAlarmResolution.resolve(
            outcome: .dismissed, pausedByAlarm: true, hasQueuedAlarms: false
        ) == .stop)
    }

    // MARK: - Stopped stays stopped regardless of the queue (al-ecf)

    @Test("Snoozing stops even with another alarm queued — no resume, no blip")
    func snoozeStopsEvenWithQueuedAlarms() {
        #expect(SleepSoundAlarmResolution.resolve(
            outcome: .snoozed, pausedByAlarm: true, hasQueuedAlarms: true
        ) == .stop)
    }

    @Test("Dismissing stops regardless of what is queued")
    func dismissStopsEvenWithQueuedAlarms() {
        #expect(SleepSoundAlarmResolution.resolve(
            outcome: .dismissed, pausedByAlarm: true, hasQueuedAlarms: true
        ) == .stop)
    }

    // MARK: - A user-initiated pause is never touched

    @Test("A pause the user asked for is never stopped by a snooze")
    func userPauseSurvivesSnooze() {
        #expect(SleepSoundAlarmResolution.resolve(
            outcome: .snoozed, pausedByAlarm: false, hasQueuedAlarms: false
        ) == .none)
        #expect(SleepSoundAlarmResolution.resolve(
            outcome: .snoozed, pausedByAlarm: false, hasQueuedAlarms: true
        ) == .none)
    }

    @Test("A pause the user asked for is never stopped out from under them")
    func userPauseSurvivesDismiss() {
        #expect(SleepSoundAlarmResolution.resolve(
            outcome: .dismissed, pausedByAlarm: false, hasQueuedAlarms: false
        ) == .none)
        #expect(SleepSoundAlarmResolution.resolve(
            outcome: .dismissed, pausedByAlarm: false, hasQueuedAlarms: true
        ) == .none)
    }
}
