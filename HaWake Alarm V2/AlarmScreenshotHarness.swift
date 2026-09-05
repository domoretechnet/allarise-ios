//
//  AlarmScreenshotHarness.swift
//  HaWake Alarm V2
//
//  DEBUG-only host that renders a single active-alarm screen for a given mission
//  so it can be screenshotted deterministically in the simulator without a real
//  alarm firing:
//
//    simctl launch booted <bundle-id> -alarmScreenshot none
//    simctl launch booted <bundle-id> -alarmScreenshot math
//    simctl launch booted <bundle-id> -alarmScreenshot shake
//    simctl launch booted <bundle-id> -alarmScreenshot balanceBall
//    simctl launch booted <bundle-id> -alarmScreenshot blockDrop
//    simctl launch booted <bundle-id> -alarmScreenshot homeAssistant
//
//  Append ":mission" to jump straight past the landing page (e.g. "math:mission").
//  No effect in Release builds.
//

#if DEBUG
import AVFoundation
import SwiftData
import SwiftUI

struct AlarmScreenshotHost: View {
    let screen: String

    init(screen: String) {
        self.screen = screen
        // The harness bypasses the app root, which is where preset seeding
        // normally happens — without this the sim has no home wallpaper and every
        // alarm screenshot lands on flat black/white, hiding how these screens
        // actually read over a theme photo. Seeded in `init` (not `onAppear`) so
        // the wallpaper exists before ActiveAlarmView loads it.
        DeviceSettings.shared.seedBuiltInPresetsIfNeeded()
    }

    var body: some View {
        ActiveAlarmView(
            alarm: Self.sampleAlarm(for: screen),
            settings: DeviceSettings.shared,
            onDismiss: {},
            onSnooze: {},
            debugStartInMission: screen.contains(":mission")
        )
    }

    private static func sampleAlarm(for screen: String) -> Alarm {
        let key = screen.split(separator: ":").first.map(String.init) ?? screen
        let type: MissionType
        switch key {
        case "math":          type = .math
        case "shake":         type = .shake
        case "balanceBall":   type = .balanceBall
        case "blockDrop":     type = .blockDrop
        case "homeAssistant": type = .homeAssistant
        case "alert":         type = .alert
        default:              type = .none
        }
        var mission = Mission(type: type)
        if type == .alert {
            // Realistic sample so the alert card screenshot shows a title +
            // message instead of a bare icon. `alert:long` swaps in a
            // multi-paragraph NWS-style body to exercise the scrolling card and
            // its leading text alignment:
            //   simctl launch booted <bundle-id> -alarmScreenshot alert:long
            if screen.contains(":long") {
                mission.alertTitle = "Severe Thunderstorm Warning"
                mission.alertMessage = """
                The National Weather Service has issued a Severe Thunderstorm Warning for northern Oakland County until 3:15 AM EDT.

                At 2:41 AM, a severe thunderstorm was located near Clarkston, moving east at 45 mph. Wind gusts to 70 mph and quarter-size hail are expected with this storm.

                HAZARD: 70 mph wind gusts and 1 inch hail. SOURCE: Radar indicated. IMPACT: Hail damage to vehicles is expected. Expect wind damage to roofs, siding and trees.

                Move to an interior room on the lowest floor of a building. People outside should seek shelter immediately.
                """
            } else {
                mission.alertTitle = "Motion Detected"
                mission.alertMessage = "Motion was detected in the back yard while the alarm is armed. Check the camera feed."
            }
        }
        return Alarm(label: "Wake Up", mission: mission)
    }
}

/// Renders an active alarm driven by a synthetic 3-mission sequence
/// (math → tap ×10 → shake) so the slot machine — including a mid-sequence Tap
/// slot rendered as a full-screen TapMissionView — can be exercised/screenshotted
/// in the simulator without a real alarm firing:
///   simctl launch booted <bundle-id> -missionSequenceDebug
/// Starts straight in the mission screen; completing each slot advances to the next
/// and only the final slot dismisses. No effect in Release builds.
struct MissionSequenceDebugHost: View {
    var body: some View {
        ActiveAlarmView(
            alarm: Self.sequenceAlarm(),
            settings: DeviceSettings.shared,
            onDismiss: {},
            onSnooze: {},
            debugStartInMission: true
        )
    }

    private static func sequenceAlarm() -> Alarm {
        // Slot 1 stays in `mission` (math); slots 2..5 go in `extraMissions`. The
        // middle Tap ×10 slot exercises the mid-sequence tap screen.
        let alarm = Alarm(label: "Wake Up", mission: Mission(type: .math))
        var tap = Mission(type: .none)
        tap.tapDismissMode = .tap
        tap.tapCount = 10
        alarm.extraMissions = [tap, Mission(type: .shake)]
        return alarm
    }
}

/// Renders an active alarm for a missionless "Tap" alarm so the landing-page
/// dismiss chip (tap-count counter or hold-to-dismiss) can be screenshotted. The
/// tap/hold gate lives on the LANDING page (not a mission sub-view), so this
/// starts on the landing screen:
///   simctl launch booted <bundle-id> -tapMissionDebug 10      (10-tap counter)
///   simctl launch booted <bundle-id> -tapMissionDebug hold    (hold-to-dismiss)
/// No effect in Release builds.
struct TapMissionDebugHost: View {
    let mode: String

    var body: some View {
        ActiveAlarmView(
            alarm: Self.tapAlarm(mode: mode),
            settings: DeviceSettings.shared,
            onDismiss: {},
            onSnooze: {},
            debugStartInMission: false
        )
    }

