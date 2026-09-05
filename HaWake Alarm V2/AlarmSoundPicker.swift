//
//  AlarmSoundPicker.swift
//  HaWake Alarm V2
//
//  Sound picker component for alarm sound selection
//

import AVFoundation
import SwiftUI

/// Station browser presentation mode. Item-based so the edit/new mode travels
/// WITH the presentation — a Bool + side flag could build the cover with the
/// flag's stale value on its first presentation. Top-level so hosts can own
/// the `@State` and anchor the `.fullScreenCover` at their stable root
/// (Form / NavigationStack), instead of the picker's Form-row context which
/// tears the editor sheet down when the cover presents.
enum StationBrowserMode: String, Identifiable {
    case edit, new
    var id: String { rawValue }
}

/// Which custom-alarm-tone entry point the picker asked for. Both land on the
/// same scoped Sound Manager screen; `add` opens the file importer on arrival.
/// Identifiable so the HOST can anchor the presentation at its stable root —
/// the same rule `StationBrowserMode` follows, and for the same reason
/// (presenting from a Form row tears the host's own sheet down).
enum CustomToneMode: String, Identifiable {
    case add, edit
    var id: String { rawValue }
    var opensImporter: Bool { self == .add }
}

extension View {
    /// Presents the scoped custom-alarm-tone screen for `mode`. Every host of
    /// `AlarmSoundPicker` attaches this at its own stable root, so the three of
    /// them can't drift in how the screen is presented or dismissed.
    func customAlarmToneScreen(mode: Binding<CustomToneMode?>) -> some View {
        fullScreenCover(item: mode) { requested in
            NavigationStack {
                SoundManagerView(initialCategory: .alarmTone,
                                 customOnly: true,
                                 autoImport: requested.opensImporter)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { mode.wrappedValue = nil }
                        }
                    }
            }
        }
    }
}

