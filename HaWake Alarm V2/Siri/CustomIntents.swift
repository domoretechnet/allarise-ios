//
//  CustomIntents.swift
//  HaWake Alarm V2
//
//  Allarise-specific Siri intents (stable App Intents APIs, iOS 26+).
//  These cover actions outside the iOS 27 clock schema: skip/unskip,
//  sleep sounds, morning weather, and Home Assistant controls.
//  All delegate to SiriAlarmService / existing service singletons.
//

import AppIntents
import Foundation

// MARK: - Skip Next Alarm

struct SkipNextAlarmIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Next Alarm"
    static var description = IntentDescription(
        "Skips the next occurrence of your upcoming alarm. One-time alarms are turned off."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = try await SiriAlarmService.shared.skipNextAlarm()
        switch outcome {
        case .skippedRecurring(let alarm, let nextRing):
            if let nextRing {
                let when = nextRing.formatted(date: .abbreviated, time: .shortened)
                return .result(dialog: "Skipping “\(alarm.label)” — it'll ring next on \(when).")
            }
            return .result(dialog: "Skipping the next ring of “\(alarm.label)”.")
        case .disabledOneTime(let alarm):
            return .result(dialog: "“\(alarm.label)” was a one-time alarm, so I turned it off.")
        }
    }
}

// MARK: - Unskip Alarm

struct UnskipAlarmIntent: AppIntent {
    static var title: LocalizedStringResource = "Unskip Alarm"
    static var description = IntentDescription(
        "Restores the next occurrence of a skipped alarm."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let alarm = try await SiriAlarmService.shared.unskipAlarm()
        if let next = alarm.nextFireDate() {
            let when = next.formatted(date: .abbreviated, time: .shortened)
            return .result(dialog: "“\(alarm.label)” is back on — next ring \(when).")
        }
        return .result(dialog: "“\(alarm.label)” is back on.")
    }
}

// MARK: - Stop Sleep Sounds

struct StopSleepSoundsIntent: AppIntent {
    // Title/identity unchanged so existing user shortcuts keep working — this
    // intent now stops whichever sleep-audio source is active (sleep sounds or
    // radio), since only one owns the Now Playing session at a time.
    static var title: LocalizedStringResource = "Stop Sleep Sounds"
    static var description = IntentDescription("Stops any playing Allarise sleep sounds or radio.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Radio and sleep sounds are mutually exclusive (each stops the other
        // on start), so at most one is active. Check radio first.
        if RadioPlayerManager.shared.isActive {
            RadioPlayerManager.shared.stop()
            return .result(dialog: "Radio stopped.")
        }
        if SleepSoundManager.shared.isActive {
            SleepSoundManager.shared.stop()
            return .result(dialog: "Sleep sounds stopped.")
        }
        return .result(dialog: "Nothing is playing.")
    }
}

// MARK: - Start Sleep Sound

