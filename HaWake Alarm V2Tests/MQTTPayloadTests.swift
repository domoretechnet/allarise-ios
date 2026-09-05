//
//  MQTTPayloadTests.swift
//  HaWake Alarm V2Tests
//
//  LAYER 1 of the MQTT test suite: the payload → model translation.
//
//  These tests send the EXACT JSON Home Assistant sends and assert on what the
//  app builds from it. They deliberately stop short of the broker: no network,
//  no ModelContainer, no scheduling, no notifications — so they are fast,
//  hermetic, and safe to run in CI. What they pin down is the contract that the
//  wire format depends on, which is where the regressions actually live
//  (mission sequences, the slot-clearing rule, the mapping tables, and the
//  payload parser's Python-literal fallback).
//
//  Layer 2 — publishing to a real broker and asserting on the retained state
//  topics the app publishes back — is a separate host-side script, because it
//  needs a running app and a broker. It only has to prove the wire works; the
//  translation is already proven here.
//
//  Reference: Documents/15-INBOUND-COMMANDS-REFERENCE.md
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

// NOTE: payload PARSING (`MQTTManager.parseCommandPayload`) — strict JSON,
// the Python-literal fallback, and the "None of the trash" regression — is
// already covered by `MQTTPayloadParsingTests` in HaWake_Alarm_V2Tests.swift.
// Not duplicated here.

// MARK: - Mission sequence construction

@MainActor
struct MQTTMissionSequenceTests {

    private var handler: MQTTCommandHandler { .shared }

    @Test("No `missions` key yields nil, so the caller falls back to `mission`")
    func absentMissionsIsNil() {
        #expect(handler.buildMissionSequence(from: ["mission": "math"]) == nil)
    }

    @Test("Bare-string elements build a sequence in order")
    func stringElements() throws {
        let seq = try #require(handler.buildMissionSequence(from: ["missions": ["math", "shake"]]))
        #expect(seq.count == 2)
        #expect(seq[0].type == .math)
        #expect(seq[1].type == .shake)
    }

    @Test("Object elements carry their own mission_config")
    func objectElements() throws {
        let payload: [String: Any] = [
            "missions": [
                ["mission": "math", "mission_config": ["math_count": 4, "math_difficulty": "hard"]],
                ["mission": "shake", "mission_config": ["shake_count": 30]],
            ]
        ]
        let seq = try #require(handler.buildMissionSequence(from: payload))
        #expect(seq.count == 2)
        #expect(seq[0].type == .math)
        #expect(seq[0].mathProblemCount == 4)
        #expect(seq[0].mathDifficulty == .hard)
        #expect(seq[1].type == .shake)
        #expect(seq[1].shakeCount == 30)
    }

    @Test("`type` is accepted as an alias for `mission` inside array elements")
    func typeAliasAccepted() throws {
        let seq = try #require(handler.buildMissionSequence(from: ["missions": [["type": "shake"]]]))
        #expect(seq.count == 1)
        #expect(seq[0].type == .shake)
    }

    @Test("An explicitly empty array means one default Tap mission, not zero")
    func emptyArrayYieldsSingleDefault() throws {
        let seq = try #require(handler.buildMissionSequence(from: ["missions": []]))
        #expect(seq.count == 1)
        #expect(seq[0].type == .none)
    }

    @Test("More than five missions are truncated to the cap, not rejected")
    func truncatesBeyondCap() throws {
        let payload: [String: Any] = [
            "missions": ["math", "shake", "math", "shake", "math", "shake", "math"]
        ]
        let seq = try #require(handler.buildMissionSequence(from: payload))
        #expect(seq.count == MQTTCommandHandler.maxMissionSlots)
        #expect(seq.count == 5)
    }

    @Test("Unrecognised mission names fall back to Tap rather than failing the payload")
    func unknownMissionFallsBack() throws {
        let seq = try #require(handler.buildMissionSequence(from: ["missions": ["definitely_not_a_mission"]]))
        #expect(seq[0].type == .none)
    }
}

// MARK: - applyMissions: the slot-clearing contract

@MainActor
struct MQTTApplyMissionsTests {

    private var handler: MQTTCommandHandler { .shared }

    /// The documented rule, and the reason the singular field behaves this way:
    /// "set this alarm's mission to X" must not leave invisible extra slots
    /// behind, or the alarm demands more than the automation said it would.
    @Test("Singular `mission` replaces slot 1 AND clears slots 2–5")
    func singularMissionClearsExtras() {
        let alarm = Alarm(label: "Multi", mission: Mission(type: .math))
        alarm.extraMissions = [Mission(type: .shake), Mission(type: .balanceBall)]
        #expect(alarm.extraMissions.count == 2)

        let applied = handler.applyMissions(from: ["mission": "shake"], to: alarm)

        #expect(applied)
        #expect(alarm.mission.type == .shake)
        #expect(alarm.extraMissions.isEmpty, "singular `mission` must clear slots 2–5")
    }

    @Test("`missions` replaces the entire sequence")
    func missionsArrayReplacesSequence() {
        let alarm = Alarm(label: "Multi", mission: Mission(type: .math))
        alarm.extraMissions = [Mission(type: .shake)]

        let applied = handler.applyMissions(from: ["missions": ["blockDrop_placeholder", "math", "shake"]], to: alarm)

        #expect(applied)
        #expect(alarm.extraMissions.count == 2)
        #expect(alarm.mission.type == .none, "unknown first element falls back to Tap")
        #expect(alarm.extraMissions[0].type == .math)
        #expect(alarm.extraMissions[1].type == .shake)
    }

