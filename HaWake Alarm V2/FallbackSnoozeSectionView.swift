//
//  FallbackSnoozeSectionView.swift
//  HaWake Alarm V2
//
//  Fallback snooze rows embedded inside the main Snooze section. Shown when the
//  snooze mode is Home Assistant; configures how snooze works when MQTT is
//  unavailable. Rendered WITHOUT its own Section wrapper so it lives inside the
//  Snooze section and participates in that section's single accordion expansion.
//

import SwiftUI

struct FallbackSnoozeRows: View {
    @Binding var mission: Mission

    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }

    /// Local edit toggle — expands the steppers under the fallback summary card.
    /// Kept local (not the editor accordion) so all of Snooze expands/collapses as
    /// one unit; it resets whenever the Snooze section is re-expanded.
    @State private var isEditing = false

    private func snoozeModeLabel(_ mode: SnoozeMode) -> String {
        switch mode {
        case .tap:           return "Tap"
        case .hold:          return "Hold"
        case .homeAssistant: return "HA"
        case .disabled:      return "Disabled"
        }
    }

    private func snoozeModeIcon(_ mode: SnoozeMode) -> String {
        switch mode {
        case .tap:           return "hand.tap.fill"
        case .hold:          return "hand.raised.fill"
        case .homeAssistant: return "house.fill"
        case .disabled:      return "xmark.circle.fill"
        }
    }

    private var holdDurationText: String {
        String(format: "%.1fs", mission.haSnoozeFallbackHoldDuration)
    }

    private var snoozeSummaryText: String {
        if mission.haSnoozeFallback == .hold {
            return "\(mission.haSnoozeFallbackDuration)min · \(mission.haSnoozeFallbackMaxCount == 0 ? "∞" : "\(mission.haSnoozeFallbackMaxCount)")x · \(holdDurationText)"
        } else {
            return "\(mission.haSnoozeFallbackDuration)min · \(mission.haSnoozeFallbackMaxCount == 0 ? "∞" : "\(mission.haSnoozeFallbackMaxCount)")x"
        }
    }

    var body: some View {
        // Visual break between the primary HA snooze content and the fallback group.
        Divider()

        // Sub-group header — matches the app's row idiom (accent icon + headline).
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.title2)
                .foregroundStyle(accent)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("If MQTT Is Offline")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Fallback snooze used when Home Assistant can't be reached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)

        snoozeModeButtons
            .listRowSeparator(.hidden, edges: .bottom)

        if isEditing && mission.haSnoozeFallback != .disabled {
            editModeControls
        } else {
            summaryCard
        }

        Text("Used for snooze if MQTT is unavailable.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Summary Card

    @ViewBuilder
    private var summaryCard: some View {
        switch mission.haSnoozeFallback {
        case .tap:
            Button {
                withAnimation(.smooth) { isEditing = true }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "hand.tap.fill")
                        .font(.title2)
                        .foregroundStyle(accent)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Tap to Snooze")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(snoozeSummaryText)
                                .font(.subheadline)
                                .foregroundStyle(accent)
                        }
                        Text("Tap the snooze button to delay the alarm.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(accent)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

        case .hold:
            Button {
                withAnimation(.smooth) { isEditing = true }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "hand.raised.fill")
                        .font(.title2)
                        .foregroundStyle(accent)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Hold to Snooze")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(snoozeSummaryText)
                                .font(.subheadline)
                                .foregroundStyle(accent)
                        }
                        Text("Press and hold the snooze button for the set duration.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(accent)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

        case .disabled:
            HStack(spacing: 12) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snooze Disabled")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Snooze will not be available when MQTT is offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)

        case .homeAssistant:
            EmptyView()
        }
    }

    // MARK: - Edit Mode Controls

    private var editModeControls: some View {
        Group {
            Stepper(
                "Snooze: \(mission.haSnoozeFallbackDuration) min",
                value: $mission.haSnoozeFallbackDuration,
                in: 1...30
            )

            Stepper(
                "Max Snoozes: \(mission.haSnoozeFallbackMaxCount == 0 ? "Unlimited" : "\(mission.haSnoozeFallbackMaxCount)")",
                value: $mission.haSnoozeFallbackMaxCount,
                in: 0...20
            )

            if mission.haSnoozeFallback == .hold {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Hold Duration")
                            .font(.subheadline)
                        Spacer()
                        Text(holdDurationText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    FormSlider(
                        value: $mission.haSnoozeFallbackHoldDuration,
                        range: 0.5...30,
                        step: 0.5
                    )
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Mode Buttons

    private var snoozeModeButtons: some View {
        HStack(spacing: 12) {
            ForEach(SnoozeMode.standardCases, id: \.self) { mode in
                let isSelected = mission.haSnoozeFallback == mode

                Button {
                    mission.haSnoozeFallback = mode
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: snoozeModeIcon(mode))
                            .font(.body)
                        Text(snoozeModeLabel(mode))
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? accent : Color.primary)
                .selectableTile(isSelected: isSelected, accent: accent)
            }
        }
    }
}
