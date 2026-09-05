//
//  AlarmOverrideResolutionTests.swift
//  HaWake Alarm V2Tests
//
//  Regression cover for al-qcd: the alarm editor threw away a per-alarm Hold
//  Duration unless the user also changed the skip MODE.
//
//  The bug was a disagreement between two rules that lived in different files:
//  Save wrote the duration only when the section was marked custom, but only the
//  mode picker ever marked it. Both rules now live in `AlarmOverrideResolution`,
//  and these tests pin the pair together — the marking test and the save test
//  are the two halves that drifted.
//
//  The invariant that must NOT regress in the other direction: a section the
//  user never touched still saves nil for every field, so the alarm keeps
//  following the global Settings value and a later change there still reaches
//  it. Option (b) — "always save the duration when mode is Hold" — would have
//  passed the first test and broken this one.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

// MARK: - Marking a section custom

struct AlarmOverrideMarkingTests {

    @Test("Editing ONLY the hold duration marks the section custom — the al-qcd bug")
    func durationEditAloneMarksCustom() {
        // Global 18s, user drags this alarm down to 2s and touches nothing else.
        #expect(AlarmOverrideResolution.marksCustom(alreadyCustom: false,
                                                    edited: 2.0,
                                                    global: 18.0))
    }

    @Test("Editing only the mode still marks custom, as it always did")
    func modeEditMarksCustom() {
        #expect(AlarmOverrideResolution.marksCustom(alreadyCustom: false,
                                                    edited: SkipAlarmMode.tap,
                                                    global: SkipAlarmMode.hold))
    }

    @Test("Landing exactly on the global value does not create an override")
    func matchingGlobalStaysDefault() {
        // Keeps the alarm tracking Settings instead of pinning today's number.
        #expect(!AlarmOverrideResolution.marksCustom(alreadyCustom: false,
                                                     edited: 1.5,
                                                     global: 1.5))
    }

    @Test("The flag latches on — passing back through the global value cannot clear it")
    func flagOnlyLatchesOn() {
        // Mid-drag a slider crosses the global value; that must not discard the
        // rest of the user's edits in this section.
        #expect(AlarmOverrideResolution.marksCustom(alreadyCustom: true,
                                                    edited: 1.5,
                                                    global: 1.5))
    }

    @Test("Max snooze count is an edit like any other")
    func maxCountEditMarksCustom() {
        #expect(AlarmOverrideResolution.marksCustom(alreadyCustom: false,
                                                    edited: 5,
                                                    global: 3))
    }
}

// MARK: - What Save persists — Skip

struct AlarmOverrideSkipSaveTests {

    @Test("A duration-only edit survives Save")
    func durationOnlyEditSurvivesSave() {
        // The whole bug: this used to resolve to holdDuration == nil.
        let fields = AlarmOverrideResolution.skipFields(isCustom: true,
                                                        mode: .hold,
                                                        holdDuration: 2.0)
        #expect(fields.holdDuration == 2.0)
        #expect(fields.mode == .hold)
        #expect(fields.allowSkipOnce)
    }

    @Test("An untouched section saves nil, so the alarm keeps following Settings")
    func untouchedSectionSavesNil() {
        let fields = AlarmOverrideResolution.skipFields(isCustom: false,
                                                        mode: .hold,
                                                        holdDuration: 2.0)
        #expect(fields.mode == nil)
        #expect(fields.holdDuration == nil)
        #expect(fields.allowSkipOnce)  // legacy default
    }

    @Test("Tap mode stores no duration")
    func tapClearsDuration() {
        let fields = AlarmOverrideResolution.skipFields(isCustom: true,
                                                        mode: .tap,
                                                        holdDuration: 9.0)
        #expect(fields.mode == .tap)
        #expect(fields.holdDuration == nil)
        #expect(fields.allowSkipOnce)
    }

    @Test("Disabled mode clears the duration and turns skipping off")
    func disabledClearsEverything() {
        let fields = AlarmOverrideResolution.skipFields(isCustom: true,
                                                        mode: .disabled,
                                                        holdDuration: 9.0)
        #expect(fields.mode == .disabled)
        #expect(fields.holdDuration == nil)
        #expect(!fields.allowSkipOnce)
    }
}

// MARK: - What Save persists — Snooze

struct AlarmOverrideSnoozeSaveTests {

    @Test("A snooze hold-duration-only edit survives Save")
    func snoozeDurationOnlyEditSurvivesSave() {
        let fields = AlarmOverrideResolution.snoozeFields(isCustom: true,
                                                          mode: .hold,
                                                          holdDuration: 3.0,
                                                          maxCount: 3)
        #expect(fields.holdDuration == 3.0)
        #expect(fields.maxCount == 3)
        #expect(fields.mode == .hold)
    }

    @Test("An untouched snooze section saves nil for all three override fields")
    func untouchedSnoozeSectionSavesNil() {
        let fields = AlarmOverrideResolution.snoozeFields(isCustom: false,
                                                          mode: .hold,
                                                          holdDuration: 3.0,
                                                          maxCount: 5)
        #expect(fields.mode == nil)
        #expect(fields.holdDuration == nil)
        #expect(fields.maxCount == nil)
    }

    @Test("Tap snooze keeps the max count but stores no hold duration")
    func tapKeepsMaxCount() {
        let fields = AlarmOverrideResolution.snoozeFields(isCustom: true,
                                                          mode: .tap,
                                                          holdDuration: 3.0,
                                                          maxCount: 4)
        #expect(fields.mode == .tap)
        #expect(fields.holdDuration == nil)
        #expect(fields.maxCount == 4)
    }

    @Test("Disabled snooze clears the max count too")
    func disabledClearsMaxCount() {
        let fields = AlarmOverrideResolution.snoozeFields(isCustom: true,
                                                          mode: .disabled,
                                                          holdDuration: 3.0,
                                                          maxCount: 4)
        #expect(fields.mode == .disabled)
        #expect(fields.holdDuration == nil)
        #expect(fields.maxCount == nil)
    }
}
