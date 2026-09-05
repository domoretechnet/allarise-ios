//
//  MissionConfigControls.swift
//  HaWake Alarm V2
//
//  Shared per-type mission configuration UI: the type description line, the
//  difficulty/intensity chip row, the detailed customize steppers, and the
//  Tap dismiss-mode controls. Used by the alarm editor's MissionSlotEditorSheet
//  and rendered INLINE by Settings → Alarm Defaults, so the two screens stay
//  identical. All controls edit a Binding<Mission> — the sheet binds its local
//  draft, the defaults page binds a write-through proxy over DeviceSettings.
//

import SwiftUI

enum MissionConfigInfo {
    /// One-to-two line secondary description of a mission type, shown under the
    /// type grids. `slotOne` only changes the Tap phrasing.
    static func description(for type: MissionType, slotOne: Bool = true) -> String? {
        switch type {
        case .none:
            return slotOne
                ? "Dismiss with a tap — no mission required."
                : "A tap step in the sequence — single tap, multi-tap, or hold."
        case .shake:         return "Shake your phone until the meter fills to dismiss."
        case .math:          return "Solve math problems to dismiss."
        case .balanceBall:   return "Tilt the phone to roll a marble into the target zone and hold it there."
        case .blockDrop:     return "Clear lines in a falling bricks puzzle to dismiss."
        case .meteor:        return "Slide the pod and blast the falling meteors to dismiss."
        case .homeAssistant: return "The alarm is dismissed by your Home Assistant automation over MQTT."
        case .alert:         return nil
        }
    }
}

/// A single edge-to-edge row of equal-width difficulty/intensity chips for the
/// mission's type. Picking a difficulty means its stock tuning, so the chips
/// wipe any fine-tune overrides.
struct MissionChipRow: View {
    @Binding var mission: Mission
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            switch mission.type {
            case .shake:
                ForEach(ShakeIntensity.allCases, id: \.self) { intensity in
                    chip(intensity.rawValue, selected: mission.shakeIntensity == intensity) {
                        mission.shakeIntensity = intensity
                    }
                }
            case .math:
                ForEach(MathDifficulty.allCases, id: \.self) { difficulty in
                    chip(difficulty.displayLabel, selected: mission.mathDifficulty == difficulty) {
                        mission.mathDifficulty = difficulty
                    }
                }
            case .balanceBall:
                ForEach(BalanceDifficulty.allCases, id: \.self) { difficulty in
                    chip(difficulty.rawValue, selected: mission.balanceDifficulty == difficulty) {
                        mission.balanceDifficulty = difficulty
                        mission.balanceHoldOverride = nil
                        mission.balanceZoneRadiusOverride = nil
                        mission.balanceZoneDwellOverride = nil
                    }
                }
            case .blockDrop:
                ForEach(BlockDropDifficulty.allCases, id: \.self) { difficulty in
                    chip(difficulty.rawValue, selected: mission.blockDropDifficulty == difficulty) {
                        mission.blockDropDifficulty = difficulty
                        mission.blockDropLinesOverride = nil
                        mission.blockDropIntervalOverride = nil
                        mission.blockDropGarbageRowsOverride = nil
                        mission.blockDropGapWidthOverride = nil
                        mission.blockDropGapsAlignedOverride = nil
                    }
                }
            case .meteor:
                ForEach(MeteorDifficulty.allCases, id: \.self) { difficulty in
                    chip(difficulty.rawValue, selected: mission.meteorDifficulty == difficulty) {
                        mission.meteorDifficulty = difficulty
                        mission.meteorTargetsOverride = nil
                        mission.meteorFireIntervalOverride = nil
                    }
                }
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    /// An equal-width chip that fills its share of the row and centers its label.
    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(selected ? accent : Color.primary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 54)
                .selectableTile(isSelected: selected, accent: accent, cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }
}

/// The detailed per-type customize controls shown under the chip row.
struct MissionCustomizeControls: View {
    @Binding var mission: Mission

    var body: some View {
        switch mission.type {
        case .shake:       shakeControls
        case .math:        mathControls
        case .balanceBall: balanceControls
        case .blockDrop:   blockDropControls
        case .meteor:      meteorControls
        default:           EmptyView()
        }
    }

