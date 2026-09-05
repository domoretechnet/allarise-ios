//
//  HaWake_Alarm_V2App.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import SwiftUI
import SwiftData
import AppIntents
import CoreData
import AVFoundation

@main
struct HaWake_Alarm_V2App: App {
    // Add AppDelegate for notification handling
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Use shared singleton to avoid slow initialization
    let settings = DeviceSettings.shared

    /// Mutually exclusive first-run screens. See `launchGate`.
    private enum LaunchGate: Int, Identifiable {
        case onboarding
        case dataPreferences
        var id: Int { rawValue }
    }

    let container: ModelContainer
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var presetImportAlert: PresetImportAlert?
    @State private var showTermsUpdate = false
    /// Set at launch when the terms sheet and the data-preferences prompt are
    /// BOTH pending. The terms sheet wins the first slot; this makes it hand off
    /// to the prompt when it closes instead of postponing it a whole launch.
    @State private var dataPreferencesDeferred = false
    /// The full-screen gate in front of the app at launch, if any.
    ///
    /// ONE piece of state driving ONE modifier, deliberately. These used to be
    /// two `@State` bools behind two stacked `.fullScreenCover` modifiers on the
    /// same view — SwiftUI honours only one cover per view, so the second was
    /// silently dead and the data-preferences prompt never appeared for existing
    /// installs. They are mutually exclusive anyway (new installs get the
    /// preferences screen as step 2 of onboarding), so an enum models it
    /// honestly and makes the collision impossible to reintroduce.
    @State private var launchGate: LaunchGate?
    @State private var pendingSoundImportURL: URL?
    @State private var soundImportName = ""
    @State private var soundImportCategory: CustomSound.Category = .alarmTone
    @State private var showingSoundImportSheet = false
    @State private var showingSoundImportPaywall = false
    /// Set in `init` (not `onAppear`) so the alert is already pending when the
    /// first frame renders — the recovery has, by definition, already happened.
    @State private var databaseRecoveryNotice: AlarmBackupStore.RecoveryNotice?

    struct PresetImportAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// Plain-language account of a database rebuild. No error codes, no jargon —
    /// the one thing the user needs to know is whether their alarms are still
    /// there, and if not, that they have to re-create them.
    static func recoveryMessage(for notice: AlarmBackupStore.RecoveryNotice) -> String {
        if notice.snapshotCount == 0 {
            return "The alarm database had to be rebuilt after it failed to open, and there was no backup to restore from. Any alarms you had set are gone and will need to be created again. Please check your alarms before relying on them tonight."
        }
        if notice.restoredCount == notice.snapshotCount {
            let plural = notice.restoredCount == 1 ? "alarm was" : "alarms were"
            return "The alarm database had to be rebuilt after it failed to open. \(notice.restoredCount) \(plural) restored from the automatic backup. Please double-check your alarm times and settings before relying on them tonight."
        }
        return "The alarm database had to be rebuilt after it failed to open. \(notice.restoredCount) of \(notice.snapshotCount) alarms could be restored from the automatic backup. Please check your alarms and re-create anything that's missing."
    }

    private func dismissDatabaseRecoveryNotice() {
        databaseRecoveryNotice = nil
        AlarmBackupStore.clearPendingNotice()
    }
    
    init() {
        let _appT = Date()
        func appElapsed(_ label: String) {
            let ms = Date().timeIntervalSince(_appT) * 1000
            print(String(format: "⏱️ [App.init] %@ — %.0f ms", label, ms))
        }
        print("⏱️ App init started at \(Date())")
        appElapsed("START")

        // Initialize onboarding / terms state SYNCHRONOUSLY so the full-screen cover is
        // already presenting when the view first renders. Relying on .onAppear here
        // leaves a brief window on fresh installs where the user can see and interact
        // with the main alarm list before the cover slides up — unacceptable because
        // they must agree to terms before using the app.
        let needsOnboarding = !DeviceSettings.shared.hasCompletedOnboarding
        let needsTermsUpdate = !needsOnboarding
            && DeviceSettings.shared.agreedTermsVersion < DeviceSettings.currentTermsVersion
        // Existing installs from before the data-preferences prompt existed see
        // it exactly once, standalone — onboarding already ran for them, so they
        // must not be sent back through it. New installs get it as step 2 of
        // onboarding instead, hence the `!needsOnboarding` guard.
        //
        // The `!needsTermsUpdate` guard keeps the two screens from stacking, but
        // both are pending at once for anyone upgrading across the terms-v6 bump
        // (which added the optional data collection this prompt asks about). So
        // the terms sheet hands off to the prompt on dismissal rather than
        // leaving it for the next cold launch — see `dataPreferencesDeferred`.
        let needsDataPreferences = !needsOnboarding
            && !needsTermsUpdate
            && !DeviceSettings.shared.hasAnsweredDataPreferences
        _dataPreferencesDeferred = State(initialValue: !needsOnboarding
            && needsTermsUpdate
            && !DeviceSettings.shared.hasAnsweredDataPreferences)
        _showTermsUpdate = State(initialValue: needsTermsUpdate)
        _launchGate = State(initialValue: needsOnboarding ? .onboarding
                                        : needsDataPreferences ? .dataPreferences
                                        : nil)
        appElapsed("onboarding state")

        // Registers the backend and observes activation — it does NOT start
        // collection. `bootstrap` calls `refreshConsent`, which starts a backend
        // only if `analyticsOptIn` is already true; in the EU consent must
        // precede collection, so nothing may run before that check.
        //
        // The backend is passed unconditionally: FirebaseAnalyticsBackend
        // compiles and runs with or without the SDK present, so adding the
        // package later activates it with no change here, and an open-source
        // checkout without Firebase behaves as a no-op.
        Analytics.shared.bootstrap(backend: FirebaseAnalyticsBackend())
        // ProductUpdatePush.refreshConsent() deliberately does NOT run here —
        // it moved to `AppDelegate.didFinishLaunchingWithOptions`, which runs
        // after this init and after the notification delegate is installed. See
        // the comment there for why registering for APNs this early cost 13–30s.
        // MetricKit is the only source for the two kills that matter to an app
        // which stays resident overnight — jetsam and the background CPU limit.
        // Neither is a "crash", so no crash reporter ever sees them. Registration
        // is free: payloads are system-delivered roughly daily, nothing polls.
        AppExitMonitor.start()
        appElapsed("analytics")

        // Ensure the Application Support directory exists before SwiftData tries to create its store.
        // On fresh installs or after Xcode redeploys, this directory may not exist yet, causing
        // CoreData to fail with errno 2 and attempt recovery (which recreates the database).
        let fileManager = FileManager.default
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            if !fileManager.fileExists(atPath: appSupport.path) {
                try? fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
                print("📁 Created Application Support directory")
            }
        }
        appElapsed("fileManager")

