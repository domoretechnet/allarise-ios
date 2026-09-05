//
//  AlarmListView.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import SwiftUI
import SwiftData
import Combine


struct AlarmListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Alarm.time) private var alarms: [Alarm]
    
    // Combined sheet presentation state
    @State private var activeSheet: SheetType?
    #if DEBUG
    @State private var showThemeColorEditor = false
    @State private var showAlarmScreenCycler = false
    // Kids Sleep (al-2se): debug-only OK-to-wake sessions, one per kid. The
    // picker/create flow is a fullScreenCover, not a SheetType case, because
    // it is full-screen by design and must not inherit the shared sheet
    // detents. Home cards are swipe-to-cancel only; editing lives in the
    // picker's own sheet.
    @State private var showSleepTimerCreate = false
    #endif
    // Tracks the quick alarm sheet detent; starts at medium, user can expand to large if content is clipped
    @State private var quickAlarmDetent: PresentationDetent = .medium
    // Periodic "support the project" prompt (free model). Shown on foreground when due,
    // never over an alarm or another sheet. See SupportPromptManager.
    @State private var showingSupportPrompt = false
    
    enum SheetType: Identifiable {
        case editAlarm(Alarm)
        case newAlarm
        case quickAlarm
        case sleepSounds
        case settings(expandMQTT: Bool = false)
        case proPaywall

        var id: String {
            switch self {
            case .editAlarm(let alarm): return "edit_\(alarm.id)"
            case .newAlarm: return "new"
            case .quickAlarm: return "quick"
            case .sleepSounds: return "sleepSounds"
            case .settings: return "settings"
            case .proPaywall: return "paywall"
            }
        }
    }
    
    // Use shared singletons to avoid recreating expensive objects
    let settings = DeviceSettings.shared
    let storeManager = StoreManager.shared
    let mqttManager = HAIntegrationRouter.shared
    
    // Track if authorization has been requested to avoid repeated calls
    @State private var hasRequestedAuthorization = false
    
    // Custom wallpaper. Released while backgrounded — see the scenePhase
    // handler — so a multi-megabyte decoded bitmap isn't pinned all night
    // while nothing is on screen to show it.
    @State private var homeWallpaper: UIImage?
    @Environment(\.scenePhase) private var wallpaperScenePhase
    
    // Floating + button expansion
    @State private var isAddMenuExpanded = false
    @State private var isSettingsMenuExpanded = false
    
    // Bottom status bar
    
    // Inline rename state
    @State private var renamingAlarmID: PersistentIdentifier?
    @State private var renameText: String = ""
    @FocusState private var isRenameFocused: Bool
    
    var enabledAlarms: [Alarm] {
        alarms.filter { $0.isEnabled }
    }
    
    var sortedAlarms: [Alarm] {
        // Compute each alarm's next fire date once up front — running it inside
        // the comparator repeats the 15-day calendar walk O(n log n) times.
        let pairs = alarms.map { ($0, $0.nextFireDate()) }
        return pairs.sorted { pair1, pair2 in
            let (alarm1, fire1) = pair1
            let (alarm2, fire2) = pair2
            // Check if either alarm is a completed one-time alarm
            let completed1 = !alarm1.isRecurring && alarm1.lastFireDate != nil
            let completed2 = !alarm2.isRecurring && alarm2.lastFireDate != nil

            // Push completed alarms to the bottom
            if completed1 != completed2 {
                return completed2 // completed2 = true means alarm2 goes to bottom
            }

            // First priority: Enabled vs Disabled
            if alarm1.isEnabled != alarm2.isEnabled {
                return alarm1.isEnabled // Enabled alarms first
            }

            // If both are enabled, sort by next fire time
            if alarm1.isEnabled && alarm2.isEnabled {
                // Handle nil fire dates (shouldn't happen for enabled alarms, but safety first)
                if fire1 == nil && fire2 == nil {
                    return alarm1.time < alarm2.time
                } else if fire1 == nil {
                    return false
                } else if fire2 == nil {
                    return true
                }

                return fire1! < fire2!
            }

            // If both are disabled, sort by time of day
            return alarm1.time < alarm2.time
        }.map { $0.0 }
    }
    

    
    var body: some View {
        // Sort once per body pass — the sort walks every alarm's schedule, so
        // recomputing it at each of the several usage sites below adds up.
        let sortedAlarms = self.sortedAlarms
        return NavigationStack {
            VStack(spacing: 0) {
                // Custom glass toolbar when wallpaper is active (replaces hidden nav bar)
                if settings.homeWallpaperEnabled {
                    glassToolbar
                }
                
                // Banners sit ABOVE the widget in both modes. In wallpaper mode
                // that happens inside `glassToolbar` (the widget lives there,
                // under the title); here it's the non-wallpaper path.
                if !settings.homeWallpaperEnabled {
                    homeBanners
                    armWidget
                }

                List {
                    #if DEBUG
                    // Kids Sleep trackers (al-2se): list rows above the
                    // alarms so they get the native swipe-to-reveal Cancel,
                    // in the exact idiom of the alarm rows' Delete (user
                    // request 2026-08-13; replaced a custom fling gesture).
                    ForEach(SleepTimerStore.shared.activeSessions) { sleepSession in
                        SleepTimerTrackerCard(
                            session: sleepSession,
                            settings: settings,
                            accentColor: settings.appAccent(for: colorScheme)
                        )
                        // Rebuild on light/dark change — glassEffect holds a
                        // stale render across trait changes (same trap as the
                        // arm widget).
                        .id(colorScheme)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                SleepTimerStore.shared.cancel(kidName: sleepSession.kidName)
                            } label: {
                                Label("Cancel", systemImage: "trash")
                                    .foregroundStyle(.white)
                            }
                        }
                        .listRowBackground(settings.homeWallpaperEnabled ? Color.clear : nil)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                    #endif

                    ForEach(sortedAlarms) { alarm in
                        AlarmRow(
                            alarm: alarm,
                            settings: settings,
                            mqttManager: mqttManager,
                            isRenaming: renamingAlarmID == alarm.persistentModelID,
                            renameText: $renameText,
                            isRenameFocused: $isRenameFocused,
                            onSkip: {
                                skipNextAlarm(alarm)
                            },
                            onUnskip: {
                                unskipAlarm(alarm)
                            },
                            onDelete: {
                                deleteAlarm(alarm)
                            },
                            onTap: {
                                // Alarm COUNT is no longer a Pro gate — every
                                // alarm is editable regardless of purchase.
                                AppLogger.shared.log("Opened Edit Alarm: '\(alarm.label)'", category: .alarm)
                                activeSheet = .editAlarm(alarm)
                            }
                        )

                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if alarm.swipeRightCommandID == nil || !settings.armButtonEnabled {
                                Button {
                                    duplicateAlarm(alarm)
                                } label: {
                                    // Force white content — swipe-action labels otherwise
                                    // inherit the ambient tint/foreground and read poorly
                                    // on the saturated background.
                                    Label("Duplicate", systemImage: "doc.on.doc")
                                        .foregroundStyle(.white)
                                }
                                .tint(settings.appAccent(for: colorScheme))
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if alarm.swipeLeftCommandID == nil || !settings.armButtonEnabled {
                                Button(role: .destructive) {
                                    deleteAlarm(alarm)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .listRowBackground(settings.homeWallpaperEnabled ? Color.clear : nil)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }

                    // Sleep sound active row — anchored below all alarms
                    if SleepSoundManager.shared.isActive {
                        SleepSoundActiveRow(settings: settings)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    SleepSoundManager.shared.stop()
                                } label: {
                                    Label("Stop", systemImage: "stop.fill")
                                        .foregroundStyle(.white)
                                }
                            }
                            .listRowBackground(settings.homeWallpaperEnabled ? Color.clear : nil)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }

                    // Radio active row — same anchoring as sleep sounds
                    if RadioPlayerManager.shared.isActive {
                        RadioActiveRow(settings: settings)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    RadioPlayerManager.shared.stop()
                                } label: {
                                    Label("Stop", systemImage: "stop.fill")
                                        .foregroundStyle(.white)
                                }
                            }
                            .listRowBackground(settings.homeWallpaperEnabled ? Color.clear : nil)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .contentMargins(.top, settings.homeWallpaperEnabled ? 0 : nil)
                // Clear the floating bubbles: bottom padding + bubble diameter,
                // plus margin so the last row's Skip button can always be scrolled
                // out from under them rather than resting just beneath the +.
                // Derived from the bubble's own metrics so "Bigger Alarm Rows",
                // which scales the bubbles up, keeps the same clearance — see
                // FloatingBubbleMetrics.
                .contentMargins(.bottom, FloatingBubbleMetrics.listBottomMargin(scale: buttonScale))
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button {
                            // Commit rename on Done tap
                            if let alarmID = renamingAlarmID,
                               let alarm = sortedAlarms.first(where: { $0.persistentModelID == alarmID }) {
                                commitRename(alarm)
                            }
                            isRenameFocused = false
                        } label: {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                        }
                    }
                }
                .onChange(of: isRenameFocused) { _, focused in
                    if !focused, let alarmID = renamingAlarmID,
                       let alarm = sortedAlarms.first(where: { $0.persistentModelID == alarmID }) {
                        commitRename(alarm)
                    }
                }
                
            }
            .navigationTitle("Alarms")
            .toolbar { }
            .toolbar(settings.homeWallpaperEnabled ? .hidden : .automatic, for: .navigationBar)
            .sheet(item: $activeSheet) { sheetType in
                Group {
                switch sheetType {
                case .editAlarm(let alarm):
                    AlarmEditorView(
                        alarm: alarm,
                        settings: settings,
                        storeManager: storeManager,
                        onDuplicate: { duplicateAlarm($0) },
                        onDelete: { deleteAlarm($0) }
                    )
                case .newAlarm:
                    NewAlarmEditorView(
                        settings: settings,
                        storeManager: storeManager,
                        onCreate: { newAlarm in
                            // Assign stable MQTT index before inserting
                            newAlarm.alarmIndex = DeviceSettings.shared.assignNextAlarmIndex()
                            modelContext.insert(newAlarm)
                            do {
                                try modelContext.save()
                                print("✅ SwiftData: New alarm saved successfully")
                            } catch {
                                print("❌ SwiftData: Failed to save new alarm: \(error)")
                            }
                            let timeFormatter = DateFormatter()
                            timeFormatter.timeStyle = .short
                            let days = newAlarm.safeRecurringDays.isEmpty ? "one-time" : newAlarm.safeRecurringDays.sorted().map(String.init).joined(separator: ",")
                            AppLogger.shared.log("Alarm created: '\(newAlarm.label)' time=\(timeFormatter.string(from: newAlarm.time)) days=\(days) mission=\(newAlarm.mission.type.rawValue) sound=\(newAlarm.soundName) vol=\(newAlarm.customVolumeLevel.map { String(format: "%.0f%%", $0 * 100) } ?? "default") snooze=\(newAlarm.snoozeDuration)min", category: .alarm)
                            Analytics.shared.log(.alarmCreated(
                                missionCount: newAlarm.missionSequence.count,
                                hasRadio: newAlarm.radioStationURL != nil,
                                hasNotes: newAlarm.hasNotesContent,
                                hasSwipeCommands: newAlarm.swipeLeftCommandID != nil || newAlarm.swipeRightCommandID != nil,
                                isRecurring: newAlarm.isRecurring
                            ))
                            Task {
                                await DualAlarmCoordinator.shared.scheduleAlarm(newAlarm)
                                updateMQTTStatus()
                            }
                        }
                    )
                case .sleepSounds:
                    // Full-height page — houses both sleep sounds and radio
                    SleepSoundSetupView(settings: settings)
                case .quickAlarm:
                    QuickAlarmView(
                        settings: settings,
                        onCreate: { newAlarm in
                            // Quick alarms are ephemeral — no per-alarm MQTT index
                            // They publish as a dedicated "Quick Alarm" dashboard sensor instead
                            modelContext.insert(newAlarm)
                            do {
                                try modelContext.save()
                                print("✅ SwiftData: Quick alarm saved successfully")
                            } catch {
                                print("❌ SwiftData: Failed to save quick alarm: \(error)")
                            }
                            AppLogger.shared.log("Quick alarm created: '\(newAlarm.label)' fires at \(newAlarm.time)", category: .alarm)
                            Analytics.shared.log(.alarmCreated(
                                missionCount: newAlarm.missionSequence.count,
                                hasRadio: newAlarm.radioStationURL != nil,
                                hasNotes: newAlarm.hasNotesContent,
                                hasSwipeCommands: newAlarm.swipeLeftCommandID != nil || newAlarm.swipeRightCommandID != nil,
                                isRecurring: newAlarm.isRecurring
                            ))
                            Task {
                                await DualAlarmCoordinator.shared.scheduleAlarm(newAlarm)
                                updateMQTTStatus()
                            }
                        }
                    )
                    // Allow expanding to large so content is never clipped on tall devices
                    .presentationDetents([.medium, .large], selection: $quickAlarmDetent)
                    // Ensures scroll gesture scrolls content rather than collapsing the sheet
                    .presentationContentInteraction(.scrolls)
                case .settings(let expandMQTT):
                    SettingsView(settings: settings, storeManager: storeManager, initiallyOpenIntegrationSettings: expandMQTT)
                case .proPaywall:
                    ProPaywallView(storeManager: storeManager)
                }
                }
                // Sheets get their own environment — re-apply the app appearance
                // + accent so an in-Settings Light/Dark toggle recolors this sheet
                // (and the alarm editor) immediately, not only after reopening.
                .appAppearanceTheme(settings)
            }
            .onReceive(NotificationCenter.default.publisher(for: .dismissSettingsSheet)) { _ in
                activeSheet = nil
            }
            #if DEBUG
            // Kids Sleep (al-2se). Store mutations publish the retained MQTT
            // schedule themselves — the view layer never talks to the broker.
            .fullScreenCover(isPresented: $showSleepTimerCreate) {
                SleepTimerKidPickerView(settings: settings) { session, bedtimeAlarm in
                    SleepTimerStore.shared.start(session, bedtimeAlarm: bedtimeAlarm)
                    showSleepTimerCreate = false
                }
                .appAppearanceTheme(settings)
            }
            // (Home-card tap-to-edit removed by user decision — the card is
            // swipe-to-cancel only; wake-point editing lives in the picker.)
            // Expiry needs BOTH hooks: the foreground transition catches
            // sessions that ended while backgrounded, and the periodic sweep
            // catches ones that end while the app sits open — without it the
            // finished card lingered on screen until the next foreground. The
            // sweep is a .task loop, not an inline Timer.publish: a publisher
            // created inline in body resubscribes and restarts its countdown on
            // every re-evaluation, so under frequent re-renders it could starve
            // and never fire. A .task is tied to view lifetime and survives
            // body re-evaluation (al-cmd).
            .onChange(of: wallpaperScenePhase) { _, newPhase in
                if newPhase == .active { SleepTimerStore.shared.clearIfExpired() }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    SleepTimerStore.shared.clearIfExpired()
                }
            }
            #endif


            // Note: Removed .fullScreenCover for ActiveAlarmView
            // We now use AlarmWindowManager which shows FullScreenAlarmView directly
            .overlay {
                if sortedAlarms.isEmpty && !SleepSoundManager.shared.isActive {
                    ContentUnavailableView(
                        "No Alarms",
                        systemImage: "alarm",
                        description: Text("Tap + to create your first alarm")
                    )
                    .foregroundStyle(settings.homeWallpaperEnabled ? .white : .secondary)
                }
            }
            .overlay {
                // Dismiss scrim when any menu is expanded
                if isAddMenuExpanded || isSettingsMenuExpanded {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.smooth(duration: 0.2)) {
                                isAddMenuExpanded = false
                                isSettingsMenuExpanded = false
                            }
                        }
                }
            }
            .overlay(alignment: .bottom) {
                floatingButtons
            }
            // DEBUG: Remove before shipping — floating weather test button
            .overlay(alignment: .topLeading) {
                #if DEBUG
                if settings.debugHomeBubblesEnabled {
                Menu {
                    Section("Debug Toggles") {
                        Toggle("Disable Weather API", isOn: Binding(
                            get: { settings.debugDisableWeatherAPI },
                            set: { settings.debugDisableWeatherAPI = $0 }
                        ))
                        Toggle("Mission Wallpaper", isOn: Binding(
                            get: { settings.debugMissionWallpaperEnabled },
                            set: { settings.debugMissionWallpaperEnabled = $0 }
                        ))
                        Toggle("Alarm Screen Bubble", isOn: Binding(
                            get: { settings.debugAlarmScreenBubbleEnabled },
                            set: { settings.debugAlarmScreenBubbleEnabled = $0 }
                        ))
                    }

                    Divider()

                    Button("Live Weather") {
                        AlarmWindowManager.shared.showWeatherCardPreview()
                    }
                    Button("Theme Colors…") {
                        showThemeColorEditor = true
                    }

                } label: {
                    Image(systemName: "cloud.sun.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .padding(.leading, 16)
                .padding(.top, settings.homeWallpaperEnabled ? 60 : 8)
                .sheet(isPresented: $showThemeColorEditor) {
                    ThemeColorEditorView(settings: settings)
                        .appAppearanceTheme(settings)
                }
                }
                #endif
            }
            .overlay(alignment: .topTrailing) {
                #if DEBUG
                // Floating alarm-screen cycler bubble — gated by its debug toggle.
                if settings.debugHomeBubblesEnabled && settings.debugAlarmScreenBubbleEnabled {
                    Button {
                        showAlarmScreenCycler = true
                    } label: {
                        Image(systemName: "bell.badge.waveform.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    }
                    .padding(.trailing, 16)
                    .padding(.top, settings.homeWallpaperEnabled ? 60 : 8)
                    .fullScreenCover(isPresented: $showAlarmScreenCycler) {
                        AlarmScreenCyclerView(settings: settings)
                    }
                }
                #endif
            }
            
            .background {
                if settings.homeWallpaperEnabled, let homeWallpaper {
                    GeometryReader { geo in
                        let useDark = colorScheme == .dark
                        Image(uiImage: homeWallpaper)
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(useDark ? settings.homeDarkWallpaperScale : settings.homeWallpaperScale)
                            .offset(
                                x: useDark ? settings.homeDarkWallpaperOffsetX : settings.homeWallpaperOffsetX,
                                y: useDark ? settings.homeDarkWallpaperOffsetY : settings.homeWallpaperOffsetY
                            )
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                        
                        // Dimming overlay
                        Color.black.opacity(useDark ? settings.homeDarkWallpaperDimming : settings.homeWallpaperDimming)
                    }
                    .ignoresSafeArea()
                } else {
                    Color(uiColor: .systemGroupedBackground)
                }
            }
            .scrollContentBackground(settings.homeWallpaperEnabled && homeWallpaper != nil ? .hidden : .automatic)
        }
        .onChange(of: alarms) { oldValue, newValue in
            updateMQTTStatus()
        }
        .onAppear {
            // Load wallpaper for current appearance
            let key = settings.activeHomeWallpaperKey(forDark: colorScheme == .dark)
            homeWallpaper = settings.loadWallpaper(for: key)
            updateNavBarAppearance()
            updateStatusBarStyle()
            
            // Clean up stale snooze states ONLY when snoozeUntil is nil
            // (corrupt data). When snoozeUntil is in the past, the snooze
            // expired and the alarm needs to RE-FIRE — the scenePhase .active
            // handler detects expired snoozes and fires them. Resetting
            // isSnoozed here would prevent that recovery.
            for alarm in alarms where alarm.isSnoozed {
                if alarm.snoozeUntil == nil {
                    alarm.isSnoozed = false
                    alarm.snoozeCount = 0
                }
            }

            // Clear stale skipped-fire dates whose time has already passed.
            // isSkipped() auto-expires via Date() comparison, but the underlying
            // value persists until explicitly cleared. Doing it here ensures the
            // skip button re-appears for the next occurrence immediately on view load.
            for alarm in alarms where alarm.skippedFireDate != nil {
                if let skipped = alarm.skippedFireDate, skipped < Date() {
                    alarm.skippedFireDate = nil
                }
            }
            
            // Only request authorization once to avoid blocking UI on every view appearance.
            // If onboarding hasn't been completed yet, OnboardingView handles this.
            if !hasRequestedAuthorization && DeviceSettings.shared.hasCompletedOnboarding {
                hasRequestedAuthorization = true
                Task {
                    _ = await DualAlarmCoordinator.shared.requestAuthorization()
                }
            }
            
            // Update MQTT status synchronously (no await needed)
            updateMQTTStatus()
            
            // Publish current alarm state to MQTT if enabled
            if settings.mqttEnabled {
                mqttManager.publishCurrentAlarmState(
                    alarms: alarms,
                    settings: settings
                )
            }

            // Consider the support prompt on cold-launch too (scenePhase may not toggle).
            maybeShowSupportPrompt()
        }
        // Listen for alarm dismissed notification
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AlarmDismissed")).receive(on: DispatchQueue.main)) { notification in
            if let alarmID = notification.userInfo?["alarmID"] as? Int {
                let label = notification.userInfo?["alarmLabel"] as? String
                handleAlarmDismissed(alarmID: alarmID, label: label)
            }
        }
        // Listen for alarm state changes (toggles, edits, etc.)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AlarmStateChanged")).receive(on: DispatchQueue.main)) { _ in
            // Small delay so @Query reflects SwiftData changes before republish
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                updateMQTTStatus()
            }
        }
        // Republish per-alarm discovery + state when MQTT reconnects.
        // Delay 500ms so SwiftData's @Query has time to fully reload before
        // we publish — avoids capturing a partial alarm list on rapid reconnects
        // which would trigger the stale-purge and clear retained broker data.
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MQTTDidConnect")).receive(on: DispatchQueue.main)) { _ in
            print("📡 MQTTDidConnect received: mqttEnabled=\(settings.mqttEnabled), isConnected=\(mqttManager.isConnected), alarmCount=\(alarms.count)")
            guard settings.mqttEnabled else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard mqttManager.isConnected else { return }
                print("📡 MQTTDidConnect (delayed): publishing alarm state, alarmCount=\(alarms.count)")
                mqttManager.publishCurrentAlarmState(
                    alarms: alarms,
                    settings: settings
                )
            }
        }
        // Listen for alarm snoozed notification (Option B: restore volume on snooze)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AlarmSnoozed")).receive(on: DispatchQueue.main)) { _ in
            Task { @MainActor in
                VolumeManager.shared.restoreOriginalVolume()
                print("🔊 Volume restored after snooze (Option B)")
            }
        }
        .onChange(of: colorScheme) { _, newScheme in
            let key = settings.activeHomeWallpaperKey(forDark: newScheme == .dark)
            print("[Theme] onChange(colorScheme) → \(newScheme == .dark ? "dark" : "light") key=\(key)")
            homeWallpaper = settings.loadWallpaper(for: key)
            print("[Theme]   wallpaper loaded: \(homeWallpaper != nil ? "\(Int(homeWallpaper!.size.width))x\(Int(homeWallpaper!.size.height))" : "nil")")
        }
        .onChange(of: settings.homeWallpaperEnabled) { _, newValue in
            let key = settings.activeHomeWallpaperKey(forDark: colorScheme == .dark)
            print("[Theme] onChange(homeWallpaperEnabled) → \(newValue) key=\(key)")
            homeWallpaper = settings.loadWallpaper(for: key)
            updateNavBarAppearance()
            updateStatusBarStyle()
        }
        .onChange(of: settings.appliedHomePresetID) { oldID, newID in
            let key = settings.activeHomeWallpaperKey(forDark: colorScheme == .dark)
            print("[Theme] onChange(appliedHomePresetID) \(oldID ?? "nil") → \(newID ?? "nil") key=\(key)")
            homeWallpaper = settings.loadWallpaper(for: key)
            print("[Theme]   wallpaper loaded: \(homeWallpaper != nil ? "\(Int(homeWallpaper!.size.width))x\(Int(homeWallpaper!.size.height))" : "nil")")
            updateNavBarAppearance()
            updateStatusBarStyle()
        }
        .onChange(of: wallpaperScenePhase) { _, phase in
            // Deliberately does NOT release the wallpaper on .background.
            //
            // That was tried and reverted: dropping it meant every return to
            // the app rendered a blank white screen while the bitmap
            // re-decoded on the main thread. The memory it saved isn't worth
            // that — at the downsampled size this is ~20 MB, not the ~150 MB
            // that made full-resolution presets a jetsam risk, and the NSCache
            // in DeviceSettings plus the memory-warning purge already let the
            // system reclaim it when there is genuine pressure.
            //
            // Reload only if something else dropped it (a memory warning).
            if phase == .active, homeWallpaper == nil, settings.homeWallpaperEnabled {
                let key = settings.activeHomeWallpaperKey(forDark: colorScheme == .dark)
                homeWallpaper = settings.loadWallpaper(for: key)
            }
            if phase == .active { maybeShowSupportPrompt() }
        }
        .sheet(isPresented: $showingSupportPrompt) {
            SupportPromptView(
                onSupport: {
                    // Open the tip jar after this sheet finishes dismissing, so the two
                    // sheets don't try to present simultaneously.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        activeSheet = .proPaywall
                    }
                },
                onShared: { SupportPromptManager.shared.handleShared() },
                onDismiss: { SupportPromptManager.shared.handleDismissed() }
            )
            .appAppearanceTheme(settings)
        }
    }

    /// Presents the periodic support prompt if it's due and the moment is right — never
    /// over a firing alarm or another sheet. The active-use day for today is credited by
    /// the app-level scenePhase handler; the short delay lets that (and any alarm state)
    /// settle before we check, so the threshold-crossing day isn't missed by a race.
    private func maybeShowSupportPrompt() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard !showingSupportPrompt,
                  activeSheet == nil,
                  !AlarmWindowManager.shared.isShowingAlarm,
                  !AlarmSoundPlayer.shared.isPlaying,
                  DeviceSettings.shared.hasCompletedOnboarding,
                  SupportPromptManager.shared.shouldPrompt
            else { return }
            showingSupportPrompt = true
        }
    }
    
    // Note: Removed handleAlarmFired and handleAlarmSnoozed - 
    // These are now handled by AlarmWindowManager and FullScreenAlarmView
    
    /// Resolved color customization for the current appearance
    private var toolbarColors: HomeColorCustomization {
        settings.homeColors(for: colorScheme)
    }
    
    /// Custom glass-styled toolbar replacing the hidden NavigationBar when wallpaper is enabled.
    /// Placed directly in the VStack body, so it sits right below the safe area (status bar).
    private var glassToolbar: some View {
        let toolbarColor = toolbarColors.resolvedToolbarColor
        
        return VStack(alignment: .leading, spacing: 0) {
            // Title row
            Text("Alarms")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(toolbarColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            
            // Banners, then the widget — a reliability warning must never sit
            // below the control it's warning about.
            homeBanners
            armWidget
        }
    }

    /// The home banners, in fixed priority order. The ones above mean alarms may
    /// not ring; What's New is news and must never push a reliability warning
    /// off the top of the screen.
    private var homeBanners: some View {
        VStack(spacing: 8) {
            // Notifications-off warning — alarms won't ring without notification permission.
            AlarmPermissionBanner()
            // Background refresh warning banner (Alarmy-style)
            BackgroundRefreshBanner()
            // Above What's New: this is a safety-relevant removal, not news, and
            // unlike What's New it ignores the product-updates opt-in.
            NWSRemovalBanner()
            // Below the safety-adjacent notices — alarms ring in every persistence
            // mode — but above the rest, because the default changed underneath
            // every user (including anyone who had chosen Off) and nothing else
            // tells them. Shown once, then latched.
            DynamicModeBanner()
            // Radio alarms silently degrade to their tone without persistence.
            RadioPersistenceBanner()
            // (The "You slept through …" home banner was removed 2026-08-10 by
            // user decision; slept-through detection now surfaces only via the
            // Home Assistant sensor — see SleptThroughNotice / al-ad1.)
            WhatsNewBanner()
            // (Kids Sleep trackers moved into the List so they get the native
            // swipe-to-reveal delete, matching the alarm rows.)
        }
    }

    /// The Home Assistant arm/command widget. Shared by both layouts so the two
    /// paths can't drift — they previously carried separate copies with different
    /// top padding.
    @ViewBuilder
    private var armWidget: some View {
        if settings.armButtonEnabled && settings.mqttEnabled {
            ArmButtonView(
                settings: settings,
                mqttManager: mqttManager
            )
            // Rebuild on light/dark change — glassEffect holds a stale
            // render across trait changes when the host isn't recreated.
            .id(colorScheme)
            .padding(.horizontal, 16)
            // Breathing room under whichever banners are showing.
            .padding(.top, 10)
        }
    }
    
    // MARK: - Floating Bottom Buttons
    
    @State private var showingMQTTInfo = false
    
    /// Scale factor matching alarm row sizing
    private var buttonScale: CGFloat {
        settings.biggerAlarmRows ? 1.15 : 1.0
    }

    /// Diameter of the two floating bubbles at the current button scale.
    private var bubbleDiameter: CGFloat {
        FloatingBubbleMetrics.diameter(scale: buttonScale)
    }

    /// Resolved button tint color — the theme's toolbar color when wallpaper is
    /// on, the app accent otherwise.
    ///
    /// The no-wallpaper branch was a literal `.blue`, so the home screen's
    /// floating buttons ignored a custom accent entirely (al-nl9). The toolbar
    /// color is its own theme role and stays as-is.
    private var floatingButtonColor: Color {
        settings.homeWallpaperEnabled
            ? toolbarColors.resolvedToolbarColor
            : settings.appAccent(for: colorScheme)
    }
    
    /// Connected reads the app accent (override included), matching the status
    /// sheet's own connected dot — the raw theme skip slot it used before is a
    /// different role and ignored a hand-picked accent. The other four states
    /// are semantic (warning/error/off) and deliberately stay fixed.
    private var mqttStatusColor: Color {
        switch mqttManager.connectionState {
        case .connected: return settings.appAccent(for: colorScheme)
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .notConfigured: return .orange
        case .error: return .red
        }
    }
    
    private var floatingButtons: some View {
        HStack(alignment: .bottom) {
            // Left: Settings gear with expandable menu (when MQTT enabled)
            VStack(spacing: 12 * buttonScale) {
                if isSettingsMenuExpanded {
                    VStack(spacing: 8 * buttonScale) {
                        // Settings option
                        Button {
                            withAnimation(.smooth(duration: 0.2)) { isSettingsMenuExpanded = false }
                            AppLogger.shared.log("Opened Settings", category: .general)
                            activeSheet = .settings()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 16 * buttonScale, weight: .medium))
                                Text("Settings")
                                    .font(.system(size: 15 * buttonScale, weight: .semibold))
                            }
                            .foregroundStyle(floatingButtonColor)
                            .padding(.horizontal, 20 * buttonScale)
                            .padding(.vertical, 12 * buttonScale)
                            .background(.ultraThinMaterial, in: Capsule())
                            .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                        
                        // MQTT Status option
                        Button {
                            withAnimation(.smooth(duration: 0.2)) { isSettingsMenuExpanded = false }
                            showingMQTTInfo = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "network")
                                    .font(.system(size: 16 * buttonScale, weight: .medium))
                                Text("MQTT Status")
                                    .font(.system(size: 15 * buttonScale, weight: .semibold))
                                Circle()
                                    .fill(mqttStatusColor)
                                    .frame(width: 8, height: 8)
                            }
                            .foregroundStyle(floatingButtonColor)
                            .padding(.horizontal, 20 * buttonScale)
                            .padding(.vertical, 12 * buttonScale)
                            .background(.ultraThinMaterial, in: Capsule())
                            .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                }
                
                // The gear bubble
                Button {
                    if settings.mqttEnabled {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isSettingsMenuExpanded.toggle()
                            isAddMenuExpanded = false
                        }
                    } else {
                        withAnimation(.smooth(duration: 0.2)) { isAddMenuExpanded = false }
                        AppLogger.shared.log("Opened Settings", category: .general)
                        activeSheet = .settings()
                    }
                } label: {
                    Image(systemName: isSettingsMenuExpanded ? "xmark" : "gear")
                        .font(.system(size: 22 * buttonScale, weight: .semibold))
                        .foregroundStyle(floatingButtonColor)
                        .frame(width: bubbleDiameter, height: bubbleDiameter)
                        .background(.ultraThinMaterial, in: Circle())
                        // Match the + bubble: hit the circle, not the square.
                        .contentShape(Circle())
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                        .overlay {
                            if settings.mqttEnabled && !isSettingsMenuExpanded {
                                Circle()
                                    .strokeBorder(mqttStatusColor.opacity(0.8), lineWidth: 2)
                                    .frame(width: bubbleDiameter, height: bubbleDiameter)
                                    // Decoration only — the MQTT ring must never
                                    // take a touch off the bubble or the row below.
                                    .allowsHitTesting(false)
                            }
                        }
                        .rotationEffect(.degrees(isSettingsMenuExpanded ? 90 : 0))
                }
                // Clamp OUTSIDE the Button as well as inside its label. A content
                // shape set within the label only limits the label; the button
                // style wrapping it can still claim the full rectangular frame,
                // which is how the square's corners kept eating taps aimed at the
                // Skip button of the row behind it (al-xyq). The explicit frame
                // is a no-op at the label's own size — it just pins what the
                // circle is inscribed in.
                .frame(width: bubbleDiameter, height: bubbleDiameter)
                .contentShape(.interaction, Circle())
                .sheet(isPresented: $showingMQTTInfo) {
                    MQTTStatusDetailView(
                        mqttManager: mqttManager,
                        settings: settings,
                        onOpenSettings: {
                            showingMQTTInfo = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                activeSheet = .settings(expandMQTT: true)
                            }
                        }
                    )
                    // Sheets get their own environment — without this, a forced
                    // Light/Dark appearance leaves the sheet on the DEVICE scheme
                    // and its connected dots resolve the wrong per-scheme accent.
                    .appAppearanceTheme(settings)
                }
            }
            
            // Explicitly inert: this strip lies across the full width of the
            // list, directly over the column the rows draw their Skip button in.
            // Nothing between the two bubbles may take a touch.
            Spacer()
                .allowsHitTesting(false)

            // Right: Add alarm
            HStack(spacing: 12 * buttonScale) {
                // Add alarm: + bubble with expandable options above
                VStack(spacing: 12 * buttonScale) {
                    if isAddMenuExpanded {
                        VStack(spacing: 8 * buttonScale) {
                            // New Alarm option
                            Button {
                                withAnimation(.smooth(duration: 0.2)) { isAddMenuExpanded = false }
                                addAlarm()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "alarm")
                                        .font(.system(size: 16 * buttonScale, weight: .medium))
                                    Text("New Alarm")
                                        .font(.system(size: 15 * buttonScale, weight: .semibold))
                                }
                                .foregroundStyle(floatingButtonColor)
                                .padding(.horizontal, 20 * buttonScale)
                                .padding(.vertical, 12 * buttonScale)
                                .background(.ultraThinMaterial, in: Capsule())
                                .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                            
                            // Quick Alarm option
                            Button {
                                withAnimation(.smooth(duration: 0.2)) { isAddMenuExpanded = false }
                                openQuickAlarm()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 16 * buttonScale, weight: .medium))
                                    Text("Quick Alarm")
                                        .font(.system(size: 15 * buttonScale, weight: .semibold))
                                }
                                .foregroundStyle(floatingButtonColor)
                                .padding(.horizontal, 20 * buttonScale)
                                .padding(.vertical, 12 * buttonScale)
                                .background(.ultraThinMaterial, in: Capsule())
                                .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))

                            // Sleep Sounds option
                            if !SleepSoundManager.shared.isActive {
                                Button {
                                    withAnimation(.smooth(duration: 0.2)) { isAddMenuExpanded = false }
                                    activeSheet = .sleepSounds
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "moon.zzz.fill")
                                            .font(.system(size: 16 * buttonScale, weight: .medium))
                                        Text("Sleep Sounds")
                                            .font(.system(size: 15 * buttonScale, weight: .semibold))
                                    }
                                    .foregroundStyle(floatingButtonColor)
                                    .padding(.horizontal, 20 * buttonScale)
                                    .padding(.vertical, 12 * buttonScale)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
                                }
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            }

                            #if DEBUG
                            // Kids Sleep (al-2se): debug-only. Always shown —
                            // the picker inside handles per-kid start vs edit.
                            Button {
                                withAnimation(.smooth(duration: 0.2)) { isAddMenuExpanded = false }
                                showSleepTimerCreate = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "moon.stars.fill")
                                        .font(.system(size: 16 * buttonScale, weight: .medium))
                                    Text("Kids Sleep")
                                        .font(.system(size: 15 * buttonScale, weight: .semibold))
                                }
                                .foregroundStyle(floatingButtonColor)
                                .padding(.horizontal, 20 * buttonScale)
                                .padding(.vertical, 12 * buttonScale)
                                .background(.ultraThinMaterial, in: Capsule())
                                .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                            #endif

                        }
                    }
                    
                    // The + bubble
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isAddMenuExpanded.toggle()
                            isSettingsMenuExpanded = false
                        }
                    } label: {
                        Image(systemName: isAddMenuExpanded ? "xmark" : "plus")
                            .font(.system(size: 24 * buttonScale, weight: .semibold))
                            .foregroundStyle(floatingButtonColor)
                            .frame(width: bubbleDiameter, height: bubbleDiameter)
                            .background(.ultraThinMaterial, in: Circle())
                            // Hit-test the CIRCLE, not its bounding square: the square's
                            // corners reach ~8pt past the visible bubble and were eating
                            // taps meant for the row Skip button that scrolls past it.
                            .contentShape(Circle())
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                            .rotationEffect(.degrees(isAddMenuExpanded ? 90 : 0))
                    }
                    // See the gear bubble: the label-level content shape is not
                    // enough on its own, because the button style around it can
                    // still claim the rectangular frame. Clamp here too.
                    .frame(width: bubbleDiameter, height: bubbleDiameter)
                    .contentShape(.interaction, Circle())
                }
            }
        }
        .padding(.horizontal, 24)
        // Shared with the list's bottom content margin so the two can't drift.
        .padding(.bottom, FloatingBubbleMetrics.bottomInset)
    }

    private func updateNavBarAppearance() {
        if settings.homeWallpaperEnabled {
            // Make the nav bar fully transparent so no gray bar shows behind our custom toolbar
            let transparent = UINavigationBarAppearance()
            transparent.configureWithTransparentBackground()
            transparent.shadowColor = nil
            transparent.backgroundColor = nil
            UINavigationBar.appearance().standardAppearance = transparent
            UINavigationBar.appearance().scrollEdgeAppearance = transparent
            UINavigationBar.appearance().compactAppearance = transparent
        } else {
            // Restore standard nav bar defaults
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
            UINavigationBar.appearance().compactAppearance = nil
        }
        UINavigationBar.appearance().tintColor = nil
    }

    /// Force the system status bar to white for home presets that ship a dark
    /// light-mode wallpaper; otherwise leave it following the app color scheme.
    private func updateStatusBarStyle() {
        StatusBarStyleController.shared.setOverride(
            settings.appliedHomePresetPrefersLightStatusBar() ? .lightContent : nil
        )
    }

    private func addAlarm() {
        AppLogger.shared.log("Opened New Alarm editor", category: .alarm)
        activeSheet = .newAlarm
    }
    
    /// Opens the Quick Alarm sheet (timer-style "alarm in X minutes")
    private func openQuickAlarm() {
        AppLogger.shared.log("Opened Quick Alarm editor", category: .alarm)
        activeSheet = .quickAlarm
    }
    
    private func deleteAlarm(_ alarm: Alarm) {
        AppLogger.shared.log("Alarm deleted: '\(alarm.label)' enabled=\(alarm.isEnabled)", category: .alarm)
        Analytics.shared.log(.alarmDeleted)
        // Clear all retained MQTT data for this alarm from the broker
        if settings.mqttEnabled {
            MQTTManager.shared.clearDeletedAlarm(alarmIndex: alarm.alarmIndex, settings: settings)
        }
        Task {
            await DualAlarmCoordinator.shared.cancelAlarm(alarm)
        }
        modelContext.delete(alarm)
        do {
            try modelContext.save()
            print("✅ SwiftData: Alarm delete saved successfully")
        } catch {
            print("❌ SwiftData: Failed to save alarm delete: \(error)")
        }
        // Delay so @Query reflects the deletion before we republish next-alarm
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            updateMQTTStatus()
        }
    }
    
    private func skipNextAlarm(_ alarm: Alarm) {
        if alarm.isRecurring {
            // Recurring alarm: skip the next occurrence
            alarm.skippedFireDate = alarm.nextFireDate()
            AppLogger.shared.log("Alarm skipped: '\(alarm.label)' skipping fire at \(alarm.skippedFireDate.map(String.init(describing:)) ?? "nil")", category: .alarm)
            
            Task {
                await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
                // Delay so @Query reflects skippedFireDate change before republish
                try? await Task.sleep(for: .milliseconds(150))
                updateMQTTStatus()
            }
        } else {
            // One-time alarm: disable it
            alarm.isEnabled = false
            AppLogger.shared.log("Alarm skipped (one-time disabled): '\(alarm.label)'", category: .alarm)
            
            Task {
                await DualAlarmCoordinator.shared.cancelAlarm(alarm)
                // Delay so @Query reflects isEnabled change before republish
                try? await Task.sleep(for: .milliseconds(150))
                updateMQTTStatus()
            }
        }
    }
    
    private func unskipAlarm(_ alarm: Alarm) {
        alarm.skippedFireDate = nil
        AppLogger.shared.log("Alarm unskipped: '\(alarm.label)'", category: .alarm)
        
        Task {
            await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
            // Delay so @Query reflects cleared skip before republish
            try? await Task.sleep(for: .milliseconds(150))
            updateMQTTStatus()
        }
    }
    
    private func handleAlarmDismissed(alarmID: Int, label: String? = nil) {
        // Find the alarm — try hash first, then fall back to label match
        let alarm: Alarm?
        let matchMethod: String
        if let exact = alarms.first(where: { $0.stableHash == alarmID }) {
            alarm = exact
            matchMethod = "hash"
        } else if let lbl = label, let byLabel = alarms.first(where: { $0.label == lbl }) {
            alarm = byLabel
            matchMethod = "label"
        } else {
            alarm = alarms.first(where: { $0.isEnabled })
            matchMethod = "first-enabled-fallback"
        }
        if let alarm {
            print("📋 handleAlarmDismissed: matched via \(matchMethod), label='\(alarm.label)', isEphemeral=\(alarm.isEphemeral), alarmID=\(alarmID)")
            
            // Mark as fired
            alarm.lastFireDate = Date()

            // Always reset snooze state on dismiss — regardless of alarm type.
            // AlarmWindowManager.dismissAlarm() resets on its own ModelContext instance,
            // but AlarmListView's @Query uses the view's context, so we must reset here too.
            alarm.isSnoozed = false
            alarm.snoozeUntil = nil
            alarm.snoozeCount = 0

            // A kid's bedtime alarm (al-5a94) retires the moment it is dismissed.
            // It is a one-shot for tonight, so leaving a disabled row in the list
            // until the session expires at wake was just clutter (owner request
            // 2026-08-22, al-02is). Asking the store also RELEASES its mapping,
            // so the later cancel/expiry sweep does not chase a deleted row.
            //
            // Deliberately NOT implemented by setting `isEphemeral`: quick-alarm
            // -ness also puts an alarm on the Quick Alarm MQTT sensor and inside
            // `delete_quick_alarm`'s reach, and neither filters
            // `excludeFromMQTT` — this alarm has to stay invisible to HA.
            let isDismissedBedtimeAlarm = alarm.stableID.map {
                SleepTimerStore.shared.claimDismissedBedtimeAlarm(alarmID: $0)
            } ?? false

            // If it's an ephemeral alarm (quick alarm), delete it entirely
            if alarm.isEphemeral || isDismissedBedtimeAlarm {
                // Snapshot before the delete: reading a deleted SwiftData model
                // back out of the Task is a crash, not a blank value.
                let alarmLabel = alarm.label
                let alarmIndex = alarm.alarmIndex
                let publishesToHA = !alarm.excludeFromMQTT
                Task {
                    await DualAlarmCoordinator.shared.cancelAlarm(alarm)
                    await MainActor.run {
                        VolumeManager.shared.restoreOriginalVolume()
                        modelContext.delete(alarm)
                        try? modelContext.save()
                        print("🗑️ One-shot alarm deleted after dismiss: '\(alarmLabel)'")
                    }
                    // Small delay to let SwiftData model deletion propagate before reading @Query
                    try? await Task.sleep(for: .milliseconds(150))
                    updateMQTTStatus()
                    // An MQTT-hidden alarm never set these, so publishing idle
                    // here would flap HA for a ring it never saw — the same
                    // guard `LocalNotificationScheduler.dismissAlarm` applies.
                    if settings.mqttEnabled && publishesToHA {
                        HAIntegrationRouter.shared.publishAlarmState(.idle, settings: settings)
                        HAIntegrationRouter.shared.publishSnoozeCount(0, settings: settings)
                        HAIntegrationRouter.shared.publishSnoozesRemaining(0, settings: settings)
                        // Per-alarm idle state
                        if alarmIndex > 0 {
                            HAIntegrationRouter.shared.publishPerAlarmStateTransition(alarmIndex: alarmIndex, state: .idle, snoozeAllowed: false, settings: settings)
                            HAIntegrationRouter.shared.publishPerAlarmSnoozeFireTime(alarmIndex: alarmIndex, snoozeUntil: nil, settings: settings)
                        }
                    }
                }
                return
            }

            // If it's a one-time alarm, disable it
            if !alarm.isRecurring {
                alarm.isEnabled = false
                print("🔔 One-time alarm dismissed and disabled")
            }

            // Cancel current scheduled notifications and snooze timers, then reschedule if recurring
            Task {
                await DualAlarmCoordinator.shared.cancelAlarm(alarm)
                DualAlarmCoordinator.shared.cancelSnooze(for: alarm)

                // Restore original volume when alarm is fully dismissed
                await MainActor.run {
                    VolumeManager.shared.restoreOriginalVolume()
                    print("🔊 Volume restored after alarm dismissed")
                }

                // Reschedule recurring alarms for their next occurrence
                if alarm.isRecurring && alarm.isEnabled {
                    await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
                    print("🔔 Recurring alarm rescheduled for next occurrence")
                }
                
                // Small delay to let SwiftData model changes propagate before reading @Query
                try? await Task.sleep(for: .milliseconds(150))
                
                updateMQTTStatus()
                
                // Clear current alarm MQTT state
                if settings.mqttEnabled {
                    HAIntegrationRouter.shared.publishAlarmState(.idle, settings: settings)
                    HAIntegrationRouter.shared.publishSnoozeCount(0, settings: settings)
                    HAIntegrationRouter.shared.publishSnoozesRemaining(0, settings: settings)
                    // Per-alarm idle state
                    if alarm.alarmIndex > 0 {
                        HAIntegrationRouter.shared.publishPerAlarmStateTransition(alarmIndex: alarm.alarmIndex, state: .idle, snoozeAllowed: false, settings: settings)
                        HAIntegrationRouter.shared.publishPerAlarmSnoozeFireTime(alarmIndex: alarm.alarmIndex, snoozeUntil: nil, settings: settings)
                    }
                    print("📡 Published alarm cleared to MQTT (state: idle)")
                }
            }
        } else {
            print("⚠️ handleAlarmDismissed: no alarm found for alarmID=\(alarmID), label=\(label ?? "nil"), available=\(alarms.map { "\($0.label)=\($0.stableHash) ephemeral=\($0.isEphemeral)" })")
        }
    }
    
    // Note: dismissAlarm and snoozeAlarm removed - 
    // These are now handled directly in FullScreenAlarmView and AlarmWindowManager
    
    private func updateMQTTStatus() {
        guard settings.mqttEnabled else { return }
        
        // Use helper method to publish all alarm state
        mqttManager.publishCurrentAlarmState(
            alarms: alarms,
            settings: settings
        )
    }
    
    // MARK: - Long-Press Menu
    

    
    // MARK: - Duplicate & Rename
    
    private func duplicateAlarm(_ alarm: Alarm) {
        // The field-by-field copy lives on `Alarm.duplicate` so it sits beside the
        // properties it mirrors — see the contract comment there before adding a
        // new stored property.
        let newAlarm = alarm.duplicate(
            label: DeviceSettings.nextDuplicateName(for: alarm.label, existingNames: alarms.map(\.label)),
            alarmIndex: alarm.isEphemeral ? 0 : settings.assignNextAlarmIndex()
        )
        modelContext.insert(newAlarm)
        do {
            try modelContext.save()
            print("✅ SwiftData: Duplicated alarm saved successfully")
        } catch {
            print("❌ SwiftData: Failed to save duplicated alarm: \(error)")
        }
        AppLogger.shared.log("Alarm duplicated: '\(alarm.label)' → '\(newAlarm.label)'", category: .alarm)
        // A duplicate is a newly persisted alarm, so it counts as a creation.
        Analytics.shared.log(.alarmCreated(
            missionCount: newAlarm.missionSequence.count,
            hasRadio: newAlarm.radioStationURL != nil,
            hasNotes: newAlarm.hasNotesContent,
            hasSwipeCommands: newAlarm.swipeLeftCommandID != nil || newAlarm.swipeRightCommandID != nil,
            isRecurring: newAlarm.isRecurring
        ))
        // Delay so @Query reflects the new alarm before republish
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            updateMQTTStatus()
            // Open editor for the new alarm if the setting is enabled
            if settings.editDuplicatedAlarms {
                activeSheet = .editAlarm(newAlarm)
            }
        }
    }
    
    private func commitRename(_ alarm: Alarm) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            alarm.label = trimmed
            do {
                try modelContext.save()
                print("✅ SwiftData: Alarm rename saved successfully")
            } catch {
                print("❌ SwiftData: Failed to save alarm rename: \(error)")
            }
        }
        renamingAlarmID = nil
        isRenameFocused = false
        // Delay so @Query reflects the name change before republish
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            updateMQTTStatus()
        }
    }
}