    private var meteorControls: some View {
        Group {
            Stepper(value: Binding(
                get: { mission.effectiveMeteorTargets },
                set: { mission.meteorTargetsOverride = $0 }
            ), in: 3...40) {
                HStack {
                    Text("Meteors to destroy")
                    Spacer()
                    Text("\(mission.effectiveMeteorTargets)").foregroundStyle(.secondary)
                }
            }
            Stepper(value: Binding(
                get: { mission.effectiveMeteorFireInterval },
                set: { mission.meteorFireIntervalOverride = $0 }
            ), in: 0.25...1.5, step: 0.05) {
                HStack {
                    Text("Fire every")
                    Spacer()
                    Text(String(format: "%.2fs", mission.effectiveMeteorFireInterval)).foregroundStyle(.secondary)
                }
            }
            Text("Slide the pod left and right — it fires on its own. A slower fire rate makes every shot count. Meteors that slip past shatter on the shield; progress never goes backward. Choosing a difficulty resets these to its defaults.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shakeControls: some View {
        Group {
            Picker("Mode", selection: $mission.shakeMode) {
                ForEach(ShakeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if mission.shakeMode == .duration {
                Stepper("Duration: \(mission.shakeDuration)s", value: $mission.shakeDuration, in: 1...30)
            } else {
                Stepper("Count: \(mission.shakeCount)", value: $mission.shakeCount, in: 5...100, step: 5)
            }
        }
    }

    private var mathControls: some View {
        Stepper("Problems: \(mission.mathProblemCount)", value: $mission.mathProblemCount, in: 1...10)
    }

    private var balanceControls: some View {
        Group {
            Stepper(
                value: Binding(
                    get: { mission.effectiveBalanceHoldDuration },
                    set: { mission.balanceHoldOverride = $0 }
                ),
                in: 3...120, step: 1
            ) {
                HStack {
                    Text("Hold time")
                    Spacer()
                    Text("\(Int(mission.effectiveBalanceHoldDuration))s")
                        .foregroundStyle(.secondary)
                }
            }
            Stepper(
                value: Binding(
                    get: { mission.effectiveBalanceZoneRadius },
                    set: { mission.balanceZoneRadiusOverride = $0 }
                ),
                in: 24...60, step: 2
            ) {
                HStack {
                    Text("Target size")
                    Spacer()
                    Text(mission.balanceTargetSizeLabel)
                        .foregroundStyle(.secondary)
                }
            }
            Stepper(
                value: Binding(
                    get: { mission.effectiveBalanceZoneDwell },
                    set: { mission.balanceZoneDwellOverride = $0 }
                ),
                in: 2...10, step: 1
            ) {
                HStack {
                    Text("Target moves every")
                    Spacer()
                    Text("\(Int(mission.effectiveBalanceZoneDwell))s")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Tilt your phone to roll the marble into the target circle and hold it there. The target relocates periodically. Choosing a difficulty resets these to its defaults. Setting the phone down restarts the alarm sound.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var blockDropControls: some View {
        Group {
            Stepper(value: Binding(
                get: { mission.effectiveBlockDropLines },
                set: { mission.blockDropLinesOverride = $0 }
            ), in: 1...12) {
                HStack { Text("Lines to clear"); Spacer()
                    Text("\(mission.effectiveBlockDropLines)").foregroundStyle(.secondary) }
            }
            Stepper(value: Binding(
                get: { mission.effectiveBlockDropInterval },
                set: { mission.blockDropIntervalOverride = $0 }
            ), in: 0.2...1.5, step: 0.05) {
                HStack { Text("Drop every"); Spacer()
                    Text(String(format: "%.2fs", mission.effectiveBlockDropInterval)).foregroundStyle(.secondary) }
            }
            Stepper(value: Binding(
                get: { mission.effectiveBlockDropGarbageRows },
                set: { mission.blockDropGarbageRowsOverride = $0 }
            ), in: 0...8) {
                HStack { Text("Pre-filled rows"); Spacer()
                    Text("\(mission.effectiveBlockDropGarbageRows)").foregroundStyle(.secondary) }
            }
            Stepper(value: Binding(
                get: { mission.effectiveBlockDropGapWidth },
                set: { mission.blockDropGapWidthOverride = $0 }
            ), in: 1...4) {
                HStack { Text("Gap width"); Spacer()
                    Text("\(mission.effectiveBlockDropGapWidth)").foregroundStyle(.secondary) }
            }
            Toggle("Gaps line up", isOn: Binding(
                get: { mission.effectiveBlockDropGapsAligned },
                set: { mission.blockDropGapsAlignedOverride = $0 }
            ))
            Text("Falling bricks stack on a board with gap-filled rows. Slot pieces into the gaps to complete rows. Choosing a difficulty resets these to its defaults.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Dismiss-mode config for a Tap (missionless) slot: Tap/Hold mode picker with
/// either a tap-count stepper or a hold-time stepper. The grace-period group is
/// NOT included — it is alarm-level state the editor sheet appends itself.
struct TapDismissControls: View {
    @Binding var mission: Mission

    var body: some View {
        Picker("Mode", selection: $mission.tapDismissMode) {
            ForEach(TapDismissMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }

        if mission.tapDismissMode == .tap {
            Stepper(value: $mission.tapCount, in: 1...50) {
                HStack {
                    Text("Taps to dismiss")
                    Spacer()
                    Text("\(mission.tapCount)").foregroundStyle(.secondary)
                }
            }
            Text("More taps make accidental dismissal harder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Stepper(value: $mission.tapHoldDuration, in: 1...10, step: 1) {
                HStack {
                    Text("Hold duration")
                    Spacer()
                    Text("\(Int(mission.tapHoldDuration))s").foregroundStyle(.secondary)
                }
            }
            Text("Hold the dismiss button the whole time to turn the alarm off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