        // Try to create the ModelContainer normally
        do {
            print("⏱️ Creating ModelContainer...")
            let schema = Schema([Alarm.self])
            let config = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            container = try ModelContainer(for: schema, configurations: [config])
            print("✅ ModelContainer initialized successfully at \(Date())")
            AppLogger.shared.log("App launched, ModelContainer initialized (local-only)", category: .general)
        } catch {
            print("❌ Failed to create ModelContainer: \(error)")
            print("❌ Error details: \(String(describing: error))")
            AppLogger.shared.log("ModelContainer FAILED to open: \(error)", category: .general)

            // RECOVERY. Wiping the store is the only way back into a usable app,
            // but it must never be the first thing that happens and never happen
            // silently — losing every alarm without warning is worse than a slow
            // launch. Order matters:
            //   1. read the JSON snapshot the last good launch left behind,
            //   2. copy the raw store files aside (a future build with a real
            //      MigrationPlan may still be able to open them),
            //   3. only then wipe and recreate,
            //   4. put the alarms back,
            //   5. leave a notice for the UI so the user is told what happened.
            let snapshot = AlarmBackupStore.readSnapshot()
            let archive = AlarmBackupStore.archiveStoreFiles()

            print("⚠️ Clearing incompatible database due to error...")
            Self.clearIncompatibleDatabase()

            do {
                print("⚠️ Attempting to recreate container after clearing database...")
                let schema = Schema([Alarm.self])
                let config = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: false,
                    allowsSave: true,
                    cloudKitDatabase: .none
                )
                container = try ModelContainer(for: schema, configurations: [config])
                print("✅ ModelContainer recreated successfully")
            } catch {
                print("❌ Failed again: \(error)")
                fatalError("Failed to create ModelContainer: \(error)")
            }

