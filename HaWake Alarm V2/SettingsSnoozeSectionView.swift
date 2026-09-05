//
//  SettingsSnoozeSectionView.swift
//  HaWake Alarm V2
//
//  Liquid Glass snooze mode selector for Settings defaults.
//  Binds directly to DeviceSettings properties. Only standard modes (no HA).
//  Includes text descriptors for each mode.
//

import SwiftUI

struct SettingsSnoozeSectionView: View {
    @Bindable var settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }

    var body: some View {
        Section("Default Snooze") {
            snoozeModeButtons
            
            // Descriptor text for the selected mode
            modeDescriptor
            
            if settings.snoozeMode != .disabled {
                Stepper(
                    "Snooze: \(settings.defaultSnoozeDuration) min",
                    value: $settings.defaultSnoozeDuration,
                    in: 1...30
                )
                
                Stepper(
                    "Max Snoozes: \(settings.defaultMaxSnoozeCount == 0 ? "Unlimited" : "\(settings.defaultMaxSnoozeCount)")",
                    value: $settings.defaultMaxSnoozeCount,
                    in: 0...20
                )
            }
            
            if settings.snoozeMode == .hold {
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
                        value: $settings.snoozeHoldDuration,
                        range: 0.5...30,
                        step: 0.5
                    )
                }
                .padding(.vertical, 4)
            }
            
            Text("This is the default for new alarms. Each alarm can override this setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Liquid Glass Buttons
    
    private var snoozeModeButtons: some View {
        HStack(spacing: 12) {
            ForEach(SnoozeMode.standardCases, id: \.self) { mode in
                let isSelected = settings.snoozeMode == mode
                
                Button {
                    settings.snoozeMode = mode
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
    
    // MARK: - Mode Descriptors
    
    @ViewBuilder
    private var modeDescriptor: some View {
        switch settings.snoozeMode {
        case .tap:
            HStack(spacing: 12) {
                Image(systemName: "hand.tap.fill")
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 36)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tap to Snooze")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Tap the snooze button to delay the alarm. Quick and easy, but may lead to accidental snoozes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            
        case .hold:
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 36)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hold to Snooze")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Press and hold the snooze button for the set duration. Prevents accidental snoozes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            
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
                    Text("The snooze button is hidden. The alarm can only be dismissed by completing the mission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            
        case .homeAssistant:
            EmptyView()
        }
    }
    
    // MARK: - Helpers
    
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
        if settings.snoozeHoldDuration == 0 {
            return "None (Instant)"
        } else {
            return String(format: "%.1fs", settings.snoozeHoldDuration)
        }
    }
}
