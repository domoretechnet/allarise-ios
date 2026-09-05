//
//  SettingsSkipAlarmSectionView.swift
//  HaWake Alarm V2
//
//  Liquid Glass skip alarm mode selector for Settings defaults.
//  Binds directly to DeviceSettings properties.
//

import SwiftUI

struct SettingsSkipAlarmSectionView: View {
    @Bindable var settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }
    
    @State private var isEditingHold = false

    var body: some View {
        Section("Default Skip Alarm") {
            skipModeButtons
                .onChange(of: settings.skipAlarmMode) { _, newValue in
                    if newValue != .hold {
                        isEditingHold = false
                    }
                }
                .onDisappear {
                    isEditingHold = false
                }

            switch settings.skipAlarmMode {
            case .tap:
                tapSummary
            case .hold:
                if isEditingHold {
                    holdEditControls
                } else {
                    holdSummary
                }
            case .disabled:
                disabledSummary
            }
        }
    }
    
    // MARK: - Liquid Glass Buttons
    
    private var skipModeButtons: some View {
        HStack(spacing: 12) {
            ForEach(SkipAlarmMode.allCases) { mode in
                let isSelected = settings.skipAlarmMode == mode
                
                Button {
                    settings.skipAlarmMode = mode
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
    
    // MARK: - Tap Summary
    
    private var tapSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.tap.fill")
                .font(.title2)
                .foregroundStyle(accent)
                .frame(width: 36)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Tap to Skip")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Tap the skip button from the alarm list to skip the next occurrence of an alarm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
    
    // MARK: - Hold Summary (collapsed)
    
    private var holdSummary: some View {
        Button {
            withAnimation(.smooth) {
                isEditingHold = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 36)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Hold to Skip")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(holdDurationText)
                            .font(.subheadline)
                            .foregroundStyle(accent)
                    }
                    Text("Press and hold the skip button to prevent accidental skips.")
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
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
    
    // MARK: - Hold Edit Controls (expanded)
    
    private var holdEditControls: some View {
        Group {
            HStack {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 36)
                
                Text("Hold to Skip")
                    .font(.headline)
            }
            
            Text("Press and hold the skip button to prevent accidental skips.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
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
                    value: $settings.skipAlarmHoldDuration,
                    range: 0.5...30,
                    step: 0.5
                )
            }
            .padding(.vertical, 4)
        }
    }
    
    // MARK: - Disabled Summary
    
    private var disabledSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(accent)
                .frame(width: 36)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Skip Disabled")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("The skip button is hidden. Alarms cannot be skipped from the alarm list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
    
    // MARK: - Helpers
    
    private func skipModeLabel(_ mode: SkipAlarmMode) -> String {
        switch mode {
        case .tap:      return "Tap"
        case .hold:     return "Hold"
        case .disabled: return "Disabled"
        }
    }
    
    private func skipModeIcon(_ mode: SkipAlarmMode) -> String {
        switch mode {
        case .tap:      return "hand.tap.fill"
        case .hold:     return "hand.raised.fill"
        case .disabled: return "xmark.circle.fill"
        }
    }
    
    private var holdDurationText: String {
        if settings.skipAlarmHoldDuration == 0 {
            return "Instant"
        } else {
            return String(format: "%.1fs", settings.skipAlarmHoldDuration)
        }
    }
}