            let snapshotAlarms = snapshot?.alarms ?? []
            let restored = AlarmBackupStore.restore(into: container, from: snapshotAlarms)
            AlarmBackupStore.setPendingNotice(
                AlarmBackupStore.RecoveryNotice(
                    date: Date(),
                    restoredCount: restored,
                    snapshotCount: snapshotAlarms.count,
                    archivePath: archive?.path,
                    errorDescription: String(describing: error)
                )
            )
            AppLogger.shared.log(
                "Database rebuilt after open failure — restored \(restored)/\(snapshotAlarms.count) alarm(s) from backup",
                category: .general
            )
        }
        appElapsed("ModelContainer")

        // Assign stable identities to alarms created before the stableID field
        // existed. Must run before ANY scheduling/recovery code touches
        // stableHash, so old alarms don't schedule under the legacy
        // session-scoped hash and orphan their AlarmKit backups.
        Self.migrateStableIDs(container: container)
        appElapsed("migrateStableIDs")

        // Repair alarms whose soundName holds a sound DISPLAY NAME instead of a
        // sound id. Must run before any scheduling/prewarming reads soundName.
        Self.migrateLegacySoundNames(container: container)
        appElapsed("migrateLegacySoundNames")

        // Mirror the (now migrated) alarms to the JSON backup. This is the copy
        // that gets restored if a future schema change makes the store
        // unopenable — see AlarmBackupStore.
        AlarmBackupStore.writeSnapshot(container: container)
        appElapsed("AlarmBackupStore.writeSnapshot")

        print("✅ Using LocalNotificationScheduler (Alarmy-style)")

        // Install observers so the AppAudioSession shadow `isActive` flag
        // stays in sync when iOS deactivates the session behind our back
        // (interruptions, media services reset). Must happen before any
        // audio code runs.
        AppAudioSession.installObservers()
        appElapsed("installObservers")

        // Start always-on audio state monitoring: compact one-line snapshots
        // on every session/route/interruption transition + a 30s heartbeat
        // (de-duped if nothing changed). Feeds the regular app log so real
        // users' audio issues can be diagnosed from exported logs.
        AudioDiagnostics.startMonitoring()
        appElapsed("AudioDiagnostics")

        // Record memory warnings and shed caches. Keep-alive keeps this process
        // resident all night, so jetsam is a real alarm-reliability risk — and
        // without this line in the log, a jetsam kill is indistinguishable from
        // a force-quit after the fact.
        MemoryPressureMonitor.start()
        appElapsed("MemoryPressureMonitor")

        // Set model container immediately so AlarmWindowManager can use it even before
        // the SwiftUI view hierarchy loads. This is critical for cold-launch scenarios
        // (e.g., CompleteMissionIntent opens the app and needs to show the alarm
        // mission screen before onAppear fires).
        AlarmWindowManager.shared.setModelContainer(container)
        appElapsed("AlarmWindowManager.setModelContainer")

        // Start network monitoring for MQTT auto-switching
        NetworkMonitor.shared.startMonitoring()
        print("✅ Network monitoring started")
        appElapsed("NetworkMonitor.startMonitoring")

        // Kick off StoreManager initialization eagerly so purchase/early-adopter
        // status is ready before the user navigates to create an alarm. Without
        // this the singleton is lazily created when SettingsView or the paywall
        // first appears, which can be several seconds after launch.
        _ = StoreManager.shared
        print("✅ StoreManager initialization kicked off")
        appElapsed("StoreManager.shared")

        // Surface any database-recovery notice (this launch's, or one left by a
        // launch that never got as far as showing it).
        _databaseRecoveryNotice = State(initialValue: AlarmBackupStore.pendingNotice)

        print("⏱️ App init completed at \(Date())")
    }
    
    /// One-time migration: assign a stableID to alarms created before the
    /// field existed. All alarm identity (AlarmKit UUIDs, timer keys,
    /// recovery blobs) derives from Alarm.stableHash, which needs stableID
    /// to be non-nil to survive relaunches. Runs synchronously in App.init,
    /// before any scheduling or recovery code executes.
    @MainActor
    static func migrateStableIDs(container: ModelContainer) {
        let context = container.mainContext
        guard let alarms = try? context.fetch(FetchDescriptor<Alarm>()) else { return }
        var migrated = 0
        for alarm in alarms where alarm.stableID == nil {
            alarm.stableID = UUID()
            migrated += 1
        }
        if migrated > 0 {
            try? context.save()
            print("✅ migrateStableIDs: assigned stableID to \(migrated) pre-existing alarm(s)")
            AppLogger.shared.log("Assigned stableID to \(migrated) pre-existing alarm(s)", category: .general)
        }
    }

    /// One-time repair: rewrite `soundName` values that hold a sound DISPLAY NAME
    /// to the sound's id.
    ///
    /// Every consumer of `soundName` resolves it with `getSound(id:)` — the field
    /// has always been an id — but the MQTT create/update handlers used to store
    /// `sound.displayName`. Since `displayName` is the file name with underscores
    /// turned into spaces, and four of the five bundled tones have underscores,
    /// an alarm created from Home Assistant stored e.g. "Alarm Clock" for the file
    /// `Alarm_Clock.wav`. That id resolves to nil and `AlarmSoundPlayer.play` then
    /// returns without playing anything — the alarm rings silent in-app.
    ///
    /// The handlers now store `sound.id`, but existing rows still carry the bad
    /// value, so they need rewriting once. A name is only ever rewritten when it
    /// fails to resolve as an id AND matches a real sound's display name exactly,
    /// so a custom tone the user deleted (which also fails to resolve, but matches
    /// nothing) is left alone rather than being silently repointed.
    @MainActor
    static func migrateLegacySoundNames(container: ModelContainer) {
        let key = "didMigrateLegacySoundNames"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let context = container.mainContext
        guard let alarms = try? context.fetch(FetchDescriptor<Alarm>()) else { return }

        let manager = AlarmSoundManager.shared
        let allSounds = manager.getAllSounds()
        var repaired = 0
        for alarm in alarms {
            // Already a valid id — nothing to do.
            if manager.getSound(id: alarm.soundName) != nil { continue }
            guard let match = allSounds.first(where: { $0.displayName == alarm.soundName }) else { continue }
            print("🔧 Sound name repair: '\(alarm.label)' \(alarm.soundName) → \(match.id)")
            AppLogger.shared.log(
                "Sound name repair: '\(alarm.label)' '\(alarm.soundName)' → '\(match.id)'",
                category: .alarm
            )
            alarm.soundName = match.id
            repaired += 1
        }

        if repaired > 0 {
            try? context.save()
            print("✅ migrateLegacySoundNames: repaired \(repaired) alarm(s)")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    static func clearIncompatibleDatabase() {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        
        // Look for SwiftData database files
        let dbFiles = try? fileManager.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil)
        dbFiles?.forEach { url in
            if url.pathExtension == "store" || url.lastPathComponent.contains("default.store") {
                print("🗑️ Removing old database: \(url.lastPathComponent)")
                try? fileManager.removeItem(at: url)
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // Launch-argument harness so the balance mission can be exercised in
            // the simulator without navigating UI:
            //   simctl launch booted <bundle-id> -balanceBallDebug hard        (mission view alone)
            //   simctl launch booted <bundle-id> -balanceBallDebug alarm-hard  (real alarm window over the open app)
            if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-balanceBallDebug") {
                let arg = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? "medium"
                if arg.hasPrefix("alarm") {
                    let difficultyRaw = arg.replacingOccurrences(of: "alarm-", with: "")
                    appRoot.onAppear {
                        BalanceBallDebugAlarm.fire(
                            difficulty: BalanceDifficulty(rawValue: difficultyRaw.capitalized) ?? .medium,
                            after: 4
                        )
                    }
                } else {
                    BalanceBallDebugHost(difficulty: BalanceDifficulty(rawValue: arg.capitalized) ?? .medium)
                }
            } else if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-missionPreviewDebug") {
                // Renders the mission "Try It Out" preview screen directly:
                //   simctl launch booted <bundle-id> -missionPreviewDebug shake|math|balanceBall|blockDrop
                let arg = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? "math"
                let type: MissionType = switch arg {
                case "shake": .shake
                case "balanceBall": .balanceBall
                case "blockDrop": .blockDrop
                case "meteor": .meteor
                default: .math
                }
                MissionPreviewView(mission: DeviceSettings.shared.defaultMission(for: type), settings: DeviceSettings.shared)
            } else if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-meteorDebug") {
                // Meteor Defense mission harness:
                //   simctl launch booted <bundle-id> -meteorDebug hard   (mission view alone)
                let arg = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? "medium"
                MeteorDebugHost(difficulty: MeteorDifficulty(rawValue: arg.capitalized) ?? .medium)
            } else if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-blockDropDebug") {
                // Same idea for the Block Drop mission:
                //   simctl launch booted <bundle-id> -blockDropDebug hard   (mission view alone)
                let arg = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? "medium"
                BlockDropDebugHost(difficulty: BlockDropDifficulty(rawValue: arg.capitalized) ?? .medium)
            } else if ProcessInfo.processInfo.arguments.contains("-alarmAuthDebug") {
                // Fresh-install AlarmKit authorization check WITHOUT the notification
                // prompt blocking first — does the system alarm prompt ever appear?
                //   simctl launch booted <bundle-id> -alarmAuthDebug
                appRoot.onAppear {
                    Task {
                        // Wait past the launch transition so the request happens
                        // while the app is fully active.
                        try? await Task.sleep(for: .seconds(3))
                        print("🧪 [alarmAuthDebug] deniedBefore=\(AlarmKitScheduler.shared.isAuthorizationDenied)")
                        let granted = await AlarmKitScheduler.shared.requestAuthorization()
                        print("🧪 [alarmAuthDebug] granted=\(granted) deniedAfter=\(AlarmKitScheduler.shared.isAuthorizationDenied)")
                    }
                }
            } else if ProcessInfo.processInfo.arguments.contains("-soundPickerDebug") {
                // Alarm editor's sound section, expanded, for visual checks:
                //   simctl launch booted <bundle-id> -soundPickerDebug
                AlarmSoundPickerDebugHost()
            } else if ProcessInfo.processInfo.arguments.contains("-missionSheetDebug") {
                // Mission slot editor sheet alone, for layout checks:
                //   simctl launch booted <bundle-id> -missionSheetDebug
                MissionSheetDebugHost()
            } else if ProcessInfo.processInfo.arguments.contains("-radioFadeDebug") {
                // Radio + fade-in fire-sequence audio check:
                //   simctl launch --console-pty booted <bundle-id> -radioFadeDebug
                RadioFadeDebugHost()
            } else if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-alarmFireFadeDebug") {
                // Fires a REAL alarm through the in-app timer path and prints the
                // full volume picture every 2s (player / fade target / system):
                //   simctl launch --console-pty booted <bundle-id> -alarmFireFadeDebug [tone|radio]
                let arg = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? "tone"
                AlarmFireFadeDebugHost(mode: arg)
            } else if ProcessInfo.processInfo.arguments.contains("-radioSleepFadeDebug") {
                // Radio sleep-timer fade-out check:
                //   simctl launch --console-pty booted <bundle-id> -radioSleepFadeDebug
                RadioSleepFadeDebugHost()
            } else if ProcessInfo.processInfo.arguments.contains("-alarmDefaultsDebug") {
                // Alarm Defaults page (default mission/snooze/skip) for visual checks:
                //   simctl launch booted <bundle-id> -alarmDefaultsDebug
                AlarmDefaultsDebugHost()
            } else if ProcessInfo.processInfo.arguments.contains("-missionCountDebug") {
                // Alarm rows with 1/3/5 missions to check the slot-count badge:
                //   simctl launch booted <bundle-id> -missionCountDebug
                MissionCountDebugHost()
            } else if ProcessInfo.processInfo.arguments.contains("-settingsDebug") {
                // Settings screen for visual checks (collapsible sections):
                //   simctl launch booted <bundle-id> -settingsDebug
                SettingsDebugHost()
            } else if ProcessInfo.processInfo.arguments.contains("-themeAccentDebug") {
                // Theme accent picker sheet, light slot by default:
                //   simctl launch booted <bundle-id> -themeAccentDebug
                //   simctl launch booted <bundle-id> -themeAccentDebug -themeAccentDark
                ThemeAccentDebugHost()
            } else if ProcessInfo.processInfo.arguments.contains("-customColorPickerDebug") {
                // Our custom colour picker, presented directly:
                //   simctl launch booted <bundle-id> -customColorPickerDebug
                CustomColorPickerDebugHost()
            } else if ProcessInfo.processInfo.arguments.contains("-alarmEditorDebug") {
                // Alarm editor with an HA mission (shake fallback) for visual checks:
                //   simctl launch booted <bundle-id> -alarmEditorDebug
                AlarmEditorDebugHost()
            } else if ProcessInfo.processInfo.arguments.contains("-missionSequenceDebug") {
                // Active alarm with a synthetic 3-mission sequence (math → shake →
                // math) to exercise the slot machine:
                //   simctl launch booted <bundle-id> -missionSequenceDebug
                MissionSequenceDebugHost()
            } else if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-tapMissionDebug") {
                // Active alarm (landing page) for a missionless Tap alarm — a tap
                // counter or hold-to-dismiss chip:
                //   simctl launch booted <bundle-id> -tapMissionDebug 10
                //   simctl launch booted <bundle-id> -tapMissionDebug hold
                let arg = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? "10"
                TapMissionDebugHost(mode: arg)
            } else if ProcessInfo.processInfo.arguments.contains("-verseDebug") {
                // Verse of the Day card, full-screen, with today's verse (forces a
                // refresh attempt; falls back to a bundled verse offline):
                //   simctl launch booted <bundle-id> -verseDebug
                VerseDebugHost()
            } else if ProcessInfo.processInfo.arguments.contains("-afterAlarmDebug") {
                // Full After-Alarm flow with a synthetic [verse, weather] alarm —
                // Continue on the verse card advances to the weather card:
                //   simctl launch booted <bundle-id> -afterAlarmDebug
                AfterAlarmDebugHost()
            } else if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-afterAlarmSectionDebug") {
                // After-Alarm editor section (two-row grid + one action's config
                // sheet, each of which carries that action's "Preview …" button):
                //   simctl launch booted <bundle-id> -afterAlarmSectionDebug [notes|verse|weather|appLink] [-noSheet]
                let arg = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? "notes"
                AfterAlarmSectionDebugHost(sheetAction: arg)
            } else if ProcessInfo.processInfo.arguments.contains("-notesDebug") {
                // Full-page Notes after-alarm step with sample notes + two
                // sample command buttons:
                //   simctl launch booted <bundle-id> -notesDebug
                NotesDebugHost()
            } else if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-notesEditorDebug") {
                // The DIRECT Notes editor, in one of its three key states:
                //   simctl launch booted <bundle-id> -notesEditorDebug            (keyboard hidden)
                //   simctl launch booted <bundle-id> -notesEditorDebug keyboard   (keyboard up, commands hidden)
                //   simctl launch booted <bundle-id> -notesEditorDebug jiggle     (grid in edit mode)
                let arg = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? ""
                NotesEditorDebugHost(mode: arg)
            } else if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-commandPickerDebug") {
                // The unified command picker, opened from one of its contexts:
                //   simctl launch booted <bundle-id> -commandPickerDebug noteSlot
                //   simctl launch booted <bundle-id> -commandPickerDebug swipeLeft
                let arg = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? "noteSlot"
                CommandPickerDebugHost(context: arg)
            } else if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-commandFormDebug") {
                // The shared command form in EDIT mode, per source, plus the
                // delete confirmation with its usage warning:
                //   simctl launch booted <bundle-id> -commandFormDebug ha|shortcut|delete
                let arg = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? "ha"
                CommandFormDebugHost(mode: arg)
            } else if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-commandWidgetDebug") {
                // The command widget's settings page: widget gestures and the
                // Widget List (membership + order), no library:
                //   simctl launch booted <bundle-id> -commandWidgetDebug [off]
                let arg = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? "on"
                CommandWidgetDebugHost(mode: arg)
            } else if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-soundManagerDebug") {
                // Sound Manager, full or scoped to custom sleep sounds:
                //   simctl launch booted <bundle-id> -soundManagerDebug [custom]
                let arg = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? ""
                SoundManagerDebugHost(mode: arg)
            } else if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-dataPrefsDebug") {
                // Data preferences screen, first-run or legacy-user wording:
                //   simctl launch booted <bundle-id> -dataPrefsDebug [legacy]
                let arg = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? ""
                DataPreferencesDebugHost(mode: arg)
            } else if ProcessInfo.processInfo.arguments.contains("-onboardingDebug") {
                // First-launch onboarding (a reinstall won't bring it back —
                // hasCompletedOnboarding is Keychain-backed):
                //   simctl launch booted <bundle-id> -onboardingDebug
                OnboardingDebugHost()
            } else if ProcessInfo.processInfo.arguments.contains("-radioBrowserDebug") {
                // Radio browser, for its Top / Near You scope tiles:
                //   simctl launch booted <bundle-id> -radioBrowserDebug
                RadioBrowserDebugHost()
            } else if ProcessInfo.processInfo.arguments.contains("-commandLibraryDebug") {
                // The command library — Settings › Commands / "Manage Commands":
                //   simctl launch booted <bundle-id> -commandLibraryDebug
                CommandLibraryDebugHost()
            } else if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-alarmScreenshot") {
                // Renders a single active-alarm screen for screenshotting:
                //   simctl launch booted <bundle-id> -alarmScreenshot math
                let screen = ProcessInfo.processInfo.arguments.dropFirst(idx + 1).first ?? "none"
                AlarmScreenshotHost(screen: screen)
            } else if ProcessInfo.processInfo.arguments.contains("-supportDebug") {
                // StoreKit-free preview of the redesigned support screen — full tip jar
                // (all tiers + the featured "Most Popular" Lifetime) + monthly, without
                // needing App Store Connect products. For visual review + review screenshots:
                //   simctl launch booted <bundle-id> -supportDebug
                SupportPreviewMockHost()
            } else if ProcessInfo.processInfo.arguments.contains("-supportPromptDebug") {
                // Auto-presents the periodic "Enjoying Allarise?" support prompt as its
                // real sheet, for visual review of that card:
                //   simctl launch booted <bundle-id> -supportPromptDebug
                SupportPromptDebugHost()
            } else if ProcessInfo.processInfo.arguments.contains("-backgroundRefreshDebug") {
                // The full-screen "Background Refresh Required" nag
                // (BackgroundRefreshWarningView), rendered directly for visual
                // review. In the real app it only appears when Background App
                // Refresh is disabled while App Persistence != Off:
                //   simctl launch booted <bundle-id> -backgroundRefreshDebug
                BackgroundRefreshWarningView()
            } else {
                appRoot
            }
            #else
            appRoot
            #endif
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
    }

    @ViewBuilder
    private var appRoot: some View {
            AppAccentTint(settings: settings) {
            AlarmListView()
                .preferredColorScheme(
                    settings.appAppearance == "light" ? .light :
                    settings.appAppearance == "dark" ? .dark : nil
                )
                .showBackgroundRefreshWarning()  // Show warning if background refresh is disabled
                // Release notes, opened when a product-update push is tapped.
                .whatsNewSheet()
                .fullScreenCover(item: $launchGate) { gate in
                    switch gate {
                    case .onboarding:
                        // Dismisses itself via the environment's dismiss action,
                        // which clears `launchGate`.
                        OnboardingView()
                            .appAppearanceTheme(settings)
                    case .dataPreferences:
                        DataPreferencesView(isPartOfOnboarding: false) {
                            launchGate = nil
                        }
                        .appAppearanceTheme(settings)
                    }
                }
                .sheet(isPresented: $showTermsUpdate, onDismiss: {
                    // Guarded on the flag rather than re-reading the setting, so
                    // a user who already answered isn't asked again if the sheet
                    // is ever dismissed for another reason.
                    if dataPreferencesDeferred {
                        dataPreferencesDeferred = false
                        launchGate = .dataPreferences
                    }
                }) {
                    TermsUpdateView()
                        .appAppearanceTheme(settings)
                }
                .alert(
                    presetImportAlert?.title ?? "",
                    isPresented: Binding(
                        get: { presetImportAlert != nil },
                        set: { if !$0 { presetImportAlert = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) { presetImportAlert = nil }
                } message: {
                    if let alert = presetImportAlert {
                        Text(alert.message)
                    }
                }
                .sheet(isPresented: $showingSoundImportSheet) {
                    SoundImportSheet(
                        url: pendingSoundImportURL,
                        name: $soundImportName,
                        category: $soundImportCategory,
                        onImport: { performSoundImport() },
                        onCancel: {
                            pendingSoundImportURL = nil
                            showingSoundImportSheet = false
                        }
                    )
                    .presentationDetents([.medium])
                    .appAppearanceTheme(settings)
                }
                .sheet(isPresented: $showingSoundImportPaywall) {
                    ProPaywallView(storeManager: StoreManager.shared)
                        .appAppearanceTheme(settings)
                }
                // Tell the user when the alarm database had to be rebuilt. Shown
                // once, on the first launch after it happens, because an alarm
                // that silently stopped existing is not something they should
                // find out about by oversleeping.
                .alert(
                    databaseRecoveryNotice?.hadLoss == true
                        ? "Alarms Could Not Be Restored"
                        : "Alarms Restored",
                    isPresented: Binding(
                        get: { databaseRecoveryNotice != nil },
                        set: { if !$0 { dismissDatabaseRecoveryNotice() } }
                    )
                ) {
                    Button("OK", role: .cancel) { dismissDatabaseRecoveryNotice() }
                } message: {
                    if let notice = databaseRecoveryNotice {
                        Text(Self.recoveryMessage(for: notice))
                    }
                }
                .onOpenURL { url in
                    // Handle audio file imports (including legacy .hwsound)
                    let ext = url.pathExtension.lowercased()
                    if ext == "hwsound" || AudioConverter.supportedExtensions.contains(ext) {
                        // Custom sound imports are free in the support model, so this no
                        // longer gates behind Pro. (`featuresUnlocked` is always true;
                        // flip it in StoreManager to restore paid gating.)
                        guard StoreManager.shared.featuresUnlocked else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                showingSoundImportPaywall = true
                            }
                            return
                        }
                        let rawName = url.deletingPathExtension().lastPathComponent
                        pendingSoundImportURL = url
                        soundImportName = CustomSound.sanitizedName(from: rawName)
                        soundImportCategory = .alarmTone
                        // Delay presentation so any existing sheet (Settings, etc.) can dismiss first.
                        // Without this, the import sheet tries to present behind the current sheet.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            showingSoundImportSheet = true
                        }
                        return
                    }

                    // Handle .hawaketheme file imports
                    if url.pathExtension == "hawaketheme" {
                        let result = settings.importTheme(from: url)
                        switch result {
                        case .success(let name):
                            presetImportAlert = PresetImportAlert(
                                title: "Theme Imported",
                                message: "Theme \"\(name)\" has been added."
                            )
                            NotificationCenter.default.post(name: .presetImported, object: nil)
                        case .failure(let message):
                            presetImportAlert = PresetImportAlert(
                                title: "Import Failed",
                                message: message
                            )
                        }
                        return
                    }
                    
                    // Handle legacy .hawakepreset file imports
                    if url.pathExtension == "hawakepreset" {
                        let result = settings.importPreset(from: url)
                        switch result {
                        case .home(let preset):
                            presetImportAlert = PresetImportAlert(
                                title: "Theme Imported",
                                message: "Theme \"\(preset.name)\" has been added."
                            )
                            NotificationCenter.default.post(name: .presetImported, object: nil)
                        case .alarm(let preset):
                            presetImportAlert = PresetImportAlert(
                                title: "Theme Imported",
                                message: "Theme \"\(preset.name)\" has been added."
                            )
                            NotificationCenter.default.post(name: .presetImported, object: nil)
                        case .failure(let message):
                            presetImportAlert = PresetImportAlert(
                                title: "Import Failed",
                                message: message
                            )
                        }
                        return
                    }
                    
                    // Handle deep links from Live Activity taps (allarise://alarm;
                    // hawake:// kept as a legacy alias)
                    print("=== DIAG === onOpenURL: \(url)")
                    if (url.scheme == "allarise" || url.scheme == "hawake") && url.host == "alarm" {
                        Task { @MainActor in
                            // First try to make existing alarm window visible
                            if AlarmWindowManager.shared.ensureAlarmWindowVisible() {
                                print("=== DIAG === onOpenURL: alarm window re-keyed")
                                return
                            }

                            // No alarm window yet — check for pending alarm
                            if PendingAlarmStore.shared.pendingAlarm != nil {
                                AlarmWindowManager.shared.checkAndShowPendingAlarm()
                                return
                            }

                            // No alarm window and no pending alarm.
                            // If alarm sound is playing, the timer fired but the UI
                            // hasn't appeared yet — wait briefly and retry.
                            if AlarmSoundPlayer.shared.isPlaying {
                                print("=== DIAG === onOpenURL: sound playing but no UI yet, retrying in 1s...")
                                try? await Task.sleep(for: .seconds(1))
                                if AlarmWindowManager.shared.ensureAlarmWindowVisible() {
                                    print("=== DIAG === onOpenURL: alarm window found on retry")
                                    return
                                }
                                if PendingAlarmStore.shared.pendingAlarm != nil {
                                    AlarmWindowManager.shared.checkAndShowPendingAlarm()
                                    print("=== DIAG === onOpenURL: retry checkAndShowPendingAlarm")
                                    return
                                }
                            }

                            // No alarm window, no pending alarm, no sound playing.
                            // Stale state — clean up any lingering notifications.
                            print("=== DIAG === onOpenURL: stale state detected, cleaning up notifications")
                            AlarmLiveActivityManager.shared.stopAlarmNotifications()
                        }
                    }
                }
                .onAppear {
                    // Refresh Siri phrase parameters (sleep-sound and MQTT-command
                    // names change at runtime; App Shortcuts cache them).
                    AllariseShortcuts.updateAppShortcutParameters()

                    // Onboarding / terms cover state is initialized in `init()` so it is
                    // already presenting when the view first renders. Do not re-trigger it
                    // here — that would create a flicker where the user briefly sees the
                    // main UI before the cover slides up.

                    // Opportunistically refresh Verse of the Day content (throttled to
                    // ~6h internally, off-main at .utility QoS, silent when offline).
                    // This is the ONLY integration point for the verse backend.
                    VerseOfDayService.shared.refreshIfNeeded()

                    Task { @MainActor in
                        // Clean up any stale alarm notifications left over from a previous
                        // session (e.g., app was force-killed before notifications could be stopped).
                        // Skip if there's a pending alarm to avoid killing active notifications.
                        let hasPending = PendingAlarmStore.shared.pendingAlarm != nil || PendingAlarmStore.shared.hasPendingAlarm()
                        if !AlarmWindowManager.shared.isShowingAlarm && !AlarmSoundPlayer.shared.isPlaying && !hasPending {
                            AlarmLiveActivityManager.shared.stopAlarmNotifications()
                        }
                        
                        // Fallback permission requests for users who completed onboarding
                        // (or app updates from before onboarding existed).
                        // No-op if already granted/denied.
                        if settings.hasCompletedOnboarding {
                            NetworkMonitor.shared.requestLocationPermission()
                        }
                        
                        // Connect to MQTT if enabled
                        if settings.mqttEnabled {
                            // Wait for NetworkMonitor to resolve the initial network state
                            // (SSID detection can take time). Timeout after 5 seconds to avoid
                            // blocking indefinitely if SSID is unavailable.
                            let startTime = Date()
                            while !NetworkMonitor.shared.hasResolvedInitialNetwork {
                                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                                if Date().timeIntervalSince(startTime) > 5.0 {
                                    print("⚠️ NetworkMonitor did not resolve within 5s — connecting with current state")
                                    break
                                }
                            }
                            print("🔌 HA Integration: network resolved in \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s — connecting")
                            HAIntegrationRouter.shared.activate(settings: settings)
                            HAIntegrationRouter.shared.connect(settings: settings)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    // Fires on timezone change, midnight rollover, or daylight saving transition.
                    // Re-run alarm reconciliation so timers and AlarmKit failsafes use the
                    // correct wall-clock time after the change.
                    print("[ALARM-STATE] significantTimeChange: re-reconciling alarms")
                    Task { @MainActor in
                        guard !MQTTCommandHandler.shared.isSuppressingAlarmAccess else { return }
                        let context = container.mainContext
                        let descriptor = FetchDescriptor<Alarm>()
                        let alarms = ((try? context.fetch(descriptor)) ?? []).filter { !$0.isDetached && $0.isEnabled }
                        for alarm in alarms where !alarm.isSnoozed {
                            await DualAlarmCoordinator.shared.scheduleAlarmForReconciliation(alarm)
                        }
                        AppLogger.shared.log("Alarms re-reconciled after significant time change (\(alarms.count) alarms)", category: .alarm)
                    }
                }
            }
    }

    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
            print("[ALARM-STATE] ━━━ scenePhase: \(oldPhase) → \(newPhase) at \(Date()) ━━━")
            Task { @MainActor in
                // Skip if an alarm delete is in progress — fetched objects may
                // have invalidated backing data during persistent store merge.
                guard !MQTTCommandHandler.shared.isSuppressingAlarmAccess else {
                    print("[ALARM-STATE] scenePhase: SKIPPING (alarm delete in progress)")
                    AppLifecycleMonitor.shared.handleScenePhase(newPhase, hasAlarms: false)
                    return
                }
                let context = container.mainContext
                let descriptor = FetchDescriptor<Alarm>()
                let alarms = ((try? context.fetch(descriptor)) ?? []).filter { !$0.isDetached }
                let enabledAlarms = alarms.filter { $0.isEnabled }
                let hasActiveAlarms = !enabledAlarms.isEmpty

                print("[ALARM-STATE] scenePhase: totalAlarms=\(alarms.count), enabledAlarms=\(enabledAlarms.count), isShowingAlarm=\(AlarmWindowManager.shared.isShowingAlarm), isPlaying=\(AlarmSoundPlayer.shared.isPlaying), hasPendingAlarm=\(PendingAlarmStore.shared.hasPendingAlarm()), pendingAlarmInMemory=\(PendingAlarmStore.shared.pendingAlarm != nil)")

                AppLifecycleMonitor.shared.handleScenePhase(newPhase, hasAlarms: hasActiveAlarms)

                if newPhase == .active {
                    // Clear stale pending alarms: if no alarms are enabled and nothing
                    // is actively playing, any pending alarm in UserDefaults is leftover
                    // from a previous session (e.g., app was killed mid-flow).
                    // EXCEPTION: Alert alarms (from MQTT) are transient and NOT stored
                    // in the database, so enabledAlarms will be empty even during a
                    // legitimate alert. Skip cleanup if the pending alarm is an alert.
                    let pendingIsAlert = PendingAlarmStore.shared.pendingAlarm?.missionType == .alert
                    if enabledAlarms.isEmpty && !AlarmSoundPlayer.shared.isPlaying && !AlarmWindowManager.shared.isShowingAlarm && !pendingIsAlert {
                        if PendingAlarmStore.shared.hasPendingAlarm() || PendingAlarmStore.shared.pendingAlarm != nil || PendingAlarmStore.shared.activeRingingAlarmID() != nil {
                            PendingAlarmStore.shared.consumePendingAlarm()
                            PendingAlarmStore.shared.pendingAlarm = nil
                            PendingAlarmStore.shared.clearActiveRingingAlarm()
                            print("[ALARM-STATE] scenePhase=.active: cleared stale pending alarm (no enabled alarms)")
                        }
                    }

                    AppLogger.shared.log("scenePhase → active", category: .general)

                    // Credit one active-use day toward the periodic support prompt. This
                    // is the "user actually opened the app" signal (foreground/active),
                    // idempotent per calendar day — background wake-ups never reach here.
                    SupportPromptManager.shared.recordActiveDayIfNeeded()

                    // Opportunistic Verse of the Day refresh on foreground (throttled
                    // ~6h internally, silent offline). Only verse-backend integration.
                    VerseOfDayService.shared.refreshIfNeeded()

                    print("[ALARM-STATE] scenePhase=.active: calling checkAndShowPendingAlarm()")
                    AlarmWindowManager.shared.checkAndShowPendingAlarm()
                    
                    // Cancel ringing guards ONLY when no AlarmKit alarm is currently
                    // alerting. On cold start from a force-close, the guard fires
                    // and handleAlarmAlerting processes it via the alarmUpdates
                    // observer. But the observer runs on a non-MainActor executor
                    // and may not have fired yet by the time this MainActor handler
                    // runs. Calling cancelRingingGuard here would stop the guard
                    // before handleAlarmAlerting sees it, preventing alarm recovery.
                    if !AlarmKitScheduler.shared.hasAlertingAlarm {
                        if AlarmWindowManager.shared.isShowingAlarm {
                            if let activeID = AlarmWindowManager.shared.currentAlarmID {
                                DualAlarmCoordinator.shared.cancelRingingGuard(forAlarmHash: activeID)
                            }
                        }
                        for alarm in enabledAlarms {
                            DualAlarmCoordinator.shared.cancelRingingGuard(forAlarmHash: alarm.stableHash)
                        }
                    } else {
                        print("[ALARM-STATE] scenePhase=.active: AlarmKit alarm is alerting — SKIPPING guard cancellation to allow handleAlarmAlerting to process it")
                    }

                    let pendingInMemory = PendingAlarmStore.shared.pendingAlarm != nil
                    let hasSnoozedAlarm = enabledAlarms.contains { $0.isSnoozed && ($0.snoozeUntil ?? .distantPast) > Date() }
                    // Also check if AlarmKit has an alarm currently alerting — on
                    // cold start after a force-close, the guard fires and
                    // handleAlarmAlerting may not have finished setting up the
                    // alarm UI yet. Without this check, cleanup+reschedule races
                    // with the guard handler and can stop notifications, interfere
                    // with sound, or reschedule AlarmKit alarms mid-alerting.
                    let alarmKitAlerting = AlarmKitScheduler.shared.hasAlertingAlarm
                    if !AlarmWindowManager.shared.isShowingAlarm && !PendingAlarmStore.shared.hasPendingAlarm() && !pendingInMemory && !AlarmSoundPlayer.shared.isPlaying && !alarmKitAlerting {
                        let validHashes = Set(enabledAlarms.map { $0.stableHash })
                        print("[ALARM-STATE] scenePhase=.active: no active alarm, running cleanup+reschedule for \(validHashes.count) enabled alarms (snoozed: \(hasSnoozedAlarm))")

                        // Slept-through reconciliation (al-bee.5). FIRST inside
                        // this block, and therefore:
                        //   * strictly after checkAndShowPendingAlarm() above,
                        //   * inside the same not-ringing guard, so it cannot
                        //     race a live ring,
                        //   * before cleanupStaleAlarms, which can stop resident
                        //     AlarmKit alarms — the cold-start evidence that an
                        //     alarm rang with nobody home.
                        // Reads only and arms nothing; if it misbehaves, every
                        // alarm still rings, because no lifecycle path reads it.
                        SleptThroughNotice.shared.reconcile(
                            knownAlarms: alarms.map { ($0.stableHash, $0.label, $0.alarmIndex) }
                        )

                        // End all Live Activities before rescheduling to prevent orphans.
                        // Each scheduleAlarm() call creates a new Live Activity; without
                        // Stop stale alarm notifications before rescheduling.
                        // SKIP if an alarm is snoozed — notifications will restart when snooze ends.
                        if !hasSnoozedAlarm {
                            AlarmLiveActivityManager.shared.stopAlarmNotifications()
                        }

                        DualAlarmCoordinator.shared.cleanupStaleAlarms(validAlarmHashes: validHashes)

                        // Clear stale skipped-fire dates: when a skip's target time passes
                        // without being cleared by AlarmKitScheduler (normal — the AlarmKit
                        // alarm was successfully cancelled so it never fired the guard),
                        // the skippedFireDate persists. isSkipped correctly returns false once
                        // the date is past, but clearing the value here ensures nextFireDate()
                        // doesn't filter around a stale entry and the skip button state is clean.
                        for alarm in enabledAlarms {
                            if let skipped = alarm.skippedFireDate, skipped < Date() {
                                alarm.skippedFireDate = nil
                                AppLogger.shared.log("Cleared expired skip for '\(alarm.label)' (was \(skipped))", category: .alarm)
                                print("[ALARM-STATE] scenePhase=.active: cleared expired skip for '\(alarm.label)' (was \(skipped))")
                            }
                        }

                        for alarm in enabledAlarms {
                            if alarm.isSnoozed {
                                if let snoozeUntil = alarm.snoozeUntil, snoozeUntil > Date() {
                                    // Snooze is still active — ensure AlarmKit failsafe exists.
                                    // The in-app Timer handles the normal case, but if the user
                                    // force-kills the app, the Timer dies. The AlarmKit failsafe
                                    // is the only thing that survives a force-kill.
                                    let alarmID = alarm.stableHash
                                    print("[ALARM-STATE] scenePhase=.active: snoozed alarm '\(alarm.label)' — verifying AlarmKit failsafe (snooze until \(snoozeUntil))")
                                    Task {
                                        await AlarmKitScheduler.shared.scheduleSnoozeFailsafe(
                                            alarm: alarm,
                                            alarmID: alarmID,
                                            snoozeUntil: snoozeUntil
                                        )
                                    }
                                    continue
                                }
                                // Snooze expired while app was suspended — the in-memory
                                // Timer died and AlarmKit failsafe may have already been
                                // consumed. Fire the alarm NOW to recover the missed snooze.
                                print("[ALARM-STATE] scenePhase=.active: EXPIRED snooze for '\(alarm.label)' — firing immediately")
                                AppLogger.shared.log("Recovering missed snooze re-fire: '\(alarm.label)'", category: .alarm)
                                alarm.isSnoozed = false
                                alarm.snoozeUntil = nil
                                let alarmID = alarm.stableHash
                                // Cancel the AlarmKit snooze failsafe — we're handling
                                // the re-fire here, so the failsafe is no longer needed.
                                // Without this, the failsafe fires seconds later with a
                                // DefaultStopIntent, racing with the alarm we're showing.
                                AlarmKitScheduler.shared.cancelSnoozeFailsafe(forAlarmHash: alarmID)
                                PendingAlarmStore.shared.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                                    alarmID: alarmID,
                                    label: alarm.label,
                                    missionType: alarm.mission.type,
                                    soundID: alarm.soundName,
                                    volumeLevel: alarm.effectiveVolumeLevel(settings: settings)
                                )
                                AlarmWindowManager.shared.checkAndShowPendingAlarm()
                                continue
                            }
                            await DualAlarmCoordinator.shared.scheduleAlarmForReconciliation(alarm)
                        }
                    } else {
                        print("[ALARM-STATE] scenePhase=.active: SKIPPING cleanup+reschedule (isShowingAlarm=\(AlarmWindowManager.shared.isShowingAlarm), hasPendingAlarm=\(PendingAlarmStore.shared.hasPendingAlarm()), isPlaying=\(AlarmSoundPlayer.shared.isPlaying), alarmKitAlerting=\(alarmKitAlerting))")
                    }

                    // Retry alarm notifications if alarm is showing but notifications aren't running.
                    // This handles the case where the alarm fired from the background.
                    // activeRingingAlarmID is nil after snooze/dismiss (cleared synchronously),
                    // even if the alarm window is briefly still visible (async dismiss pending).
                    let laMgr = AlarmLiveActivityManager.shared
                    if AlarmWindowManager.shared.isShowingAlarm && !laMgr.hasActiveNotifications
                        && PendingAlarmStore.shared.activeRingingAlarmID() != nil {
                        if let alarm = AlarmWindowManager.shared.currentAlarm {
                            let alarmID: Int
                            if alarm.mission.type == .alert {
                                alarmID = MQTTCommandHandler.alertAlarmID(title: alarm.label)
                            } else {
                                alarmID = alarm.stableHash
                            }
                            print("[ALARM-STATE] scenePhase=.active: starting alarm notifications for '\(alarm.label)' (id=\(alarmID))")
                            let retryVibration = alarm.effectiveVibrationEnabled(settings: settings)
                            laMgr.vibrationEnabled = retryVibration
                            laMgr.suppressLockScreenNotifications = false
                            laMgr.startAlarmNotifications(
                                alarmLabel: alarm.label,
                                alarmID: alarmID
                            )
                        } else {
                            print("[ALARM-STATE] scenePhase=.active: alarm window showing but no currentAlarm — cannot start notifications")
                        }
                    }

                    if settings.mqttEnabled {
                        if !HAIntegrationRouter.shared.isConnected {
                            print("[ALARM-STATE] scenePhase=.active: MQTT not connected, reconnecting...")
                            HAIntegrationRouter.shared.connect(settings: settings)
                        } else {
                            // Already connected — republish availability first, then per-alarm state
                            HAIntegrationRouter.shared.publishOnlineState(settings: settings)
                            NotificationCenter.default.post(name: NSNotification.Name("MQTTDidConnect"), object: nil)
                        }
                    }

                    // Re-arm NWS weather alert polling. The poll timer does not
                    // survive process termination, and start() is idempotent.
                    // DEBUG-only: NWS is gated out of production.
                    #if DEBUG
                    if settings.nwsAlertsEnabled {
                        NWSAlertService.shared.start()
                    }
                    #endif
                } else if newPhase == .inactive {
                    print("[ALARM-STATE] scenePhase=.inactive: isPlaying=\(AlarmSoundPlayer.shared.isPlaying)")
                    // Flush any unsaved SwiftData changes before the app may be killed.
                    // .inactive fires when the user swipes up or the app is about to background.
                    if context.hasChanges {
                        try? context.save()
                        print("[ALARM-STATE] scenePhase=.inactive: saved pending SwiftData changes")
                    }
                } else if newPhase == .background {
                    let audioSession = AVAudioSession.sharedInstance()
                    print("[ALARM-STATE] scenePhase=.background: isPlaying=\(AlarmSoundPlayer.shared.isPlaying), keepAliveNeeded=\(settings.keepAliveNeeded), audioCategory=\(audioSession.category.rawValue), secondaryAudioHint=\(audioSession.secondaryAudioShouldBeSilencedHint)")
                    // Second safety net — ensure data is persisted before possible termination.
                    if context.hasChanges {
                        try? context.save()
                        print("[ALARM-STATE] scenePhase=.background: saved pending SwiftData changes")
                    }
                    // Refresh the JSON backup now that everything is saved. Doing
                    // it here (rather than at each edit site) means the backup is
                    // never more than one foreground session behind, whatever
                    // created or changed the alarms — editor, MQTT, or Siri.
                    AlarmBackupStore.writeSnapshot(container: container)
                    let hasPendingAlarm = PendingAlarmStore.shared.pendingAlarm != nil || PendingAlarmStore.shared.hasPendingAlarm()
                    // activeRingingAlarmID is cleared SYNCHRONOUSLY during snooze/dismiss, before
                    // the async window-hide Task runs. Use it as the authoritative gate so that a
                    // briefly-still-visible alarm window after a snooze tap doesn't trigger a guard.
                    let isActivelyRinging = PendingAlarmStore.shared.activeRingingAlarmID() != nil
                    let alarmActive = isActivelyRinging && (AlarmSoundPlayer.shared.isPlaying || hasPendingAlarm || AlarmWindowManager.shared.isShowingAlarm)
                    print("[ALARM-STATE] scenePhase=.background: isPlaying=\(AlarmSoundPlayer.shared.isPlaying), hasPendingAlarm=\(hasPendingAlarm), isShowingAlarm=\(AlarmWindowManager.shared.isShowingAlarm), currentAlarm=\(AlarmWindowManager.shared.currentAlarm?.label ?? "nil"), currentAlarmID=\(AlarmWindowManager.shared.currentAlarmID.map(String.init) ?? "nil"), alarmActive=\(alarmActive)")
                    if !alarmActive {
                        print("[ALARM-STATE] scenePhase=.background: no alarm active — running forceCleanup")
                        VolumeManager.shared.forceCleanup()
                    } else {
                        print("[ALARM-STATE] scenePhase=.background: SKIPPING forceCleanup (alarm is playing or pending)")

                        // Schedule a ringing guard — if the user force-kills the app
                        // while the alarm is ringing, AlarmKit will re-fire within
                        // seconds to ensure the alarm isn't silently lost.
                        if let currentAlarm = AlarmWindowManager.shared.currentAlarm,
                           let alarmID = AlarmWindowManager.shared.currentAlarmID {
                            print("[ALARM-STATE] scenePhase=.background: scheduling ringing guard for '\(currentAlarm.label)' (id=\(alarmID))")
                            await DualAlarmCoordinator.shared.scheduleRingingGuard(alarm: currentAlarm, alarmID: alarmID)
                        } else if let pending = PendingAlarmStore.shared.pendingAlarm {
                            // Alarm UI hasn't fully loaded yet — use pending alarm info
                            print("[ALARM-STATE] scenePhase=.background: scheduling ringing guard from PENDING alarm '\(pending.label)' (id=\(pending.alarmID))")
                            await DualAlarmCoordinator.shared.scheduleRingingGuardFromInfo(
                                alarmID: pending.alarmID,
                                label: pending.label,
                                // Resolve from the full stored mission blob so a multi-tap/hold
                                // Tap alarm (a real mission) keeps CompleteMissionIntent.
                                requiresMission: PendingAlarmStore.shared.reconstructAlarm(alarmID: pending.alarmID)
                                    .map { !$0.missionSequence.isEmpty } ?? (pending.missionType != .none),
                                soundID: pending.soundID
                            )
                        } else if PendingAlarmStore.shared.hasPendingAlarm() {
                            // In-memory pending was cleared but UserDefaults still has it
                            if let info = PendingAlarmStore.shared.consumePendingAlarm() {
                                print("[ALARM-STATE] scenePhase=.background: scheduling ringing guard from UserDefaults pending alarm '\(info.label)' (id=\(info.alarmID))")
                                await DualAlarmCoordinator.shared.scheduleRingingGuardFromInfo(
                                    alarmID: info.alarmID,
                                    label: info.label,
                                    requiresMission: PendingAlarmStore.shared.reconstructAlarm(alarmID: info.alarmID)
                                        .map { !$0.missionSequence.isEmpty } ?? (info.missionType != .none),
                                    soundID: info.soundID
                                )
                                // Re-store so checkAndShowPendingAlarm can still pick it up on foreground
                                PendingAlarmStore.shared.pendingAlarm = info
                                PendingAlarmStore.shared.setPendingAlarmFull(
                                    alarmID: info.alarmID,
                                    label: info.label,
                                    missionType: info.missionType.rawValue,
                                    soundID: info.soundID,
                                    volumeLevel: info.volumeLevel
                                )
                            }
                        } else {
                            // All state checks failed — no way to schedule a guard.
                            // This should not happen if an alarm is actively ringing.
                            print("[ALARM-STATE] ⚠️ scenePhase=.background: FAILED to schedule ringing guard — no currentAlarm, no pendingAlarm, no UserDefaults pending")
                        }
                    }
                }
            }
        }

    private func performSoundImport() {
        guard let url = pendingSoundImportURL else { return }
        showingSoundImportSheet = false

        do {
            let name: String
            switch soundImportCategory {
            case .alarmTone:
                let sound = try CustomSoundManager.shared.importAlarmTone(from: url, name: soundImportName)
                name = sound.name
            case .sleepSound:
                let sound = try CustomSoundManager.shared.importSleepSound(from: url, name: soundImportName)
                name = sound.name
            }
            presetImportAlert = PresetImportAlert(
                title: "Sound Imported",
                message: "\"\(name)\" added to \(soundImportCategory == .alarmTone ? "alarm tones" : "sleep sounds")."
            )
        } catch {
            presetImportAlert = PresetImportAlert(
                title: "Import Failed",
                message: error.localizedDescription
            )
        }

        pendingSoundImportURL = nil
        soundImportName = ""
    }
}

