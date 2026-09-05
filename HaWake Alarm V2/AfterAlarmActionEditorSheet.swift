//
//  AfterAlarmActionEditorSheet.swift
//  HaWake Alarm V2
//
//  The pop-out config sheet for one After-Alarm action, mirroring
//  `MissionSlotEditorSheet`: a draft-based Form with Cancel / Save, anchored on
//  the host editor's Form ROOT (never a Form row — that tears the editor sheet
//  down; see the stationBrowserMode comment in AlarmEditorView) and pinned to the
//  grouped background so it doesn't shift material between detents.
//
//  Two modes:
//    • ADD — presents the REMAINING action types as pastel tiles; picking one
//      reveals its config, and Save appends it to the ordered list.
//    • EDIT — opens straight into the tapped card's config.
//
//  Config per type:
//    • notes   — NOT configured in this Form at all. Notes open
//      `NotesAfterAlarmEditorView` full-screen (from this sheet's stable
//      NavigationStack root, the same anchor the previews use), so the note is
//      written directly on a page that looks like the page it becomes. Edit mode
//      opens it immediately; add mode opens it once the Notes tile is picked.
//    • verse   — a description line, nothing to configure.
//    • weather — a description line and WeatherKit attribution. Any number of
//      alarms may show it (the old two-alarm cap is gone).
//    • appLink — the Dismiss/Snooze link fields migrated verbatim from the old
//      AppLinkSectionView (same bindings + validation). Its presence in the list
//      is the after-alarm "Open App" step; the URL lives in `dismissAppURI`.
//
//  EVERY type is previewable from its config, via the shared
//  `ProminentPreviewButton` → fullScreenCover pattern the mission pop-out
//  established. Each preview renders the REAL shipped screen built from the
//  current DRAFTS, so what's rehearsed is what will run. Previews are inert
//  (notes commands are visible but never publish) with ONE deliberate exception:
//  the Open App preview really opens the link its chip is assigned, since a link
//  that never fires can't be verified. See `AppLinkPreviewView`.
//

import SwiftUI

/// Which card the pop-out edits.
enum AfterAlarmEditTarget: Equatable {
    case action(AfterAlarmAction)   // an existing, filled card
    case add                        // the add box — commits a brand-new action
}

/// Identifiable request so the host can drive `.sheet(item:)` from its Form root.
struct AfterAlarmEditRequest: Identifiable {
    let target: AfterAlarmEditTarget
    var id: String {
        switch target {
        case .action(let a): return "action-\(a.rawValue)"
        case .add:           return "add"
        }
    }
}

struct AfterAlarmActionEditorSheet: View {
    let target: AfterAlarmEditTarget
    /// The ordered action list (source of truth, owned by the host editor).
    @Binding var actions: [AfterAlarmAction]
    /// The appLink config fields (source of truth, owned by the host editor) —
    /// the same bindings the old AppLinkSectionView edited.
    @Binding var dismissAppURI: String
    @Binding var snoozeAppURI: String
    /// The notes config fields (source of truth, owned by the host editor):
    /// the notes text and the four command-button slots (UUID strings of
    /// MQTTCommand; always exactly 4 entries, nil = empty slot).
    @Binding var notesText: String
    @Binding var noteCommandIDs: [String?]
    let settings: DeviceSettings
    /// DEBUG harness hook (`-afterAlarmSectionDebug <action> -autoPreview`): open
    /// the selected action's preview as soon as the sheet appears, so previews can
    /// be screenshotted without a tap. Same spirit as
    /// `ActiveAlarmView.debugStartInMission`; never set in the shipping app.
    var debugAutoPreview: Bool = false

