//
//  FallbackMissionSectionView.swift
//  HaWake Alarm V2
//
//  Fallback mission selector shown when the primary mission is Home Assistant.
//  Allows the user to configure a local mission used when MQTT is unavailable.
//

import SwiftUI

struct FallbackMissionSectionView: View {
    @Binding var mission: Mission
    /// Shared accordion state — expanding this section collapses the editor's others
    var expandedSection: Binding<AlarmEditorSection?> = .constant(nil)
    /// Launches a full-screen preview of the fallback mission (owned by the
    /// editor so the cover anchors on the Form root); nil hides the row.
    var onPreview: ((Mission) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }

    private var isEditing: Bool { expandedSection.wrappedValue == .fallbackMission }

    /// The fallback mission type (convenience binding into `mission.haFallbackMission`)
    private var fallbackType: MissionType {
        get { mission.haFallbackMission }
    }
    
    /// Human-readable summary of the fallback mission
    private var fallbackSummaryText: String {
        switch mission.haFallbackMission {
        case .none:
            switch mission.haFallbackTapDismissMode {
            case .hold:
                return "Hold \(Int(mission.haFallbackTapHoldDuration))s to Dismiss"
            case .tap:
                return mission.haFallbackTapCount > 1
                    ? "Tap \(mission.haFallbackTapCount)× to Dismiss"
                    : "Tap to Dismiss Alarm in App"
            }
        case .shake:
            switch mission.haFallbackShakeMode {
            case .duration:
                return "Shake · \(mission.haFallbackShakeDuration)s · \(mission.haFallbackShakeIntensity.rawValue)"
            case .count:
                return "Shake · \(mission.haFallbackShakeCount) shakes · \(mission.haFallbackShakeIntensity.rawValue)"
            }
        case .math:
            return "\(mission.haFallbackMathProblemCount) Problem\(mission.haFallbackMathProblemCount == 1 ? "" : "s") · \(mission.haFallbackMathDifficulty.rawValue)"
        case .balanceBall:
            return "Balance · \(mission.haFallbackBalanceDifficulty.rawValue) · \(Int(mission.haFallbackBalanceDifficulty.holdDuration))s hold"
        case .blockDrop:
            return "Bricks · \(mission.haFallbackBlockDropDifficulty.rawValue)"
        case .meteor:
            return "Meteor · \(mission.haFallbackMeteorDifficulty.rawValue)"
        case .homeAssistant, .alert:
            // Not eligible as backups: an HA fallback for an HA mission is
            // circular, and Alert is a notification surface, not a mission.
            return ""
        }
    }
    
    var body: some View {
        // The backup mission TYPE is now chosen in the main mission grid
        // (MissionSelectorView's dual-picker). This section configures the chosen
        // backup's settings.
        //
        // `.none` (Tap) is EDITABLE now. It used to be treated as "no backup, so
        // nothing to configure", which was true when a Tap fallback was always a
        // single tap — but Tap carries a dismiss mode, a tap count and a hold
        // duration, so it has as much to configure as the others.
        Section("Backup Mission") {
            if isEditing {
                editModeControls
            } else {
                summaryCard
            }

            if let onPreview, fallbackType.isPreviewable {
                MissionPreviewRow(accent: accent) {
                    // Preview the fallback exactly as the alarm would run it.
                    onPreview(mission.dismissFallbackMission)
                }
            }

            Text("Runs to dismiss the alarm if Home Assistant is unreachable. Choose the backup in the mission grid above.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isEditing {
                // Grace period for the backup mission — folded in from the
                // former standalone "Fallback Grace Period" section so there
                // is a single grace control living with the backup it governs.
                FallbackGracePeriodSettings(
                    gracePeriod: $mission.haFallbackGracePeriod,
                    fallbackMission: mission.dismissFallbackMission
                )

                SectionCollapseButton(accent: accent) {
                    expandedSection.wrappedValue = nil
                }
            }
        }
    }

    // MARK: - Summary Card
    
