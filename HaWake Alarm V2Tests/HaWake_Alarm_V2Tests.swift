//
//  HaWake_Alarm_V2Tests.swift
//  HaWake Alarm V2Tests
//
//  Created by Bryan on 3/8/26.
//

import Testing
import Foundation
import SwiftData
@testable import HaWake_Alarm_V2

struct HaWake_Alarm_V2Tests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}

// MARK: - Command source derivation

struct CommandSourceKindTests {

    @Test func homeAssistantWhenNoURL() {
        let command = MQTTCommand(name: "Arm")
        #expect(command.sourceKind == .homeAssistant)
        #expect(command.sourceKind.isURL == false)
    }

    @Test func shortcutWhenShortcutsScheme() {
        var command = MQTTCommand(name: "Good Morning")
        command.actionURL = "shortcuts://run-shortcut?name=Good%20Morning"
        #expect(command.sourceKind == .shortcut)
        #expect(command.sourceKind.isURL)
    }

    @Test func linkForOtherURLs() {
        var web = MQTTCommand(name: "Dashboard")
        web.actionURL = "https://home.example.com"
        #expect(web.sourceKind == .link)

        var tel = MQTTCommand(name: "Call")
        tel.actionURL = "tel:5551234"
        #expect(tel.sourceKind == .link)
    }

    @Test func linkPresentsAsShortcut() {
        // The case stays distinct (the derivation differs), but the UI only ever
        // offers two kinds of command, so `.link` wears the shortcut label and
        // glyph rather than leaking a third word into badges.
        #expect(CommandSourceKind.link.label == "Shortcut")
        #expect(CommandSourceKind.link.glyph == CommandSourceKind.shortcut.glyph)
        #expect(CommandSourceKind.homeAssistant.label == "Home Assistant")
    }

    @Test func blankOrWhitespaceURLIsHomeAssistant() {
        // resolvedActionURL trims; an all-whitespace URL means "no URL".
        var command = MQTTCommand(name: "Edge")
        command.actionURL = "   "
        #expect(command.sourceKind == .homeAssistant)
    }

    @Test func displayNameNeverBlank() {
        #expect(MQTTCommand(name: "   ").displayName == "Untitled")
        #expect(MQTTCommand(name: "Coffee").displayName == "Coffee")
    }
}

// MARK: - Picker search / filter

struct CommandPickerFilterTests {

    private func sample() -> [MQTTCommand] {
        var shortcut = MQTTCommand(name: "Good Morning")
        shortcut.actionURL = "shortcuts://run-shortcut?name=Good%20Morning"
        var link = MQTTCommand(name: "Dashboard")
        link.actionURL = "https://home.example.com"
        return [MQTTCommand(name: "Start Coffee"), shortcut, link]
    }

    @Test func noSearchAllFilterReturnsEverything() {
        let result = CommandPickerSheet.filtered(sample(), search: "", matching: { _ in true })
        #expect(result.count == 3)
    }

    @Test func searchMatchesName() {
        let result = CommandPickerSheet.filtered(sample(), search: "coffee", matching: { _ in true })
        #expect(result.map(\.name) == ["Start Coffee"])
    }

    @Test func searchMatchesSourceLabel() {
        // "shortcut" matches every URL-backed command's derived source label.
        // `.link` presents AS "Shortcut" (the UI only offers two kinds), so a
        // plain web link is found by that search too — the Home Assistant
        // command still isn't.
        let result = CommandPickerSheet.filtered(sample(), search: "shortcut", matching: { _ in true })
        #expect(result.map(\.name) == ["Good Morning", "Dashboard"])
    }

    @Test func searchOverridesTypeTabsOnlyWhenNonEmpty() {
        #expect(CommandPickerSheet.searchOverridesTypeTabs("") == false)
        #expect(CommandPickerSheet.searchOverridesTypeTabs("   ") == false)
        #expect(CommandPickerSheet.searchOverridesTypeTabs("coffee"))
    }

    @Test func searchSpansBothTypeTabs() {
        // With the Home Assistant tab active, searching still has to reach a
        // Shortcut command — otherwise you'd need to know a command's type
        // before you could find it by name.
        let spanning: (MQTTCommand) -> Bool = { _ in true }
        let result = CommandPickerSheet.filtered(sample(), search: "morning", matching: spanning)
        #expect(result.map(\.name) == ["Good Morning"])

        // Same needle, scoped the old way, finds nothing — this is the bug the
        // spanning matcher fixes.
        let scoped = CommandPickerSheet.filtered(sample(), search: "morning",
                                                 matching: { $0.sourceKind == .homeAssistant })
        #expect(scoped.isEmpty)
    }

    @Test func homeAssistantFilterExcludesURLCommands() {
        let result = CommandPickerSheet.filtered(sample(), search: "",
                                                 matching: { $0.sourceKind == .homeAssistant })
        #expect(result.map(\.name) == ["Start Coffee"])
    }

