//
//  AlarmBackupStore.swift
//  HaWake Alarm V2
//
//  A plain-JSON safety net under the SwiftData store.
//
//  WHY THIS EXISTS. `HaWakeAlarmV2App.init` creates the `ModelContainer`, and its
//  only recovery path when that throws is `clearIncompatibleDatabase()` — which
//  DELETES the store. That is the correct last resort (an app that cannot open its
//  database cannot ring an alarm at all), but on its own it silently destroys every
//  alarm the user ever created, with no notice and no way back. A schema change
//  that migrates cleanly on every device we test and fails on one we didn't is
//  exactly the shape of bug that reaches users.
//
//  So the store is never the only copy:
//
//    1. On every successful launch, `writeSnapshot` mirrors all alarms to
//       `alarm-backup.json` (atomic write, Application Support, excluded from
//       iCloud backup churn by living next to the store).
//    2. If the container fails to open, `archiveStoreFiles` copies the raw
//       `.store*` files aside BEFORE the wipe, so a future version can still do a
//       forensic recovery that this JSON snapshot can't.
//    3. After the wipe, `restore` re-creates every alarm from the snapshot.
//    4. `pendingNotice` records what happened so the UI can tell the user in plain
//       language instead of leaving them to discover it at 6am.
//
//  The snapshot is DELIBERATELY a flat Codable struct rather than anything
//  SwiftData-aware: its whole job is to survive the failure of the SwiftData layer,
//  so it must not share machinery with it. Blob fields (`missionData`,
//  `extraMissionsData`, `afterAlarmOrderData`) are copied verbatim — they are
//  already self-describing JSON with their own backward-compatible decoders.
//

import Foundation
import SwiftData

// MARK: - Snapshot

/// A flat, storage-independent copy of one `Alarm`. Every stored property of the
/// model appears here; adding a property to `Alarm` without adding it here means
/// that property is silently lost in a recovery, so keep the two in step.
struct AlarmSnapshot: Codable {
    var stableID: UUID?
    var time: Date
    var label: String
    var isEnabled: Bool
    var recurringDaysRaw: String
    var soundName: String
    var snoozeDuration: Int
    var missionData: Data
    var extraMissionsData: Data?
    var allowSkipOnce: Bool
    var skippedFireDate: Date?
    var lastFireDate: Date?
    var skipHoldDuration: Double?
    var isSnoozed: Bool
    var snoozeUntil: Date?
    var snoozeCount: Int
    var maxSnoozeCount: Int?
    var snoozeRequiresHold: Bool?
    var customSnoozeHoldDuration: Double?
    var snoozeModeRaw: String?
    var skipAlarmModeRaw: String?
    var customVolumeLevel: Double?
    var customGracePeriod: Double?
    var customVibrationEnabled: Bool?
    var customFadeInEnabled: Bool?
    var customFadeInDuration: Int?
    var swipeLeftCommandID: String?
    var swipeRightCommandID: String?
    var showWeatherAfterAlarm: Bool
    var dismissAppURI: String?
    var snoozeAppURI: String?
    var alarmScreenNotes: String
    var alarmScreenCommandID1: String?
    var alarmScreenCommandID2: String?
    var alarmScreenCommandID3: String?
    var alarmScreenCommandID4: String?
    var afterAlarmOrderData: Data?
    var radioStationID: String?
    var radioStationName: String?
    var radioStationURL: String?
    var source: String
    var mqttID: String?
    var isEphemeral: Bool
    var alarmIndex: Int
    // Optionals (unlike the Bools above) so snapshots written before these
    // fields existed still decode — a decode failure here would void the whole
    // backup, which is the one thing this file must never do.
    var excludeFromMQTT: Bool?
    var firesAtExactTime: Bool?