    @Test("A payload carrying neither field leaves the sequence untouched")
    func noMissionFieldsIsNoOp() {
        let alarm = Alarm(label: "Multi", mission: Mission(type: .math))
        alarm.extraMissions = [Mission(type: .shake)]

        let applied = handler.applyMissions(from: ["label": "renamed only"], to: alarm)

        #expect(!applied)
        #expect(alarm.mission.type == .math)
        #expect(alarm.extraMissions.count == 1)
    }

    @Test("`missions` wins when a payload carries both forms")
    func missionsBeatsSingular() {
        let alarm = Alarm(label: "Multi", mission: Mission(type: .none))
        let payload: [String: Any] = ["mission": "math", "missions": ["shake", "math"]]

        handler.applyMissions(from: payload, to: alarm)

        #expect(alarm.mission.type == .shake)
        #expect(alarm.extraMissions.count == 1)
    }
}

// MARK: - Single-mission config mapping

@MainActor
struct MQTTMissionConfigTests {

    private var handler: MQTTCommandHandler { .shared }

    @Test("Shake config maps every field")
    func shakeConfig() {
        let mission = handler.buildMission(from: [
            "mission": "shake",
            "mission_config": [
                "shake_mode": "count",
                "shake_count": 42,
                "shake_duration": 15,
                "shake_intensity": "vigorous",
            ],
        ])
        #expect(mission.type == .shake)
        #expect(mission.shakeMode == .count)
        #expect(mission.shakeCount == 42)
        #expect(mission.shakeDuration == 15)
        #expect(mission.shakeIntensity == .vigorous)
    }

    @Test("Math config maps count and difficulty")
    func mathConfig() {
        let mission = handler.buildMission(from: [
            "mission": "math",
            "mission_config": ["math_count": 7, "math_difficulty": "super_easy"],
        ])
        #expect(mission.type == .math)
        #expect(mission.mathProblemCount == 7)
        #expect(mission.mathDifficulty == .superEasy)
    }

    @Test("Mission names are case-insensitive")
    func caseInsensitiveMissionName() {
        #expect(handler.buildMission(from: ["mission": "MATH"]).type == .math)
        #expect(handler.buildMission(from: ["mission": "Shake"]).type == .shake)
    }

    @Test("A missing mission field yields Tap")
    func missingMissionIsTap() {
        #expect(handler.buildMission(from: [:]).type == .none)
    }

    @Test("home_assistant carries its fallback mission and that mission's own config")
    func homeAssistantFallback() {
        let mission = handler.buildMission(from: [
            "mission": "home_assistant",
            "mission_config": [
                "fallback_mission": "shake",
                "fallback_shake_mode": "count",
                "fallback_shake_count": 25,
            ],
        ])
        #expect(mission.type == .homeAssistant)
        #expect(mission.haFallbackMission == .shake)
        #expect(mission.haFallbackShakeMode == .count)
        #expect(mission.haFallbackShakeCount == 25)
    }

    @Test("An unrecognised fallback mission resolves to none, not the default mission")
    func unknownFallbackIsNone() {
        let mission = handler.buildMission(from: [
            "mission": "home_assistant",
            "mission_config": ["fallback_mission": "not_a_mission"],
        ])
        #expect(mission.haFallbackMission == .none)
    }
}

// MARK: - Value mapping tables

@MainActor
struct MQTTValueMappingTests {

    private var handler: MQTTCommandHandler { .shared }

    @Test("Snooze modes map, and unknown values are rejected rather than defaulted")
    func snoozeModes() {
        #expect(handler.mapSnoozeMode("tap") == SnoozeMode.tap.rawValue)
        #expect(handler.mapSnoozeMode("hold") == SnoozeMode.hold.rawValue)
        #expect(handler.mapSnoozeMode("home_assistant") == SnoozeMode.homeAssistant.rawValue)
        #expect(handler.mapSnoozeMode("disabled") == SnoozeMode.disabled.rawValue)
        #expect(handler.mapSnoozeMode("nonsense") == nil)
    }

    @Test("Skip modes map, and unknown values are rejected")
    func skipModes() {
        #expect(handler.mapSkipMode("tap") == SkipAlarmMode.tap.rawValue)
        #expect(handler.mapSkipMode("hold") == SkipAlarmMode.hold.rawValue)
        #expect(handler.mapSkipMode("disabled") == SkipAlarmMode.disabled.rawValue)
        #expect(handler.mapSkipMode("nonsense") == nil)
    }

    @Test("Shake intensity falls back to medium")
    func shakeIntensity() {
        #expect(handler.mapShakeIntensity("light") == .light)
        #expect(handler.mapShakeIntensity("vigorous") == .vigorous)
        #expect(handler.mapShakeIntensity("anything else") == .medium)
    }

    @Test("Math difficulty falls back to easy")
    func mathDifficulty() {
        #expect(handler.mapMathDifficulty("super_easy") == .superEasy)
        #expect(handler.mapMathDifficulty("medium") == .medium)
        #expect(handler.mapMathDifficulty("hard") == .hard)
        #expect(handler.mapMathDifficulty("anything else") == .easy)
    }

    /// HACS services send 0–100; the app stores 0.0–1.0.
    @Test("Volume normalises percentages and clamps out-of-range values")
    func volumeNormalisation() {
        #expect(handler.normalizeVolume(50) == 0.5)
        #expect(handler.normalizeVolume(100) == 1.0)
        #expect(handler.normalizeVolume(0.75) == 0.75)
        #expect(handler.normalizeVolume(0) == 0.0)
        #expect(handler.normalizeVolume(250) == 1.0, "above 100% clamps")
        #expect(handler.normalizeVolume(-5) == 0.0, "negatives clamp to zero")
    }
}

