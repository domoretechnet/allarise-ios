//
//  CommandFormView.swift
//  HaWake Alarm V2
//
//  THE command creator/editor. One form, three entry points:
//    • "Create New Command" inside `CommandPickerSheet` (assignment context)
//    • a picker row's Edit action
//    • the command library (`CommandLibraryView`), pushed
//
//  Editing NEVER changes a command's UUID, so every place it is assigned picks up
//  the change automatically. Creating from an assignment context saves to
//  `settings.mqttCommands` and hands the new command back so the caller can wire
//  it to the requesting destination.
//
//  Validation and execution semantics are unchanged from the two forms this
//  replaces (`NewQuickCommandSheet` + `MQTTCommandDetailView`): a name is
//  required, a URL command additionally requires a URL, and Home Assistant is
//  only offered when MQTT is configured.
//

import SwiftData
import SwiftUI

struct CommandFormView: View {
    enum Mode: Equatable {
        case create
        case edit(UUID)

        var isEditing: Bool { if case .edit = self { return true }; return false }
        var editingID: UUID? { if case .edit(let id) = self { return id }; return nil }
    }

    let mode: Mode
    @Bindable var settings: DeviceSettings
    /// Non-nil when the form was launched to fill an assignment — drives the
    /// "Will assign to Button 2" banner.
    var destination: CommandAssignmentDestination?
    /// Whether the form owns a Cancel button (sheet presentation) or is pushed
    /// into an existing navigation stack (no Cancel — Back handles it).
    var showsCancel: Bool = false
    /// CREATE only: which type to start on. The picker passes its active filter
    /// here, so "Add Command" from the Shortcuts tab opens a Shortcut command.
    /// A PREFILL, not a decision — the type tabs stay right at the top of this
    /// form, so a wrong guess is one tap to fix. nil keeps the Home Assistant
    /// default.
    var initialIsURL: Bool?
    /// True only when the user reached this form THROUGH the command widget —
    /// its Widget List rows, or a picker opened from a widget gesture. Gates the
    /// "Show in Widget List" option, which is a widget concern and has no
    /// business being asked while someone fills a Notes button or an alarm
    /// swipe. Nil `destination` (the library) is not the widget context either.
    var widgetContext: Bool = false
    /// Fires after the command is written to `settings.mqttCommands`, with the
    /// saved value (same UUID on edit).
    var onSaved: (MQTTCommand) -> Void = { _ in }
    /// Fires after the command was deleted everywhere.
    var onDeleted: (UUID) -> Void = { _ in }
    /// DEBUG harness hook (`-commandFormDebug delete`): pop the delete
    /// confirmation shortly after appearing so its usage-warning copy can be
    /// screenshotted. Never set in the shipping app.
    var debugAutoDeleteConfirm: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Query private var alarms: [Alarm]

    private var accent: Color { settings.appAccent(for: colorScheme) }

    @State private var name: String = ""
    @State private var icon: String = "terminal"
    @State private var colorR: Double = 0.0
    @State private var colorG: Double = 0.47
    @State private var colorB: Double = 1.0
    @State private var armAction: MQTTCommand.ArmAction = .none
    @State private var showInList: Bool = true
    @State private var isURL: Bool = false
    @State private var actionURL: String = ""
    @State private var didLoad = false
    @State private var showDeleteConfirm = false
    /// The custom color well's presentation flag lives on the FORM, not on
    /// `CommandColorGrid` and not on the row: every picked color writes
    /// colorR/G/B on each drag tick, which re-renders this body and rebuilds the
    /// Form row the grid occupies. Anything the row owns — including a `.sheet`
    /// — goes down with it, which is how the picker used to dismiss itself on
    /// the first touch (al-dgb).
    @State private var showingCustomColorPicker = false
    /// Picks buffer here while the picker is open; committed in onDismiss.
    /// See SystemColorPicker.swift for why nothing may render per pick.
    @State private var customPickBuffer = ColorSelectionBuffer()

    private var iconColor: Color { Color(red: colorR, green: colorG, blue: colorB) }

