//
//  CustomSoundManager.swift
//  HaWake Alarm V2
//
//  Manages import, storage, deletion, and metadata of user-imported custom sounds.
//  Alarm tones are converted to WAV and copied to Library/Sounds/ for notification access.
//  Sleep sounds are stored as-is (m4a preferred).
//

import AVFoundation
import Foundation
import SwiftData
import SwiftUI

final class CustomSoundManager {
    static let shared = CustomSoundManager()

    // MARK: - Size Limits

    static let alarmToneMaxBytes: Int64 = 10_000_000        // 10 MB per alarm tone (~1 min WAV)
    static let alarmToneTotalMaxBytes: Int64 = 2_000_000_000 // 2 GB total for alarm tones
    static let sleepSoundMaxBytes: Int64 = 100_000_000     // 100 MB per sleep sound
    static let sleepSoundTotalMaxBytes: Int64 = 2_000_000_000 // 2 GB total for sleep sounds

    // MARK: - iCloud Container

    private static let cloudLock = NSLock()
    nonisolated(unsafe) private static var _cachedCloudURL: URL?
    nonisolated(unsafe) private static var _cloudQueried = false

    /// The iCloud ubiquity container URL, cached after first access.
    ///
    /// Returns `nil` if iCloud is unavailable — user not signed in, iCloud Drive
    /// disabled for the app, entitlement mismatch, or offline on first launch.
    /// Callers should treat nil as a signal to fall back to local Documents storage.
    ///
    /// The first call can block briefly while the system sets up the container
    /// handle; subsequent calls are fast. We cache even the nil result to avoid
    /// re-querying on every access.
    nonisolated static var cloudContainerURL: URL? {
        cloudLock.lock()
        defer { cloudLock.unlock() }
        if _cloudQueried { return _cachedCloudURL }
        _cloudQueried = true
        _cachedCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)
        if let url = _cachedCloudURL {
            print("☁️ CustomSoundManager: iCloud container ready at \(url.path)")
        } else {
            print("⚠️ CustomSoundManager: iCloud container unavailable — using local storage (sounds will not survive reinstall)")
        }
        return _cachedCloudURL
    }

    /// True when custom sound storage is backed by iCloud Drive. Sounds stored
    /// in iCloud survive app reinstall and sync across the user's devices.
    static var isCloudBacked: Bool {
        cloudContainerURL != nil
    }

    // MARK: - Directories

    /// The current storage base directory — iCloud Documents/CustomSounds if
    /// iCloud is available, otherwise the local sandbox Documents/CustomSounds.
    /// iCloud storage persists across reinstalls; local storage does not.
    private static var baseDirectory: URL {
        if let cloudURL = cloudContainerURL {
            return cloudURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("CustomSounds", isDirectory: true)
        }
        return localBaseDirectory
    }

    /// Always-local base directory (sandbox `Documents/CustomSounds`). Used as
    /// the fallback when iCloud is unavailable, and as the migration source
    /// when moving an existing local-only library into iCloud.
    private static var localBaseDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("CustomSounds", isDirectory: true)
    }

    static var alarmTonesDirectory: URL {
        baseDirectory.appendingPathComponent("AlarmTones", isDirectory: true)
    }

    static var sleepSoundsDirectory: URL {
        baseDirectory.appendingPathComponent("SleepSounds", isDirectory: true)
    }

    private static var metadataURL: URL {
        baseDirectory.appendingPathComponent("metadata.json")
    }

    /// Library/Sounds/ — where iOS looks for custom notification sounds.
    /// Always local (not iCloud-backed) because `UNNotificationSound` needs
    /// the file to be immediately available when an alarm fires. Acts as a
    /// mirror of the iCloud alarm tones, refreshed eagerly on init.
    private static var librarySoundsDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Sounds", isDirectory: true)
    }

    // MARK: - State

    private(set) var sounds: [CustomSound] = []

    private init() {
        // All first-launch work lives in `bootstrap()` and runs off the main
        // thread. Previously this ran synchronously inside the `static let
        // shared` lazy initializer — which executes on whatever thread first
        // touches the singleton (almost always the main thread, inside a
        // dispatch_once). On devices with slow iCloud daemon response
        // (thermally-throttled, fresh reinstall with pending downloads, etc.)
        // the 20-second launch watchdog could fire before init returned,
        // producing 0x8BADF00D crashes on cold launch.
    }

    /// Performs iCloud probe, directory setup, migrations, metadata load, and
    /// alarm-tone mirroring — all off the main thread. Must be called once
    /// from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// Until bootstrap completes, `sounds` is empty and file-system accessors
    /// transparently resolve to local storage (because `cloudContainerURL`
    /// hasn't been queried yet). That window is short — the only practical
    /// consequence is that a user who opens SoundManagerView in the first
    /// ~1–2 seconds of a cold launch may see their custom list populate
    /// after a brief flash.
    /// The one-time bootstrap work, retained so out-of-process entry points
    /// (Siri / App Intents cold-launching straight into an intent) can await
    /// completion instead of racing the detached load and seeing an empty
    /// custom-sound list.
    private var bootstrapTask: Task<Void, Never>?

    /// Awaits bootstrap completion, kicking it off if it hasn't started
    /// (e.g. an intent runs before AppDelegate got there). Call from any
    /// path that needs `sounds` to be authoritative — Siri entity queries,
    /// intent perform() bodies.
    func ensureBootstrapped() async {
        if bootstrapTask == nil { bootstrap() }
        await bootstrapTask?.value
    }

    func bootstrap() {
        guard bootstrapTask == nil else { return }
        bootstrapTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = Self.cloudContainerURL        // may block on `bird` daemon
            self.ensureDirectories()
            self.migrateLocalToCloudIfNeeded()
            let loaded = Self.loadMetadataFromDisk()
            let migrated = self.migrateExistingSleepSounds(existing: loaded)
            let didMigrate = migrated.count != loaded.count
            if didMigrate {
                Self.writeMetadata(migrated)
            }
            self.mirrorAlarmTonesToLibrarySoundsIfNeeded(sounds: migrated)
            await MainActor.run {
                self.sounds = migrated
                // Invalidate the alarm-sound cache: getAllSounds() may have run
                // (and cached an EMPTY custom list) before bootstrap finished —
                // without this, a selected custom tone stays unresolvable for
                // the entire launch.
                AlarmSoundManager.shared.invalidateCache()
                if didMigrate {
                    HAIntegrationRouter.shared.publishAvailableSleepSounds(settings: DeviceSettings.shared)
                    HAIntegrationRouter.shared.publishAvailableAlarmSounds(settings: DeviceSettings.shared)
                }
                print("✅ CustomSoundManager: bootstrap complete (\(self.sounds.count) sound(s))")
            }
        }
    }

    // MARK: - Directory Setup

    private func ensureDirectories() {
        let fm = FileManager.default
        for dir in [Self.alarmTonesDirectory, Self.sleepSoundsDirectory, Self.librarySoundsDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - iCloud Migration

    /// One-time migration: moves any custom sounds stored in the local-only
    /// `Documents/CustomSounds` directory into the iCloud container. Runs on
    /// every init but is a no-op after the initial move.
    ///
    /// Only runs when iCloud is available AND the iCloud container doesn't
    /// already have content (to avoid clobbering real iCloud data with a stale
    /// local snapshot). If both locations have content we don't merge — we
    /// simply leave the local copies behind and trust the iCloud data, since
    /// iCloud is the canonical source of truth going forward.
    private func migrateLocalToCloudIfNeeded() {
        guard Self.isCloudBacked else { return }

        let fm = FileManager.default
        let localBase = Self.localBaseDirectory

        // No local data to migrate
        guard fm.fileExists(atPath: localBase.path) else { return }

        // If the iCloud container already has a metadata file, the user has
        // previously synced from a different device — don't overwrite it.
        if fm.fileExists(atPath: Self.metadataURL.path) {
            print("ℹ️ CustomSoundManager: iCloud metadata already exists; leaving legacy local data in place")
            return
        }

        let localAlarmTones = localBase.appendingPathComponent("AlarmTones", isDirectory: true)
        let localSleepSounds = localBase.appendingPathComponent("SleepSounds", isDirectory: true)
        let localMetadata = localBase.appendingPathComponent("metadata.json")

        var movedCount = 0

        // Move alarm tone files
        if let tones = try? fm.contentsOfDirectory(at: localAlarmTones, includingPropertiesForKeys: nil) {
            for file in tones {
                let dest = Self.alarmTonesDirectory.appendingPathComponent(file.lastPathComponent)
                do {
                    try fm.moveItem(at: file, to: dest)
                    movedCount += 1
                } catch {
                    print("⚠️ CustomSoundManager: failed to migrate alarm tone \(file.lastPathComponent): \(error)")
                }
            }
        }

        // Move sleep sound files
        if let sleepSounds = try? fm.contentsOfDirectory(at: localSleepSounds, includingPropertiesForKeys: nil) {
            for file in sleepSounds {
                let dest = Self.sleepSoundsDirectory.appendingPathComponent(file.lastPathComponent)
                do {
                    try fm.moveItem(at: file, to: dest)
                    movedCount += 1
                } catch {
                    print("⚠️ CustomSoundManager: failed to migrate sleep sound \(file.lastPathComponent): \(error)")
                }
            }
        }

        // Move metadata (if not already present in iCloud)
        if fm.fileExists(atPath: localMetadata.path) {
            try? fm.moveItem(at: localMetadata, to: Self.metadataURL)
            movedCount += 1
        }

        // Clean up now-empty local directories
        try? fm.removeItem(at: localAlarmTones)
        try? fm.removeItem(at: localSleepSounds)
        try? fm.removeItem(at: localBase)

        if movedCount > 0 {
            print("✅ CustomSoundManager: migrated \(movedCount) file(s) from local storage to iCloud")
        }
    }

    /// Ensures `Library/Sounds/` contains a local copy of every alarm tone in
    /// the library. Needed after a fresh install: iCloud has the master files
    /// but `Library/Sounds/` is empty. `UNNotificationSound` can't read iCloud
    /// placeholders, so we eagerly mirror them to the sandbox-local Library.
    ///
    /// For each missing file we kick off an iCloud download and then attempt
    /// the copy. If the download hasn't completed yet, the copy may fail
    /// silently; next launch will retry. During that window the affected
    /// alarms will play the system default notification sound as a fallback.
    private func mirrorAlarmTonesToLibrarySoundsIfNeeded(sounds: [CustomSound]) {
        let fm = FileManager.default
        let alarmTones = sounds.filter { $0.category == .alarmTone }
        guard !alarmTones.isEmpty else { return }

        var mirroredCount = 0
        for sound in alarmTones {
            let source = Self.alarmTonesDirectory.appendingPathComponent(sound.fileName)
            let dest = Self.librarySoundsDirectory.appendingPathComponent(sound.fileName)

            // Already mirrored
            if fm.fileExists(atPath: dest.path) { continue }

            // Trigger iCloud download if the source is a placeholder
            if Self.isCloudBacked {
                try? fm.startDownloadingUbiquitousItem(at: source)
            }

            // Best-effort copy. If the source isn't downloaded yet, this fails
            // silently and the next launch will retry.
            do {
                try fm.copyItem(at: source, to: dest)
                mirroredCount += 1
            } catch {
                print("⚠️ CustomSoundManager: Library/Sounds/ mirror pending for \(sound.fileName) (iCloud downloading): \(error.localizedDescription)")
            }
        }

        if mirroredCount > 0 {
            print("🔁 CustomSoundManager: mirrored \(mirroredCount) alarm tone(s) to Library/Sounds/ for notification access")
        }
    }

    // MARK: - Metadata Persistence

    private static func loadMetadataFromDisk() -> [CustomSound] {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([CustomSound].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.sortOrder < $1.sortOrder }
    }

    private static func writeMetadata(_ sounds: [CustomSound]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(sounds) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    /// Persist the library and re-publish BOTH inventory topics.
    ///
    /// Every mutation (import, rename, delete, reorder) funnels through here, and
    /// a single call site can't know which category changed — publishing both is
    /// two retained messages, and a stale dropdown is a silent no-op for whoever
    /// picks from it.
    private func saveMetadata() {
        Self.writeMetadata(sounds)
        HAIntegrationRouter.shared.publishAvailableSleepSounds(settings: DeviceSettings.shared)
        HAIntegrationRouter.shared.publishAvailableAlarmSounds(settings: DeviceSettings.shared)
    }

    // MARK: - Import

    /// Imports an audio file as a custom alarm tone. Converts to WAV and copies to Library/Sounds/.
    @discardableResult
    func importAlarmTone(from sourceURL: URL, name: String) throws -> CustomSound {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        // Validate name
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard CustomSound.isValidMQTTName(trimmedName) else {
            throw ImportError.invalidName
        }
        guard !sounds.contains(where: { $0.name.lowercased() == trimmedName.lowercased() }) else {
            throw ImportError.duplicateName
        }

        // Check source file size (reject very large files to prevent OOM during conversion)
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let sourceSize = (attrs[.size] as? Int64) ?? 0
        if sourceSize > Self.alarmToneMaxBytes * 5 {
            throw ImportError.fileTooLarge
        }

        // Check total alarm tone storage
        if totalAlarmToneBytes() + sourceSize > Self.alarmToneTotalMaxBytes {
            throw ImportError.storageLimitExceeded
        }

        // Check duration before converting — alarm tones over 30s won't play as notifications
        let sourceDuration = Self.readDuration(url: sourceURL)
        if sourceDuration > 90 {
            throw ImportError.tooLong(seconds: sourceDuration)
        }

        let soundID = "custom_\(UUID().uuidString)"
        let outputURL = Self.alarmTonesDirectory.appendingPathComponent("\(soundID).wav")

        // Convert to WAV
        _ = try AudioConverter.convertToWAV(source: sourceURL, outputURL: outputURL)

        // Copy to Library/Sounds/ for notification access
        let notifURL = Self.librarySoundsDirectory.appendingPathComponent("\(soundID).wav")
        try? FileManager.default.removeItem(at: notifURL)
        try FileManager.default.copyItem(at: outputURL, to: notifURL)

        // Read duration
        let duration = Self.readDuration(url: outputURL)

        // Get file size
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (fileAttrs[.size] as? Int64) ?? 0

        let sound = CustomSound(
            id: soundID,
            name: trimmedName,
            category: .alarmTone,
            fileExtension: "wav",
            importDate: Date(),
            fileSizeBytes: fileSize,
            durationSeconds: duration,
            sortOrder: (sounds.filter { $0.category == .alarmTone }.map(\.sortOrder).max() ?? -1) + 1
        )

        sounds.append(sound)
        saveMetadata()

        // Invalidate AlarmSoundManager cache
        AlarmSoundManager.shared.invalidateCache()

        print("✅ Imported alarm tone: \(trimmedName) (\(soundID))")
        return sound
    }

    /// Imports an audio file as a custom sleep sound. Stored as-is (m4a preferred).
    @discardableResult
    func importSleepSound(from sourceURL: URL, name: String) throws -> CustomSound {
        let sound = try Self.importSleepSoundFile(from: sourceURL, name: name, existing: sounds)

        sounds.append(sound)
        saveMetadata()

        print("✅ Imported sleep sound: \(sound.name) (\(sound.id))")
        return sound
    }

    /// File-system half of a sleep sound import: validates against the given
    /// snapshot of the library, copies the file, and returns the new entry.
    /// Does not touch `sounds` or persist metadata — the caller does that.
    private static func importSleepSoundFile(from sourceURL: URL, name: String, existing: [CustomSound]) throws -> CustomSound {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard CustomSound.isValidMQTTName(trimmedName) else {
            throw ImportError.invalidName
        }
        guard !existing.contains(where: { $0.name.lowercased() == trimmedName.lowercased() }) else {
            throw ImportError.duplicateName
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        if fileSize > sleepSoundMaxBytes {
            throw ImportError.fileTooLarge
        }

        // Check total sleep sound storage
        let currentTotal = existing.filter { $0.category == .sleepSound }.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        if currentTotal + fileSize > sleepSoundTotalMaxBytes {
            throw ImportError.storageLimitExceeded
        }

        let ext = sourceURL.pathExtension.lowercased()
        let soundID = "custom_\(UUID().uuidString)"
        let destURL = sleepSoundsDirectory.appendingPathComponent("\(soundID).\(ext)")

        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        let duration = readDuration(url: destURL)

        return CustomSound(
            id: soundID,
            name: trimmedName,
            category: .sleepSound,
            fileExtension: ext,
            importDate: Date(),
            fileSizeBytes: fileSize,
            durationSeconds: duration,
            sortOrder: (existing.filter { $0.category == .sleepSound }.map(\.sortOrder).max() ?? -1) + 1
        )
    }

    // MARK: - Delete

    /// Deletes a custom sound. Returns the IDs of alarms that were using it (caller should warn).
    @discardableResult
    func deleteSound(id: String) -> [String] {
        guard let sound = sounds.first(where: { $0.id == id }) else { return [] }

        let fm = FileManager.default

        // Remove the sound file
        let fileURL = self.fileURL(for: sound)
        try? fm.removeItem(at: fileURL)

        // Remove notification copy for alarm tones
        if sound.category == .alarmTone {
            let notifURL = Self.librarySoundsDirectory.appendingPathComponent(sound.fileName)
            try? fm.removeItem(at: notifURL)
        }

        sounds.removeAll { $0.id == id }
        saveMetadata()

        if sound.category == .alarmTone {
            AlarmSoundManager.shared.invalidateCache()
        }

        print("🗑 Deleted custom sound: \(sound.name) (\(id))")
        return []
    }

    /// Checks if any active alarms use the given sound ID.
    func alarmsUsingSoundID(_ soundID: String, container: ModelContainer?) -> [Alarm] {
        guard let container else { return [] }
        let context = container.mainContext
        guard let alarms = try? context.fetch(FetchDescriptor<Alarm>()) else { return [] }
        return alarms.filter { $0.soundName == soundID }
    }

    // MARK: - Rename

    func renameSound(id: String, newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard CustomSound.isValidMQTTName(trimmed) else {
            throw ImportError.invalidName
        }
        guard !sounds.contains(where: { $0.id != id && $0.name.lowercased() == trimmed.lowercased() }) else {
            throw ImportError.duplicateName
        }
        guard let index = sounds.firstIndex(where: { $0.id == id }) else { return }
        sounds[index].name = trimmed
        saveMetadata()

        if sounds[index].category == .alarmTone {
            AlarmSoundManager.shared.invalidateCache()
        }
    }

    // MARK: - Reorder

    func reorderSounds(category: CustomSound.Category, fromOffsets: IndexSet, toOffset: Int) {
        var categorySounds = sounds.filter { $0.category == category }.sorted { $0.sortOrder < $1.sortOrder }
        categorySounds.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (i, sound) in categorySounds.enumerated() {
            if let idx = sounds.firstIndex(where: { $0.id == sound.id }) {
                sounds[idx].sortOrder = i
            }
        }
        saveMetadata()
        if category == .alarmTone {
            AlarmSoundManager.shared.invalidateCache()
        }
    }

    // MARK: - Lookup

    func sound(byID id: String) -> CustomSound? {
        sounds.first { $0.id == id }
    }

    /// Finds a custom sound by its MQTT name (display name with spaces→underscores).
    func soundByMQTTName(_ mqttName: String, category: CustomSound.Category? = nil) -> CustomSound? {
        sounds.first { sound in
            (category == nil || sound.category == category) &&
            sound.mqttName.lowercased() == mqttName.lowercased()
        }
    }

    func alarmTones() -> [CustomSound] {
        sounds.filter { $0.category == .alarmTone }.sorted { $0.sortOrder < $1.sortOrder }
    }

    func sleepSounds() -> [CustomSound] {
        sounds.filter { $0.category == .sleepSound }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Returns the file URL for playback.
    ///
    /// For alarm tones we prefer the `Library/Sounds/` mirror because it is
    /// always local (the iCloud master may be a placeholder until download
    /// completes after a fresh install). Falls back to the iCloud/local master
    /// path if the mirror hasn't been written yet.
    ///
    /// Sleep sounds return the master path directly. If the file is an iCloud
    /// placeholder, we eagerly trigger a download so playback can proceed
    /// (AVFoundation does not download iCloud placeholders on its own).
    func fileURL(for sound: CustomSound) -> URL {
        switch sound.category {
        case .alarmTone:
            let libraryCopy = Self.librarySoundsDirectory.appendingPathComponent(sound.fileName)
            if FileManager.default.fileExists(atPath: libraryCopy.path) {
                return libraryCopy
            }
            return Self.alarmTonesDirectory.appendingPathComponent(sound.fileName)
        case .sleepSound:
            let url = Self.sleepSoundsDirectory.appendingPathComponent(sound.fileName)
            if Self.isCloudBacked {
                // No-op if the file is already downloaded locally.
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
            return url
        }
    }

    /// Returns the file URL for a custom sound by ID.
    func fileURL(forID id: String) -> URL? {
        guard let sound = sound(byID: id) else { return nil }
        let url = fileURL(for: sound)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns the notification sound name for a custom alarm tone (filename in Library/Sounds/).
    func notificationSoundName(forID id: String) -> String? {
        guard let sound = sound(byID: id), sound.category == .alarmTone else { return nil }
        let url = Self.librarySoundsDirectory.appendingPathComponent(sound.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return sound.fileName
    }

    // MARK: - Storage

    func totalAlarmToneBytes() -> Int64 {
        sounds.filter { $0.category == .alarmTone }.reduce(0) { $0 + $1.fileSizeBytes }
    }

    func totalSleepSoundBytes() -> Int64 {
        sounds.filter { $0.category == .sleepSound }.reduce(0) { $0 + $1.fileSizeBytes }
    }

    // MARK: - Migration

    /// Migrates existing imported sleep sounds from Documents/Sleep Sounds/ to the new location.
    /// Operates on (and returns) a local snapshot of the library so it can run
    /// off the main thread during bootstrap; the caller assigns the result to `sounds`.
    private func migrateExistingSleepSounds(existing: [CustomSound]) -> [CustomSound] {
        var result = existing
        let oldDir = SleepSoundManager.importedSoundsDirectory
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return result
        }

        for fileURL in contents where fileURL.pathExtension.lowercased() == "m4a" {
            let baseName = fileURL.deletingPathExtension().lastPathComponent
            // Skip if already migrated (check by name)
            if result.contains(where: { $0.name.lowercased() == baseName.replacingOccurrences(of: "_", with: " ").lowercased() }) {
                continue
            }

            let sanitized = CustomSound.sanitizedName(from: baseName)
            // Don't fail migration for individual files
            do {
                let sound = try Self.importSleepSoundFile(from: fileURL, name: sanitized, existing: result)
                result.append(sound)
                print("🔄 Migrated sleep sound: \(sanitized)")
            } catch {
                print("⚠️ Failed to migrate sleep sound '\(baseName)': \(error)")
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func readDuration(url: URL) -> Double {
        do {
            let file = try AVAudioFile(forReading: url)
            return Double(file.length) / file.processingFormat.sampleRate
        } catch {
            return 0
        }
    }

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case invalidName
        case duplicateName
        case fileTooLarge
        case tooLong(seconds: Double)
        case storageLimitExceeded
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Name must be 1-64 characters using only letters, numbers, spaces, underscores, and hyphens."
            case .duplicateName:
                return "A custom sound with this name already exists."
            case .fileTooLarge:
                return "The file is too large to import."
            case .tooLong(let seconds):
                let mins = Int(seconds) / 60
                let secs = Int(seconds) % 60
                return "Alarm tone is too long (\(mins)m \(secs)s). Maximum is 90 seconds. Trim it first or import as a sleep sound instead."
            case .storageLimitExceeded:
                return "Storage limit reached. Delete some sounds to free up space."
            case .unsupportedFormat:
                return "This audio format is not supported."
            }
        }
    }
}