struct AlarmSoundPicker: View {
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }
    @Binding var selectedSoundID: String
    var alarmVolumeLevel: Double = 1.0
    var customVolumeLevel: Binding<Double?>?
    /// When provided, renders a global volume slider (non-optional) and preview button
    var globalVolumeLevel: Binding<Double>?
    /// Section header title — defaults to "Sound", can be overridden (e.g. "Default Sound" in Settings)
    var sectionTitle: String = "Sound"
    /// Global vibrate toggle (used in Settings — simple on/off)
    var globalVibrate: Binding<Bool>?
    /// Per-alarm vibrate override — nil = use global default, non-nil = per-alarm override
    var customVibrate: Binding<Bool?>?
    /// The current global vibrate default (used when customVibrate is nil)
    var globalVibrateDefault: Bool = true
    /// Global fade-in toggle (used in Settings — gradual volume ramp when vibrate is off)
    var globalFadeIn: Binding<Bool>?
    /// Global fade-in duration in minutes (used in Settings)
    var globalFadeInDuration: Binding<Int>?
    /// Per-alarm fade-in override — nil = use global default
    var customFadeIn: Binding<Bool?>?
    /// Per-alarm fade-in duration override in minutes — nil = use global default
    var customFadeInDuration: Binding<Int?>?
    /// The current global fade-in defaults (used when custom values are nil)
    var globalFadeInDefault: Bool = false
    var globalFadeInDurationDefault: Int = 5
    /// Wake-up radio station (alarm editor and sound settings — nil hides the row).
    /// Choices come from stations favorited in the plus-menu Radio sheet.
    var radioStation: Binding<RadioStation?>? = nil
    /// Whether this section starts collapsed (showing only a summary row)
    var startCollapsed: Bool = false
    /// When true, renders rows directly without wrapping in a Section (for embedding in another Section)
    var embeddedMode: Bool = false
    /// Shared accordion state — expanding this section collapses the editor's others
    var expandedSection: Binding<AlarmEditorSection?> = .constant(nil)
    private var isExpanded: Bool { expandedSection.wrappedValue == .sound }
    /// Station browser presentation, OWNED BY THE HOST. The host anchors the
    /// matching `.fullScreenCover(item:)` at its stable root (Form /
    /// NavigationStack) — presenting from the picker's own Form-row context
    /// inside the editor sheet tore the sheet down. The picker only sets the
    /// mode; hosts with no radioStation binding leave this `.constant(nil)`.
    var stationBrowserMode: Binding<StationBrowserMode?> = .constant(nil)
    /// Custom-alarm-tone screen presentation, OWNED BY THE HOST for exactly the
    /// same reason as `stationBrowserMode` above. The picker only sets the mode.
    var customToneMode: Binding<CustomToneMode?> = .constant(nil)
    @State private var isPlaying = false
    @State private var playingSoundID: String?
    @State private var prePreviewVolume: Float = 0.0
    @State private var radioPreviewPlayer: AVPlayer?
    /// Spinner state for the preview buttons. This player is a bare AVPlayer
    /// that RadioPlayerManager never sees, so it can't borrow that manager's
    /// isConnecting — it observes its own clock instead.
    @State private var radioPreviewConnecting = false
    @State private var radioPreviewObserver: Any?
    /// Dead-air meter for the preview. A stream can connect and advance its
    /// clock while rendering pure silence (an off-the-air icecast station); the
    /// clock-only spinner above clears anyway, so the button looks like it is
    /// playing sound when it is not. This taps the preview item and reports
    /// whether audible samples arrive. FAIL-SOFT: if the tap can't attach,
    /// `isMonitoring` stays false and we never accuse the station.
    @State private var radioPreviewMonitor: StreamAudioLevelMonitor?
    /// UI verdict, driven ONLY from the silence-check task below — never read
    /// the monitor directly in `body` (it is a plain class, not @Observable, so
    /// SwiftUI would not react to its properties).
    @State private var radioPreviewSilent = false
    /// The running silence check. Started when the preview clock first advances,
    /// cancelled in `stopRadioPreview`.
    @State private var radioPreviewSilenceTask: Task<Void, Never>?
    /// Inline disclosure state for the Sound and Radio header rows. Only one may
    /// be open at a time — expanding one collapses the other so the open list
    /// has the card to itself (mirrors SleepSoundSetupView's source rows). This
    /// is INNER state, independent of the host's `expandedSection` accordion.
    @State private var soundExpanded = false
    @State private var radioExpanded = false

    /// DEBUG harness hook (`-soundPickerDebug expanded`): start with the tone
    /// list open, which otherwise needs a tap no screenshot run can perform.
    /// Never true in the shipping app.
    private static var debugStartsExpanded: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-soundPickerDebug") else { return false }
        return args.dropFirst(idx + 1).first == "expanded"
        #else
        return false
        #endif
    }

    /// Reloaded when the custom-tone screen closes, so a tone imported there
    /// shows up in this list without leaving the picker. Was a `let`, which
    /// meant a freshly imported tone stayed invisible until the whole screen was
    /// rebuilt.
    @State private var sounds = AlarmSoundManager.shared.getAllSounds()
    
    /// The effective volume used for preview playback
    private var effectiveVolume: Double {
        customVolumeLevel?.wrappedValue ?? globalVolumeLevel?.wrappedValue ?? alarmVolumeLevel
    }
    
    /// Whether vibration is effectively on (checks per-alarm override then global)
    private var effectiveVibrateIsOn: Bool {
        if let custom = customVibrate?.wrappedValue {
            return custom
        }
        return globalVibrate?.wrappedValue ?? globalVibrateDefault
    }
    
    private var selectedSoundName: String {
        sounds.first(where: { $0.id == selectedSoundID })?.displayName ?? "Default"
    }

    /// Collapsed-card title — an assigned radio station takes over from the
    /// tone, since the station is what actually plays when the alarm rings.
    private var summaryTitle: String {
        radioStation?.wrappedValue?.name ?? selectedSoundName
    }

    private var summaryIcon: String {
        radioStation?.wrappedValue != nil ? "radio" : "speaker.wave.2.fill"
    }
    
    /// Label for fade-in duration: 0 = "30 sec", otherwise "N min"
    private func fadeInDurationLabel(_ value: Int) -> String {
        value == 0 ? "30 sec" : "\(value) min"
    }
    
    /// Summary text for per-alarm volume
    private var volumeSummaryText: String {
        let vol = Int((customVolumeLevel?.wrappedValue ?? globalVolumeLevel?.wrappedValue ?? alarmVolumeLevel) * 100)
        return "\(vol)%"
    }
    
    var body: some View {
        Group {
            if embeddedMode {
                soundRows
            } else {
                Section {
                    soundRows
                } header: {
                    Text(sectionTitle)
                } footer: {
                    soundFooter
                }
            }
        }
    }
    
    @ViewBuilder
    private var soundRows: some View {
        Group {
            if startCollapsed && !isExpanded {
                // Summary card — matches pattern from Mission / Snooze sections
                Button {
                    withAnimation(.smooth) {
                        expandedSection.wrappedValue = .sound
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: summaryIcon)
                            .font(.title2)
                            .foregroundStyle(accent)
                            .frame(width: 36)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(summaryTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Tap to customize sound, volume & more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Text(volumeSummaryText)
                            .font(.subheadline)
                            .foregroundStyle(accent)
                        
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(accent)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            } else {
                // Sound + Radio as collapsible two-line header rows borrowed
                // from SleepSoundSetupView. Only one list opens at a time; while
                // one is expanded the OTHER header is hidden entirely.
                if !radioExpanded {
                    soundPickerRows
                }

                // Per-alarm wake-up radio (alarm editor only)
                if let radioBinding = radioStation, !soundExpanded {
                    radioPickerRows(radioBinding)
                }

                // Volume slider
                if let volumeBinding = globalVolumeLevel {
                    globalVolumeView(volumeBinding: volumeBinding)
                }

                if let volumeBinding = customVolumeLevel {
                    perAlarmVolumeView(volumeBinding: volumeBinding)
                }
                
                // Global vibrate toggle (Settings)
                if let vibrateBinding = globalVibrate {
                    Toggle(isOn: vibrateBinding) {
                        HStack(spacing: 8) {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .foregroundStyle(accent)
                                .frame(width: 24)
                            Text("Vibrate")
                        }
                    }
                }
                
                // Per-alarm vibrate toggle
                if let vibrateBinding = customVibrate {
                    Toggle(isOn: Binding(
                        get: { vibrateBinding.wrappedValue ?? globalVibrateDefault },
                        set: { vibrateBinding.wrappedValue = $0 }
                    )) {
                        HStack(spacing: 8) {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .foregroundStyle(accent)
                                .frame(width: 24)
                            Text("Vibrate")
                        }
                    }
                }

                // Apple Watch haptic note — only show when vibrate is actually enabled
                let vibrateIsOn = globalVibrate?.wrappedValue == true
                    || (customVibrate?.wrappedValue ?? globalVibrateDefault)
                if vibrateIsOn {
                    HStack(spacing: 6) {
                        Image(systemName: "applewatch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Apple Watch vibration only works when your phone is locked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .listRowSeparator(.hidden, edges: .top)
                }

                // Fade-in controls
                // Global fade-in (Settings)
                if let fadeInBinding = globalFadeIn {
                    Toggle(isOn: fadeInBinding) {
                        HStack(spacing: 8) {
                            Image(systemName: "sunrise.fill")
                                .foregroundStyle(accent)
                                .frame(width: 24)
                            Text("Fade In")
                        }
                    }
                    if fadeInBinding.wrappedValue, let durationBinding = globalFadeInDuration {
                        Stepper("Duration: \(fadeInDurationLabel(durationBinding.wrappedValue))", value: durationBinding, in: 0...15)
                    }
                }
                
                // Per-alarm fade-in override
                if let fadeInBinding = customFadeIn {
                    Toggle(isOn: Binding(
                        get: { fadeInBinding.wrappedValue ?? globalFadeInDefault },
                        set: { fadeInBinding.wrappedValue = $0 }
                    )) {
                        HStack(spacing: 8) {
                            Image(systemName: "sunrise.fill")
                                .foregroundStyle(accent)
                                .frame(width: 24)
                            Text("Fade In")
                        }
                    }
                    let fadeInOn = fadeInBinding.wrappedValue ?? globalFadeInDefault
                    if fadeInOn, let durationBinding = customFadeInDuration {
                        Stepper("Duration: \(fadeInDurationLabel(durationBinding.wrappedValue ?? globalFadeInDurationDefault))",
                            value: Binding(
                                get: { durationBinding.wrappedValue ?? globalFadeInDurationDefault },
                                set: { durationBinding.wrappedValue = $0 }
                            ),
                            in: 0...15
                        )
                    }
                }

                if startCollapsed {
                    SectionCollapseButton(accent: accent) {
                        expandedSection.wrappedValue = nil
                    }
                }
            }
        }
        .onAppear {
            // The station browser mode is HOST-owned now; the host's fresh
            // @State already defaults to nil, so the picker must NOT reset it
            // here — doing so could clear a mode the host just set.
            soundExpanded = Self.debugStartsExpanded
            radioExpanded = false
        }
        .onDisappear {
            if stationBrowserMode.wrappedValue == nil,
               startCollapsed,
               expandedSection.wrappedValue == .sound {
                expandedSection.wrappedValue = nil
            }
            if isPlaying {
                stopPreview()
            }
            if radioPreviewPlayer != nil {
                stopRadioPreview()
            }
        }
        .onChange(of: selectedSoundID) { _, newSoundID in
            // If previewing, restart with the newly selected sound
            if isPlaying {
                AlarmSoundPlayer.shared.stop()
                AlarmSoundPlayer.shared.unlock()
                playingSoundID = newSoundID
                Task { @MainActor in
                    await AlarmSoundPlayer.shared.play(soundID: newSoundID)
                }
            }
        }
        .onChange(of: customToneMode.wrappedValue) { _, mode in
            // Closed → pick up anything imported while it was open.
            if mode == nil {
                sounds = AlarmSoundManager.shared.getAllSounds()
            }
        }
    }
    
    @ViewBuilder
    private var soundFooter: some View {
        if sounds.isEmpty {
            Text("No alarm sounds found. Add .wav files to the AlarmSounds folder.")
                .foregroundStyle(.red)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if globalVibrate != nil || globalVolumeLevel != nil {
                    Text("Volume is set during alarm and restored after dismiss.")
                        .font(.caption2)
                    if globalFadeIn?.wrappedValue == true {
                        Text("Fade In gradually increases volume over the set duration.")
                            .font(.caption2)
                    }
                }
                // Reliability reassurance for wake-up radio (the inline
                // caption moved here when the radio row was restyled).
                if radioStation?.wrappedValue != nil {
                    Text("Radio streams when the alarm rings. Your alarm tone plays automatically if the stream can't start.")
                        .font(.caption2)
                }
            }
        }
    }
    
    /// Fixed-width leading icon column shared by the Sound and Radio headers
    /// and the blue action rows (matches SleepSoundSetupView's `rowIcon`).
    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title2)
            .foregroundStyle(accent)
            .frame(width: 36)
    }

    /// Blue icon + blue text — reads as an action, not a pickable item. The
    /// expanded lists hide their separators, so the blue accent is the only
    /// cue distinguishing actions (Edit / New Station) from selectable rows.
    private func actionRowLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            rowIcon(icon)
            Text(title)
                .foregroundStyle(accent)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    /// Collapsible Sound section. The header shows the "Sound" title with the
    /// current tone on the caption line, a preview play/stop button for the
    /// selected tone, and a rotating chevron. Tapping the header toggles the
    /// inline tone list; picking a tone selects it and collapses.
    @ViewBuilder
    private var soundPickerRows: some View {
        // Header. Tone and radio are NOT mutually exclusive and are no longer
        // presented as if they were: a tone is always selected, because it is
        // what rings when the stream cannot start. With a station assigned the
        // two rows are badged PRIMARY (radio) and BACKUP (tone) rather than one
        // of them being blanked out. Picking a tone does not clear radio —
        // radio is switched off by its own "Off" row in `radioPickerRows`.
        let radioAssigned = (radioStation?.wrappedValue != nil)
        HStack(spacing: 12) {
            rowIcon("speaker.wave.2.fill")
            // With radio assigned the tone is still chosen — it's the BACKUP
            // that rings if the stream can't start. The badge says so; no
            // explanatory text needed.
            headerTextBlock(
                title: "Alarm Sound",
                value: selectedSoundName,
                dimmed: false,
                badge: radioAssigned ? "BACKUP" : nil,
                badgeTint: .secondary
            )
            // Preview the SELECTED tone here (rather than one button per row) —
            // it keeps a single, always-visible affordance in sync with the
            // volume rows' preview buttons through the shared `isPlaying` state.
            Button {
                previewSound()
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.borderless)
            .disabled(sounds.isEmpty)
            Spacer()
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(soundExpanded ? 0 : -90))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // Expanded list is separator-free; hide the header's own line too.
        .listRowSeparator(soundExpanded ? .hidden : .automatic)
        .onTapGesture {
            withAnimation(.smooth(duration: 0.25)) {
                soundExpanded.toggle()
                if soundExpanded { radioExpanded = false }
            }
        }

        if soundExpanded {
            let builtIn = sounds.filter { !$0.id.hasPrefix("custom_") }
            let custom = sounds.filter { $0.id.hasPrefix("custom_") }
            ForEach(builtIn) { sound in
                soundToneRow(sound)
            }
            if !custom.isEmpty {
                Text("Custom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 48)
                    .listRowSeparator(.hidden)
                ForEach(custom) { sound in
                    soundToneRow(sound)
                }
            }

            // Edit / Add for custom tones, mirroring the radio section's
            // "Edit Stations" / "New Station" pair below. Both open the scoped
            // custom-alarm-tone screen; Add lands there with the file importer
            // already up.
            Button {
                openCustomTones(.edit)
            } label: {
                actionRowLabel("Edit Custom Tones", icon: "pencil")
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)

            Button {
                openCustomTones(.add)
            } label: {
                actionRowLabel("Add Custom Tone", icon: "plus")
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
        }
    }

    /// Hand the request UP to the host, which owns the presentation. Stops any
    /// running preview first — the same courtesy `openRadioBrowser` does.
    private func openCustomTones(_ mode: CustomToneMode) {
        if isPlaying { stopPreview() }
        if radioPreviewPlayer != nil { stopRadioPreview() }
        customToneMode.wrappedValue = mode
    }

    /// Header text block: title (+ optional PRIMARY/BACKUP badge) and an
    /// empty-gated value line inside a fixed-height frame, so a valueless
    /// row keeps its height with the title centered on the icon.
    private func headerTextBlock(title: String, value: String, dimmed: Bool, badge: String? = nil, badgeTint: Color = .blue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(dimmed ? .secondary : .primary)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badgeTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeTint.opacity(0.15), in: Capsule())
                }
            }
            if !value.isEmpty {
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 38, alignment: .leading)
    }

    /// One selectable tone row in the expanded Alarm Sound list. With radio
    /// assigned this picks the BACKUP tone — it does NOT clear the station.
    private func soundToneRow(_ sound: AlarmSound) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) {
                selectedSoundID = sound.id
                soundExpanded = false
            }
        } label: {
            HStack(spacing: 8) {
                Text(sound.displayName)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer()
                if selectedSoundID == sound.id {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accent)
                }
            }
            .padding(.leading, 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
    }

    /// Collapsible Radio section mirroring the Sound row. The header shows
    /// "Radio" with the current station (or "None") on the caption line, a
    /// stream test button when a station is assigned, and a rotating chevron.
    /// Expanding reveals an "Off" row, the favorite stations, and the blue
    /// Edit / New Station action rows. "Off" is how radio is cleared — picking
    /// an alarm tone does NOT clear it, because the tone is the always-present
    /// fallback that rings if the stream can't start. A station assigned but
    /// later un-favorited stays reachable so its checkmark never disappears.
    @ViewBuilder
    private func radioPickerRows(_ binding: Binding<RadioStation?>) -> some View {
        let favorites = RadioPlayerManager.shared.favorites

        // Header — grayed while no station is assigned ("None"), mirroring
        // the Alarm Sound row's inactive state. Still fully tappable.
        let radioAssigned = (binding.wrappedValue != nil)
        HStack(spacing: 12) {
            rowIcon("radio")
                .opacity(radioAssigned ? 1.0 : 0.45)
            headerTextBlock(
                title: "Radio",
                value: binding.wrappedValue?.name ?? "",
                dimmed: !radioAssigned,
                badge: radioAssigned ? "PRIMARY" : nil,
                badgeTint: accent
            )
            // Test the stream at the alarm's effective volume — same volume
            // handling as the sound preview button.
            if let station = binding.wrappedValue {
                Button {
                    toggleRadioPreview(station)
                } label: {
                    RadioPlayCircle(
                        systemImage: radioPreviewPlayer != nil ? "stop.fill" : "play.fill",
                        isConnecting: radioPreviewConnecting,
                        diameter: 24,
                        fill: .solid(accent)
                    )
                }
                .buttonStyle(.borderless)
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(radioExpanded ? 0 : -90))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .listRowSeparator(radioExpanded ? .hidden : .automatic)
        .onTapGesture {
            withAnimation(.smooth(duration: 0.25)) {
                radioExpanded.toggle()
                if radioExpanded { soundExpanded = false }
            }
        }
        .onChange(of: binding.wrappedValue?.id) { _, _ in
            // Station changed mid-test — stop rather than play a stale stream.
            if radioPreviewPlayer != nil { stopRadioPreview() }
        }

        // Dead-air notice, directly under the row whose Test button was pressed.
        // Only appears once the meter has confirmed silence — never when the tap
        // failed to attach (audibility unknown). Matches the Apple Watch note's
        // caption idiom above.
        if radioPreviewSilent {
            HStack(spacing: 6) {
                Image(systemName: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("No sound from this station right now — it may be off the air. If this happens at alarm time, the alarm tone plays instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity)
            .listRowSeparator(.hidden, edges: .top)
        }

        if radioExpanded {
            // Off — radio is a feature you switch off, not a missing pick.
            // (Tapping the checked station below also unticks it.)
            Button {
                withAnimation(.smooth(duration: 0.25)) {
                    binding.wrappedValue = nil
                    radioExpanded = false
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Off")
                        .foregroundStyle(.primary)
                    Spacer()
                    if binding.wrappedValue == nil {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                }
                .padding(.leading, 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)

            // Favorites, plus the current station if it isn't a favorite so its
            // checkmark stays reachable.
            let stations: [RadioStation] = {
                if let current = binding.wrappedValue,
                   !favorites.contains(where: { $0.id == current.id }) {
                    return favorites + [current]
                }
                return favorites
            }()

            ForEach(stations) { station in
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        // Tapping the checked station unticks it (radio off).
                        if binding.wrappedValue?.id == station.id {
                            binding.wrappedValue = nil
                        } else {
                            binding.wrappedValue = station
                        }
                        radioExpanded = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(station.name)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        if binding.wrappedValue?.id == station.id {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(accent)
                        }
                    }
                    .padding(.leading, 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }

            // Edit Stations — opens the browser straight into favorites-edit.
            Button {
                openRadioBrowser(startInEdit: true)
            } label: {
                actionRowLabel("Edit Stations", icon: "pencil")
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)

            // New Station — opens the normal browser.
            Button {
                openRadioBrowser(startInEdit: false)
            } label: {
                actionRowLabel("New Station", icon: "plus")
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
        }
    }

    /// Open the full station browser in pick mode. Stops any running preview
    /// first, and routes "Edit Stations" straight into the favorites-edit list.
    /// The cover is anchored at the HOST's stable root, so setting the shared
    /// binding directly is safe — no deferred present needed.
    private func openRadioBrowser(startInEdit: Bool) {
        if isPlaying { stopPreview() }
        if radioPreviewPlayer != nil { stopRadioPreview() }
        stationBrowserMode.wrappedValue = startInEdit ? .edit : .new
    }

    /// Start/stop a live test of the wake-up station at the effective alarm
    /// volume (mirrors previewSound's save/set/restore volume handling).
    private func toggleRadioPreview(_ station: RadioStation) {
        if radioPreviewPlayer != nil {
            stopRadioPreview()
            return
        }
        guard let url = URL(string: station.streamURL) else { return }
        // One test at a time — the tone preview and radio test share the
        // saved pre-preview volume, so never run both.
        if isPlaying { stopPreview() }
        prePreviewVolume = VolumeManager.shared.getCurrentVolume()
        VolumeManager.shared.setSystemVolumeQuietly(to: Float(effectiveVolume))
        // Build from an explicit item so a dead-air meter can tap it. Behavior
        // is identical to AVPlayer(url:).
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let monitor = StreamAudioLevelMonitor()
        monitor.attach(url: url)
        radioPreviewMonitor = monitor
        radioPreviewSilent = false
        player.play()
        radioPreviewPlayer = player
        // Spinner until the clock actually advances — same "audio is really
        // rendering" signal RadioPlayerManager uses.
        radioPreviewConnecting = true
        radioPreviewObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 10),
            queue: .main
        ) { time in
            // Clock advanced: clear the spinner and, exactly once, start the
            // dead-air check. The 5s window begins here, NOT at play().
            if time.seconds > 0, radioPreviewConnecting {
                radioPreviewConnecting = false
                startRadioSilenceCheck()
            }
        }
    }

    /// Watch the preview meter for dead air. After 5s of the stream playing, if
    /// the tap is monitoring but has heard nothing audible, flag it silent; then
    /// keep polling so a late-arriving audio buffer clears the accusation.
    /// FAIL-SOFT: `isMonitoring` is false when the tap never attached, so the
    /// verdict stays false and the caption never shows.
    @MainActor
    private func startRadioSilenceCheck() {
        radioPreviewSilenceTask?.cancel()
        radioPreviewSilenceTask = Task { @MainActor in
            // Let the stream play for 5s before the first verdict.
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            while !Task.isCancelled {
                if let monitor = radioPreviewMonitor {
                    let silent = monitor.isMonitoring && !monitor.hasHeardAudio
                    if radioPreviewSilent != silent {
                        withAnimation(.smooth) { radioPreviewSilent = silent }
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopRadioPreview() {
        if let token = radioPreviewObserver {
            radioPreviewPlayer?.removeTimeObserver(token)
            radioPreviewObserver = nil
        }
        radioPreviewSilenceTask?.cancel()
        radioPreviewSilenceTask = nil
        radioPreviewMonitor?.detach()
        radioPreviewMonitor = nil
        radioPreviewSilent = false
        radioPreviewConnecting = false
        radioPreviewPlayer?.pause()
        radioPreviewPlayer = nil
        VolumeManager.shared.setSystemVolumeQuietly(to: prePreviewVolume)
        prePreviewVolume = 0.0
    }

    /// True while whichever source the alarm would play is being previewed.
    private var activePreviewRunning: Bool {
        radioStation?.wrappedValue != nil ? radioPreviewPlayer != nil : isPlaying
    }

    /// Start/stop a preview of the alarm's ACTIVE source — the assigned
    /// radio station when one is set, otherwise the selected tone. Both
    /// paths share the same save/set/restore volume contract.
    private func toggleActivePreview() {
        if let station = radioStation?.wrappedValue {
            toggleRadioPreview(station)
        } else {
            previewSound()
        }
    }

    /// Shared play/stop button for both volume rows — syncs with the alarm's
    /// active source (radio or tone), not just the tone.
    private var volumePreviewButton: some View {
        Button {
            toggleActivePreview()
        } label: {
            // Only the radio branch of this shared button can be "connecting";
            // a bundled tone starts instantly.
            RadioPlayCircle(
                systemImage: activePreviewRunning ? "stop.fill" : "play.fill",
                isConnecting: radioStation?.wrappedValue != nil && radioPreviewConnecting,
                diameter: 24,
                fill: .solid(accent)
            )
        }
        .buttonStyle(.borderless)
        .disabled(radioStation?.wrappedValue == nil && sounds.isEmpty)
    }

    @ViewBuilder
    private func globalVolumeView(volumeBinding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Alarm Volume")
            HStack(spacing: 8) {
                // Preview what the alarm will ACTUALLY play at this volume —
                // the assigned station when radio is set, else the tone.
                volumePreviewButton
                FormSlider(
                    value: volumeBinding,
                    range: 0.0...1.0,
                    tint: accent
                )
                Text("\(Int(volumeBinding.wrappedValue * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 52, alignment: .trailing)
            }
            .onChange(of: volumeBinding.wrappedValue) {
                if isPlaying || radioPreviewPlayer != nil {
                    VolumeManager.shared.setSystemVolumeQuietly(to: Float(volumeBinding.wrappedValue))
                }
            }
        }
    }

    @ViewBuilder
    private func perAlarmVolumeView(volumeBinding: Binding<Double?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Volume")
                .font(.subheadline)
            HStack(spacing: 8) {
                // Preview what the alarm will ACTUALLY play at this volume —
                // the assigned station when radio is set, else the tone.
                volumePreviewButton
                FormSlider(
                    value: Binding(
                        get: { volumeBinding.wrappedValue ?? alarmVolumeLevel },
                        set: { volumeBinding.wrappedValue = $0 }
                    ),
                    range: 0.0...1.0,
                    tint: accent
                )
                Text("\(Int((volumeBinding.wrappedValue ?? alarmVolumeLevel) * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 52, alignment: .trailing)
            }
            .onChange(of: volumeBinding.wrappedValue) {
                if isPlaying || radioPreviewPlayer != nil {
                    VolumeManager.shared.setSystemVolumeQuietly(to: Float(volumeBinding.wrappedValue ?? alarmVolumeLevel))
                }
            }
        }
    }
    
    private func previewSound() {
        if isPlaying {
            stopPreview()
        } else {
            // One test at a time (shared saved pre-preview volume)
            if radioPreviewPlayer != nil { stopRadioPreview() }
            // Save current volume and set to alarm level
            prePreviewVolume = VolumeManager.shared.getCurrentVolume()
            VolumeManager.shared.setSystemVolumeQuietly(to: Float(effectiveVolume))

            isPlaying = true
            playingSoundID = selectedSoundID
            
            // Play async — loops until user taps Stop Preview
            AlarmSoundPlayer.shared.unlock()
            Task { @MainActor in
                await AlarmSoundPlayer.shared.play(soundID: selectedSoundID)
            }
        }
    }

    private func stopPreview() {
        AlarmSoundPlayer.shared.stop()
        isPlaying = false
        playingSoundID = nil

        // Restore original volume
        VolumeManager.shared.setSystemVolumeQuietly(to: prePreviewVolume)
        prePreviewVolume = 0.0
    }
}

#Preview {
    Form {
        AlarmSoundPicker(selectedSoundID: .constant("Classic_Alarm"))
    }
}

#if DEBUG
/// Launch-argument harness for visual checks without UI navigation:
///   simctl launch booted domoretech.HaWake-Alarm-V2 -soundPickerDebug
/// Shows the alarm editor's sound section expanded with a sample radio
/// station assigned (long name to exercise the wrap).
struct AlarmSoundPickerDebugHost: View {
    @State private var soundID = AlarmSoundManager.shared.getAllSounds().first?.id ?? ""
    @State private var customVolume: Double? = 0.8
    @State private var vibrate: Bool? = nil
    @State private var fadeIn: Bool? = nil
    @State private var fadeInDuration: Int? = nil
    @State private var stationBrowserMode: StationBrowserMode?
    @State private var station: RadioStation? = RadioStation(
        id: "debug-station",
        name: "WCSG 91.3 Grand Rapids — Family Friendly Radio",
        streamURL: "https://example.com/stream",
        faviconURL: nil,
        country: "USA",
        tags: "christian, contemporary",
        codec: "MP3",
        bitrate: 128
    )

    var body: some View {
        NavigationStack {
            Form {
                AlarmSoundPicker(
                    selectedSoundID: $soundID,
                    alarmVolumeLevel: 0.8,
                    customVolumeLevel: $customVolume,
                    customVibrate: $vibrate,
                    customFadeIn: $fadeIn,
                    customFadeInDuration: $fadeInDuration,
                    radioStation: $station,
                    stationBrowserMode: $stationBrowserMode
                )
            }
            .navigationTitle("Sound Debug")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $stationBrowserMode) { mode in
                NavigationStack {
                    RadioBrowserView(
                        settings: DeviceSettings.shared,
                        pickMode: true,
                        startInFavoritesEdit: mode == .edit,
                        onPick: { station = $0 }
                    )
                }
            }
        }
    }
}
#endif
