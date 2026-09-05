//
//  KeepAliveSleepDecisionTests.swift
//  HaWake Alarm V2Tests
//
//  The keep-alive's "sleep sounds are active, stand down" branch (al-cbf).
//  The bug it exists to prevent: a user pause mutes the sleep engine and keeps
//  it running AS the keep-alive, then a system interruption tears that engine
//  down and leaves state stuck at .paused over a dead session. "active" alone
//  then meant "defer", so the keep-alive never took over — the app sat
//  backgrounded with an armed alarm and no audio coverage, one iOS sweep from
//  suspension. Coverage, not bare activity, decides whether deferring is safe.
//
//  Hermetic: KeepAliveSleepDecision.decide is pure — no audio engine, no session.
//

import Testing
@testable import HaWake_Alarm_V2

struct KeepAliveSleepDecisionTests {

    @Test("Sleep inactive always yields a keep-alive start, whatever coverage claims")
    func inactiveStarts() {
        #expect(KeepAliveSleepDecision.decide(sleepActive: false, hasLiveCoverage: false) == .startKeepAlive)
        // Coverage is meaningless when nothing is active — still start.
        #expect(KeepAliveSleepDecision.decide(sleepActive: false, hasLiveCoverage: true) == .startKeepAlive)
    }

    @Test("Active with live coverage defers — the running sleep engine owns the session")
    func coveredDefers() {
        #expect(KeepAliveSleepDecision.decide(sleepActive: true, hasLiveCoverage: true) == .deferToSleep)
    }

    // The core al-cbf case: state says active, but nothing is holding the session.
    @Test("Active without coverage reasserts rather than blindly deferring")
    func phantomReasserts() {
        #expect(KeepAliveSleepDecision.decide(sleepActive: true, hasLiveCoverage: false) == .reassertThenRecheck)
    }
}
