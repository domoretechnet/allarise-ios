//
//  AnalyticsEvent.swift
//  HaWake Alarm V2
//
//  The complete telemetry vocabulary, as a TYPED enum rather than string
//  literals scattered across call sites. Three reasons it's shaped this way:
//
//  1. NO PII BY CONSTRUCTION. Every associated value is an Int, Bool, or a
//     closed enum. There is no `String` parameter anywhere in this file, so an
//     alarm label, a custom sound name, a radio station name, a Home Assistant
//     zone, a shortcut name, or note text CANNOT be logged even by accident.
//     Free-text fields are exactly where people put personal information.
//
//  2. GA4 LIMITS ARE FINITE. 500 distinct event names per app, 25 parameters
//     per event, and high-cardinality parameter values silently degrade
//     reporting. A closed enum keeps the name count fixed and knowable.
//
//  3. RENAMING IS SAFE. The wire name lives here once; call sites reference
//     cases. Changing a name can't leave half the app logging the old one.
//
//  Counts and durations are BUCKETED (see `Bucket`) rather than logged raw:
//  "3–5 alarms" answers every product question "4 alarms" does, and a bucket
//  can't become an identifier the way a precise tuple of exact values can.
//

import Foundation

// MARK: - Buckets

/// Coarse ranges. Raw counts and millisecond timings are both higher-cardinality
/// and more identifying than anything they'd tell us.
enum Bucket {
    /// 0, 1, 2, 3–5, 6–10, 11–20, 21+
    static func count(_ value: Int) -> String {
        switch value {
        case ..<0:    return "invalid"
        case 0:       return "0"
        case 1:       return "1"
        case 2:       return "2"
        case 3...5:   return "3_5"
        case 6...10:  return "6_10"
        case 11...20: return "11_20"
        default:      return "21_plus"
        }
    }

    /// Sub-second resolution near zero (where alarm latency matters), coarse above.
    static func seconds(_ value: TimeInterval) -> String {
        switch value {
        case ..<0:      return "invalid"
        case 0..<1:     return "under_1s"
        case 1..<3:     return "1_3s"
        case 3..<10:    return "3_10s"
        case 10..<30:   return "10_30s"
        case 30..<60:   return "30_60s"
        case 60..<300:  return "1_5m"
        case 300..<900: return "5_15m"
        default:        return "15m_plus"
        }
    }

    /// Minutes, for sleep timers and snooze lengths.
    static func minutes(_ value: Int) -> String {
        switch value {
        case ..<0:     return "invalid"
        case 0..<5:    return "under_5"
        case 5..<15:   return "5_15"
        case 15..<31:  return "15_30"
        case 31..<61:  return "31_60"
        case 61..<181: return "1_3h"
        default:       return "3h_plus"
        }
    }

    /// Remaining memory headroom, for pressure events.
    static func megabytes(_ value: Int) -> String {
        switch value {
        case ..<0:      return "invalid"
        case 0..<25:    return "under_25"
        case 25..<50:   return "25_50"
        case 50..<100:  return "50_100"
        case 100..<250: return "100_250"
        default:        return "250_plus"
        }
    }
}

// MARK: - Closed vocabularies

/// Where a command was fired from. Deliberately not the command's name.
enum CommandSurface: String {
    case widgetGesture = "widget_gesture"
    case widgetList = "widget_list"
    case alarmSwipe = "alarm_swipe"
    case notesButton = "notes_button"
}

/// Which delivery path actually rang the alarm — the core reliability signal.
/// Mirrors the tiers in Documents/16-FORCE-KILL-RECOVERY.md.
enum AlarmDeliveryPath: String {
    /// In-app timer fired at the exact time. The healthy path.
    case primaryTimer = "primary_timer"
    /// Tier 3: the +5s AlarmKit failsafe alerted — the app was dead or suspended.
    case alarmKitFailsafe = "alarmkit_failsafe_5s"
    /// Tier 2: the +2min weekly backup alerted — the app had been dead a while.
    case alarmKitWeeklyBackup = "alarmkit_weekly_2m"
    /// Tier 1: reconciliation on launch found an overdue alarm. It was MISSED
    /// until the user reopened the app.
    case launchRecovery = "launch_recovery"
    /// The ringing guard fired — the app died mid-ring.
    case ringingGuard = "ringing_guard"
}

/// How a ringing alarm ended.
enum AlarmOutcome: String {
    case dismissed, snoozed, skipped
    case missionFailed = "mission_failed"
}

/// What the user was doing when a paywall appeared.
enum PaywallSource: String {
    case missionType = "mission_type"
    case theme
    case customSound = "custom_sound"
    case settings
}

/// Sleep session audio source.
enum SleepSource: String {
    case sound, radio
}

/// Which after-alarm step was shown.
enum AfterAlarmStep: String {
    case notes, verse, weather, appLink = "app_link"
}