    init(_ alarm: Alarm) {
        stableID = alarm.stableID
        time = alarm.time
        label = alarm.label
        isEnabled = alarm.isEnabled
        recurringDaysRaw = alarm.recurringDaysRaw
        soundName = alarm.soundName
        snoozeDuration = alarm.snoozeDuration
        missionData = alarm.missionData
        extraMissionsData = alarm.extraMissionsData
        allowSkipOnce = alarm.allowSkipOnce
        skippedFireDate = alarm.skippedFireDate
        lastFireDate = alarm.lastFireDate
        skipHoldDuration = alarm.skipHoldDuration
        isSnoozed = alarm.isSnoozed
        snoozeUntil = alarm.snoozeUntil
        snoozeCount = alarm.snoozeCount
        maxSnoozeCount = alarm.maxSnoozeCount
        snoozeRequiresHold = alarm.snoozeRequiresHold
        customSnoozeHoldDuration = alarm.customSnoozeHoldDuration
        snoozeModeRaw = alarm.snoozeModeRaw
        skipAlarmModeRaw = alarm.skipAlarmModeRaw
        customVolumeLevel = alarm.customVolumeLevel
        customGracePeriod = alarm.customGracePeriod
        customVibrationEnabled = alarm.customVibrationEnabled
        customFadeInEnabled = alarm.customFadeInEnabled
        customFadeInDuration = alarm.customFadeInDuration
        swipeLeftCommandID = alarm.swipeLeftCommandID
        swipeRightCommandID = alarm.swipeRightCommandID
        showWeatherAfterAlarm = alarm.showWeatherAfterAlarm
        dismissAppURI = alarm.dismissAppURI
        snoozeAppURI = alarm.snoozeAppURI
        alarmScreenNotes = alarm.alarmScreenNotes
        alarmScreenCommandID1 = alarm.alarmScreenCommandID1
        alarmScreenCommandID2 = alarm.alarmScreenCommandID2
        alarmScreenCommandID3 = alarm.alarmScreenCommandID3
        alarmScreenCommandID4 = alarm.alarmScreenCommandID4
        afterAlarmOrderData = alarm.afterAlarmOrderData
        radioStationID = alarm.radioStationID
        radioStationName = alarm.radioStationName
        radioStationURL = alarm.radioStationURL
        source = alarm.source
        mqttID = alarm.mqttID
        isEphemeral = alarm.isEphemeral
        alarmIndex = alarm.alarmIndex
        excludeFromMQTT = alarm.excludeFromMQTT
        firesAtExactTime = alarm.firesAtExactTime
    }

    /// Rebuild a live model. The designated initialiser only covers part of the
    /// model, so the remaining fields are assigned afterwards — including
    /// `stableID`, which MUST be carried over verbatim: AlarmKit UUIDs, timer keys
    /// and recovery blobs are all derived from it, and minting a fresh one here
    /// would orphan everything already scheduled for this alarm.
    func makeAlarm() -> Alarm {
        let alarm = Alarm(
            time: time,
            label: label,
            isEnabled: isEnabled,
            soundName: soundName,
            snoozeDuration: snoozeDuration,
            allowSkipOnce: allowSkipOnce,
            skippedFireDate: skippedFireDate,
            lastFireDate: lastFireDate,
            skipHoldDuration: skipHoldDuration,
            isSnoozed: isSnoozed,
            snoozeUntil: snoozeUntil,
            snoozeCount: snoozeCount,
            maxSnoozeCount: maxSnoozeCount,
            snoozeRequiresHold: snoozeRequiresHold,
            customSnoozeHoldDuration: customSnoozeHoldDuration,
            snoozeModeRaw: snoozeModeRaw,
            skipAlarmModeRaw: skipAlarmModeRaw
        )
        alarm.stableID = stableID ?? UUID()
        alarm.recurringDaysRaw = recurringDaysRaw
        alarm.missionData = missionData
        alarm.extraMissionsData = extraMissionsData
        alarm.customVolumeLevel = customVolumeLevel
        alarm.customGracePeriod = customGracePeriod
        alarm.customVibrationEnabled = customVibrationEnabled
        alarm.customFadeInEnabled = customFadeInEnabled
        alarm.customFadeInDuration = customFadeInDuration
        alarm.swipeLeftCommandID = swipeLeftCommandID
        alarm.swipeRightCommandID = swipeRightCommandID
        alarm.showWeatherAfterAlarm = showWeatherAfterAlarm
        alarm.dismissAppURI = dismissAppURI
        alarm.snoozeAppURI = snoozeAppURI
        alarm.alarmScreenNotes = alarmScreenNotes
        alarm.alarmScreenCommandID1 = alarmScreenCommandID1
        alarm.alarmScreenCommandID2 = alarmScreenCommandID2
        alarm.alarmScreenCommandID3 = alarmScreenCommandID3
        alarm.alarmScreenCommandID4 = alarmScreenCommandID4
        alarm.afterAlarmOrderData = afterAlarmOrderData
        alarm.radioStationID = radioStationID
        alarm.radioStationName = radioStationName
        alarm.radioStationURL = radioStationURL
        alarm.source = source
        alarm.mqttID = mqttID
        alarm.isEphemeral = isEphemeral
        alarm.alarmIndex = alarmIndex
        alarm.excludeFromMQTT = excludeFromMQTT ?? false
        alarm.firesAtExactTime = firesAtExactTime ?? false
        return alarm
    }
}

/// The on-disk file: a version tag, a timestamp, and the alarms.
private struct AlarmBackupFile: Codable {
    var version: Int
    var savedAt: Date
    var alarms: [AlarmSnapshot]
}

// MARK: - Store

enum AlarmBackupStore {
    /// Bumped only if the file layout itself changes. Snapshot FIELDS may be added
    /// freely — they decode as nil/absent on an older file.
    private static let currentVersion = 1

    private static let backupFileName = "alarm-backup.json"
    private static let noticeKey = "alarmDatabaseRecoveryNotice"

    // MARK: File locations

    private static var applicationSupport: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    static var backupURL: URL? {
        applicationSupport?.appendingPathComponent(backupFileName)
    }