struct AlarmRow: View {
    @Bindable var alarm: Alarm
    let settings: DeviceSettings
    let mqttManager: HAIntegrationRouter
    var isRenaming: Bool = false
    @Binding var renameText: String
    var isRenameFocused: FocusState<Bool>.Binding
    let onSkip: () -> Void
    let onUnskip: () -> Void
    let onDelete: () -> Void
    let onTap: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var currentTime = Date()
    @State private var swipeOffset: CGFloat = 0
    @State private var lastSwipeFireTime: Date = .distantPast
    @State private var pendingSwipeCommand: MQTTCommand?
    @State private var showSwipeConfirmAlert = false
    @State private var skipProgress: Double = 0
    @State private var isPressingSkip = false
    @State private var skipCompleted = false
    @State private var holdTimer: Timer?
    // One 1 Hz timer shared by every row — a per-row Timer.publish would put
    // N timers on the run loop and recreate the publisher on each body pass.
    private static let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Cached next fire date, held in a reference box so it can be refreshed
    // during body evaluation without touching view state. Recomputed only when
    // a schedule-relevant field changes or the cached date has passed — the
    // full computation walks up to 15 days of calendar math.
    private final class FireDateCache {
        var scheduleKey: String = ""
        var nextFire: Date?
        var isValid = false
    }
    @State private var fireDateCache = FireDateCache()