// MARK: - Alert identity

@MainActor
struct MQTTAlertIDTests {

    @Test("The same alert title always yields the same ID within a run")
    func stableForSameTitle() {
        #expect(
            MQTTCommandHandler.alertAlarmID(title: "Motion Detected")
                == MQTTCommandHandler.alertAlarmID(title: "Motion Detected")
        )
    }

    @Test("Different titles yield different IDs so concurrent alerts don't collide")
    func differsByTitle() {
        #expect(
            MQTTCommandHandler.alertAlarmID(title: "Motion Detected")
                != MQTTCommandHandler.alertAlarmID(title: "Door Opened")
        )
    }
}

// MARK: - After-alarm reconciliation
//
// MQTT never writes the explicit after-alarm ORDER — it mutates the config
// fields and `Alarm.afterAlarmActions` reconciles on read. These tests pin that
// reconciliation, since it is the only thing making MQTT-configured steps show
// up at all.

@MainActor
struct MQTTAfterAlarmReconciliationTests {

    @Test("Setting notes text surfaces the Notes step")
    func notesTextSurfacesStep() {
        let alarm = Alarm(label: "A")
        #expect(!alarm.afterAlarmActions.contains(.notes))

        alarm.alarmScreenNotes = "Take the bins out"

        #expect(alarm.afterAlarmActions.contains(.notes))
    }

    @Test("Clearing notes content drops the Notes step")
    func clearingNotesDropsStep() {
        let alarm = Alarm(label: "A")
        alarm.alarmScreenNotes = "Take the bins out"
        #expect(alarm.afterAlarmActions.contains(.notes))

        alarm.alarmScreenNotes = ""

        #expect(!alarm.afterAlarmActions.contains(.notes), "an empty Notes page must not be shown")
    }

    @Test("A dismiss URI surfaces the App Link step, and it sorts last")
    func appLinkSurfacesAndSortsLast() {
        let alarm = Alarm(label: "A")
        alarm.alarmScreenNotes = "note"
        alarm.dismissAppURI = "shortcuts://run-shortcut?name=Morning"

        let actions = alarm.afterAlarmActions

        #expect(actions.contains(.appLink))
        #expect(actions.last == .appLink, "the terminal open-app step must be last")
    }

    @Test("An empty dismiss URI drops the App Link step")
    func emptyURIDropsAppLink() {
        let alarm = Alarm(label: "A")
        alarm.dismissAppURI = "shortcuts://run"
        #expect(alarm.afterAlarmActions.contains(.appLink))

        alarm.dismissAppURI = ""

        #expect(!alarm.afterAlarmActions.contains(.appLink))
    }

    /// COVERAGE GAP, asserted so it is visible rather than assumed. MQTT has no
    /// field for the Verse of the Day step — `MQTTCommandHandler` never
    /// references it — so Home Assistant cannot enable it. If a `verse` field is
    /// ever added, this test should be replaced with one that sets it.
    @Test("Verse of the Day cannot currently be enabled from MQTT")
    func verseHasNoMQTTPath() {
        let alarm = Alarm(label: "A")
        alarm.alarmScreenNotes = "note"
        alarm.showWeatherAfterAlarm = true
        alarm.dismissAppURI = "shortcuts://run"

        // Every field MQTT can set, and .verse still never appears.
        #expect(!alarm.afterAlarmActions.contains(.verse))
    }
}

// MARK: - HA fallback mission eligibility
//
// Bricks and Meteor were not offered as HA fallbacks: the picker's grid excluded
// them, `ActiveAlarmView`'s fallback switch dropped them into the manual-dismiss
// catch-all, MQTT's `fallback_mission` mapping didn't know the names, and there
// were no fields to hold their difficulty. These pin the MQTT half of that fix.

@MainActor
struct MQTTFallbackMissionTests {

    private var handler: MQTTCommandHandler { .shared }

    @Test("Bricks is accepted as an HA fallback, with its own difficulty")
    func blockDropFallback() {
        let mission = handler.buildMission(from: [
            "mission": "home_assistant",
            "mission_config": [
                "fallback_mission": "block_drop",
                "fallback_block_drop_difficulty": "hard",
            ],
        ])
        #expect(mission.haFallbackMission == .blockDrop)
        #expect(mission.haFallbackBlockDropDifficulty == .hard)
    }

    @Test("Meteor is accepted as an HA fallback, with its own difficulty")
    func meteorFallback() {
        let mission = handler.buildMission(from: [
            "mission": "home_assistant",
            "mission_config": [
                "fallback_mission": "meteor",
                "fallback_meteor_difficulty": "easy",
            ],
        ])
        #expect(mission.haFallbackMission == .meteor)
        #expect(mission.haFallbackMeteorDifficulty == .easy)
    }

    /// The difficulty has to survive into the mission that actually RUNS, which
    /// is what `dismissFallbackMission` builds — the fallback previously always
    /// ran at the type default because there was nowhere to store it.
    @Test("Fallback difficulty reaches the mission that runs")
    func fallbackDifficultyReachesRuntime() {
        let mission = handler.buildMission(from: [
            "mission": "home_assistant",
            "mission_config": [
                "fallback_mission": "block_drop",
                "fallback_block_drop_difficulty": "hard",
            ],
        ])
        let runtime = mission.dismissFallbackMission
        #expect(runtime.type == .blockDrop)
        #expect(runtime.blockDropDifficulty == .hard)
    }

