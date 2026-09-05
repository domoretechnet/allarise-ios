//
//  ForceCloseHeartbeatDecisionTests.swift
//  HaWake Alarm V2Tests
//
//  The force-close heartbeat's arm gate (al-s96g). The bug it exists to prevent:
//  a stale persisted debug toggle, or residency ending while backgrounded, armed
//  the heartbeat when suspension was actually the DESIGNED next step — so iOS
//  suspended us seconds later and the pending "Allarise stopped running"
//  notification fired as a false alarm.
//
//  These tests pin the pure conjunction. Note especially that release builds pass
//  debugOverride: false ALWAYS — DeviceSettings.forceCloseWarningDebugOverride
//  compiles the toggle read out of release, so the "non-resident WITH override"
//  escape hatch below can only ever open in a DEBUG build.
//
//  Hermetic: AppLifecycleMonitor.shouldArmHeartbeat is pure — no notifications,
//  no timers, no singletons.
//

import Testing
@testable import HaWake_Alarm_V2

struct ForceCloseHeartbeatDecisionTests {

    @Test("Suppressed always stands the heartbeat down, even with override and keep-alive both on")
    func suppressedAlwaysWins() {
        #expect(AppLifecycleMonitor.shouldArmHeartbeat(
            suppressed: true,
            keepAliveNeeded: true,
            debugOverride: true,
            alarmRinging: false
        ) == false)
    }

    @Test("Non-resident without the debug override does not arm — suspension is expected")
    func nonResidentNoOverrideStandsDown() {
        #expect(AppLifecycleMonitor.shouldArmHeartbeat(
            suppressed: false,
            keepAliveNeeded: false,
            debugOverride: false,
            alarmRinging: false
        ) == false)
    }

    // The DEBUG-only escape hatch: forceCloseWarningDebugOverride is always false
    // in release, so this branch can only ever fire in a debug build.
    @Test("Non-resident WITH the debug override arms — the debug escape hatch")
    func nonResidentWithOverrideArms() {
        #expect(AppLifecycleMonitor.shouldArmHeartbeat(
            suppressed: false,
            keepAliveNeeded: false,
            debugOverride: true,
            alarmRinging: false
        ) == true)
    }

    @Test("A ringing alarm stands the heartbeat down — the backup notification handles it")
    func residentRingingStandsDown() {
        #expect(AppLifecycleMonitor.shouldArmHeartbeat(
            suppressed: false,
            keepAliveNeeded: true,
            debugOverride: false,
            alarmRinging: true
        ) == false)
    }

    // The path that MUST still warn: persistence resident, not suppressed, no ring
    // in progress — the genuine force-kill case the whole heartbeat exists for.
    @Test("Resident, not suppressed, not ringing arms the heartbeat")
    func residentQuietArms() {
        #expect(AppLifecycleMonitor.shouldArmHeartbeat(
            suppressed: false,
            keepAliveNeeded: true,
            debugOverride: false,
            alarmRinging: false
        ) == true)
    }

    // residencyDidChange reconciles BOTH directions through this same gate
    // (al-y7vc). These two pin the residency-END outcomes the imperative path
    // must honor: with the DEBUG override on, residency ending keeps the
    // heartbeat armed (the toggle promises warnings regardless of persistence);
    // with it off, residency ending stands the heartbeat down (suspension is
    // the designed next step, al-s96g).

    @Test("Residency ending with the debug override on keeps the heartbeat armed")
    func residencyEndWithOverrideStaysArmed() {
        #expect(AppLifecycleMonitor.shouldArmHeartbeat(
            suppressed: false,
            keepAliveNeeded: false,   // keepAliveNeeded reflects the new residency
            debugOverride: true,
            alarmRinging: false
        ) == true)
    }

    @Test("Residency ending without the override stands the heartbeat down")
    func residencyEndWithoutOverrideStandsDown() {
        #expect(AppLifecycleMonitor.shouldArmHeartbeat(
            suppressed: false,
            keepAliveNeeded: false,
            debugOverride: false,
            alarmRinging: false
        ) == false)
    }
}