    private static func tapAlarm(mode: String) -> Alarm {
        var m = Mission(type: .none)
        if mode.lowercased() == "hold" {
            m.tapDismissMode = .hold
            m.tapHoldDuration = 3
        } else {
            m.tapDismissMode = .tap
            m.tapCount = Int(mode) ?? 10
        }
        return Alarm(label: "Wake Up", mission: m)
    }
}

/// Presents the mission slot editor sheet directly (shake mission, slot 1) so its
/// layout can be screenshotted without tapping through the editor:
///   simctl launch booted <bundle-id> -missionSheetDebug
struct MissionSheetDebugHost: View {
    /// Optional type argument: `-missionSheetDebug meteor|math|balanceBall|…`
    /// (defaults to shake).
    private static var argType: MissionType {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-missionSheetDebug"),
              let raw = args.dropFirst(idx + 1).first else { return .shake }
        switch raw {
        case "meteor":      return .meteor
        case "math":        return .math
        case "balanceBall": return .balanceBall
        case "blockDrop":   return .blockDrop
        case "none":        return .none
        default:            return .shake
        }
    }

    @State private var mission = Mission(type: MissionSheetDebugHost.argType)
    @State private var extraMissions: [Mission] = []
    @State private var useCustomGrace = false
    @State private var customGrace: Double = 0
    @State private var request: MissionSlotEditRequest? = MissionSlotEditRequest(target: .slot(0))

    var body: some View {
        Color.clear
            .sheet(item: $request) { req in
                MissionSlotEditorSheet(
                    target: req.target,
                    mission: $mission,
                    extraMissions: $extraMissions,
                    useCustomGracePeriod: $useCustomGrace,
                    customGracePeriod: $customGrace,
                    settings: DeviceSettings.shared,
                    // -mqttOff shows the slot-1 HA tile in its disabled state.
                    mqttEnabled: !ProcessInfo.processInfo.arguments.contains("-mqttOff")
                )
                .onAppear {
                    // Optional "-sheetScroll <y>" arg scrolls the sheet's form so
                    // below-the-fold rows (e.g. Try It Out) can be screenshotted.
                    let args = ProcessInfo.processInfo.arguments
                    guard let idx = args.firstIndex(of: "-sheetScroll"),
                          let y = args.dropFirst(idx + 1).first.flatMap({ Double($0) }) else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                        for window in scenes.flatMap(\.windows) {
                            if let scrollView = Self.deepestScrollView(in: window) {
                                let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                                scrollView.setContentOffset(CGPoint(x: 0, y: min(CGFloat(y), maxY)), animated: false)
                                return
                            }
                        }
                    }
                }
            }
    }

    /// Finds the most deeply nested scroll view (the sheet's Form, not any outer one).
    private static func deepestScrollView(in view: UIView) -> UIScrollView? {
        var found: UIScrollView? = view as? UIScrollView
        for sub in view.subviews {
            if let deeper = deepestScrollView(in: sub) { found = deeper }
        }
        return found
    }
}

/// Exercises the ALARM fire audio sequence with a radio stream + fade-in,
/// printing stream/wav volumes every 2s so the ramp can be verified end-to-end:
///   simctl launch --console-pty booted <bundle-id> -radioFadeDebug
struct RadioFadeDebugHost: View {
    var body: some View {
        Text("radio fade debug — see console")
            .task {
                let url = "https://ice1.somafm.com/groovesalad-128-mp3"
                print("🧪 [radioFadeDebug] begin — 20s fade, stream \(url)")
                VolumeManager.shared.prepareForFadeIn(to: 0.5)
                await AlarmSoundPlayer.shared.play(soundID: "Solarpsychedelic", initialVolume: 0.0)
                print("🧪 [radioFadeDebug] wav playing=\(AlarmSoundPlayer.shared.isPlaying)")
                RadioAlarmStreamer.shared.beginAttempt(stationID: nil, stationName: "SomaFM", urlString: url)
                try? await Task.sleep(for: .seconds(1))
                await RadioAlarmStreamer.shared.waitForConfirmation(upTo: 10)
                VolumeManager.shared.startPlayerFadeIn(duration: 20)
                for i in 1...12 {
                    try? await Task.sleep(for: .seconds(2))
                    let sv = RadioAlarmStreamer.shared.currentStreamVolume.map { String(format: "%.2f", $0) } ?? "nil"
                    let wv = AlarmSoundPlayer.shared.currentPlayerVolume.map { String(format: "%.2f", $0) } ?? "nil"
                    print("🧪 [radioFadeDebug] t=\(i * 2)s streaming=\(RadioAlarmStreamer.shared.isStreaming) streamVol=\(sv) wavVol=\(wv)")
                }
                AlarmSoundPlayer.shared.stop()
                print("🧪 [radioFadeDebug] done")
            }
    }
}

