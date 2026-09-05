//
//  SiriSupportEntities.swift
//  HaWake Alarm V2
//
//  Plain App Entities (iOS 26+) backing the custom intents: sleep sounds
//  and user-configured MQTT commands. Both are thin views over existing
//  managers — no new storage.
//

import AppIntents
import Foundation

// MARK: - Sleep Sound

struct SleepSoundEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sleep Sound"
    static var defaultQuery = SleepSoundQuery()

    /// Raw sound id (bundle filename / custom_ id) — same ids
    /// SleepSoundManager.start(soundName:) accepts.
    var id: String
    var displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

struct SleepSoundQuery: EntityStringQuery {
    /// Upper bound on how long a query waits for CustomSoundManager's bootstrap
    /// before returning what it has. See `allEntities()`.
    private static let bootstrapWaitSeconds: Double = 4

    /// Waits for CustomSoundManager's bootstrap, but no longer than
    /// `bootstrapWaitSeconds`.
    ///
    /// Siri can cold-launch the app straight into an entity query, racing the
    /// detached metadata load — without waiting, custom sleep sounds are
    /// intermittently missing from the Shortcuts list. But bootstrap's first
    /// step is an iCloud ubiquity-container probe that can block for a long
    /// time on a cold launch (thermal throttling, pending downloads, iOS 27
    /// beta `bird`-daemon latency). Blocking the query on that whole chain is
    /// what produced the *empty* picker: Shortcuts times out its own query,
    /// gets nothing, and caches an empty snapshot until the next reboot.
    ///
    /// Racing bootstrap against a timeout fixes both: a warm launch (bootstrap
    /// wins, ~1–2s) returns the full list including custom sounds; a cold/slow
    /// launch (timeout wins) still returns bundle + legacy sounds promptly
    /// instead of hanging. Bundle sounds are enumerated synchronously from the
    /// app bundle and never depend on bootstrap, so the list is never empty
    /// when bundled sounds exist on disk. The detached bootstrap keeps running
    /// after the timeout, so the next query (and the app's foreground
    /// `updateAppShortcutParameters()`) picks up the custom sounds.
    private func awaitBootstrapBounded() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await CustomSoundManager.shared.ensureBootstrapped() }
            group.addTask { try? await Task.sleep(for: .seconds(Self.bootstrapWaitSeconds)) }
            _ = await group.next()   // return as soon as either finishes
            group.cancelAll()        // does not cancel the retained detached bootstrap
        }
    }

    @MainActor
    private func allEntities() async -> [SleepSoundEntity] {
        await awaitBootstrapBounded()
        return SleepSoundManager.availableSounds().map {
            SleepSoundEntity(id: $0, displayName: SleepSoundManager.displayName(for: $0))
        }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SleepSoundEntity] {
        await allEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SleepSoundEntity] {
        let q = string.lowercased()
        return await allEntities().filter { $0.displayName.lowercased().contains(q) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SleepSoundEntity] {
        await allEntities()
    }
}

// MARK: - Radio Station

struct RadioStationEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Radio Station"
    static var defaultQuery = RadioStationQuery()

    /// RadioStation.id — the radio-browser `stationuuid`. Stable and NOT
    /// derived from the (user-renamable, possibly emoji/unicode) display name,
    /// so the Shortcuts round-trip never breaks on odd station names.
    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct RadioStationQuery: EntityStringQuery {
    /// Favorites, plus the last-played station when it isn't already a favorite
    /// (so a recently played station stays selectable). Backed entirely by
    /// RadioPlayerManager — favorites load synchronously from UserDefaults at
    /// init, so no bootstrap wait is needed (unlike sleep sounds).
    @MainActor
    private func allEntities() -> [RadioStationEntity] {
        let manager = RadioPlayerManager.shared
        var stations = manager.favorites
        if let last = manager.lastStation, !stations.contains(where: { $0.id == last.id }) {
            stations.append(last)
        }
        return stations.map { RadioStationEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [RadioStationEntity] {
        allEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [RadioStationEntity] {
        let q = string.lowercased()
        return allEntities().filter { $0.name.lowercased().contains(q) }
    }

    @MainActor
    func suggestedEntities() async throws -> [RadioStationEntity] {
        // Suggested list = favorites only (mirrors sleep sounds' suggestions).
        RadioPlayerManager.shared.favorites.map { RadioStationEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - MQTT Command

struct MQTTCommandEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Command"
    static var defaultQuery = MQTTCommandQuery()

    /// MQTTCommand.id UUID string.
    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct MQTTCommandQuery: EntityStringQuery {
    @MainActor
    private func allEntities() -> [MQTTCommandEntity] {
        DeviceSettings.shared.mqttCommands.map {
            MQTTCommandEntity(id: $0.id.uuidString, name: $0.name)
        }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MQTTCommandEntity] {
        allEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MQTTCommandEntity] {
        let q = string.lowercased()
        return allEntities().filter { $0.name.lowercased().contains(q) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MQTTCommandEntity] {
        allEntities()  // max 10 commands exist by design
    }
}