// MARK: - Sound Import Sheet

struct SoundImportSheet: View {
    let url: URL?
    @Binding var name: String
    @Binding var category: CustomSound.Category
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Sound Name") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                    if !name.isEmpty && !CustomSound.isValidMQTTName(name) {
                        Text("Use only letters, numbers, spaces, underscores, and hyphens (1-64 chars)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Import As") {
                    Picker("Category", selection: $category) {
                        Text("Alarm Tone").tag(CustomSound.Category.alarmTone)
                        Text("Sleep Sound").tag(CustomSound.Category.sleepSound)
                    }
                    .pickerStyle(.segmented)
                }

                if category == .alarmTone {
                    Section {
                        Text("Alarm tones are converted to WAV for notification compatibility. Max ~1 minute.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let url {
                    Section("File") {
                        LabeledContent("Name", value: url.lastPathComponent)
                        LabeledContent("Format", value: url.pathExtension.uppercased())
                    }
                }
            }
            .navigationTitle("Import Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onImport)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !CustomSound.isValidMQTTName(name))
                }
            }
        }
    }
}

/// Applies the theme's accent as the app-wide `.tint`, re-reading the effective
/// color scheme so light/dark pick the right customization. Wrapping the root
/// here means toggles, sliders, nav bars, Settings, and sheets all follow the
/// theme accent — and a disabled toggle falls back to the accent, not system blue.
private struct AppAccentTint<Content: View>: View {
    let settings: DeviceSettings
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content()
            .tint(settings.appAccent(for: colorScheme))
    }
}

