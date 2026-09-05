//
//  NotesAfterAlarmEditorView.swift
//  HaWake Alarm V2
//
//  The DIRECT editor for the after-alarm Notes step — you write the note on a
//  page that looks like the page it will become, instead of typing into a white
//  Form card and imagining the result.
//
//  It reuses the runtime page's chrome verbatim (`NotesPageBackdrop`,
//  `NotesPageHeader`, `NotesCommandSquare` — see NotesAfterAlarmView.swift) but
//  NEVER its execution: the four command squares here are live visual previews
//  that open the shared picker, and can't publish MQTT or open a URL.
//
//  Draft-based, exactly like the pop-out sheets it replaces: everything mutates
//  local state and only Save writes back through `onSave`. X discards (with a
//  confirmation when there are unsaved changes).
//
//  KEYBOARD
//  Typing is the point of this screen, so while the keyboard is up the command
//  section is simply GONE — no docked tab, no fly-out tray above the keyboard.
//  Dragging down out of the text and onto the keyboard dismisses it
//  (`.scrollDismissesKeyboard(.interactively)`), which brings the full command
//  section back; that swipe is the way back to the buttons. Deliberately not a
//  plain downward swipe — the note itself scrolls, so only a drag that reaches
//  the keyboard puts it away.
//

import SwiftUI
import UIKit

struct NotesAfterAlarmEditorView: View {
    /// Starting note text (the host's draft).
    let initialNotes: String
    /// Starting command slots — UUID strings, padded/truncated to exactly four.
    let initialCommandIDs: [String?]
    @Bindable var settings: DeviceSettings
    /// ADD mode: Save stays disabled until there is text or at least one command
    /// (an empty Notes step would be dropped on read anyway). EDIT mode allows an
    /// empty save — the host removes the now-empty Notes action, preserving the
    /// behavior the Form-based editor had.
    var requiresContent: Bool = false
    /// Commits the drafts. The host owns the actual model write.
    var onSave: (String, [String?]) -> Void
    /// Discards. Must never mutate host drafts.
    var onCancel: () -> Void

