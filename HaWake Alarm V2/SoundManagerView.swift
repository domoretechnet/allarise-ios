//
//  SoundManagerView.swift
//  HaWake Alarm V2
//
//  Settings page for managing custom alarm tones and sleep sounds.
//

import AVFoundation
import MediaPlayer
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SoundManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }
    @State private var selectedCategory: CustomSound.Category
    /// Single-purpose mode: no category tabs and no built-in list, just the
    /// CUSTOM sounds for `selectedCategory` and their storage line. Sleep
    /// Sounds' "Add Custom Sound" row opens this — someone who tapped that is
    /// there to add a custom sleep sound, not to browse built-in alarm tones.
    private let customOnly: Bool
    /// Opens the file importer as soon as this screen appears. What separates an
    /// "Add Custom Tone" entry point from an "Edit Custom Tones" one, since both
    /// land here: Add gets you straight to picking a file, Edit gets you the
    /// list. Same split as the radio browser's New Station / Edit Stations.
    private let autoImport: Bool
    /// One-shot guard so returning from the importer doesn't reopen it.
    @State private var didAutoImport = false

    /// Callers can land on a specific category — the Sleep Sounds page opens
    /// straight into sleep sounds; Settings keeps the alarm-tone default.
    init(initialCategory: CustomSound.Category = .alarmTone,
         customOnly: Bool = false,
         autoImport: Bool = false) {
        _selectedCategory = State(initialValue: initialCategory)
        self.customOnly = customOnly
        self.autoImport = autoImport
    }

    @State private var showingImporter = false
    @State private var showingNamePrompt = false
    @State private var pendingImportURL: URL?
    @State private var importName = ""
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var renamingSound: CustomSound?
    @State private var renameText = ""
    @State private var previewingID: String?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var previewDelegate = PreviewDelegate()
    /// True only while a preview has actually claimed the audio session.
    /// Without it, onDisappear's stopPreview() deactivated the app-wide
    /// session on every close of this screen — silencing an active sleep
    /// sound engine that never recovers (our own setActive(false) sends no
    /// interruption notification, so SleepSoundManager can't tell).
    @State private var previewTookSession = false
    @State private var showingPaywall = false

    private var manager: CustomSoundManager { .shared }
    private var storeManager: StoreManager { .shared }

    /// Begins the import flow. Custom sounds are free in the support model, so this no
    /// longer gates behind Pro — every user reaches the file importer directly.
    private func requestImport() {
        showingImporter = true
    }

    var body: some View {
        List {
            if !customOnly {
                categoryPicker
            }

            if selectedCategory == .alarmTone {
                if !customOnly { builtInAlarmTonesSection }
                customAlarmTonesSection
                alarmStorageSection
            } else {
                if !customOnly { builtInSleepSoundsSection }
                customSleepSoundsSection
                sleepStorageSection
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("Name Your Sound", isPresented: $showingNamePrompt) {
            TextField("Sound name", text: $importName)
            Button("Import") { performImport() }
            Button("Cancel", role: .cancel) {
                pendingImportURL = nil
                importName = ""
            }
        } message: {
            Text(selectedCategory == .alarmTone
                 ? "Enter a name for this alarm tone. Letters, numbers, spaces, underscores, and hyphens only."
                 : "Enter a name for this sleep sound.")
        }
        .alert("Rename Sound", isPresented: Binding(
            get: { renamingSound != nil },
            set: { if !$0 { renamingSound = nil } }
        )) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                if let sound = renamingSound {
                    do {
                        try manager.renameSound(id: sound.id, newName: renameText)
                    } catch {
                        errorMessage = error.localizedDescription
                        showingError = true
                    }
                }
                renamingSound = nil
            }
            Button("Cancel", role: .cancel) { renamingSound = nil }
        } message: {
            Text("Letters, numbers, spaces, underscores, and hyphens only (1-64 chars).")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let msg = errorMessage {
                Text(msg)
            }
        }
        .sheet(isPresented: $showingPaywall) {
            ProPaywallView(storeManager: storeManager)
        }
        .onAppear {
            // A beat after the push settles, so the importer slides over a
            // drawn screen rather than racing the navigation transition.
            guard autoImport, !didAutoImport else { return }
            didAutoImport = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { requestImport() }
        }
        .onDisappear {
            stopPreview()
        }
    }

    /// The scoped version has NO page title — with a single section on screen,
    /// a nav title and a section header would say the same thing twice, so the
    /// section header carries the full name instead (see `customSectionHeader`).
    private var navigationTitle: String {
        customOnly ? "" : "Sound Manager"
    }

    /// "Custom" inside the full manager, where the category tabs above already
    /// say which kind; the full name when this section IS the screen.
    private var customSectionHeader: String {
        guard customOnly else { return "Custom" }
        return selectedCategory == .alarmTone ? "Custom Alarm Tones" : "Custom Sleep Sounds"
    }

    // MARK: - Category Picker

    /// The app's shared accent tiles rather than a stock segmented picker, which
    /// was both a different height from every other chooser in the app and
    /// silently dropped the category glyphs.
    private var categoryPicker: some View {
        Section {
            AccentSegmentRow {
                AccentSegmentTile(
                    title: "Alarm Tones",
                    systemImage: "bell.fill",
                    isSelected: selectedCategory == .alarmTone,
                    accent: accent,
                    action: { selectedCategory = .alarmTone }
                )
                AccentSegmentTile(
                    title: "Sleep Sounds",
                    systemImage: "moon.zzz.fill",
                    isSelected: selectedCategory == .sleepSound,
                    accent: accent,
                    action: { selectedCategory = .sleepSound }
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    // MARK: - Built-in Alarm Tones

    private var builtInAlarmTonesSection: some View {
        Section {
            let builtIn = AlarmSoundManager.shared.getAllSounds().filter { !$0.id.hasPrefix("custom_") }
            ForEach(builtIn) { sound in
                soundRow(title: sound.displayName, id: sound.id, isCustom: false) {
                    if let url = sound.fileURL { previewSound(url: url, id: sound.id) }
                }
                .moveDisabled(true)
                .deleteDisabled(true)
            }
        } header: {
            Text("Built-in")
        }
    }

    // MARK: - Custom Alarm Tones

    private var customAlarmTonesSection: some View {
        Section {
            let tones = manager.alarmTones()
            if tones.isEmpty {
                Text("No custom alarm tones yet")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .moveDisabled(true)
                    .deleteDisabled(true)
            } else {
                ForEach(tones) { sound in
                    soundRow(title: sound.name, id: sound.id, isCustom: true) {
                        let url = manager.fileURL(for: sound)
                        previewSound(url: url, id: sound.id)
                    }


                }
                .onMove { from, to in
                    manager.reorderSounds(category: .alarmTone, fromOffsets: from, toOffset: to)
                }
                .onDelete { offsets in
                    let tones = manager.alarmTones()
                    for index in offsets {
                        let sound = tones[index]
                        let affected = manager.alarmsUsingSoundID(sound.id, container: AlarmWindowManager.shared.modelContainer)
                        if !affected.isEmpty {
                            errorMessage = "\"\(sound.name)\" is used by \(affected.count) alarm(s). Remove it from those alarms first."
                            showingError = true
                            return
                        }
                        manager.deleteSound(id: sound.id)
                    }
                }
            }
        } header: {
            HStack {
                Text(customSectionHeader)
                Spacer()
                Button {
                    requestImport()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(accent)
                        .clipShape(Circle())
                }
            }
            .padding(.bottom, 4)
        } footer: {
            Text("Import .m4a, .mp3, .wav, .aiff, .caf, .flac, or .aac files. Alarm tones are converted to WAV for notification compatibility (max 10 MB / ~1 min). Tap a name to rename.")
        }
    }

    // MARK: - Built-in Sleep Sounds

    private var builtInSleepSoundsSection: some View {
        Section {
            let builtIn = SleepSoundManager.availableSounds().filter { !$0.hasPrefix("custom_") }
            ForEach(builtIn, id: \.self) { name in
                soundRow(title: SleepSoundManager.displayName(for: name), id: name, isCustom: false) {
                    if let url = sleepSoundURL(for: name) { previewSound(url: url, id: name) }
                }
                .moveDisabled(true)
                .deleteDisabled(true)
            }
        } header: {
            Text("Built-in")
        }
    }

    // MARK: - Custom Sleep Sounds

    private var customSleepSoundsSection: some View {
        Section {
            let sleepSounds = manager.sleepSounds()
            if sleepSounds.isEmpty {
                Text("No custom sleep sounds yet")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .moveDisabled(true)
                    .deleteDisabled(true)
            } else {
                ForEach(sleepSounds) { sound in
                    soundRow(title: sound.name, id: sound.id, isCustom: true) {
                        let url = manager.fileURL(for: sound)
                        previewSound(url: url, id: sound.id)
                    }


                }
                .onMove { from, to in
                    manager.reorderSounds(category: .sleepSound, fromOffsets: from, toOffset: to)
                }
                .onDelete { offsets in
                    let sleepSounds = manager.sleepSounds()
                    for index in offsets {
                        manager.deleteSound(id: sleepSounds[index].id)
                    }
                }
            }
        } header: {
            HStack {
                Text(customSectionHeader)
                Spacer()
                Button {
                    requestImport()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(accent)
                        .clipShape(Circle())
                }
            }
            .padding(.bottom, 4)
        } footer: {
            Text("Import audio files up to 100 MB each. Tap a name to rename.")
        }
    }

    // MARK: - Storage Sections

    private var alarmStorageSection: some View {
        Section {
            let used = manager.totalAlarmToneBytes()
            storageRow(used: used, label: "Alarm Tones")
        } header: {
            Text("Storage")
        } footer: {
            Text("Space used by custom alarm tones on this device.")
        }
    }

    private var sleepStorageSection: some View {
        Section {
            let used = manager.totalSleepSoundBytes()
            storageRow(used: used, label: "Sleep Sounds")
        } header: {
            Text("Storage")
        } footer: {
            Text("Space used by custom sleep sounds on this device.")
        }
    }

    // MARK: - Reusable Views

    @ViewBuilder
    private func soundRow(title: String, id: String, isCustom: Bool, onPreview: @escaping () -> Void) -> some View {
        HStack {
            if isCustom, let sound = manager.sound(byID: id) {
                Button {
                    renamingSound = sound
                    renameText = sound.name
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(formatFileSize(sound.fileSizeBytes) + " \u{2022} " + formatDuration(sound.durationSeconds))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Fill the row so the blank space between the name and
                    // the play button is tappable too (plain buttons only
                    // hit-test their visible content).
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(title)
                    .font(.body)
            }

            Spacer()

            Button {
                if previewingID == id {
                    stopPreview()
                } else {
                    onPreview()
                }
            } label: {
                Image(systemName: previewingID == id ? "stop.fill" : "play.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func storageRow(used: Int64, label: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(formatFileSize(used))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Import Flow

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            let ext = url.pathExtension.lowercased()
            guard AudioConverter.supportedExtensions.contains(ext) else {
                errorMessage = "Unsupported format: .\(ext)"
                showingError = true
                return
            }

            pendingImportURL = url
            let rawName = url.deletingPathExtension().lastPathComponent
            importName = CustomSound.sanitizedName(from: rawName)
            showingNamePrompt = true

        case .failure(let error):
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func performImport() {
        guard let url = pendingImportURL else { return }
        defer {
            pendingImportURL = nil
            importName = ""
        }

        do {
            switch selectedCategory {
            case .alarmTone:
                try manager.importAlarmTone(from: url, name: importName)
                Analytics.shared.log(.customAlarmToneImported)
            case .sleepSound:
                try manager.importSleepSound(from: url, name: importName)
                Analytics.shared.log(.customSleepSoundImported)
            }
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    // MARK: - Preview

    private func previewSound(url: URL, id: String) {
        stopPreview()
        do {
            try AppAudioSession.setCategory(.playback, mode: .default)
            try AppAudioSession.setActive(true)
            previewTookSession = true
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = 0
            previewDelegate.onFinish = { [self] in
                previewingID = nil
                audioPlayer = nil
                releasePreviewSession()
            }
            player.delegate = previewDelegate
            player.play()
            audioPlayer = player
            previewingID = id
        } catch {
            print("❌ Preview failed: \(error)")
        }
    }

    private func stopPreview() {
        audioPlayer?.stop()
        audioPlayer = nil
        previewingID = nil
        releasePreviewSession()
    }

    /// Hands the shared audio session back to whoever owned it before the
    /// preview. No-op if no preview claimed the session (plain open/close of
    /// this screen must not touch audio at all).
    private func releasePreviewSession() {
        guard previewTookSession else { return }
        previewTookSession = false

        if SleepSoundManager.shared.isActive {
            // Sleep sounds own the session — deactivating would silence the
            // engine with no interruption notification to recover from.
            // Reassert their session and Now Playing info instead.
            SleepSoundManager.shared.reassertSessionOwnership()
        } else if RadioPlayerManager.shared.ownsAudioSession {
            // Same rule for an active radio stream.
            RadioPlayerManager.shared.reassertSessionOwnership()
        } else {
            try? AppAudioSession.setActive(false, options: .notifyOthersOnDeactivation)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            // The keep-alive's silent player died with the session; restart it
            // now rather than waiting up to 30s for its health-check timer.
            if DeviceSettings.shared.keepAliveNeeded {
                Task.detached(priority: .utility) {
                    await BackgroundAudioKeepAlive.shared.startAsync()
                }
            }
        }
    }

    // MARK: - Helpers

    private func sleepSoundURL(for name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "Sleep Sounds") {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: "m4a")
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }
}

// MARK: - Preview Delegate

private class PreviewDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onFinish?()
        }
    }
}