/// Applies the app's appearance override (light/dark/system) AND the theme
/// accent tint to a view.
///
/// Sheets and covers are presented into their own SwiftUI environment, so the
/// `.preferredColorScheme` applied inside `appRoot` never reaches an open sheet.
/// Without it, an open sheet keeps the *device* color scheme, and because
/// `settings.appAccent(for:)` re-reads the scheme, its accent goes stale too —
/// toggling Light/Dark/System in Settings doesn't re-color the already-open
/// sheet until it's dismissed and reopened. Applying this modifier to each
/// sheet/cover root re-resolves both the color scheme and the per-scheme accent
/// the instant appearance changes, exactly matching the root window.
private struct AppAppearanceThemeModifier: ViewModifier {
    let settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(
                settings.appAppearance == "light" ? .light :
                settings.appAppearance == "dark" ? .dark : nil
            )
            .tint(settings.appAccent(for: colorScheme))
    }
}

extension View {
    /// Apply to a sheet/cover root so an appearance change immediately
    /// re-renders it with the correct color scheme and per-scheme accent.
    /// See `AppAppearanceThemeModifier` for why sheets need this explicitly.
    func appAppearanceTheme(_ settings: DeviceSettings) -> some View {
        modifier(AppAppearanceThemeModifier(settings: settings))
    }
}
