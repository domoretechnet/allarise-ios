//
//  AlertConfigurationSettingsView.swift
//  HaWake Alarm V2
//

import SwiftUI

struct AlertConfigurationSettingsView: View {
    @Bindable var settings: DeviceSettings

    var body: some View {
        Form {
            Section {
                Picker("Alert Sound", selection: $settings.alertDefaultSound) {
                    ForEach(AlarmSoundManager.shared.getAllSounds(), id: \.id) { sound in
                        Text(sound.displayName).tag(sound.id)
                    }
                }
                .pickerStyle(.navigationLink)

                Toggle(isOn: $settings.alertVibrationEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vibrate")
                        Text("Vibrate when an HA alert fires")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.alertVibrationEnabled) { _, newValue in
                    if settings.mqttEnabled {
                        HAIntegrationRouter.shared.publishAlertVibrationEnabled(newValue, settings: settings)
                    }
                }

                Toggle(isOn: $settings.alertLoopMedia) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Loop Media")
                        Text("Continuously loop media_url audio until dismissed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.alertLoopMedia) { _, newValue in
                    if settings.mqttEnabled {
                        HAIntegrationRouter.shared.publishAlertLoopMedia(newValue, settings: settings)
                    }
                }

                if settings.alertLoopMedia {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Loop Delay")
                            Spacer()
                            Text(settings.alertLoopDelay == 0
                                 ? "No delay"
                                 : "\(Int(settings.alertLoopDelay))s")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.alertLoopDelay, in: 0...60, step: 1)
                            .onChange(of: settings.alertLoopDelay) { _, newValue in
                                if settings.mqttEnabled {
                                    HAIntegrationRouter.shared.publishAlertLoopDelay(newValue, settings: settings)
                                }
                            }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Alert Volume")
                        Spacer()
                        Text("\(Int(settings.mediaAlertVolume * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.mediaAlertVolume, in: 0...1, step: 0.05)
                        .onChange(of: settings.mediaAlertVolume) { _, newValue in
                            if settings.mqttEnabled {
                                MQTTManager.shared.publishMediaAlertVolume(newValue, settings: settings)
                            }
                        }
                }
            } footer: {
                Text("Sound and volume can be overridden per-alert via the MQTT payload. Loop Media, Loop Delay, and Vibrate are also controllable from Home Assistant.")
            }
        }
        .navigationTitle("Alert Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if settings.alertDefaultSound.isEmpty,
               let first = AlarmSoundManager.shared.getAllSounds().first {
                settings.alertDefaultSound = first.id
            }
        }
    }
}