    /// DEBUG harness hook (`-notesEditorDebug keyboard`): raise the keyboard
    /// shortly after appearing so that state can be screenshotted without a tap.
    /// Same spirit as `AfterAlarmActionEditorSheet.debugAutoPreview`; never set
    /// in the shipping app.
    var debugFocusNote: Bool = false
    /// `-notesEditorDebug jiggle`: start the command grid in edit mode, which
    /// otherwise needs a long-press no screenshot harness can perform.
    var debugSlotsEditMode: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }

    // MARK: Drafts

    @State private var draftNotes: String
    @State private var draftCommandIDs: [String?]

    // MARK: Transient UI state

    @FocusState private var isWriting: Bool
    /// Which slot the picker is filling (nil = closed). Presented from this
    /// view's ROOT so the draft survives.
    @State private var pickerSlot: SlotBox?
    @State private var showDiscardConfirm = false
    /// Jiggle mode for the command grid (long-press to enter, tap outside to
    /// exit) — the mission editor's model. Transient, never persisted.
    @State private var slotsEditMode = false

    /// Identifiable slot index so `.sheet(item:)` can drive the picker.
    private struct SlotBox: Identifiable {
        let slot: Int
        var id: Int { slot }
    }

    /// Matches the runtime page's card inset (and the alert / Home Assistant
    /// cards), so the editor's card sits exactly where the page's will.
    private let horizontalPadding: CGFloat = 16

    init(initialNotes: String,
         initialCommandIDs: [String?],
         settings: DeviceSettings,
         requiresContent: Bool = false,
         onSave: @escaping (String, [String?]) -> Void,
         onCancel: @escaping () -> Void,
         debugFocusNote: Bool = false,
         debugSlotsEditMode: Bool = false) {
        self.initialNotes = initialNotes
        self.initialCommandIDs = initialCommandIDs
        self.settings = settings
        self.requiresContent = requiresContent
        self.onSave = onSave
        self.onCancel = onCancel
        self.debugFocusNote = debugFocusNote
        self.debugSlotsEditMode = debugSlotsEditMode
        _slotsEditMode = State(initialValue: debugSlotsEditMode)
        _draftNotes = State(initialValue: initialNotes)
        _draftCommandIDs = State(initialValue: Self.normalizedSlots(initialCommandIDs))
    }

    /// Always exactly four slots, whatever the host handed over.
    static func normalizedSlots(_ slots: [String?]) -> [String?] {
        Array((slots + Array(repeating: nil, count: 4)).prefix(4))
    }

    // MARK: - Derived state

    private var trimmedNotes: String {
        draftNotes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the draft would render something — the same rule the Form-based
    /// editor used.
    var hasContent: Bool {
        !trimmedNotes.isEmpty || draftCommandIDs.contains(where: { $0 != nil })
    }

    private var saveDisabled: Bool { requiresContent && !hasContent }

    private var hasUnsavedChanges: Bool {
        draftNotes != initialNotes || draftCommandIDs != Self.normalizedSlots(initialCommandIDs)
    }

    /// The home wallpaper, resolved through the SAME path the runtime flow and
    /// `AfterAlarmActionEditorSheet.previewWallpaper` use, so the editor never
    /// shows a background the real page wouldn't.
    private var wallpaper: UIImage? {
        guard settings.homeWallpaperEnabled else { return nil }
        return settings.loadWallpaper(for: settings.activeHomeWallpaperKey(forDark: colorScheme == .dark))
    }

    private func command(inSlot slot: Int) -> MQTTCommand? {
        guard slot < draftCommandIDs.count,
              let raw = draftCommandIDs[slot],
              let uuid = UUID(uuidString: raw) else { return nil }
        return settings.mqttCommands.first { $0.id == uuid }
    }

    // MARK: - Compacted slot model (grid)

    /// Assigned slot indices in order, skipping holes and IDs whose command was
    /// deleted from the library. The grid works on this dense view; the draft
    /// array stays four-wide because that's the shape the host round-trips.
    private var filledSlots: [Int] {
        (0..<4).filter { command(inSlot: $0) != nil }
    }

    /// The commands behind `filledSlots`, in the same order.
    private var assignedCommands: [MQTTCommand] {
        filledSlots.compactMap { command(inSlot: $0) }
    }

    /// Write a dense list of command IDs back into the four-wide draft.
    private func writeSlots(_ ids: [String?]) {
        let dense = ids.compactMap { $0 }
        draftCommandIDs = Self.normalizedSlots(dense.map { Optional($0) })
    }

    /// Reorder commit from the grid: `order` is the new arrangement of indices
    /// into `assignedCommands`.
    private func reorderSlots(_ order: [Int]) {
        let current = assignedCommands
        let reordered = order.compactMap { $0 < current.count ? current[$0].id.uuidString : nil }
        writeSlots(reordered.map { Optional($0) })
    }

    /// Minus badge: clear that button. The command itself stays in the library —
    /// this only unassigns it, which is why there's no delete confirmation.
    private func removeSlot(_ index: Int) {
        var ids = assignedCommands.map { Optional($0.id.uuidString) }
        guard index < ids.count else { return }
        ids.remove(at: index)
        writeSlots(ids)
        if ids.isEmpty { slotsEditMode = false }
    }

    /// The draft slot the next assignment should fill — the first hole.
    private var nextFreeSlot: Int {
        (0..<4).first { command(inSlot: $0) == nil } ?? 3
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            NotesPageBackdrop(wallpaper: wallpaper, accent: accent)

            VStack(alignment: .leading, spacing: 0) {
                navigationBar
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 8)

                // Header + writing area on the SHARED card, exactly like the
                // runtime page this screen previews. Both used to lay white text
                // straight onto the wallpaper; when the runtime page moved to a
                // card its backdrop scrim was lightened to suit, which left this
                // screen's white-on-photo text sitting on a weaker scrim than it
                // was designed for.
                VStack(alignment: .leading, spacing: 14) {
                    NotesPageHeader(accent: accent, titleColor: .primary)
                    noteEditor
                }
                .padding(.vertical, 28)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .themedCard(accent: accent)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 12)
            }
            // Interactive content stays clear of the keyboard; only the backdrop
            // above ignores it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomSection
            }
        }
        .statusBarHidden(true)
        .onAppear {
            guard debugFocusNote else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                isWriting = true
            }
        }
        // Picker anchored on the ROOT, never on a command square's own hierarchy,
        // so the note draft survives the presentation.
        .sheet(item: $pickerSlot) { box in
            CommandPickerSheet(
                destination: .noteSlot(box.slot),
                currentID: command(inSlot: box.slot)?.id,
                settings: settings,
                onPick: { newID in
                    draftCommandIDs[box.slot] = newID?.uuidString
                }
            )
        }
        // A command deleted from the picker/library must not linger in this draft.
        .onReceive(NotificationCenter.default.publisher(for: .mqttCommandDeleted)) { note in
            guard let id = note.userInfo?["id"] as? UUID else { return }
            CommandDeletionCoordinator.clearDraftSlots(&draftCommandIDs, deleted: id)
        }
        .confirmationDialog("Discard changes to this note?",
                            isPresented: $showDiscardConfirm,
                            titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { onCancel() }
            Button("Keep Editing", role: .cancel) { }
        }
    }

    // MARK: - Navigation bar (over the wallpaper)

    private var navigationBar: some View {
        HStack(spacing: 12) {
            Button {
                isWriting = false
                if hasUnsavedChanges { showDiscardConfirm = true } else { onCancel() }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")

            // No page title: the "Notes" heading right below it already names
            // the screen, so a centred "Edit Notes" said it twice.
            Spacer(minLength: 0)

            Button {
                isWriting = false
                onSave(draftNotes, draftCommandIDs)
            } label: {
                Text("Save")
                    .font(.headline)
                    .foregroundStyle(saveDisabled ? Color.white.opacity(0.45) : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(
                        Capsule().fill(saveDisabled ? Color.white.opacity(0.12) : accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(saveDisabled)
            .accessibilityLabel("Save notes")
        }
    }

    // MARK: - Note editor

    /// Multiline editor sitting directly ON the card — no inner box. The card is
    /// already the writing surface; a second rounded rectangle inside it was a
    /// box within a box, and the runtime page this previews puts its notes text
    /// straight onto the card with nothing around it.
    private var noteEditor: some View {
        ZStack(alignment: .topLeading) {
            if draftNotes.isEmpty {
                Text("What should this alarm remind you about?")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    // Matches TextEditor's own text insets so the placeholder
                    // sits exactly where the first typed character will.
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $draftNotes)
                .focused($isWriting)
                .font(.title3)
                .lineSpacing(5)
                .foregroundStyle(.primary)
                .tint(accent)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                // Drag down out of the text and onto the keyboard to dismiss it,
                // the way Messages does. `.interactively` only engages once the
                // touch reaches the keyboard's own frame, so a long note still
                // scrolls normally inside the editor — dismissing takes a
                // deliberate drag past the bottom of the writing area, not any
                // downward swipe.
                .scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Notes text")
    }

    // MARK: - Bottom section

    /// Two states: the full command section when the keyboard is down, and
    /// nothing at all while it's up. The fly-out tray that used to live above the
    /// keyboard is gone — dismissing the keyboard (drag down onto it) is the way
    /// back to the buttons, which is one gesture instead of a tab to find.
    @ViewBuilder
    private var bottomSection: some View {
        if !isWriting {
            fullCommandSection
        }
    }

    /// The complete section — heading plus the four slots. No separate Manage
    /// button: the add tile reads "Add / Edit" and the picker it opens already
    /// carries a "Manage Commands" link, so a second route to the library was
    /// just an extra blue word competing with the heading.
    private var fullCommandSection: some View {
        // The heading now carries title2 weight, so the old 10pt gap left it
        // crowding the row it labels. The section's TOP padding grew with it —
        // a heading has to sit closer to what it labels than to what precedes
        // it, and at equal gaps it read as floating between the two.
        VStack(alignment: .leading, spacing: 20) {
            // Same accent-glyph-plus-title treatment as "Notes" at the top of the
            // page, so both headings on this screen read as headings.
            NotesPageHeader(accent: accent,
                            title: "Command Buttons",
                            icon: "square.grid.2x2.fill")

            // UIKit-backed so drag-to-reorder gets the system's interactive
            // movement — the same reason the alarm editor's mission grid is.
            CommandSlotGrid(
                commands: assignedCommands,
                maxSlots: 4,
                editMode: slotsEditMode,
                onTapSlot: { index in
                    guard index < filledSlots.count else { return }
                    pickerSlot = SlotBox(slot: filledSlots[index])
                },
                onTapAdd: { pickerSlot = SlotBox(slot: nextFreeSlot) },
                onEnterEdit: {
                    // Typing and jiggling at once makes no sense — drop the keyboard.
                    isWriting = false
                    withAnimation(.easeInOut(duration: 0.2)) { slotsEditMode = true }
                },
                onExitEdit: {
                    withAnimation(.easeInOut(duration: 0.2)) { slotsEditMode = false }
                },
                onRemove: { removeSlot($0) },
                onReorder: { reorderSlots($0) }
            )
            .frame(height: CommandSlotGrid.gridHeight)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 32)
        .padding(.bottom, 6)
    }

}

// MARK: - Host presentation

extension View {
    /// Presents the DIRECT Notes editor full-screen when `isPresented`, wired to
    /// the host's notes drafts. Editing a Notes card uses this straight from the
    /// alarm editor's Form root — NOT through `AfterAlarmActionEditorSheet` — so
    /// there's no intermediate sheet to stack a second screen on top of (that
    /// double-present trapped the user with no way back into the note). Save
    /// commits the drafts and, if the note ends up empty, removes the `.notes`
    /// action (the same rule the sheet used). Cancel never mutates the drafts.
    func notesAfterAlarmEditor(
        isPresented: Binding<Bool>,
        settings: DeviceSettings,
        notes: Binding<String>,
        commandIDs: Binding<[String?]>,
        actions: Binding<[AfterAlarmAction]>
    ) -> some View {
        fullScreenCover(isPresented: isPresented) {
            NotesAfterAlarmEditorView(
                initialNotes: notes.wrappedValue,
                initialCommandIDs: commandIDs.wrappedValue,
                settings: settings,
                // Editing an existing card: an empty save removes it, so content
                // isn't required here (unlike ADD mode, handled by the sheet).
                requiresContent: false,
                onSave: { newNotes, slots in
                    let normalized = NotesAfterAlarmEditorView.normalizedSlots(slots)
                    notes.wrappedValue = newNotes
                    commandIDs.wrappedValue = normalized
                    let hasContent = !newNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || normalized.contains(where: { $0 != nil })
                    if !hasContent {
                        actions.wrappedValue.removeAll { $0 == .notes }
                    }
                    isPresented.wrappedValue = false
                },
                onCancel: { isPresented.wrappedValue = false }
            )
        }
    }
}

#if DEBUG
#Preview {
    NotesAfterAlarmEditorView(
        initialNotes: "Take the trash out before 8.",
        initialCommandIDs: [nil, nil, nil, nil],
        settings: DeviceSettings.shared,
        onSave: { _, _ in },
        onCancel: { }
    )
}
#endif