/// Exercises the radio SLEEP fade-out: plays a stream, arms a 25s sleep timer
/// with a 15s fade, and prints state/volume every 2s until the auto-stop:
///   simctl launch --console-pty booted <bundle-id> -radioSleepFadeDebug
struct RadioSleepFadeDebugHost: View {
    var body: some View {
        Text("radio sleep fade debug — see console")
            .task {
                let station = RadioStation(
                    id: "debug-somafm", name: "SomaFM Groove Salad",
                    streamURL: "https://ice1.somafm.com/groovesalad-128-mp3",
                    faviconURL: nil, country: "", tags: "", codec: "MP3", bitrate: 128)
                let m = RadioPlayerManager.shared
                m.setVolume(0.6)
                let ok = m.play(station: station)
                print("🧪 [radioSleepFadeDebug] play started=\(ok); arming 25s timer, 15s fade")
                m.setSleepTimer(end: Date().addingTimeInterval(25), fadeOut: 15)
                for i in 1...18 {
                    try? await Task.sleep(for: .seconds(2))
                    let vol = m.debugPlayerVolume.map { String(format: "%.2f", $0) } ?? "nil"
                    print("🧪 [radioSleepFadeDebug] t=\(i * 2)s state=\(m.state) vol=\(vol)")
                }
                print("🧪 [radioSleepFadeDebug] done")
            }
    }
}

/// Renders the Alarm Defaults page directly (default mission/snooze/skip):
///   simctl launch booted <bundle-id> -alarmDefaultsDebug
struct AlarmDefaultsDebugHost: View {
    var body: some View {
        NavigationStack {
            AlarmDefaultsView(settings: DeviceSettings.shared)
        }
        .appAppearanceTheme(DeviceSettings.shared)
    }
}

/// Renders the Settings screen directly for UI-verification screenshots:
///   simctl launch booted <bundle-id> -settingsDebug
///
/// `appAppearanceTheme` is what the real app wraps this screen in (the root
/// `AppAccentTint`, plus the per-sheet modifier on `AlarmListView`'s sheet
/// router). Without it the harness renders with NO ambient tint, so every stock
/// control falls back to system green/blue and the screenshot lies about the
/// accent — which is exactly the check these shots are used for (al-nl9).
struct SettingsDebugHost: View {
    var body: some View {
        SettingsView(settings: DeviceSettings.shared, storeManager: StoreManager.shared)
            .appAppearanceTheme(DeviceSettings.shared)
            .onAppear {
                // Optional "-settingsScroll <y>" jumps to a fixed offset so
                // below-the-fold sections (App Persistence) can be
                // screenshotted deterministically — same hook the alarm editor
                // harness uses.
                let args = ProcessInfo.processInfo.arguments
                guard let idx = args.firstIndex(of: "-settingsScroll"),
                      let y = args.dropFirst(idx + 1).first.flatMap({ Double($0) }) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    for window in scenes.flatMap(\.windows) {
                        if let scrollView = AlarmEditorDebugHost.firstScrollView(in: window) {
                            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                            scrollView.setContentOffset(CGPoint(x: 0, y: min(CGFloat(y), maxY)), animated: false)
                            return
                        }
                    }
                }
            }
    }
}

/// Renders the theme accent picker sheet directly, so the commands-style grid,
/// the custom well and the reset row can be screenshotted without tapping
/// through Settings:
///   simctl launch booted <bundle-id> -themeAccentDebug
///
/// Add "-themeAccentDark" to edit the dark-mode slot instead of light — the two
/// are separate stored values, so both are worth shooting.
struct ThemeAccentDebugHost: View {
    var body: some View {
        let dark = ProcessInfo.processInfo.arguments.contains("-themeAccentDark")
        let expanded = ProcessInfo.processInfo.arguments.contains("-themeAccentExpanded")
        ThemeAccentPickerSheet(settings: DeviceSettings.shared,
                               editingScheme: dark ? .dark : .light,
                               themeName: "Neon Silk",
                               startExpanded: expanded)
    }
}

/// Renders the custom colour picker directly, so the SB field, hue slider,
/// preview and Done button can be screenshotted without tapping through a well:
///   simctl launch booted <bundle-id> -customColorPickerDebug
struct CustomColorPickerDebugHost: View {
    var body: some View {
        CustomColorPickerSheet(
            initial: Color(red: 0.35, green: 0.34, blue: 0.84),
            onPick: { _ in },
            onFinish: {}
        )
    }
}

/// Renders the alarm editor with a 2-slot sequence — slot 1 Home Assistant (with a
/// Shake fallback) plus slot 2 Math — so the five-box slot row (boxes 1–2 filled as
/// [1: HA] [2: Math], boxes 3–5 empty) and the slot pop-out can be screenshotted.
/// The HA fallback is now chosen inside the slot-1 editor sheet, not a Backup box:
///   simctl launch booted <bundle-id> -alarmEditorDebug
struct AlarmEditorDebugHost: View {
    @State private var alarm: Alarm = {
        var mission = Mission(type: .homeAssistant)
        mission.haFallbackMission = .shake
        let alarm = Alarm(label: "HA Debug", mission: mission)
        // Non-zero so the editor's MQTT-index footer renders — it is hidden for
        // alarms that have never been published, which a bare harness alarm is.
        alarm.alarmIndex = 7
        // Slot 2 (an extra) is a Math mission so the multi-slot row is exercised.
        alarm.extraMissions = [Mission(type: .math)]
        // Legacy weather flag → `afterAlarmActions` derives [.weather], so the After
        // Alarm grid opens with a filled Weather card for screenshots. Notes text
        // additionally derives [.notes], exercising the two-row grid.
        alarm.showWeatherAfterAlarm = true
        alarm.alarmScreenNotes = "Take the trash out before 8."
        return alarm
    }()