    @Test("Fallback config survives a Codable round-trip")
    func fallbackSurvivesEncoding() throws {
        var mission = Mission(type: .homeAssistant)
        mission.haFallbackMission = .meteor
        mission.haFallbackMeteorDifficulty = .hard

        let data = try JSONEncoder().encode(mission)
        let decoded = try JSONDecoder().decode(Mission.self, from: data)

        #expect(decoded.haFallbackMission == .meteor)
        #expect(decoded.haFallbackMeteorDifficulty == .hard)
    }
}

// MARK: - Fallback parity with primary missions
//
// The rule these enforce: anything settable on a mission when creating an alarm
// in the app must be settable on a FALLBACK over MQTT. Fallback config had grown
// field-by-field and covered only shake, math, and balance difficulty — Tap had
// nothing at all, and Bricks/Meteor had no overrides.

@MainActor
struct MQTTFallbackParityTests {

    private var handler: MQTTCommandHandler { .shared }

    private func haMission(_ config: [String: Any]) -> Mission {
        handler.buildMission(from: ["mission": "home_assistant", "mission_config": config])
    }

    @Test("Tap fallback carries dismiss mode, count and hold duration")
    func tapFallbackConfigurable() {
        let m = haMission([
            "fallback_mission": "none",
            "fallback_tap_dismiss_mode": "tap",
            "fallback_tap_count": 10,
        ])
        #expect(m.haFallbackTapDismissMode == .tap)
        #expect(m.haFallbackTapCount == 10)

        let held = haMission([
            "fallback_mission": "none",
            "fallback_tap_dismiss_mode": "hold",
            "fallback_tap_hold_duration": 5,
        ])
        #expect(held.haFallbackTapDismissMode == .hold)
        #expect(held.haFallbackTapHoldDuration == 5)
    }

    @Test("Tap fallback config reaches the mission that runs")
    func tapFallbackReachesRuntime() {
        let runtime = haMission([
            "fallback_mission": "none",
            "fallback_tap_count": 7,
        ]).dismissFallbackMission
        #expect(runtime.type == .none)
        #expect(runtime.tapCount == 7)
    }

    @Test("Bricks fallback accepts every override its primary form does")
    func blockDropFallbackOverrides() {
        let m = haMission([
            "fallback_mission": "block_drop",
            "fallback_block_drop_lines": 8,
            "fallback_block_drop_drop_interval": 0.4,
            "fallback_block_drop_prefilled_rows": 3,
            "fallback_block_drop_gap_width": 2,
            "fallback_block_drop_gaps_aligned": true,
        ])
        #expect(m.haFallbackBlockDropLinesOverride == 8)
        #expect(m.haFallbackBlockDropIntervalOverride == 0.4)
        #expect(m.haFallbackBlockDropGarbageRowsOverride == 3)
        #expect(m.haFallbackBlockDropGapWidthOverride == 2)
        #expect(m.haFallbackBlockDropGapsAlignedOverride == true)

        let runtime = m.dismissFallbackMission
        #expect(runtime.blockDropLinesOverride == 8)
        #expect(runtime.blockDropGapsAlignedOverride == true)
    }

    @Test("Meteor fallback accepts every override its primary form does")
    func meteorFallbackOverrides() {
        let m = haMission([
            "fallback_mission": "meteor",
            "fallback_meteor_targets": 20,
            "fallback_meteor_fire_interval": 0.5,
        ])
        #expect(m.haFallbackMeteorTargetsOverride == 20)
        #expect(m.haFallbackMeteorFireIntervalOverride == 0.5)

        let runtime = m.dismissFallbackMission
        #expect(runtime.meteorTargetsOverride == 20)
        #expect(runtime.meteorFireIntervalOverride == 0.5)
    }

    /// Fallback overrides clamp to the SAME ranges as their primary counterparts,
    /// so a hostile or fat-fingered automation can't produce an unplayable
    /// fallback that the user then can't dismiss.
    @Test("Fallback overrides clamp to the primary mission's ranges")
    func fallbackOverridesClamp() {
        let m = haMission([
            "fallback_mission": "block_drop",
            "fallback_block_drop_lines": 999,
            "fallback_block_drop_prefilled_rows": -5,
        ])
        #expect(m.haFallbackBlockDropLinesOverride == 12, "lines clamp to 12")
        #expect(m.haFallbackBlockDropGarbageRowsOverride == 0, "rows clamp to 0")

        let meteor = haMission([
            "fallback_mission": "meteor",
            "fallback_meteor_targets": 1,
        ])
        #expect(meteor.haFallbackMeteorTargetsOverride == 3, "targets clamp up to 3")
    }

    @Test("Every fallback field survives a Codable round-trip")
    func fallbackFieldsRoundTrip() throws {
        var mission = Mission(type: .homeAssistant)
        mission.haFallbackMission = .blockDrop
        mission.haFallbackTapCount = 9
        mission.haFallbackBlockDropLinesOverride = 6
        mission.haFallbackMeteorTargetsOverride = 15
        mission.haFallbackBalanceHoldOverride = 4

        let decoded = try JSONDecoder().decode(
            Mission.self, from: try JSONEncoder().encode(mission)
        )

        #expect(decoded.haFallbackTapCount == 9)
        #expect(decoded.haFallbackBlockDropLinesOverride == 6)
        #expect(decoded.haFallbackMeteorTargetsOverride == 15)
        #expect(decoded.haFallbackBalanceHoldOverride == 4)
    }
}

// MARK: - Radio over MQTT
//
// Per Documents/working-notes/PLAN-radio-mqtt.md. `radio_station` on create/update accepts
// three forms; the shared sleep-timer parsing is exercised directly because
// `radio_start` and `sleep_sound_start` must not drift.

@MainActor
struct MQTTRadioTests {

