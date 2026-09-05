//
//  MQTTAppPersistenceTests.swift
//  HaWake Alarm V2Tests
//
//  `app_persistence` is the first SETTING Home Assistant can write, and the one
//  where getting the parse wrong is most expensive: an unrecognised value that
//  resolved to `false` would switch persistence off, and once the app is
//  suspended nothing can switch it back on remotely. So the contract these pin
//  down is narrow on purpose — every spelling an automation plausibly produces
//  means what it looks like, and everything else means nothing at all.
//
//  Same layer as MQTTPayloadTests: pure payload → value translation, no broker,
//  no ModelContainer, no side effects. The side effects (writing
//  DeviceSettings, starting/stopping the keep-alive player, republishing the
//  state topic) are deliberately NOT exercised here — they touch the shared
//  singleton and would leave the user's real persistence setting flipped.
//
//  Reference: Documents/15-INBOUND-COMMANDS-REFERENCE.md → "App Persistence"
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

@MainActor
struct MQTTAppPersistenceParsingTests {

    // MARK: - The shapes that must mean ON

    @Test("A JSON bool parses")
    func jsonBool() {
        #expect(MQTTCommandHandler.parseOnOff(true) == true)
        #expect(MQTTCommandHandler.parseOnOff(false) == false)
    }

    /// What a Home Assistant switch entity publishes on the command topic.
    @Test("HA's own ON/OFF payload parses, in any case")
    func haSwitchPayload() {
        #expect(MQTTCommandHandler.parseOnOff("ON") == true)
        #expect(MQTTCommandHandler.parseOnOff("OFF") == false)
        #expect(MQTTCommandHandler.parseOnOff("on") == true)
        #expect(MQTTCommandHandler.parseOnOff("Off") == false)
    }

    /// A template that stringifies a bool gives Python's spelling; YAML's bare
    /// `on:` becomes `true`. Both are routine in automations.
    @Test("Stringified booleans parse in both spellings")
    func stringifiedBooleans() {
        #expect(MQTTCommandHandler.parseOnOff("true") == true)
        #expect(MQTTCommandHandler.parseOnOff("True") == true)
        #expect(MQTTCommandHandler.parseOnOff("false") == false)
        #expect(MQTTCommandHandler.parseOnOff("False") == false)
    }

    @Test("Numeric strings and JSON numbers parse")
    func numbers() {
        #expect(MQTTCommandHandler.parseOnOff("1") == true)
        #expect(MQTTCommandHandler.parseOnOff("0") == false)
        #expect(MQTTCommandHandler.parseOnOff(1) == true)
        #expect(MQTTCommandHandler.parseOnOff(0) == false)
    }

    @Test("The remaining obvious synonyms parse")
    func synonyms() {
        #expect(MQTTCommandHandler.parseOnOff("yes") == true)
        #expect(MQTTCommandHandler.parseOnOff("no") == false)
        #expect(MQTTCommandHandler.parseOnOff("enable") == true)
        #expect(MQTTCommandHandler.parseOnOff("disabled") == false)
    }

    /// Values arrive off a broker, out of a text box, or via a template that
    /// appended a newline. Trimming is what stops `" ON\n"` being a silent
    /// no-op that nobody can explain.
    @Test("Surrounding whitespace and newlines are trimmed")
    func whitespaceTrimmed() {
        #expect(MQTTCommandHandler.parseOnOff("  ON  ") == true)
        #expect(MQTTCommandHandler.parseOnOff("off\n") == false)
        #expect(MQTTCommandHandler.parseOnOff("\ttrue ") == true)
    }

    // MARK: - The shapes that must mean NOTHING

    /// The important half. Anything unrecognised has to be nil so the caller
    /// ignores it — resolving garbage to `false` would switch persistence OFF,
    /// and that is the one direction the phone cannot recover from remotely.
    @Test("Garbage is nil, never false")
    func garbageIsNil() {
        #expect(MQTTCommandHandler.parseOnOff("maybe") == nil)
        #expect(MQTTCommandHandler.parseOnOff("") == nil)
        #expect(MQTTCommandHandler.parseOnOff("   ") == nil)
        #expect(MQTTCommandHandler.parseOnOff("{}") == nil)
        #expect(MQTTCommandHandler.parseOnOff("toggle") == nil)
        #expect(MQTTCommandHandler.parseOnOff(nil) == nil)
    }

    @Test("A number that is not 0 or 1 is nil")
    func nonBooleanNumberIsNil() {
        #expect(MQTTCommandHandler.parseOnOff(2) == nil)
        #expect(MQTTCommandHandler.parseOnOff(-1) == nil)
        #expect(MQTTCommandHandler.parseOnOff("2") == nil)
    }

    @Test("Structured values are nil rather than truthy")
    func structuredValuesAreNil() {
        #expect(MQTTCommandHandler.parseOnOff(["enabled": true]) == nil)
        #expect(MQTTCommandHandler.parseOnOff(["on"]) == nil)
    }

    // MARK: - Payload round-trip through the real parser