    var body: some View {
        NavigationStack {
            AlarmEditorView(
                alarm: alarm,
                settings: DeviceSettings.shared,
                storeManager: StoreManager.shared
            )
        }
        // Match the real presentation environment — see SettingsDebugHost.
        .appAppearanceTheme(DeviceSettings.shared)
        .onAppear {
            // Swipe Commands is gated on the command widget being on, and its
            // rows need a library to point at. Seeded ONLY for that section so
            // other -editorScroll offsets keep their existing form layout.
            if AlarmEditorSection.debugPreexpanded == .swipeCommands {
                CommandDebugSeed.apply(widgetEnabled: true)
            }
            // Optional "-editorScroll <y>" arg jumps the form to a fixed offset so
            // below-the-fold sections can be screenshotted deterministically.
            let args = ProcessInfo.processInfo.arguments
            guard let idx = args.firstIndex(of: "-editorScroll"),
                  let y = args.dropFirst(idx + 1).first.flatMap({ Double($0) }) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                for window in scenes.flatMap(\.windows) {
                    if let scrollView = Self.firstScrollView(in: window) {
                        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                        scrollView.setContentOffset(CGPoint(x: 0, y: min(CGFloat(y), maxY)), animated: false)
                        return
                    }
                }
            }
        }
    }

    /// Shared with `SettingsDebugHost`, which needs the same scroll hook.
    static func firstScrollView(in view: UIView) -> UIScrollView? {
        // The Form itself is UICollectionView-backed on modern iOS, and the
        // mission/after-alarm card grids are ALSO (non-scrolling) collection
        // views — so pick the COLLECTION VIEW with the largest content height:
        // the Form dwarfs the little grids. Restricting to collection views also
        // skips the wheel time picker's internal UIScrollView, which on newer iOS
        // reports a taller contentSize than the Form and hijacked the offset.
        var best: UICollectionView? = nil
        func walk(_ v: UIView) {
            if let collection = v as? UICollectionView,
               collection.contentSize.height > (best?.contentSize.height ?? 0) {
                best = collection
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return best
    }
}

/// Renders the Verse of the Day card full-screen with today's verse, for visual
/// verification of the (not-yet-wired) After-Alarm verse experience:
///   simctl launch booted <bundle-id> -verseDebug
/// Triggers a (forced, throttle-bypassing) refresh attempt first, then displays
/// whatever `verseForToday()` resolves — a cached manifest verse + image when
/// online, or the bundled public-domain fallback over a generated gradient when
/// offline. No effect in Release builds.
struct VerseDebugHost: View {
    @State private var verse: VerseOfDay = VerseOfDayService.shared.verseForToday()

    var body: some View {
        VerseOfDayCardView(verse: verse, onContinue: {})
            .onAppear {
                // Attempt a fresh fetch, then re-read once it has had a moment to
                // land on disk. Offline, this is a no-op and the fallback shows.
                VerseOfDayService.shared.refreshIfNeeded(force: true)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    verse = VerseOfDayService.shared.verseForToday()
                }
            }
    }
}

/// Renders the full After-Alarm flow (`AfterAlarmFlowView`) with a synthetic
/// [verse, weather] alarm so the step-through can be screenshotted:
///   simctl launch booted <bundle-id> -afterAlarmDebug
/// Tap the verse card's Continue to advance to the weather card. Uses today's
/// verse (forces a refresh attempt first; falls back to a bundled verse
/// offline) and no wallpaper. No effect in Release builds.
/// Renders the After-Alarm editor section standalone — the two-row grid with a
/// filled Notes card — and pops one action's config sheet after a beat (pass
/// -noSheet to keep just the grid, or an action id to pick which sheet opens):
///   simctl launch booted <bundle-id> -afterAlarmSectionDebug [notes|verse|weather|appLink] [-noSheet]
/// Each sheet carries that action's "Preview …" launcher, so this is also how the
/// preview buttons get screenshotted — add -autoPreview to open that action's
/// preview immediately (the sim can't be tapped from the CLI). No effect in
/// Release builds.
struct AfterAlarmSectionDebugHost: View {
    /// Which action's config sheet auto-opens (raw value; defaults to notes).
    var sheetAction: String = AfterAlarmAction.notes.rawValue

    @State private var actions: [AfterAlarmAction] = [.notes, .verse, .weather, .appLink]
    @State private var edit: AfterAlarmEditRequest?
    /// Mirrors the real editors: Notes opens the direct full-screen editor, not the
    /// config sheet — so this harness exercises the same (single-screen) path.
    @State private var showNotesEditor = false
    @State private var notesText = "Take the trash out before 8."
    // Seed the sample commands + wire the first two note slots SYNCHRONOUSLY here
    // (not in onAppear): mutating this @State from onAppear races the async sheet
    // presentation and gets discarded before the sheet reads it.
    @State private var noteCommandIDs: [String?] = AfterAlarmSectionDebugHost.seededNoteCommandIDs()
    // Seeded so the appLink sheet (and its preview, whose chips really open the
    // link) has something concrete to show.
    @State private var dismissURI = "shortcuts://run-shortcut?name=Good%20Morning"
    @State private var snoozeURI = ""