    @Test("An object with a url is stored verbatim, no favourite required")
    func objectFormStored() {
        let alarm = Alarm(label: "Radio")
        MQTTCommandHandler.shared.handleRadioStationForTesting(
            payload: ["radio_station": ["url": "https://stream.example/wdet", "name": "WDET", "uuid": "abc-123"]],
            alarm: alarm
        )
        #expect(alarm.radioStationURL == "https://stream.example/wdet")
        #expect(alarm.radioStationName == "WDET")
        #expect(alarm.radioStationID == "abc-123")
    }

    @Test("uuid and name are optional in the object form")
    func objectFormDefaults() {
        let alarm = Alarm(label: "Radio")
        MQTTCommandHandler.shared.handleRadioStationForTesting(
            payload: ["radio_station": ["url": "https://stream.example/x"]],
            alarm: alarm
        )
        #expect(alarm.radioStationURL == "https://stream.example/x")
        #expect(alarm.radioStationName == "Radio", "falls back to a generic name")
        #expect(alarm.radioStationID == "https://stream.example/x", "falls back to the URL")
    }

    @Test("An empty string clears all three fields")
    func emptyStringClears() {
        let alarm = Alarm(label: "Radio")
        alarm.radioStationID = "abc"
        alarm.radioStationName = "WDET"
        alarm.radioStationURL = "https://stream.example/wdet"

        MQTTCommandHandler.shared.handleRadioStationForTesting(
            payload: ["radio_station": ""], alarm: alarm
        )

        #expect(alarm.radioStationID == nil)
        #expect(alarm.radioStationName == nil)
        #expect(alarm.radioStationURL == nil)
    }

    /// A typo in an automation must not cost you the alarm — the station is left
    /// alone and the alarm is still created/updated.
    @Test("An unmatched favourite name leaves the existing station untouched")
    func unknownNameIsNonFatal() {
        let alarm = Alarm(label: "Radio")
        alarm.radioStationName = "Existing"
        alarm.radioStationURL = "https://stream.example/existing"

        MQTTCommandHandler.shared.handleRadioStationForTesting(
            payload: ["radio_station": "Definitely Not A Favourite"], alarm: alarm
        )

        #expect(alarm.radioStationName == "Existing")
        #expect(alarm.radioStationURL == "https://stream.example/existing")
    }

    @Test("A payload without the key leaves the station alone (partial update)")
    func absentKeyIsNoOp() {
        let alarm = Alarm(label: "Radio")
        alarm.radioStationName = "Existing"

        MQTTCommandHandler.shared.handleRadioStationForTesting(
            payload: ["label": "renamed"], alarm: alarm
        )

        #expect(alarm.radioStationName == "Existing")
    }

    // MARK: Sleep-timer spec, shared with sleep_sound_start

    @Test("duration_minutes yields a stop date, clamped to 12 hours")
    func durationMinutes() throws {
        let spec = MQTTCommandHandler.sleepTimerSpec(from: ["duration_minutes": 30])
        let end = try #require(spec.end)
        let minutes = end.timeIntervalSinceNow / 60
        #expect(minutes > 29 && minutes < 31)

        let clamped = MQTTCommandHandler.sleepTimerSpec(from: ["duration_minutes": 5000])
        let clampedEnd = try #require(clamped.end)
        #expect(clampedEnd.timeIntervalSinceNow / 3600 < 12.1, "clamps to 12 hours")
    }

    @Test("No duration means indefinite")
    func indefinite() {
        #expect(MQTTCommandHandler.sleepTimerSpec(from: [:]).end == nil)
        #expect(MQTTCommandHandler.sleepTimerSpec(from: ["duration_minutes": 0]).end == nil)
    }

    @Test("Fade-out accepts minutes or seconds, seconds winning")
    func fadeOut() {
        #expect(MQTTCommandHandler.sleepTimerSpec(from: ["fade_out_minutes": 2]).fadeOut == 120)
        #expect(MQTTCommandHandler.sleepTimerSpec(from: ["fade_out_seconds": 45]).fadeOut == 45)
        #expect(
            MQTTCommandHandler.sleepTimerSpec(from: ["fade_out_seconds": 10, "fade_out_minutes": 5]).fadeOut == 10,
            "seconds takes precedence over minutes"
        )
        #expect(MQTTCommandHandler.sleepTimerSpec(from: ["fade_out_minutes": -3]).fadeOut == 0, "negatives clamp")
    }
}

// MARK: - After-alarm actions over MQTT
//
// `after_alarm_actions` is ADDITIVE. The steps have always been inferred from
// config fields (`notes`, `morning_weather`, `dismissAppURI`) by
// `Alarm.afterAlarmActions`, and automations written before this field existed
// rely on that. The regression tests below are the ones that matter: a payload
// that doesn't mention the array must behave exactly as it did.

@MainActor
struct MQTTAfterAlarmActionsTests {

    private func apply(_ payload: [String: Any], to alarm: Alarm) {
        MQTTCommandHandler.shared.handleAfterAlarmActionsForTesting(payload: payload, alarm: alarm)
    }

    // ── Backwards compatibility ──────────────────────────────────────────