    private var scheduleKey: String {
        "\(alarm.isEnabled)|\(alarm.time.timeIntervalSinceReferenceDate)|\(alarm.recurringDaysRaw)|\(alarm.skippedFireDate?.timeIntervalSinceReferenceDate ?? -1)|\(alarm.lastFireDate?.timeIntervalSinceReferenceDate ?? -1)|\(alarm.isEphemeral)"
    }

    private func cachedNextFireDate(at time: Date) -> Date? {
        let key = scheduleKey
        if fireDateCache.isValid, fireDateCache.scheduleKey == key,
           let cached = fireDateCache.nextFire, cached > time {
            return cached
        }
        let computed = alarm.nextFireDate(from: time)
        fireDateCache.scheduleKey = key
        fireDateCache.nextFire = computed
        fireDateCache.isValid = true
        return computed
    }
    
    /// Whether to use dark mode wallpaper settings
    private var useDarkSettings: Bool {
        colorScheme == .dark
    }
    
    /// Resolved color customization for current appearance
    private var colors: HomeColorCustomization {
        settings.homeColors(for: colorScheme)
    }

    /// Base color for the whole hold-to-skip treatment: the chip's label, its
    /// resting wash, the "Keep holding…" line, the fill that rises through
    /// `HoldPressStyle`, and the Undo chip that replaces it once skipped.
    ///
    /// Goes through `settings.skipAccent(for:)` rather than
    /// `colors.resolvedSkipButtonColor` so the user's per-theme accent override
    /// reaches it — reading the slot directly resolved BEFORE the override was
    /// consulted, which is exactly the bug al-4gz reports. Every call site keeps
    /// its own opacity, so only the base moves and the press keeps its depth.
    private var skipAccent: Color {
        settings.skipAccent(for: colorScheme)
    }