    /// URL type is forced when Home Assistant/MQTT is off — there is nothing to
    /// publish to, so a command can only open a URL.
    private var isURLType: Bool { isURL || !settings.mqttEnabled }

    private var trimmedURL: String { actionURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var saveDisabled: Bool {
        if trimmedName.isEmpty { return true }
        if isURLType && trimmedURL.isEmpty { return true }
        return false
    }

    private var editingCommand: MQTTCommand? {
        guard let id = mode.editingID else { return nil }
        return settings.mqttCommands.first { $0.id == id }
    }

    /// The user's MQTT zone label, shown in the security section header so it
    /// names the actual alarm being controlled. Matches ArmButtonView's fallback.
    private var securityZoneName: String {
        let zone = settings.armZone.trimmingCharacters(in: .whitespaces)
        return zone.isEmpty ? "Home" : zone
    }

    /// Toggling the add-on on picks Arm as the starting action; off clears it.
    private var securityEnabled: Binding<Bool> {
        Binding(
            get: { armAction != .none },
            set: { armAction = $0 ? .arm : .none }
        )
    }

    /// One arm/disarm/toggle tile. No glyph — the three actions don't have
    /// meaningful ones — but the same tile and height as the type tabs above, so
    /// this form doesn't stack two differently-sized choosers.
    private func securityPill(_ action: MQTTCommand.ArmAction) -> some View {
        AccentSegmentTile(
            title: action.label,
            isSelected: armAction == action,
            accent: accent,
            action: { armAction = action }
        )
    }

    /// One command-type tile. Carries the same glyph the source badge uses, so
    /// the two read as one system.
    private func typePill(_ label: String, glyph: String, isURLValue: Bool) -> some View {
        AccentSegmentTile(
            title: label,
            systemImage: glyph,
            isSelected: isURL == isURLValue,
            accent: accent,
            action: { isURL = isURLValue }
        )
    }

    var body: some View {
        Form {
            if let destination {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.turn.down.right")
                            .foregroundStyle(accent)
                        Text("Will assign to \(destination.label)")
                            .font(.subheadline)
                        Spacer(minLength: 0)
                    }
                }
            }

            // Type — only offered when Home Assistant is configured. With HA off,
            // commands can only open URLs, so the picker is hidden.
            if settings.mqttEnabled {
                Section {
                    // Accent-themed selectable tiles, matching the command picker's
                    // filter row and the mission/mode choosers, instead of a stock
                    // segmented bar.
                    AccentSegmentRow {
                        typePill("Home Assistant",
                                 glyph: CommandSourceKind.homeAssistant.glyph,
                                 isURLValue: false)
                        typePill("Shortcut / Link",
                                 glyph: CommandSourceKind.shortcut.glyph,
                                 isURLValue: true)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } footer: {
                    Text(isURLType
                        ? "Opens a shortcut, app link, or web address when tapped."
                        : "Publishes an action to Home Assistant when tapped.")
                }
            }

            Section {
                TextField("Command name", text: $name)
                    .autocorrectionDisabled()
            } header: {
                Text("Name")
            } footer: {
                Text(isURLType
                    ? "The label shown on the command button."
                    : "This name is published as a sensor value to Home Assistant when the command is tapped.")
            }

            if isURLType {
                Section {
                    TextField("shortcuts://run-shortcut?name=…", text: $actionURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("URL")
                } footer: {
                    Text("A Shortcuts link (shortcuts://run-shortcut?name=…), another app link (mailto:, tel:), or a web address.")
                }
            }

            Section {
                CommandIconGrid(selectedIcon: $icon, iconColor: iconColor)
            } header: {
                Text("Icon")
            }

            Section {
                CommandColorGrid(colorR: $colorR,
                                 colorG: $colorG,
                                 colorB: $colorB,
                                 onRequestCustomColor: { showingCustomColorPicker = true })
            } header: {
                Text("Icon Color")
            }

            // Security state — Home Assistant commands only, and only when the
            // widget's Alarm Control is on. Without that gate the rows rendered
            // identically while being completely inert, so a user could configure
            // an action that could never fire.
            //
            // Presented as an opt-in ADD-ON rather than four equal choices: this is
            // a side effect layered on the command's normal action, not a pick-one.
            if !isURLType && settings.hassWidgetAlarmEnabled {
                Section {
                    Toggle("Also change security state", isOn: securityEnabled)

                    if armAction != .none {
                        AccentSegmentRow {
                            ForEach(MQTTCommand.ArmAction.allCases.filter { $0 != .none }) { action in
                                securityPill(action)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                } header: {
                    // Zone-named so it's clear WHICH alarm this touches — the zone
                    // is the user's own MQTT label and is what the widget shows.
                    Text("\(securityZoneName) Security Alarm Action")
                } footer: {
                    Text(armAction == .none
                        ? "Besides its normal action, this command can arm or disarm the \(securityZoneName) security alarm in Home Assistant."
                        : "Running this command will also \(armAction.label.lowercased()) the \(securityZoneName) security alarm in Home Assistant.")
                }
            }

            // Widget list membership — ONLY when the user got here through the
            // command widget. Asking "show this in the widget list?" while
            // someone is filling a Notes button or an alarm swipe is a question
            // about a screen they aren't on. Everywhere else the stored value is
            // carried through this form untouched (see `load()` for the
            // create-time default).
            if widgetContext {
                Section {
                    Toggle("Show in Widget List", isOn: $showInList)
                } footer: {
                    Text("When off, this command won't appear in the expanded widget list. It can still be triggered by a gesture, an alarm swipe, or a notes button.")
                }
            }

            // No Preview section. The icon and color grids above already show
            // the command exactly as it will render, so a separate swatch at the
            // bottom only added scrolling.

            if mode.isEditing {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Command", systemImage: "trash")
                            .foregroundStyle(.red)
                            .frame(minHeight: 44)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        // Anchored on the Form, outside every Section — see
        // `showingCustomColorPicker` above and SystemColorPicker.swift (al-dgb).
        // Picks land in the buffer only; the commit to colorR/G/B happens in
        // onDismiss, AFTER the picker is gone — writing them per pick re-renders
        // this Form and tore the picker down (al-dgb round 4).
        .sheet(isPresented: $showingCustomColorPicker, onDismiss: {
            if let picked = customPickBuffer.take() {
                let rgb = commandColorComponents(of: picked)
                colorR = rgb.r
                colorG = rgb.g
                colorB = rgb.b
            }
        }) {
            CustomColorPickerSheet(
                initial: iconColor,
                onPick: { customPickBuffer.latest = $0 },
                onFinish: { showingCustomColorPicker = false }
            )
            // Our own picker sizes to its content — no safe-area override or
            // large detent needed the way the system picker did.
            .presentationDetents([.medium, .large])
        }
        .navigationTitle(mode.isEditing ? "Edit Command" : "New Command")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(mode.isEditing ? "Save" : "Add") { save() }
                    .fontWeight(.semibold)
                    .disabled(saveDisabled)
            }
        }
        .onAppear {
            load()
            if debugAutoDeleteConfirm {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showDeleteConfirm = true }
            }
        }
        .confirmationDialog(deleteTitle,
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete Everywhere", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: - Delete copy

    private var deleteUsages: [CommandUsage] {
        guard let id = mode.editingID else { return [] }
        return CommandUsageResolver.usages(of: id, settings: settings, alarms: alarms)
    }

    private var deleteTitle: String {
        guard let command = editingCommand else { return "Delete Command?" }
        return "Delete \(command.displayName)?"
    }

    private var deleteMessage: String {
        guard let command = editingCommand else { return "" }
        return CommandUsageResolver.deletionMessage(for: command, usages: deleteUsages)
    }

    // MARK: - Load / save / delete

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let command = editingCommand else {
            // CREATE. A command made while filling a Notes button or an alarm
            // swipe was made FOR that slot — it shouldn't silently join the home
            // widget's expanded list too. Created from the library (no
            // destination) or for a widget gesture, it does.
            showInList = destination.map(\.isWidget) ?? true
            // Start on the type the caller was already looking at.
            if let initialIsURL { isURL = initialIsURL }
            return
        }
        name = command.name
        icon = command.icon
        colorR = command.iconColorRed
        colorG = command.iconColorGreen
        colorB = command.iconColorBlue
        armAction = command.armAction
        showInList = command.showInList
        isURL = command.isURLCommand
        actionURL = command.actionURL ?? ""
    }

    /// Writes the form back into the library. On edit this mutates IN PLACE at the
    /// command's existing index, so both its UUID and its position are preserved
    /// and every assignment elsewhere keeps resolving.
    private func save() {
        var command: MQTTCommand
        if let id = mode.editingID,
           let index = settings.mqttCommands.firstIndex(where: { $0.id == id }) {
            command = settings.mqttCommands[index]
            apply(to: &command)
            settings.mqttCommands[index] = command
        } else {
            command = MQTTCommand(name: trimmedName)
            apply(to: &command)
            settings.mqttCommands.append(command)
            // Creation only — an edit keeps the same command and its id.
            Analytics.shared.log(.commandCreated(kind: command.sourceKind,
                                                 fromWidgetContext: widgetContext))
        }
        // Remembered on SAVE, not on tap: browsing the grid isn't a choice, and
        // a cancelled form shouldn't reorder anything. Purely a convenience —
        // nothing downstream reads these.
        CommandPaletteRecents.record(icon: command.icon,
                                     colorRed: command.iconColorRed,
                                     colorGreen: command.iconColorGreen,
                                     colorBlue: command.iconColorBlue)

        onSaved(command)
        dismiss()
    }

    private func apply(to command: inout MQTTCommand) {
        command.name = trimmedName
        command.icon = icon
        command.iconColorRed = colorR
        command.iconColorGreen = colorG
        command.iconColorBlue = colorB
        command.showInList = showInList
        if isURLType {
            command.actionURL = trimmedURL.isEmpty ? nil : trimmedURL
            command.armAction = .none
        } else {
            command.actionURL = nil
            command.armAction = armAction
        }
    }

    private func performDelete() {
        guard let id = mode.editingID else { return }
        CommandDeletionCoordinator.delete(id, settings: settings, alarms: alarms, modelContext: modelContext)
        onDeleted(id)
        dismiss()
    }
}

// MARK: - Sheet wrapper

/// `CommandFormView` in its own navigation stack, for sheet presentation. The
/// pushed (global Commands screen) case uses `CommandFormView` directly so it
/// doesn't nest a second stack.
struct CommandFormSheet: View {
    let mode: CommandFormView.Mode
    @Bindable var settings: DeviceSettings
    var destination: CommandAssignmentDestination?
    /// See `CommandFormView.initialIsURL`.
    var initialIsURL: Bool?
    /// See `CommandFormView.widgetContext`.
    var widgetContext: Bool = false
    var onSaved: (MQTTCommand) -> Void = { _ in }
    var onDeleted: (UUID) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            CommandFormView(
                mode: mode,
                settings: settings,
                destination: destination,
                showsCancel: true,
                initialIsURL: initialIsURL,
                widgetContext: widgetContext,
                onSaved: onSaved,
                onDeleted: onDeleted
            )
        }
        .presentationDetents([.large])
    }
}

// MARK: - Shared icon / color grids

/// The icon grid, shared by every command form.
///
/// Collapsed it is a WINDOW onto the full catalog, in two parts: a "Recent" row
/// of the user's own last five icons, then ten more in catalog order with the
/// recents removed so nothing is offered twice. A user who always makes orange
/// lightbulb commands never expands anything.
///
/// The "More" row expands the FULL catalog in place, grouped by category. In
/// place rather than pushed: a Form row that navigates draws a stray disclosure
/// chevron beside its label (ROCK18), and a second screen hid the catalog behind
/// a decision the user had to make before they could look at it.
///
/// The collapsed slice is recomputed whenever the selection lands outside it, so
/// an icon chosen from the expanded catalog is still wearing its checkmark once
/// the section closes again.
struct CommandIconGrid: View {
    @Binding var selectedIcon: String
    let iconColor: Color

    /// One row of recents, five columns wide.
    static let recentLimit = 5
    /// Two rows of catalog beneath it.
    static let inlineLimit = 10

    @State private var recentIcons: [String] = []
    @State private var inlineIcons: [String] = []
    @State private var isExpanded = false

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !recentIcons.isEmpty {
                CommandPaletteCaption(text: "Recent")
                grid(recentIcons)
            }

            if isExpanded {
                ForEach(MQTTCommand.resolvedIconCatalog) { category in
                    CommandPaletteCaption(text: category.name)
                    grid(category.icons)
                }
            } else {
                // Unlabeled when it stands alone — the "Icon" section header
                // has already said what these are.
                if !recentIcons.isEmpty {
                    CommandPaletteCaption(text: "Standard")
                }
                grid(inlineIcons)
            }

            CommandPaletteMoreRow(isExpanded: isExpanded, subject: "icons") {
                // No withAnimation: the swap changes this one Form row's height by a
                // full catalog, and List animates that badly — the captions above
                // visibly tear off and re-drop. Snap the content; the chevron
                // keeps its own rotation animation inside CommandPaletteMoreRow.
                isExpanded.toggle()
            }
        }
        .padding(.vertical, 4)
        .onAppear { refresh() }
        // The form loads the edited command's icon in its OWN onAppear, which
        // runs after this one, so the first refresh can see the placeholder
        // default. Re-running on change covers that and the return from the
        // expanded catalog with one rule.
        .onChange(of: selectedIcon) { _, _ in refresh() }
    }

