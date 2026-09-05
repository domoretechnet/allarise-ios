//
//  AlarmDefaultsView.swift
//  HaWake Alarm V2
//
//  Default alarm settings page — mission, snooze, and skip alarm.
//

import SwiftUI

struct AlarmDefaultsView: View {
    @Bindable var settings: DeviceSettings

    /// Mission "Try It Out" preview, anchored on the Form root (presenting
    /// from a Form row can tear down enclosing presentations — see
    /// AlarmEditorView's stationBrowserMode comment).
    @State private var missionPreview: MissionPreviewRequest?

    var body: some View {
        Form {
            SettingsMissionSelectorView(
                settings: settings,
                onPreview: { missionPreview = MissionPreviewRequest(mission: $0) }
            )

            SettingsSnoozeSectionView(settings: settings)

            SettingsSkipAlarmSectionView(settings: settings)
        }
        .navigationTitle("Alarm Defaults")
        .navigationBarTitleDisplayMode(.large)
        // Breathing room between the large title and the first section header.
        .contentMargins(.top, 16, for: .scrollContent)
        .fullScreenCover(item: $missionPreview) { request in
            MissionPreviewView(mission: request.mission, settings: settings)
        }
    }

}

#Preview {
    NavigationStack {
        AlarmDefaultsView(settings: DeviceSettings.shared)
    }
}
