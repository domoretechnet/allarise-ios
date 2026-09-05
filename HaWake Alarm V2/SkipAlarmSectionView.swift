//
//  SkipAlarmSectionView.swift
//  HaWake Alarm V2
//
//  Reusable skip alarm settings section for the alarm editor.
//  Liquid Glass buttons for mode selection with summary cards.
//

import SwiftUI

struct SkipAlarmSectionView: View {
    @Binding var skipAlarmMode: SkipAlarmMode
    @Binding var skipHoldDuration: Double
    @Binding var useCustomSkipMode: Bool
    let settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }
    /// When true, the section starts fully collapsed showing only a one-line summary
    var startCollapsed: Bool = false
    /// Shared accordion state — expanding this section collapses the editor's others
    var expandedSection: Binding<AlarmEditorSection?> = .constant(nil)

    private var isExpanded: Bool { expandedSection.wrappedValue == .skipAlarm }

    /// Short labels for the glass buttons
    private func skipModeLabel(_ mode: SkipAlarmMode) -> String {
        switch mode {
        case .tap:      return "Tap"
        case .hold:     return "Hold"
        case .disabled: return "Disabled"
        }
    }
    
    /// SF Symbol icons for the glass buttons
    private func skipModeIcon(_ mode: SkipAlarmMode) -> String {
        switch mode {
        case .tap:      return "hand.tap.fill"
        case .hold:     return "hand.raised.fill"
        case .disabled: return "xmark.circle.fill"
        }
    }
    
    var body: some View {
        Section("Skip Alarm") {
            if startCollapsed && !isExpanded {
                collapsedCard
            } else {
                skipModeButtons
                    .onDisappear {
                        if startCollapsed, expandedSection.wrappedValue == .skipAlarm {
                            expandedSection.wrappedValue = nil
                        }
                    }
                    .onChange(of: skipAlarmMode) { _, newValue in
                        useCustomSkipMode = AlarmOverrideResolution.marksCustom(
                            alreadyCustom: useCustomSkipMode,
                            edited: newValue,
                            global: settings.skipAlarmMode
                        )
                    }
                    // Hold Duration counts as customising this alarm too (al-qcd).
                    // Without this the slider moved, the row showed the new
                    // number, and Save wrote nil — dropping the alarm back to the
                    // global duration with nothing said. Only the MODE used to
                    // latch the flag, so a duration-only edit was discarded.
                    .onChange(of: skipHoldDuration) { _, newValue in
                        useCustomSkipMode = AlarmOverrideResolution.marksCustom(
                            alreadyCustom: useCustomSkipMode,
                            edited: newValue,
                            global: settings.skipAlarmHoldDuration
                        )
                    }
                
                // What the selected mode does, then — immediately — whatever it
                // has to configure. The collapsed card at the top of the section
                // is the only summary; picking a mode used to land on a SECOND
                // summary that had to be tapped again to reveal one slider.
                modeDescription

                if skipAlarmMode == .hold {
                    holdDurationControl
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
                expandedSection.wrappedValue = .skipAlarm
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: skipModeIcon(skipAlarmMode))
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 36)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skip Alarm")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(collapsedSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if skipAlarmMode == .hold {
                    Text(holdDurationText)
                        .font(.subheadline)
                        .foregroundStyle(accent)
                } else {
                    Text(skipAlarmMode == .disabled ? "Off" : "Tap")
                        .font(.subheadline)
                        .foregroundStyle(accent)
                }
                
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
        switch skipAlarmMode {
        case .tap: return "Tap to skip next occurrence"
        case .hold: return "Hold to skip next occurrence"
        case .disabled: return "Skipping disabled"
        }
    }
    
    // MARK: - Liquid Glass Skip Mode Buttons
    
    private var skipModeButtons: some View {
        HStack(spacing: 12) {
            ForEach(SkipAlarmMode.allCases) { mode in
                let isSelected = skipAlarmMode == mode
                
                Button {
                    skipAlarmMode = mode
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: skipModeIcon(mode))
                            .font(.body)
                        Text(skipModeLabel(mode))
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
        switch skipAlarmMode {
        case .tap:
            return "Tap the skip button from the alarm list to skip the next occurrence of this alarm."
        case .hold:
            return "Press and hold the skip button to prevent accidental skips."
        case .disabled:
            return "The skip button is hidden. This alarm cannot be skipped from the alarm list."
        }
    }

    // MARK: - Hold Duration Control

    private var holdDurationControl: some View {
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
                value: $skipHoldDuration,
                range: 0.5...30,
                step: 0.5
            )
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers
    
    private var holdDurationText: String {
        if skipHoldDuration == 0 {
            return "Instant"
        } else {
            return String(format: "%.1fs", skipHoldDuration)
        }
    }
}