    private func grid(_ icons: [String]) -> some View {
        LazyVGrid(columns: Self.columns, spacing: 12) {
            ForEach(icons, id: \.self) { iconName in
                Button {
                    selectedIcon = iconName
                } label: {
                    CommandIconTile(icon: iconName,
                                    isSelected: selectedIcon == iconName,
                                    iconColor: iconColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(iconName)
                .accessibilityAddTraits(selectedIcon == iconName ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// Recents are read once — they only change on SAVE, and a row that
    /// reshuffled mid-edit would move tiles out from under the user's thumb.
    /// The slice below them is rebuilt only when it can't show the selection.
    private func refresh() {
        let catalog = MQTTCommand.allAvailableIcons
        if recentIcons.isEmpty {
            recentIcons = CommandPaletteRecents.visibleRecents(CommandPaletteRecents.recentIcons(),
                                                               catalog: catalog,
                                                               limit: Self.recentLimit)
        }
        guard inlineIcons.isEmpty
                || !(inlineIcons.contains(selectedIcon) || recentIcons.contains(selectedIcon)) else { return }
        inlineIcons = CommandPaletteRecents.inlineSlice(catalog: catalog,
                                                        excluding: recentIcons,
                                                        selected: selectedIcon,
                                                        limit: Self.inlineLimit)
    }
}

/// The color grid, shared by every command form.
///
/// Shape: a "Recent" row of the user's own last six colors (custom mixes
/// included, remembered by RGB), then the twelve standard colors in full — every
/// one, named. "More" expands the rest of the named catalog plus the custom
/// color well in place.
///
/// A command carrying a color that ISN'T one of the presets — which
/// `create_command`'s `color_r`/`color_g`/`color_b` has always been able to
/// produce, and the custom color well can too — leads the Recent row so the form
/// still shows what the command looks like, with its checkmark, before Save has
/// had a chance to remember it.
struct CommandColorGrid: View {
    @Binding var colorR: Double
    @Binding var colorG: Double
    @Binding var colorB: Double
    /// Raised when the custom well is tapped. The grid does NOT present the
    /// picker itself — it lives inside a Form row that is rebuilt every time
    /// colorR/G/B change, so the owning form has to hold the presentation state
    /// and the `.sheet` (al-dgb). No default value on purpose: a new call site
    /// that forgets to wire this should fail to compile rather than ship an
    /// inert well.
    let onRequestCustomColor: () -> Void

    /// One row of recents, six columns wide.
    static let recentLimit = 6

    /// Read once on appear — recents only change on SAVE, and this grid is
    /// rebuilt fresh after a save, so re-reading mid-edit would only move tiles
    /// under the user's thumb.
    @State private var storedRecentHexes: [String] = []
    @State private var isExpanded = false

    /// Six across for the unlabeled Recent row; five when the swatches carry
    /// their names, which is how the catalog stays readable at 36 colors.
    private static let recentColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)
    private static let namedColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    /// The preset this command's RGB matches, or nil for a custom color.
    private var selectedName: String? {
        MQTTCommand.presetColorName(red: colorR, green: colorG, blue: colorB)
    }

    private var isCustom: Bool { selectedName == nil }

    private var currentColor: Color { Color(red: colorR, green: colorG, blue: colorB) }

    private var currentHex: String { commandColorHex(red: colorR, green: colorG, blue: colorB) }

    /// The Recent row's contents. A custom in-progress color leads the row so it
    /// always wears its checkmark — the stored list only updates on Save, and a
    /// named color already shows its checkmark down in the Standard grid.
    private var displayRecents: [CommandPaletteRecents.RecentColor] {
        var hexes = storedRecentHexes
        if isCustom { hexes.insert(currentHex, at: 0) }
        return CommandPaletteRecents.recentColors(hexes, limit: Self.recentLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let recents = displayRecents
            if !recents.isEmpty {
                CommandPaletteCaption(text: "Recent")
                recentGrid(recents)
            }

            CommandPaletteCaption(text: "Standard")
            namedGrid(MQTTCommand.presetColors)

            if isExpanded {
                CommandPaletteCaption(text: "More Colors")
                namedGrid(MQTTCommand.extendedColors)
                customWell
            }

            CommandPaletteMoreRow(isExpanded: isExpanded, subject: "colors") {
                // No withAnimation: the swap changes this one Form row's height by a
                // full catalog, and List animates that badly — the captions above
                // visibly tear off and re-drop. Snap the content; the chevron
                // keeps its own rotation animation inside CommandPaletteMoreRow.
                isExpanded.toggle()
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            if storedRecentHexes.isEmpty {
                storedRecentHexes = CommandPaletteRecents.recentColorHexes()
            }
        }
    }

    // OUR UIColorPickerViewController wrapper, not SwiftUI's ColorPicker — see
    // SystemColorPicker.swift for why (al-dgb). Each picked color lands in the
    // same three stored Doubles a preset writes, so a custom color is still
    // not a new kind of value; the form does that writing, since it is also
    // where the picker is presented from.
    private var customWell: some View {
        SystemColorPickerRow(
            title: "Custom Color",
            caption: "Any color you like. Home Assistant can set the same thing with the create_command color_r / color_g / color_b fields.",
            color: currentColor,
            action: onRequestCustomColor
        )
    }

    /// The Recent row: unlabeled swatches, because a custom mix has no name to
    /// carry. Selection is by rendered color, so a recent that happens to equal
    /// the current color wears the checkmark.
    private func recentGrid(_ recents: [CommandPaletteRecents.RecentColor]) -> some View {
        LazyVGrid(columns: Self.recentColumns, spacing: 12) {
            ForEach(recents) { recent in
                Button {
                    colorR = recent.r
                    colorG = recent.g
                    colorB = recent.b
                } label: {
                    CommandColorSwatch(color: recent.color, isSelected: recent.hex == currentHex)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recent.name ?? "Custom color")
                .accessibilityAddTraits(recent.hex == currentHex ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// A labeled catalog grid — the name is the same one `create_command`'s
    /// `color` field takes, and unlabeled circles are impossible to talk about.
    private func namedGrid(_ presets: [(name: String, color: Color, r: Double, g: Double, b: Double)]) -> some View {
        LazyVGrid(columns: Self.namedColumns, spacing: 12) {
            ForEach(presets, id: \.name) { preset in
                Button {
                    select(preset)
                } label: {
                    VStack(spacing: 2) {
                        CommandColorSwatch(color: preset.color, isSelected: selectedName == preset.name)
                        Text(preset.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(selectedName == preset.name ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private func select(_ preset: (name: String, color: Color, r: Double, g: Double, b: Double)) {
        colorR = preset.r
        colorG = preset.g
        colorB = preset.b
    }
}
