//
//  AfterAlarmSectionView.swift
//  HaWake Alarm V2
//
//  The "After Alarm" editor section: a numbered-box grid built on the exact same
//  principles as the Mission grid (`MissionSelectorView`), over the ordered
//  after-alarm pipeline that runs once an alarm is FULLY dismissed. Up to four
//  boxes (notes / verse / weather / open-app) plus an add box while fewer than
//  all four are present.
//
//  This view owns the DATA rules (order, add/remove, appLink-last normalization)
//  and the edit-mode state the grid reports into; `AfterAlarmCardGrid` owns the
//  home-screen physics. Tapping a box reports the target UP to the host editor,
//  which presents the config sheet from its Form root (presenting from a Form row
//  tears the editor sheet down — same rule as the mission slot pop-out).
//

import SwiftUI

struct AfterAlarmSectionView: View {
    /// The ordered after-alarm actions (source of truth, owned by the host editor).
    @Binding var actions: [AfterAlarmAction]
    let settings: DeviceSettings
    /// Reports a tapped box up to the host editor, which presents the config sheet
    /// from its Form root.
    var onEdit: (AfterAlarmEditTarget) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }

    /// Four action types exist — 3-column grid, wrapping onto a second row.
    private let maxSlots = 4

    @State private var editMode = false

    var body: some View {
        Section {
            VStack(spacing: 10) {
                AfterAlarmCardGrid(
                    actions: actions,
                    maxSlots: maxSlots,
                    editMode: editMode,
                    accent: accent,
                    onTapCard: { index in
                        guard index < actions.count else { return }
                        onEdit(.action(actions[index]))
                    },
                    onTapAdd: { onEdit(.add) },
                    onEnterEdit: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { editMode = true }
                    },
                    onExitEdit: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { editMode = false }
                    },
                    onRemove: { removeAction(at: $0) },
                    onReorder: { order in
                        let base = actions
                        let newList = order.compactMap { $0 < base.count ? base[$0] : nil }
                        writeActions(newList)
                    }
                )
                .frame(height: AfterAlarmCardGrid.gridHeight)
            }
            .padding(.vertical, 2)
        } header: {
            // "Done" lives on the header LINE (not a row above the grid) so the
            // collection view never shifts when edit mode begins — same reasoning
            // as the mission grid's header.
            HStack {
                Text("After Alarm")
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
            Text("Runs in order after the alarm is dismissed. Opening another app is always last.")
                .font(.caption2)
        }
    }

    // MARK: - Mutation

    /// Write an ordered action list back through the binding, normalized so
    /// `.appLink` stays last (the backstop behind the grid's move clamp).
    private func writeActions(_ list: [AfterAlarmAction]) {
        let normalized = Alarm.normalizeAfterAlarm(list)
        if actions != normalized { actions = normalized }
    }

    private func removeAction(at index: Int) {
        guard index < actions.count else { return }
        var list = actions
        list.remove(at: index)
        let willBeEmpty = list.isEmpty
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
            writeActions(list)
            if willBeEmpty { editMode = false }
        }
    }
}
