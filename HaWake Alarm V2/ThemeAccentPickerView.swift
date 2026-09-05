//
//  ThemeAccentPickerView.swift
//  HaWake Alarm V2
//
//  The accent color row that sits directly under the theme wallpaper strip in
//  Settings, and the picker sheet it opens.
//
//  Deliberate choices:
//
//  • THE ROW LIVES INSIDE `themePickerRow`'s OWN VStack, not as a Form row of
//    its own. A sibling Form row would draw the inset-grouped separator — the
//    "gray bar between the wallpapers and picker" — and the accent belongs to
//    the theme above it, so it reads as part of the same control.
//
//  • A DOT AND ONE LINE OF TEXT. The dot is the current accent, so the row
//    always shows what it controls without being opened.
//
//  • THE SHEET IS THE COMMAND FORM'S COLOR PICKER. It reuses
//    `CommandColorSwatch`, `CommandPaletteCaption` and `CommandPaletteMoreRow`
//    against the same `MQTTCommand` palette, so a user who has picked a command
//    color already knows this screen.
//
//  • EVERY TAP APPLIES IMMEDIATELY. There is no Save; the sheet stays open so
//    the accent can be judged against the live UI behind it. The reset lives in
//    two places — inline on the row once an override exists, and always at the
//    bottom of the sheet.
//

import SwiftUI

// MARK: - Settings row

/// The colored-dot accent row shown under the theme strip.
struct ThemeAccentRow: View {
    @Bindable var settings: DeviceSettings
    /// Name of the applied theme, for the sheet's title. Passed in rather than
    /// re-derived because Settings already has the preset list cached.
    var themeName: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var showingPicker = false

    private var accent: Color { settings.appAccent(for: colorScheme) }
    private var isOverridden: Bool { settings.hasThemeAccentOverride(for: colorScheme) }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                showingPicker = true
            } label: {
                // Deliberately just the dot and one short label. The per-theme,
                // per-appearance storage is real but is NOT narrated here — the
                // row stays the size of a row.
                HStack(spacing: 10) {
                    ThemeAccentDot(color: accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accent Color")
                        Text("Tints buttons and highlights")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Accent color")
            .accessibilityHint("Tints buttons and highlights")

            // Only offered once there is something to undo — a permanently
            // visible Reset on an untouched theme suggests the accent is already
            // customised when it isn't.
            if isOverridden {
                Button {
                    settings.setThemeAccent(nil, for: colorScheme)
                } label: {
                    // `arrow.counterclockwise` is the app's reset glyph — the
                    // same one "Reset All Settings" and "Reset MQTT Alarm IDs"
                    // wear.
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .accessibilityLabel("Reset accent color to theme default")
            }
        }
        .padding(.top, 10)
        .sheet(isPresented: $showingPicker) {
            ThemeAccentPickerSheet(settings: settings,
                                   editingScheme: colorScheme,
                                   themeName: themeName)
                // Sheets get their own environment: without re-applying the app
                // appearance, a forced Light/Dark setting leaves this sheet on
                // the DEVICE scheme, so it renders (and previews the accent) in
                // the opposite appearance from the Settings screen that opened
                // it — while `editingScheme` keeps writing the slot the user was
                // actually looking at.
                .appAppearanceTheme(settings)
        }
    }
}

/// The accent swatch on the settings row. A ring rather than a bare circle so a
/// near-white or near-black accent is still visible on the matching background.
struct ThemeAccentDot: View {
    let color: Color
    var diameter: CGFloat = 22

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            }
    }
}

// MARK: - Picker sheet

/// The commands-section color picker, pointed at the theme accent.
///
/// `editingScheme` is captured from the presenting view rather than read from
/// the environment: the sheet must keep writing the slot the user opened, and
/// the whole point of the feature is that light and dark are separate values.
struct ThemeAccentPickerSheet: View {
    @Bindable var settings: DeviceSettings
    let editingScheme: ColorScheme
    var themeName: String?
    /// Debug-only: open with the catalog already expanded, so the screenshot
    /// harness can capture the "More Colors" grid and the big custom-well bubble
    /// without a tap. Always false in the real Settings row.
    var startExpanded: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var isExpanded = false
    /// Lives here, not in `SystemColorPickerRow`: every picked color writes to
    /// `settings`, which re-renders this view and rebuilds the Form row the well
    /// sits in — a row-owned sheet dies with it (al-dgb).
    @State private var showingCustomPicker = false
    /// Picks buffer here while the picker is open; committed in onDismiss.
    /// See SystemColorPicker.swift for why nothing may render per pick.
    @State private var customPickBuffer = ColorSelectionBuffer()
    /// Read once on appear — recents change only on a discrete pick, and re-reading
    /// mid-edit would reshuffle tiles under the user's thumb.
    @State private var storedRecentHexes: [String] = []