    /// The bare payload path: `MQTTManager` tries `parseOnOff` on the raw string
    /// BEFORE attempting JSON, which is what lets a HA switch's `ON` work at all
    /// — `ON` is not valid JSON and would otherwise be rejected outright.
    @Test("A bare switch payload is not valid JSON, which is why it is parsed first")
    func bareSwitchPayloadIsNotJSON() {
        #expect(MQTTManager.parseCommandPayload("ON") == nil)
        #expect(MQTTCommandHandler.parseOnOff("ON") == true)
    }

    /// The JSON path: every key spelling the handler tries, checked through the
    /// real payload parser so the test exercises the same string a broker sends.
    @Test("Every accepted key spelling resolves out of a real JSON payload")
    func keySpellingsResolve() throws {
        let cases: [(String, Bool)] = [
            (#"{"enabled": true}"#, true),
            (#"{"state": "OFF"}"#, false),
            (#"{"value": 1}"#, true),
            (#"{"app_persistence": "off"}"#, false),
            (#"{"persistence": "yes"}"#, true),
        ]
        for (json, expected) in cases {
            let payload = try #require(MQTTManager.parseCommandPayload(json), "\(json) should parse")
            let resolved = ["enabled", "state", "value", "app_persistence", "persistence"]
                .compactMap { MQTTCommandHandler.parseOnOff(payload[$0]) }
                .first
            #expect(resolved == expected, "\(json)")
        }
    }

    /// Python-literal payloads reach the same place — HA templates that render a
    /// dict rather than JSON are a real source of inbound messages, and the
    /// parser's fallback already handles them.
    @Test("A Python-literal payload still yields a usable value")
    func pythonLiteralPayload() throws {
        let payload = try #require(MQTTManager.parseCommandPayload(#"{"enabled": True}"#))
        #expect(MQTTCommandHandler.parseOnOff(payload["enabled"]) == true)
    }

    /// An empty payload — what a dashboard button with no body sends — must not
    /// resolve to anything. `MQTTManager` substitutes `{}` for an empty payload,
    /// and `{}` carrying no recognised key means "ignore", not "turn off".
    @Test("An empty payload resolves to nothing")
    func emptyPayloadResolvesToNothing() throws {
        let payload = try #require(MQTTManager.parseCommandPayload("{}"))
        let resolved = ["enabled", "state", "value", "app_persistence", "persistence"]
            .compactMap { MQTTCommandHandler.parseOnOff(payload[$0]) }
            .first
        #expect(resolved == nil)
    }

    /// Key precedence is fixed so a payload carrying two of them is not a coin
    /// toss between app builds.
    @Test("`enabled` wins over the later spellings")
    func keyPrecedence() throws {
        let payload = try #require(
            MQTTManager.parseCommandPayload(#"{"enabled": true, "state": "off"}"#)
        )
        let resolved = ["enabled", "state", "value", "app_persistence", "persistence"]
            .compactMap { MQTTCommandHandler.parseOnOff(payload[$0]) }
            .first
        #expect(resolved == true)
    }
}

/// The three-way extension. `parseAppPersistenceMode` is what both inbound
/// paths now call, so these tests carry two obligations: that `DYNAMIC` is
/// understood in every shape `ON` already was, and — the more important half —
/// that nothing which used to mean on, off, or nothing means anything
/// different now.
///
/// Same layer as the suite above: pure payload → value, no broker, no
/// singleton writes.
@MainActor
struct MQTTAppPersistenceModeParsingTests {

    /// The keys the JSON handler tries, in its order. Duplicated here rather
    /// than exposed from the handler so a silent reordering shows up as a test
    /// failure instead of being absorbed.
    private static let keys = ["enabled", "state", "value", "app_persistence", "persistence"]

    private func resolveJSON(_ json: String) throws -> AppPersistenceMode? {
        let payload = try #require(MQTTManager.parseCommandPayload(json), "\(json) should parse")
        return Self.keys
            .compactMap { MQTTCommandHandler.parseAppPersistenceMode(payload[$0]) }
            .first
    }

    // MARK: - The new word

    @Test("A bare DYNAMIC payload parses, in any case")
    func bareDynamic() {
        #expect(MQTTCommandHandler.parseAppPersistenceMode("DYNAMIC") == .dynamic)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("dynamic") == .dynamic)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("Dynamic") == .dynamic)
    }

    /// Trimmed like every other spelling — a template that appended a newline
    /// must not silently do nothing.
    @Test("Whitespace around DYNAMIC is trimmed")
    func dynamicWhitespace() {
        #expect(MQTTCommandHandler.parseAppPersistenceMode("  DYNAMIC  ") == .dynamic)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("dynamic\n") == .dynamic)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("\tDynamic ") == .dynamic)
    }

    /// A bare `DYNAMIC` is no more valid JSON than a bare `ON`, which is why
    /// both are parsed off the raw string before JSON is attempted.
    @Test("A bare DYNAMIC payload is not valid JSON")
    func bareDynamicIsNotJSON() {
        #expect(MQTTManager.parseCommandPayload("DYNAMIC") == nil)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("DYNAMIC") == .dynamic)
    }

    @Test("DYNAMIC resolves out of every JSON key spelling ON uses")
    func dynamicThroughEveryKey() throws {
        let cases = [
            #"{"enabled": "DYNAMIC"}"#,
            #"{"state": "dynamic"}"#,
            #"{"value": "Dynamic"}"#,
            #"{"app_persistence": "  dynamic "}"#,
            #"{"persistence": "DYNAMIC"}"#,
        ]
        for json in cases {
            #expect(try resolveJSON(json) == .dynamic, "\(json)")
        }
    }

    // MARK: - Nothing that worked before changed

    @Test("ON/OFF still resolve, through the mode-level parse")
    func onOffUnchanged() {
        #expect(MQTTCommandHandler.parseAppPersistenceMode("ON") == .on)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("OFF") == .off)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("on") == .on)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("Off") == .off)
        #expect(MQTTCommandHandler.parseAppPersistenceMode(true) == .on)
        #expect(MQTTCommandHandler.parseAppPersistenceMode(false) == .off)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("True") == .on)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("false") == .off)
        #expect(MQTTCommandHandler.parseAppPersistenceMode(1) == .on)
        #expect(MQTTCommandHandler.parseAppPersistenceMode(0) == .off)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("yes") == .on)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("disabled") == .off)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("  ON  ") == .on)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("off\n") == .off)
    }

    /// Every spelling agrees with `parseOnOff`, exhaustively — the mode parse
    /// is a wrapper, and this is what proves it stayed one.
    @Test("The on/off contract is delegated, not reimplemented")
    func delegatesToParseOnOff() {
        let raws: [Any] = [
            true, false, 0, 1, 2, -1,
            "ON", "OFF", "on", "off", "Off", "true", "True", "false", "False",
            "1", "0", "2", "yes", "no", "y", "n",
            "enable", "enabled", "disable", "disabled",
            "  ON  ", "off\n", "\ttrue ", "maybe", "", "   ", "{}", "toggle",
        ]
        for raw in raws {
            let expected = MQTTCommandHandler.parseOnOff(raw).map { $0 ? AppPersistenceMode.on : .off }
            #expect(MQTTCommandHandler.parseAppPersistenceMode(raw) == expected, "\(raw)")
        }
    }

    // MARK: - The shapes that must still mean NOTHING

    /// Unchanged in the direction that matters: garbage stays nil, so a bad
    /// payload is ignored rather than resolving to `.off` and suspending an app
    /// that then cannot be told to come back.
    @Test("Garbage is still nil, never .off")
    func garbageIsStillNil() {
        #expect(MQTTCommandHandler.parseAppPersistenceMode("maybe") == nil)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("") == nil)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("   ") == nil)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("{}") == nil)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("toggle") == nil)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("auto") == nil)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("dyn") == nil)
        #expect(MQTTCommandHandler.parseAppPersistenceMode("dynamic mode") == nil)
        #expect(MQTTCommandHandler.parseAppPersistenceMode(nil) == nil)
        #expect(MQTTCommandHandler.parseAppPersistenceMode(2) == nil)
        #expect(MQTTCommandHandler.parseAppPersistenceMode(["enabled": true]) == nil)
        #expect(MQTTCommandHandler.parseAppPersistenceMode(["dynamic"]) == nil)
    }

    @Test("An empty payload still resolves to nothing")
    func emptyPayloadResolvesToNothing() throws {
        #expect(try resolveJSON("{}") == nil)
    }

    @Test("Existing JSON key spellings keep their exact meaning")
    func jsonKeySpellingsUnchanged() throws {
        #expect(try resolveJSON(#"{"enabled": true}"#) == .on)
        #expect(try resolveJSON(#"{"state": "OFF"}"#) == .off)
        #expect(try resolveJSON(#"{"value": 1}"#) == .on)
        #expect(try resolveJSON(#"{"app_persistence": "off"}"#) == .off)
        #expect(try resolveJSON(#"{"persistence": "yes"}"#) == .on)
        #expect(try resolveJSON(#"{"enabled": True}"#) == .on)
    }

    @Test("Key precedence is unchanged, including against a dynamic value")
    func keyPrecedenceUnchanged() throws {
        #expect(try resolveJSON(#"{"enabled": true, "state": "off"}"#) == .on)
        #expect(try resolveJSON(#"{"enabled": "dynamic", "state": "off"}"#) == .dynamic)
        #expect(try resolveJSON(#"{"enabled": "off", "state": "dynamic"}"#) == .off)
    }

    /// The raw values are the MQTT payload for the new state topic and the
    /// persisted UserDefaults value, so they are contract, not cosmetics.
    @Test("Mode raw values are the published payloads")
    func rawValuesAreContract() {
        #expect(AppPersistenceMode.on.rawValue == "on")
        #expect(AppPersistenceMode.off.rawValue == "off")
        #expect(AppPersistenceMode.dynamic.rawValue == "dynamic")
    }
}
