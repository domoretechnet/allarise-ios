//
//  AllariseShortcuts.swift
//  HaWake Alarm V2
//
//  App Shortcuts: the fixed Siri phrases for Allarise's custom intents.
//  \(.applicationName) resolves to "Allarise" (CFBundleDisplayName) and to
//  every INAlternativeAppNames entry, so each phrase below matches all
//  spoken variants of the name. On iOS 26 these are the only Siri phrases;
//  on iOS 27 the clock-schema intents add natural alarm language on top.
//
//  Phrase guidelines: every phrase must contain the app-name token; keep
//  each list under ~10 — alternates multiply the recognition space.
//

import AppIntents

struct AllariseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SkipNextAlarmIntent(),
            phrases: [
                "Skip my next alarm in \(.applicationName)",
                "Skip my alarm in \(.applicationName)",
                "Skip the next alarm in \(.applicationName)",
                "Skip tomorrow's alarm in \(.applicationName)",
                "Cancel my next alarm in \(.applicationName)",
                "Don't wake me up tomorrow in \(.applicationName)",
                "Let me sleep in tomorrow in \(.applicationName)",
                "\(.applicationName) skip my next alarm",
                "\(.applicationName) skip my alarm",
            ],
            shortTitle: "Skip Next Alarm",
            systemImageName: "forward.end"
        )
        AppShortcut(
            intent: UnskipAlarmIntent(),
            phrases: [
                "Unskip my alarm in \(.applicationName)",
                "Unskip my next alarm in \(.applicationName)",
                "Restore my alarm in \(.applicationName)",
                "Restore my skipped alarm in \(.applicationName)",
                "Turn my alarm back on in \(.applicationName)",
                "Undo the skip in \(.applicationName)",
                "\(.applicationName) unskip my alarm",
            ],
            shortTitle: "Unskip Alarm",
            systemImageName: "backward.end"
        )
        AppShortcut(
            intent: StopSleepSoundsIntent(),
            phrases: [
                "Stop sleep sounds in \(.applicationName)",
                "Stop the sleep sound in \(.applicationName)",
                "Turn off sleep sounds in \(.applicationName)",
                "Stop white noise in \(.applicationName)",
                "Stop playing sounds in \(.applicationName)",
                "\(.applicationName) stop sleep sounds",
            ],
            shortTitle: "Stop Sleep Sounds",
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: StartSleepSoundIntent(),
            phrases: [
                "Play sleep sounds in \(.applicationName)",
                "Play \(\.$sound) in \(.applicationName)",
                "Start sleep sounds in \(.applicationName)",
                "Start \(\.$sound) in \(.applicationName)",
                "Put on sleep sounds in \(.applicationName)",
                "Play white noise in \(.applicationName)",
                "Play some sleep sounds in \(.applicationName)",
                "Help me fall asleep with \(.applicationName)",
                "\(.applicationName) sleep sounds",
            ],
            shortTitle: "Start Sleep Sounds",
            systemImageName: "moon.stars"
        )
        AppShortcut(
            intent: StartRadioIntent(),
            phrases: [
                "Play radio in \(.applicationName)",
                "Play \(\.$station) in \(.applicationName)",
                "Play \(\.$station) radio in \(.applicationName)",
                "Start radio in \(.applicationName)",
                "Put on the radio in \(.applicationName)",
                "Play the radio in \(.applicationName)",
                "\(.applicationName) radio",
            ],
            shortTitle: "Start Radio",
            systemImageName: "radio"
        )
        AppShortcut(
            intent: RunMQTTCommandIntent(),
            phrases: [
                "Run \(\.$command) in \(.applicationName)",
                "Run a command in \(.applicationName)",
                "Send \(\.$command) in \(.applicationName)",
                "Trigger \(\.$command) in \(.applicationName)",
                "Run the \(\.$command) command in \(.applicationName)",
                "\(.applicationName) run \(\.$command)",
            ],
            shortTitle: "Run Command",
            systemImageName: "bolt.circle"
        )
        AppShortcut(
            intent: SetArmStateIntent(),
            phrases: [
                "\(\.$action) my system in \(.applicationName)",
                "\(\.$action) my security in \(.applicationName)",
                "\(\.$action) my home in \(.applicationName)",
                "\(\.$action) my house in \(.applicationName)",
                "\(\.$action) my security system in \(.applicationName)",
                "\(.applicationName) security",
            ],
            shortTitle: "Arm or Disarm",
            systemImageName: "shield"
        )
    }
}
