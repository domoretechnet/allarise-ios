//
//  RadioDeadAirPolicyTests.swift
//  HaWake Alarm V2Tests
//
//  Pins DeadAirPolicy — the pure decision logic behind RadioAlarmStreamer's
//  dead-air defence. A station can be technically playable (its clock advances)
//  while rendering silence; these tests lock in when that silence is allowed to
//  confirm and when a confirmed stream is declared dead air.
//
//  The fail-soft invariant is the important one: with no metering
//  (isMonitoring == false) every decision reduces to the clock-only world that
//  existed before StreamAudioLevelMonitor — mayConfirm allows, isDeadAir never
//  fires. That is what keeps a station where the tap can't attach behaving
//  exactly as it did before.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

struct RadioDeadAirPolicyTests {

    /// Fixed reference instant so every case is deterministic — no sleeping.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - mayConfirm (the confirmation gate)

    @Test("mayConfirm is fail-soft: no metering allows confirmation regardless of content args")
    func mayConfirmFailSoftAllows() {
        // isMonitoring == false short-circuits before any content reasoning.
        #expect(DeadAirPolicy.mayConfirm(isMonitoring: false, hasHeardAudio: false,
                                         contentGateActive: false, hasHeardContent: false) == true)
        #expect(DeadAirPolicy.mayConfirm(isMonitoring: false, hasHeardAudio: true,
                                         contentGateActive: true, hasHeardContent: true) == true)
    }

    @Test("mayConfirm blocks a monitored stream that has been silent (silence outranks content claims)")
    func mayConfirmBlocksSilent() {
        #expect(DeadAirPolicy.mayConfirm(isMonitoring: true, hasHeardAudio: false,
                                         contentGateActive: false, hasHeardContent: false) == false)
        // Even if the content flags claim content, no audible audio → dead air.
        #expect(DeadAirPolicy.mayConfirm(isMonitoring: true, hasHeardAudio: false,
                                         contentGateActive: true, hasHeardContent: true) == false)
    }

    @Test("mayConfirm is amplitude-only when the classifier is unavailable")
    func mayConfirmClassifierUnavailable() {
        // Audible + gate inactive → today's amplitude-only behavior: allow.
        #expect(DeadAirPolicy.mayConfirm(isMonitoring: true, hasHeardAudio: true,
                                         contentGateActive: false, hasHeardContent: false) == true)
    }

    @Test("mayConfirm holds a loud stream with no recognizable content (noise)")
    func mayConfirmBlocksNoiseWithGate() {
        #expect(DeadAirPolicy.mayConfirm(isMonitoring: true, hasHeardAudio: true,
                                         contentGateActive: true, hasHeardContent: false) == false)
    }

    @Test("mayConfirm allows a monitored stream with recognized content")
    func mayConfirmAllowsContent() {
        #expect(DeadAirPolicy.mayConfirm(isMonitoring: true, hasHeardAudio: true,
                                         contentGateActive: true, hasHeardContent: true) == true)
    }

    // MARK: - isDeadAir (the post-confirmation watchdog verdict)

    @Test("isDeadAir is false when not monitoring, regardless of silence")
    func isDeadAirNotMonitoring() {
        #expect(DeadAirPolicy.isDeadAir(
            isMonitoring: false,
            clockAdvanced: true,
            lastAudibleAt: now.addingTimeInterval(-100),
            monitoringSince: now.addingTimeInterval(-100),
            now: now
        ) == false)
    }

    @Test("isDeadAir is false when the clock did not advance, even after long silence")
    func isDeadAirClockNotAdvanced() {
        #expect(DeadAirPolicy.isDeadAir(
            isMonitoring: true,
            clockAdvanced: false,
            lastAudibleAt: now.addingTimeInterval(-100),
            monitoringSince: now.addingTimeInterval(-100),
            now: now
        ) == false)
    }

    @Test("isDeadAir is true when monitoring + advancing and last audio was 13s ago")
    func isDeadAirLastAudible13sAgo() {
        #expect(DeadAirPolicy.isDeadAir(
            isMonitoring: true,
            clockAdvanced: true,
            lastAudibleAt: now.addingTimeInterval(-13),
            monitoringSince: now.addingTimeInterval(-30),
            now: now
        ) == true)
    }

    @Test("isDeadAir is false when last audio was 11s ago (inside the silence window)")
    func isDeadAirLastAudible11sAgo() {
        #expect(DeadAirPolicy.isDeadAir(
            isMonitoring: true,
            clockAdvanced: true,
            lastAudibleAt: now.addingTimeInterval(-11),
            monitoringSince: now.addingTimeInterval(-30),
            now: now
        ) == false)
    }

    @Test("isDeadAir uses monitoringSince as baseline when nothing was ever audible (13s → true)")
    func isDeadAirNeverAudibleMonitoring13sAgo() {
        #expect(DeadAirPolicy.isDeadAir(
            isMonitoring: true,
            clockAdvanced: true,
            lastAudibleAt: nil,
            monitoringSince: now.addingTimeInterval(-13),
            now: now
        ) == true)
    }

    @Test("isDeadAir is false when both baselines are nil")
    func isDeadAirNoBaseline() {
        #expect(DeadAirPolicy.isDeadAir(
            isMonitoring: true,
            clockAdvanced: true,
            lastAudibleAt: nil,
            monitoringSince: nil,
            now: now
        ) == false)
    }
}
