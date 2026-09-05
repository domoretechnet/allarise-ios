//
//  AllariseIntentError.swift
//  HaWake Alarm V2
//
//  Refusal errors for the Siri / App Intents layer. Each case carries the
//  spoken dialog Siri uses. Policy rationale: missions must never be
//  bypassable by voice (see Documents/02, the lock-screen bypass rule).
//

import Foundation

enum AllariseIntentError: Error, CustomLocalizedStringResourceConvertible {
    // Creation / limits
    case freeLimitReached
    case unsupportedRecurrence
    case invalidTime
    case storageUnavailable

    // Lookup
    case alarmNotFound
    case noUpcomingAlarms
    case noSkippedAlarms
    case skipDisabled
    case mqttCommandNotFound

    // Ringing-state refusals
    case notRinging
    case alreadySnoozed

    // Snooze gates
    case snoozeDisabled
    case snoozeHomeAssistantOnly
    case snoozeExhausted

    // Mission-bypass protection
    case missionBlocksDismiss
    case missionBlocksDelete
    case missionBlocksDisable
    case ringingBlocksDisable
    case snoozedBlocksDisable

    // Quick alarms as timers
    case quickAlarmsCannotPause
    case quickAlarmsCannotResume
    case quickAlarmAlreadyFired

    // Radio
    case noRadioStations
    case audioBlockedByRingingAlarm
    case audioSessionUnavailable

    // Home Assistant
    case haNotEnabled
    case haNotConnected

    // Weather
    case weatherNeedsLocation
    case weatherUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .freeLimitReached:
            return "You've reached the free alarm limit. Upgrade to Pro in the app to add more alarms."
        case .unsupportedRecurrence:
            return "Alarms repeat on days of the week — that repeat pattern isn't supported."
        case .invalidTime:
            return "I couldn't understand that alarm time."
        case .storageUnavailable:
            return "The app isn't ready yet — open it and try again."
        case .alarmNotFound:
            return "I couldn't find that alarm."
        case .noUpcomingAlarms:
            return "There are no upcoming alarms to skip."
        case .noSkippedAlarms:
            return "No alarms are currently skipped."
        case .skipDisabled:
            return "Skipping is turned off for that alarm."
        case .mqttCommandNotFound:
            return "That command isn't set up in the app."
        case .notRinging:
            return "That alarm isn't ringing."
        case .alreadySnoozed:
            return "That alarm is already snoozed."
        case .snoozeDisabled:
            return "Snooze is turned off for this alarm."
        case .snoozeHomeAssistantOnly:
            return "Only Home Assistant can snooze this alarm."
        case .snoozeExhausted:
            return "No snoozes left for this alarm."
        case .missionBlocksDismiss:
            return "This alarm has a mission — it can't be dismissed until you complete it when it rings."
        case .missionBlocksDelete:
            return "You can't delete an alarm while its mission is waiting to be completed."
        case .missionBlocksDisable:
            return "You can't turn off an alarm while its mission is waiting to be completed."
        case .ringingBlocksDisable:
            return "That alarm is ringing. Dismiss it first."
        case .snoozedBlocksDisable:
            return "This alarm is snoozed. Cancel the snooze first."
        case .quickAlarmsCannotPause:
            return "Quick alarms can't be paused."
        case .quickAlarmsCannotResume:
            return "Quick alarms can't be paused, so there's nothing to resume."
        case .quickAlarmAlreadyFired:
            return "That quick alarm has already gone off."
        case .noRadioStations:
            return "You don't have any saved radio stations yet. Add some favorites in the app first."
        case .audioBlockedByRingingAlarm:
            return "An alarm is going off right now. Dismiss it first, then try again."
        case .audioSessionUnavailable:
            return "I couldn't start audio just now. Open Allarise and try again."
        case .haNotEnabled:
            return "The Home Assistant arm control isn't enabled in the app."
        case .haNotConnected:
            return "The app isn't connected to Home Assistant right now."
        case .weatherNeedsLocation:
            return "I need location access to get your weather — open the app to enable it."
        case .weatherUnavailable:
            return "I couldn't fetch the weather right now."
        }
    }
}
