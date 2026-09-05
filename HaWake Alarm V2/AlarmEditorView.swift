//
//  AlarmEditorView.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import SwiftUI
import SwiftData

struct AlarmEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Alarm.time) private var allAlarms: [Alarm]
    @Bindable var alarm: Alarm
    
    let settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }
    let storeManager: StoreManager
    var onDuplicate: ((Alarm) -> Void)?
    var onDelete: ((Alarm) -> Void)?
    
    @State private var selectedTime = Date()
    @State private var mission: Mission
    /// Slots 2..5 of the mission sequence (slot 1 stays in `mission`).
    @State private var extraMissions: [Mission]
    @State private var selectedDays: Set<Int> = []
    @State private var snoozeMode: SnoozeMode
    @State private var snoozeHoldDuration: Double
    @State private var maxSnoozeCount: Int
    @State private var useCustomSnoozeMode = false
    @State private var skipAlarmMode: SkipAlarmMode
    @State private var skipHoldDuration: Double
    @State private var useCustomSkipMode = false
    @State private var customVolumeLevel: Double?
    @State private var customVibrationEnabled: Bool?
    @State private var customFadeInEnabled: Bool?
    @State private var customFadeInDuration: Int?
    @State private var useCustomGracePeriod = false
    @State private var customGracePeriod: Double
    @State private var swipeLeftCommandID: UUID?
    @State private var swipeRightCommandID: UUID?
    @State private var dismissAppURI: String
    @State private var snoozeAppURI: String
    @State private var alarmRadioStation: RadioStation?
    /// Station browser presentation, anchored on this editor's Form root (a
    /// stable root) rather than the picker's Form-row context — the latter
    /// tore this editor sheet down when the cover presented.
    @State private var stationBrowserMode: StationBrowserMode?
    /// Custom-alarm-tone screen, anchored on the Form root for the same reason
    /// as stationBrowserMode.
    @State private var customToneMode: CustomToneMode?
    /// Mission "Try It Out" preview, anchored on the Form root for the same
    /// reason as stationBrowserMode.
    @State private var missionPreview: MissionPreviewRequest?
    /// The mission-slot pop-out request, anchored on the Form root (a slot tap in
    /// MissionSelectorView sets this; presenting from the row itself would tear
    /// the editor sheet down — same rule as stationBrowserMode).
    @State private var missionSlotEdit: MissionSlotEditRequest?
    /// Ordered after-alarm pipeline (notes / verse / weather / open-app), loaded
    /// from the alarm's legacy-reconciling `afterAlarmActions` accessor and written
    /// back on save (order → afterAlarmOrderData, legacy fields kept in sync).
    @State private var afterAlarmActions: [AfterAlarmAction]
    /// Notes after-alarm config: the notes text and the four command-button
    /// slots (UUID strings of MQTTCommand; always exactly 4 entries).
    @State private var alarmScreenNotes: String
    @State private var noteCommandIDs: [String?]
    /// After-alarm action config pop-out, anchored on the Form root (same rule as
    /// missionSlotEdit). Notes are NOT routed here — see `showNotesEditor`.
    @State private var afterAlarmEdit: AfterAlarmEditRequest?
    /// Editing a Notes card opens the full-screen editor DIRECTLY from this Form
    /// root — no intermediate config sheet to stack a second screen on top of.
    @State private var showNotesEditor = false
    /// Accordion state: the one editor section currently expanded (nil = all collapsed)
    @State private var expandedEditorSection: AlarmEditorSection?
    /// Tracks whether saveAlarm() was called so onDisappear knows
    /// whether it needs to reschedule (cancel path) or not (save path).
    @State private var didSave = false
    /// Which swipe direction the unified command picker is filling. Anchored on
    /// the Form root (same rule as stationBrowserMode / missionSlotEdit).
    @State private var swipePicker: SwipeCommandTarget?
    @FocusState private var isNameFocused: Bool
    /// Whether another alarm (not this one) has the same label
    private var isDuplicateLabel: Bool {
        allAlarms.contains { $0.id != alarm.id && $0.label.trimmingCharacters(in: .whitespaces) == alarm.label.trimmingCharacters(in: .whitespaces) }
    }
    
    /// Whether the label is empty or blank
    private var isEmptyLabel: Bool {
        alarm.label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether the label has no ASCII letters/digits (would produce an auto-generated MQTT slug)
    private var hasNoASCIIChars: Bool {
        let trimmed = alarm.label.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }
    
    /// Suggest a unique name by appending the next available number
    private var suggestedUniqueLabel: String {
        let base = alarm.label.trimmingCharacters(in: .whitespaces)
        let existingLabels = Set(allAlarms.filter { $0.id != alarm.id }.map { $0.label })
        var candidate = base
        var counter = 2
        while existingLabels.contains(candidate) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    init(alarm: Alarm, settings: DeviceSettings, storeManager: StoreManager, onDuplicate: ((Alarm) -> Void)? = nil, onDelete: ((Alarm) -> Void)? = nil) {
        self.alarm = alarm
        self.settings = settings
        self.storeManager = storeManager
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        _selectedTime = State(initialValue: alarm.time)
        _mission = State(initialValue: alarm.mission)
        _extraMissions = State(initialValue: alarm.extraMissions)
        _selectedDays = State(initialValue: alarm.safeRecurringDays)
        _customVolumeLevel = State(initialValue: alarm.customVolumeLevel)
        _customVibrationEnabled = State(initialValue: alarm.customVibrationEnabled)
        _customFadeInEnabled = State(initialValue: alarm.customFadeInEnabled)
        _customFadeInDuration = State(initialValue: alarm.customFadeInDuration)
        
        // Initialize grace period override
        if let gracePeriod = alarm.customGracePeriod {
            _useCustomGracePeriod = State(initialValue: true)
            _customGracePeriod = State(initialValue: gracePeriod)
        } else {
            _useCustomGracePeriod = State(initialValue: false)
            _customGracePeriod = State(initialValue: 0)
        }
        
        // Initialize snooze mode override
        if let mode = alarm.alarmSnoozeMode {
            _useCustomSnoozeMode = State(initialValue: true)
            _snoozeMode = State(initialValue: mode)
        } else {
            _useCustomSnoozeMode = State(initialValue: false)
            _snoozeMode = State(initialValue: settings.snoozeMode)
        }
        _snoozeHoldDuration = State(initialValue: alarm.customSnoozeHoldDuration ?? settings.snoozeHoldDuration)
        _maxSnoozeCount = State(initialValue: alarm.maxSnoozeCount ?? settings.defaultMaxSnoozeCount)
        
        // Initialize skip alarm mode override
        if let mode = alarm.alarmSkipMode {
            _useCustomSkipMode = State(initialValue: true)
            _skipAlarmMode = State(initialValue: mode)
        } else {
            _useCustomSkipMode = State(initialValue: false)
            _skipAlarmMode = State(initialValue: alarm.allowSkipOnce ? settings.skipAlarmMode : .disabled)
        }
        _skipHoldDuration = State(initialValue: alarm.skipHoldDuration ?? settings.skipAlarmHoldDuration)
        
        // Initialize swipe command IDs
        if let leftStr = alarm.swipeLeftCommandID {
            _swipeLeftCommandID = State(initialValue: UUID(uuidString: leftStr))
        }
        if let rightStr = alarm.swipeRightCommandID {
            _swipeRightCommandID = State(initialValue: UUID(uuidString: rightStr))
        }

        // Initialize dismiss/snooze app links
        _dismissAppURI = State(initialValue: alarm.dismissAppURI ?? "")
        _snoozeAppURI = State(initialValue: alarm.snoozeAppURI ?? "")

        // Initialize the after-alarm pipeline. `afterAlarmActions` already
        // reconciles the legacy fields (weather toggle → .weather, dismiss link →
        // .appLink) into an ordered list. Also surface the Open App card when only
        // a snooze link is set, so that link stays reachable/editable.
        var loadedActions = alarm.afterAlarmActions
        if !loadedActions.contains(.appLink),
           !(alarm.snoozeAppURI?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            loadedActions.append(.appLink)
        }
        _afterAlarmActions = State(initialValue: Alarm.normalizeAfterAlarm(loadedActions))

        // Initialize the Notes after-alarm config (text + 4 command slots).
        _alarmScreenNotes = State(initialValue: alarm.alarmScreenNotes)
        _noteCommandIDs = State(initialValue: [
            alarm.alarmScreenCommandID1, alarm.alarmScreenCommandID2,
            alarm.alarmScreenCommandID3, alarm.alarmScreenCommandID4
        ])

        // Initialize wake-up radio station — prefer the live favorite (fresh
        // URL/metadata), fall back to the snapshot stored on the alarm.
        if let stationID = alarm.radioStationID, let stationURL = alarm.radioStationURL {
            let favorite = RadioPlayerManager.shared.favorites.first { $0.id == stationID }
            _alarmRadioStation = State(initialValue: favorite ?? RadioStation(
                id: stationID,
                name: alarm.radioStationName ?? "Radio Station",
                streamURL: stationURL,
                faviconURL: nil, country: "", tags: "", codec: "", bitrate: 0
            ))
        }

    }

    /// True when any slot (slot 1 or an extra) is a Home Assistant mission.
    private var hasHAMission: Bool {
        mission.type == .homeAssistant || extraMissions.contains { $0.type == .homeAssistant }
    }

    /// Binding to whichever slot's Mission is Home Assistant (slot 1 or an extra),
    /// or nil when no slot uses HA. Drives the backup mission/snooze sections.
    private var haMissionBinding: Binding<Mission>? {
        if mission.type == .homeAssistant { return $mission }
        if let i = extraMissions.firstIndex(where: { $0.type == .homeAssistant }) {
            return Binding(
                get: { i < extraMissions.count ? extraMissions[i] : Mission() },
                set: { newValue in
                    guard i < extraMissions.count else { return }
                    extraMissions[i] = newValue
                }
            )
        }
        return nil
    }

    /// Mission type driving the Snooze section — HA whenever any slot is HA (so the
    /// HA snooze option is offered), otherwise slot 1's type.
    private var snoozeMissionType: MissionType {
        hasHAMission ? .homeAssistant : mission.type
    }

    var body: some View {
        NavigationStack {
            Form {
                // Duplicate & Delete actions (only when swipe commands replace default row swipes)
                if (onDuplicate != nil || onDelete != nil) && (swipeLeftCommandID != nil || swipeRightCommandID != nil) {
                    Section {
                        HStack(spacing: 12) {
                            if let onDuplicate {
                                Button {
                                    onDuplicate(alarm)
                                    dismiss()
                                } label: {
                                    Label("Duplicate", systemImage: "doc.on.doc")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                            
                            if let onDelete {
                                Button {
                                    onDelete(alarm)
                                    dismiss()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                        .foregroundStyle(.red)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
                
                #if DEBUG
                Section {
                    Button("Test Alarm (10s)") {
                        saveAlarm(debugFireIn: 10)
                    }
                    .disabled(isEmptyLabel)
                }
                #endif
                
                Section {
                    WheelTimePicker(selection: $selectedTime)
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    LabeledContent("Alarm Name") {
                        TextField("Enter a name", text: $alarm.label)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .submitLabel(.done)
                            .focused($isNameFocused)
                            .onSubmit { isNameFocused = false }
                    }
                    
                    if isEmptyLabel {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                            Text("Alarm name cannot be empty.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else if hasNoASCIIChars {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Name should include at least one letter or number for MQTT compatibility.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else if isDuplicateLabel {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(accent)
                                .font(.caption)
                            Text("Will be saved as \"\(suggestedUniqueLabel)\"")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    DayPickerView(selectedDays: $selectedDays)
                }
                
                AlarmSoundPicker(
                    selectedSoundID: $alarm.soundName,
                    alarmVolumeLevel: settings.alarmVolumeLevel,
                    customVolumeLevel: $customVolumeLevel,
                    customVibrate: $customVibrationEnabled,
                    globalVibrateDefault: settings.alarmVibrationEnabled,
                    customFadeIn: $customFadeInEnabled,
                    customFadeInDuration: $customFadeInDuration,
                    globalFadeInDefault: settings.alarmFadeInEnabled,
                    globalFadeInDurationDefault: settings.alarmFadeInDuration,
                    radioStation: $alarmRadioStation,
                    startCollapsed: true,
                    expandedSection: $expandedEditorSection,
                    stationBrowserMode: $stationBrowserMode,
                    customToneMode: $customToneMode
                )
                
                MissionSelectorView(
                    mission: $mission,
                    extraMissions: $extraMissions,
                    settings: settings,
                    mqttEnabled: settings.mqttEnabled,
                    onEditSlot: { missionSlotEdit = MissionSlotEditRequest(target: $0) }
                )

                // Snooze section — when snooze runs in HA mode, the fallback snooze
                // controls fold into this same section (see SnoozeSectionView).
                SnoozeSectionView(
                    snoozeMode: $snoozeMode,
                    snoozeDuration: $alarm.snoozeDuration,
                    snoozeHoldDuration: $snoozeHoldDuration,
                    maxSnoozeCount: $maxSnoozeCount,
                    useCustomSnoozeMode: $useCustomSnoozeMode,
                    settings: settings,
                    missionType: snoozeMissionType,
                    haMission: haMissionBinding,
                    startCollapsed: true,
                    expandedSection: $expandedEditorSection
                )

                SkipAlarmSectionView(
                    skipAlarmMode: $skipAlarmMode,
                    skipHoldDuration: $skipHoldDuration,
                    useCustomSkipMode: $useCustomSkipMode,
                    settings: settings,
                    startCollapsed: true,
                    expandedSection: $expandedEditorSection
                )
                
                // Automations, flattened into two independent top-level sections
                // (the old umbrella nested accordions inside an accordion).
                // Swipe Commands only appears when the arm button surfaces them.
                if settings.armButtonEnabled {
                    Section("Swipe Commands") {
                        SwipeCommandSection(
                            swipeLeftCommandID: $swipeLeftCommandID,
                            swipeRightCommandID: $swipeRightCommandID,
                            settings: settings,
                            // Reported UP so the picker presents from the Form root
                            // — presenting it from these rows tears the sheet down.
                            onRequestPicker: { swipePicker = $0 },
                            expandedSection: $expandedEditorSection
                        )
                    }
                }

                // After Alarm: the ordered post-dismiss pipeline (verse / weather /
                // open-app) as a numbered-box grid — replaces the old standalone App
                // Launch section and Morning Weather toggle.
                AfterAlarmSectionView(
                    actions: $afterAlarmActions,
                    settings: settings,
                    onEdit: { target in
                        // Notes open the full-screen editor DIRECTLY; every other
                        // action type uses the config sheet.
                        if target == .action(.notes) {
                            showNotesEditor = true
                        } else {
                            afterAlarmEdit = AfterAlarmEditRequest(target: target)
                        }
                    }
                )

                // The alarm's MQTT index, shown quietly at the very bottom.
                //
                // `index` is how Home Assistant targets this alarm
                // (update_alarm, delete_alarm, the per-alarm command topics),
                // and until now there was nowhere in the app to find it —
                // you had to read it off an MQTT topic. Deliberately
                // understated: it matters to the handful of people wiring
                // automations and to nobody else.
                //
                // Only for alarms that HAVE an index: it is assigned when the
                // alarm is first published, so a brand-new unsaved alarm has
                // none to show.
                if alarm.alarmIndex > 0 {
                    Section {
                        VStack(spacing: 3) {
                            Text("MQTT Alarm Index")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(alarm.alarmIndex)")
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            // Keyed on whether ANY slot is HA (not just slot 1) so HA in an extra
            // slot still auto-selects HA snooze, and reverting only happens when
            // no slot uses HA.
            .onChange(of: hasHAMission) { _, isHA in
                if isHA {
                    snoozeMode = .homeAssistant
                    useCustomSnoozeMode = true
                } else if snoozeMode == .homeAssistant {
                    // No slot uses HA any more — revert to default snooze
                    snoozeMode = settings.snoozeMode
                    useCustomSnoozeMode = false
                }
            }
            .navigationTitle("Edit Alarm")
            .navigationBarTitleDisplayMode(.inline)
            // Anchored on the Form root (a stable root), NOT the picker's
            // Form-row context — presenting from a Form row inside this editor
            // sheet tore the sheet down. Mirrors SleepSoundSetupView.
            .fullScreenCover(item: $stationBrowserMode) { mode in
                NavigationStack {
                    RadioBrowserView(
                        settings: DeviceSettings.shared,
                        pickMode: true,
                        startInFavoritesEdit: mode == .edit,
                        onPick: { alarmRadioStation = $0 }
                    )
                }
            }
            .customAlarmToneScreen(mode: $customToneMode)
            .fullScreenCover(item: $missionPreview) { request in
                MissionPreviewView(mission: request.mission, settings: settings)
            }
            // Mission-slot pop-out, anchored on the Form root. Compacts the
            // sequence on dismiss so cleared middle slots close their gap.
            .sheet(item: $missionSlotEdit, onDismiss: compactMissions) { request in
                MissionSlotEditorSheet(
                    target: request.target,
                    mission: $mission,
                    extraMissions: $extraMissions,
                    useCustomGracePeriod: $useCustomGracePeriod,
                    customGracePeriod: $customGracePeriod,
                    settings: settings,
                    mqttEnabled: settings.mqttEnabled
                )
            }
            // After-alarm action config pop-out, anchored on the Form root.
            .sheet(item: $afterAlarmEdit) { request in
                AfterAlarmActionEditorSheet(
                    target: request.target,
                    actions: $afterAlarmActions,
                    dismissAppURI: $dismissAppURI,
                    snoozeAppURI: $snoozeAppURI,
                    notesText: $alarmScreenNotes,
                    noteCommandIDs: $noteCommandIDs,
                    settings: settings
                )
            }
            // Editing a Notes card — presented DIRECTLY from the Form root, with no
            // intermediate config sheet (that stacked two screens and trapped the
            // user with no way back into the note).
            .notesAfterAlarmEditor(
                isPresented: $showNotesEditor,
                settings: settings,
                notes: $alarmScreenNotes,
                commandIDs: $noteCommandIDs,
                actions: $afterAlarmActions
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAlarm()
                    }
                    .disabled(isEmptyLabel)
                }
            }
            .onAppear {
                // Cancel the alarm while editing so it can't fire and pop up
                // the full-screen alarm UI over the editor sheet.
                Task {
                    await DualAlarmCoordinator.shared.cancelAlarm(alarm)
                }
                #if DEBUG
                // `-editorExpand swipe` opens an accordion section that a
                // screenshot harness can't tap open. Never set in shipping.
                AlarmEditorSection.debugPreexpanded.map { expandedEditorSection = $0 }
                #endif
            }
            .onDisappear {
                // If the user cancelled (didn't save), reschedule the alarm
                // so it goes back to its original state. The save path already
                // reschedules in saveAlarm(), so skip the duplicate.
                if !didSave && alarm.isEnabled {
                    Task {
                        await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
                    }
                }
            }
            // The unified command picker, anchored on the Form root.
            .sheet(item: $swipePicker) { target in
                CommandPickerSheet(
                    destination: target.destination,
                    currentID: target.isLeft ? swipeLeftCommandID : swipeRightCommandID,
                    settings: settings,
                    onPick: { newID in
                        if target.isLeft { swipeLeftCommandID = newID }
                        else { swipeRightCommandID = newID }
                    }
                )
            }
            // Clear unsaved draft assignments when their command is deleted from
            // the library (the picker can delete while this editor is open).
            .onReceive(NotificationCenter.default.publisher(for: .mqttCommandDeleted)) { note in
                guard let id = note.userInfo?["id"] as? UUID else { return }
                if swipeLeftCommandID == id { swipeLeftCommandID = nil }
                if swipeRightCommandID == id { swipeRightCommandID = nil }
                CommandDeletionCoordinator.clearDraftSlots(&noteCommandIDs, deleted: id)
            }
        }
    }

    /// Keeps missions packed into contiguous slots 1..N. Tap (`.none`) slots are
    /// real, combinable missions now, so they are NOT filtered out — dropping them
    /// here would silently delete configured Tap slots. Clearing a slot is an
    /// explicit removal (the sheet's "No Mission" tile, the Remove context action),
    /// so slots are already packed; this only re-splits the packed list back through
    /// the bindings. Idempotent — safe to run on every pop-out dismiss.
    private func compactMissions() {
        var all = [mission] + extraMissions
        let first = all.removeFirst()
        if mission != first { mission = first }
        if extraMissions != all { extraMissions = all }
    }

    private func saveAlarm(debugFireIn: TimeInterval? = nil) {
        // Block saving with empty label
        if isEmptyLabel { return }

        // Auto-fix duplicate names by appending next available number
        if isDuplicateLabel {
            alarm.label = suggestedUniqueLabel
        }
        
        alarm.time = selectedTime
        alarm.recurringDays = selectedDays
        alarm.mission = mission
        alarm.extraMissions = extraMissions
        alarm.customVolumeLevel = customVolumeLevel
        alarm.customVibrationEnabled = customVibrationEnabled
        alarm.customFadeInEnabled = customFadeInEnabled
        alarm.customFadeInDuration = customFadeInDuration
        
        // DEBUG: Override alarm time to fire in N seconds
        #if DEBUG
        if let debugFireIn {
            alarm.time = Date().addingTimeInterval(debugFireIn)
            alarm.recurringDays = []  // Make it one-time so it fires at the exact time
            alarm.lastFireDate = nil  // Clear so nextFireDate() doesn't skip it
            print("🐛 DEBUG: Alarm '\(alarm.label)' will fire in \(Int(debugFireIn))s at \(alarm.time)")
        }
        #endif
        
        // Save grace period override
        if useCustomGracePeriod {
            alarm.customGracePeriod = customGracePeriod
        } else {
            alarm.customGracePeriod = nil
        }
        
        // Save snooze + skip overrides. The rules live in AlarmOverrideResolution
        // so they cannot drift from the rule that decides when a section becomes
        // custom in the first place — drift is exactly what al-qcd was.
        let snoozeOverride = AlarmOverrideResolution.snoozeFields(
            isCustom: useCustomSnoozeMode,
            mode: snoozeMode,
            holdDuration: snoozeHoldDuration,
            maxCount: maxSnoozeCount
        )
        alarm.alarmSnoozeMode = snoozeOverride.mode
        alarm.customSnoozeHoldDuration = snoozeOverride.holdDuration
        alarm.maxSnoozeCount = snoozeOverride.maxCount

        let skipOverride = AlarmOverrideResolution.skipFields(
            isCustom: useCustomSkipMode,
            mode: skipAlarmMode,
            holdDuration: skipHoldDuration
        )
        alarm.alarmSkipMode = skipOverride.mode
        alarm.skipHoldDuration = skipOverride.holdDuration
        alarm.allowSkipOnce = skipOverride.allowSkipOnce

        // Save swipe command assignments
        alarm.swipeLeftCommandID = swipeLeftCommandID?.uuidString
        alarm.swipeRightCommandID = swipeRightCommandID?.uuidString

        // Save the after-alarm pipeline. Write the EXPLICIT order, then keep the
        // legacy per-alarm fields in sync so the dismiss flow, MQTT publish, and
        // the read-time reconciliation all agree:
        //   • weather present ⇔ showWeatherAfterAlarm
        //   • appLink present  → keep dismissAppURI; appLink removed → clear it
        //   • notes present    → keep notes text/commands; removed → clear them
        // (The snooze link is independent of the pipeline and always saved.)
        alarm.afterAlarmActions = afterAlarmActions
        alarm.showWeatherAfterAlarm = afterAlarmActions.contains(.weather)
        if afterAlarmActions.contains(.notes) {
            alarm.alarmScreenNotes = alarmScreenNotes
            let slots = noteCommandIDs + Array(repeating: nil, count: max(0, 4 - noteCommandIDs.count))
            alarm.alarmScreenCommandID1 = slots[0]
            alarm.alarmScreenCommandID2 = slots[1]
            alarm.alarmScreenCommandID3 = slots[2]
            alarm.alarmScreenCommandID4 = slots[3]
        } else {
            alarm.alarmScreenNotes = ""
            alarm.alarmScreenCommandID1 = nil
            alarm.alarmScreenCommandID2 = nil
            alarm.alarmScreenCommandID3 = nil
            alarm.alarmScreenCommandID4 = nil
        }
        let trimmedDismissLink = dismissAppURI.trimmingCharacters(in: .whitespacesAndNewlines)
        if afterAlarmActions.contains(.appLink) {
            alarm.dismissAppURI = trimmedDismissLink.isEmpty ? nil : trimmedDismissLink
        } else {
            alarm.dismissAppURI = nil
        }
        let trimmedSnoozeLink = snoozeAppURI.trimmingCharacters(in: .whitespacesAndNewlines)
        alarm.snoozeAppURI = trimmedSnoozeLink.isEmpty ? nil : trimmedSnoozeLink

        // Save wake-up radio station snapshot
        alarm.radioStationID = alarmRadioStation?.id
        alarm.radioStationName = alarmRadioStation?.name
        alarm.radioStationURL = alarmRadioStation?.streamURL

        // Clear any pending skip when saving changes
        alarm.skippedFireDate = nil
        
        // Reset snooze state when editing alarm
        alarm.isSnoozed = false
        alarm.snoozeUntil = nil
        alarm.snoozeCount = 0
        
        // Cancel any active snooze notification/timer in the background
        // This prevents a lingering snooze from firing after the alarm has been edited
        DualAlarmCoordinator.shared.cancelSnooze(for: alarm)
        
        // If this was a one-time alarm that had fired, clear lastFireDate
        // so it can fire again with the new settings.
        if !alarm.isRecurring && alarm.lastFireDate != nil {
            alarm.lastFireDate = nil
        }

        // Always enable the alarm on save — if the user is editing it,
        // they intend for it to be active.
        if !alarm.isEnabled {
            alarm.isEnabled = true
            print("🔔 Alarm re-enabled after editing")
        }
        
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        let days = alarm.safeRecurringDays.isEmpty ? "one-time" : alarm.safeRecurringDays.sorted().map(String.init).joined(separator: ",")
        AppLogger.shared.log("Alarm saved: '\(alarm.label)' time=\(timeFormatter.string(from: alarm.time)) days=\(days) mission=\(alarm.mission.type.rawValue) sound=\(alarm.soundName) vol=\(alarm.customVolumeLevel.map { String(format: "%.0f%%", $0 * 100) } ?? "default") snooze=\(alarm.snoozeDuration)min", category: .alarm)

        do {
            try modelContext.save()
            print("✅ SwiftData: Alarm edit saved successfully")
        } catch {
            print("❌ SwiftData: Failed to save alarm edit: \(error)")
        }
        
        Task {
            await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
        }

        // Update per-alarm MQTT state
        if settings.mqttEnabled {
            HAIntegrationRouter.shared.publishPerAlarmState(alarm: alarm, settings: settings)
        }

        // Notify that alarm state changed for MQTT update (global sensors)
        NotificationCenter.default.post(
            name: NSNotification.Name("AlarmStateChanged"),
            object: nil
        )

        didSave = true
        dismiss()
    }

}

struct DayPickerView: View {
    @Binding var selectedDays: Set<Int>

    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }

    private let calendar = Calendar.current

    /// Day numbers ordered by the locale's first day of week
    private var orderedDayNumbers: [Int] {
        LocaleWeekday.orderedDayNumbers(calendar: calendar)
    }

    /// Locale-aware short day symbols (e.g. "Sun", "Mon" or localized equivalents)
    private var shortSymbols: [String] {
        calendar.shortWeekdaySymbols // 0=Sun, 1=Mon, …
    }

    private var weekdays: Set<Int> { LocaleWeekday.weekdayNumbers(calendar: calendar) }
    private var weekend: Set<Int> { LocaleWeekday.weekendDayNumbers(calendar: calendar) }
    private let everyday: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    /// Exact match — only weekdays selected, nothing else
    private var isWeekdaysSelected: Bool {
        selectedDays == weekdays
    }

    /// Exact match — only weekend selected, nothing else
    private var isWeekendSelected: Bool {
        selectedDays == weekend
    }

    /// Exact match — all 7 days selected
    private var isEverydaySelected: Bool {
        selectedDays == everyday
    }

    var body: some View {
        // Center a fixed-width block so pills align to the first day circle
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 10) {
                // Individual day bubbles — locale-ordered
                HStack(spacing: 8) {
                    ForEach(orderedDayNumbers, id: \.self) { dayNumber in
                        Button {
                            if selectedDays.contains(dayNumber) {
                                selectedDays.remove(dayNumber)
                            } else {
                                selectedDays.insert(dayNumber)
                            }
                        } label: {
                            Text(shortSymbols[dayNumber - 1])
                                .font(.caption)
                                .fontWeight(.medium)
                                .frame(width: 40, height: 40)
                                .background(
                                    Circle()
                                        .fill(selectedDays.contains(dayNumber) ? accent : Color.gray.opacity(0.2))
                                )
                                .foregroundColor(selectedDays.contains(dayNumber) ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Preset quick-select pills
                HStack(spacing: 10) {
                    presetPill("Weekdays", isActive: isWeekdaysSelected) {
                        if isWeekdaysSelected {
                            selectedDays = []
                        } else {
                            selectedDays = weekdays
                        }
                    }

                    presetPill("Weekend", isActive: isWeekendSelected) {
                        if isWeekendSelected {
                            selectedDays = []
                        } else {
                            selectedDays = weekend
                        }
                    }

                    presetPill("Everyday", isActive: isEverydaySelected) {
                        if isEverydaySelected {
                            selectedDays = []
                        } else {
                            selectedDays = everyday
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
    
    private func presetPill(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isActive ? accent : Color.gray.opacity(0.2))
                )
                .foregroundColor(isActive ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - New Alarm Editor
struct NewAlarmEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Alarm.time) private var allAlarms: [Alarm]
    
    let settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }
    let storeManager: StoreManager
    let onCreate: (Alarm) -> Void
    
    @State private var selectedTime = Date()
    @State private var label = "Alarm"
    @State private var snoozeDuration: Int
    @State private var soundName: String
    @State private var mission: Mission
    /// Slots 2..5 of the mission sequence (slot 1 stays in `mission`).
    @State private var extraMissions: [Mission] = []
    @State private var selectedDays: Set<Int> = []
    
    // New alarms use global defaults — no custom overrides initially
    // But we still show the mode pickers for per-alarm customization
    @State private var useCustomSnoozeMode = false
    @State private var snoozeMode: SnoozeMode
    @State private var snoozeHoldDuration: Double
    @State private var maxSnoozeCount: Int
    @State private var useCustomSkipMode = false
    @State private var skipAlarmMode: SkipAlarmMode
    @State private var skipHoldDuration: Double
    @State private var customVolumeLevel: Double? = nil
    @State private var customVibrationEnabled: Bool? = nil
    @State private var customFadeInEnabled: Bool? = nil
    @State private var customFadeInDuration: Int? = nil
    @State private var useCustomGracePeriod = false
    @State private var customGracePeriod: Double = 0
    @State private var swipeLeftCommandID: UUID?
    @State private var swipeRightCommandID: UUID?
    @State private var dismissAppURI: String = ""
    @State private var snoozeAppURI: String = ""
    /// Ordered after-alarm pipeline. New alarms start empty (no legacy state).
    @State private var afterAlarmActions: [AfterAlarmAction] = []
    /// Notes after-alarm config (text + 4 command slots) for the new alarm.
    @State private var alarmScreenNotes: String = ""
    @State private var noteCommandIDs: [String?] = [nil, nil, nil, nil]
    /// After-alarm action config pop-out, anchored on the Form root. Notes are NOT
    /// routed here — see `showNotesEditor`.
    @State private var afterAlarmEdit: AfterAlarmEditRequest?
    /// Editing a Notes card opens the full-screen editor DIRECTLY from this Form
    /// root — no intermediate config sheet to stack a second screen on top of.
    @State private var showNotesEditor = false
    @State private var alarmRadioStation: RadioStation?
    /// Station browser presentation, anchored on this editor's Form root (a
    /// stable root) rather than the picker's Form-row context — the latter
    /// tore this editor sheet down when the cover presented.
    @State private var stationBrowserMode: StationBrowserMode?
    /// Custom-alarm-tone screen, anchored on the Form root for the same reason
    /// as stationBrowserMode.
    @State private var customToneMode: CustomToneMode?
    /// Mission "Try It Out" preview, anchored on the Form root for the same
    /// reason as stationBrowserMode.
    @State private var missionPreview: MissionPreviewRequest?
    /// The mission-slot pop-out request, anchored on the Form root (see the edit
    /// editor for rationale).
    @State private var missionSlotEdit: MissionSlotEditRequest?
    /// Accordion state: the one editor section currently expanded (nil = all collapsed)
    @State private var expandedEditorSection: AlarmEditorSection?
    /// Which swipe direction the unified command picker is filling. Anchored on
    /// the Form root (same rule as stationBrowserMode / missionSlotEdit).
    @State private var swipePicker: SwipeCommandTarget?
    @FocusState private var isNameFocused: Bool
    
    init(settings: DeviceSettings, storeManager: StoreManager, onCreate: @escaping (Alarm) -> Void) {
        self.settings = settings
        self.storeManager = storeManager
        self.onCreate = onCreate
        
        _snoozeDuration = State(initialValue: settings.defaultSnoozeDuration)
        _soundName = State(initialValue: settings.defaultAlarmSound)
        
        _mission = State(initialValue: settings.defaultMission)
        
        _snoozeMode = State(initialValue: settings.snoozeMode)
        _maxSnoozeCount = State(initialValue: settings.defaultMaxSnoozeCount)
        _snoozeHoldDuration = State(initialValue: settings.snoozeHoldDuration)
        _skipAlarmMode = State(initialValue: settings.skipAlarmMode)
        _skipHoldDuration = State(initialValue: settings.skipAlarmHoldDuration)
        // New alarms inherit the default wake-up radio station (Settings > Sound)
        _alarmRadioStation = State(initialValue: settings.defaultRadioStation)
    }
    
    /// Whether an existing alarm has the same label
    private var isDuplicateLabel: Bool {
        allAlarms.contains { $0.label.trimmingCharacters(in: .whitespaces) == label.trimmingCharacters(in: .whitespaces) }
    }
    
    /// Whether the label is empty or blank
    private var isEmptyLabel: Bool {
        label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether the label has no ASCII letters/digits (would produce an auto-generated MQTT slug)
    private var hasNoASCIIChars: Bool {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }
    
    /// Suggest a unique name by appending the next available number
    private var suggestedUniqueLabel: String {
        let base = label.trimmingCharacters(in: .whitespaces)
        let existingLabels = Set(allAlarms.map { $0.label })
        var candidate = base
        var counter = 2
        while existingLabels.contains(candidate) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    /// True when any slot (slot 1 or an extra) is a Home Assistant mission.
    private var hasHAMission: Bool {
        mission.type == .homeAssistant || extraMissions.contains { $0.type == .homeAssistant }
    }

    /// Binding to whichever slot's Mission is Home Assistant (slot 1 or an extra),
    /// or nil when no slot uses HA.
    private var haMissionBinding: Binding<Mission>? {
        if mission.type == .homeAssistant { return $mission }
        if let i = extraMissions.firstIndex(where: { $0.type == .homeAssistant }) {
            return Binding(
                get: { i < extraMissions.count ? extraMissions[i] : Mission() },
                set: { newValue in
                    guard i < extraMissions.count else { return }
                    extraMissions[i] = newValue
                }
            )
        }
        return nil
    }

    /// Mission type driving the Snooze section — HA whenever any slot is HA.
    private var snoozeMissionType: MissionType {
        hasHAMission ? .homeAssistant : mission.type
    }

    var body: some View {
        NavigationStack {
            Form {
                #if DEBUG
                Section {
                    Button("Test Alarm (10s)") {
                        saveAlarm(debugFireIn: 10)
                    }
                    .disabled(isEmptyLabel)
                }
                #endif

                Section {
                    WheelTimePicker(selection: $selectedTime)
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                        .clipped()

                    LabeledContent("Alarm Name") {
                        TextField("Enter a name", text: $label)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .submitLabel(.done)
                            .focused($isNameFocused)
                            .onSubmit { isNameFocused = false }
                    }
                    
                    if isEmptyLabel {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                            Text("Alarm name cannot be empty.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else if hasNoASCIIChars {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Name should include at least one letter or number for MQTT compatibility.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else if isDuplicateLabel {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(accent)
                                .font(.caption)
                            Text("Will be saved as \"\(suggestedUniqueLabel)\"")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    DayPickerView(selectedDays: $selectedDays)
                }
                
                AlarmSoundPicker(
                    selectedSoundID: $soundName,
                    alarmVolumeLevel: settings.alarmVolumeLevel,
                    customVolumeLevel: $customVolumeLevel,
                    customVibrate: $customVibrationEnabled,
                    globalVibrateDefault: settings.alarmVibrationEnabled,
                    customFadeIn: $customFadeInEnabled,
                    customFadeInDuration: $customFadeInDuration,
                    globalFadeInDefault: settings.alarmFadeInEnabled,
                    globalFadeInDurationDefault: settings.alarmFadeInDuration,
                    radioStation: $alarmRadioStation,
                    startCollapsed: true,
                    expandedSection: $expandedEditorSection,
                    stationBrowserMode: $stationBrowserMode,
                    customToneMode: $customToneMode
                )
                
                MissionSelectorView(
                    mission: $mission,
                    extraMissions: $extraMissions,
                    settings: settings,
                    mqttEnabled: settings.mqttEnabled,
                    onEditSlot: { missionSlotEdit = MissionSlotEditRequest(target: $0) }
                )

                // Snooze section — when snooze runs in HA mode, the fallback snooze
                // controls fold into this same section (see SnoozeSectionView).
                SnoozeSectionView(
                    snoozeMode: $snoozeMode,
                    snoozeDuration: $snoozeDuration,
                    snoozeHoldDuration: $snoozeHoldDuration,
                    maxSnoozeCount: $maxSnoozeCount,
                    useCustomSnoozeMode: $useCustomSnoozeMode,
                    settings: settings,
                    missionType: snoozeMissionType,
                    haMission: haMissionBinding,
                    startCollapsed: true,
                    expandedSection: $expandedEditorSection
                )

                SkipAlarmSectionView(
                    skipAlarmMode: $skipAlarmMode,
                    skipHoldDuration: $skipHoldDuration,
                    useCustomSkipMode: $useCustomSkipMode,
                    settings: settings,
                    startCollapsed: true,
                    expandedSection: $expandedEditorSection
                )

                // Automations, flattened into two independent top-level sections
                // (the old umbrella nested accordions inside an accordion).
                // Swipe Commands only appears when the arm button surfaces them.
                if settings.armButtonEnabled {
                    Section("Swipe Commands") {
                        SwipeCommandSection(
                            swipeLeftCommandID: $swipeLeftCommandID,
                            swipeRightCommandID: $swipeRightCommandID,
                            settings: settings,
                            // Reported UP so the picker presents from the Form root.
                            onRequestPicker: { swipePicker = $0 },
                            expandedSection: $expandedEditorSection
                        )
                    }
                }

                // After Alarm: the ordered post-dismiss pipeline (verse / weather /
                // open-app) as a numbered-box grid — replaces the old standalone App
                // Launch section and Morning Weather toggle.
                AfterAlarmSectionView(
                    actions: $afterAlarmActions,
                    settings: settings,
                    onEdit: { target in
                        // Notes open the full-screen editor DIRECTLY; every other
                        // action type uses the config sheet.
                        if target == .action(.notes) {
                            showNotesEditor = true
                        } else {
                            afterAlarmEdit = AfterAlarmEditRequest(target: target)
                        }
                    }
                )
            }
            .scrollDismissesKeyboard(.immediately)
            // Keyed on whether ANY slot is HA (see the edit editor for rationale).
            .onChange(of: hasHAMission) { _, isHA in
                if isHA {
                    snoozeMode = .homeAssistant
                    useCustomSnoozeMode = true
                } else if snoozeMode == .homeAssistant {
                    snoozeMode = settings.snoozeMode
                    useCustomSnoozeMode = false
                }
            }
            .navigationTitle("New Alarm")
            .navigationBarTitleDisplayMode(.inline)
            // Anchored on the Form root (a stable root), NOT the picker's
            // Form-row context — presenting from a Form row inside this editor
            // sheet tore the sheet down. Mirrors SleepSoundSetupView.
            .fullScreenCover(item: $stationBrowserMode) { mode in
                NavigationStack {
                    RadioBrowserView(
                        settings: DeviceSettings.shared,
                        pickMode: true,
                        startInFavoritesEdit: mode == .edit,
                        onPick: { alarmRadioStation = $0 }
                    )
                }
            }
            .customAlarmToneScreen(mode: $customToneMode)
            .fullScreenCover(item: $missionPreview) { request in
                MissionPreviewView(mission: request.mission, settings: settings)
            }
            // Mission-slot pop-out, anchored on the Form root. Compacts the
            // sequence on dismiss so cleared middle slots close their gap.
            .sheet(item: $missionSlotEdit, onDismiss: compactMissions) { request in
                MissionSlotEditorSheet(
                    target: request.target,
                    mission: $mission,
                    extraMissions: $extraMissions,
                    useCustomGracePeriod: $useCustomGracePeriod,
                    customGracePeriod: $customGracePeriod,
                    settings: settings,
                    mqttEnabled: settings.mqttEnabled
                )
            }
            // After-alarm action config pop-out, anchored on the Form root.
            .sheet(item: $afterAlarmEdit) { request in
                AfterAlarmActionEditorSheet(
                    target: request.target,
                    actions: $afterAlarmActions,
                    dismissAppURI: $dismissAppURI,
                    snoozeAppURI: $snoozeAppURI,
                    notesText: $alarmScreenNotes,
                    noteCommandIDs: $noteCommandIDs,
                    settings: settings
                )
            }
            // Editing a Notes card — presented DIRECTLY from the Form root, with no
            // intermediate config sheet (that stacked two screens and trapped the
            // user with no way back into the note).
            .notesAfterAlarmEditor(
                isPresented: $showNotesEditor,
                settings: settings,
                notes: $alarmScreenNotes,
                commandIDs: $noteCommandIDs,
                actions: $afterAlarmActions
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAlarm()
                    }
                    .disabled(isEmptyLabel)
                }
            }
            .onAppear {
                // Generate a unique default label based on existing alarms
                let existingLabels = Set(allAlarms.map { $0.label })
                if existingLabels.contains(label) {
                    label = suggestedUniqueLabel
                }
            }
            // The unified command picker, anchored on the Form root.
            .sheet(item: $swipePicker) { target in
                CommandPickerSheet(
                    destination: target.destination,
                    currentID: target.isLeft ? swipeLeftCommandID : swipeRightCommandID,
                    settings: settings,
                    onPick: { newID in
                        if target.isLeft { swipeLeftCommandID = newID }
                        else { swipeRightCommandID = newID }
                    }
                )
            }
            // Clear unsaved draft assignments when their command is deleted from
            // the library (the picker can delete while this editor is open).
            .onReceive(NotificationCenter.default.publisher(for: .mqttCommandDeleted)) { note in
                guard let id = note.userInfo?["id"] as? UUID else { return }
                if swipeLeftCommandID == id { swipeLeftCommandID = nil }
                if swipeRightCommandID == id { swipeRightCommandID = nil }
                CommandDeletionCoordinator.clearDraftSlots(&noteCommandIDs, deleted: id)
            }
        }
    }

    /// Keeps missions packed into contiguous slots 1..N. Tap (`.none`) slots are
    /// real, combinable missions now, so they are NOT filtered out — dropping them
    /// here would silently delete configured Tap slots. Clearing a slot is an
    /// explicit removal (the sheet's "No Mission" tile, the Remove context action),
    /// so slots are already packed; this only re-splits the packed list back through
    /// the bindings. Idempotent — safe to run on every pop-out dismiss.
    private func compactMissions() {
        var all = [mission] + extraMissions
        let first = all.removeFirst()
        if mission != first { mission = first }
        if extraMissions != all { extraMissions = all }
    }

    private func saveAlarm(debugFireIn: TimeInterval? = nil) {
        // Block saving with empty label
        if isEmptyLabel { return }

        // Auto-fix duplicate names by appending next available number
        if isDuplicateLabel {
            label = suggestedUniqueLabel
        }

        var fireTime = selectedTime
        var fireDays = selectedDays
        
        // DEBUG: Override alarm time to fire in N seconds
        #if DEBUG
        if let debugFireIn {
            fireTime = Date().addingTimeInterval(debugFireIn)
            fireDays = []  // Make it one-time so it fires at the exact time
            print("🐛 DEBUG: New alarm '\(label)' will fire in \(Int(debugFireIn))s at \(fireTime)")
        }
        #endif
        
        // Same resolution as the edit path — a new alarm and an edited one must
        // agree about what "custom" stores, so both go through one place (al-qcd).
        let skipOverride = AlarmOverrideResolution.skipFields(
            isCustom: useCustomSkipMode,
            mode: skipAlarmMode,
            holdDuration: skipHoldDuration
        )
        let snoozeOverride = AlarmOverrideResolution.snoozeFields(
            isCustom: useCustomSnoozeMode,
            mode: snoozeMode,
            holdDuration: snoozeHoldDuration,
            maxCount: maxSnoozeCount
        )

        let newAlarm = Alarm(
            time: fireTime,
            label: label,
            isEnabled: true,
            recurringDays: fireDays,
            soundName: soundName,
            snoozeDuration: snoozeDuration,
            mission: mission,
            allowSkipOnce: skipOverride.allowSkipOnce,
            skippedFireDate: nil,
            lastFireDate: nil,
            skipHoldDuration: skipOverride.holdDuration,
            maxSnoozeCount: snoozeOverride.maxCount,
            customSnoozeHoldDuration: snoozeOverride.holdDuration,
            snoozeModeRaw: snoozeOverride.mode?.rawValue,
            skipAlarmModeRaw: skipOverride.mode?.rawValue
        )
        newAlarm.extraMissions = extraMissions
        newAlarm.customVolumeLevel = customVolumeLevel
        newAlarm.customVibrationEnabled = customVibrationEnabled
        newAlarm.customFadeInEnabled = customFadeInEnabled
        newAlarm.customFadeInDuration = customFadeInDuration
        if useCustomGracePeriod {
            newAlarm.customGracePeriod = customGracePeriod
        }
        // Save swipe command assignments
        newAlarm.swipeLeftCommandID = swipeLeftCommandID?.uuidString
        newAlarm.swipeRightCommandID = swipeRightCommandID?.uuidString

        // Save the after-alarm pipeline: explicit order plus legacy fields kept in
        // sync (weather ⇔ showWeatherAfterAlarm; appLink present → keep dismiss
        // link, else clear). The snooze link is independent and always saved.
        newAlarm.afterAlarmActions = afterAlarmActions
        newAlarm.showWeatherAfterAlarm = afterAlarmActions.contains(.weather)
        let trimmedDismissLink = dismissAppURI.trimmingCharacters(in: .whitespacesAndNewlines)
        if afterAlarmActions.contains(.appLink) {
            newAlarm.dismissAppURI = trimmedDismissLink.isEmpty ? nil : trimmedDismissLink
        } else {
            newAlarm.dismissAppURI = nil
        }
        let trimmedSnoozeLink = snoozeAppURI.trimmingCharacters(in: .whitespacesAndNewlines)
        newAlarm.snoozeAppURI = trimmedSnoozeLink.isEmpty ? nil : trimmedSnoozeLink

        // Notes after-alarm config (only when the step is part of the pipeline)
        if afterAlarmActions.contains(.notes) {
            newAlarm.alarmScreenNotes = alarmScreenNotes
            let slots = noteCommandIDs + Array(repeating: nil, count: max(0, 4 - noteCommandIDs.count))
            newAlarm.alarmScreenCommandID1 = slots[0]
            newAlarm.alarmScreenCommandID2 = slots[1]
            newAlarm.alarmScreenCommandID3 = slots[2]
            newAlarm.alarmScreenCommandID4 = slots[3]
        }

        // Save wake-up radio station snapshot
        newAlarm.radioStationID = alarmRadioStation?.id
        newAlarm.radioStationName = alarmRadioStation?.name
        newAlarm.radioStationURL = alarmRadioStation?.streamURL

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        let days = fireDays.isEmpty ? "one-time" : fireDays.sorted().map(String.init).joined(separator: ",")
        AppLogger.shared.log("New alarm: '\(label)' time=\(timeFormatter.string(from: fireTime)) days=\(days) mission=\(mission.type.rawValue) sound=\(soundName) vol=\(customVolumeLevel.map { String(format: "%.0f%%", $0 * 100) } ?? "default") snooze=\(snoozeDuration)min", category: .alarm)
        
        onCreate(newAlarm)
        dismiss()
    }
    
}

// MARK: - Reusable Fallback Configuration Views

struct FallbackGracePeriodSettings: View {
    @Binding var gracePeriod: Double
    let fallbackMission: Mission
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Grace Period")
                    .font(.subheadline)
                Spacer()
                if gracePeriod == 0 {
                    Text("Auto (\(Int(fallbackMission.calculatedGracePeriod))s)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(Int(gracePeriod))s")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            FormSlider(
                value: $gracePeriod,
                range: 0...120,
                step: 5
            )
        }
        .padding(.vertical, 4)

        Text("A timer for the alarm to sound again in case you fall back asleep.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Swipe command assignment

/// Which swipe direction the unified command picker is filling. Identifiable so
/// the host editors can drive `.sheet(item:)` from their Form ROOT — the swipe
/// rows only report the request up (presenting from a Form row inside the editor
/// sheet tears the sheet down; see stationBrowserMode above).
enum SwipeCommandTarget: String, Identifiable {
    case left, right

    var id: String { rawValue }
    var isLeft: Bool { self == .left }
    var destination: CommandAssignmentDestination { isLeft ? .alarmSwipeLeft : .alarmSwipeRight }
}

private struct SwipeCommandSection: View {
    @Binding var swipeLeftCommandID: UUID?
    @Binding var swipeRightCommandID: UUID?
    @Bindable var settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }
    /// Reports a tapped row UP to the host editor, which presents the unified
    /// `CommandPickerSheet` from its Form root.
    var onRequestPicker: (SwipeCommandTarget) -> Void
    /// Shared accordion state — expanding this section collapses the editor's others
    var expandedSection: Binding<AlarmEditorSection?> = .constant(nil)

    private var commands: [MQTTCommand] { settings.mqttCommands }

    private var isExpanded: Bool { expandedSection.wrappedValue == .swipeCommands }

    /// Whether any swipe command is assigned
    private var hasAssignments: Bool {
        swipeLeftCommandID != nil || swipeRightCommandID != nil
    }
    
    /// Summary text for the collapsed card
    private var collapsedSummaryText: String {
        if !hasAssignments {
            return "No swipe commands assigned"
        }
        var parts: [String] = []
        if let id = swipeLeftCommandID, let cmd = commands.first(where: { $0.id == id }) {
            parts.append("← \(cmd.name)")
        }
        if let id = swipeRightCommandID, let cmd = commands.first(where: { $0.id == id }) {
            parts.append("→ \(cmd.name)")
        }
        return parts.joined(separator: " · ")
    }
    
    /// Emits plain list rows — the parent Section provides the header.
    var body: some View {
        Group {
            if !isExpanded {
                collapsedCard
            } else {
                expandedContent
                SectionCollapseButton(accent: accent) {
                    expandedSection.wrappedValue = nil
                }
            }
        }
    }

    // MARK: - Collapsed Card
    
    private var collapsedCard: some View {
        Button {
            withAnimation(.smooth) {
                expandedSection.wrappedValue = .swipeCommands
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "hand.draw.fill")
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 36)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Swipe Commands")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(collapsedSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Text(hasAssignments ? "On" : "Off")
                    .font(.subheadline)
                    .foregroundStyle(accent)
                
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(accent)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Expanded Content
    
    /// Deliberately built to read like Command Widget › Widget Gestures: the
    /// same `CommandAssignmentRow`, the same plain directional glyphs, the same
    /// accent tint on every row, and a trailing explainer instead of a leading
    /// one. An alarm's swipes and the widget's gestures are the same idea
    /// pointed at different surfaces, so they shouldn't look like two features.
    /// Only the collapsed card and the collapse chevron stay editor-specific.
    private var expandedContent: some View {
        Group {
            // Both rows open the SAME picker the notes slots and widget gestures
            // use — presented by the host from its Form root.
            CommandAssignmentRow(
                destination: .alarmSwipeLeft,
                command: swipeLeftCommandID.flatMap { id in commands.first { $0.id == id } },
                leadingGlyph: "arrow.left",
                leadingTint: accent,
                onTap: { onRequestPicker(.left) }
            )

            CommandAssignmentRow(
                destination: .alarmSwipeRight,
                command: swipeRightCommandID.flatMap { id in commands.first { $0.id == id } },
                leadingGlyph: "arrow.right",
                leadingTint: accent,
                onTap: { onRequestPicker(.right) }
            )

            Text("These fire when you swipe the alarm's row left or right on the home screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Wheel Time Picker (focus-safe UIViewRepresentable)

/// Wraps UIDatePicker (wheel style) in a UIViewRepresentable to reduce keyboard
/// appearance lag. Marks the picker as non-focusable so the UIKit focus engine
/// skips it when building its focus map on keyboard show.
private struct WheelTimePicker: UIViewRepresentable {
    @Binding var selection: Date

    func makeUIView(context: Context) -> _NonFocusableDatePicker {
        let picker = _NonFocusableDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .wheels
        picker.addTarget(
            context.coordinator,
            action: #selector(Coordinator.valueChanged(_:)),
            for: .valueChanged
        )
        return picker
    }

    func updateUIView(_ picker: _NonFocusableDatePicker, context: Context) {
        if !Calendar.current.isDate(picker.date, equalTo: selection, toGranularity: .minute) {
            picker.setDate(selection, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: WheelTimePicker
        init(_ parent: WheelTimePicker) { self.parent = parent }
        @objc func valueChanged(_ picker: UIDatePicker) { parent.selection = picker.date }
    }
}

final class _NonFocusableDatePicker: UIDatePicker {
    override var canBecomeFocused: Bool { false }
}

#Preview {
    @Previewable @State var previewAlarm = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Alarm.self, configurations: config)
        let alarm = Alarm()
        container.mainContext.insert(alarm)
        return alarm
    }()
    
    AlarmEditorView(
        alarm: previewAlarm,
        settings: DeviceSettings.shared,
        storeManager: StoreManager.shared
    )
}
