//
//  MissionPreviewView.swift
//  HaWake Alarm V2
//
//  Full-screen "try it out" host for missions. It renders the REAL alarm
//  experience — the actual `ActiveAlarmView` driven by a synthetic in-memory
//  Alarm built from the previewed Mission — running in `previewMode` so every
//  audio / global-state / MQTT side effect is gated off. What the user sees is
//  exactly what a live alarm shows, minus the sound:
//    • Math / Shake / Blocks / Balance → the real mission screen (wallpaper,
//      mission chrome, and the live grace-period countdown ring), just silent.
//    • Tap (.none) → the real pre-mission landing page (wallpaper, WAKE UP /
//      clock hero, snooze chip, and the live dismiss chip).
//  HA fallback previews arrive here as a concrete shake/math/balance mission
//  (the sheet passes `dismissFallbackMission`) and get the same treatment.
//  Completing the mission (or the tap/hold dismiss) exits the preview; a small
//  top-corner X is always available to bail out of a hard mission.
//
//  Presented as a fullScreenCover anchored on each host's Form root (see the
//  stationBrowserMode comment in AlarmEditorView — presenting from a Form row
//  inside the editor sheet tears the sheet down).
//

import SwiftUI

/// Identifiable wrapper so hosts can drive `.fullScreenCover(item:)`.
struct MissionPreviewRequest: Identifiable {
    let id = UUID()
    let mission: Mission
}

extension MissionType {
    /// Types that can be tried in a preview. HA just waits on MQTT and .alert
    /// is internal, so neither makes sense to rehearse.
    var isPreviewable: Bool {
        switch self {
        case .shake, .math, .balanceBall, .blockDrop, .meteor: return true
        case .none, .homeAssistant, .alert: return false
        }
    }
}

struct MissionPreviewView: View {
    let mission: Mission
    let settings: DeviceSettings

    @Environment(\.dismiss) private var dismiss

    /// Synthetic, in-memory alarm built from the previewed mission. Created ONCE
    /// (never re-derived on re-render, never inserted into a SwiftData context) so
    /// the hosted `ActiveAlarmView` keeps a stable identity while its grace timer
    /// runs. Same construction the DEBUG screenshot hosts use.
    @State private var previewAlarm: Alarm

    init(mission: Mission, settings: DeviceSettings) {
        self.mission = mission
        self.settings = settings
        _previewAlarm = State(initialValue: Alarm(label: "Preview", mission: mission))
    }

    var body: some View {
        // The REAL alarm screen, running silently in preview mode. `.none` (Tap)
        // starts on the landing page (its dismiss chip is gated there); every real
        // mission jumps straight into the mission phase, exactly like the DEBUG
        // "start in mission" hosts, so the grace countdown engages on interaction.
        ActiveAlarmView(
            alarm: previewAlarm,
            settings: settings,
            onDismiss: { dismiss() },
            onSnooze: {
                // Snooze is cosmetic in a preview: acknowledge with a light haptic,
                // but NEVER exit — there is no alarm to actually postpone here.
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            },
            debugStartInMission: mission.type != .none,
            previewMode: true
        )
        // Always-available bail-out for hard missions — the previous preview's
        // close-button look, kept as a small top-corner overlay.
        .overlay(alignment: .topTrailing) { closeButton }
        .statusBarHidden(true)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

// MARK: - Shared "Try It Out" row for the mission pickers

/// Form row that launches a mission preview. Kept borderless so it reads as a
/// row action (same style as MathProblemPreviewRow's refresh).
struct MissionPreviewRow: View {
    let accent: Color
    var title: String = "Try It Out"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(accent)
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(accent)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Shared prominent preview button (the pop-out sheets' pinned launcher)

/// The filled accent "Try It Out" button used by the mission slot pop-out,
/// shared so other config sheets (e.g. the notes preview) render the exact same
/// control. Drop it directly in a Form Section — it zeroes its own row insets
/// and clears the row background.
struct ProminentPreviewButton: View {
    let accent: Color
    var title: String = "Try It Out"
    var icon: String = "play.fill"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Plain icon+title HStack that fills the button's content box and
            // centers optically. The `maxWidth: .infinity` frame lives INSIDE
            // the label (so borderedProminent centers the whole row), and the
            // list row insets are zeroed so the Form doesn't add asymmetric
            // leading padding that would drift the label right-of-center.
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.vertical, 7)
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
    }
}

#Preview {
    MissionPreviewView(
        mission: {
            var m = Mission()
            m.type = .blockDrop
            m.blockDropDifficulty = .easy
            return m
        }(),
        settings: DeviceSettings.shared
    )
}
