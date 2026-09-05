//
//  CommandLibraryView.swift
//  HaWake Alarm V2
//
//  THE command library: create, edit, and delete the commands themselves.
//  Nothing widget-specific lives here, and neither does the global Confirm
//  Commands switch (Settings › General) — this screen owns the RECORDS, not how
//  or where they fire.
//
//  Split back out of `CommandWidgetSettingsView` deliberately. Commands drive
//  three independent consumers — the home-screen widget, an alarm's swipes, and
//  the after-alarm Notes buttons — so hosting the library inside the WIDGET's
//  settings made widget-only concerns (which commands appear in the expanded
//  widget list, and in what order) read as properties of a command everywhere,
//  and "Manage Commands" from a Notes button landed the user in a page full of
//  widget toggles.
//
//  The shape now: each consumer owns its own ASSIGNMENT page — the alarm
//  editor's swipe rows, the Notes editor's button grid, the widget's Widget
//  Gestures / Widget List sections — while this screen owns the commands
//  themselves and `CommandFormView` stays the single shared editor behind all
//  of them.
//
//  Reached from Settings › Commands, the picker's "Manage Commands" link, the
//  Notes editor's "Manage" button, and the widget page's own link.
//
//  ORDER IS NOT EDITABLE HERE. The array's order is the widget list's order, so
//  it is edited where it means something — the widget's Widget List section.
//

import SwiftData
import SwiftUI

struct CommandLibraryView: View {
    @Bindable var settings: DeviceSettings
    @Environment(\.modelContext) private var modelContext
    @Query private var alarms: [Alarm]

    /// Presents the shared creator (the list's Add button).
    @State private var showCreator = false
    /// Command awaiting delete confirmation (swipe action).
    @State private var pendingDelete: MQTTCommand?

    var body: some View {
        List {
            Section {
                if settings.mqttCommands.isEmpty {
                    Text("No commands yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ForEach(settings.mqttCommands) { command in
                    NavigationLink {
                        // The SHARED form, pushed (no nested navigation stack).
                        // Editing keeps the command's UUID, so every assignment
                        // elsewhere picks the change up automatically.
                        CommandFormView(mode: .edit(command.id), settings: settings)
                    } label: {
                        CommandLibraryRow(command: command)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = command
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

                if settings.mqttCommands.count < 10 {
                    Button {
                        showCreator = true
                    } label: {
                        Label("Add Command", systemImage: "plus")
                            .frame(minHeight: 44)
                    }
                }
            } header: {
                Text("Commands")
            } footer: {
                if settings.mqttCommands.count >= 10 {
                    Text("Maximum of 10 commands reached.")
                } else {
                    Text("Tap a command to edit it. Swipe to delete, which also clears any alarm swipe, Notes button, or widget gesture using it.")
                }
            }

            // Confirm Commands, mirrored from Settings › General. It is still a
            // GLOBAL switch — same `settings.confirmCommandsEnabled` binding, so
            // the two stay in lockstep — but it surfaces here because this is the
            // screen every "Manage Commands" link lands on, and "do my commands
            // ask before firing?" is the question people have while looking at
            // their commands, not while scrolling General.
            Section {
                Toggle(isOn: $settings.confirmCommandsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Confirm Commands")
                        Text("Applies to all commands")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("When on, swipe commands, tap commands, and button commands all ask for confirmation before they run. This is a global setting — it also appears in Settings › General.")
            }
        }
        .navigationTitle("Commands")
        .navigationBarTitleDisplayMode(.inline)
        // Anchored on the List root, never on a row (documented teardown rule).
        .sheet(isPresented: $showCreator) {
            CommandFormSheet(mode: .create, settings: settings)
        }
        .confirmationDialog(deleteTitle,
                            isPresented: Binding(
                                get: { pendingDelete != nil },
                                set: { if !$0 { pendingDelete = nil } }
                            ),
                            titleVisibility: .visible) {
            Button("Delete Everywhere", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: - Deletion

    private var deleteTitle: String {
        pendingDelete.map { "Delete \($0.displayName)?" } ?? "Delete Command?"
    }

    private var deleteMessage: String {
        guard let command = pendingDelete else { return "" }
        let usages = CommandUsageResolver.usages(of: command.id, settings: settings, alarms: alarms)
        return CommandUsageResolver.deletionMessage(for: command, usages: usages)
    }

    private func confirmDelete() {
        guard let command = pendingDelete else { return }
        pendingDelete = nil
        CommandDeletionCoordinator.delete(command.id, settings: settings, alarms: alarms, modelContext: modelContext)
    }
}

// MARK: - Shared row

/// One command as it appears in a management list: icon, name, source, and the
/// security add-on badge when it carries one. Shared by the library and the
/// widget's Widget List section so the two can't drift.
struct CommandLibraryRow: View {
    let command: MQTTCommand

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: command.icon)
                .font(.body)
                .foregroundStyle(command.iconColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(command.displayName)
                    .foregroundStyle(command.name.isEmpty ? .secondary : .primary)
                HStack(spacing: 4) {
                    Image(systemName: command.sourceKind.glyph)
                        .font(.caption2)
                    Text(command.sourceKind.label)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if command.armAction != .none {
                Text(command.armAction.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            }

        }
        .accessibilityLabel("\(command.displayName), \(command.sourceKind.label)")
    }
}
