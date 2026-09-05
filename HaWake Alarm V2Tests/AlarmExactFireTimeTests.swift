//
//  AlarmExactFireTimeTests.swift
//  HaWake Alarm V2Tests
//
//  Guards `Alarm.firesAtExactTime` (al-is5q), the Kids Sleep bedtime alarm's
//  fire-time semantics. A plain one-time alarm resolves hour/minute to the next
//  daily occurrence — which zeroes seconds and rolls a just-passed minute to
//  TOMORROW. The exact branch must return the stored Date verbatim, and keep
//  returning it for up to 60 s after it passes so a "bed now" alarm reaches the
//  scheduler's overdue path (immediate ring) instead of vanishing for a day.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

@MainActor
struct AlarmExactFireTimeTests {

    private func exactAlarm(time: Date) -> Alarm {
        let a = Alarm(time: time, label: "Bedtime", isEnabled: true)
        a.firesAtExactTime = true
        return a
    }

    @Test("A future exact time is returned verbatim, seconds included")
    func futureTimeIsVerbatim() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fire = now.addingTimeInterval(30)   // the 30-second countdown
        #expect(exactAlarm(time: fire).nextFireDate(from: now) == fire)
    }

    @Test("A just-passed exact time still fires — the overdue path needs it")
    func justPassedStillReturned() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fire = now.addingTimeInterval(-2)   // "bed now", scheduling ran a moment later
        #expect(exactAlarm(time: fire).nextFireDate(from: now) == fire)
    }

    @Test("More than 60 s past is stale, not tomorrow")
    func stalePastIsNil() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fire = now.addingTimeInterval(-61)
        #expect(exactAlarm(time: fire).nextFireDate(from: now) == nil)
    }

    @Test("An exact one-shot that already fired never reschedules")
    func firedOneShotIsDone() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = exactAlarm(time: now.addingTimeInterval(30))
        a.lastFireDate = now.addingTimeInterval(-10)
        #expect(a.nextFireDate(from: now) == nil)
    }

    @Test("A plain one-time alarm keeps minute resolution — no behavior change")
    func plainAlarmUnaffected() {
        let cal = Calendar.current
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = Alarm(time: now.addingTimeInterval(90), label: "Regular", isEnabled: true)
        let fire = a.nextFireDate(from: now)
        #expect(fire != nil)
        if let fire {
            #expect(cal.component(.second, from: fire) == 0)
        }
    }
}