    /// Unified arm/disarm toggle tint: ALWAYS the app accent slot, in both
    /// Classic Colorful and muted styles. Each theme still defines its own color
    /// (light/dark can differ) — the unification is within a theme, not across
    /// themes.
    ///
    /// Reads `appAccent(for:)` rather than `colors.resolvedAccentColor` so the
    /// user's per-theme accent override reaches the toggle. Going straight to the
    /// theme's own accent skipped the override entirely, which is why picking a
    /// custom accent left these toggles on the old color (al-nl9). With no
    /// override set the two expressions are identical, so themed defaults are
    /// unchanged.
    private var armToggleTint: Color {
        settings.appAccent(for: colorScheme)
    }

    /// Snoozed or skipped alarms can't be freely toggled — the toggle keeps the
    /// unified tint but is shown grayed out / disabled-looking so it reads as
    /// "can't be messed with" (no more per-state purple/orange tints).
    private var isToggleInactive: Bool {
        alarm.isSnoozed || alarm.isSkipped
    }

    /// Unified color for informational row text (time-until-fire, snooze
    /// countdown, snoozes-remaining). One calm secondary tone across every theme
    /// and mode (light/dark, wallpaper/non-wallpaper) instead of per-state tints.
    private var rowInfoColor: Color { .secondary }