    // MARK: Snapshot

    /// Mirror the current alarms to disk. Called after a successful launch, and
    /// again whenever alarms change, so the newest copy is never more than one
    /// edit behind. Failures are logged but never thrown — a backup that cannot be
    /// written must not stop the app from running.
    @MainActor
    static func writeSnapshot(container: ModelContainer) {
        guard let url = backupURL else { return }
        let context = container.mainContext
        guard let alarms = try? context.fetch(FetchDescriptor<Alarm>()) else { return }
        writeSnapshot(alarms.map(AlarmSnapshot.init), to: url)
    }

    private static func writeSnapshot(_ snapshots: [AlarmSnapshot], to url: URL) {
        let file = AlarmBackupFile(version: currentVersion, savedAt: Date(), alarms: snapshots)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
            print("💾 Alarm backup written (\(snapshots.count) alarm(s))")
        } catch {
            print("⚠️ Failed to write alarm backup: \(error)")
        }
    }

    /// Read the snapshot written by a previous launch. nil = no usable backup.
    static func readSnapshot() -> (alarms: [AlarmSnapshot], savedAt: Date)? {
        guard let url = backupURL,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(AlarmBackupFile.self, from: data) else {
            print("⚠️ Alarm backup exists but could not be decoded")
            return nil
        }
        return (file.alarms, file.savedAt)
    }

    // MARK: Raw store archive

    /// Copy the SwiftData store files somewhere safe before they are deleted.
    /// Returns the archive directory when at least one file was copied.
    ///
    /// This is separate from the JSON snapshot on purpose: the snapshot can only
    /// ever contain what the LAST successful launch saw, whereas the raw store may
    /// hold newer state that a future build (with a real `MigrationPlan`) could
    /// still open. Keeping both costs a few hundred KB once.
    @discardableResult
    static func archiveStoreFiles() -> URL? {
        let fm = FileManager.default
        guard let appSupport = applicationSupport,
              let contents = try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil)
        else { return nil }

        let storeFiles = contents.filter {
            $0.pathExtension == "store" || $0.lastPathComponent.hasPrefix("default.store")
        }
        guard !storeFiles.isEmpty else { return nil }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let archive = appSupport.appendingPathComponent("RecoveredStore-\(stamp)", isDirectory: true)
        do {
            try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        } catch {
            print("⚠️ Could not create store archive directory: \(error)")
            return nil
        }

        var copied = 0
        for file in storeFiles {
            let destination = archive.appendingPathComponent(file.lastPathComponent)
            do {
                try fm.copyItem(at: file, to: destination)
                copied += 1
            } catch {
                print("⚠️ Could not archive \(file.lastPathComponent): \(error)")
            }
        }
        guard copied > 0 else {
            try? fm.removeItem(at: archive)
            return nil
        }
        print("🗄️ Archived \(copied) store file(s) to \(archive.lastPathComponent)")
        return archive
    }

    // MARK: Restore

    /// Insert every snapshotted alarm into a freshly created (empty) store.
    /// Returns the number restored.
    ///
    /// Only ever called against a store we just created after a wipe, so there is
    /// nothing to merge with and no de-duplication to do.
    @MainActor
    static func restore(into container: ModelContainer, from snapshots: [AlarmSnapshot]) -> Int {
        guard !snapshots.isEmpty else { return 0 }
        let context = container.mainContext
        var restored = 0
        for snapshot in snapshots {
            context.insert(snapshot.makeAlarm())
            restored += 1
        }
        do {
            try context.save()
        } catch {
            print("❌ Failed to save restored alarms: \(error)")
            return 0
        }
        print("♻️ Restored \(restored) alarm(s) from backup")
        return restored
    }

    // MARK: User notice

    /// What happened during a database recovery, held until the UI has shown it.
    struct RecoveryNotice: Codable {
        var date: Date
        /// Alarms successfully re-created from the JSON snapshot.
        var restoredCount: Int
        /// Alarms present in the snapshot (may exceed `restoredCount` if the
        /// restore itself failed).
        var snapshotCount: Int
        /// Folder holding the copied raw store files, if any were salvaged.
        var archivePath: String?
        /// The underlying container error, for the log and a support request.
        var errorDescription: String

        /// True when the user lost data we could not put back.
        var hadLoss: Bool { restoredCount < snapshotCount || snapshotCount == 0 }
    }

    /// Record that a recovery happened. Read once by the UI, then cleared.
    static func setPendingNotice(_ notice: RecoveryNotice) {
        guard let data = try? JSONEncoder().encode(notice) else { return }
        UserDefaults.standard.set(data, forKey: noticeKey)
    }

    static var pendingNotice: RecoveryNotice? {
        guard let data = UserDefaults.standard.data(forKey: noticeKey) else { return nil }
        return try? JSONDecoder().decode(RecoveryNotice.self, from: data)
    }

    static func clearPendingNotice() {
        UserDefaults.standard.removeObject(forKey: noticeKey)
    }
}