/// Why an app process exited, from MetricKit's MXAppExitMetric.
enum AppExitReason: String {
    /// We hit OUR OWN per-app memory limit.
    case memoryLimit = "memory_limit"
    /// The DEVICE ran out of memory and we were the cheapest thing to kill.
    /// Genuinely different from `memoryLimit` — the fix for one (use less) is
    /// not the fix for the other (be resident less, or be cheaper to keep) —
    /// and it's the more likely of the two for an app that stays up all night.
    case systemMemoryPressure = "system_memory_pressure"
    case backgroundCPULimit = "background_cpu_limit"
    case badAccess = "bad_access"
    case abnormal
    case watchdog
    case normal
}

// MARK: - Events

/// Every event the app can emit. Adding a case here is the ONLY way to add
/// telemetry, which keeps the taxonomy reviewable in one place.
enum AnalyticsEvent {

    // MARK: Alarms
    case alarmCreated(missionCount: Int, hasRadio: Bool, hasNotes: Bool, hasSwipeCommands: Bool, isRecurring: Bool)
    case alarmDeleted
    case alarmFired(path: AlarmDeliveryPath, missionCount: Int, usedRadio: Bool, secondsToAudio: TimeInterval)
    case alarmEnded(outcome: AlarmOutcome, snoozeCount: Int, secondsRinging: TimeInterval)

    // MARK: Reliability
    /// The alarm rang but no audio was confirmed playing — the worst class of bug.
    case alarmSilentStart(path: AlarmDeliveryPath)
    /// Radio was the primary source and the stream never confirmed, so the tone took over.
    case radioFellBackToTone(secondsAttempted: TimeInterval)
    /// A Home Assistant mission couldn't reach the broker and used its fallback.
    case haMissionFellBack
    /// The process died while an alarm was scheduled — a leading indicator of misses.
    case terminatedWithAlarmPending(wasRinging: Bool)
    /// MetricKit's daily report of why the process exited.
    case appExitReported(reason: AppExitReason, count: Int, wasBackground: Bool)
    /// Memory pressure while running, with remaining headroom.
    case memoryPressure(critical: Bool, availableMB: Int, wasBackground: Bool)

    // MARK: Missions
    case missionStarted(type: MissionType, slotIndex: Int)
    case missionCompleted(type: MissionType, seconds: TimeInterval)
    case missionAbandoned(type: MissionType, seconds: TimeInterval)

    // MARK: Radio
    case radioStationPicked(forSleep: Bool)
    case radioStreamFailed(forSleep: Bool)
    case radioFavoriteAdded

    // MARK: Custom sounds
    case customAlarmToneImported
    case customSleepSoundImported

    // MARK: Sleep sounds
    case sleepSessionStarted(source: SleepSource, timerMinutes: Int)
    case sleepSessionEnded(source: SleepSource, actualMinutes: Int)

    // MARK: Commands
    case commandCreated(kind: CommandSourceKind, fromWidgetContext: Bool)
    case commandFired(kind: CommandSourceKind, surface: CommandSurface)
    case commandDeleted

    // MARK: MQTT / Home Assistant
    case mqttCommandReceived(commandType: String)
    case mqttArmStateChanged(armed: Bool, surface: CommandSurface)
    case mqttConnectionFailed

    // MARK: App Intents (Siri / Shortcuts)
    /// The intent's own identifier — our vocabulary, never a user's shortcut name.
    case appIntentInvoked(intentName: String)

    // MARK: After-alarm pipeline
    case afterAlarmShown(stepCount: Int)
    case afterAlarmStepViewed(step: AfterAlarmStep)

    // MARK: Pro
    case paywallShown(source: PaywallSource)
    case purchaseStarted
    case purchaseCompleted
}

// MARK: - Wire format

extension AnalyticsEvent {

    /// GA4 event name: snake_case, ≤40 chars, stable forever once shipped.
    var name: String {
        switch self {
        case .alarmCreated:               return "alarm_created"
        case .alarmDeleted:               return "alarm_deleted"
        case .alarmFired:                 return "alarm_fired"
        case .alarmEnded:                 return "alarm_ended"
        case .alarmSilentStart:           return "alarm_silent_start"
        case .radioFellBackToTone:        return "radio_fell_back_to_tone"
        case .haMissionFellBack:          return "ha_mission_fell_back"
        case .terminatedWithAlarmPending: return "terminated_alarm_pending"
        case .appExitReported:            return "app_exit_reported"
        case .memoryPressure:             return "memory_pressure"
        case .missionStarted:             return "mission_started"
        case .missionCompleted:           return "mission_completed"
        case .missionAbandoned:           return "mission_abandoned"
        case .radioStationPicked:         return "radio_station_picked"
        case .radioStreamFailed:          return "radio_stream_failed"
        case .radioFavoriteAdded:         return "radio_favorite_added"
        case .customAlarmToneImported:    return "custom_tone_imported"
        case .customSleepSoundImported:   return "custom_sleep_sound_imported"
        case .sleepSessionStarted:        return "sleep_session_started"
        case .sleepSessionEnded:          return "sleep_session_ended"
        case .commandCreated:             return "command_created"
        case .commandFired:               return "command_fired"
        case .commandDeleted:             return "command_deleted"
        case .mqttCommandReceived:        return "mqtt_command_received"
        case .mqttArmStateChanged:        return "mqtt_arm_state_changed"
        case .mqttConnectionFailed:       return "mqtt_connection_failed"
        case .appIntentInvoked:           return "app_intent_invoked"
        case .afterAlarmShown:            return "after_alarm_shown"
        case .afterAlarmStepViewed:       return "after_alarm_step_viewed"
        case .paywallShown:               return "paywall_shown"
        case .purchaseStarted:            return "purchase_started"
        case .purchaseCompleted:          return "purchase_completed"
        }
    }

