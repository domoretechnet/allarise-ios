//
//  PersistenceResidencyResolutionTests.swift
//  HaWake Alarm V2Tests
//
//  Pins the pure decision logic behind the Dynamic App Persistence mode
//  (DynamicPersistence.swift): when the app should be resident, and when the
//  BGAppRefreshTask ladder should next ask to run. Pure value → value, no
//  singletons, no side effects — the controller wiring is deliberately not
//  exercised here.
//
//  The invariants that must never regress:
//  - .on is always resident; .off never is (and never submits a ladder task).
//  - .dynamic submits the ladder REGARDLESS of charging state — charging
//    affects residency, never submission (Low Power Mode affects neither).
//  - A ringing alarm always counts as resident, so nothing tears down audio
//    mid-ring.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

struct PersistenceResidencyResolutionTests {

    /// A fixed reference "now" so every window comparison is deterministic.
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func minutes(_ m: Double) -> TimeInterval { m * 60 }

    // MARK: - residentNow

    @Test("Mode .on is always resident, whatever the conditions")
    func onAlwaysResident() {
        #expect(PersistenceResidencyResolution.residentNow(
            mode: .on, isCharging: false, alarmRinging: false, nextFireDate: nil, now: now
        ))
        #expect(PersistenceResidencyResolution.residentNow(
            mode: .on, isCharging: true, alarmRinging: true,
            nextFireDate: now.addingTimeInterval(minutes(300)), now: now
        ))
    }

    @Test("Mode .off is never resident, even charging with an imminent alarm")
    func offNeverResident() {
        #expect(!PersistenceResidencyResolution.residentNow(
            mode: .off, isCharging: true, alarmRinging: false,
            nextFireDate: now.addingTimeInterval(minutes(10)), now: now
        ))
    }

    @Test("Dynamic: charging alone makes the app resident")
    func dynamicChargingResident() {
        #expect(PersistenceResidencyResolution.residentNow(
            mode: .dynamic, isCharging: true, alarmRinging: false, nextFireDate: nil, now: now
        ))
    }

    @Test("Dynamic: a ringing alarm counts as resident so audio is never torn down mid-ring")
    func dynamicRingingResident() {
        #expect(PersistenceResidencyResolution.residentNow(
            mode: .dynamic, isCharging: false, alarmRinging: true, nextFireDate: nil, now: now
        ))
    }

    @Test("Dynamic: inside the 75-minute pre-alarm window is resident")
    func dynamicInsideWindow() {
        let fire = now.addingTimeInterval(minutes(60))
        #expect(PersistenceResidencyResolution.residentNow(
            mode: .dynamic, isCharging: false, alarmRinging: false, nextFireDate: fire, now: now
        ))
    }

    @Test("Dynamic: exactly at the window boundary is resident")
    func dynamicAtWindowBoundary() {
        let fire = now.addingTimeInterval(PersistenceResidencyResolution.leadTime)
        #expect(PersistenceResidencyResolution.residentNow(
            mode: .dynamic, isCharging: false, alarmRinging: false, nextFireDate: fire, now: now
        ))
    }

    @Test("Dynamic: before the window, on battery, is not resident")
    func dynamicBeforeWindow() {
        let fire = now.addingTimeInterval(minutes(76))
        #expect(!PersistenceResidencyResolution.residentNow(
            mode: .dynamic, isCharging: false, alarmRinging: false, nextFireDate: fire, now: now
        ))
    }

    @Test("Dynamic: a fire date in the past does not hold residency")
    func dynamicPastFire() {
        let fire = now.addingTimeInterval(-minutes(1))
        #expect(!PersistenceResidencyResolution.residentNow(
            mode: .dynamic, isCharging: false, alarmRinging: false, nextFireDate: fire, now: now
        ))
    }

    @Test("Dynamic: no upcoming alarm, unplugged → not resident")
    func dynamicNoAlarm() {
        #expect(!PersistenceResidencyResolution.residentNow(
            mode: .dynamic, isCharging: false, alarmRinging: false, nextFireDate: nil, now: now
        ))
    }

    @Test("Dynamic: armed, unplugged, no alarm → resident (the new arm-keeps-awake rule)")
    func dynamicArmedResident() {
        #expect(PersistenceResidencyResolution.residentNow(
            mode: .dynamic, isCharging: false, alarmRinging: false, nextFireDate: nil,
            armed: true, residencyWhenArmed: true, now: now
        ))
    }

    @Test("Dynamic: armed but the feature is toggled off → not resident")
    func dynamicArmedButOptedOut() {
        #expect(!PersistenceResidencyResolution.residentNow(
            mode: .dynamic, isCharging: false, alarmRinging: false, nextFireDate: nil,
            armed: true, residencyWhenArmed: false, now: now
        ))
    }

    @Test("Dynamic: disarmed with the feature on, no other reason → not resident")
    func dynamicDisarmedNotResident() {
        #expect(!PersistenceResidencyResolution.residentNow(
            mode: .dynamic, isCharging: false, alarmRinging: false, nextFireDate: nil,
            armed: false, residencyWhenArmed: true, now: now
        ))
    }

    @Test("Armed never overrides .off — persistence Off stays Off")
    func offIgnoresArmed() {
        #expect(!PersistenceResidencyResolution.residentNow(
            mode: .off, isCharging: false, alarmRinging: false, nextFireDate: nil,
            armed: true, residencyWhenArmed: true, now: now
        ))
    }

    // MARK: - ladderEarliestBeginDate

    @Test(".off submits nothing")
    func offSubmitsNothing() {
        #expect(PersistenceResidencyResolution.ladderEarliestBeginDate(
            mode: .off, nextFireDate: now.addingTimeInterval(minutes(60)), now: now
        ) == nil)
    }

    @Test(".on keeps the historical +15 min heartbeat")
    func onHeartbeat() {
        let date = PersistenceResidencyResolution.ladderEarliestBeginDate(
            mode: .on, nextFireDate: nil, now: now
        )
        #expect(date == now.addingTimeInterval(PersistenceResidencyResolution.heartbeatInterval))
    }

    @Test("Dynamic with no upcoming alarm resubmits on the idle cadence — it still submits")
    func dynamicIdleStillSubmits() {
        let date = PersistenceResidencyResolution.ladderEarliestBeginDate(
            mode: .dynamic, nextFireDate: nil, now: now
        )
        #expect(date == now.addingTimeInterval(PersistenceResidencyResolution.idleResubmitInterval))
    }

    @Test("Dynamic, alarm 8h out: first submission aims 3.5h before the fire")
    func dynamicFarAlarm() {
        let fire = now.addingTimeInterval(minutes(8 * 60))
        let date = PersistenceResidencyResolution.ladderEarliestBeginDate(
            mode: .dynamic, nextFireDate: fire, now: now
        )
        #expect(date == fire.addingTimeInterval(-PersistenceResidencyResolution.firstSubmissionLead))
    }

    @Test("Dynamic, alarm 2h out: aims at the window start (fire − 75 min)")
    func dynamicNearAlarm() {
        let fire = now.addingTimeInterval(minutes(120))
        let date = PersistenceResidencyResolution.ladderEarliestBeginDate(
            mode: .dynamic, nextFireDate: fire, now: now
        )
        #expect(date == fire.addingTimeInterval(-PersistenceResidencyResolution.leadTime))
    }

    @Test("Dynamic, already inside the window: falls back to the heartbeat floor")
    func dynamicInsideWindowSubmission() {
        let fire = now.addingTimeInterval(minutes(60))
        let date = PersistenceResidencyResolution.ladderEarliestBeginDate(
            mode: .dynamic, nextFireDate: fire, now: now
        )
        #expect(date == now.addingTimeInterval(PersistenceResidencyResolution.heartbeatInterval))
    }

    @Test("Dynamic, window opens sooner than the 15-min floor: floor wins")
    func dynamicFloorWins() {
        let fire = now.addingTimeInterval(minutes(80))  // window start = now + 5 min
        let date = PersistenceResidencyResolution.ladderEarliestBeginDate(
            mode: .dynamic, nextFireDate: fire, now: now
        )
        #expect(date == now.addingTimeInterval(PersistenceResidencyResolution.heartbeatInterval))
    }

    // MARK: - ladderWakeAction

    @Test("Wake inside the window activates")
    func wakeActivates() {
        let fire = now.addingTimeInterval(minutes(70))
        #expect(PersistenceResidencyResolution.ladderWakeAction(nextFireDate: fire, now: now) == .activate)
    }

    @Test("Wake before the window resubmits for the window start")
    func wakeResubmits() {
        let fire = now.addingTimeInterval(minutes(180))
        let action = PersistenceResidencyResolution.ladderWakeAction(nextFireDate: fire, now: now)
        #expect(action == .resubmit(fire.addingTimeInterval(-PersistenceResidencyResolution.leadTime)))
    }

    @Test("Wake with no upcoming alarm goes idle but keeps the ladder alive")
    func wakeIdle() {
        let action = PersistenceResidencyResolution.ladderWakeAction(nextFireDate: nil, now: now)
        #expect(action == .idle(now.addingTimeInterval(PersistenceResidencyResolution.idleResubmitInterval)))
    }

    @Test("Wake after the fire has passed goes idle (the next occurrence is recomputed upstream)")
    func wakePastFire() {
        let fire = now.addingTimeInterval(-minutes(5))
        let action = PersistenceResidencyResolution.ladderWakeAction(nextFireDate: fire, now: now)
        #expect(action == .idle(now.addingTimeInterval(PersistenceResidencyResolution.idleResubmitInterval)))
    }

    // A wake landing while charging (or armed with residency opted in) is the
    // only recovery path after a background kill — the battery/arm observers
    // died with the process, so the wake must activate, window or not (al-q4fr).

    @Test("Wake while charging activates even far outside the pre-alarm window")
    func wakeChargingOutsideWindowActivates() {
        let fire = now.addingTimeInterval(minutes(180))
        let action = PersistenceResidencyResolution.ladderWakeAction(
            nextFireDate: fire, isCharging: true, now: now)
        #expect(action == .activate)
    }

    @Test("Wake while charging activates even with no upcoming alarm")
    func wakeChargingNoAlarmActivates() {
        let action = PersistenceResidencyResolution.ladderWakeAction(
            nextFireDate: nil, isCharging: true, now: now)
        #expect(action == .activate)
    }

    @Test("Wake while armed with residency opted in activates outside the window")
    func wakeArmedActivates() {
        let fire = now.addingTimeInterval(minutes(180))
        let action = PersistenceResidencyResolution.ladderWakeAction(
            nextFireDate: fire, armed: true, residencyWhenArmed: true, now: now)
        #expect(action == .activate)
    }

    @Test("Wake while armed but opted out still resubmits outside the window")
    func wakeArmedOptedOutResubmits() {
        let fire = now.addingTimeInterval(minutes(180))
        let action = PersistenceResidencyResolution.ladderWakeAction(
            nextFireDate: fire, armed: true, residencyWhenArmed: false, now: now)
        #expect(action == .resubmit(fire.addingTimeInterval(-PersistenceResidencyResolution.leadTime)))
    }
}