    /// Six across for the unlabeled Recent row; five when the swatches carry
    /// names — the same grids the command color picker uses.
    private static let recentColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)
    private static let namedColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    /// How many recents the row shows.
    private static let recentLimit = 6

    private var current: Color { settings.appAccent(for: editingScheme) }
    private var isOverridden: Bool { settings.hasThemeAccentOverride(for: editingScheme) }
    private var appearanceLabel: String { editingScheme == .dark ? "Dark" : "Light" }

    private var currentComponents: (r: Double, g: Double, b: Double) { commandColorComponents(of: current) }
    private var currentHex: String {
        let rgb = currentComponents
        return commandColorHex(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// The accent colors each theme ships with, for the appearance being edited —
    /// the "Theme Colors" standard set.
    private var themeSwatches: [(name: String, color: Color, r: Double, g: Double, b: Double)] {
        settings.themeAccentSwatches(for: editingScheme)
    }

    /// The named preset the current accent matches, or nil for a custom color.
    private var selectedName: String? {
        let rgb = currentComponents
        return MQTTCommand.presetColorName(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// The theme whose accent the current color matches, if any — so the header
    /// can read "Verdant" rather than "Custom" when the user picks a theme accent.
    private var selectedThemeName: String? {
        themeSwatches.first { commandColorHex(red: $0.r, green: $0.g, blue: $0.b) == currentHex }?.name
    }

    /// Whether the current accent already shows a checkmark somewhere in the
    /// palette (a named preset or a theme accent). When it doesn't — a genuine
    /// custom mix — it leads the Recent row so it still shows what is applied.
    private var isShownInPalette: Bool { selectedName != nil || selectedThemeName != nil }

    /// The Recent row's contents: stored recents, led by the current color when
    /// it is a custom mix with nowhere else to show its checkmark.
    private var displayRecents: [CommandPaletteRecents.RecentColor] {
        var hexes = storedRecentHexes
        if !isShownInPalette { hexes.insert(currentHex, at: 0) }
        return CommandPaletteRecents.recentColors(hexes, limit: Self.recentLimit)
    }


    var body: some View {
        NavigationStack {
            Form {
                Section {
                    let recents = displayRecents
                    if !recents.isEmpty {
                        CommandPaletteCaption(text: "Recent")
                        recentGrid(recents)
                    }

                    CommandPaletteCaption(text: "Theme Colors")
                    themeGrid(themeSwatches)

                    if isExpanded {
                        CommandPaletteCaption(text: "Standard")
                        namedGrid(MQTTCommand.presetColors)
                        CommandPaletteCaption(text: "More Colors")
                        namedGrid(MQTTCommand.extendedColors)
                        customWell
                    }

                    CommandPaletteMoreRow(isExpanded: isExpanded, subject: "colors") {
                        // Un-animated for the same reason the command palette is:
                        // a Form row that grows by a whole catalog animates badly.
                        isExpanded.toggle()
                    }
                } header: {
                    // The heading names what is being edited; the storage model
                    // is not spelled out beyond that. (The current colour's own
                    // preview now lives on the Custom Color well below, not in a
                    // header card.)
                    Text(themeName.map { "\($0) — \(appearanceLabel) Mode" } ?? "\(appearanceLabel) Mode")
                } footer: {
                    // The one storage rule worth narrating: a user who picks a
                    // color here and later flips appearance (or theme) would
                    // otherwise read the unchanged accent there as "it didn't
                    // save" — the exact al-94t report.
                    Text("Saved for \(themeName ?? "this theme") in \(appearanceLabel) Mode. Each theme keeps its own accent for Light and Dark.")
                }

                Section {
                    Button {
                        settings.setThemeAccent(nil, for: editingScheme)
                    } label: {
                        Label("Reset to Theme Default", systemImage: "arrow.counterclockwise")
                            // Styled explicitly rather than left to `role:
                            // .destructive` + `.disabled`, which renders as
                            // ordinary black text in a Form and reads as tappable.
                            .foregroundStyle(isOverridden ? Color.red : Color.secondary)
                    }
                    .disabled(!isOverridden)
                }
            }
            // Anchored on the Form, outside every Section — see al-dgb above.
            // Picks land in the buffer only; the store commit happens in
            // onDismiss, AFTER the picker is gone, so applying the color can't
            // re-render this stack out from under the open picker.
            .sheet(isPresented: $showingCustomPicker, onDismiss: {
                if let picked = customPickBuffer.take() {
                    let rgb = commandColorComponents(of: picked)
                    apply(red: rgb.r, green: rgb.g, blue: rgb.b)
                }
            }) {
                CustomColorPickerSheet(
                    initial: current,
                    onPick: { customPickBuffer.latest = $0 },
                    onFinish: { showingCustomPicker = false }
                )
                // Our own picker sizes to its content, so it needs neither the
                // safe-area override nor the large detent the system picker did.
                .presentationDetents([.medium, .large])
            }
            .navigationTitle("Accent Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if storedRecentHexes.isEmpty {
                    storedRecentHexes = CommandPaletteRecents.recentColorHexes()
                }
                if startExpanded { isExpanded = true }
            }
        }
    }

    // MARK: - Grids

    /// The Recent row: unlabeled swatches (a custom mix has no name to carry),
    /// selection by rendered color.
    private func recentGrid(_ recents: [CommandPaletteRecents.RecentColor]) -> some View {
        LazyVGrid(columns: Self.recentColumns, spacing: 12) {
            ForEach(recents) { recent in
                Button {
                    apply(red: recent.r, green: recent.g, blue: recent.b)
                } label: {
                    CommandColorSwatch(color: recent.color, isSelected: recent.hex == currentHex)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recent.name ?? "Custom color")
                .accessibilityAddTraits(recent.hex == currentHex ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// The theme-accent grid: each swatch labeled with the theme it belongs to,
    /// matched to the current accent by rendered color.
    private func themeGrid(_ swatches: [(name: String, color: Color, r: Double, g: Double, b: Double)]) -> some View {
        LazyVGrid(columns: Self.namedColumns, spacing: 12) {
            ForEach(swatches, id: \.name) { swatch in
                let isSelected = commandColorHex(red: swatch.r, green: swatch.g, blue: swatch.b) == currentHex
                Button {
                    apply(red: swatch.r, green: swatch.g, blue: swatch.b)
                } label: {
                    VStack(spacing: 2) {
                        CommandColorSwatch(color: swatch.color, isSelected: isSelected)
                        Text(swatch.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private func namedGrid(_ presets: [(name: String, color: Color, r: Double, g: Double, b: Double)]) -> some View {
        LazyVGrid(columns: Self.namedColumns, spacing: 12) {
            ForEach(presets, id: \.name) { preset in
                Button {
                    apply(red: preset.r, green: preset.g, blue: preset.b)
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

    // The custom well opens OUR UIColorPickerViewController wrapper, not
    // SwiftUI's ColorPicker — see SystemColorPicker.swift for why (al-dgb).
    private var customWell: some View {
        SystemColorPickerRow(
            title: "Custom Color",
            caption: "Any color you like.",
            color: current,
            // The big preview bubble lives here, on the custom well itself —
            // the current accent shown large right where the spectrum picker is
            // opened, rather than in a separate header card.
            swatchDiameter: 56
        ) {
            showingCustomPicker = true
        }
    }

    /// Applies an accent from its literal RGB — the same value in both
    /// appearances, so the saved accent doesn't shift under a dynamic color — and
    /// remembers it in the shared recent-colors list, custom mixes included. Each
    /// call here is one discrete pick (a swatch tap, or a single commit from the
    /// custom well's onDismiss), never a per-drag tick, so recording is cheap.
    private func apply(red: Double, green: Double, blue: Double) {
        settings.setThemeAccent(Color(red: red, green: green, blue: blue), for: editingScheme)
        CommandPaletteRecents.recordColorHex(red: red, green: green, blue: blue)
        storedRecentHexes = CommandPaletteRecents.recentColorHexes()
    }
}
