//
//  AlarmDuplicationTests.swift
//  HaWake Alarm V2Tests
//
//  Guards `Alarm.duplicate(label:alarmIndex:)`.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  Duplication used to be a hand-maintained list of assignments inside
//  `AlarmListView.duplicateAlarm`. Nothing connected that list to the model, so
//  every feature added afterwards was silently dropped when a user duplicated an
//  alarm: mission slots 2–5, the entire After-Alarm sequence, the notes page and
//  its four command buttons, and the radio station. It failed quietly — the copy
//  looked fine until you opened it.
//
//  So the important test here is not `copiesEverything` (which only checks the
//  fields someone remembered to list). It is `everyStoredPropertyIsClassified`,
//  which walks the model's own storage and fails when a property exists that this
//  file has not been told about. That is the one that catches the NEXT feature.
//
//  Reference: Documents/09-DATA-MODEL-AND-SETTINGS.md — "Adding a stored property"
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

@MainActor
struct AlarmDuplicationTests {

    // MARK: - The classification contract
    //
    // Every stored property on `Alarm` must appear in exactly one of these sets.
    // When you add a property, add its name here too, and handle it in
    // `Alarm.duplicate`. If you don't, `everyStoredPropertyIsClassified` fails.

    /// Carried onto the copy — the things that make the alarm what it is.
    static let copied: Set<String> = [
        "time", "recurringDaysRaw", "soundName", "snoozeDuration",
        "missionData", "extraMissionsData",
        "allowSkipOnce", "skipHoldDuration", "maxSnoozeCount",
        "snoozeRequiresHold", "customSnoozeHoldDuration",
        "snoozeModeRaw", "skipAlarmModeRaw",
        "customVolumeLevel", "customGracePeriod", "customVibrationEnabled",
        "customFadeInEnabled", "customFadeInDuration",
        "swipeLeftCommandID", "swipeRightCommandID",
        "showWeatherAfterAlarm", "dismissAppURI", "snoozeAppURI",
        "alarmScreenNotes",
        "alarmScreenCommandID1", "alarmScreenCommandID2",
        "alarmScreenCommandID3", "alarmScreenCommandID4",
        "afterAlarmOrderData",
        "radioStationID", "radioStationName", "radioStationURL",
        "isEphemeral", "excludeFromMQTT", "firesAtExactTime",
    ]

    /// Must differ on the copy.
    static let newIdentity: Set<String> = [
        "stableID", "label", "alarmIndex", "isEnabled",
    ]

    /// Deliberately reset — runtime state and provenance.
    static let reset: Set<String> = [
        "isSnoozed", "snoozeUntil", "snoozeCount",
        "skippedFireDate", "lastFireDate",
        "source", "mqttID",
    ]

    /// Builds an alarm with a non-default value in every copied field, so a
    /// missing assignment shows up as a mismatch rather than as two matching
    /// defaults.
    private func fullyPopulatedAlarm() -> Alarm {
        let a = Alarm(
            time: Date(timeIntervalSince1970: 1_800_000_000),
            label: "Original",
            isEnabled: true,
            recurringDays: [2, 4, 6],
            soundName: "Classic_Alarm",
            snoozeDuration: 12,
            mission: Mission(type: .math),
            allowSkipOnce: false,
            skipHoldDuration: 2.5,
            maxSnoozeCount: 7,
            customSnoozeHoldDuration: 3.5,
            snoozeModeRaw: "Hold to Snooze",
            skipAlarmModeRaw: "Hold to Skip Alarm"
        )
        a.extraMissions = [Mission(type: .shake), Mission(type: .blockDrop), Mission(type: .meteor)]
        a.customVolumeLevel = 0.77
        a.customGracePeriod = 42
        a.customVibrationEnabled = true
        a.customFadeInEnabled = true
        a.customFadeInDuration = 8
        a.swipeLeftCommandID = "cmd-left"
        a.swipeRightCommandID = "cmd-right"
        a.showWeatherAfterAlarm = true
        a.dismissAppURI = "shortcuts://run-shortcut?name=Dismiss"
        a.snoozeAppURI = "shortcuts://run-shortcut?name=Snooze"
        a.alarmScreenNotes = "Bins out. Passport."
        a.alarmScreenCommandID1 = "c1"
        a.alarmScreenCommandID2 = "c2"
        a.alarmScreenCommandID3 = "c3"
        a.alarmScreenCommandID4 = "c4"
        a.afterAlarmOrderData = try? JSONEncoder().encode(["weather", "verse", "notes"])
        a.radioStationID = "station-42"
        a.radioStationName = "BBC Radio 4"
        a.radioStationURL = "https://example.invalid/stream.mp3"
        a.isEphemeral = false
        a.excludeFromMQTT = true
        a.firesAtExactTime = true
        // Runtime state that must NOT survive duplication.
        a.isSnoozed = true
        a.snoozeUntil = Date(timeIntervalSince1970: 1_800_003_600)
        a.snoozeCount = 2
        a.skippedFireDate = Date(timeIntervalSince1970: 1_800_007_200)
        a.lastFireDate = Date(timeIntervalSince1970: 1_799_000_000)
        a.mqttID = "ha-original-7"
        a.source = "mqtt"
        return a
    }

    // MARK: - The canary