    /// Draft-based editing: everything mutates these local snapshots, written back
    /// to the host bindings only on Save. Cancel / swipe-down discard them.
    @State private var selectedAction: AfterAlarmAction?
    @State private var draftDismissURI: String
    @State private var draftSnoozeURI: String
    @State private var draftNotesText: String
    @State private var draftNoteCommandIDs: [String?]
    /// Drives the full-screen Notes editor. Presented from this sheet's
    /// NavigationStack ROOT (same anchor as the previews) — never from a Form row.
    /// Edit mode starts true so the editor is what the user actually sees.
    @State private var showNotesEditor: Bool
    /// Drive the on-demand full-page previews (the mission "Try It Out" pattern),
    /// each presented as a fullScreenCover from this sheet's root.
    @State private var showNotesPreview = false
    @State private var showVersePreview = false
    @State private var showWeatherPreview = false
    @State private var showAppLinkPreview = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }

    @State private var detent: PresentationDetent = .large

    init(target: AfterAlarmEditTarget,
         actions: Binding<[AfterAlarmAction]>,
         dismissAppURI: Binding<String>,
         snoozeAppURI: Binding<String>,
         notesText: Binding<String>,
         noteCommandIDs: Binding<[String?]>,
         settings: DeviceSettings,
         debugAutoPreview: Bool = false) {
        self.target = target
        self._actions = actions
        self._dismissAppURI = dismissAppURI
        self._snoozeAppURI = snoozeAppURI
        self._notesText = notesText
        self._noteCommandIDs = noteCommandIDs
        self.settings = settings
        self.debugAutoPreview = debugAutoPreview
        // Edit mode opens on its fixed action; add mode starts with nothing picked.
        switch target {
        case .action(let a): _selectedAction = State(initialValue: a)
        case .add:           _selectedAction = State(initialValue: nil)
        }
        // EDITING an existing Notes card never routes through this sheet — the
        // host opens `NotesAfterAlarmEditorView` full-screen directly (presenting a
        // cover on top of this sheet stacked two screens and trapped the user). So
        // this sheet only handles Notes in ADD mode, where the type tile's tap is
        // what opens the editor. Starts closed either way.
        _showNotesEditor = State(initialValue: false)
        _draftDismissURI = State(initialValue: dismissAppURI.wrappedValue)
        _draftSnoozeURI = State(initialValue: snoozeAppURI.wrappedValue)
        _draftNotesText = State(initialValue: notesText.wrappedValue)
        // Defensive: always mirror exactly 4 slots regardless of what the host
        // handed over.
        var slots = noteCommandIDs.wrappedValue
        if slots.count < 4 { slots += Array(repeating: nil, count: 4 - slots.count) }
        _draftNoteCommandIDs = State(initialValue: Array(slots.prefix(4)))
    }

    /// Action types not yet in the list — the choices offered in add mode.
    private var remainingTypes: [AfterAlarmAction] {
        AfterAlarmAction.allCases.filter { !actions.contains($0) }
    }

    private var isAddMode: Bool {
        if case .add = target { return true }
        return false
    }

    /// True when the notes draft has something to show (text or ≥1 command).
    private var draftHasNotesContent: Bool {
        !draftNotesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draftNoteCommandIDs.contains(where: { $0 != nil })
    }

    /// Save is blocked when nothing is chosen, or when adding a Notes step with
    /// no content (nothing to show → the step would be dropped on read anyway).
    private var saveDisabled: Bool {
        guard let action = selectedAction else { return true }
        if action == .notes && isAddMode && !draftHasNotesContent { return true }
        return false
    }

    /// Slot-numbered title mirroring the mission pop-out's "Mission N": the add
    /// box edits the next open slot, an existing card edits its position in the
    /// ordered list.
    private var navTitle: String {
        switch target {
        case .add:
            return "After Alarm \(actions.count + 1)"
        case .action(let a):
            if let index = actions.firstIndex(of: a) {
                return "After Alarm \(index + 1)"
            }
            return "After Alarm"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isAddMode {
                    Section {
                        typePicker
                    } footer: {
                        Text("Pick what happens after this alarm is dismissed.")
                    }
                }

                if let action = selectedAction {
                    config(for: action)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard debugAutoPreview, let action = selectedAction else { return }
                switch action {
                case .notes:   showNotesPreview = true
                case .verse:   showVersePreview = true
                case .weather: showWeatherPreview = true
                case .appLink: showAppLinkPreview = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commit() }
                        .fontWeight(.semibold)
                        .disabled(saveDisabled)
                }
            }
            // The DIRECT Notes editor — the note is written on a page that looks
            // like the page it becomes. Anchored on this sheet's NavigationStack
            // root (same rule as the previews below). Save commits the drafts and
            // closes the whole pop-out; Cancel discards without touching the host
            // bindings (add mode falls back to the type picker).
            .fullScreenCover(isPresented: $showNotesEditor) {
                NotesAfterAlarmEditorView(
                    initialNotes: draftNotesText,
                    initialCommandIDs: draftNoteCommandIDs,
                    settings: settings,
                    // Adding a Notes step with nothing to show stays disallowed;
                    // editing one down to nothing removes it (handled in commit()).
                    requiresContent: isAddMode,
                    onSave: { notes, slots in
                        draftNotesText = notes
                        draftNoteCommandIDs = AfterAlarmActionEditorSheet.normalizedSlots(slots)
                        showNotesEditor = false
                        selectedAction = .notes
                        commit()
                    },
                    onCancel: {
                        showNotesEditor = false
                        if isAddMode {
                            // Back to the type picker — nothing was committed.
                            selectedAction = nil
                        } else {
                            dismiss()
                        }
                    }
                )
            }
            // A command deleted from the picker/library must not linger in the
            // slots this sheet still holds as drafts.
            .onReceive(NotificationCenter.default.publisher(for: .mqttCommandDeleted)) { note in
                guard let id = note.userInfo?["id"] as? UUID else { return }
                CommandDeletionCoordinator.clearDraftSlots(&draftNoteCommandIDs, deleted: id)
            }
            // On-demand preview of the REAL notes page, built from the current
            // drafts. Anchored on the sheet's own root (not a Form row) so the
            // config stays open underneath — the same precedent as the mission
            // preview. previewMode gates side effects (commands visible but
            // inert); Continue and the corner X both dismiss the cover.
            .fullScreenCover(isPresented: $showNotesPreview) {
                NotesAfterAlarmView(
                    notes: draftNotesText,
                    commands: draftPreviewCommands,
                    wallpaper: previewWallpaper.image,
                    onContinue: { showNotesPreview = false },
                    previewMode: true
                )
                .previewCloseButton { showNotesPreview = false }
            }
            // The REAL verse card with real artwork — the same zero-network disk
            // read the flow host does, but for YESTERDAY's verse, so looking at
            // the preview doesn't spoil the one the user wakes up to. When
            // yesterday isn't in the cached manifest it falls back to today's
            // (uncaptioned) rather than showing nothing. Continue and the corner
            // X both dismiss; the card has no other side effects.
            .fullScreenCover(isPresented: $showVersePreview) {
                versePreviewCard
            }
            // The REAL Good Morning card, wallpaper and all. It fetches live
            // WeatherKit data exactly as the shipped card does (that IS the
            // preview) but publishes no HA "awake" state — that belongs to the
            // flow host, which isn't involved here. Tapping anywhere, the card's
            // own dismiss button, and its 30s auto-dismiss all close the preview.
            .fullScreenCover(isPresented: $showWeatherPreview) {
                GoodMorningWeatherView(
                    onDismiss: { showWeatherPreview = false },
                    wallpaperImage: previewWallpaper.image,
                    wallpaperIsDark: previewWallpaper.isDark
                )
                .statusBarHidden(true)
            }
            // The alarm landing page, silent — but its Dismiss / Snooze chips
            // really open the drafted links (see AppLinkPreviewView).
            .fullScreenCover(isPresented: $showAppLinkPreview) {
                AppLinkPreviewView(
                    dismissURI: draftDismissURI,
                    snoozeURI: draftSnoozeURI,
                    settings: settings
                )
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        // Pin the backing to the Form's grouped background so it stays identical at
        // both detents (see MissionSlotEditorSheet for the rationale).
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: - Verse preview

    /// Yesterday's verse when it is cached — captioned, so the user knows why it
    /// isn't the one they will see in the morning — and today's, uncaptioned,
    /// when it isn't. Resolved in a property rather than inline because the
    /// cover's ViewBuilder cannot hold the `let`.
    private var versePreviewCard: some View {
        let preview = VerseOfDayService.shared.previewVerse()
        return VerseOfDayCardView(
            verse: preview.verse,
            caption: preview.isYesterday ? "Yesterday's verse" : nil,
            onContinue: { showVersePreview = false }
        )
        .previewCloseButton { showVersePreview = false }
    }

    // MARK: - Add-mode type picker

    private var typePicker: some View {
        let types = remainingTypes
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12),
                            count: max(1, min(types.count, 3)))
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(types, id: \.self) { type in
                typeTile(type, isSelected: selectedAction == type) {
                    // Notes goes straight into its full-screen editor; every other
                    // type reveals its config inline as before.
                    //
                    // Deliberately NOT setting `selectedAction` for notes here:
                    // doing so rendered `config(for: .notes)` into this Form on
                    // the same frame, so its fallback rows flashed for an instant
                    // before the cover finished animating up — which read as the
                    // OLD Form-based notes screen appearing and then vanishing.
                    // Save sets it (see the cover's onSave); Cancel leaves the
                    // type picker as it was.
                    if type == .notes {
                        showNotesEditor = true
                    } else {
                        selectedAction = type
                    }
                }
            }
        }
    }

    private func typeTile(_ type: AfterAlarmAction, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: type.cardIcon)
                    .font(.title2)
                    .frame(height: 28)
                Text(type.cardLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isSelected ? accent : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .selectableTile(isSelected: isSelected, accent: accent)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Per-action config

    @ViewBuilder
    private func config(for action: AfterAlarmAction) -> some View {
        switch action {
        case .notes:
            // Notes has no Form config — it is edited directly on the full-screen
            // page (opened automatically above). These rows are the fallback the
            // user lands on if they back out of the editor in add mode.
            Section {
                Text(draftNotesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "No note yet."
                     : draftNotesText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)

                ProminentPreviewButton(accent: accent, title: "Edit Notes", icon: "square.and.pencil") {
                    showNotesEditor = true
                }
            } header: {
                Text("Notes")
            } footer: {
                if settings.mqttEnabled {
                    Text("Write the note on the real page, with up to four command buttons. Each runs one of your Home Assistant commands.")
                } else {
                    Text("Write the note on the real page, with up to four command buttons. They run through Home Assistant when MQTT is connected.")
                }
            }

            // On-demand full-page preview of the shipped, RUNTIME page (inert) —
            // the shared prominent launcher, same as every other action type.
            Section {
                ProminentPreviewButton(accent: accent, title: "Preview My Notes") {
                    showNotesPreview = true
                }
            }
        case .verse:
            Section {
                Text("Shows the verse of the day with artwork after you dismiss this alarm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ProminentPreviewButton(accent: accent, title: "Preview Verse") {
                    showVersePreview = true
                }
            } footer: {
                Text("The preview shows yesterday's verse when it's available, so today's is still a surprise in the morning.")
            }
        case .weather:
            Section {
                Text("Shows this morning's weather card after you dismiss this alarm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } footer: {
                // WeatherKit attribution must accompany the weather feature.
                AppleWeatherAttributionView()
                    .padding(.top, 4)
            }

            Section {
                ProminentPreviewButton(accent: accent, title: "Preview Weather") {
                    showWeatherPreview = true
                }
            }
        case .appLink:
            Section {
                Text("Opens an app link after this alarm is dismissed or snoozed. Use any URL another app understands, like a Shortcuts link that runs one of your shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Because this leaves Allarise, it always runs last — it stays at the end of the list automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                linkField(title: "Dismiss Link", text: $draftDismissURI)
                linkField(title: "Snooze Link", text: $draftSnoozeURI)

                Text("Examples: shortcuts://run-shortcut?name=Good%20Morning or https://home.mydomain.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Open App")
            }

            // Unlike the other previews this one is NOT inert — its chips really
            // open the links above, which is the only way to confirm a shortcut
            // URL actually works. The footer says so before the user taps.
            Section {
                ProminentPreviewButton(accent: accent, title: "Preview Open App") {
                    showAppLinkPreview = true
                }
            } footer: {
                Text("Shows the alarm screen. Tapping Dismiss or Snooze there really opens the link above, so you can check it works.")
            }
        }
    }

    private func linkField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
            TextField("Enter URL", text: text)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
            if isInvalidLink(text.wrappedValue) {
                Text("This doesn't look like a valid URL — it won't be opened.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func isInvalidLink(_ uri: String) -> Bool {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && URL(string: trimmed) == nil
    }

    // MARK: - Preview inputs

    /// The draft's assigned commands, in slot order (non-nil slots only) — the
    /// exact `[MQTTCommand]` the shipped page would render.
    private var draftPreviewCommands: [MQTTCommand] {
        (0..<4).compactMap { slotCommand($0) }
    }

    /// The home wallpaper the Notes and Weather cards paint behind their content,
    /// resolved the same way the flow host resolves it
    /// (`LocalNotificationScheduler.loadWeatherWallpaper`) so a preview isn't
    /// showing a background the real card wouldn't. Cheap on repeat access — the
    /// decode is NSCache-backed and downsampled inside `loadWallpaper`.
    private var previewWallpaper: (image: UIImage?, isDark: Bool) {
        let isDark = colorScheme == .dark
        guard settings.homeWallpaperEnabled else { return (nil, isDark) }
        return (settings.loadWallpaper(for: settings.activeHomeWallpaperKey(forDark: isDark)), isDark)
    }

    // MARK: - Notes command slots

    /// Always exactly four slots, whatever a caller hands over.
    static func normalizedSlots(_ slots: [String?]) -> [String?] {
        Array((slots + Array(repeating: nil, count: 4)).prefix(4))
    }

    /// The command currently assigned to a slot, if any.
    private func slotCommand(_ slot: Int) -> MQTTCommand? {
        guard slot < draftNoteCommandIDs.count,
              let idStr = draftNoteCommandIDs[slot],
              let uuid = UUID(uuidString: idStr) else { return nil }
        return settings.mqttCommands.first { $0.id == uuid }
    }

    // MARK: - Commit

    /// Writes drafts back on Save. Add mode appends the chosen action (normalized —
    /// `.appLink` forced last); edit mode leaves ordering alone. appLink always
    /// flushes its link fields. Cancel / swipe-down bypass this and discard.
    private func commit() {
        guard let action = selectedAction else { dismiss(); return }
        if action == .appLink {
            dismissAppURI = draftDismissURI
            snoozeAppURI = draftSnoozeURI
        }
        if action == .notes {
            notesText = draftNotesText
            noteCommandIDs = draftNoteCommandIDs
            // Editing an existing Notes card down to no content removes the
            // card — an empty notes page would be dropped on read anyway.
            if !isAddMode && !draftHasNotesContent {
                actions.removeAll { $0 == .notes }
            }
        }
        if isAddMode, !actions.contains(action) {
            actions = Alarm.normalizeAfterAlarm(actions + [action])
        }
        dismiss()
    }
}

// MARK: - Shared preview chrome

private extension View {
    /// The small top-corner X + hidden status bar every full-page After-Alarm
    /// preview wears, matching `MissionPreviewView`'s bail-out button. Cards whose
    /// only exit is "Continue" need it; the weather card (tap anywhere to dismiss)
    /// doesn't and skips it.
    func previewCloseButton(_ action: @escaping () -> Void) -> some View {
        overlay(alignment: .topTrailing) {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .statusBarHidden(true)
    }
}