    /// Resolved Glass variant from settings (appearance-aware)
    private var homeGlassVariant: Glass {
        guard settings.homeWallpaperEnabled else { return .identity }
        let variant = useDarkSettings ? settings.homeDarkGlassVariant : settings.homeGlassVariant
        switch variant {
        case 1: return .clear
        case 2:
            let r = useDarkSettings ? settings.homeDarkGlassTintRed : settings.homeGlassTintRed
            let g = useDarkSettings ? settings.homeDarkGlassTintGreen : settings.homeGlassTintGreen
            let b = useDarkSettings ? settings.homeDarkGlassTintBlue : settings.homeGlassTintBlue
            let opacity = useDarkSettings ? settings.homeDarkGlassTintOpacity : settings.homeGlassTintOpacity
            return .regular.tint(Color(red: r, green: g, blue: b).opacity(opacity))
        default: return .regular
        }
    }
    
    /// Scale factor for alarm row sizing
    private var scale: CGFloat {
        settings.biggerAlarmRows ? 1.2 : 1.0
    }
    
    /// Resolved clear dimming (appearance-aware)
    private var homeClearDimming: Double {
        let variant = useDarkSettings ? settings.homeDarkGlassVariant : settings.homeGlassVariant
        guard variant == 1 else { return 0 }
        return useDarkSettings ? settings.homeDarkGlassClearDimming : settings.homeGlassClearDimming
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4 * scale) {
                // Alarm name label (or inline rename field)
                if settings.showAlarmNamesOnHome && !alarm.label.isEmpty {
                    if isRenaming {
                        TextField("Alarm Name", text: $renameText)
                            .font(.system(size: 14 * scale, weight: .medium))
                            .foregroundStyle(textColor(primary: false))
                            .focused(isRenameFocused)
                            .submitLabel(.done)
                    } else {
                        Text(alarm.label)
                            .font(.system(size: 14 * scale, weight: .medium))
                            .foregroundStyle(textColor(primary: false))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                
                HStack(alignment: .lastTextBaseline, spacing: 5 * scale) {
                    Text(timeString)
                        .font(.system(size: settings.biggerAlarmRows ? 50 : 48, weight: .thin))
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(textColor(primary: true))
                    
                    // Slot count for the multi-mission alarms. A single-mission
                    // alarm shows no number at all — "1" would be noise on the
                    // common case.
                    let missionCount = alarm.missionSequence.count
                    // A Tap-only alarm still shows nothing, as before. But a
                    // SEQUENCE that merely starts with Tap used to show nothing
                    // either, which made a three-step alarm look like a plain
                    // tap-to-dismiss one.
                    if alarm.mission.type != .none || missionCount > 1 {
                        // Offset positions the icon's center at the AM/PM vertical midpoint
                        // Use a larger offset in expanded mode to keep the icon higher
                        let amPmOffset: CGFloat = settings.biggerAlarmRows ? 12 : 8
                        HStack(spacing: 3 * scale) {
                            Image(systemName: alarm.mission.type.iconName)
                                .font(.system(size: 15 * scale))
                                .foregroundStyle(missionIconColor)
                                .frame(width: 28 * scale, height: 28 * scale)
                                .background {
                                    RoundedRectangle(cornerRadius: 6 * scale)
                                        .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                                }

                            if missionCount > 1 {
                                // Bare numeral — no chip, no box, no "+". The
                                // glyph already carries the framing, so the count
                                // only has to be legible, and at most one digit
                                // (five slots max) it costs ~10pt of width. That
                                // matters: this line also carries a 48pt time and
                                // the MQTT badge, and on a small phone anything
                                // wider risks clipping.
                                // "+N", where N is how many missions follow the
                                // one the glyph shows — the glyph IS mission one,
                                // so a two-mission alarm reads "+1", not "2".
                                Text("+\(missionCount - 1)")
                                    // Deliberately small. This line is the most
                                    // contended in the app — a 48pt time, the
                                    // mission glyph, and the row's controls — and
                                    // at glyph size the count crowded them even on
                                    // a Pro Max. It only has to be readable, not
                                    // prominent; the glyph is the thing you scan for.
                                    .font(.system(size: 10 * scale, weight: .bold))
                                    .foregroundStyle(missionIconColor)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .accessibilityLabel("\(missionCount) missions total")
                            }
                        }
                        .padding(.leading, 8 * scale)
                        .alignmentGuide(.lastTextBaseline) { d in
                            d[VerticalAlignment.center] + amPmOffset
                        }
                    }
                    
                    // No MQTT badge. It marked alarms Home Assistant created, but
                    // it was the widest thing on this line for the least useful
                    // information — and once the mission count joined the row it
                    // was what got squeezed, wrapping "MQTT" onto two lines even
                    // on a large phone. `alarm.source` is still recorded; nothing
                    // downstream depended on the badge.
                }
                
                if alarm.isRecurring {
                    recurringDaysView
                }
                
                // Show "Keep holding" during skip-hold, otherwise show next fire time.
                //
                // The countdown is the point (al-lwz). Hold Duration is a slider
                // that runs to 30 SECONDS, and at the long end the only feedback
                // was an unquantified "Keep holding…" over a 32%-opacity fill
                // creeping up a small chip — indistinguishable from a button that
                // is simply broken, which is exactly how it was reported. Naming
                // the seconds left turns "this doesn't work" into "this needs
                // eleven more seconds, and I should shorten it in Settings".
                // The alarm screen's own hold already does this
                // (`Text(isHolding ? "Keep holding…" : "Hold \(…)s")` in
                // ActiveAlarmView); the list was the surface that didn't.
                if isPressingSkip {
                    HStack(spacing: 4 * scale) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 12 * scale))
                        Text("Keep holding… \(skipHoldSecondsRemaining)s")
                            .font(.system(size: 12 * scale, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    .foregroundStyle(skipAccent)
                } else if let nextFire = cachedNextFireDate(at: currentTime), nextFire > currentTime, !alarm.isSnoozed {
                    HStack(spacing: 4 * scale) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 12 * scale))
                        Text(timeUntil(nextFire, at: currentTime))
                            .font(.system(size: 12 * scale))
                    }
                    .foregroundStyle(alarm.isEnabled ? rowInfoColor : rowInfoColor.opacity(0.3))
                }
                

                
                // Show snoozed indicator
                if alarm.isSnoozed, let snoozeUntil = alarm.snoozeUntil, snoozeUntil > currentTime {
                    let maxSnoozes = alarm.maxSnoozeCount ?? settings.defaultMaxSnoozeCount
                    let snoozesLeft = maxSnoozes == 0 ? 0 : max(0, maxSnoozes - alarm.snoozeCount)
                    let timeRemaining = snoozeUntil.timeIntervalSince(currentTime)

                    HStack(spacing: 5 * scale) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(rowInfoColor)
                        Text(snoozeCountdownText(timeRemaining: timeRemaining))
                            .font(.system(size: 12 * scale))
                            .fontWeight(.semibold)
                            .foregroundStyle(rowInfoColor)
                        if maxSnoozes > 0 && snoozesLeft > 0 {
                            Image(systemName: "moon.zzz.fill")
                                .font(.system(size: 11 * scale))
                                .foregroundStyle(rowInfoColor)
                            Text("\(snoozesLeft)")
                                .font(.system(size: 12 * scale))
                                .fontWeight(.semibold)
                                .foregroundStyle(rowInfoColor)
                        }
                    }
                }
                
                

            }
            
            Spacer()
            
            VStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { alarm.isEnabled },
                    set: { newValue in
                        // Prevent disabling while snoozed
                        if !newValue && alarm.isSnoozed {
                            print("⚠️ Cannot disable alarm while snoozed")
                            return
                        }
                        
                        print("🟡 Toggle changed: \(alarm.isEnabled) → \(newValue), isRecurring: \(alarm.isRecurring), lastFireDate: \(String(describing: alarm.lastFireDate))")
                        AppLogger.shared.log("Alarm toggled: '\(alarm.label)' \(alarm.isEnabled ? "ON" : "OFF") → \(newValue ? "ON" : "OFF")", category: .alarm)
                        
                        // Turning off a quick (ephemeral) alarm deletes it
                        if !newValue && alarm.isEphemeral {
                            onDelete()
                            return
                        }
                        
                        // Allow re-enabling one-time alarms even if they've fired
                        // Just clear the lastFireDate to make them schedulable again
                        if newValue && !alarm.isRecurring && alarm.lastFireDate != nil {
                            alarm.lastFireDate = nil
                            print("🔔 One-time alarm re-enabled, cleared lastFireDate")
                        }
                        
                        // Update the enabled state
                        alarm.isEnabled = newValue
                        
                        Task {
                            if newValue {
                                print("🟡 Scheduling alarm...")
                                await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
                            } else {
                                print("🟡 Cancelling alarm...")
                                await DualAlarmCoordinator.shared.cancelAlarm(alarm)
                            }
                        }
                        
                        // Immediately publish this alarm's enabled state to MQTT
                        if settings.mqttEnabled && alarm.alarmIndex > 0 {
                            HAIntegrationRouter.shared.publishPerAlarmState(alarm: alarm, settings: settings)
                        }
                        
                        // Trigger full MQTT refresh (counts, next alarm, etc.)
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(100))
                            NotificationCenter.default.post(
                                name: NSNotification.Name("AlarmStateChanged"),
                                object: nil
                            )
                        }
                    }
                ))
                    .labelsHidden()
                    .tint(armToggleTint)
                    .grayscale(isToggleInactive ? 1.0 : 0.0)
                    .opacity(isToggleInactive ? 0.55 : 1.0)
                    .disabled(alarm.isSnoozed)  // Disable toggle when snoozed
                
                // Show skip button if skip mode is not disabled, alarm is enabled, not skipped, and NOT snoozed
                // For recurring alarms: skips the next occurrence
                // For one-time alarms: turns the alarm off
                // Hidden for ephemeral (quick) alarms — toggling off deletes them instead
                if alarm.effectiveSkipMode(settings: settings) != .disabled
                    && alarm.isEnabled 
                    && !alarm.isSkipped
                    && !alarm.isSnoozed
                    && !alarm.isEphemeral {
                    skipButton
                }
                
                // Show unskip button when alarm is skipped
                if alarm.isSkipped && alarm.isEnabled {
                    unskipButton
                }
            }
            .scaleEffect(scale, anchor: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isPressingSkip else { return }
            onTap()
        }
        .onReceive(Self.timer) { now in
            // Only commit the state write (and the row re-render it triggers) when
            // the visible countdown text would actually change: once per minute
            // normally, once per second inside the final minute before firing.
            if countdownFingerprint(at: now) != countdownFingerprint(at: currentTime) {
                currentTime = now
            }
            // Clear a stale skippedFireDate when its time passes while the app is open.
            // onAppear and scenePhase.active handle the case where the app was backgrounded;
            // this handles the case where the user leaves the app open past the skip time.
            if let skipped = alarm.skippedFireDate, skipped < now {
                alarm.skippedFireDate = nil
            }
        }
        .padding(.vertical, 16 * scale)
        .padding(.leading, 16 * scale)
        .padding(.trailing, 12 * scale)
        .background {
            if !settings.homeWallpaperEnabled {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
            } else if homeClearDimming > 0 {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(homeClearDimming))
            }
        }
        .glassEffect(homeGlassVariant, in: .rect(cornerRadius: 16))
        .overlay {
            if settings.homeWallpaperEnabled {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
            }
        }
        .offset(x: swipeOffset)
        .gesture(swipeCommandGesture)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: swipeOffset)
        .alert("Confirm Command", isPresented: $showSwipeConfirmAlert, presenting: pendingSwipeCommand) { command in
            Button("Run", role: .destructive) {
                fireSwipeCommandDirectly(command)
            }
            Button("Cancel", role: .cancel) {}
        } message: { command in
            Text("Run \"\(command.name)\"?")
        }
    }
    
    // MARK: - Swipe Command Gesture
    
    private var hasSwipeCommands: Bool {
        settings.armButtonEnabled && (alarm.swipeLeftCommandID != nil || alarm.swipeRightCommandID != nil)
    }
    
    private var swipeCommandGesture: some Gesture {
        DragGesture(minimumDistance: hasSwipeCommands ? 30 : .infinity)
            .onChanged { value in
                // Only allow horizontal swipe in the direction that has a command
                let translation = value.translation.width
                if translation < 0 && alarm.swipeLeftCommandID != nil {
                    swipeOffset = translation * 0.4  // Dampened drag
                } else if translation > 0 && alarm.swipeRightCommandID != nil {
                    swipeOffset = translation * 0.4
                }
            }
            .onEnded { value in
                let translation = value.translation.width
                if translation < -60, let cmdIDStr = alarm.swipeLeftCommandID,
                   let cmdID = UUID(uuidString: cmdIDStr),
                   let command = settings.mqttCommands.first(where: { $0.id == cmdID }) {
                    fireSwipeCommand(command)
                } else if translation > 60, let cmdIDStr = alarm.swipeRightCommandID,
                          let cmdID = UUID(uuidString: cmdIDStr),
                          let command = settings.mqttCommands.first(where: { $0.id == cmdID }) {
                    fireSwipeCommand(command)
                }
                swipeOffset = 0
            }
    }
    
    private func fireSwipeCommand(_ command: MQTTCommand) {
        // Debounce to prevent double-fire from gesture edge cases
        guard Date().timeIntervalSince(lastSwipeFireTime) > 0.5 else { return }
        lastSwipeFireTime = Date()

        // URL commands don't need an MQTT connection; HA commands do.
        if command.resolvedActionURL == nil {
            guard mqttManager.isConnected else { return }
        }

        if settings.confirmCommandsEnabled {
            pendingSwipeCommand = command
            showSwipeConfirmAlert = true
        } else {
            fireSwipeCommandDirectly(command)
        }
    }
    
    private func fireSwipeCommandDirectly(_ command: MQTTCommand) {
        Analytics.shared.log(.commandFired(kind: command.sourceKind, surface: .alarmSwipe))
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // URL command → open the link; otherwise publish to Home Assistant.
        if let urlString = command.resolvedActionURL, let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        } else if !command.name.isEmpty {
            mqttManager.publishArmCustomCommand(command.name, settings: settings)
        }

        // Apply the command's security action, same as the widget banner and the
        // notes page. This path used to skip it, so a command that armed the alarm
        // from the widget silently did nothing when fired by an alarm swipe.
        if settings.hassWidgetAlarmEnabled {
            switch command.armAction {
            case .none: break
            case .arm: mqttManager.requestArmStateChange(true, settings: settings)
            case .disarm: mqttManager.requestArmStateChange(false, settings: settings)
            case .toggle:
                // No live armed-state subscription on this path — treat toggle as
                // arm, matching the notes page's documented behavior.
                mqttManager.requestArmStateChange(true, settings: settings)
            }
        }

        // Notify the widget to show the command icon in its own color
        NotificationCenter.default.post(
            name: .widgetCommandExecuted,
            object: nil,
            userInfo: [
                "icon": command.icon,
                "iconColorRed": command.iconColorRed,
                "iconColorGreen": command.iconColorGreen,
                "iconColorBlue": command.iconColorBlue,
            ]
        )
    }
    
    private var unskipButton: some View {
        Button {
            onUnskip()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption2)
                Text("Undo")
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundStyle(skipAccent.opacity(0.95))
            .padding(.horizontal, 8)
            .padding(.vertical, 14)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    RoundedRectangle(cornerRadius: 8)
                        .fill(skipAccent.opacity(0.12))
                }
            }
            .saturation(0.7)
        }
        .buttonStyle(.plain)
    }
    
    private var skipButton: some View {
        let effectiveMode = alarm.effectiveSkipMode(settings: settings)
        let isOneTime = !alarm.isRecurring
        
        // A real Button, not a DragGesture(minimumDistance: 0). The drag-based
        // tap fought the List's scroll recognizer — the scroll cancels the drag
        // mid-press — and iOS additionally defers raw touch delivery near the
        // home indicator, so the bottom-most row's Skip was the least clickable
        // spot on the screen (al-xyq, punchlists PARA34 + BEER58). A Button is
        // UIKit-backed: scroll-vs-tap arbitration and deferred bottom-edge
        // touches are the system's problem, and a press the scroll steals just
        // reads as isPressed = false, which cancels the hold cleanly.
        return Button {
            // The action fires on touch-up. Tap mode skips on release; hold
            // mode completes through the press timer instead.
            if effectiveMode == .tap { onSkip() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOneTime ? "power" : (effectiveMode == .hold ? "hand.point.up.fill" : "forward.fill"))
                    .font(.caption2)
                Text(isOneTime ? "Off" : "Skip")
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundStyle(skipAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 14)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    RoundedRectangle(cornerRadius: 8)
                        .fill(skipAccent.opacity(0.14))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Tactile hold-to-confirm press (skip modes only; tap mode fires on release).
            .holdPress(progress: effectiveMode == .tap ? 0 : skipProgress,
                       isHolding: effectiveMode == .tap ? false : isPressingSkip,
                       accent: skipAccent,
                       cornerRadius: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(SkipPressReportingStyle { pressed in
            guard effectiveMode != .tap else { return }
            if pressed {
                startHoldProgress()
            } else {
                endHoldProgress()
            }
        })
    }

    /// Relays the button's system-arbitrated pressed state to the hold timer.
    /// When the List's scroll takes the touch, isPressed flips to false and the
    /// hold cancels — no translation thresholds to tune.
    private struct SkipPressReportingStyle: ButtonStyle {
        let onPressedChange: (Bool) -> Void

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onChange(of: configuration.isPressed) { _, pressed in
                    onPressedChange(pressed)
                }
        }
    }
    
    /// How long this alarm's hold-to-skip takes: its own override, else the
    /// app-wide setting. One place, so the countdown label and the timer that
    /// drives it can never disagree.
    private var skipHoldTotalDuration: Double {
        alarm.skipHoldDuration ?? settings.skipAlarmHoldDuration
    }

    /// Whole seconds left in the current hold, for the "Keep holding…" label.
    /// Rounded up so it only reaches 0 when the skip actually commits, and
    /// floored at 0 so a late tick can never render a negative.
    private var skipHoldSecondsRemaining: Int {
        max(0, Int(ceil(skipHoldTotalDuration * (1 - min(max(skipProgress, 0), 1)))))
    }

    private func startHoldProgress() {
        guard !skipCompleted else { return }
        
        isPressingSkip = true
        skipProgress = 0
        
        let totalDuration = skipHoldTotalDuration

        // If duration is 0, instantly trigger
        if totalDuration == 0 {
            onSkip()
            isPressingSkip = false
            return
        }
        
        let updateInterval = 0.033 // ~30fps
        let started = Date()

        // WALL CLOCK, NOT TICK COUNT. Progress used to add a fixed increment per
        // tick (`increment = updateInterval / totalDuration`), so the bar
        // measured *ticks delivered*, not time elapsed — every dropped or
        // coalesced tick permanently lengthened the hold and the last stretch
        // read as a stall. Deriving the fraction from elapsed time makes "hold
        // 2 seconds" two real seconds and guarantees the threshold is reached
        // even after dropped frames.
        //
        // `.common` rather than the `.default` that `Timer.scheduledTimer`
        // gives you: this row lives inside a `List`, i.e. a UIScrollView, and a
        // `.default`-only timer stops firing whenever the run loop enters
        // `UITrackingRunLoopMode`. Measured under XCUITest this did NOT stall
        // (a perfectly stationary synthetic press never enters tracking mode,
        // and ticks arrived at a full 30 Hz either way), so it is defence
        // rather than the fix for al-lwz — but it costs nothing and it is what
        // the row's 1 Hz clock above and the CADisplayLink-driven arm/snooze
        // holds already use.
        let timer = Timer(timeInterval: updateInterval, repeats: true) { timer in
            let fraction = min(Date().timeIntervalSince(started) / totalDuration, 1.0)

            withAnimation(.linear(duration: updateInterval)) {
                skipProgress = fraction
            }

            if fraction >= 1.0 {
                timer.invalidate()
                holdTimer = nil
                skipCompleted = true
                skipProgress = 0
                isPressingSkip = false
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                onSkip()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }
    
    private func endHoldProgress() {
        holdTimer?.invalidate()
        holdTimer = nil
        
        if skipCompleted {
            skipCompleted = false
            return
        }
        
        withAnimation(.easeOut(duration: 0.2)) {
            skipProgress = 0
            isPressingSkip = false
        }
    }
    

    
    
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .short
        return formatter
    }()

    private var timeString: String {
        Self.timeFormatter.string(from: alarm.time)
    }
    

    
    @ViewBuilder
    private var recurringDaysView: some View {
        let days = alarm.safeRecurringDays

        if days.count == 7 {
            Text("Every day")
                .font(.system(size: 13 * scale))
                .foregroundStyle(textColor(primary: false))
        } else if days == LocaleWeekday.weekdayNumbers() {
            Text("Weekdays")
                .font(.system(size: 13 * scale))
                .foregroundStyle(textColor(primary: false))
        } else if days == LocaleWeekday.weekendDayNumbers() {
            Text("Weekends")
                .font(.system(size: 13 * scale))
                .foregroundStyle(textColor(primary: false))
        } else {
            // Show locale-ordered single-letter day indicators
            let cal = Calendar.current
            let symbols = cal.veryShortWeekdaySymbols // 0=Sun, 1=Mon, ...
            let orderedDayNumbers = LocaleWeekday.orderedDayNumbers(calendar: cal)
            HStack(spacing: 8 * scale) {
                ForEach(orderedDayNumbers, id: \.self) { dayNumber in
                    Text(symbols[dayNumber - 1])
                        .font(.system(size: 13 * scale, weight: days.contains(dayNumber) ? .bold : .regular))
                        .foregroundStyle(
                            days.contains(dayNumber)
                                ? textColor(primary: false)
                                : textColor(primary: false).opacity(0.3)
                        )
                }
            }
        }
    }
    
    private func textColor(primary: Bool) -> Color {
        if !alarm.isEnabled {
            // When disabled, make everything really dim
            let base: Color = primary ? (colors.resolvedAlarmTimeColor ?? .primary) : (colors.resolvedAlarmLabelColor ?? .secondary)
            return base.opacity(0.25)
        } else if alarm.isSkipped && primary {
            // When skipped today, dim the main time text
            return colors.resolvedAlarmTimeColor?.opacity(0.6) ?? .secondary
        } else if primary {
            return colors.resolvedAlarmTimeColor ?? .primary
        } else {
            return colors.resolvedAlarmLabelColor ?? .secondary
        }
    }
    
    private var missionIconColor: Color {
        if !alarm.isEnabled {
            return (colors.resolvedMissionIconColor ?? .secondary).opacity(0.25)
        }
        return colors.resolvedMissionIconColor ?? .secondary
    }
    
    /// Everything in the row body that visibly depends on the clock, rendered at a
    /// hypothetical time. Two consecutive ticks producing the same fingerprint means
    /// re-rendering the row would draw identical content, so the tick can be skipped.
    private func countdownFingerprint(at time: Date) -> String {
        var parts: [String] = []
        if !alarm.isSnoozed, let nextFire = cachedNextFireDate(at: time), nextFire > time {
            parts.append(timeUntil(nextFire, at: time))
        }
        if alarm.isSnoozed, let snoozeUntil = alarm.snoozeUntil, snoozeUntil > time {
            parts.append(snoozeCountdownText(timeRemaining: snoozeUntil.timeIntervalSince(time)))
        }
        return parts.joined(separator: "|")
    }

    private func timeUntil(_ date: Date, at now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 24 {
            let days = hours / 24
            return "\(days)d \(hours % 24)h"
        } else if hours > 0 {
            // Round minutes up if there are leftover seconds
            let m = seconds > 0 ? minutes + 1 : minutes
            if m >= 60 { return "\(hours + 1)h" }
            return "\(hours)h \(m)m"
        } else if minutes > 0 {
            // Round up so e.g. 9m 58s shows as 10m, not 9m
            let m = seconds > 0 ? minutes + 1 : minutes
            return "\(m)m"
        } else if seconds > 0 {
            return "\(seconds)s"
        } else {
            return "now"
        }
    }
    
    private func snoozeCountdownText(timeRemaining: TimeInterval) -> String {
        let minutes = Int(timeRemaining) / 60
        let seconds = Int(timeRemaining) % 60
        
        if minutes > 0 {
            return "\(minutes) min\(minutes == 1 ? "" : "s")"
        } else if seconds > 0 {
            return "\(seconds) sec\(seconds == 1 ? "" : "s")"
        } else {
            return "ending..."
        }
    }
}

#Preview {
    AlarmListView()
        .modelContainer(for: Alarm.self, inMemory: true)
}