    var body: some View {
        NavigationStack {
            Form {
                AfterAlarmSectionView(
                    actions: $actions,
                    settings: DeviceSettings.shared,
                    onEdit: { target in
                        if target == .action(.notes) {
                            showNotesEditor = true
                        } else {
                            edit = AfterAlarmEditRequest(target: target)
                        }
                    }
                )
            }
            .sheet(item: $edit) { request in
                AfterAlarmActionEditorSheet(
                    target: request.target,
                    actions: $actions,
                    dismissAppURI: $dismissURI,
                    snoozeAppURI: $snoozeURI,
                    notesText: $notesText,
                    noteCommandIDs: $noteCommandIDs,
                    settings: DeviceSettings.shared,
                    debugAutoPreview: ProcessInfo.processInfo.arguments.contains("-autoPreview")
                )
            }
            .notesAfterAlarmEditor(
                isPresented: $showNotesEditor,
                settings: DeviceSettings.shared,
                notes: $notesText,
                commandIDs: $noteCommandIDs,
                actions: $actions
            )
            .onAppear {
                guard !ProcessInfo.processInfo.arguments.contains("-noSheet") else { return }
                let target = AfterAlarmAction(rawValue: sheetAction) ?? .notes
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    // Notes → the direct editor (the real path); everything else →
                    // the config sheet.
                    if target == .notes {
                        showNotesEditor = true
                    } else {
                        edit = AfterAlarmEditRequest(target: .action(target))
                    }
                }
            }
        }
    }

    /// Ensure two sample commands exist in settings so the sheet's live preview
    /// and command slots have something to show, and return note-slot IDs wired to
    /// the first two. Mutating sim settings is acceptable in this DEBUG-only
    /// harness. Shared with the Notes-editor and picker hosts below.
    static func seededNoteCommandIDs() -> [String?] {
        if DeviceSettings.shared.mqttCommands.isEmpty {
            let coffee = MQTTCommand(name: "Coffee", icon: "cup.and.saucer.fill",
                                     iconColorRed: 1.0, iconColorGreen: 0.58, iconColorBlue: 0.0)
            var shortcut = MQTTCommand(name: "Good Morning", icon: "sun.max.fill",
                                       iconColorRed: 1.0, iconColorGreen: 0.84, iconColorBlue: 0.04)
            // One of each source so the badges/filters have something to show.
            shortcut.actionURL = "shortcuts://run-shortcut?name=Good%20Morning"
            DeviceSettings.shared.mqttCommands.append(contentsOf: [coffee, shortcut])
        }
        let ids: [String?] = DeviceSettings.shared.mqttCommands.prefix(2).map { $0.id.uuidString }
        return Array((ids + [nil, nil, nil, nil]).prefix(4))
    }
}

/// Renders the full-page Notes after-alarm step with sample notes and two
/// sample command buttons so it can be screenshotted:
///   simctl launch booted <bundle-id> -notesDebug
/// No effect in Release builds.
struct NotesDebugHost: View {
    // Deliberately LONG (20+ lines) so the full-page scroll is exercised and the
    // pinned bottom controls can be verified not to clip the text.
    private static let longNotes = """
    Morning checklist — work through top to bottom:

    1. Take the trash and recycling out before 8am — pickup is early on Tuesdays.
    2. Dentist appointment at 2:30 — leave the house by 2:00 to beat traffic.
    3. Grab the dry cleaning on the way home; ticket is in the car's glovebox.
    4. Call the plumber about the leak under the kitchen sink.
    5. Water the plants on the back porch and the fern in the office.
    6. Reply to Sarah about the weekend trip — she needs a yes/no by noon.
    7. Pick up groceries: milk, eggs, bread, coffee, spinach, chicken.
    8. Charge the drill batteries for the shelf project this evening.
    9. Move laundry to the dryer before you leave for the office.
    10. Renew the parking permit online — it expires at the end of the month.
    11. Book the vet appointment for the dog's annual shots.
    12. Send the signed lease back to the landlord before 5pm.
    13. Confirm the dinner reservation for Friday at 7:30.
    14. Back up the laptop — the drive is on the desk in the study.
    15. Set out the recycling bins for tomorrow's collection.

    If nothing above is urgent, take a breath and enjoy the coffee first.
    """

    var body: some View {
        NotesAfterAlarmView(
            notes: Self.longNotes,
            commands: [
                MQTTCommand(name: "Coffee", icon: "cup.and.saucer.fill",
                            iconColorRed: 1.0, iconColorGreen: 0.58, iconColorBlue: 0.0),
                MQTTCommand(name: "Lights", icon: "lightbulb.fill",
                            iconColorRed: 1.0, iconColorGreen: 0.84, iconColorBlue: 0.04),
            ],
            wallpaper: nil,
            onContinue: {}
        )
    }
}

/// Presents the DIRECT Notes after-alarm editor (`NotesAfterAlarmEditorView`)
/// with sample text + two wired command slots, so its three key states can be
/// screenshotted deterministically:
///   simctl launch booted <bundle-id> -notesEditorDebug           (keyboard hidden)
///   simctl launch booted <bundle-id> -notesEditorDebug keyboard  (keyboard up, commands hidden)
///   simctl launch booted <bundle-id> -notesEditorDebug jiggle    (command grid in edit mode)
/// No effect in Release builds.
struct NotesEditorDebugHost: View {
    /// "" = keyboard hidden (full command section), "keyboard" = keyboard up
    /// (command section hidden entirely), "jiggle" = grid in edit mode.
    var mode: String = ""

    @State private var commandIDs: [String?] = AfterAlarmSectionDebugHost.seededNoteCommandIDs()

    var body: some View {
        NotesAfterAlarmEditorView(
            initialNotes: "Take the trash out before 8.\n\nDentist at 2:30 — leave by 2.",
            initialCommandIDs: commandIDs,
            settings: DeviceSettings.shared,
            onSave: { _, _ in },
            onCancel: { },
            debugFocusNote: mode == "keyboard",
            debugSlotsEditMode: mode == "jiggle"
        )
    }
}

