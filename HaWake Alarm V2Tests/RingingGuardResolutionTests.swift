//
//  RingingGuardResolutionTests.swift
//  HaWake Alarm V2Tests
//
//  Regression cover for the 2026-08-05 dual-alarm incident (al-anx) and its two
//  decision-level causes:
//
//    al-kfe — the rolling ringing guard stopped rolling the moment a SECOND
//             alarm took over the global ringing flag, leaving the first
//             alarm's guard armed at its last rolled time.
//    al-0j7 — the duplicate-.alerting guard was keyed on that same flag, so the
//             armed guard then re-ran the whole fire path for an alarm that was
//             still on screen: restarting its tone and tearing down the radio
//             stream the second alarm had just started.
//
//  Both directions matter. The tests that must never be "fixed" by loosening
//  suppression are the ones asserting a genuine first ring still gets through:
//  a suppressed ring is silence, and silence is the failure this app cannot
//  have. When the evidence is ambiguous, ringing twice beats not ringing.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

// MARK: - Guard rolling

struct RingingGuardRollTests {

    @Test("Keeps rolling for the alarm that owns the global ringing flag")
    func rollsForActiveRingingAlarm() {
        #expect(RingingGuardResolution.shouldKeepRolling(
            rolledAlarmID: 1,
            activeRingingAlarmID: 1,
            showingAlarmID: nil,
            queuedAlarmIDs: []
        ))
    }

    @Test("Keeps rolling for a still-showing alarm after a second alarm takes the ringing flag — al-kfe")
    func rollsForShowingAlarmWhenSecondAlarmFires() {
        // Exactly the incident: alarm 1 on screen, alarm 2 fired and became the
        // active ringing alarm. Alarm 1's roller must NOT stop.
        #expect(RingingGuardResolution.shouldKeepRolling(
            rolledAlarmID: 1,
            activeRingingAlarmID: 2,
            showingAlarmID: 1,
            queuedAlarmIDs: [2]
        ))
    }

    @Test("Keeps rolling for a queued alarm waiting behind the showing one")
    func rollsForQueuedAlarm() {
        #expect(RingingGuardResolution.shouldKeepRolling(
            rolledAlarmID: 2,
            activeRingingAlarmID: 1,
            showingAlarmID: 1,
            queuedAlarmIDs: [2]
        ))
    }

    @Test("Stops rolling once the alarm is neither ringing, showing, nor queued")
    func stopsWhenAlarmIsFullyResolved() {
        #expect(!RingingGuardResolution.shouldKeepRolling(
            rolledAlarmID: 1,
            activeRingingAlarmID: nil,
            showingAlarmID: nil,
            queuedAlarmIDs: []
        ))
    }

    @Test("Stops rolling for a dismissed alarm while a DIFFERENT alarm rings on")
    func stopsForDismissedAlarmWhileAnotherRings() {
        // Alarm 1 dismissed, alarm 2 dequeued and now showing. Alarm 1's roller
        // must stop — otherwise the guard rolls forever.
        #expect(!RingingGuardResolution.shouldKeepRolling(
            rolledAlarmID: 1,
            activeRingingAlarmID: 2,
            showingAlarmID: 2,
            queuedAlarmIDs: []
        ))
    }
}

// MARK: - Duplicate .alerting suppression

struct RingingGuardDuplicateTests {

    /// The common case: nothing is ringing, nothing is on screen. A first ring.
    private func freshFire(alarmHash: Int) -> Bool {
        RingingGuardResolution.isDuplicateAlerting(
            alarmHash: alarmHash,
            handlingAlarmHash: nil,
            activeRingingAlarmID: nil,
            showingAlarmID: nil,
            isShowingAlarm: false,
            isAudioPlaying: false,
            isFadeActive: false
        )
    }

    @Test("A genuine first ring is never suppressed")
    func firstRingIsNotDuplicate() {
        #expect(!freshFire(alarmHash: 1))
    }

    @Test("The synchronous handling latch suppresses without needing audio evidence")
    func handlingLatchSuppresses() {
        #expect(RingingGuardResolution.isDuplicateAlerting(
            alarmHash: 1,
            handlingAlarmHash: 1,
            activeRingingAlarmID: nil,
            showingAlarmID: nil,
            isShowingAlarm: false,
            isAudioPlaying: false,
            isFadeActive: false
        ))
    }

    @Test("The active ringing alarm with audio up is a duplicate (pre-existing rule)")
    func activeRingingWithAudioIsDuplicate() {
        #expect(RingingGuardResolution.isDuplicateAlerting(
            alarmHash: 1,
            handlingAlarmHash: nil,
            activeRingingAlarmID: 1,
            showingAlarmID: nil,
            isShowingAlarm: false,
            isAudioPlaying: true,
            isFadeActive: false
        ))
    }

    @Test("An armed fade counts as audio evidence")
    func fadeCountsAsEvidence() {
        #expect(RingingGuardResolution.isDuplicateAlerting(
            alarmHash: 1,
            handlingAlarmHash: nil,
            activeRingingAlarmID: 1,
            showingAlarmID: nil,
            isShowingAlarm: false,
            isAudioPlaying: false,
            isFadeActive: true
        ))
    }

    @Test("The still-showing alarm is a duplicate after a second alarm takes the ringing flag — al-0j7")
    func showingAlarmIsDuplicateWhenRingingFlagMovedOn() {
        // The incident: alarm 1's late ringing guard reaches .alerting while
        // alarm 1 is on screen and alarm 2 owns the ringing flag. Before this
        // rule, the whole fire path re-ran for alarm 1 and killed alarm 2's
        // just-started radio stream.
        #expect(RingingGuardResolution.isDuplicateAlerting(
            alarmHash: 1,
            handlingAlarmHash: nil,
            activeRingingAlarmID: 2,
            showingAlarmID: 1,
            isShowingAlarm: true,
            isAudioPlaying: false,
            isFadeActive: false
        ))
    }

    @Test("A different alarm's window is NOT evidence — the second alarm still rings")
    func otherAlarmsWindowDoesNotSuppress() {
        // Alarm 2 fires for the FIRST time while alarm 1 is on screen with its
        // audio running. Suppressing here would silently drop alarm 2.
        #expect(!RingingGuardResolution.isDuplicateAlerting(
            alarmHash: 2,
            handlingAlarmHash: 1,
            activeRingingAlarmID: 1,
            showingAlarmID: 1,
            isShowingAlarm: true,
            isAudioPlaying: true,
            isFadeActive: true
        ))
    }

    @Test("An alarm window with no identity does not suppress anything")
    func nilShowingIDDoesNotSuppress() {
        #expect(!RingingGuardResolution.isDuplicateAlerting(
            alarmHash: 1,
            handlingAlarmHash: nil,
            activeRingingAlarmID: nil,
            showingAlarmID: nil,
            isShowingAlarm: true,
            isAudioPlaying: true,
            isFadeActive: true
        ))
    }

    @Test("Ringing flag alone, with nothing audible, does not suppress")
    func staleRingingFlagDoesNotSuppress() {
        // A stale activeRingingAlarmID with no window, no audio and no fade is
        // exactly the state a recovery tier exists to rescue — it must ring.
        #expect(!RingingGuardResolution.isDuplicateAlerting(
            alarmHash: 1,
            handlingAlarmHash: nil,
            activeRingingAlarmID: 1,
            showingAlarmID: nil,
            isShowingAlarm: false,
            isAudioPlaying: false,
            isFadeActive: false
        ))
    }
}