    @Test("Every stored property on Alarm is classified — catches new fields")
    func everyStoredPropertyIsClassified() {
        let known = Self.copied.union(Self.newIdentity).union(Self.reset)
        let actual = Set(Alarm.storedPropertyNamesForDuplicationAudit)

        let unclassified = actual.subtracting(known)
        #expect(
            unclassified.isEmpty,
            """
            New stored property on Alarm that duplication does not know about: \
            \(unclassified.sorted().joined(separator: ", ")).
            Add it to Alarm.duplicate(label:alarmIndex:) AND to one of the sets in \
            this file. See Documents/09-DATA-MODEL-AND-SETTINGS.md.
            """
        )

        let stale = known.subtracting(actual)
        #expect(
            stale.isEmpty,
            "These names are classified here but no longer exist on Alarm: \(stale.sorted().joined(separator: ", "))."
        )
    }

    // MARK: - Behaviour

    @Test("A duplicate carries every configured field")
    func copiesEverything() {
        let a = fullyPopulatedAlarm()
        let b = a.duplicate(label: "Original 2", alarmIndex: 9)

        #expect(b.time == a.time)
        #expect(b.safeRecurringDays == a.safeRecurringDays)
        #expect(b.soundName == a.soundName)
        #expect(b.snoozeDuration == a.snoozeDuration)
        #expect(b.mission.type == a.mission.type)
        // The regression that started this: slots 2–5.
        #expect(b.extraMissions.count == 3)
        #expect(b.extraMissions.map(\.type) == a.extraMissions.map(\.type))
        #expect(b.missionSequence.count == a.missionSequence.count)

        #expect(b.allowSkipOnce == a.allowSkipOnce)
        #expect(b.skipHoldDuration == a.skipHoldDuration)
        #expect(b.maxSnoozeCount == a.maxSnoozeCount)
        #expect(b.customSnoozeHoldDuration == a.customSnoozeHoldDuration)
        #expect(b.snoozeModeRaw == a.snoozeModeRaw)
        #expect(b.skipAlarmModeRaw == a.skipAlarmModeRaw)

        #expect(b.customVolumeLevel == a.customVolumeLevel)
        #expect(b.customGracePeriod == a.customGracePeriod)
        #expect(b.customVibrationEnabled == a.customVibrationEnabled)
        #expect(b.customFadeInEnabled == a.customFadeInEnabled)
        #expect(b.customFadeInDuration == a.customFadeInDuration)

        #expect(b.swipeLeftCommandID == a.swipeLeftCommandID)
        #expect(b.swipeRightCommandID == a.swipeRightCommandID)

        // After-Alarm sequence
        #expect(b.showWeatherAfterAlarm == a.showWeatherAfterAlarm)
        #expect(b.dismissAppURI == a.dismissAppURI)
        #expect(b.snoozeAppURI == a.snoozeAppURI)
        #expect(b.afterAlarmOrderData == a.afterAlarmOrderData)

        // Notes page + command buttons
        #expect(b.alarmScreenNotes == a.alarmScreenNotes)
        #expect(b.alarmScreenCommandID1 == a.alarmScreenCommandID1)
        #expect(b.alarmScreenCommandID2 == a.alarmScreenCommandID2)
        #expect(b.alarmScreenCommandID3 == a.alarmScreenCommandID3)
        #expect(b.alarmScreenCommandID4 == a.alarmScreenCommandID4)

        // Radio
        #expect(b.radioStationID == a.radioStationID)
        #expect(b.radioStationName == a.radioStationName)
        #expect(b.radioStationURL == a.radioStationURL)

        #expect(b.isEphemeral == a.isEphemeral)
        #expect(b.excludeFromMQTT == a.excludeFromMQTT)
        #expect(b.firesAtExactTime == a.firesAtExactTime)
    }

    @Test("A duplicate takes a new identity and arrives switched off")
    func newIdentityFields() {
        let a = fullyPopulatedAlarm()
        let b = a.duplicate(label: "Original 2", alarmIndex: 9)

        #expect(b.label == "Original 2")
        #expect(b.alarmIndex == 9)
        #expect(b.stableID != a.stableID)
        // Off by design: a copy must not ring at a time the user hasn't reviewed.
        #expect(b.isEnabled == false)
    }

    @Test("A duplicate inherits no runtime state or provenance")
    func runtimeStateIsReset() {
        let a = fullyPopulatedAlarm()
        let b = a.duplicate(label: "Original 2", alarmIndex: 9)

        #expect(b.isSnoozed == false)
        #expect(b.snoozeUntil == nil)
        #expect(b.snoozeCount == 0)
        #expect(b.skippedFireDate == nil)
        #expect(b.lastFireDate == nil)
        // HA's ID belongs to the original alarm, not to a local copy of it.
        #expect(b.mqttID == nil)
        #expect(b.source != "mqtt")
    }

    @Test("The analytics event describes the copy, not an empty alarm")
    func analyticsSeesTheRealCopy() {
        // duplicateAlarm() logs .alarmCreated using the NEW alarm. Before the
        // structural fix these all read back empty, under-reporting every
        // duplicate. This pins the values the event is built from.
        let a = fullyPopulatedAlarm()
        let b = a.duplicate(label: "Original 2", alarmIndex: 9)

        #expect(b.missionSequence.count > 1)
        #expect(b.radioStationURL != nil)
        #expect(b.hasNotesContent)
        #expect(b.swipeLeftCommandID != nil || b.swipeRightCommandID != nil)
    }
}
