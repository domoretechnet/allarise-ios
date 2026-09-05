//
//  SnoozeSectionView.swift
//  HaWake Alarm V2
//
//  Reusable snooze settings section for the alarm editor.
//  Liquid Glass buttons with summary card / edit mode pattern.
//

import SwiftUI

struct SnoozeSectionView: View {
    @Binding var snoozeMode: SnoozeMode
    @Binding var snoozeDuration: Int
    @Binding var snoozeHoldDuration: Double
    @Binding var maxSnoozeCount: Int
    @Binding var useCustomSnoozeMode: Bool
    let settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }
    /// The current alarm mission type — controls whether HA snooze option is shown
    var missionType: MissionType = .none
    /// Binding to the HA slot's Mission (holds the `haSnoozeFallback*` fields).
    /// Non-nil only when a slot uses Home Assistant; drives the embedded fallback
    /// snooze sub-group shown when the snooze mode is Home Assistant.
    var haMission: Binding<Mission>? = nil
    /// When true, the section starts fully collapsed showing only a one-line summary
    var startCollapsed: Bool = false
    /// Shared accordion state — expanding this section collapses the editor's others
    var expandedSection: Binding<AlarmEditorSection?> = .constant(nil)

    private var isExpanded: Bool { expandedSection.wrappedValue == .snooze }

    /// Which modes to show based on current mission
    private var visibleModes: [SnoozeMode] {
        missionType == .homeAssistant ? SnoozeMode.allWithHA : SnoozeMode.standardCases
    }
    
    /// Short labels for the glass buttons
    private func snoozeModeLabel(_ mode: SnoozeMode) -> String {
        switch mode {
        case .tap:           return "Tap"
        case .hold:          return "Hold"
        case .homeAssistant: return "HA"
        case .disabled:      return "Disabled"
        }
    }
    
    /// SF Symbol icons for the glass buttons
    private func snoozeModeIcon(_ mode: SnoozeMode) -> String {
        switch mode {
        case .tap:           return "hand.tap.fill"
        case .hold:          return "hand.raised.fill"
        case .homeAssistant: return "house.fill"
        case .disabled:      return "xmark.circle.fill"
        }
    }
    
    var body: some View {
        Section("Snooze") {
            if startCollapsed && !isExpanded {
                collapsedCard
            } else {
                snoozeModeButtons
                    .onDisappear {
                        if startCollapsed, expandedSection.wrappedValue == .snooze {
                            expandedSection.wrappedValue = nil
                        }
                    }
                    .onChange(of: snoozeMode) { _, newValue in
                        useCustomSnoozeMode = AlarmOverrideResolution.marksCustom(
                            alreadyCustom: useCustomSnoozeMode,
                            edited: newValue,
                            global: settings.snoozeMode
                        )
                    }
                    // Same discard as Skip had (al-qcd): only the MODE latched the
                    // flag, so a hold-duration or max-snoozes edit on its own was
                    // written as nil by Save. Note `snoozeDuration` is absent here
                    // — it binds straight to the model and was never gated.
                    .onChange(of: snoozeHoldDuration) { _, newValue in
                        useCustomSnoozeMode = AlarmOverrideResolution.marksCustom(
                            alreadyCustom: useCustomSnoozeMode,
                            edited: newValue,
                            global: settings.snoozeHoldDuration
                        )
                    }
                    .onChange(of: maxSnoozeCount) { _, newValue in
                        useCustomSnoozeMode = AlarmOverrideResolution.marksCustom(
                            alreadyCustom: useCustomSnoozeMode,
                            edited: newValue,
                            global: settings.defaultMaxSnoozeCount
                        )
                    }
                
                // What the selected mode does, then — immediately — whatever it
                // has to configure. The collapsed card at the top of the section
                // is the only summary; picking a mode used to land on a SECOND
                // summary that had to be tapped again to reach the steppers.
                modeDescription

                if snoozeMode != .disabled && snoozeMode != .homeAssistant {
                    editModeControls
                }

                // Fallback snooze folds in here as a sub-group when the snooze mode
                // is Home Assistant — configures snooze behavior for when MQTT is
                // offline. Shares this section's single expand/collapse.
                if snoozeMode == .homeAssistant, let haMission {
                    FallbackSnoozeRows(mission: haMission)
                }

                if startCollapsed {
                    SectionCollapseButton(accent: accent) {
                        expandedSection.wrappedValue = nil
                    }
                }
            }
        }
    }
    
    // MARK: - Collapsed Card
    
    private var collapsedCard: some View {
        Button {
            withAnimation(.smooth) {
                expandedSection.wrappedValue = .snooze
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: snoozeModeIcon(snoozeMode))
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 36)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snooze")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(collapsedSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()

                Text(collapsedTrailingText)
                    .font(.subheadline)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(accent)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
    
    /// Short description for the collapsed state
    private var collapsedSummaryText: String {
        switch snoozeMode {
        case .tap: return "Tap to snooze"
        case .hold: return "Hold to snooze"
        case .homeAssistant: return "Home Assistant"
        case .disabled: return "Snooze disabled"
        }
    }

    /// Trailing summary on the collapsed card. In HA mode this reflects the
    /// fallback snooze briefly (e.g. "HA · fallback: Hold 5min·3x").
    private var collapsedTrailingText: String {
        switch snoozeMode {
        case .disabled:
            return "Off"
        case .homeAssistant:
            guard let fallback = haMission?.wrappedValue else { return "HA" }
            return "HA · fallback: \(fallbackSummaryText(for: fallback))"
        default:
            return snoozeSummaryText
        }
    }

    /// Compact fallback-snooze summary for the collapsed HA card.
    private func fallbackSummaryText(for mission: Mission) -> String {
        switch mission.haSnoozeFallback {
        case .disabled:
            return "Off"
        default:
            let label = mission.haSnoozeFallback == .hold ? "Hold" : "Tap"
            let count = mission.haSnoozeFallbackMaxCount == 0 ? "∞" : "\(mission.haSnoozeFallbackMaxCount)"
            return "\(label) \(mission.haSnoozeFallbackDuration)min·\(count)x"
        }
    }
    
    // MARK: - Mode description

    /// One caption explaining the selected mode. Replaces the per-mode summary
    /// cards: with the mode tiles right above it, restating the mode as a
    /// headline was noise — what the user needs is what it DOES.
    private var modeDescription: some View {
        Text(modeDescriptionText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeDescriptionText: String {
        switch snoozeMode {
        case .tap:
            return "Tap the snooze button to delay the alarm. Quick and easy, but may lead to accidental snoozes."
        case .hold:
            return "Press and hold the snooze button for the set duration. Prevents accidental snoozes."
        case .homeAssistant:
            return "Home Assistant controls snooze via MQTT. Configure a fallback below if MQTT is unavailable."
        case .disabled:
            return "The snooze button is hidden. The alarm can only be dismissed by completing the mission."
        }
    }

    /// Compact summary of snooze settings for the summary card
    private var snoozeSummaryText: String {
        if snoozeMode == .hold {
            return "\(snoozeDuration)min · \(maxSnoozeCount == 0 ? "∞" : "\(maxSnoozeCount)")x · \(holdDurationText)"
        } else {
            return "\(snoozeDuration)min · \(maxSnoozeCount == 0 ? "∞" : "\(maxSnoozeCount)")x"
        }
    }
    
    private var holdDurationText: String {
        if snoozeHoldDuration == 0 {
            return "Instant"
        } else {
            return String(format: "%.1fs", snoozeHoldDuration)
        }
    }
    
    // MARK: - Edit Mode Controls
    
    private var editModeControls: some View {
        Group {
            Stepper(
                "Snooze: \(snoozeDuration) min",
                value: $snoozeDuration,
                in: 1...30
            )
            
            Stepper(
                "Max Snoozes: \(maxSnoozeCount == 0 ? "Unlimited" : "\(maxSnoozeCount)")",
                value: $maxSnoozeCount,
                in: 0...20
            )
            
            if snoozeMode == .hold {
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
                        value: $snoozeHoldDuration,
                        range: 0.5...30,
                        step: 0.5
                    )
                }
                .padding(.vertical, 4)
            }
            
        }
    }
    
    // MARK: - Liquid Glass Snooze Mode Buttons
    
    private var snoozeModeButtons: some View {
        HStack(spacing: visibleModes.count > 3 ? 8 : 12) {
            ForEach(visibleModes) { mode in
                let isSelected = snoozeMode == mode
                
                Button {
                    snoozeMode = mode
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: snoozeModeIcon(mode))
                            .font(.body)
                        Text(snoozeModeLabel(mode))
                            .font(.caption2)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 4)
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
