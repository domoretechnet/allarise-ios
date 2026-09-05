//
//  SleepTimerLogicTests.swift
//  HaWake Alarm V2Tests
//
//  The pure phase logic behind Bryson's OK-to-wake status light (al-2se).
//  The bug it exists to prevent: this same before_bed → ringing → sleeping_1..4
//  → off state machine is evaluated TWICE — once in HA's template sensor and
//  once here in SleepTimerLogic — both deriving the phase from now() vs. the
//  published schedule timestamps. If the app's derivation drifts from HA's, the
//  tracker card and the child's physical light disagree: the light says "stay in
//  bed" while the app says "ok to wake", or vice versa. So the boundaries have
//  to be pinned exactly — the ringing window, the quarter split, which side of
//  a boundary a probe lands on, and the degenerate spans a dragged wake-time can
//  produce. Every date here is built from DateComponents through an explicit
//  Gregorian calendar on a FIXED TimeZone; nothing reads the wall clock.
//

import Testing
import Foundation
@testable import HaWake_Alarm_V2

struct SleepTimerLogicTests {

    // Fixed calendar/zone so hour-of-day and 6 AM matching are deterministic.
    private static let zone = TimeZone(identifier: "America/Detroit")!
    private static var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }()

    /// Build an exact instant in the fixed zone. Fails the test if unbuildable.
    private static func date(_ y: Int, _ mo: Int, _ d: Int,
                             _ h: Int, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = s
        comps.timeZone = zone
        return cal.date(from: comps)!
    }

    // MARK: - detectedType(at:calendar:)  — 6 AM–6 PM is nap, else bedtime

    @Test("detectedType: mid-morning and evening land nap vs bedtime")
    func detectedTypeBasic() {
        #expect(SleepTimerLogic.detectedType(at: Self.date(2026, 8, 13, 10, 0), calendar: Self.cal) == .nap)
        #expect(SleepTimerLogic.detectedType(at: Self.date(2026, 8, 13, 19, 0), calendar: Self.cal) == .bedtime)
    }

    @Test("detectedType: 1 AM is bedtime, not a nap (the midnight hole)")
    func detectedTypeMidnightHole() {
        #expect(SleepTimerLogic.detectedType(at: Self.date(2026, 8, 13, 1, 0), calendar: Self.cal) == .bedtime)
    }

    @Test("detectedType: boundary hours — 6:00 AM nap, 5:59 PM nap, 6:00 PM bedtime")
    func detectedTypeBoundaries() {
        #expect(SleepTimerLogic.detectedType(at: Self.date(2026, 8, 13, 6, 0), calendar: Self.cal) == .nap)
        #expect(SleepTimerLogic.detectedType(at: Self.date(2026, 8, 13, 17, 59), calendar: Self.cal) == .nap)
        #expect(SleepTimerLogic.detectedType(at: Self.date(2026, 8, 13, 18, 0), calendar: Self.cal) == .bedtime)
    }

    // MARK: - defaultSleepEnd(type:bedTime:calendar:)

    @Test("defaultSleepEnd: nap is bedTime + 2h exactly")
    func defaultSleepEndNap() {
        let bed = Self.date(2026, 8, 13, 13, 0)
        let end = SleepTimerLogic.defaultSleepEnd(type: .nap, bedTime: bed, calendar: Self.cal)
        #expect(end == bed.addingTimeInterval(2 * 60 * 60))
    }

    @Test("defaultSleepEnd: bedtime 8 PM wakes at 6 AM the NEXT day")
    func defaultSleepEndBedtimeEvening() {
        let bed = Self.date(2026, 8, 13, 20, 0)
        let end = SleepTimerLogic.defaultSleepEnd(type: .bedtime, bedTime: bed, calendar: Self.cal)
        #expect(end == Self.date(2026, 8, 14, 6, 0))
    }

    @Test("defaultSleepEnd: bedtime 1 AM wakes at 6 AM the SAME day")
    func defaultSleepEndBedtimeAfterMidnight() {
        let bed = Self.date(2026, 8, 13, 1, 0)
        let end = SleepTimerLogic.defaultSleepEnd(type: .bedtime, bedTime: bed, calendar: Self.cal)
        #expect(end == Self.date(2026, 8, 13, 6, 0))
    }

    @Test("defaultSleepEnd: bedtime exactly 6 AM wakes the next 6 AM (strictly after)")
    func defaultSleepEndBedtimeExactlySixAM() {
        let bed = Self.date(2026, 8, 13, 6, 0)
        let end = SleepTimerLogic.defaultSleepEnd(type: .bedtime, bedTime: bed, calendar: Self.cal)
        #expect(end == Self.date(2026, 8, 14, 6, 0))
    }

    // MARK: - phase(of:at:)

    /// A well-formed session: clean 2-hour sleep span anchored at bedTime.
    /// bedTime 8:00 PM → sleepEnd 10:00 PM; ringing overlays the first 30 s.
    private static func twoHourSession() -> SleepTimerSession {
        let bed = date(2026, 8, 13, 20, 0)
        return SleepTimerSession(id: UUID(), type: .bedtime,
                                 createdAt: date(2026, 8, 13, 19, 45),
                                 bedTime: bed, sleepEnd: bed.addingTimeInterval(2 * 60 * 60))
    }

    @Test("phase: before bedTime is .beforeBed")
    func phaseBeforeBed() {
        let s = Self.twoHourSession()
        #expect(SleepTimerLogic.phase(of: s, at: s.bedTime.addingTimeInterval(-60)) == .beforeBed)
    }

    @Test("phase: the 30-second ringing overlay, then straight into sleeping_1")
    func phaseRinging() {
        let s = Self.twoHourSession()
        // Exactly at bedTime is already ringing (not before-bed).
        #expect(SleepTimerLogic.phase(of: s, at: s.bedTime) == .ringing)
        #expect(SleepTimerLogic.phase(of: s, at: s.bedTime.addingTimeInterval(15)) == .ringing)
        // Exactly at ringing-end the overlay lifts — sleeping_1 territory,
        // which ringing was covering all along.
        #expect(SleepTimerLogic.phase(of: s, at: s.bedTime.addingTimeInterval(SleepTimerLogic.ringingWindow)) == .sleeping1)
    }

    @Test("phase: the four sleeping quarters anchor at bedTime, probed just inside each")
    func phaseSleepingQuarters() {
        let s = Self.twoHourSession()
        let bed = s.bedTime
        #expect(SleepTimerLogic.phase(of: s, at: bed.addingTimeInterval(1 * 60)) == .sleeping1)
        #expect(SleepTimerLogic.phase(of: s, at: bed.addingTimeInterval(31 * 60)) == .sleeping2)
        #expect(SleepTimerLogic.phase(of: s, at: bed.addingTimeInterval(61 * 60)) == .sleeping3)
        #expect(SleepTimerLogic.phase(of: s, at: bed.addingTimeInterval(91 * 60)) == .sleeping4)
        // Just before sleepEnd is still the 4th quarter.
        #expect(SleepTimerLogic.phase(of: s, at: s.sleepEnd.addingTimeInterval(-60)) == .sleeping4)
    }

    @Test("phase: at and after sleepEnd is .off")
    func phaseOff() {
        let s = Self.twoHourSession()
        #expect(SleepTimerLogic.phase(of: s, at: s.sleepEnd) == .off)
        #expect(SleepTimerLogic.phase(of: s, at: s.sleepEnd.addingTimeInterval(60)) == .off)
    }

    @Test("phase: exact quarter boundaries land in the LATER quarter")
    func phaseBoundaryLandsLater() {
        let s = Self.twoHourSession()
        let bed = s.bedTime
        // Exactly the 25% mark (+30 min into a 2 h span) → sleeping2, not sleeping1.
        #expect(SleepTimerLogic.phase(of: s, at: bed.addingTimeInterval(30 * 60)) == .sleeping2)
        // 50% mark → sleeping3.
        #expect(SleepTimerLogic.phase(of: s, at: bed.addingTimeInterval(60 * 60)) == .sleeping3)
        // 75% mark → sleeping4.
        #expect(SleepTimerLogic.phase(of: s, at: bed.addingTimeInterval(90 * 60)) == .sleeping4)
    }

    /// sleepEnd dragged INSIDE the ringing overlay: sleepEnd < bedTime + 30 s.
    private static func degenerateSession() -> SleepTimerSession {
        let bed = date(2026, 8, 13, 20, 0)
        let sleepEnd = bed.addingTimeInterval(20) // only 20 s after bedTime
        return SleepTimerSession(id: UUID(), type: .nap,
                                 createdAt: date(2026, 8, 13, 19, 55),
                                 bedTime: bed, sleepEnd: sleepEnd)
    }

    @Test("phase: degenerate span — ringing until sleepEnd, then off, never sleeping")
    func phaseDegenerate() {
        let s = Self.degenerateSession()
        // Between bedTime and sleepEnd → ringing (the clamped overlay).
        #expect(SleepTimerLogic.phase(of: s, at: s.bedTime.addingTimeInterval(5)) == .ringing)
        #expect(SleepTimerLogic.phase(of: s, at: s.bedTime.addingTimeInterval(15)) == .ringing)
        // At/after sleepEnd → off.
        #expect(SleepTimerLogic.phase(of: s, at: s.sleepEnd) == .off)
        #expect(SleepTimerLogic.phase(of: s, at: s.sleepEnd.addingTimeInterval(60)) == .off)
        // No sleeping phase is ever reachable across the whole span.
        var t = s.bedTime
        while t < s.sleepEnd.addingTimeInterval(60) {
            #expect(SleepTimerLogic.phase(of: s, at: t).isSleeping == false)
            t = t.addingTimeInterval(2)
        }
    }

    @Test("phase: sleepEnd == bedTime is .off immediately at bedTime")
    func phaseZeroLength() {
        let bed = Self.date(2026, 8, 13, 20, 0)
        let s = SleepTimerSession(id: UUID(), type: .nap,
                                  createdAt: Self.date(2026, 8, 13, 19, 55),
                                  bedTime: bed, sleepEnd: bed)
        #expect(SleepTimerLogic.phase(of: s, at: bed) == .off)
    }

    // MARK: - quarterBoundaries(of:)

    @Test("quarterBoundaries: 2-hour span → three boundaries at +30/+60/+90 from bedTime")
    func quarterBoundariesWellFormed() {
        let s = Self.twoHourSession()
        let bed = s.bedTime
        let bounds = SleepTimerLogic.quarterBoundaries(of: s)
        #expect(bounds.count == 3)
        #expect(bounds == [
            bed.addingTimeInterval(30 * 60),
            bed.addingTimeInterval(60 * 60),
            bed.addingTimeInterval(90 * 60),
        ])
    }

    @Test("quarterBoundaries: zero-length span → empty")
    func quarterBoundariesDegenerate() {
        let bed = Self.date(2026, 8, 13, 20, 0)
        let s = SleepTimerSession(id: UUID(), type: .nap,
                                  createdAt: Self.date(2026, 8, 13, 19, 55),
                                  bedTime: bed, sleepEnd: bed)
        #expect(SleepTimerLogic.quarterBoundaries(of: s).isEmpty)
    }

    // MARK: - nextTransition(of:after:)

    @Test("nextTransition: walk a full session end to end")
    func nextTransitionWalk() {
        let s = Self.twoHourSession()
        let bed = s.bedTime
        let ringEnd = bed.addingTimeInterval(SleepTimerLogic.ringingWindow)

        // Before bedTime → bedTime.
        #expect(SleepTimerLogic.nextTransition(of: s, after: bed.addingTimeInterval(-60)) == bed)
        // During the ringing overlay → its end.
        #expect(SleepTimerLogic.nextTransition(of: s, after: bed.addingTimeInterval(15)) == ringEnd)
        // Inside sleeping_2 (between +30 and +60 from bedTime) → the 50% boundary.
        #expect(SleepTimerLogic.nextTransition(of: s, after: bed.addingTimeInterval(45 * 60))
                == bed.addingTimeInterval(60 * 60))
        // Inside sleeping_4 (between +90 and sleepEnd) → sleepEnd.
        #expect(SleepTimerLogic.nextTransition(of: s, after: bed.addingTimeInterval(100 * 60)) == s.sleepEnd)
        // At and after sleepEnd → nil.
        #expect(SleepTimerLogic.nextTransition(of: s, after: s.sleepEnd) == nil)
        #expect(SleepTimerLogic.nextTransition(of: s, after: s.sleepEnd.addingTimeInterval(60)) == nil)
    }

    // MARK: - mqttPayload(for:)

    @Test("mqttPayload: nil session is exactly [active: false]")
    func mqttPayloadNil() {
        let payload = SleepTimerLogic.mqttPayload(for: nil)
        #expect(payload.count == 1)
        #expect((payload["active"] as? Bool) == false)
    }

    @Test("mqttPayload: a session carries active/type/timestamps that round-trip ISO-8601")
    func mqttPayloadSession() {
        let s = Self.twoHourSession()
        let payload = SleepTimerLogic.mqttPayload(for: s)

        #expect((payload["active"] as? Bool) == true)
        #expect((payload["type"] as? String) == "bedtime") // raw string, the HA contract

        let iso = ISO8601DateFormatter()
        func roundTrip(_ key: String) -> Date? {
            guard let str = payload[key] as? String else { return nil }
            return iso.date(from: str)
        }
        // Timestamps present and parse back to the source dates (within 1 s).
        let bed = try? #require(roundTrip("bed_time"))
        let end = try? #require(roundTrip("sleep_end"))
        let created = try? #require(roundTrip("created_at"))
        #expect(abs((bed ?? .distantPast).timeIntervalSince1970 - s.bedTime.timeIntervalSince1970) < 1)
        #expect(abs((end ?? .distantPast).timeIntervalSince1970 - s.sleepEnd.timeIntervalSince1970) < 1)
        #expect(abs((created ?? .distantPast).timeIntervalSince1970 - s.createdAt.timeIntervalSince1970) < 1)
    }

    @Test("mqttPayload: nap session reports type raw string \"nap\"")
    func mqttPayloadNapType() {
        let s = Self.degenerateSession() // type .nap
        #expect((SleepTimerLogic.mqttPayload(for: s)["type"] as? String) == "nap")
    }

    @Test("mqttPayload: carries sleep_end_updated_at as the ISO-8601 of the session's stamp (al-z9qx)")
    func mqttPayloadSleepEndUpdatedAt() {
        // A same-id remote is ordered against the local copy on this key, so the
        // publish must emit it for the wake-point drag's stamp to travel.
        let bed = Self.date(2026, 8, 13, 20, 0)
        let stamp = Self.date(2026, 8, 13, 21, 30)
        let s = SleepTimerSession(id: UUID(), type: .bedtime,
                                  createdAt: Self.date(2026, 8, 13, 19, 45),
                                  bedTime: bed, sleepEnd: bed.addingTimeInterval(2 * 60 * 60),
                                  sleepEndUpdatedAt: stamp)
        let payload = SleepTimerLogic.mqttPayload(for: s)
        let iso = ISO8601DateFormatter()
        #expect((payload["sleep_end_updated_at"] as? String) == iso.string(from: stamp))
    }
}
