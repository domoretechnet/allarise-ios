//
//  QuickAlarmView.swift
//  HaWake Alarm V2
//
//  Quick timer-style alarm creation (like Alarmy's quick alarm)
//

import SwiftUI

struct QuickAlarmView: View {
    let settings: DeviceSettings
    let onCreate: (Alarm) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// The app-wide theme accent, matching every other control.
    private var accentColor: Color {
        settings.appAccent(for: colorScheme)
    }
    
    // Duration presets in minutes
    private let presets: [(label: String, minutes: Int)] = [
        ("1 min", 1),
        ("5 min", 5),
        ("10 min", 10),
        ("15 min", 15),
        ("30 min", 30),
        ("1 hour", 60),
    ]
    
    @State private var selectedMinutes: Int = 5
    @State private var selectedSoundID: String
    // Display name tracked separately so the button label updates without re-querying the sound list
    @State private var selectedSoundName: String
    @State private var showingSoundPicker = false
    @State private var vibrate: Bool
    @State private var volumeLevel: Double
    
    private let sounds: [AlarmSound]
    
    init(settings: DeviceSettings, onCreate: @escaping (Alarm) -> Void) {
        // Load sounds once in init so we can resolve the display name for the default sound
        let sounds = AlarmSoundManager.shared.getAllSounds()

        self.settings = settings
        self.onCreate = onCreate
        self.sounds = sounds
        _selectedSoundID = State(initialValue: settings.defaultAlarmSound)
        _selectedSoundName = State(
            initialValue: sounds.first(where: { $0.id == settings.defaultAlarmSound })?.displayName ?? "Sound"
        )
        _vibrate = State(initialValue: settings.alarmVibrationEnabled)
        _volumeLevel = State(initialValue: settings.alarmVolumeLevel)
    }
    
    private var fireTime: Date {
        Date().addingTimeInterval(TimeInterval(selectedMinutes * 60))
    }
    
    private var countdownString: String {
        if selectedMinutes >= 60 {
            let hours = selectedMinutes / 60
            let mins = selectedMinutes % 60
            if mins == 0 {
                return "\(hours) hr"
            }
            return "\(hours) hr \(mins) min"
        }
        return "\(selectedMinutes) min"
    }
    
    private var fireTimeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: fireTime)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                        // Timer-style display with countdown duration and fire time
                        VStack(spacing: 4) {
                            HStack(spacing: 16) {
                                Button {
                                    withAnimation(.smooth(duration: 0.2)) {
                                        if selectedMinutes > 1 {
                                            selectedMinutes -= 1
                                        }
                                    }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.title)
                                        .foregroundStyle(selectedMinutes > 1 ? accentColor : .gray.opacity(0.4))
                                }
                                .buttonStyle(.plain)
                                .disabled(selectedMinutes <= 1)

                                Text(countdownString)
                                    .font(.system(size: 38, weight: .bold, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .contentTransition(.numericText())
                                    .animation(.smooth, value: selectedMinutes)

                                Button {
                                    withAnimation(.smooth(duration: 0.2)) {
                                        selectedMinutes += 1
                                    }
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title)
                                        .foregroundStyle(accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                            Text("Alarm at \(fireTimeString)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)

                        // Duration presets — 3x2 grid
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(presets, id: \.minutes) { preset in
                                Button {
                                    withAnimation(.smooth(duration: 0.2)) {
                                        selectedMinutes = preset.minutes
                                    }
                                } label: {
                                    Text(preset.label)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(selectedMinutes == preset.minutes ? .white : accentColor)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                        .background(
                                            selectedMinutes == preset.minutes
                                            ? AnyShapeStyle(accentColor)
                                            : AnyShapeStyle(.ultraThinMaterial)
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)

                        // Sound, vibrate, volume options
                        VStack(spacing: 0) {
                            // Sound picker row
                            HStack {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(accentColor)
                                    .frame(width: 24)
                                Text("Sound")
                                Spacer()
                                Button {
                                    showingSoundPicker = true
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(selectedSoundName)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                            .truncationMode(.tail)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .frame(minWidth: 0, maxWidth: 170, alignment: .trailing)
                                    .foregroundStyle(accentColor)
                                    .layoutPriority(1)
                                }
                                .buttonStyle(.plain)
                            }
                            // confirmationDialog avoids the inline Picker expanding the sheet height on medium detent
                            .confirmationDialog("Choose Sound", isPresented: $showingSoundPicker, titleVisibility: .visible) {
                                ForEach(sounds) { sound in
                                    Button(sound.displayName) {
                                        selectedSoundID = sound.id
                                        selectedSoundName = sound.displayName
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)

                            Divider().padding(.leading, 56)

                            // Volume slider + vibrate icon
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.wave.1.fill")
                                    .foregroundStyle(accentColor)
                                    .frame(width: 24)
                                Slider(value: $volumeLevel, in: 0.0...1.0)
                                    .tint(accentColor)
                                Text("\(Int(volumeLevel * 100))%")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(width: 52, alignment: .trailing)

                                Button {
                                    vibrate.toggle()
                                } label: {
                                    Image(systemName: "iphone.radiowaves.left.and.right")
                                        .font(.title3)
                                        .foregroundStyle(vibrate ? accentColor : .gray)
                                        .contentTransition(.symbolEffect(.replace))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            // safeAreaBar pins the button and reserves scroll inset so the volume slider is never hidden behind it
            .safeAreaBar(edge: .bottom) {
                Button {
                    createQuickAlarm()
                } label: {
                    Text("Set Alarm")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(accentColor, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .buttonStyle(.plain)
                .background(.bar)
            }
            .navigationTitle("Quick Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
    
    private func createQuickAlarm() {
        // Generate descriptive label: "Quick Alarm (5 min)" or "Quick Alarm (1 hour)"
        let quickLabel: String
        if selectedMinutes >= 60 {
            let hours = selectedMinutes / 60
            let mins = selectedMinutes % 60
            if mins == 0 {
                quickLabel = "Quick Alarm (\(hours) hr)"
            } else {
                quickLabel = "Quick Alarm (\(hours) hr \(mins) min)"
            }
        } else {
            quickLabel = "Quick Alarm (\(selectedMinutes) min)"
        }
        
        let alarm = Alarm(
            time: fireTime,
            label: quickLabel,
            isEnabled: true,
            recurringDays: [],
            soundName: selectedSoundID,
            snoozeDuration: settings.defaultSnoozeDuration
        )
        alarm.isEphemeral = true
        alarm.customVolumeLevel = volumeLevel
        alarm.customVibrationEnabled = vibrate
        
        onCreate(alarm)
        dismiss()
    }
}
