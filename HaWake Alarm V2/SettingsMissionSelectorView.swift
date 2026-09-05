//
//  SettingsMissionSelectorView.swift
//  HaWake Alarm V2
//
//  Default Mission section for Settings → Alarm Defaults. The alarm editor's
//  mission picker, rendered INLINE: the full type grid up top (minus Home
//  Assistant — HA is per-alarm, slot-1-only, never the global default), then
//  the same description / Try It Out / difficulty chips / customize controls
//  the MissionSlotEditorSheet shows, via the shared MissionConfigControls
//  views. Everything edits the global defaults live through a write-through
//  Mission binding — no pop-out, no Save.
//

import SwiftUI

struct SettingsMissionSelectorView: View {
    @Bindable var settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }

    /// Launches a full-screen mission preview (owned by AlarmDefaultsView so
    /// the cover anchors on the Form root); nil hides the Try It Out button.
    var onPreview: ((Mission) -> Void)? = nil

    /// Mission types available as defaults (no HA).
    private let availableTypes: [MissionType] = [.none, .shake, .math, .balanceBall, .blockDrop, .meteor]

    /// Paywall shown when a Pro-gated type is tapped.
    @State private var showingPaywall = false

    /// Write-through proxy: the shared controls edit a Mission built from the
    /// current global defaults, and every change decomposes straight back into
    /// the per-type default fields via applyDefaultMission.
    private var defaultMission: Binding<Mission> {
        Binding(
            get: { settings.defaultMission },
            set: { settings.applyDefaultMission($0) }
        )
    }

    var body: some View {
        Section("Default Mission") {
            missionTypeButtons

            if let desc = MissionConfigInfo.description(for: settings.defaultMissionType) {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Math example lives with the type description — same card,
            // mirroring the editor sheet.
            if settings.defaultMissionType == .math {
                MathProblemPreviewRow(difficulty: settings.defaultMathDifficulty)
            }
        }

        if let onPreview,
           settings.defaultMissionType.isPreviewable || settings.defaultMissionType == .none {
            Section {
                Button {
                    onPreview(settings.defaultMission)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Try It Out")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }
        }

        Section {
            if settings.defaultMissionType == .none {
                TapDismissControls(mission: defaultMission)
            } else {
                MissionChipRow(mission: defaultMission, accent: accent)
                MissionCustomizeControls(mission: defaultMission)
            }
        } header: {
            Text(settings.defaultMissionType == .none ? "Dismiss"
                 : settings.defaultMissionType == .shake ? "Intensity" : "Difficulty")
        } footer: {
            Text("This is the default for new alarms. Each alarm can override this setting.")
        }
        .sheet(isPresented: $showingPaywall) {
            ProPaywallView(storeManager: StoreManager.shared)
        }
    }

    // MARK: - Mission type grid (mirrors the editor sheet's picker)

    private var missionTypeButtons: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12),
                            count: availableTypes.count <= 4 ? max(1, availableTypes.count) : 3)
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(availableTypes.enumerated()), id: \.element) { index, type in
                missionButton(for: type, glyphDelay: Double(index) * 0.5)
            }
        }
    }

    private func missionButton(for type: MissionType, glyphDelay: Double) -> some View {
        let isSelected = settings.defaultMissionType == type
        let isLocked = type.requiresPro && !StoreManager.shared.featuresUnlocked

        return Button {
            // A locked type can't become the global default — it would seed
            // every new alarm with a mission the user can't run.
            guard !isLocked else {
                Analytics.shared.log(.paywallShown(source: .missionType))
                showingPaywall = true
                return
            }
            settings.defaultMissionType = type
        } label: {
            VStack(spacing: 6) {
                MissionTypeGlyph(type: type, accent: isSelected ? accent : Color.primary,
                                 animated: true, delay: glyphDelay)
                Text(type.shortLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? accent : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .selectableTile(isSelected: isSelected, accent: accent)
            .overlay(alignment: .topTrailing) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLocked ? "\(type.shortLabel), requires Allarise Pro" : type.shortLabel)
    }
}