/// AudioPlaybackIntent (not a plain AppIntent) so Shortcuts/Siri can start
/// playback while the app is in the BACKGROUND. As a plain AppIntent, iOS
/// launches the app backgrounded, AVAudioSession.setActive(true) throws
/// CannotStartPlaying (561015905), and nothing is audible until the user
/// manually foregrounds the app — at which point the already-running AVPlayer
/// finally gets a usable session. UIBackgroundModes "audio" does not help:
/// it keeps an ALREADY-ACTIVE session alive, it does not grant the right to
/// activate one from a cold background launch. AudioPlaybackIntent is what
/// grants that. Deliberately NOT .foreground(.immediate) (as the dismiss
/// intents use) — starting a sleep sound should not drag the user into the app.
struct StartSleepSoundIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Start Sleep Sounds"
    static var description = IntentDescription(
        "Plays an Allarise sleep sound. Uses your last-played sound when none is specified."
    )

    @Parameter(title: "Sound")
    var sound: SleepSoundEntity?

    @Parameter(title: "Hours")
    var hours: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let settings = DeviceSettings.shared
        // Cold-launch race: custom sounds load asynchronously at startup, and
        // resolving a custom sound id (or listing) before that finishes fails.
        await CustomSoundManager.shared.ensureBootstrapped()
        let available = SleepSoundManager.availableSounds()
        guard !available.isEmpty else {
            return .result(dialog: "There are no sleep sounds available.")
        }

        // Explicit choice > last played > first available.
        let soundID: String
        if let sound {
            soundID = sound.id
        } else if !settings.lastSleepSoundName.isEmpty, available.contains(settings.lastSleepSoundName) {
            soundID = settings.lastSleepSoundName
        } else {
            soundID = available[0]
        }

        let volume = settings.lastSleepSoundVolume > 0 ? settings.lastSleepSoundVolume : 0.5
        let durationHours = min(max(hours ?? 8, 1), 12)

        SleepSoundManager.shared.start(
            soundName: soundID,
            volume: volume,
            mode: .duration(TimeInterval(durationHours) * 3600),
            fadeOutDuration: 0
        )

        let name = SleepSoundManager.displayName(for: soundID)
        return .result(dialog: "Playing \(name) for \(durationHours) hour\(durationHours == 1 ? "" : "s").")
    }
}

// MARK: - Start Radio

/// AudioPlaybackIntent so Shortcuts can start the stream from the background —
/// see StartSleepSoundIntent above for why a plain AppIntent stays silent until
/// the app is opened.
struct StartRadioIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Start Radio"
    static var description = IntentDescription(
        "Plays one of your Allarise radio stations. Uses your last-played station when none is specified."
    )

    @Parameter(title: "Station")
    var station: RadioStationEntity?

    @Parameter(title: "Hours")
    var hours: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = RadioPlayerManager.shared

        // Resolve to a concrete RadioStation (the entity only carries id + name;
        // playback needs the stored stream URL). Explicit choice > last played
        // > first favorite. The entity id is the stationuuid, so match on it.
        let resolved: RadioStation
        if let station,
           let match = manager.favorites.first(where: { $0.id == station.id })
               ?? (manager.lastStation.map { $0.id == station.id ? $0 : nil } ?? nil) {
            resolved = match
        } else if let last = manager.lastStation {
            resolved = last
        } else if let first = manager.favorites.first {
            resolved = first
        } else {
            throw AllariseIntentError.noRadioStations
        }

        let durationHours = min(max(hours ?? 8, 1), 12)

        // play() refuses while an alarm is ringing (guards on
        // AlarmSoundPlayer.shared.shouldBePlaying) and won't start a session.
        // Its return value — NOT isActive — is what distinguishes real playback
        // from a failed background session activation: play() sets state to
        // .playing either way, so isActive alone would report success while
        // silent (the original Shortcuts bug).
        let started = manager.play(station: resolved)
        guard manager.isActive, manager.currentStation?.id == resolved.id else {
            throw AllariseIntentError.audioBlockedByRingingAlarm
        }
        guard started else {
            throw AllariseIntentError.audioSessionUnavailable
        }
        manager.setSleepTimer(
            end: Date().addingTimeInterval(TimeInterval(durationHours) * 3600),
            fadeOut: 0
        )

        return .result(dialog: "Playing \(resolved.name) for \(durationHours) hour\(durationHours == 1 ? "" : "s").")
    }
}

// MARK: - Morning Weather

struct MorningWeatherIntent: AppIntent {
    static var title: LocalizedStringResource = "Morning Weather"
    static var description = IntentDescription("Reads your current weather and today's forecast.")
    // Pulled from Siri/Shortcuts (no AppShortcut phrases, hidden from the
    // Shortcuts action gallery). The intent body stays so nothing else breaks
    // and it can be re-surfaced later by flipping this + re-adding phrases.
    static var isDiscoverable: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = HaWakeWeatherService.shared
        await service.fetchWeather()

