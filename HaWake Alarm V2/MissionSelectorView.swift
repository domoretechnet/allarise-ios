//
//  MissionSelectorView.swift
//  HaWake Alarm V2
//
//  Lean multi-slot mission row. Five numbered boxes are always shown (slot 1
//  lives in `mission`, slots 2..5 in `extraMissions` — up to four extras).
//  Filled boxes show the mission icon + label; empty boxes are dimmed
//  placeholders. Home Assistant is a slot-1-only type — its fallback mission is
//  chosen inside the Home Assistant slot's editor sheet, not as a separate box.
//  Tapping any box does NOT edit inline — it reports the target up to the host
//  editor, which owns the pop-out sheet anchored on its Form root (presenting a
//  sheet from a Form row tears the editor sheet down; see the stationBrowserMode
//  comment in AlarmEditorView).
//
//  The grid itself is `MissionCardGrid`, a UICollectionView wrapper: reordering
//  uses the SYSTEM's interactive-movement support (true home-screen physics —
//  lift, live reflow, drop settle) with CoreAnimation wobble in edit mode. This
//  view owns the DATA rules: slot packing, HA-first normalization, removal
//  compaction, and the edit-mode state the grid reports into.
//

import SwiftUI

struct MissionSelectorView: View {
    /// Slot 1 — the original binding, plumbing unchanged.
    @Binding var mission: Mission
    /// Slots 2..5 (0-based here). Empty = single-mission alarm.
    @Binding var extraMissions: [Mission]
    let settings: DeviceSettings
    let mqttEnabled: Bool
    /// Reports a tapped box up to the host editor, which presents the pop-out
    /// sheet from its Form root.
    var onEditSlot: (MissionSlotTarget) -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// The app-wide theme accent for the current appearance.
    private var accent: Color { settings.appAccent(for: colorScheme) }

    /// Maximum missions in one alarm (slot 1 + up to four extras).
    private let maxSlots = 5

    @State private var editMode = false

    // MARK: - Slot model

    /// Number of configured mission slots (slot 1 + extras). A Tap (`.none`) slot
    /// is a real, configured slot — it only reads as "empty" when the whole alarm
    /// is the truly-empty default: slot 1 a plain single-tap that the user never
    /// explicitly chose (see `tapExplicitlyChosen`), with no extras.
    private var filledCount: Int {
        if mission.type == .none && !mission.tapDismissIsMission && !mission.tapExplicitlyChosen && extraMissions.isEmpty {
            return 0
        }
        return 1 + extraMissions.count
    }

    /// The filled cards, in slot order, for the grid.
    private var filledMissions: [Mission] {
        filledCount == 0 ? [] : [mission] + extraMissions
    }

    // MARK: - Body

    var body: some View {
        Section {
            VStack(spacing: 10) {
                MissionCardGrid(
                    missions: filledMissions,
                    maxSlots: maxSlots,
                    editMode: editMode,
                    accent: accent,
                    addTargetsSlotOne: filledCount == 0,
                    onTapCard: { onEditSlot(.slot($0)) },
                    onTapAdd: { onEditSlot(filledCount == 0 ? .slot(0) : .add) },
                    onEnterEdit: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { editMode = true }
                    },
                    onExitEdit: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { editMode = false }
                    },
                    onRemove: { removeMission(at: $0) },
                    onReorder: { order in
                        let base = filledMissions
                        let newList = order.compactMap { $0 < base.count ? base[$0] : nil }
                        writeMissions(newList)
                    }
                )
                .frame(height: MissionCardGrid.gridHeight)
            }
            .padding(.vertical, 2)
        } header: {
            // Done lives in the header LINE (not a row above the grid): inserting a
            // row when edit mode begins shifted the collection view down mid-gesture,
            // making the freshly-lifted card appear to jump upward. The header keeps
            // one line height in both modes, so the grid never moves.
            HStack {
                Text("Mission")
                Spacer()
                if editMode {
                    Button("Done") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { editMode = false }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .textCase(nil)
                }
            }
        } footer: {
            Text("Missions are optional — with no mission, just tap to dismiss. Tap a numbered box to add up to \(maxSlots) missions; they run in order. Touch and hold a mission to rearrange or remove.")
                .font(.caption2)
        }
    }

    // MARK: - Slot mutation

    /// Write an ordered mission list back through the bindings: first survivor
    /// becomes slot 1, the rest become the extras. Same semantics as the host's
    /// `compactMissions()`, kept equality-guarded to avoid redundant writes.
    ///
    /// Home Assistant is a slot-1-only type. Removing slot 1 promotes the next
    /// mission into slot 1, which can strand a (legacy) HA mission at index > 0 —
    /// so normalize HA to the front before writing. This is the final backstop
    /// behind the grid's move clamp too.
    private func writeMissions(_ all: [Mission]) {
        let normalized = normalizedHAFirst(all)
        if normalized.isEmpty {
            // Reset slot 1 to a pristine default. Compare against Mission() (not just
            // `type != .none`) so an explicitly-chosen Tap card — type .none but with
            // tapExplicitlyChosen set — is cleared back to the add-box on Remove.
            if mission != Mission() { mission = Mission() }
            if !extraMissions.isEmpty { extraMissions = [] }
        } else {
            var rest = normalized
            let first = rest.removeFirst()
            if mission != first { mission = first }
            if extraMissions != rest { extraMissions = rest }
        }
    }

    /// Enforce the slot-1-only rule for Home Assistant: if an HA mission is present
    /// but not first, move it to the front. New alarms can only ever place HA in
    /// slot 1, so this only fires for legacy data or a removal that promoted a
    /// later HA mission.
    private func normalizedHAFirst(_ all: [Mission]) -> [Mission] {
        guard let i = all.firstIndex(where: { $0.type == .homeAssistant }), i != 0 else { return all }
        var result = all
        let ha = result.remove(at: i)
        result.insert(ha, at: 0)
        return result
    }

    /// Clear a filled slot and compact later missions left into the gap.
    /// Removing the last mission auto-exits edit mode.
    private func removeMission(at index: Int) {
        var all = filledMissions
        guard index < all.count else { return }
        all.remove(at: index)
        let willBeEmpty = all.isEmpty
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
            writeMissions(all)
            if willBeEmpty { editMode = false }
        }
    }
}

#Preview {
    Form {
        MissionSelectorView(
            mission: .constant(Mission(type: .shake)),
            extraMissions: .constant([]),
            settings: DeviceSettings.shared,
            mqttEnabled: true,
            onEditSlot: { _ in }
        )
    }
}
