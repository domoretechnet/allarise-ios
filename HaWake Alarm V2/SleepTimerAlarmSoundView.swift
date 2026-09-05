//
//  SleepTimerAlarmSoundView.swift
//  HaWake Alarm V2
//
//  Full sound screen for the Kids Sleep bedtime alarm (al-5a94) — the SAME
//  AlarmSoundPicker section a normal alarm editor shows (tone browser, custom
//  tones, wake-up radio, per-alarm volume / vibrate / fade-in, the Apple Watch
//  haptic note), hosted on its own screen because the section needs a Form
//  root and host-anchored fullScreenCovers. The create page presents this as a
//  sheet and owns all the state; this view only edits the bindings.
//

import SwiftUI

struct SleepTimerAlarmSoundView: View {
    let settings: DeviceSettings
    @Binding var soundID: String
    @Binding var customVolume: Double?
    @Binding var customVibrate: Bool?
    @Binding var customFadeIn: Bool?
    @Binding var customFadeInDuration: Int?
    @Binding var radioStation: RadioStation?

    @Environment(\.dismiss) private var dismiss
    // Presentation state for the pickers' pop-outs, anchored HERE on the Form
    // root — presenting from the picker's own Form-row context tears the sheet
    // down (same rule as AlarmEditorView / SleepSoundSetupView).
    @State private var stationBrowserMode: StationBrowserMode?
    @State private var customToneMode: CustomToneMode?
    // The sound section has this screen to itself, so it starts expanded.
    @State private var expandedSection: AlarmEditorSection? = .sound

    var body: some View {
        NavigationStack {
            Form {
                AlarmSoundPicker(
                    selectedSoundID: $soundID,
                    alarmVolumeLevel: settings.alarmVolumeLevel,
                    customVolumeLevel: $customVolume,
                    customVibrate: $customVibrate,
                    globalVibrateDefault: settings.alarmVibrationEnabled,
                    customFadeIn: $customFadeIn,
                    customFadeInDuration: $customFadeInDuration,
                    globalFadeInDefault: settings.alarmFadeInEnabled,
                    globalFadeInDurationDefault: settings.alarmFadeInDuration,
                    radioStation: $radioStation,
                    expandedSection: $expandedSection,
                    stationBrowserMode: $stationBrowserMode,
                    customToneMode: $customToneMode
                )
            }
            .navigationTitle("Bedtime Alarm Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(item: $stationBrowserMode) { mode in
                NavigationStack {
                    RadioBrowserView(
                        settings: settings,
                        pickMode: true,
                        startInFavoritesEdit: mode == .edit,
                        onPick: { radioStation = $0 }
                    )
                }
            }
            .customAlarmToneScreen(mode: $customToneMode)
        }
    }
}
