//
//  NotesAfterAlarmView.swift
//  HaWake Alarm V2
//
//  The full-page Notes step of the after-alarm pipeline, ported from V1's
//  alarm-screen notes widget. Once the alarm is fully dismissed this page shows
//  the alarm's notes as a full-screen read (no clock, no alarm chrome) plus up
//  to four square command buttons — the same 48×48 glass squares V1 rendered on
//  the alarm screen — each of which publishes its command's name to
//  `{prefix}/{device}/sensor/arm_custom_command` exactly like the home-screen
//  command widget.
//
//  Chrome mirrors `VerseOfDayCardView`: home wallpaper (when the host passes
//  one) or an accent-tinted generated gradient, a bottom legibility scrim, and
//  the same accent "Continue" affordance that advances the flow.
//

import SwiftUI
import UIKit

struct NotesAfterAlarmView: View {
    /// The alarm's notes text ("" = commands-only page).
    let notes: String
    /// Resolved command buttons, in slot order (may be empty = notes-only page).
    let commands: [MQTTCommand]
    /// Source alarm label, shown as a small caption under the "Notes" heading so
    /// the user can tell which alarm a page came from. Set only when a slept-through
    /// stack merges pages from more than one alarm; nil (the default) for a single
    /// alarm's flow, which renders exactly as before.
    var attribution: String? = nil
    /// Wallpaper handed over by the flow host (same image the weather card
    /// uses). nil → generated accent gradient.
    let wallpaper: UIImage?
    var onContinue: () -> Void = {}
    /// Non-interactive preview: renders the real chrome but suppresses every
    /// side effect (no MQTT publish, no haptics, no confirm alert). The config
    /// sheet drives this so the live preview mirrors the shipped page exactly.
    /// Hit-testing is disabled by the host; this guards the side effects too.
    var previewMode: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    /// Command briefly showing the green "fired" checkmark.
    @State private var executedCommandID: UUID?
    /// Confirm-before-run support (settings.confirmCommandsEnabled).
    @State private var pendingCommand: MQTTCommand?
    @State private var showConfirmAlert = false

    private var settings: DeviceSettings { DeviceSettings.shared }
    private var accent: Color { settings.appAccent(for: colorScheme) }