    private var summaryCard: some View {
        Group {
            Button {
                withAnimation(.smooth) {
                    expandedSection.wrappedValue = .fallbackMission
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: fallbackType.iconName)
                        .font(.title2)
                        .foregroundStyle(accent)
                        .frame(width: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(fallbackType == .none ? "Manual Dismiss" : fallbackType.rawValue)
                            .font(.headline)
                            .foregroundStyle(accent)
                        Text(fallbackSummaryText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if fallbackType != .none {
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(accent)
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if fallbackType == .math {
                MathProblemPreviewRow(difficulty: mission.haFallbackMathDifficulty)
            }
        }
    }
    
    // MARK: - Edit Mode
    
    @ViewBuilder
    private var editModeControls: some View {
        switch fallbackType {
        case .shake:
            fallbackShakeSettings
        case .math:
            fallbackMathSettings
        case .balanceBall:
            fallbackBalanceSettings
        case .blockDrop:
            fallbackBlockDropSettings
        case .meteor:
            fallbackMeteorSettings
        case .none:
            fallbackTapSettings
        default:
            EmptyView()
        }
        
    }
    
    // MARK: - Fallback Shake Settings
    
    private var fallbackShakeSettings: some View {
        Group {
            Picker("Mode", selection: $mission.haFallbackShakeMode) {
                ForEach(ShakeMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            
            if mission.haFallbackShakeMode == .duration {
                Stepper("Duration: \(mission.haFallbackShakeDuration)s", value: $mission.haFallbackShakeDuration, in: 1...30)
            } else {
                Stepper("Count: \(mission.haFallbackShakeCount)", value: $mission.haFallbackShakeCount, in: 5...100, step: 5)
            }
            
            Picker("Intensity", selection: $mission.haFallbackShakeIntensity) {
                ForEach(ShakeIntensity.allCases, id: \.self) { intensity in
                    Text(intensity.rawValue).tag(intensity)
                }
            }
        }
    }
    
    // MARK: - Fallback Math Settings
    
    private var fallbackMathSettings: some View {
        Group {
            Stepper("Problems: \(mission.haFallbackMathProblemCount)", value: $mission.haFallbackMathProblemCount, in: 1...10)

            Picker("Difficulty", selection: $mission.haFallbackMathDifficulty) {
                ForEach(MathDifficulty.allCases, id: \.self) { difficulty in
                    Text(difficulty.displayLabel).tag(difficulty)
                }
            }

            MathProblemPreviewRow(difficulty: mission.haFallbackMathDifficulty)
        }
    }

    // MARK: - Fallback Balance Settings

    private var fallbackBalanceSettings: some View {
        Group {
            Picker("Difficulty", selection: $mission.haFallbackBalanceDifficulty) {
                ForEach(BalanceDifficulty.allCases, id: \.self) { difficulty in
                    Text(difficulty.rawValue).tag(difficulty)
                }
            }

            LabeledContent("Hold time", value: "\(Int(mission.haFallbackBalanceDifficulty.holdDuration))s")
        }
    }

    // MARK: - Fallback Bricks Settings

    /// Bricks and Meteor became fallback-eligible in 2026-07; before that these
    /// controls did not exist and the type fell through to `EmptyView`, so
    /// picking either as a backup gave no way to tune it.
    private var fallbackBlockDropSettings: some View {
        Group {
            Picker("Difficulty", selection: $mission.haFallbackBlockDropDifficulty) {
                ForEach(BlockDropDifficulty.allCases, id: \.self) { difficulty in
                    Text(difficulty.rawValue).tag(difficulty)
                }
            }

            LabeledContent("Lines to clear",
                           value: "\(mission.haFallbackBlockDropLinesOverride ?? mission.haFallbackBlockDropDifficulty.linesToClear)")
        }
    }

    // MARK: - Fallback Meteor Settings

    private var fallbackMeteorSettings: some View {
        Group {
            Picker("Difficulty", selection: $mission.haFallbackMeteorDifficulty) {
                ForEach(MeteorDifficulty.allCases, id: \.self) { difficulty in
                    Text(difficulty.rawValue).tag(difficulty)
                }
            }

            LabeledContent("Meteors to destroy",
                           value: "\(mission.haFallbackMeteorTargetsOverride ?? mission.haFallbackMeteorDifficulty.targetsToDestroy)")
        }
    }

    // MARK: - Fallback Tap Settings

    /// The same three knobs the primary Tap mission exposes. A Tap fallback was
    /// previously always a single tap, so "tap 10 times to dismiss" could be set
    /// as a mission but not as a backup.
    private var fallbackTapSettings: some View {
        Group {
            Picker("Dismiss by", selection: $mission.haFallbackTapDismissMode) {
                ForEach(TapDismissMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            if mission.haFallbackTapDismissMode == .hold {
                Stepper("Hold: \(Int(mission.haFallbackTapHoldDuration))s",
                        value: $mission.haFallbackTapHoldDuration, in: 1...10, step: 1)
            } else {
                Stepper("Taps: \(mission.haFallbackTapCount)",
                        value: $mission.haFallbackTapCount, in: 1...50)
            }
        }
    }
}