/// Opens the unified `CommandPickerSheet` directly for a given destination so the
/// shared picker can be screenshotted from more than one context:
///   simctl launch booted <bundle-id> -commandPickerDebug noteSlot   (from a Notes button)
///   simctl launch booted <bundle-id> -commandPickerDebug swipeLeft  (from alarm Swipe Left)
/// Seeds two sample commands and pre-assigns the first so the checkmark shows.
/// No effect in Release builds.
struct CommandPickerDebugHost: View {
    var context: String = "noteSlot"

    @State private var currentID: UUID? = {
        _ = AfterAlarmSectionDebugHost.seededNoteCommandIDs()
        return DeviceSettings.shared.mqttCommands.first?.id
    }()
    @State private var present = false

    private var destination: CommandAssignmentDestination {
        switch context {
        case "swipeLeft":  return .alarmSwipeLeft
        case "swipeRight": return .alarmSwipeRight
        default:           return .noteSlot(1)
        }
    }

    var body: some View {
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
            .sheet(isPresented: $present) {
                CommandPickerSheet(
                    destination: destination,
                    currentID: currentID,
                    settings: DeviceSettings.shared,
                    onPick: { currentID = $0 }
                )
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { present = true }
            }
    }
}

/// Opens the shared `CommandFormView` directly in EDIT mode against a seeded
/// sample command, or the delete confirmation over it, so those states can be
/// screenshotted:
///   simctl launch booted <bundle-id> -commandFormDebug ha        (edit a Home Assistant command)
///   simctl launch booted <bundle-id> -commandFormDebug shortcut  (edit a Shortcut command)
///   simctl launch booted <bundle-id> -commandFormDebug delete    (edit + delete usage warning)
/// The `ha` seed also turns on MQTT + widget Alarm Control and sets a "Garage"
/// zone, so the zone-named security section renders (scroll down to see it).
/// No effect in Release builds.
struct CommandFormDebugHost: View {
    var mode: String = "ha"

    @State private var commandID: UUID = CommandFormDebugHost.seed()

    var body: some View {
        NavigationStack {
            CommandFormView(mode: .edit(commandID),
                            settings: DeviceSettings.shared,
                            debugAutoDeleteConfirm: mode == "delete")
        }
    }

    /// Seeds one sample command of the requested source and, for the delete case,
    /// assigns it to a couple of places so the usage warning has something to
    /// report. Returns the command's id.
    private static func seed() -> UUID {
        let modeArg = ProcessInfo.processInfo.arguments.firstIndex(of: "-commandFormDebug")
            .flatMap { ProcessInfo.processInfo.arguments.dropFirst($0 + 1).first } ?? "ha"
        let settings = DeviceSettings.shared

        // Seed the icon/color memory so the palette grids screenshot the way a
        // real user sees them — their own recent choices first, not the raw
        // catalog order. Debug-only, so this never touches a shipping install.
        CommandPaletteRecents.clearAll()
        for icon in ["cup.and.saucer.fill", "lightbulb.fill", "lock.fill"].reversed() {
            CommandPaletteRecents.recordIcon(icon)
        }
        for color in ["Crimson", "Amber", "Teal"].reversed() {
            CommandPaletteRecents.recordColorName(color)
            // The color grid now renders the hex list, so seed that too — plus a
            // custom mix, to show that recents remember colors that aren't presets.
            if let preset = MQTTCommand.presetColor(named: color) {
                CommandPaletteRecents.recordColorHex(red: preset.r, green: preset.g, blue: preset.b)
            }
        }
        CommandPaletteRecents.recordColorHex(red: 0.42, green: 0.19, blue: 0.63) // a custom mix

        var command: MQTTCommand
        switch modeArg {
        case "shortcut":
            command = MQTTCommand(name: "Good Morning", icon: "sun.max.fill",
                                  iconColorRed: 1.0, iconColorGreen: 0.58, iconColorBlue: 0.0)
            command.actionURL = "shortcuts://run-shortcut?name=Good%20Morning"
        default:
            command = MQTTCommand(name: "Start Coffee", icon: "cup.and.saucer.fill",
                                  iconColorRed: 0.64, iconColorGreen: 0.52, iconColorBlue: 0.37)
            command.armAction = .disarm
            // The security section only renders with HA + widget alarm control on;
            // a non-default zone proves the header name is the user's, not "Home".
            settings.mqttEnabled = true
            settings.hassWidgetAlarmEnabled = true
            settings.armZone = "Garage"
        }
        settings.mqttCommands.append(command)

        if modeArg == "delete" {
            // Assign it to two places so the warning reads a real usage list.
            settings.widgetSwipeLeftCommandID = command.id
            if let container = AlarmWindowManager.shared.modelContainer {
                let alarm = Alarm(label: "Morning Alarm")
                alarm.alarmScreenCommandID1 = command.id.uuidString
                container.mainContext.insert(alarm)
                try? container.mainContext.save()
            }
        }
        return command.id
    }
}

/// The command widget's settings page — widget-only concerns: the gesture
/// assignments (Swipe Left / Swipe Right / Double Tap) and the Widget List
/// (which commands show in the expanded list, and in what order).
///
/// `off` turns the widget itself off, which collapses the widget-only sections —
/// use it to check "Manage Commands" stays reachable, since alarm swipes and
/// Notes buttons use the same library whether or not the widget is shown.
///
/// `noalarm` drops the Alarm Control rows, which is the only way to get the
/// Widget List section above the fold for a screenshot.
///
///   simctl launch booted <bundle-id> -commandWidgetDebug
///   simctl launch booted <bundle-id> -commandWidgetDebug off
///   simctl launch booted <bundle-id> -commandWidgetDebug noalarm
struct CommandWidgetDebugHost: View {
    init(mode: String = "on") {
        CommandDebugSeed.apply(widgetEnabled: mode != "off",
                               alarmControl: mode != "noalarm")
    }

