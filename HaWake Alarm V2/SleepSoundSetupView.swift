
//
//  SleepSoundSetupView.swift
//  HaWake Alarm V2
//
//  Setup sheet for starting sleep sounds — pick a sound, set volume,
//  duration (hours or until next alarm), and fade-out.
//

import AVFoundation
import MediaPlayer
import SwiftUI
import SwiftData

struct SleepSoundSetupView: View {
    let settings: DeviceSettings
    /// When true the sheet drives the RUNNING session — every tap applies
    /// instantly (used by SleepSoundActiveRow). When false it's the ordinary
    /// "start a new session" setup flow (the moon button).
    var liveMode: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Alarm.time) private var alarms: [Alarm]

    private var scale: CGFloat { settings.biggerAlarmRows ? 1.2 : 1.0 }

    /// The app-wide theme accent for the current appearance (matches the mini-player row).
    private var themeAccentColor: Color { settings.appAccent(for: colorScheme) }

    /// State (not let) so returning from the custom-sound manager can refresh
    /// the list with newly added sounds.
    @State private var sounds = SleepSoundManager.availableSounds()

    /// Which source the shared timer settings will drive. Session-only (no
    /// persistence) and initially nil so BOTH source rows start blank — the
    /// last row the user picks from becomes the active source. Picking a sound
    /// selects `.sound` and blanks the radio value line; picking a station
    /// selects `.radio` and blanks the sound value line.
    private enum ActiveSource { case sound, radio }
    @State private var activeSource: ActiveSource?

    @State private var selectedSound: String
    @State private var volume: Double
    @State private var untilNextAlarm: Bool = false
    @State private var selectedDurationMinutes: Int = 480
    @State private var fadeOutMinutes: Int = 0
    /// Which custom-sleep-sound entry point was tapped — Add lands on the scoped
    /// screen with the file importer already up, Edit just shows the list. Same
    /// split as the alarm tone section's Add / Edit pair.
    @State private var soundManagerMode: CustomToneMode?
    @State private var selectedStation: RadioStation?
    /// Station browser presentation. Item-based (not a Bool + side flag) so
    /// the edit/new mode travels WITH the presentation — setting a flag and
    /// presenting in the same transaction could build the cover with the
    /// flag's stale value on first presentation ("Edit Stations" landed in
    /// plain browse until the cover had been shown once).
    private enum StationBrowserMode: String, Identifiable {
        case edit, new
        var id: String { rawValue }
    }
    @State private var stationBrowserMode: StationBrowserMode?
    /// Inline disclosure state for the two source rows. Only one may be open
    /// at a time — expanding one collapses the other to keep the sheet compact.
    @State private var soundExpanded = false
    @State private var radioExpanded = false
    /// Live mode: set when duration/fade/until-next-alarm change, so Start
    /// knows a sleep-sound session needs an automatic restart to re-time.
    @State private var timerDirty = false

    // MARK: - Preview (local players, NOT the managers' real playback)
    // One preview button on the volume row tests whichever source is active
    // at the slider volume: sounds loop through an AVAudioPlayer, radio
    // streams through a bare AVPlayer. Neither stops a live radio stream or
    // an already-running sleep-sound engine.
    @State private var previewPlayer: AVAudioPlayer?
    @State private var radioPreviewPlayer: AVPlayer?
    @State private var previewing = false
    /// Spinner state for the radio preview — this is a bare AVPlayer outside
    /// RadioPlayerManager, so it observes its own clock (see AlarmSoundPicker).
    @State private var radioPreviewConnecting = false
    @State private var radioPreviewObserver: Any?
    /// True only while a preview actually claimed the shared audio session, so
    /// onDisappear's stop never deactivates a session it didn't take (which
    /// would silence an active sleep-sound engine that can't recover).
    @State private var previewTookSession = false

    private let fadeOutOptions: [(label: String, minutes: Int)] = [
        ("Off", 0), ("5 min", 5), ("10 min", 10), ("15 min", 15), ("30 min", 30), ("60 min", 60)
    ]

    init(settings: DeviceSettings, liveMode: Bool = false) {
        self.settings = settings
        self.liveMode = liveMode
        let sounds = SleepSoundManager.availableSounds()
        let lastName = settings.lastSleepSoundName
        _selectedSound = State(initialValue: sounds.first(where: { $0 == lastName }) ?? sounds.first ?? "")
        _volume = State(initialValue: settings.lastSleepSoundVolume > 0 ? settings.lastSleepSoundVolume : 0.5)
        _selectedDurationMinutes = State(initialValue: settings.lastSleepDurationMinutes)
        _fadeOutMinutes = State(initialValue: settings.lastSleepFadeOutMinutes)
        _untilNextAlarm = State(initialValue: settings.lastSleepUntilNextAlarm)
        let radioManager = RadioPlayerManager.shared
        _selectedStation = State(initialValue: radioManager.lastStation ?? radioManager.favorites.first)
    }

    // Finds the soonest enabled non-ephemeral alarm fire date — used for "Until Next Alarm"
    private var nextAlarmDate: Date? {
        alarms
            .filter { $0.isEnabled && !$0.isEphemeral }
            .compactMap { $0.nextFireDate() }
            .min()
    }

    private var nextAlarmTimeString: String {
        guard let date = nextAlarmDate else { return "No alarm set — will play indefinitely" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "Stops at " + formatter.string(from: date)
    }

    /// Sound row value line — shown only while sounds are the active source.
    /// A single space keeps the two-line row height when blank.
    private var soundValueText: String {
        guard activeSource == .sound, !selectedSound.isEmpty else { return "" }
        return SleepSoundManager.displayName(for: selectedSound)
    }

    /// Radio row value line — shown only while radio is the active source.
    private var radioValueText: String {
        guard activeSource == .radio, let station = selectedStation else { return "" }
        return station.name
    }

    /// Header text block: title + optional value line inside a fixed-height
    /// frame, so a blank (unpicked) row keeps its height AND the title stays
    /// vertically centered with the icon (a placeholder-space line used to
    /// push the title off-center).
    private func headerTextBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 17 * scale, weight: .semibold))
            if !value.isEmpty {
                Text(value)
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 38, alignment: .leading)
    }

    private var startDisabled: Bool {
        switch activeSource {
        case .none: return true
        case .radio: return selectedStation == nil
        case .sound: return selectedSound.isEmpty
        }
    }

    /// 15/30-minute presets, then whole hours up to 12.
    private static let durationOptions: [Int] = [15, 30] + (1...12).map { $0 * 60 }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    var body: some View {
        NavigationStack {
            Form {
                // Now Playing — same card language as the radio browser's:
                // artwork with a waveform/pause overlay, name, caption, and a
                // pause/resume button. Live mode only (there is no session to
                // show in the ordinary start-a-session flow).
                if liveMode {
                    Section {
                        liveNowPlayingCard
                    }
                }

                // Sources: sleep sound + radio, both blank until picked. Their
                // expanded pickers appear as additional rows in this Section.
                // While one section is expanded the OTHER disappears entirely,
                // so the open list has the card to itself.
                Section {
                    if !radioExpanded {
                        soundPickerRows
                    }
                    if !soundExpanded {
                        radioPickerRows
                    }
                }

                // Volume — applies to whichever source plays. The preview
                // button tests the picked media (sound or station) at this
                // volume so the user hears what Start will actually sound like.
                Section {
                    HStack(spacing: 12) {
                        rowIcon("speaker.wave.1.fill")
                        // Preview is hidden in live mode — playback IS live, so
                        // the slider already changes what you hear.
                        if !liveMode {
                            Button {
                                togglePreview()
                            } label: {
                                // Only the radio source connects; bundled and
                                // custom sleep sounds are local files.
                                RadioPlayCircle(
                                    systemImage: previewing ? "stop.fill" : "play.fill",
                                    isConnecting: radioPreviewConnecting,
                                    diameter: 24,
                                    fill: .solid(themeAccentColor)
                                )
                            }
                            .buttonStyle(.borderless)
                            .disabled(startDisabled)
                        }
                        FormSlider(value: $volume, range: 0.0...1.0, tint: themeAccentColor)
                        Text("\(Int(volume * 100))%")
                            .font(.system(size: 13 * scale))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.vertical, 4)
                }

                // Timer — duration or "until next alarm", plus fade-out.
                Section {
                    Toggle(isOn: $untilNextAlarm) {
                        HStack(spacing: 12) {
                            rowIcon("sunrise.fill")
                            Text("Until Next Alarm")
                                .font(.system(size: 17 * scale, weight: .semibold))
                        }
                    }
                    .tint(themeAccentColor)
                    .padding(.vertical, 4)

                    if untilNextAlarm {
                        HStack(spacing: 12) {
                            rowIcon("clock.fill")
                            Text(nextAlarmTimeString)
                                .font(.system(size: 13 * scale))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    } else {
                        Picker(selection: $selectedDurationMinutes) {
                            ForEach(Self.durationOptions, id: \.self) { minutes in
                                Text(durationLabel(minutes)).tag(minutes)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                rowIcon("timer")
                                Text("Duration")
                                    .font(.system(size: 17 * scale, weight: .semibold))
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(themeAccentColor)
                        .padding(.vertical, 4)
                    }

                    Picker(selection: $fadeOutMinutes) {
                        ForEach(fadeOutOptions, id: \.minutes) { opt in
                            Text(opt.label).tag(opt.minutes)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            rowIcon("arrow.down.to.line")
                            Text("Fade Out")
                                .font(.system(size: 17 * scale, weight: .semibold))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(themeAccentColor)
                    .padding(.vertical, 4)
                }
            }
            .listSectionSpacing(32)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Same chrome in both modes: Cancel walks away, Start commits.
                // In live mode source/volume changes already applied on tap;
                // Start additionally applies timer changes (restarting a
                // sleep-sound session only when required) and persists.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        liveMode ? liveStart() : startSleepSounds()
                    }
                    .disabled(startDisabled)
                }
            }
            // Add / Edit Custom Sounds push the scoped custom-sleep-sound screen
            // with a Done button back; refresh the sound list on return so new
            // imports show up.
            .navigationDestination(isPresented: Binding(
                get: { soundManagerMode != nil },
                set: { if !$0 { soundManagerMode = nil } }
            )) {
                // Scoped to custom sleep sounds only — no category tabs, no
                // built-in list. Someone who tapped these rows is here for their
                // own sounds, not to browse.
                SoundManagerView(initialCategory: .sleepSound,
                                 customOnly: true,
                                 autoImport: soundManagerMode?.opensImporter ?? false)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                soundManagerMode = nil
                            }
                        }
                    }
            }
            .onChange(of: soundManagerMode) { _, mode in
                if mode == nil {
                    sounds = SleepSoundManager.availableSounds()
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Same floating Start in both modes (matching feel); the live
                // path only restarts when the timer settings require it.
                Button {
                    liveMode ? liveStart() : startSleepSounds()
                } label: {
                    Label(activeSource == .radio ? "Start Radio" : "Start Sleep Sounds",
                          systemImage: activeSource == .radio ? "radio.fill" : "moon.zzz.fill")
                        .font(.system(size: 17 * scale, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14 * scale)
                        .background(themeAccentColor, in: RoundedRectangle(cornerRadius: 14 * scale))
                }
                .buttonStyle(.plain)
                .disabled(startDisabled)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                // No .bar background: the button floats above the Form.
            }
            .fullScreenCover(item: $stationBrowserMode) { mode in
                NavigationStack {
                    RadioBrowserView(
                        settings: settings,
                        pickMode: true,
                        startInFavoritesEdit: mode == .edit,
                        keepPlayingOnPick: liveMode,
                        forSleepSession: true,
                        onPick: { station in
                            // Picking from the browser makes radio the active
                            // source, mirroring the inline favorites list. In
                            // live mode this also starts the station.
                            applyStationSelection(station)
                        }
                    )
                }
            }
            .onAppear { seedLiveState() }
            .onChange(of: volume) { _, newValue in
                // Keep an in-progress preview in sync with the slider.
                previewPlayer?.volume = Float(newValue)
                radioPreviewPlayer?.volume = Float(newValue)
                // Live: drive the running session's volume directly.
                if liveMode {
                    if RadioPlayerManager.shared.isActive {
                        RadioPlayerManager.shared.setVolume(Float(newValue))
                    } else if SleepSoundManager.shared.isActive {
                        SleepSoundManager.shared.setVolume(newValue)
                    }
                }
            }
            // Timer settings no longer apply instantly in live mode — they
            // take effect on Start (radio re-arms in place; sleep sounds
            // restart automatically only when these changed).
            .onChange(of: untilNextAlarm) { _, _ in timerDirty = true }
            .onChange(of: selectedDurationMinutes) { _, _ in timerDirty = true }
            .onChange(of: fadeOutMinutes) { _, _ in timerDirty = true }
            .onChange(of: selectedSound) { _, _ in
                // A different sound was picked — stop the preview rather than
                // let it keep playing the old media.
                if previewing { stopPreview() }
            }
            .onChange(of: selectedStation?.id) { _, _ in
                if previewing { stopPreview() }
            }
            .onChange(of: activeSource) { _, _ in
                // Swapping source mid-preview: the old media no longer
                // represents what Start will play.
                if previewing { stopPreview() }
            }
            .onDisappear {
                if previewing { stopPreview() }
            }
        } // NavigationStack
    }

    /// Fixed-width leading icon column, matching SettingsView's row style.
    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title2)
            .foregroundStyle(themeAccentColor)
            .frame(width: 36)
    }

    // MARK: - Sleep-sound rows

    /// Collapsible sleep-sound section. The header row shows the "Sleep Sound"
    /// title with the picked sound on the caption line (blank until picked) and
    /// a rotating chevron. Tapping the header toggles the inline bundled-sound
    /// list. Falls back to a placeholder row when no sound files were
    /// discovered so the radio row below stays reachable. (Previewing lives on
    /// the volume row, where it tests whichever source is active.)
    @ViewBuilder
    private var soundPickerRows: some View {
        if sounds.isEmpty {
            HStack(spacing: 12) {
                rowIcon("waveform.slash")
                Text("No sleep sounds found")
                    .font(.system(size: 17 * scale, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else {
            // Header
            HStack(spacing: 12) {
                rowIcon("moon.zzz.fill")
                headerTextBlock(title: "Sleep Sound", value: soundValueText)
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
                ForEach(sounds, id: \.self) { name in
                    Button {
                        applySoundSelection(name)
                    } label: {
                        HStack(spacing: 8) {
                            Text(SleepSoundManager.displayName(for: name))
                                .foregroundStyle(.primary)
                            Spacer()
                            if activeSource == .sound && selectedSound == name {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(themeAccentColor)
                            }
                        }
                        .padding(.leading, 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                }

                // Edit / Add for custom sleep sounds, mirroring the alarm tone
                // section's pair and the radio section's Edit / New.
                Button {
                    if previewing { stopPreview() }
                    soundManagerMode = .edit
                } label: {
                    actionRowLabel("Edit Custom Sounds", icon: "pencil")
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)

                Button {
                    if previewing { stopPreview() }
                    soundManagerMode = .add
                } label: {
                    actionRowLabel("Add Custom Sound", icon: "plus")
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
        }
    }

    // MARK: - List action styling

    /// Blue icon + blue text — reads as an action, not a pickable item.
    /// (Expanded lists hide their row separators; the blue accent alone
    /// distinguishes actions from pickable items.)
    private func actionRowLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            rowIcon(icon)
            Text(title)
                .foregroundStyle(themeAccentColor)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    // MARK: - Radio rows

    /// Collapsible radio section mirroring the sleep-sound row. The header shows
    /// "Radio" with the picked station on the caption line (blank until picked)
    /// and a rotating chevron. Expanding reveals the favorite stations (checkmark
    /// only while radio is the active source) plus Edit Stations / New Station
    /// rows that present the fullScreenCover browser. Picking any station makes
    /// radio the active source and collapses the list.
    @ViewBuilder
    private var radioPickerRows: some View {
        let favorites = RadioPlayerManager.shared.favorites

        // Header
        HStack(spacing: 12) {
            rowIcon("radio")
            headerTextBlock(title: "Radio", value: radioValueText)
            Spacer()
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(radioExpanded ? 0 : -90))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // Expanded list is separator-free; hide the header's own line too.
        .listRowSeparator(radioExpanded ? .hidden : .automatic)
        .onTapGesture {
            withAnimation(.smooth(duration: 0.25)) {
                radioExpanded.toggle()
                if radioExpanded { soundExpanded = false }
            }
        }

        if radioExpanded {
            // Favorites, plus the current station if it isn't a favorite so its
            // checkmark stays reachable.
            let stations: [RadioStation] = {
                if activeSource == .radio, let current = selectedStation,
                   !favorites.contains(where: { $0.id == current.id }) {
                    return favorites + [current]
                }
                return favorites
            }()

            ForEach(stations) { station in
                Button {
                    applyStationSelection(station)
                } label: {
                    HStack(spacing: 8) {
                        Text(station.name)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        if activeSource == .radio && selectedStation?.id == station.id {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(themeAccentColor)
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
                stationBrowserMode = .edit
            } label: {
                actionRowLabel("Edit Stations", icon: "pencil")
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)

            // New Station — opens the normal browser.
            Button {
                stationBrowserMode = .new
            } label: {
                actionRowLabel("New Station", icon: "plus")
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - Sound preview

    /// Resolves the playable URL for a sleep sound — custom, imported, then
    /// bundled — mirroring SleepSoundManager's private resolver.
    private func sleepSoundURL(for name: String) -> URL? {
        if name.hasPrefix("custom_") {
            return CustomSoundManager.shared.fileURL(forID: name)
        }
        let imported = SleepSoundManager.importedSoundsDirectory.appendingPathComponent("\(name).m4a")
        if FileManager.default.fileExists(atPath: imported.path) {
            return imported
        }
        return Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "Sleep Sounds")
            ?? Bundle.main.url(forResource: name, withExtension: "m4a")
    }

    /// Preview whichever source is active at the slider volume. Sounds loop
    /// through an AVAudioPlayer; radio streams through a bare AVPlayer —
    /// never the managers' real playback, which would tear down whatever is
    /// already running.
    private func togglePreview() {
        if previewing {
            stopPreview()
            return
        }
        switch activeSource {
        case .sound: startSoundPreview()
        case .radio: startRadioPreview()
        case .none: break
        }
    }

    private func startSoundPreview() {
        guard !selectedSound.isEmpty, let url = sleepSoundURL(for: selectedSound) else { return }
        do {
            try AppAudioSession.setCategory(.playback, mode: .default)
            try AppAudioSession.setActive(true)
            previewTookSession = true
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = Float(volume)
            player.play()
            previewPlayer = player
            previewing = true
        } catch {
            print("❌ Sleep sound preview failed: \(error)")
        }
    }

    private func startRadioPreview() {
        guard let station = selectedStation, let url = URL(string: station.streamURL) else { return }
        do {
            try AppAudioSession.setCategory(.playback, mode: .default)
            try AppAudioSession.setActive(true)
            previewTookSession = true
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

            let player = AVPlayer(url: url)
            player.volume = Float(volume)
            player.play()
            radioPreviewPlayer = player
            previewing = true
            radioPreviewConnecting = true
            radioPreviewObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.5, preferredTimescale: 10),
                queue: .main
            ) { time in
                if time.seconds > 0 { radioPreviewConnecting = false }
            }
        } catch {
            print("❌ Radio preview failed: \(error)")
        }
    }

    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        if let token = radioPreviewObserver {
            radioPreviewPlayer?.removeTimeObserver(token)
            radioPreviewObserver = nil
        }
        radioPreviewConnecting = false
        radioPreviewPlayer?.pause()
        radioPreviewPlayer = nil
        previewing = false
        releasePreviewSession()
    }

    /// Hands the shared audio session back to whoever owned it before the
    /// preview. No-op if no preview claimed it.
    private func releasePreviewSession() {
        guard previewTookSession else { return }
        previewTookSession = false

        if SleepSoundManager.shared.isActive {
            SleepSoundManager.shared.reassertSessionOwnership()
        } else if RadioPlayerManager.shared.ownsAudioSession {
            RadioPlayerManager.shared.reassertSessionOwnership()
        } else {
            try? AppAudioSession.setActive(false, options: .notifyOthersOnDeactivation)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            if DeviceSettings.shared.keepAliveNeeded {
                Task.detached(priority: .utility) {
                    await BackgroundAudioKeepAlive.shared.startAsync()
                }
            }
        }
    }

    /// Persist last-used preferences — shared by Save and Start.
    private func persistPreferences() {
        settings.lastSleepSoundVolume = volume
        settings.lastSleepDurationMinutes = selectedDurationMinutes
        settings.lastSleepFadeOutMinutes = fadeOutMinutes
        settings.lastSleepUntilNextAlarm = untilNextAlarm
        // Remember which source was used so the sheet reopens on it. The picked
        // station itself is persisted by RadioPlayerManager (lastStation).
        settings.lastSleepSourceWasRadio = (activeSource == .radio)
        if activeSource == .sound, !selectedSound.isEmpty {
            settings.lastSleepSoundName = selectedSound
        }
    }

    private func startSleepSounds() {
        // Any running preview must stop before real playback claims the session.
        if previewing { stopPreview() }

        persistPreferences()

        if activeSource == .radio {
            guard let station = selectedStation else { return }
            let manager = RadioPlayerManager.shared
            manager.setVolume(Float(volume))
            // The picked station is already streaming (playing before the
            // sheet opened, or handed off from the browser preview) — keep
            // it going. Timer changes never need a radio restart; the timer
            // just re-arms around the live stream.
            if manager.isActive && manager.currentStation?.id == station.id {
                if manager.state == .paused { manager.resume() }
            } else {
                manager.play(station: station)
            }
            // Same duration semantics as sleep sounds; nil end = indefinite.
            manager.setSleepTimer(end: currentEndDate(), fadeOut: TimeInterval(fadeOutMinutes * 60))
            // Sleep-sound sessions report themselves from SleepSoundManager;
            // radio sessions are started here, so report this one here.
            Analytics.shared.log(.sleepSessionStarted(source: .radio, timerMinutes: currentTimerMinutes()))
            dismiss()
            return
        }

        // Same sound already running and no timer/fade change — nothing
        // requires a restart; just sync volume (and resume if paused).
        let engine = SleepSoundManager.shared
        if engine.isActive && engine.selectedSoundName == selectedSound && !timerDirty {
            engine.setVolume(volume)
            if engine.state == .paused { engine.resume() }
            dismiss()
            return
        }

        engine.start(
            soundName: selectedSound,
            volume: volume,
            mode: currentMode(),
            fadeOutDuration: TimeInterval(fadeOutMinutes * 60)
        )

        dismiss()
    }

    // MARK: - Timer helpers (shared by Start and live mode)

    /// The engine playback mode implied by the current timer settings.
    private func currentMode() -> SleepSoundMode {
        if untilNextAlarm {
            if let date = nextAlarmDate { return .until(date) }
            return .indefinite
        }
        return .duration(Double(selectedDurationMinutes) * 60)
    }

    /// Timer length implied by the current settings, in whole minutes
    /// (0 = indefinite). Analytics only.
    private func currentTimerMinutes() -> Int {
        guard let end = currentEndDate() else { return 0 }
        return max(0, Int(end.timeIntervalSinceNow / 60))
    }

    /// Wall-clock end date implied by the current timer settings; nil = indefinite.
    private func currentEndDate() -> Date? {
        untilNextAlarm
            ? nextAlarmDate
            : Date().addingTimeInterval(Double(selectedDurationMinutes) * 60)
    }

    // MARK: - Live mode

    /// True while the running session is actually playing (not paused). Reads
    /// the @Observable managers so the view tracks play/pause changes made
    /// elsewhere (e.g. the row's pause button).
    private var liveIsPlaying: Bool {
        if RadioPlayerManager.shared.isActive {
            return RadioPlayerManager.shared.state == .playing
        }
        return SleepSoundManager.shared.state == .playing
    }

    /// Now Playing card mirroring the radio browser's: artwork (favicon for a
    /// station, moon glyph for a sleep sound) under the same dark overlay with
    /// a waveform/pause icon, name + caption, and a pause/resume button.
    private var liveNowPlayingCard: some View {
        let radio = RadioPlayerManager.shared
        let radioActive = radio.isActive
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(width: 44, height: 44)
                if radioActive, let url = radio.currentStation?.secureFaviconURL {
                    RadioFaviconView(url: url)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if radioActive {
                    Image(systemName: "radio")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundStyle(themeAccentColor)
                }
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 44, height: 44)
                Image(systemName: liveIsPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(radioActive
                     ? (radio.currentStation?.name ?? "Radio")
                     : SleepSoundManager.displayName(for: SleepSoundManager.shared.selectedSoundName))
                    .font(.system(size: 17 * scale, weight: .semibold))
                    .lineLimit(1)
                Text(radioActive
                     ? (radio.currentStation?.subtitle ?? "Radio")
                     : "Sleep Sound")
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                toggleLivePlayback()
            } label: {
                // This card fronts whichever source is live, so the spinner
                // only applies when radio is the one playing — sleep sounds
                // are local files with no connect step.
                RadioPlayCircle(
                    systemImage: liveIsPlaying ? "pause.fill" : "play.fill",
                    isConnecting: RadioPlayerManager.shared.isActive
                        && RadioPlayerManager.shared.isConnecting,
                    diameter: 34,
                    fill: .solid(themeAccentColor)
                )
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func toggleLivePlayback() {
        let radio = RadioPlayerManager.shared
        if radio.isActive {
            radio.state == .playing ? radio.pause() : radio.resume()
        } else {
            let sounds = SleepSoundManager.shared
            sounds.state == .playing ? sounds.pause() : sounds.resume()
        }
    }

    /// Seeds sheet state from whatever is currently playing so live mode opens
    /// reflecting the real session (radio takes precedence if it's active).
    private func seedLiveState() {
        guard liveMode else {
            // Non-live start flow: prefill the last-used source so the sheet
            // opens ready to Start instead of blank-until-picked. Radio and
            // sleep sounds share this sheet, so restore whichever the user last
            // picked — radio if that was last and a station is available to
            // preselect (selectedStation seeds from RadioPlayerManager.lastStation
            // in init), otherwise the last sleep sound if it's still present.
            if settings.lastSleepSourceWasRadio, selectedStation != nil {
                activeSource = .radio
            } else if !settings.lastSleepSoundName.isEmpty,
                      sounds.contains(settings.lastSleepSoundName) {
                activeSource = .sound
            }
            return
        }
        let radio = RadioPlayerManager.shared
        if radio.isActive {
            activeSource = .radio
            if let station = radio.currentStation { selectedStation = station }
            volume = Double(radio.volume)
        } else {
            activeSource = .sound
            let name = SleepSoundManager.shared.selectedSoundName
            if !name.isEmpty { selectedSound = name }
            volume = SleepSoundManager.shared.volume
        }
    }

    /// Applies a sound selection to the UI, and in live mode to playback:
    /// swap the running sound, or start sleep sounds (stopping radio) if radio
    /// was the active source.
    private func applySoundSelection(_ name: String) {
        withAnimation(.smooth(duration: 0.25)) {
            selectedSound = name
            activeSource = .sound
            soundExpanded = false
        }
        guard liveMode else { return }
        if SleepSoundManager.shared.isActive {
            SleepSoundManager.shared.changeSound(to: name)
        } else {
            SleepSoundManager.shared.start(
                soundName: name,
                volume: volume,
                mode: currentMode(),
                fadeOutDuration: TimeInterval(fadeOutMinutes * 60)
            )
        }
    }

    /// Applies a station selection to the UI, and in live mode to playback:
    /// start the station (stopping any sleep sound) and re-arm its sleep timer
    /// from the sheet's current timer settings.
    private func applyStationSelection(_ station: RadioStation) {
        withAnimation(.smooth(duration: 0.25)) {
            selectedStation = station
            activeSource = .radio
            radioExpanded = false
        }
        guard liveMode else { return }
        let manager = RadioPlayerManager.shared
        manager.setVolume(Float(volume))
        // A station handed off from the browser preview (or re-picked) is
        // already streaming — restarting it would just interrupt the audio.
        if !(manager.isActive && manager.currentStation?.id == station.id) {
            manager.play(station: station)
        }
        manager.setSleepTimer(end: currentEndDate(), fadeOut: TimeInterval(fadeOutMinutes * 60))
    }

    /// Live-mode Start: persist preferences, then apply the timer/fade
    /// settings to the running session. Radio re-arms without interruption;
    /// sleep sounds have no re-time API, so a restart happens automatically —
    /// but ONLY when the timer settings actually changed (`timerDirty`).
    private func liveStart() {
        let radio = RadioPlayerManager.shared
        let soundEngine = SleepSoundManager.shared
        // Session ended while the sheet was open — fall back to a full start.
        guard radio.isActive || soundEngine.isActive else {
            startSleepSounds()
            return
        }
        persistPreferences()
        if radio.isActive {
            radio.setSleepTimer(end: currentEndDate(), fadeOut: TimeInterval(fadeOutMinutes * 60))
        } else if timerDirty {
            soundEngine.start(
                soundName: selectedSound,
                volume: volume,
                mode: currentMode(),
                fadeOutDuration: TimeInterval(fadeOutMinutes * 60)
            )
        }
        dismiss()
    }
}