    /// THE regression test. An automation from before this field existed sends
    /// only `notes`; it must still produce a Notes step.
    @Test("A payload without the array leaves inferred steps working")
    func absentArrayPreservesInference() {
        let alarm = Alarm(label: "Legacy")
        alarm.alarmScreenNotes = "Bins out"

        apply(["notes": "Bins out"], to: alarm)

        #expect(alarm.afterAlarmActions.contains(.notes),
                "an automation that only sets notes must still get a Notes step")
    }

    @Test("A payload without the array leaves an inferred weather step working")
    func absentArrayPreservesWeather() {
        let alarm = Alarm(label: "Legacy")
        alarm.showWeatherAfterAlarm = true

        apply(["morning_weather": true], to: alarm)

        #expect(alarm.afterAlarmActions.contains(.weather))
    }

    /// Read-time reconciliation WINS over an explicit order for the actions that
    /// have config fields. Omitting `.notes` while notes text exists does not
    /// hide the step — the getter re-appends it. That is the same rule keeping
    /// config-only automations alive, so it applies here too; the way to remove
    /// the step is to clear the text.
    @Test("Omitting notes does not hide it while the text is still set")
    func omittingNotesDoesNotHideItWhileTextRemains() {
        let alarm = Alarm(label: "A")
        alarm.alarmScreenNotes = "Keep me"

        apply(["after_alarm_actions": ["weather"]], to: alarm)

        #expect(alarm.afterAlarmActions.contains(.notes),
                "reconciliation re-appends Notes because the text is still there")
        #expect(alarm.alarmScreenNotes == "Keep me")
    }

    @Test("Clearing the text is what removes the Notes step")
    func clearingTextRemovesNotesStep() {
        let alarm = Alarm(label: "A")
        alarm.alarmScreenNotes = "Bins out"
        #expect(alarm.afterAlarmActions.contains(.notes))

        alarm.alarmScreenNotes = ""
        apply(["after_alarm_actions": ["weather"]], to: alarm)

        #expect(!alarm.afterAlarmActions.contains(.notes))
    }

    // ── The new capability ───────────────────────────────────────────────

    /// Verse is the reason this field exists: it has no config field of its
    /// own, so before this there was no way to enable it from Home Assistant.
    @Test("Verse can finally be enabled from MQTT")
    func verseEnabled() {
        let alarm = Alarm(label: "A")
        #expect(!alarm.afterAlarmActions.contains(.verse))

        apply(["after_alarm_actions": ["verse"]], to: alarm)

        #expect(alarm.afterAlarmActions.contains(.verse))
    }

    @Test("The order is honoured")
    func orderHonoured() {
        let alarm = Alarm(label: "A")
        alarm.alarmScreenNotes = "note"

        apply(["after_alarm_actions": ["weather", "verse", "notes"]], to: alarm)

        #expect(alarm.afterAlarmActions == [.weather, .verse, .notes])
    }

    /// The open-app step leaves Allarise, so nothing can follow it — the app's
    /// editor enforces this and MQTT must not be able to bypass it.
    @Test("appLink is forced last however it is ordered")
    func appLinkForcedLast() {
        let alarm = Alarm(label: "A")
        alarm.dismissAppURI = "shortcuts://run"
        alarm.alarmScreenNotes = "note"

        apply(["after_alarm_actions": ["appLink", "notes", "verse"]], to: alarm)

        #expect(alarm.afterAlarmActions.last == .appLink)
    }

    @Test("snake_case ids are accepted alongside the raw ids")
    func snakeCaseAccepted() {
        let alarm = Alarm(label: "A")
        alarm.dismissAppURI = "shortcuts://run"

        apply(["after_alarm_actions": ["app_link"]], to: alarm)

        #expect(alarm.afterAlarmActions.contains(.appLink))
    }

    @Test("Unknown ids are dropped, not fatal")
    func unknownIdsDropped() {
        let alarm = Alarm(label: "A")
        apply(["after_alarm_actions": ["verse", "teleportation"]], to: alarm)
        #expect(alarm.afterAlarmActions == [.verse])
    }

    /// An empty array clears the explicit order, but config-backed actions are
    /// still re-derived. Only the actions with nothing to reconcile against —
    /// verse, weather — actually disappear.
    @Test("An empty array clears the order but not config-backed steps")
    func emptyArrayClearsOrderNotConfig() {
        let alarm = Alarm(label: "A")
        alarm.alarmScreenNotes = "note"
        apply(["after_alarm_actions": ["verse", "notes"]], to: alarm)
        #expect(alarm.afterAlarmActions.contains(.verse))

        apply(["after_alarm_actions": []], to: alarm)

        #expect(!alarm.afterAlarmActions.contains(.verse), "verse has no config to fall back on")
        #expect(alarm.afterAlarmActions.contains(.notes), "notes text still reconciles back in")
    }

    @Test("Duplicates collapse")
    func duplicatesCollapse() {
        let alarm = Alarm(label: "A")
        apply(["after_alarm_actions": ["verse", "verse"]], to: alarm)
        #expect(alarm.afterAlarmActions == [.verse])
    }
}

// MARK: - applyFadeIn: reaching the app's "30 sec" position over MQTT

@MainActor
struct MQTTFadeInTests {

    private var handler: MQTTCommandHandler { .shared }

    @Test("Minutes turn fade-in on and clamp at 15")
    func minutesClamp() {
        let alarm = Alarm(label: "A")

        #expect(handler.applyFadeIn(payload: ["fade_in_duration": 5], to: alarm))
        #expect(alarm.customFadeInEnabled == true)
        #expect(alarm.customFadeInDuration == 5)

        handler.applyFadeIn(payload: ["fade_in_duration": 99], to: alarm)
        #expect(alarm.customFadeInDuration == 15)
    }

    /// The pre-existing contract. Automations already in the field send 0 to
    /// mean "off", and that must keep meaning off.
    @Test("A bare 0 still means off")
    func zeroMeansOff() {
        let alarm = Alarm(label: "A")
        handler.applyFadeIn(payload: ["fade_in_duration": 3], to: alarm)

        handler.applyFadeIn(payload: ["fade_in_duration": 0], to: alarm)

        #expect(alarm.customFadeInEnabled == false)
        #expect(alarm.customFadeInDuration == nil)
    }

