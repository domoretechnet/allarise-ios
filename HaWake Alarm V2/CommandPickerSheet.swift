//
//  CommandPickerSheet.swift
//  HaWake Alarm V2
//
//  THE command picker. One implementation, presented from every assignment
//  context: a Notes command-button slot, an alarm's Swipe Left / Swipe Right, the
//  home widget's gesture config, and the global Commands screen's gesture rows.
//
//  ASSIGNMENT ONLY. Commands are used in three distinct places (the home widget,
//  the notes buttons, and the alarm-row swipes), so this sheet keeps a hard line:
//  it *assigns* an existing command (or clears the slot) and nothing else. Every
//  create / edit / delete happens in ONE place — the command library
//  (`CommandLibraryView`), reachable here via "Manage Commands". That keeps the
//  library single-source-of-truth while the three assignment spots stay simple
//  pickers that can't fork the editor's behavior.
//
//  Presentation rule (inherited from the alarm editor / mission pop-out): the
//  HOST anchors this on a stable root — a Form/List root or a NavigationStack —
//  never on the row that was tapped. Presenting from inside a Form row tears the
//  parent editor sheet down.
//

import SwiftUI

struct CommandPickerSheet: View {
    /// Which slot/gesture is being filled — drives the title context.
    let destination: CommandAssignmentDestination
    /// The command currently assigned to `destination` (checkmarked).
    let currentID: UUID?
    @Bindable var settings: DeviceSettings
    /// Reports the new assignment. `nil` = the user cleared it.
    let onPick: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }

    @State private var search = ""
    @State private var filter: Filter = .homeAssistant
    /// The landing tab is chosen once, on first appearance — see `initialFilter`.
    @State private var didPickInitialFilter = false
    /// Drives the reusable creator (`CommandFormView` in `.create` mode).
    @State private var showCreator = false

    /// Picker filters — one is always active; there is no "All". Two kinds is
    /// few enough that a user can just tap the other one, and dropping "All"
    /// buys the remaining tiles the room to carry their source glyph.
    /// "Shortcuts" covers every URL-backed command (Shortcut and Link both live
    /// in `actionURL`).
    private enum Filter: String, CaseIterable, Identifiable {
        case homeAssistant = "Home Assistant"
        case shortcuts = "Shortcuts"

        var id: String { rawValue }

        /// The same glyph the source badges use, so a tile and a row's marker
        /// read as the same thing.
        var glyph: String {
            switch self {
            case .homeAssistant: return CommandSourceKind.homeAssistant.glyph
            case .shortcuts:     return CommandSourceKind.shortcut.glyph
            }
        }

        func matches(_ command: MQTTCommand) -> Bool {
            switch self {
            case .homeAssistant: return command.sourceKind == .homeAssistant
            case .shortcuts:     return command.sourceKind.isURL
            }
        }
    }

    /// Which tab to land on. Without an "All" tab, defaulting blindly to Home
    /// Assistant would open the picker on an empty list for anyone whose
    /// commands are all shortcuts — so: the assigned command's own kind when
    /// there is one, else the first tab that actually has commands.
    private var initialFilter: Filter {
        if let currentID,
           let assigned = settings.mqttCommands.first(where: { $0.id == currentID }) {
            return assigned.sourceKind.isURL ? .shortcuts : .homeAssistant
        }
        if let populated = Filter.allCases.first(where: { option in
            settings.mqttCommands.contains(where: option.matches)
        }) {
            return populated
        }
        return settings.mqttEnabled ? .homeAssistant : .shortcuts
    }

    /// True while a search term is active, which makes the type tabs stand down.
    /// Split out so it is testable.
    static func searchOverridesTypeTabs(_ search: String) -> Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSearching: Bool { Self.searchOverridesTypeTabs(search) }

    /// Search + filter applied, order otherwise untouched.
    ///
    /// A SEARCH SPANS BOTH TABS. Stacking the two meant a command you could name
    /// exactly stayed hidden because it lived under the other tab — the user has
    /// to already know a command's type to find it by name, which is backwards.
    /// Searching is the broad tool; the tabs are for browsing. Every row carries
    /// its source badge, so mixed results still say what each one is.
    var visibleCommands: [MQTTCommand] {
        Self.filtered(settings.mqttCommands,
                      search: search,
                      matching: isSearching ? { _ in true } : filter.matches)
    }

    /// Pure filtering helper — search matches name OR source label, so typing
    /// "shortcut" finds every shortcut command. Split out so it is testable.
    static func filtered(_ commands: [MQTTCommand],
                         search: String,
                         matching: (MQTTCommand) -> Bool) -> [MQTTCommand] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return commands.filter { command in
            guard matching(command) else { return false }
            guard !needle.isEmpty else { return true }
            return command.displayName.lowercased().contains(needle)
                || command.sourceKind.label.lowercased().contains(needle)
        }
    }

    /// Why the list is empty. Scoped to the tab when browsing, unscoped when
    /// searching — a search already covered both tabs, so there is no "try the
    /// other tab" to hint at.
    private var emptyStateText: String {
        if settings.mqttCommands.isEmpty {
            return "No commands yet. Use Add Command below to create one."
        }
        if !isSearching {
            return "No \(filter.rawValue) commands yet."
        }
        return "No commands match."
    }

    /// One filter tile — the app's shared segmented chooser.
    private func filterPill(_ option: Filter) -> some View {
        AccentSegmentTile(
            title: option.rawValue,
            systemImage: option.glyph,
            isSelected: filter == option,
            accent: accent,
            action: { filter = option }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Accent-themed selectable tiles (the app's shared pill/tile
                    // language) rather than a stock segmented bar, matching the
                    // mission/mode choosers elsewhere. Two tiles, one always
                    // active — see `Filter` and `initialFilter`.
                    AccentSegmentRow {
                        ForEach(Filter.allCases) { option in
                            filterPill(option)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section {
                    if visibleCommands.isEmpty {
                        Text(emptyStateText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleCommands) { command in
                            commandRow(command)
                        }
                    }
                } header: {
                    Text(isSearching ? "Search Results" : "Commands")
                } footer: {
                    // Say so while searching: the tab above still shows a
                    // selection, and mixed results would otherwise look like the
                    // filter had broken.
                    Text(isSearching
                         ? "Searching covers both Home Assistant and Shortcuts. Tap a command to assign it to \(destination.label)."
                         : "Tap a command to assign it to \(destination.label).")
                }

                if currentID != nil {
                    Section {
                        Button(role: .destructive) {
                            onPick(nil)
                            dismiss()
                        } label: {
                            // `.destructive` only reddens the TEXT — the glyph
                            // keeps inheriting the list's accent, which read as a
                            // blue icon beside red words. Tinting the whole Label
                            // is how every other destructive row here is built
                            // (see CommandFormView's Delete Command, Settings'
                            // Clear Logs / Reset All Settings).
                            Label("Clear Assignment", systemImage: "xmark.circle")
                                .foregroundStyle(.red)
                                .frame(minHeight: 44)
                        }
                    } footer: {
                        Text("Leaves \(destination.label) with no command. The command itself is kept.")
                    }
                }

                Section {
                    // Opens the ONE reusable command creator (`CommandFormView`),
                    // the same building block the global editor uses. It asks
                    // Home Assistant vs Shortcut only when HA is enabled; with HA
                    // off it goes straight to a Shortcut command. On save it lands
                    // in the shared library and is assigned to this slot.
                    Button {
                        showCreator = true
                    } label: {
                        // Label text matches "Manage Commands" below (.primary — white
                        // on the dark sheet); only the icon carries the accent, so the
                        // two rows in this section no longer read as different colors.
                        Label {
                            Text("Add Command")
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(accent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    // .plain so the row's tint doesn't repaint the title — the
                    // colors above are the ones that ship.
                    .buttonStyle(.plain)

                    NavigationLink {
                        // The LIBRARY — just the commands. This used to push the
                        // command widget's settings page, which answered "manage
                        // my commands" with a screen of widget toggles. It can't
                        // recurse back into a picker, so every context offers it.
                        CommandLibraryView(settings: settings)
                    } label: {
                        Label("Manage Commands", systemImage: "slider.horizontal.3")
                            .frame(minHeight: 44)
                    }
                } footer: {
                    Text("Add a new command (assigned to \(destination.label)), or edit and delete existing ones.")
                }
            }
            .searchable(text: $search, prompt: "Search commands")
            .onAppear {
                // Once only — re-running would yank the tab out from under a
                // user who tapped the other one.
                guard !didPickInitialFilter else { return }
                didPickInitialFilter = true
                filter = initialFilter
            }
            .navigationTitle("Choose Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            // The reusable creator, anchored on this sheet's NavigationStack root.
            // The `destination` drives its "Will assign to …" banner; on save the
            // new command is assigned to this slot and the picker closes.
            .sheet(isPresented: $showCreator) {
                CommandFormSheet(
                    mode: .create,
                    settings: settings,
                    destination: destination,
                    // Open on the type the user is already filtered to: tapping
                    // Add Command from the Shortcuts tab means a shortcut. The
                    // form's own type tabs stay visible, so this is a prefill
                    // the user can override in one tap, not a locked choice.
                    initialIsURL: filter == .shortcuts,
                    // A picker opened from a widget gesture IS the widget
                    // context; one opened from a Notes slot or an alarm swipe
                    // is not, and shouldn't ask about the widget list.
                    widgetContext: destination.isWidget,
                    onSaved: { command in
                        onPick(command.id)
                        dismiss()
                    }
                )
            }
        }
    }

    // MARK: - Rows

    /// Pick-only: tapping assigns. No swipe/context Edit or Delete — those live in
    /// the global editor reached via "Manage Commands".
    private func commandRow(_ command: MQTTCommand) -> some View {
        let isAssigned = command.id == currentID
        return Button {
            onPick(command.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: command.icon)
                    .font(.body)
                    .foregroundStyle(command.iconColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(command.displayName)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: command.sourceKind.glyph)
                                .font(.caption2)
                            Text(command.sourceKind.label)
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)

                        // The security add-on, if the command carries one. Where
                        // a command PUBLISHES is only half of what it does — a
                        // command that also arms the house shouldn't be picked
                        // blind from this list.
                        if command.armAction != .none {
                            Text(command.armAction.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                        }
                    }
                }

                Spacer(minLength: 8)

                if isAssigned {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(accent)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rowAccessibilityLabel(command, isAssigned: isAssigned))
    }

    /// Name, source, security add-on, assignment — in the order the row reads.
    private func rowAccessibilityLabel(_ command: MQTTCommand, isAssigned: Bool) -> String {
        var parts = [command.displayName, command.sourceKind.label]
        if command.armAction != .none {
            parts.append("also \(command.armAction.label.lowercased())s the security alarm")
        }
        if isAssigned { parts.append("assigned") }
        return parts.joined(separator: ", ")
    }
}
