//
//  AlarmFireAudioResolutionTests.swift
//  HaWake Alarm V2Tests
//
//  Cover for al-3ox (and, through it, al-bee.2): the fire path used to run the
//  whole audio pipeline for an alarm `showAlarm` had just QUEUED, so a second
//  alarm firing at 06:30 tore down the confirmed radio stream of the alarm the
//  user was looking at, and unlocked the player straight into a mission grace
//  period's deliberate silence.
//
//  The decision is a single boolean, deliberately, and the fire path gates every
//  audio step on it — system volume prep, `unlockIfRinging()`, `play()`,
//  `beginAttempt()`, the confirmation grace and the fade arm. So the tests that
//  matter most are the ones asserting the SOLO fire — the 99% case — has nothing
//  skipped and nothing cancelled, in both the tone-only and radio directions.
//  A resolver that ever answered "queued" for a lone alarm would silence it.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

// MARK: - The 99% case: one alarm, nothing changes

struct AlarmFireAudioSoloFireTests {

    /// The full decision for a lone fire, asserted field by field: this is the
    /// byte-for-byte-as-before contract. Tone-only and radio alarms take the
    /// SAME decision — the radio-specific steps (`beginAttempt`, the confirmation
    /// grace, the prewarm adoption) sit behind this one flag in the fire path,
    /// which is why one resolver covers both directions.
    @Test("Tone-only alarm firing alone: entire audio pipeline runs, nothing cancelled")
    func toneOnlyAlarmFiringAloneIsUnchanged() {
        let decision = AlarmFireAudioResolution.resolve(
            firingAlarmID: 111,
            isShowingAlarm: false,
            showingAlarmID: nil
        )
        #expect(decision.queuedBehindShowingAlarm == false)
        #expect(decision.runsAudioPipeline)
        #expect(decision.cancelsRadioPrewarm == false)
        #expect(decision.cancelsAlarmKitFailsafeImmediately == false)
    }

    @Test("Radio alarm firing alone: stream attempt and its prewarm survive")
    func radioAlarmFiringAloneIsUnchanged() {
        // Identical inputs by design — a radio alarm is not distinguishable here,
        // and must not be: its prewarm may only be cancelled when the alarm is
        // queued, never when it is the one ringing.
        let decision = AlarmFireAudioResolution.resolve(
            firingAlarmID: 222,
            isShowingAlarm: false,
            showingAlarmID: nil
        )
        #expect(decision.runsAudioPipeline)
        #expect(decision.cancelsRadioPrewarm == false)
        #expect(decision.cancelsAlarmKitFailsafeImmediately == false)
    }

    @Test("No window means no queue, whatever stale identity is left behind")
    func noWindowNeverQueues() {
        // currentAlarmID lingers after teardown in some paths; a window that does
        // not exist can never own the audio session.
        #expect(AlarmFireAudioResolution.willQueue(
            firingAlarmID: 1,
            isShowingAlarm: false,
            showingAlarmID: 2
        ) == false)
    }
}

// MARK: - Re-entry for the alarm already on screen

struct AlarmFireAudioSameAlarmTests {

    @Test("The alarm on screen re-entering its own fire path still runs its audio")
    func sameAlarmKeepsItsPipeline() {
        // checkAndShowPendingAlarm on foreground, a recovery pickup, or the fire
        // path's own idempotent re-assert. showAlarm treats this as a duplicate
        // and keeps the screen — but the sound may never have started, so the
        // audio work must still happen. Suppressing it here would be silence.
        let decision = AlarmFireAudioResolution.resolve(
            firingAlarmID: 7,
            isShowingAlarm: true,
            showingAlarmID: 7
        )
        #expect(decision.queuedBehindShowingAlarm == false)
        #expect(decision.runsAudioPipeline)
        #expect(decision.cancelsAlarmKitFailsafeImmediately == false)
    }
}

// MARK: - The overlap that started this (al-anx / al-3ox)

struct AlarmFireAudioQueuedTests {

    @Test("Second alarm firing while another is on screen skips the audio pipeline — al-3ox")
    func secondAlarmIsQueuedAndSilent() {
        // The incident: 06:25 alarm on screen and streaming, 06:30 alarm fires.
        let decision = AlarmFireAudioResolution.resolve(
            firingAlarmID: 630,
            isShowingAlarm: true,
            showingAlarmID: 625
        )
        #expect(decision.queuedBehindShowingAlarm)
        #expect(decision.runsAudioPipeline == false)
        #expect(decision.cancelsRadioPrewarm)
        #expect(decision.cancelsAlarmKitFailsafeImmediately)
    }

    @Test("A window with no identity still owns the session — matches showAlarm exactly")
    func windowWithoutIdentityStillQueues() {
        // showAlarm's condition was `isShowingAlarm && currentAlarmID != alarmID`,
        // so a window whose identity has not been set yet queues the newcomer.
        // Preserved deliberately: the pre-check and showAlarm's own branch must
        // agree, or the fire path would skip audio for an alarm that then gets
        // presented (or run audio for one that gets queued).
        #expect(AlarmFireAudioResolution.willQueue(
            firingAlarmID: 5,
            isShowingAlarm: true,
            showingAlarmID: nil
        ))
    }

    @Test("Decision is a pure function of its inputs")
    func decisionIsStableAndComparable() {
        let a = AlarmFireAudioResolution.resolve(firingAlarmID: 1, isShowingAlarm: true, showingAlarmID: 2)
        let b = AlarmFireAudioResolution.resolve(firingAlarmID: 1, isShowingAlarm: true, showingAlarmID: 2)
        #expect(a == b)
        #expect(a != AlarmFireAudioResolution.resolve(firingAlarmID: 1, isShowingAlarm: true, showingAlarmID: 1))
    }
}
