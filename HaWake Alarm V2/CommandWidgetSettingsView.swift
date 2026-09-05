//
//  CommandWidgetSettingsView.swift
//  HaWake Alarm V2
//
//  The home-screen command widget's OWN settings — and only its own. Everything
//  on this page is a property of the widget, not of a command: whether the
//  widget shows at all, how big it is, its arm/disarm control, which command
//  each widget gesture fires, and which commands appear in its expanded list
//  (and in what order).
//
//  The command LIBRARY itself lives in `CommandLibraryView` (Settings ›
//  Commands). It used to live here, which meant "Manage Commands" from a Notes
//  button or an alarm swipe dropped the user into a page of widget toggles, and
//  made "Show in Widget List" look like a property of every command everywhere.
//  Now each consumer owns its assignment page, and the widget's list membership
//  is set here — where it means something.
//

import SwiftUI

struct CommandWidgetSettingsView: View {
    @Bindable var settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }

    /// Gesture slot awaiting a command pick. These assignments used to live in
    /// MQTTCommandEditorView, where "Swipe Left" was indistinguishable from an
    /// ALARM row's swipe (both destinations render the same label) and appeared
    /// while managing the shared library rather than the widget. They belong with
    /// the widget's own settings: pick the slot, then choose a command — the same
    /// flow the alarm editor uses.
    @State private var pickerDestination: CommandAssignmentDestination?

    /// The three widget gestures, paired with the glyph describing each.
    private static let gestureSlots: [(destination: CommandAssignmentDestination, glyph: String)] = [
        (.widgetSwipeLeft,  "arrow.left"),
        (.widgetSwipeRight, "arrow.right"),
        (.widgetDoubleTap,  "hand.tap")
    ]

    var body: some View {
        List {
            Section {
                Toggle(isOn: $settings.armButtonEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.title2)
                            .foregroundStyle(accent)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Alarm & Command Widget")
                            Text("Home Assistant alarm & command widget on the home screen")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onChange(of: settings.armButtonEnabled) { _, _ in
                    if settings.mqttEnabled {
                        HAIntegrationRouter.shared.forceReconnect(settings: settings)
                    }
                }
            }

            if settings.armButtonEnabled {
                Section {
                    Toggle(isOn: $settings.biggerWidget) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.title2)
                                .foregroundStyle(accent)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Expanded Widget")
                                Text("Increase the size of the widget on the home screen")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Toggle(isOn: $settings.hassWidgetAlarmEnabled) {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.shield.fill")
                                .font(.title2)
                                .foregroundStyle(accent)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Alarm Control")
                                Text("Show hold-to-arm/disarm button, synced with Home Assistant")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if settings.hassWidgetAlarmEnabled {
                        HStack(spacing: 12) {
                            Image(systemName: "timer")
                                .font(.title2)
                                .foregroundStyle(accent)
                                .frame(width: 36)
                            Text("Hold Duration")
                            Spacer()
                            Picker("", selection: $settings.armButtonHoldDuration) {
                                Text("0.5s").tag(0.5)
                                Text("1.0s").tag(1.0)
                                Text("1.5s").tag(1.5)
                                Text("2.0s").tag(2.0)
                                Text("2.5s").tag(2.5)
                                Text("3.0s").tag(3.0)
                                Text("4.0s").tag(4.0)
                                Text("5.0s").tag(5.0)
                            }
                            .pickerStyle(.menu)
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.title2)
                                .foregroundStyle(accent)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Alarm Zone")
                                Text("Phones sharing the same zone name see the same arm state")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            TextField("Home", text: $settings.armZone)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 120)
                                .autocorrectionDisabled()
                                .onChange(of: settings.armZone) { _, _ in
                                    if settings.mqttEnabled {
                                        HAIntegrationRouter.shared.forceReconnect(settings: settings)
                                    }
                                }
                        }
                    }
                }

                Section {
                    ForEach(Self.gestureSlots, id: \.destination) { slot in
                        CommandAssignmentRow(
                            destination: slot.destination,
                            command: assignedCommand(for: slot.destination),
                            leadingGlyph: slot.glyph,
                            leadingTint: accent,
                            onTap: { pickerDestination = slot.destination }
                        )
                    }
                } header: {
                    Text("Widget Gestures")
                } footer: {
                    Text("These fire when you swipe or double-tap the command widget on your home screen. They're separate from an alarm's own swipe commands, which are set on each alarm.")
                }

                // MARK: - Widget list
                // The widget-only half of a command: whether it shows in the
                // expanded list, and where. `settings.mqttCommands`' ORDER *is*
                // that list's order, which is why reordering lives here and not
                // in the library.
                //
                // Every command, each with its own switch — flipping one is the
                // whole interaction, so there's no add/remove step and nothing
                // to drill into. The same option also appears inside the shared
                // editor, but ONLY on the widget's own path into it (a picker
                // opened from a Widget Gesture); reaching that editor from a
                // Notes button or an alarm swipe never asks.
                Section {
                    if settings.mqttCommands.isEmpty {
                        Text("No commands yet — add one under Manage Commands.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(Array(settings.mqttCommands.enumerated()), id: \.element.id) { index, command in
                        Toggle(isOn: showInListBinding(at: index)) {
                            CommandLibraryRow(command: command)
                        }
                    }
                    .onMove { from, to in
                        settings.mqttCommands.move(fromOffsets: from, toOffset: to)
                    }
                } header: {
                    Text("Widget List")
                } footer: {
                    Text("Turn a command on to show it in the expanded widget list, and drag to set its order there. A command that's off can still be fired by a widget gesture, an alarm swipe, or a Notes button. New commands are added under Manage Commands.")
                }
            }

            // MARK: - Library
            // Creating, editing, and deleting commands is shared across the
            // widget, alarm swipes, and Notes buttons — so it lives on its own
            // screen rather than inside this one.
            Section {
                NavigationLink {
                    CommandLibraryView(settings: settings)
                } label: {
                    Label("Manage Commands", systemImage: "slider.horizontal.3")
                        .frame(minHeight: 44)
                }
            } footer: {
                Text("Add, edit, and delete the commands themselves. The same library drives alarm swipes and Notes buttons.")
            }
        }
        .navigationTitle("Alarm & Command Widget")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if settings.armButtonEnabled && settings.mqttCommands.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    // Enables drag-to-reorder on the Widget List.
                    EditButton()
                }
            }
        }
        // All presentations are anchored on the List root, never on a row
        // (documented teardown rule).
        .sheet(item: $pickerDestination) { destination in
            CommandPickerSheet(
                destination: destination,
                currentID: assignedCommand(for: destination)?.id,
                settings: settings,
                onPick: { assign($0, to: destination) }
            )
        }
    }

    // MARK: - Widget list membership

    /// Per-command `showInList` binding. Index-based so the write lands back in
    /// `settings.mqttCommands` and trips its persistence `didSet`; guarded
    /// because a delete elsewhere can shrink the array under an open row.
    private func showInListBinding(at index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard index < settings.mqttCommands.count else { return false }
                return settings.mqttCommands[index].showInList
            },
            set: { newValue in
                guard index < settings.mqttCommands.count else { return }
                settings.mqttCommands[index].showInList = newValue
            }
        )
    }

    // MARK: - Widget gesture assignment

    private func assignedCommand(for destination: CommandAssignmentDestination) -> MQTTCommand? {
        let id: UUID?
        switch destination {
        case .widgetSwipeLeft:  id = settings.widgetSwipeLeftCommandID
        case .widgetSwipeRight: id = settings.widgetSwipeRightCommandID
        case .widgetDoubleTap:  id = settings.widgetDoubleTapCommandID
        default:                id = nil
        }
        guard let id else { return nil }
        return settings.mqttCommands.first { $0.id == id }
    }

    private func assign(_ id: UUID?, to destination: CommandAssignmentDestination) {
        switch destination {
        case .widgetSwipeLeft:  settings.widgetSwipeLeftCommandID = id
        case .widgetSwipeRight: settings.widgetSwipeRightCommandID = id
        case .widgetDoubleTap:  settings.widgetDoubleTapCommandID = id
        default:                break
        }
    }
}