    /// The gap this closes: the app's picker runs 0…15 where 0 is a 30-second
    /// fade, so 30 seconds was previously unreachable over MQTT.
    @Test("0 with `fade_in: true` is the 30-second position")
    func zeroWithFlagIsThirtySeconds() {
        let alarm = Alarm(label: "A")

        handler.applyFadeIn(payload: ["fade_in_duration": 0, "fade_in": true], to: alarm)

        #expect(alarm.customFadeInEnabled == true)
        #expect(alarm.customFadeInDuration == 0, "0 minutes is the app's 30-second fade")
    }

    @Test("`fade_in` alone toggles without touching the duration")
    func flagAloneKeepsDuration() {
        let alarm = Alarm(label: "A")
        handler.applyFadeIn(payload: ["fade_in_duration": 7], to: alarm)

        handler.applyFadeIn(payload: ["fade_in": false], to: alarm)
        #expect(alarm.customFadeInEnabled == false)

        handler.applyFadeIn(payload: ["fade_in": true], to: alarm)
        #expect(alarm.customFadeInEnabled == true)
    }

    /// `fade_in: true` explicitly wins over a 0 duration, but a *false* flag
    /// must not resurrect a fade the duration just switched off.
    @Test("A false flag alongside 0 stays off")
    func falseFlagWithZeroStaysOff() {
        let alarm = Alarm(label: "A")
        handler.applyFadeIn(payload: ["fade_in_duration": 0, "fade_in": false], to: alarm)
        #expect(alarm.customFadeInEnabled == false)
    }

    @Test("Neither key present is a no-op")
    func absentKeysAreNoOp() {
        let alarm = Alarm(label: "A")
        handler.applyFadeIn(payload: ["fade_in_duration": 4], to: alarm)

        #expect(!handler.applyFadeIn(payload: ["label": "x"], to: alarm))
        #expect(alarm.customFadeInEnabled == true)
        #expect(alarm.customFadeInDuration == 4)
    }
}

// MARK: - After-alarm single-step toggles (`verse_of_day`, `morning_weather`)
//
// The array form (`after_alarm_actions`) is tested above. These cover the
// boolean form, and the two properties that matter most:
//
//   • ABSENT = UNCHANGED, in both directions. An automation that never heard of
//     `verse_of_day` must be untouched by it, and an older app receiving the key
//     ignores it silently — the app-side equivalent is that an absent key never
//     writes anything.
//   • `morning_weather` on an explicitly-ordered alarm is no longer a silent
//     no-op. That was a real hole: the editor writes an explicit order, and the
//     read path reconciles `.notes` and `.appLink` against their config fields
//     but never `.weather`, so the flag was set and nothing read it.

@MainActor
struct MQTTAfterAlarmTogglesTests {

    private func apply(_ payload: [String: Any], to alarm: Alarm) {
        MQTTCommandHandler.shared.handleAfterAlarmTogglesForTesting(payload: payload, alarm: alarm)
    }

    // ── Verse ────────────────────────────────────────────────────────────

    @Test("`verse_of_day: true` adds the verse step")
    func verseToggleOn() {
        let alarm = Alarm(label: "A")
        apply(["verse_of_day": true], to: alarm)
        #expect(alarm.afterAlarmActions.contains(.verse))
    }

    @Test("`verse_of_day: false` removes it again")
    func verseToggleOff() {
        let alarm = Alarm(label: "A")
        apply(["verse_of_day": true], to: alarm)
        apply(["verse_of_day": false], to: alarm)
        #expect(!alarm.afterAlarmActions.contains(.verse))
    }

    @Test("`verse` is accepted as an alias")
    func verseAlias() {
        let alarm = Alarm(label: "A")
        apply(["verse": true], to: alarm)
        #expect(alarm.afterAlarmActions.contains(.verse))
    }