    private var trimmedNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasAttribution: Bool {
        !(attribution?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var body: some View {
        ZStack {
            // Background + scrim bleed to every edge; the content layer respects
            // the safe area so text/controls clear the Dynamic Island and home
            // indicator without a hardcoded inset. Shared with the editor
            // (`NotesAfterAlarmEditorView`) so both paint the same page.
            NotesPageBackdrop(wallpaper: wallpaper, accent: accent)
            content
        }
        .alert("Confirm Command", isPresented: $showConfirmAlert, presenting: pendingCommand) { command in
            Button("Run") { execute(command) }
            Button("Cancel", role: .cancel) { pendingCommand = nil }
        } message: { command in
            Text("Run \"\(command.name)\"?")
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            notesCard
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 12)

            bottomControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Header + notes on the shared opaque card — the same surface the MQTT alert
    /// screen uses. The page used to lay white text straight onto the wallpaper,
    /// which forced the backdrop's scrim so dark the photo turned to mud. The card
    /// carries legibility now, so the wallpaper can stay bright around it.
    ///
    /// The title sits INSIDE the card: it's the card's heading, and floating it
    /// above on the wallpaper made it read as page chrome rather than as the
    /// notes' own title.
    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotesPageHeader(accent: accent, titleColor: .primary)
                .padding(.bottom, hasAttribution ? 4 : (trimmedNotes.isEmpty ? 0 : 14))

            // Per-page attribution: which slept-through alarm this note came from.
            // Absent for a single alarm's flow (the common case), so nothing here
            // changes the page unless a stack merged pages from several alarms.
            if let attribution, hasAttribution {
                Text("From \(attribution)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, trimmedNotes.isEmpty ? 0 : 14)
            }

            // Long notes still scroll; they just never render past the bottom of
            // their own area, so they can't run under the command row.
            if !trimmedNotes.isEmpty {
                ScrollView {
                    Text(notes)
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .lineSpacing(5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .themedCard(accent: accent)
    }

    /// Command row + Continue, pinned at the bottom so they never scroll away.
    /// No dark backing: the notes now live on a card, so this block doesn't need
    /// a scrim to separate it from the text above.
    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !commands.isEmpty {
                commandRow
                    .padding(.bottom, 16)
            }
            continueButton
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    /// Screen edge to card edge — 16, the same inset the alert and Home
    /// Assistant cards use. Was 22, left over from when this page was full-bleed
    /// text with no card to align to.
    private let horizontalPadding: CGFloat = 16

    // MARK: - Command buttons (V1's square alarm-screen buttons)

    /// Four equal-width columns, always — the same geometry the editor's grid
    /// uses, so a command sits at the same x-position on both. Filling only the
    /// first N leaves the trailing columns empty rather than re-centring, which
    /// is what keeps the editor an honest preview of this page.
    private var commandRow: some View {
        HStack(spacing: 0) {
            ForEach(0..<NotesAfterAlarmView.slotCount, id: \.self) { slot in
                if slot < commands.count {
                    commandButton(commands[slot])
                        .frame(maxWidth: .infinity)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: 0)
                }
            }
        }
        .frame(height: NotesCommandSquare.totalHeight)
    }

    /// The Notes page has always had exactly four command slots.
    static let slotCount = 4

    private func commandButton(_ command: MQTTCommand) -> some View {
        let isExecuted = executedCommandID == command.id
        return NotesCommandSquare(
            systemImage: isExecuted ? "checkmark" : command.icon,
            tint: isExecuted ? .green : command.iconColor,
            glassTint: command.iconColor,
            label: command.displayName,
            accessibilityLabel: "\(command.displayName), \(command.sourceKind.label)",
            action: { request(command) }
        )
    }

    private var continueButton: some View {
        Button(action: onContinue) {
            PrimaryActionLabel(title: "Continue", fill: accent)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Command execution

    /// Gate execution behind the optional confirm alert, matching the
    /// home-screen widget's `confirmCommandsEnabled` behavior.
    private func request(_ command: MQTTCommand) {
        // Preview renders the buttons but must never fire (belt-and-suspenders
        // with the host's `.allowsHitTesting(false)`).
        guard !previewMode else { return }
        if settings.confirmCommandsEnabled {
            pendingCommand = command
            showConfirmAlert = true
        } else {
            execute(command)
        }
    }

    /// Same execution path as ArmButtonView: publish the command name as the
    /// custom-command sensor value, apply its arm action, flash a green check.
    private func execute(_ command: MQTTCommand) {
        pendingCommand = nil
        guard HAIntegrationRouter.shared.isConnected else { return }

        Analytics.shared.log(.commandFired(kind: command.sourceKind, surface: .notesButton))
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        if !command.name.isEmpty {
            HAIntegrationRouter.shared.publishArmCustomCommand(command.name, settings: settings)
            AppLogger.shared.log("Notes page command fired: '\(command.name)'", category: .mqtt)
        }

        if settings.hassWidgetAlarmEnabled {
            switch command.armAction {
            case .none: break
            case .arm: HAIntegrationRouter.shared.requestArmStateChange(true, settings: settings)
            case .disarm: HAIntegrationRouter.shared.requestArmStateChange(false, settings: settings)
            case .toggle:
                // V1's alarm-screen button treated toggle as arm (the page has
                // no live armed-state subscription) — keep that behavior.
                HAIntegrationRouter.shared.requestArmStateChange(true, settings: settings)
            }
        }

        withAnimation { executedCommandID = command.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                if executedCommandID == command.id { executedCommandID = nil }
            }
        }
    }
}

// MARK: - Shared Notes page chrome
//
// Extracted so `NotesAfterAlarmEditorView` renders the SAME page the runtime
// does. Rendering only — no execution lives here, so the editor can reuse the
// look without inheriting any side effect.

/// Wallpaper (or the generated accent gradient) plus the full-height legibility
/// scrim, both bleeding past every edge — including the keyboard's safe area, so
/// the background never jumps when the keyboard animates in.
struct NotesPageBackdrop: View {
    let wallpaper: UIImage?
    let accent: Color

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                if let wallpaper {
                    Image(uiImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    // Generated gradient — theme-accent-tinted, same recipe as
                    // the verse card's no-image fallback.
                    LinearGradient(
                        colors: [
                            accent.opacity(0.85),
                            accent.opacity(0.35),
                            Color.black.opacity(0.9),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .ignoresSafeArea()

            // A LIGHT scrim. It used to run 0.55/0.45/0.8 because the notes text
            // sat directly on the wallpaper and needed the photo dimmed into near
            // black to stay legible. The text lives on an opaque card now, so the
            // scrim only has to serve the command labels and the wallpaper can
            // keep its color.
            LinearGradient(
                colors: [
                    Color.black.opacity(0.30),
                    Color.black.opacity(0.20),
                    Color.black.opacity(0.45),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

/// An accent glyph + title, as used for "Notes" at the top of the page. Also the
/// editor's "Command Buttons" section label, so the two headings on that screen
/// read as the same kind of thing instead of a title and a small-caps caption.
struct NotesPageHeader: View {
    let accent: Color
    var title: String = "Notes"
    var icon: String = "note.text"
    /// `.white` for the editor, which still draws its headings straight onto the
    /// dark backdrop. The runtime page passes `.primary` because its heading now
    /// sits on the opaque card with the notes.
    var titleColor: Color = .white

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(accent)
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(titleColor)
        }
    }
}

/// The glass command square plus its name. The caller owns the action, so the
/// runtime page publishes and the editor's copy stays inert.
///
/// SIZING IS SHARED with `CommandSlotGrid` (the editor's grid) on purpose: the
/// editor promises to look like the page it will become, so a square must be the
/// same size and sit at the same x-position in both.
struct NotesCommandSquare: View {
    let systemImage: String
    let tint: Color
    /// Glass tint (kept separate so a transient state — e.g. the green "fired"
    /// checkmark — doesn't restyle the square itself).
    var glassTint: Color
    /// Tiny corner source marker; editor-only.
    var sourceGlyph: String? = nil
    /// The command's name, under the square. One line, truncated — a long name
    /// loses its tail rather than reflowing and shoving the row taller.
    var label: String? = nil
    var accessibilityLabel: String? = nil
    let action: () -> Void

    /// The shared square edge.
    static let side: CGFloat = 64
    /// Height always reserved for the name, so labelled and unlabelled squares
    /// occupy identical space and a mixed row still aligns.
    static let labelHeight: CGFloat = 16
    static let labelSpacing: CGFloat = 6
    /// Square + name. What both the grid and the runtime row size themselves to.
    static var totalHeight: CGFloat { side + labelSpacing + labelHeight }

    var body: some View {
        Button(action: action) {
            NotesCommandSquareContent(
                systemImage: systemImage,
                tint: tint,
                glassTint: glassTint,
                sourceGlyph: sourceGlyph,
                label: label
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? "")
    }
}

/// The square's VISUALS, with no Button around them. Split out so the editor's
/// UIKit grid (which owns its own gestures) renders the exact same thing.
struct NotesCommandSquareContent: View {
    let systemImage: String
    let tint: Color
    var glassTint: Color
    var sourceGlyph: String? = nil
    var label: String? = nil
    /// Suppresses the source marker while the grid is in jiggle mode.
    var hidesSourceGlyph: Bool = false

    var body: some View {
        VStack(spacing: NotesCommandSquare.labelSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: NotesCommandSquare.side, height: NotesCommandSquare.side)
                .glassEffect(.regular.tint(glassTint.opacity(0.3)), in: .rect(cornerRadius: 16))
                .overlay(alignment: .bottomTrailing) {
                    if let sourceGlyph, !hidesSourceGlyph {
                        Image(systemName: sourceGlyph)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .offset(x: 3, y: 3)
                    }
                }

            // A space rather than a conditional: the row keeps its height whether
            // or not this particular square has a name.
            Text(label ?? " ")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: NotesCommandSquare.side, height: NotesCommandSquare.labelHeight)
        }
    }
}

#if DEBUG
#Preview {
    NotesAfterAlarmView(
        notes: "Take the trash out before 8.\n\nDentist at 2:30 — leave by 2.\nGrab the dry cleaning on the way home.",
        commands: [
            MQTTCommand(name: "Coffee", icon: "cup.and.saucer.fill", iconColorRed: 0.64, iconColorGreen: 0.52, iconColorBlue: 0.37),
            MQTTCommand(name: "Lights", icon: "lightbulb.fill", iconColorRed: 1.0, iconColorGreen: 0.84, iconColorBlue: 0.04),
        ],
        wallpaper: nil
    )
}
#endif