    var body: some View {
        NavigationStack {
            CommandWidgetSettingsView(settings: DeviceSettings.shared)
        }
    }
}

/// The command LIBRARY — what "Manage Commands" and Settings › Commands now
/// open. Sample commands seeded so the list, the Add row, and Confirm Commands
/// all render:
///   simctl launch booted <bundle-id> -commandLibraryDebug
struct CommandLibraryDebugHost: View {
    init() {
        CommandDebugSeed.apply(widgetEnabled: true)
    }

    var body: some View {
        NavigationStack {
            CommandLibraryView(settings: DeviceSettings.shared)
        }
    }
}

/// First-launch onboarding, rendered directly. A plain reinstall does NOT bring
/// it back — `hasCompletedOnboarding` is Keychain/iCloud-backed and survives
/// uninstall — so this is the only way to see it again:
///   simctl launch booted <bundle-id> -onboardingDebug
struct OnboardingDebugHost: View {
    var body: some View {
        OnboardingView()
    }
}

/// The data-preferences screen on its own — step 2 of onboarding, and the
/// one-off prompt existing users get. `legacy` renders the standalone wording:
///   simctl launch booted <bundle-id> -dataPrefsDebug
///   simctl launch booted <bundle-id> -dataPrefsDebug legacy
struct DataPreferencesDebugHost: View {
    var mode: String = ""

    var body: some View {
        DataPreferencesView(isPartOfOnboarding: mode != "legacy") { }
    }
}

/// The Sound Manager, full or scoped to custom sleep sounds — the two states
/// that differ after "Add Custom Sound" got its own single-purpose version:
///   simctl launch booted <bundle-id> -soundManagerDebug
///   simctl launch booted <bundle-id> -soundManagerDebug custom
struct SoundManagerDebugHost: View {
    var mode: String = ""

    var body: some View {
        NavigationStack {
            if mode == "custom" {
                SoundManagerView(initialCategory: .sleepSound, customOnly: true)
            } else {
                SoundManagerView()
            }
        }
    }
}

/// The radio browser, for checking its Top / Near You scope tiles against the
/// other segmented choosers:
///   simctl launch booted <bundle-id> -radioBrowserDebug
struct RadioBrowserDebugHost: View {
    var body: some View {
        NavigationStack {
            RadioBrowserView(settings: DeviceSettings.shared)
        }
    }
}

/// Shared seeding for the command-management harness states.
enum CommandDebugSeed {
    static func apply(widgetEnabled: Bool, alarmControl: Bool = true) {
        let settings = DeviceSettings.shared
        settings.mqttEnabled = true
        settings.armButtonEnabled = widgetEnabled
        settings.hassWidgetAlarmEnabled = alarmControl
        settings.armZone = "Garage"
        // Seeded unconditionally — a previous harness run leaves commands behind,
        // and an isEmpty guard then skipped the gesture assignments, rendering the
        // section as three empty slots.
        var coffee = MQTTCommand(name: "Start Coffee", icon: "cup.and.saucer.fill",
                                 iconColorRed: 0.64, iconColorGreen: 0.52, iconColorBlue: 0.37)
        coffee.armAction = .disarm
        var goodMorning = MQTTCommand(name: "Good Morning", icon: "sun.max.fill",
                                      iconColorRed: 1.0, iconColorGreen: 0.58, iconColorBlue: 0.0)
        goodMorning.actionURL = "shortcuts://run-shortcut?name=Good%20Morning"
        goodMorning.showInList = false
        settings.mqttCommands = [coffee, goodMorning]
        settings.widgetSwipeLeftCommandID = coffee.id
        settings.widgetDoubleTapCommandID = goodMorning.id
        settings.widgetSwipeRightCommandID = nil
    }
}

struct AfterAlarmDebugHost: View {
    @State private var verse: VerseOfDay = VerseOfDayService.shared.verseForToday()

    var body: some View {
        AfterAlarmFlowView(
            steps: [.verse, .weather],
            verse: verse,
            wallpaper: nil,
            wallpaperIsDark: false,
            onFinished: {}
        )
        .onAppear {
            VerseOfDayService.shared.refreshIfNeeded(force: true)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                verse = VerseOfDayService.shared.verseForToday()
            }
        }
    }
}

/// Fires a REAL alarm through the production in-app timer path (the one that
/// rings when the app is alive — NOT AlarmKit, NOT the isolated -radioFadeDebug
/// sequence) and prints the whole volume picture every 2s, so a fade can be
/// audited exactly as the user experiences it:
///   simctl launch --console-pty booted <bundle-id> -alarmFireFadeDebug [tone|radio]
///
/// Builds a 50%-volume alarm with a 1-minute fade, schedules it via
/// `LocalNotificationScheduler.scheduleAlarm` with the debug quick-fire override
/// (+5s), then logs player volume, the volume the fade curve WANTS, system
/// output volume, and the fade flags. Any divergence between "player" and
/// "wants" is a path stomping the ramp. No effect in Release builds.
struct AlarmFireFadeDebugHost: View {
    /// "radio" attaches a station so the streamer path is exercised too.
    var mode: String = "tone"