    /// THE regression test for this feature: a payload that says nothing about
    /// verse must not write an order, or every config-only automation would
    /// silently switch its alarms from derived to explicit behaviour.
    @Test("An absent toggle writes nothing at all")
    func absentToggleWritesNothing() {
        let alarm = Alarm(label: "A")
        alarm.showWeatherAfterAlarm = true

        apply(["label": "unrelated"], to: alarm)

        #expect(alarm.afterAlarmOrderData == nil,
                "no toggle means no explicit order is created")
        #expect(alarm.afterAlarmActions == [.weather],
                "the derived list still governs")
    }

    /// Enabling verse carries the already-derived steps across rather than
    /// replacing them — the alarm keeps everything it had.
    @Test("Enabling verse preserves the steps the alarm already had")
    func versePreservesDerivedSteps() {
        let alarm = Alarm(label: "A")
        alarm.showWeatherAfterAlarm = true
        alarm.alarmScreenNotes = "Bins out"
        alarm.dismissAppURI = "shortcuts://run-shortcut?name=X"

        apply(["verse_of_day": true], to: alarm)

        let actions = alarm.afterAlarmActions
        #expect(actions.contains(.notes))
        #expect(actions.contains(.weather))
        #expect(actions.contains(.verse))
        #expect(actions.last == .appLink, "the app-link step stays terminal")
    }

    // ── Weather ──────────────────────────────────────────────────────────

    /// The bug this closes. An alarm with an explicit order ignored
    /// `morning_weather` entirely.
    @Test("`morning_weather` reaches an explicitly-ordered alarm")
    func weatherReachesExplicitlyOrderedAlarm() {
        let alarm = Alarm(label: "A")
        alarm.afterAlarmActions = [.verse]          // an explicit order, no weather

        apply(["morning_weather": true], to: alarm)

        #expect(alarm.afterAlarmActions.contains(.weather),
                "the flag must not be a silent no-op on an ordered alarm")
        #expect(alarm.afterAlarmActions.contains(.verse), "and must not clobber the rest")
    }

    @Test("`morning_weather: false` removes the step from an explicit order")
    func weatherOffRemovesStep() {
        let alarm = Alarm(label: "A")
        alarm.afterAlarmActions = [.weather, .verse]

        apply(["morning_weather": false], to: alarm)

        #expect(!alarm.afterAlarmActions.contains(.weather))
        #expect(alarm.afterAlarmActions.contains(.verse))
    }

    /// Unchanged behaviour for the legacy path: with no explicit order, the flag
    /// alone still drives the step and no order is written.
    @Test("`morning_weather` on a derived alarm behaves exactly as before")
    func weatherOnDerivedAlarmUnchanged() {
        let alarm = Alarm(label: "A")

        apply(["morning_weather": true], to: alarm)

        #expect(alarm.showWeatherAfterAlarm)
        #expect(alarm.afterAlarmActions.contains(.weather))
        #expect(alarm.afterAlarmOrderData == nil, "still derived, not explicit")
    }

    // ── Interaction with the array ───────────────────────────────────────

    /// Both in one payload: the array sets the order, the toggle then adjusts
    /// that one step. The more specific instruction wins.
    @Test("A toggle sent with the array adjusts that one step")
    func toggleWinsOverArrayForItsOwnStep() {
        let alarm = Alarm(label: "A")

        apply(["after_alarm_actions": ["weather"], "verse_of_day": true], to: alarm)

        #expect(alarm.afterAlarmActions.contains(.weather), "the array is honoured")
        #expect(alarm.afterAlarmActions.contains(.verse), "the toggle is honoured too")
    }

    @Test("A repeated toggle is idempotent")
    func repeatedToggleIsIdempotent() {
        let alarm = Alarm(label: "A")
        apply(["verse_of_day": true], to: alarm)
        let first = alarm.afterAlarmOrderData

        apply(["verse_of_day": true], to: alarm)

        #expect(alarm.afterAlarmOrderData == first)
    }
}

// MARK: - Alarm sound resolution
//
// `sound` failing to resolve is SILENT — create_alarm falls back to the default
// tone and publishes no error — so the resolver's tolerance is the only thing
// standing between a typo and the user waking up to the wrong sound. The
// dropdown the app now publishes (`sensor/alarm_sounds_available`) is built from
// the same handles these tests assert on.

@MainActor
struct AlarmSoundResolutionTests {

    /// Exact ids are the contract every existing automation is written against.
    @Test("A bundled tone resolves by its exact id")
    func exactIDResolves() {
        let manager = AlarmSoundManager.shared
        guard let first = manager.getAllSounds().first(where: { !$0.id.hasPrefix("custom_") }) else { return }

        #expect(manager.getSound(id: first.id)?.id == first.id)
    }

    /// The added tolerance: display-name spacing and case. `Alarm_Clock`,
    /// `alarm clock` and `Alarm Clock` must all land on the same tone.
    @Test("A bundled tone resolves by display name and by case-folded spacing")
    func tolerantMatchResolves() {
        let manager = AlarmSoundManager.shared
        guard let first = manager.getAllSounds().first(where: { !$0.id.hasPrefix("custom_") }) else { return }

        #expect(manager.getSound(id: first.displayName)?.id == first.id)
        #expect(manager.getSound(id: first.displayName.lowercased())?.id == first.id)
        #expect(manager.getSound(id: "  \(first.displayName)  ")?.id == first.id)
    }

    @Test("An unknown name still resolves to nothing")
    func unknownResolvesToNil() {
        #expect(AlarmSoundManager.shared.getSound(id: "definitely not a tone ✳︎") == nil)
    }
}

// MARK: - Dismiss state vocabulary
//
// The four state strings are a published contract: every automation is written
// against `alarm/<n>/state` going to one of them, and `al-d44` is the standing
// reminder that a silent mismatch is worse than a rejection. al-bee.1 made the
// per-alarm dismiss publish unconditional (it used to be skipped whenever a
// second alarm was stacked behind the one being dismissed, leaving Home
// Assistant on `ringing` forever) — these pin that it still publishes plain
// `dismissed` and that the vocabulary did not grow a fifth value.

struct AlarmStateVocabularyTests {

    @Test("A dismissed alarm reports plain `dismissed`")
    func dismissPublishesDismissed() {
        #expect(AlarmDismissResolution.perAlarmDismissState.rawValue == "dismissed")
    }

    @Test("A dismissed alarm publishes on its OWN index, whatever the queue looks like")
    func perAlarmPublishIsUnconditionalForAnIndexedAlarm() {
        for queued in [true, false] {
            let outcome = AlarmDismissResolution.resolve(
                alarmIndex: 7, hasQueuedAlarms: queued, hasAfterAlarmSteps: true
            )
            #expect(outcome.publishesPerAlarmDismissed,
                    "alarm 7 must reach `dismissed` on alarm/7/state even with another alarm queued")
        }
    }

    @Test("The state vocabulary is still exactly the four published values")
    func vocabularyUnchanged() {
        #expect(AlarmState.idle.rawValue == "idle")
        #expect(AlarmState.ringing.rawValue == "ringing")
        #expect(AlarmState.snoozed.rawValue == "snoozed")
        #expect(AlarmState.dismissed.rawValue == "dismissed")
        #expect(AlarmState(rawValue: "collapsed") == nil,
                "a new state string would be silently missed by every existing automation")
    }
}
