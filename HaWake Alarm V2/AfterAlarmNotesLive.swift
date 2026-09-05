//
//  AfterAlarmNotesLive.swift
//  HaWake Alarm V2
//
//  Live backing state for the Notes step of the after-alarm flow.
//
//  The flow host resolves an alarm's notes text and command buttons ONCE, when it
//  builds the window. That is fine for a page the user reads and dismisses in a
//  few seconds — but Home Assistant can legitimately keep writing to an alarm
//  while its Notes page is on screen (an `update_alarm` with new `notes`, or an
//  `append_notes` adding a line as the morning routine progresses). Without this
//  the page shows whatever was true at the instant of dismissal and never changes.
//
//  So the page reads from here instead of from a captured string. The host seeds
//  the store before presenting and clears it when the flow tears down; the MQTT
//  handler pushes changes through `apply(...)`, which is a no-op unless the page
//  currently on screen belongs to the alarm being updated. That guard matters:
//  `update_alarm` targets an alarm by index and may well be aimed at a completely
//  different alarm than the one that just rang.
//
//  Deliberately NOT backed by the SwiftData model directly. The page outlives the
//  dismiss path, and reading properties off a model that has since been deleted
//  (an ephemeral MQTT alarm removes itself after firing) is a crash, not a blank
//  page.
//

import Foundation
import Observation

@MainActor
@Observable
final class AfterAlarmNotesLive {
    static let shared = AfterAlarmNotesLive()

    private init() {}

    /// `stableHash` of the alarm whose Notes page is currently presented.
    /// nil = no Notes step on screen, so pushes are ignored.
    private(set) var alarmHash: Int?

    /// Text currently rendered by the Notes page.
    private(set) var notes: String = ""

    /// Command buttons currently rendered by the Notes page, in slot order.
    private(set) var commands: [MQTTCommand] = []

    /// Seed the store for a flow that is about to be presented.
    func begin(alarmHash: Int, notes: String, commands: [MQTTCommand]) {
        self.alarmHash = alarmHash
        self.notes = notes
        self.commands = commands
    }

    /// Tear down when the flow window goes away. Leaves the content in place —
    /// only `alarmHash` gates pushes, and clearing the text here would blank the
    /// page during the dismiss animation.
    func end() {
        alarmHash = nil
    }

    /// Push an MQTT-driven change. Ignored unless `hash` matches the alarm whose
    /// page is on screen.
    ///
    /// `commandIDs` are the alarm's notes-page command slots (UUID strings);
    /// they are resolved against the current command library here so a command
    /// renamed or deleted in the same breath resolves correctly.
    func apply(hash: Int, notes: String, commandIDs: [String]) {
        guard alarmHash == hash else { return }
        self.notes = notes
        self.commands = commandIDs.compactMap { idString in
            guard let uuid = UUID(uuidString: idString) else { return nil }
            return DeviceSettings.shared.mqttCommands.first { $0.id == uuid }
        }
        AppLogger.shared.log("After-alarm Notes page updated live from MQTT", category: .mqtt)
    }
}