    var body: some View {
        Text("alarm fire fade debug — see console")
            .task {
                let settings = DeviceSettings.shared
                // ISOLATE: any other alarm in the store would ALSO quick-fire and
                // stomp the shared AlarmSoundPlayer, masking what this fade does.
                settings.debugQuickAlarmEnabled = false
                // Also clear any alarm left ringing by a previous run — the
                // force-kill recovery path would restart ITS sound at full volume
                // on launch and stomp the ramp (seen while building this harness).
                AlarmSoundPlayer.shared.stop()
                VolumeManager.shared.cancelFadeIn()
                PendingAlarmStore.shared.clearActiveRingingAlarm()
                if let container = AlarmWindowManager.shared.modelContainer,
                   let existing = try? container.mainContext.fetch(FetchDescriptor<Alarm>()) {
                    for other in existing {
                        await LocalNotificationScheduler.shared.cancelAlarm(other)
                        container.mainContext.delete(other)
                    }
                    try? container.mainContext.save()
                    print("🧪 [fireFade] cleared \(existing.count) existing alarm(s)")
                }

                let alarm = Alarm(time: Date().addingTimeInterval(60), label: "FadeDebug")
                // Pick a sound that definitely resolves to a file on this install —
                // a bare "Default" on a freshly-installed sim has no seeded preset,
                // playback fails, and the retry path CANCELS the fade (so the run
                // measures nothing).
                if let sound = AlarmSoundManager.shared.getAllSounds().first(where: { $0.fileURL != nil }) {
                    alarm.soundName = sound.id
                    print("🧪 [fireFade] using sound '\(sound.id)'")
                }
                alarm.customVolumeLevel = 0.5
                alarm.customFadeInEnabled = true
                alarm.customFadeInDuration = 1     // 1 minute
                if mode == "radio" {
                    alarm.radioStationName = "SomaFM"
                    alarm.radioStationURL = "https://ice1.somafm.com/groovesalad-128-mp3"
                }
                // Insert so the fire path's DB lookups (mission, fade resolution,
                // window presentation) behave exactly as they do for a real alarm.
                if let container = AlarmWindowManager.shared.modelContainer {
                    container.mainContext.insert(alarm)
                    try? container.mainContext.save()
                }
                // Quick-fire override: scheduleAlarm ignores nextFireDate and
                // arms the in-app timer for +5s.
                settings.debugQuickAlarmEnabled = true
                settings.debugQuickAlarmDelay = 5

                print("🧪 [fireFade] mode=\(mode) volume=50% fade=60s — firing in 5s via the real timer path")
                await LocalNotificationScheduler.shared.scheduleAlarm(alarm)

                for i in 1...40 {
                    try? await Task.sleep(for: .seconds(2))
                    let player = AlarmSoundPlayer.shared.currentPlayerVolume
                        .map { String(format: "%.2f", $0) } ?? "nil"
                    let stream = RadioAlarmStreamer.shared.currentStreamVolume
                        .map { String(format: "%.2f", $0) } ?? "-"
                    let wants = VolumeManager.shared.playerVolumeForCurrentFade()
                    let system = AVAudioSession.sharedInstance().outputVolume
                    print(String(
                        format: "🧪 [fireFade] t=%2ds player=%@ stream=%@ wants=%.2f system=%.2f fadeActive=%@ playing=%@",
                        i * 2, player, stream, wants, system,
                        VolumeManager.shared.fadeActive ? "Y" : "N",
                        AlarmSoundPlayer.shared.isPlaying ? "Y" : "N"))
                }
                AlarmSoundPlayer.shared.stop()
                settings.debugQuickAlarmEnabled = false
                print("🧪 [fireFade] done")
            }
    }
}

/// Alarm rows carrying 1 / 3 / 5 missions, so the multi-mission slot count on the
/// home row can be checked — including on a NARROW device, where the count sits on
/// the same line as a 48pt time and the MQTT badge and is the thing most likely to
/// clip:
///   simctl launch booted <bundle-id> -missionCountDebug
struct MissionCountDebugHost: View {
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(Self.samples(), id: \.persistentModelID) { alarm in
                    AlarmRow(
                        alarm: alarm,
                        settings: DeviceSettings.shared,
                        mqttManager: HAIntegrationRouter.shared,
                        renameText: $renameText,
                        isRenameFocused: $renameFocused,
                        onSkip: {}, onUnskip: {}, onDelete: {}, onTap: {}
                    )
                }
            }
            .navigationTitle("Alarms")
        }
    }

    /// One of each shape the badge has to handle: a single mission, a 3-slot
    /// sequence, a 5-slot sequence, a sequence that STARTS with Tap (which used to
    /// render no icon at all), and an MQTT-sourced row where the badge competes
    /// with the MQTT chip for the same line.
    private static func samples() -> [Alarm] {
        let single = Alarm(label: "Single mission", mission: Mission(type: .math))

        let three = Alarm(label: "Three missions", mission: Mission(type: .math))
        three.extraMissions = [Mission(type: .shake), Mission(type: .balanceBall)]

        let five = Alarm(label: "Five missions", mission: Mission(type: .blockDrop))
        five.extraMissions = [
            Mission(type: .shake), Mission(type: .math),
            Mission(type: .balanceBall), Mission(type: .meteor),
        ]

        var tap = Mission(type: .none)
        tap.tapCount = 5
        let tapFirst = Alarm(label: "Tap first", mission: tap)
        tapFirst.extraMissions = [Mission(type: .math), Mission(type: .shake)]

        let remote = Alarm(label: "From Home Assistant", mission: Mission(type: .shake))
        remote.extraMissions = [Mission(type: .math)]
        remote.source = "mqtt"

        return [single, three, five, tapFirst, remote]
    }
}
#endif