    @Test func shortcutsFilterCoversShortcutAndLink() {
        let result = CommandPickerSheet.filtered(sample(), search: "",
                                                 matching: { $0.sourceKind.isURL })
        #expect(Set(result.map(\.name)) == ["Good Morning", "Dashboard"])
    }
}

// MARK: - Usage resolution

@MainActor
struct CommandUsageResolverTests {

    private func container() throws -> ModelContainer {
        // `cloudKitDatabase: .none` matches the app's real container. Without it
        // SwiftData assumes CloudKit, which requires every attribute to be
        // optional or defaulted — Alarm's `time`, `label`, `soundName` etc. are
        // neither, so container creation throws before any test body runs.
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: Alarm.self, configurations: config)
    }

    @Test func resolvesAlarmAndWidgetUsages() throws {
        let container = try container()
        let id = UUID()

        let morning = Alarm(label: "Morning Alarm")
        morning.alarmScreenCommandID1 = id.uuidString
        let weekday = Alarm(label: "Weekday Alarm")
        weekday.swipeRightCommandID = id.uuidString
        container.mainContext.insert(morning)
        container.mainContext.insert(weekday)

        let usages = CommandUsageResolver.usages(
            of: id,
            widgetSwipeLeft: id,
            widgetSwipeRight: nil,
            widgetDoubleTap: nil,
            alarms: [morning, weekday]
        )

        // widget swipe-left + note button 1 in Morning + swipe-right in Weekday
        #expect(usages.count == 3)
        #expect(usages.contains { $0.destination == .widgetSwipeLeft && $0.alarmLabel == nil })
        #expect(usages.contains { $0.destination == .noteSlot(0) && $0.alarmLabel == "Morning Alarm" })
        #expect(usages.contains { $0.destination == .alarmSwipeRight && $0.alarmLabel == "Weekday Alarm" })
    }

    @Test func unusedCommandHasNoUsages() throws {
        let alarm = Alarm(label: "Empty")
        let usages = CommandUsageResolver.usages(
            of: UUID(), widgetSwipeLeft: nil, widgetSwipeRight: nil, widgetDoubleTap: nil,
            alarms: [alarm]
        )
        #expect(usages.isEmpty)
    }

    @Test func summaryReadsNaturally() {
        let one = [CommandUsage(destination: .noteSlot(0), alarmLabel: "Morning Alarm")]
        #expect(CommandUsageResolver.summary(one) == "Button 1 in Morning Alarm")

        let two = [
            CommandUsage(destination: .noteSlot(0), alarmLabel: "Morning Alarm"),
            CommandUsage(destination: .alarmSwipeRight, alarmLabel: "Weekday Alarm"),
        ]
        #expect(CommandUsageResolver.summary(two)
                == "Button 1 in Morning Alarm and Swipe Right in Weekday Alarm")
    }

    @Test func idMatchingIsCaseInsensitive() throws {
        let id = UUID()
        let alarm = Alarm(label: "Mixed")
        alarm.swipeLeftCommandID = id.uuidString.lowercased()
        let usages = CommandUsageResolver.usages(
            of: id, widgetSwipeLeft: nil, widgetSwipeRight: nil, widgetDoubleTap: nil,
            alarms: [alarm]
        )
        #expect(usages.map(\.destination) == [.alarmSwipeLeft])
    }
}

// MARK: - Deletion clears every persisted reference

@MainActor
struct CommandDeletionTests {

    @Test func clearDraftSlotsRemovesOnlyMatchingSlots() {
        let id = UUID()
        let other = UUID()
        var slots: [String?] = [id.uuidString, other.uuidString, nil, id.uuidString.lowercased()]
        CommandDeletionCoordinator.clearDraftSlots(&slots, deleted: id)
        #expect(slots == [nil, other.uuidString, nil, nil])
    }

    @Test func deletionMessageListsUsages() {
        let command = MQTTCommand(name: "Start Coffee")
        let usages = [
            CommandUsage(destination: .noteSlot(0), alarmLabel: "Morning Alarm"),
            CommandUsage(destination: .alarmSwipeRight, alarmLabel: "Weekday Alarm"),
        ]
        let message = CommandUsageResolver.deletionMessage(for: command, usages: usages)
        #expect(message.contains("Button 1 in Morning Alarm"))
        #expect(message.contains("Swipe Right in Weekday Alarm"))
        #expect(message.contains("both assignments"))
    }

    @Test func deletionMessageForUnusedCommand() {
        let command = MQTTCommand(name: "Lonely")
        let message = CommandUsageResolver.deletionMessage(for: command, usages: [])
        #expect(message.contains("isn't assigned"))
    }
}

// MARK: - Notes editor draft rules

struct NotesEditorDraftTests {

