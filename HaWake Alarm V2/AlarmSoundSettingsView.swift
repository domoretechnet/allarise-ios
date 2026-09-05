import SwiftUI

struct AlarmSoundSettingsView: View {
    @Bindable var settings: DeviceSettings
    /// Station browser presentation, anchored on the List root (a stable root)
    /// rather than the picker's Form-row context.
    @State private var stationBrowserMode: StationBrowserMode?
    /// Custom-tone screen presentation, anchored on the List root for the same
    /// reason as the station browser above.
    @State private var customToneMode: CustomToneMode?

    var body: some View {
        List {
            AlarmSoundPicker(
                selectedSoundID: $settings.defaultAlarmSound,
                alarmVolumeLevel: settings.alarmVolumeLevel,
                globalVolumeLevel: $settings.alarmVolumeLevel,
                sectionTitle: "Default Sound",
                globalVibrate: $settings.alarmVibrationEnabled,
                globalFadeIn: $settings.alarmFadeInEnabled,
                globalFadeInDuration: $settings.alarmFadeInDuration,
                radioStation: $settings.defaultRadioStation,
                stationBrowserMode: $stationBrowserMode,
                customToneMode: $customToneMode
            )
        }
        .navigationTitle("Sound & Volume")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $stationBrowserMode) { mode in
            NavigationStack {
                RadioBrowserView(
                    settings: DeviceSettings.shared,
                    pickMode: true,
                    startInFavoritesEdit: mode == .edit,
                    onPick: { settings.defaultRadioStation = $0 }
                )
            }
        }
        .customAlarmToneScreen(mode: $customToneMode)
    }
}
