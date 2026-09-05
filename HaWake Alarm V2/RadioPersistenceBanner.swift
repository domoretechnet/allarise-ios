//
//  RadioPersistenceBanner.swift
//  HaWake Alarm V2
//
//  Tells the user, once per persistence-off period, that their radio alarms will
//  ring with their alarm tone rather than the station.
//
//  WHY A BANNER AND NOT AN ALERT
//  -----------------------------
//  Switching App Persistence off in Settings gets a modal, because that is a
//  deliberate action with an immediate consequence and the user is right there.
//
//  The other way into the same state — setting a radio station on an alarm while
//  persistence is ALREADY off — has no good modal moment: `saveAlarm()` ends in
//  `dismiss()`, so an alert raised there is torn down with the view. Rather than
//  restructure the save flow around a warning, this banner watches for the
//  dangerous COMBINATION and surfaces it on the list the user lands on.
//
//  That turns out to be the better shape anyway: it does not care how the state
//  was reached, so it also covers the case where persistence was switched off via
//  the NWS alert path (which bypasses the radio modal), or where an MQTT/Siri
//  create added a radio station with persistence already off.
//
//  WHY IT DOES NOT NAG
//  -------------------
//  It renders only when all three hold: persistence off, at least one enabled
//  non-ephemeral alarm has a station, and the notice has not been acknowledged
//  during this off period. `radioPersistenceNoticeAcknowledged` is re-armed on
//  every on→off transition, so turning persistence back on and later off again
//  earns one more notice — and nothing in between.
//
//  Reference: Documents/24-RADIO.md — radio rides the in-app timer, which needs
//  the keep-alive. AlarmKit-only fires play the alarm's `soundName` wav.
//

import SwiftData
import SwiftUI

struct RadioPersistenceBanner: View {
    @Query private var alarms: [Alarm]
    @State private var settings = DeviceSettings.shared

    /// Enabled, non-ephemeral alarms carrying a station. Quick alarms are
    /// excluded — they fire once, imminently, while the app is still on screen.
    private var affected: [Alarm] {
        alarms.filter { $0.isEnabled && !$0.isEphemeral && ($0.radioStationURL?.isEmpty == false) }
    }

    private var shouldShow: Bool {
        settings.appPersistenceMode == .off
            && !settings.radioPersistenceNoticeAcknowledged
            && !affected.isEmpty
    }

    private var message: String {
        let names = affected.map { $0.label.isEmpty ? "Untitled" : $0.label }
        let list: String
        switch names.count {
        case 1:  list = "“\(names[0])” will ring"
        case 2:  list = "“\(names[0])” and “\(names[1])” will ring"
        default: list = "“\(names[0])”, “\(names[1])” and \(names.count - 2) more will ring"
        }
        return "\(list) with the alarm tone, not the radio. Radio needs App Persistence on to play at alarm time."
    }

    var body: some View {
        if shouldShow {
            HomeNoticeBanner(
                systemImage: "radio",
                title: "App Persistence is off",
                message: message,
                onDismiss: { settings.radioPersistenceNoticeAcknowledged = true }
            )
        }
    }
}
