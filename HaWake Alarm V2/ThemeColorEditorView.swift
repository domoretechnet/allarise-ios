//
//  ThemeColorEditorView.swift
//  HaWake Alarm V2
//
//  DEBUG-only live editor for the current theme's colors. Edits apply instantly
//  (they write straight into the theme's stored HomeColorCustomization), are
//  remembered per-theme, and can be exported as a "Log" so the exact colors that
//  went with each theme can be shared and baked into the seed presets.
//

#if DEBUG
import SwiftUI

struct ThemeColorEditorView: View {
    @Bindable var settings: DeviceSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme

    /// Which appearance's customization we're editing. Defaults to the current one.
    @State private var editingDark: Bool = false
    @State private var didInitAppearance = false
    /// Bumped after "Log" so the copied-confirmation can show.
    @State private var copiedConfirmation = false

    /// The editable color roles (label + key path into HomeColorCustomization + fallback).
    private struct Role: Identifiable {
        let id = UUID()
        let label: String
        let keyPath: WritableKeyPath<HomeColorCustomization, CodableColor?>
        let fallback: Color
    }

    private let roles: [Role] = [
        Role(label: "Accent (toggle / app tint)", keyPath: \.toggleOnTint, fallback: .blue),
        Role(label: "Skip button", keyPath: \.skipButtonColor, fallback: .orange),
        Role(label: "Snooze", keyPath: \.snoozeColor, fallback: .purple),
        Role(label: "Snooze remaining", keyPath: \.snoozeRemainingColor, fallback: .indigo),
        Role(label: "Arm button", keyPath: \.armButtonColor, fallback: .red),
        Role(label: "Arm button icon", keyPath: \.armButtonIconColor, fallback: .primary),
        Role(label: "Bell icon", keyPath: \.bellIconColor, fallback: .blue),
        Role(label: "Alarm time text", keyPath: \.alarmTimeColor, fallback: .primary),
        Role(label: "Alarm label text", keyPath: \.alarmLabelColor, fallback: .secondary),
        Role(label: "Toolbar", keyPath: \.toolbarColor, fallback: .white),
    ]

    private var presetID: String { settings.appliedHomePresetID ?? "custom" }

    private var themeName: String {
        if let id = settings.appliedHomePresetID,
           let match = settings.loadPresets().first(where: { $0.id.uuidString == id }) {
            return match.name
        }
        return "Custom / Unsaved"
    }

    private var appearanceKey: String { editingDark ? "dark" : "light" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Editing", selection: $editingDark) {
                        Text("Light").tag(false)
                        Text("Dark").tag(true)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Theme: \(themeName)")
                } footer: {
                    Text("Changes apply live and are saved into this theme. Use “Copy Log” to export the exact colors you picked for this theme.")
                }

                Section("Colors") {
                    ForEach(roles) { role in
                        ColorPicker(role.label, selection: colorBinding(for: role), supportsOpacity: false)
                    }
                }

                Section {
                    Button {
                        copyLog()
                    } label: {
                        Label(copiedConfirmation ? "Copied!" : "Copy Log for \(themeName)", systemImage: "doc.on.clipboard")
                    }
                    Button(role: .destructive) {
                        clearThemeEdits()
                    } label: {
                        Label("Clear Logged Edits for This Theme", systemImage: "trash")
                    }
                } footer: {
                    Text("The log lists every color you changed for this theme (light + dark) as hex, ready to paste back.")
                }
            }
            .navigationTitle("Theme Colors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if !didInitAppearance {
                    editingDark = systemColorScheme == .dark
                    didInitAppearance = true
                }
            }
        }
    }

    // MARK: - Editing

    private func colorBinding(for role: Role) -> Binding<Color> {
        Binding(
            get: {
                let custom = editingDark ? settings.homeColorCustomizationDark : settings.homeColorCustomization
                return custom[keyPath: role.keyPath]?.color ?? role.fallback
            },
            set: { newColor in
                let coded = CodableColor(newColor)
                if editingDark {
                    settings.homeColorCustomizationDark[keyPath: role.keyPath] = coded
                } else {
                    settings.homeColorCustomization[keyPath: role.keyPath] = coded
                }
                ThemeColorEditLog.record(
                    presetID: presetID, themeName: themeName,
                    appearance: appearanceKey, role: role.label, hex: Self.hex(coded)
                )
                copiedConfirmation = false
            }
        )
    }

    private func copyLog() {
        UIPasteboard.general.string = ThemeColorEditLog.exportText(presetID: presetID)
        copiedConfirmation = true
    }

    private func clearThemeEdits() {
        ThemeColorEditLog.clear(presetID: presetID)
        copiedConfirmation = false
    }

    static func hex(_ c: CodableColor) -> String {
        String(format: "#%02X%02X%02X",
               Int((c.red * 255).rounded()),
               Int((c.green * 255).rounded()),
               Int((c.blue * 255).rounded()))
    }
}

// MARK: - Per-theme edit log (UserDefaults)

/// Records which colors were hand-picked for which theme, so they can be exported
/// and baked into the seed presets. Keyed by preset id → appearance → role → hex.
enum ThemeColorEditLog {
    private static let key = "themeColorEditLog"
    // presetID -> ["name": themeName, "light"/"dark": [role: hex]]
    private typealias Store = [String: [String: [String: String]]]

    static func record(presetID: String, themeName: String, appearance: String, role: String, hex: String) {
        var store = load()
        var entry = store[presetID] ?? [:]
        // Stash the human name under a reserved bucket so exports read nicely.
        entry["_name", default: [:]]["name"] = themeName
        entry[appearance, default: [:]][role] = hex
        store[presetID] = entry
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear(presetID: String) {
        var store = load()
        store[presetID] = nil
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func exportText(presetID: String) -> String {
        let store = load()
        guard let entry = store[presetID] else {
            return "No color edits logged for this theme yet."
        }
        let name = entry["_name"]?["name"] ?? "Unknown"
        var lines = ["Theme: \(name) (\(presetID))"]
        for appearance in ["light", "dark"] {
            guard let colors = entry[appearance], !colors.isEmpty else { continue }
            lines.append("\(appearance.capitalized):")
            for role in colors.keys.sorted() {
                lines.append("  \(role): \(colors[role] ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func load() -> Store {
        guard let data = UserDefaults.standard.data(forKey: key),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return [:] }
        return store
    }
}
#endif