    /// Parameters, already bucketed. Values are only String / Int / Bool.
    var parameters: [String: Any] {
        switch self {
        case let .alarmCreated(missionCount, hasRadio, hasNotes, hasSwipeCommands, isRecurring):
            return ["mission_count": Bucket.count(missionCount),
                    "has_radio": hasRadio,
                    "has_notes": hasNotes,
                    "has_swipe_commands": hasSwipeCommands,
                    "is_recurring": isRecurring]

        case .alarmDeleted, .haMissionFellBack, .radioFavoriteAdded,
             .customAlarmToneImported, .customSleepSoundImported,
             .commandDeleted, .mqttConnectionFailed,
             .purchaseStarted, .purchaseCompleted:
            return [:]

        case let .alarmFired(path, missionCount, usedRadio, secondsToAudio):
            return ["path": path.rawValue,
                    "mission_count": Bucket.count(missionCount),
                    "used_radio": usedRadio,
                    "time_to_audio": Bucket.seconds(secondsToAudio)]

        case let .alarmEnded(outcome, snoozeCount, secondsRinging):
            return ["outcome": outcome.rawValue,
                    "snooze_count": Bucket.count(snoozeCount),
                    "ringing_duration": Bucket.seconds(secondsRinging)]

        case let .alarmSilentStart(path):
            return ["path": path.rawValue]

        case let .radioFellBackToTone(secondsAttempted):
            return ["attempt_duration": Bucket.seconds(secondsAttempted)]

        case let .terminatedWithAlarmPending(wasRinging):
            return ["was_ringing": wasRinging]

        case let .appExitReported(reason, count, wasBackground):
            return ["reason": reason.rawValue,
                    "exit_count": Bucket.count(count),
                    "background": wasBackground]

        case let .memoryPressure(critical, availableMB, wasBackground):
            return ["critical": critical,
                    "available_mb": Bucket.megabytes(availableMB),
                    "background": wasBackground]

        case let .missionStarted(type, slotIndex):
            return ["mission_type": type.analyticsName,
                    "slot": Bucket.count(slotIndex)]

        case let .missionCompleted(type, seconds):
            return ["mission_type": type.analyticsName,
                    "duration": Bucket.seconds(seconds)]

        case let .missionAbandoned(type, seconds):
            return ["mission_type": type.analyticsName,
                    "duration": Bucket.seconds(seconds)]

        case let .radioStationPicked(forSleep):
            return ["for_sleep": forSleep]

        case let .radioStreamFailed(forSleep):
            return ["for_sleep": forSleep]

        case let .sleepSessionStarted(source, timerMinutes):
            return ["source": source.rawValue,
                    "timer": Bucket.minutes(timerMinutes)]

        case let .sleepSessionEnded(source, actualMinutes):
            return ["source": source.rawValue,
                    "actual": Bucket.minutes(actualMinutes)]

        case let .commandCreated(kind, fromWidgetContext):
            return ["kind": kind.analyticsName,
                    "widget_context": fromWidgetContext]

        case let .commandFired(kind, surface):
            return ["kind": kind.analyticsName,
                    "surface": surface.rawValue]

        case let .mqttCommandReceived(commandType):
            return ["command_type": commandType]

        case let .mqttArmStateChanged(armed, surface):
            return ["armed": armed,
                    "surface": surface.rawValue]

        case let .appIntentInvoked(intentName):
            return ["intent": intentName]

        case let .afterAlarmShown(stepCount):
            return ["step_count": Bucket.count(stepCount)]

        case let .afterAlarmStepViewed(step):
            return ["step": step.rawValue]

        case let .paywallShown(source):
            return ["source": source.rawValue]
        }
    }
}

// MARK: - Stable wire names for existing model enums
//
// Deliberately NOT the `rawValue`s: those are user-facing display strings
// ("Block Drop", "Home Assistant") that can be reworded at any time. A wire
// name that changes silently splits a metric in two.

extension MissionType {
    var analyticsName: String {
        switch self {
        case .none:          return "tap"
        case .shake:         return "shake"
        case .math:          return "math"
        case .balanceBall:   return "balance"
        case .blockDrop:     return "bricks"
        case .meteor:        return "meteor"
        case .homeAssistant: return "home_assistant"
        case .alert:         return "alert"
        }
    }
}

extension CommandSourceKind {
    var analyticsName: String {
        switch self {
        case .homeAssistant: return "home_assistant"
        case .shortcut:      return "shortcut"
        case .link:          return "link"
        }
    }
}