        switch service.state {
        case .loaded(let current, let daily):
            let summary = WeatherSpeechFormatter.summary(
                current: current,
                daily: daily,
                locationName: service.locationName
            )
            return .result(dialog: "\(summary)")
        case .noLocation:
            throw AllariseIntentError.weatherNeedsLocation
        default:
            throw AllariseIntentError.weatherUnavailable
        }
    }
}

// MARK: - Arm / Disarm Home Assistant

enum ArmStateAction: String, AppEnum {
    case arm
    case disarm

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Security Action"
    static var caseDisplayRepresentations: [ArmStateAction: DisplayRepresentation] = [
        .arm: "Arm",
        .disarm: "Disarm",
    ]
}

struct SetArmStateIntent: AppIntent {
    static var title: LocalizedStringResource = "Arm or Disarm"
    static var description = IntentDescription(
        "Arms or disarms your Home Assistant security through Allarise."
    )

    @Parameter(title: "Action")
    var action: ArmStateAction

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let settings = DeviceSettings.shared
        guard settings.hassWidgetAlarmEnabled else { throw AllariseIntentError.haNotEnabled }
        guard HAIntegrationRouter.shared.isConnected else { throw AllariseIntentError.haNotConnected }

        let arming = action == .arm
        if !arming {
            // Disarm is the security-sensitive direction — always confirm.
            try await requestConfirmation(
                result: .result(dialog: "Disarm your Home Assistant security?")
            )
        }

        HAIntegrationRouter.shared.requestArmStateChange(arming, settings: settings)

        // HA is the source of truth: wait briefly for its retained state echo.
        let confirmed = await Self.awaitArmState(arming, timeout: 5)
        if confirmed {
            return .result(dialog: arming ? "Armed." : "Disarmed.")
        }
        return .result(dialog: "Asked Home Assistant to \(arming ? "arm" : "disarm") — it hasn't confirmed yet.")
    }

    /// Wait for the "ArmStateChanged" notification (posted when HA's retained
    /// state topic echoes back) to report the expected value, with a timeout.
    @MainActor
    private static func awaitArmState(_ expected: Bool, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            var token: NSObjectProtocol?
            var finished = false
            func finish(_ value: Bool) {
                guard !finished else { return }
                finished = true
                if let token { NotificationCenter.default.removeObserver(token) }
                continuation.resume(returning: value)
            }
            token = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("ArmStateChanged"),
                object: nil,
                queue: .main
            ) { note in
                let armed = note.userInfo?["armed"] as? Bool
                DispatchQueue.main.async {
                    if armed == expected { finish(true) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }
}

// MARK: - Run MQTT Command

struct RunMQTTCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Command"
    static var description = IntentDescription(
        "Runs one of your configured Allarise commands through Home Assistant."
    )

    @Parameter(title: "Command")
    var command: MQTTCommandEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let settings = DeviceSettings.shared
        guard HAIntegrationRouter.shared.isConnected else { throw AllariseIntentError.haNotConnected }
        guard let cmd = settings.mqttCommands.first(where: { $0.id.uuidString == command.id }) else {
            throw AllariseIntentError.mqttCommandNotFound
        }

        if settings.confirmCommandsEnabled {
            try await requestConfirmation(
                result: .result(dialog: "Run “\(cmd.name)”?")
            )
        }

        // Same sequence as the home-screen command widget.
        HAIntegrationRouter.shared.publishArmCustomCommand(cmd.name, settings: settings)
        if settings.hassWidgetAlarmEnabled {
            switch cmd.armAction {
            case .arm:
                HAIntegrationRouter.shared.requestArmStateChange(true, settings: settings)
            case .disarm:
                HAIntegrationRouter.shared.requestArmStateChange(false, settings: settings)
            case .toggle:
                HAIntegrationRouter.shared.requestArmStateChange(!settings.cachedArmState, settings: settings)
            case .none:
                break
            }
        }
        return .result(dialog: "Sent “\(cmd.name)”.")
    }
}
