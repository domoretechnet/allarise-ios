//
//  PersistenceComparisonTable.swift
//  HaWake Alarm V2
//
//  The App Persistence tradeoff, as a side-by-side grid instead of prose.
//
//  Replaces two stacked Pros/Cons bullet lists that between them ran to seven
//  full sentences — a wall of text in a narrow column. It also fixed a real gap
//  rather than just a cosmetic one: those lists only described the mode you were
//  ALREADY on, so comparing them meant toggling persistence back and forth and
//  reading twice. Every row here states all three answers at once.
//
//  The claims are carried over verbatim in meaning from that copy; only the
//  presentation changed. Battery stays a worded row because it's a tradeoff in
//  degree, not a capability you either have or don't.
//
//  Dynamic's column is mostly a third answer that neither of the others could
//  give: "yes, while the app is awake". It is a real answer, not a hedge — the
//  app is awake exactly when it matters (charging, or inside the pre-alarm
//  window) — so it gets its own glyph and a legend rather than being rounded to
//  a check or a cross.
//

import SwiftUI

struct PersistenceComparisonTable: View {
    /// The user's current mode. Its column is emphasised so the table doubles as
    /// "which one am I on?", and the others dim back.
    let mode: AppPersistenceMode

    /// Bumped by the host every time the user switches mode. The table opens
    /// itself in response, so changing persistence shows you what you just
    /// changed instead of leaving the explanation collapsed behind a chevron.
    var openTrigger: Int = 0

    /// Transient — the breakdown starts hidden on every visit. Nothing about it
    /// is worth persisting. The launch-arg escape hatch exists for the
    /// screenshot harnesses (same family as -settingsDebug), which cannot tap.
    @State private var isExpanded = Self.startsExpanded

