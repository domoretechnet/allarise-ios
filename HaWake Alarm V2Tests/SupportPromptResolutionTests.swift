//
//  SupportPromptResolutionTests.swift
//  HaWake Alarm V2Tests
//
//  Pins the pure cadence logic behind the free-model support prompt
//  (SupportPromptResolution). Pure value → value, no singletons, no storage —
//  the SupportPromptManager wiring (UserDefaults/iCloud/scene phase) is not
//  exercised here.
//
//  The invariants that must never regress:
//  - A supporter is NEVER prompted, no matter how many active days accrue.
//  - The prompt is shown at MOST 3 times, then never again (hard cap).
//  - The three prompts fall at the fixed active-use-day marks 30, 45, 125.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

struct SupportPromptResolutionTests {

    // MARK: - Schedule constants

    @Test func scheduleConstants() {
        #expect(SupportPromptResolution.promptThresholds == [30, 45, 125])
        #expect(SupportPromptResolution.maxPrompts == 3)
    }

    @Test func thresholdForEachPromptIndex() {
        #expect(SupportPromptResolution.threshold(forPromptCount: 0) == 30)
        #expect(SupportPromptResolution.threshold(forPromptCount: 1) == 45)
        #expect(SupportPromptResolution.threshold(forPromptCount: 2) == 125)
        #expect(SupportPromptResolution.threshold(forPromptCount: 3) == nil)   // cap
        #expect(SupportPromptResolution.threshold(forPromptCount: -1) == nil)  // guard
    }

    // MARK: - shouldPrompt

    @Test func supporterIsNeverPrompted() {
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: true, activeDayCount: 9999, promptCount: 0) == false)
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: true, activeDayCount: 30, promptCount: 0) == false)
    }

    @Test func firstPromptDueAtDay30() {
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: false, activeDayCount: 29, promptCount: 0) == false)
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: false, activeDayCount: 30, promptCount: 0) == true)
    }

    @Test func secondPromptDueAtDay45() {
        // Already shown once (promptCount 1) → next mark is day 45.
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: false, activeDayCount: 44, promptCount: 1) == false)
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: false, activeDayCount: 45, promptCount: 1) == true)
    }

    @Test func thirdPromptDueAtDay125() {
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: false, activeDayCount: 124, promptCount: 2) == false)
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: false, activeDayCount: 125, promptCount: 2) == true)
    }

    @Test func capReachedStopsPrompting() {
        // Three prompts already shown — never again, even far past day 90.
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: false, activeDayCount: 100_000, promptCount: 3) == false)
    }

    // MARK: - End-to-end schedule walk

    @Test func threePromptsAt30_45_125ThenSilent() {
        var count = 0
        // Prompt 1 at day 30.
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: false, activeDayCount: 30, promptCount: count))
        count = 1
        // Prompt 2 at day 45 (not before).
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: false, activeDayCount: 44, promptCount: count) == false)
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: false, activeDayCount: 45, promptCount: count) == true)
        count = 2
        // Prompt 3 at day 125 (not before).
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: false, activeDayCount: 124, promptCount: count) == false)
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: false, activeDayCount: 125, promptCount: count) == true)
        count = 3
        // Silent forever after the third.
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: false, activeDayCount: 100_000, promptCount: count) == false)
    }

    @Test func becomingASupporterHaltsAllFuturePrompts() {
        #expect(SupportPromptResolution.shouldPrompt(isSupporter: true, activeDayCount: 45, promptCount: 1) == false)
    }
}
