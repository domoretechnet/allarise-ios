//
//  AppLinkPreviewView.swift
//  HaWake Alarm V2
//
//  Full-screen "try it out" host for the After-Alarm **Open App** step, built on
//  the same bones as `MissionPreviewView`: the REAL `ActiveAlarmView` driven by a
//  synthetic in-memory Alarm, running in `previewMode` so audio / global-state /
//  MQTT side effects stay gated off.
//
//  The rehearsed screen is the pre-mission LANDING page (a `.none` Tap mission),
//  because the Open App step has no screen of its own — what the user needs to
//  rehearse is the button that triggers it. The one deliberate difference from a
//  silent preview: the Dismiss and Snooze chips REALLY open their assigned links
//  (`dismissURI` / `snoozeURI`), so the user can confirm the shortcut/app they
//  typed actually launches. Firing a link leaves Allarise, so the preview closes
//  itself on the way out; an empty link just closes the preview.
//
//  Presented as a fullScreenCover anchored on the config sheet's root (see the
//  stationBrowserMode comment in AlarmEditorView — presenting from a Form row
//  inside the editor sheet tears the sheet down).
//

import SwiftUI
import UIKit

struct AppLinkPreviewView: View {
    /// The link the Dismiss chip should open (the editor's live draft).
    let dismissURI: String
    /// The link the Snooze chip should open (the editor's live draft).
    let snoozeURI: String
    let settings: DeviceSettings

    @Environment(\.dismiss) private var dismiss

    /// Synthetic, in-memory alarm for the landing page. Created ONCE (never
    /// re-derived on re-render, never inserted into a SwiftData context) so the
    /// hosted `ActiveAlarmView` keeps a stable identity — same construction
    /// `MissionPreviewView` uses.
    @State private var previewAlarm = Alarm(label: "Preview", mission: Mission())

    var body: some View {
        // The real alarm landing page, silent: WAKE UP / clock hero, wallpaper,
        // snooze chip and the live dismiss chip. `debugStartInMission` stays false
        // so it starts (and stays) on the landing page — a `.none` Tap mission has
        // no mission phase to jump into.
        ActiveAlarmView(
            alarm: previewAlarm,
            settings: settings,
            onDismiss: { fire(dismissURI) },
            onSnooze: { fire(snoozeURI) },
            previewMode: true
        )
        .overlay(alignment: .topTrailing) { closeButton }
        .statusBarHidden(true)
    }

    /// Open the link and close the preview. Mirrors
    /// `LocalNotificationScheduler.openAppLink`: trim, require a parseable URL,
    /// and hand it to the system. An empty/invalid link opens nothing — the
    /// preview still closes, so the chip always feels like it did something.
    private func fire(_ uriString: String) {
        let trimmed = uriString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let url = URL(string: trimmed) {
            AppLogger.shared.log("Preview opening app link: \(trimmed)", category: .alarm)
            UIApplication.shared.open(url)
        }
        dismiss()
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