    private static var startsExpanded: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-persistenceTableExpanded")
        #else
        false
        #endif
    }

    @Environment(\.colorScheme) private var colorScheme
    /// The conditional glyph follows the theme accent rather than adding a
    /// third traffic-light color: green and red already carry yes/no, and the
    /// dotted outline — not a color — is what says "partial".
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }

    /// What a cell says.
    private enum Cell {
        case yes
        case no
        /// Dynamic's answer: available, but only while the app is resident.
        case conditional
        case text(String)
        /// Battery-use cells: a colored glyph instead of "Higher"/"Lower" text.
        /// Red low battery = drains more; green fuller battery = drains less.
        /// Dynamic is green like Off — its drain is closer to Off than to On —
        /// just not as full.
        case batteryHigh
        case batteryMedium
        case batteryLow
    }

    private struct Row: Identifiable {
        let label: String
        let on: Cell
        let dynamic: Cell
        let off: Cell
        var id: String { label }
    }

    /// Labels are kept SHORT on purpose — at full-sentence length every row
    /// wrapped to two or three lines and the grid became the wall of text it was
    /// meant to replace. The legend and footnote below carry any nuance they lose.
    private static let rows: [Row] = [
        Row(label: "Background HA commands", on: .yes, dynamic: .conditional, off: .no),
        Row(label: "Radio station alarms", on: .yes, dynamic: .conditional, off: .no),
        Row(label: "Custom volume & fade-in", on: .yes, dynamic: .conditional, off: .no),
        // "Alarm vibration control", not "App vibration control": what's at
        // stake is who controls the ALARM's vibration — the app when persistence
        // is on, iOS/AlarmKit when it's off.
        Row(label: "Alarm vibration control", on: .yes, dynamic: .conditional, off: .no),
        Row(label: "Full volume when closed", on: .yes, dynamic: .conditional, off: .no),
        Row(label: "CarPlay audio", on: .yes, dynamic: .conditional, off: .no),
        Row(label: "Battery use", on: .batteryHigh, dynamic: .batteryMedium, off: .batteryLow),
    ]

    /// Each mode column is this wide, so the labels get everything else. Three
    /// columns now share what two used to, so the headers scale rather than
    /// widen — "Dynamic" is the only one that needs it.
    private let columnWidth: CGFloat = 46

    /// Plain HStacks with fixed-width cells rather than a `Grid`: Grid kept
    /// collapsing the header row's height to nothing, which clipped the On/Off
    /// labels away entirely. Fixed widths align the columns just as well and
    /// leave no sizing behaviour to be surprised by.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            disclosureRow

            if isExpanded {
                table
                    .padding(.top, 10)
            }
        }
        // Opens (never closes) when the host reports a mode change — collapsing
        // it out from under someone who just expanded it would be worse than
        // leaving it open.
        .onChange(of: openTrigger) { _, _ in
            guard !isExpanded else { return }
            withAnimation(.smooth(duration: 0.25)) { isExpanded = true }
        }
        // No padding of its own — the host places this inside the same VStack as
        // the mode tiles and owns the spacing around it.
    }

    /// Collapsed by default: most people pick a mode from the two tiles above and
    /// never need the breakdown, so it shouldn't cost them a screen of scrolling.
    private var disclosureRow: some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text("What's App Persistence?")
                    .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                Spacer(minLength: 0)
            }
            // Same foreground as every other label in this card, so it tracks
            // light/dark like they do. Accent-tinting it made one line of body
            // text shout louder than the two mode tiles it belongs under.
            .foregroundStyle(.primary)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What's App Persistence?")
        .accessibilityHint(isExpanded ? "Hides the comparison" : "Shows a comparison of all three modes")
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                columnHeader("On", isActive: mode == .on)
                columnHeader("Dynamic", isActive: mode == .dynamic)
                columnHeader("Off", isActive: mode == .off)
            }
            .padding(.bottom, 2)

            ForEach(Self.rows) { row in
                HStack(spacing: 4) {
                    Text(row.label)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    cell(row.on, isActive: mode == .on)
                    cell(row.dynamic, isActive: mode == .dynamic)
                    cell(row.off, isActive: mode == .off)
                }
                .padding(.vertical, 5)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: row))
            }

            // The legend earns its line: the dotted glyph is the only cell
            // state whose meaning isn't self-evident, and it's most of a column.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: Self.conditionalSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                Text("= while the app is awake (charging or near an alarm)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 14)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Dotted circle means while the app is awake — charging, or near an alarm.")

            // Dynamic gets its own note: arming the Alarm & Command Widget
            // keeps the app awake (the conditional column becomes a check) the
            // same way a near alarm does — so an armed house never loses inbound
            // Home Assistant commands. Toggleable in Settings ▸ Reliability.
            if mode == .dynamic {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                    Text("Arming the Alarm & Command Widget also keeps the app awake, so Home Assistant can deliver alerts and notify-service messages while armed. Turn this off under Reliability.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
            }

            // Off is the one mode where the alarm's own behavior changes, so
            // it gets a second footnote — same icon+caption shape as the
            // legend above, so the two read as one family. Expanded-only, like
            // everything else in the breakdown: switching to Off auto-opens
            // the table, which is what surfaces this.
            if mode == .off {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "bell.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                    Text("Alarms fire through Apple's AlarmKit at your ringtone volume.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Pieces

    private func columnHeader(_ title: String, isActive: Bool) -> some View {
        // Deliberately NOT the accent color: full-strength label color with a
        // soft glow on the active column, dimmed on the other, so the headers
        // read as labels rather than more accent chrome.
        //
        // `.primary`, not `.white` — hard-coded white is the label color of dark
        // mode only, and rendered these headers invisible on the light card.
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary.opacity(isActive ? 1 : 0.5))
            .shadow(color: .white.opacity(isActive ? 0.7 : 0), radius: 4)
            // "Dynamic" is wider than the column at default size. Scaling it is
            // preferable to widening every column and squeezing the labels, or
            // to abbreviating a word the slider spells out in full two rows up.
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: columnWidth, alignment: .center)
    }

    /// A dotted outline, because the capability itself is: present some of the
    /// time. Deliberately not a filled shape or a third traffic-light color —
    /// the incompleteness of the stroke is the message.
    private static let conditionalSymbol = "circle.dotted"

    @ViewBuilder
    private func cell(_ value: Cell, isActive: Bool) -> some View {
        Group {
            switch value {
            case .yes:
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
            case .no:
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            case .conditional:
                Image(systemName: Self.conditionalSymbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(accent)
            case .text(let string):
                Text(string)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            // Same font as the check/x glyphs, so every icon row shares one
            // baseline and the fixed-width cell frame keeps the columns true.
            case .batteryHigh:
                Image(systemName: "battery.25")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            case .batteryMedium:
                Image(systemName: "battery.75")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
            case .batteryLow:
                Image(systemName: "battery.100")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        // The column you're not on stays legible but recedes, so the mode in
        // force reads first.
        .opacity(isActive ? 1 : 0.3)
        .frame(width: columnWidth, alignment: .center)
    }

    /// "Radio station alarms. On: yes. Dynamic: … Off: no." — VoiceOver can't
    /// see a grid's column headers, so each row has to name them.
    private func accessibilityLabel(for row: Row) -> String {
        "\(row.label). On: \(spoken(row.on)). Dynamic: \(spoken(row.dynamic)). Off: \(spoken(row.off))."
    }

    private func spoken(_ value: Cell) -> String {
        switch value {
        case .yes:              return "yes"
        case .no:               return "no"
        case .conditional:      return "only while the app is awake"
        case .text(let string): return string
        case .batteryHigh:      return "higher battery use"
        case .batteryMedium:    return "moderate battery use"
        case .batteryLow:       return "lower battery use"
        }
    }
}

#if DEBUG
#Preview {
    List {
        ForEach(AppPersistenceMode.allCases) { mode in
            Section {
                PersistenceComparisonTable(mode: mode)
            } header: {
                Text("Persistence \(mode.displayName)")
            }
        }
    }
}
#endif