    @Test func slotsAlwaysNormalizeToFour() {
        #expect(NotesAfterAlarmEditorView.normalizedSlots([]) == [nil, nil, nil, nil])
        #expect(NotesAfterAlarmEditorView.normalizedSlots(["a"]).count == 4)
        #expect(NotesAfterAlarmEditorView.normalizedSlots(["a", "b", "c", "d", "e"]).count == 4)
        #expect(NotesAfterAlarmEditorView.normalizedSlots(["a", "b", "c", "d", "e"]) == ["a", "b", "c", "d"])
    }

    @Test func sheetSlotNormalizationMatches() {
        #expect(AfterAlarmActionEditorSheet.normalizedSlots(["x"]) == ["x", nil, nil, nil])
    }
}

// MARK: - MQTT command payload parsing

struct MQTTPayloadParsingTests {

    @Test func wellFormedJSONIsNotRewritten() throws {
        // The Python-literal rewrite is a whole-string regex, so it must never
        // run on a payload that already parsed — it cannot tell a bare literal
        // from the same word inside a quoted value.
        let raw = #"{"notes": "None of the trash goes out. True story."}"#
        let payload = try #require(MQTTManager.parseCommandPayload(raw))
        #expect(payload["notes"] as? String == "None of the trash goes out. True story.")
    }

    @Test func pythonLiteralsStillParseWhenStrictJSONFails() throws {
        // HA YAML automations that omit the `>` block scalar send Python repr.
        let raw = #"{"enabled": True, "vibrate": False, "sound": None}"#
        let payload = try #require(MQTTManager.parseCommandPayload(raw))
        #expect(payload["enabled"] as? Bool == true)
        #expect(payload["vibrate"] as? Bool == false)
        #expect(payload["sound"] == nil || payload["sound"] is NSNull)
    }

    @Test func invalidPayloadReturnsNil() {
        #expect(MQTTManager.parseCommandPayload("not json at all") == nil)
        #expect(MQTTManager.parseCommandPayload("[1, 2, 3]") == nil)  // array, not an object
    }
}

// MARK: - Alarm backup snapshot round-trip

struct AlarmBackupSnapshotTests {

    @Test func snapshotPreservesIdentityAndPayloadFields() throws {
        let alarm = Alarm(time: Date(timeIntervalSince1970: 1_700_000_000), label: "Work")
        alarm.alarmScreenNotes = "Bins out"
        alarm.alarmScreenCommandID1 = UUID().uuidString
        alarm.dismissAppURI = "shortcuts://run-shortcut?name=Morning"
        alarm.alarmIndex = 7
        alarm.source = "mqtt"
        alarm.extraMissions = [Mission(), Mission()]

        let restored = AlarmSnapshot(alarm).makeAlarm()

        // stableID must survive verbatim: AlarmKit UUIDs, timer keys and the
        // recovery blobs are all derived from it.
        #expect(restored.stableID == alarm.stableID)
        #expect(restored.stableHash == alarm.stableHash)
        #expect(restored.label == "Work")
        #expect(restored.time == alarm.time)
        #expect(restored.alarmScreenNotes == "Bins out")
        #expect(restored.alarmScreenCommandID1 == alarm.alarmScreenCommandID1)
        #expect(restored.dismissAppURI == alarm.dismissAppURI)
        #expect(restored.alarmIndex == 7)
        #expect(restored.source == "mqtt")
        #expect(restored.extraMissions.count == 2)
    }

    @Test func snapshotEncodesAndDecodes() throws {
        let alarm = Alarm(label: "Weekend")
        alarm.recurringDays = [1, 7]
        let data = try JSONEncoder().encode(AlarmSnapshot(alarm))
        let decoded = try JSONDecoder().decode(AlarmSnapshot.self, from: data)
        #expect(decoded.label == "Weekend")
        #expect(decoded.recurringDaysRaw == alarm.recurringDaysRaw)
        #expect(decoded.stableID == alarm.stableID)
    }
}

// MARK: - Database recovery notice wording

struct RecoveryNoticeTests {

    private func notice(restored: Int, snapshot: Int) -> AlarmBackupStore.RecoveryNotice {
        AlarmBackupStore.RecoveryNotice(
            date: Date(),
            restoredCount: restored,
            snapshotCount: snapshot,
            archivePath: nil,
            errorDescription: "test"
        )
    }

    @Test func fullRestoreIsNotReportedAsLoss() {
        let full = notice(restored: 3, snapshot: 3)
        #expect(full.hadLoss == false)
        #expect(HaWake_Alarm_V2App.recoveryMessage(for: full).contains("3 alarms were restored"))
    }

    @Test func partialAndEmptyRestoresReportLoss() {
        #expect(notice(restored: 1, snapshot: 3).hadLoss)
        #expect(notice(restored: 0, snapshot: 0).hadLoss)
        #expect(HaWake_Alarm_V2App.recoveryMessage(for: notice(restored: 0, snapshot: 0))
            .contains("no backup"))
        #expect(HaWake_Alarm_V2App.recoveryMessage(for: notice(restored: 1, snapshot: 3))
            .contains("1 of 3"))
    }
}
