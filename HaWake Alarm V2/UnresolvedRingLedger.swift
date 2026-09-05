//
//  UnresolvedRingLedger.swift
//  HaWake Alarm V2
//
//  Persistence for slept-through detection. All of the MEANING lives in
//  `SleptThroughResolution`; this file only reads and writes a small,
//  self-pruning UserDefaults dictionary and answers questions about it.
//
//  WHY IT IS SHAPED LIKE `AlertDeliveryLedger`
//  -------------------------------------------
//  Same guarantees, deliberately: its own key, timestamps rather than flags,
//  a max age and a max entry count, tolerant decoding, and the contract that
//  **losing it costs accuracy, never a missed alarm**.
//
//  WHAT IT MUST NEVER TOUCH
//  ------------------------
//  `HaWakeAlarm.pendingAlarm*` and `HaWakeAlarm.activeRingingAlarmID` are
//  recovery state — they are how a force-killed app learns an alarm is still
//  ringing. This ledger writes ONLY `HaWakeAlarm.unresolvedRings`. A bug here
//  must be structurally incapable of making the app believe an alarm is
//  ringing, or of making it believe one is not; that is why it is a separate
//  key with no reader in any scheduling, firing, presenting or dismissing
//  path.
//
//  DECODING IS TOTAL
//  -----------------
//  Nothing here throws. A missing key, a value of the wrong type, a dictionary
//  full of junk, an entry with no timestamp — every one of them degrades to
//  "nothing known" (an empty list), never to an error and never to a partial
//  read that throws mid-way. Version skew in both directions falls out of
//  that: an older app writes no ledger and behaves exactly as it does today,
//  and a newer app reading an absent ledger reports zero.
//

import Foundation

final class UnresolvedRingLedger {

    static let shared = UnresolvedRingLedger()

    /// Sole storage key. Namespaced with the existing `HaWakeAlarm.` prefix.
    static let storageKey = "HaWakeAlarm.unresolvedRings"

    private let defaults: UserDefaults

    /// - Parameter userDefaults: injectable so tests get their own suite.
    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    // MARK: - Writing

    /// A ring began. Called from the alarm-window presentation paths, which
    /// already write `setActiveRingingAlarm`, so this costs one extra
    /// UserDefaults write on a path that is doing several already.
    ///
    /// Alert alarms (`MissionType.alert`) must never reach here — they are
    /// transient Home Assistant notifications, not wake events, and counting
    /// an unacknowledged alert as a slept-through alarm would be a lie.
    func noteRingStarted(alarmHash: Int, label: String, alarmIndex: Int, at date: Date = Date()) {
        mutate(alarmHash: alarmHash) { existing in
            let base = existing ?? UnresolvedRing(
                alarmHash: alarmHash,
                firstRingAt: date,
                openRingAt: nil,
                unattendedSince: nil,
                label: label,
                alarmIndex: alarmIndex
            )
            var updated = SleptThroughResolution.applyRingStarted(to: base, at: date)
            // Refresh the display fields: the alarm may have been renamed or
            // re-indexed since the entry was created.
            if !label.isEmpty { updated.label = label }
            if alarmIndex > 0 { updated.alarmIndex = alarmIndex }
            return updated
        }
    }

    /// The user dismissed or snoozed this alarm. Called from the paths that
    /// already call `clearActiveRingingAlarm`.
    ///
    /// The entry is NOT deleted — a late dismissal is still a slept-through
    /// morning, and deleting would make the count depend on tidying up. It
    /// ages out via `prune`.
    func noteUserAction(alarmHash: Int, at date: Date = Date()) {
        mutate(alarmHash: alarmHash) { existing in
            guard let existing else { return nil }   // never rang: nothing to close
            return SleptThroughResolution.applyUserAction(to: existing, at: date)
        }
    }

    /// A resident AlarmKit alarm was found in the `.alerting` state and maps to
    /// this alarm. Cold-start evidence that it rang with nobody home.
    ///
    /// **Deliberately create-only.** If an entry already exists we leave it
    /// completely alone, for two reasons. A live ring already has its own,
    /// more accurate, start time. And a resident `.alerting` alarm persists
    /// indefinitely — through a reboot — so bumping the timestamp on every
    /// foreground would drag yesterday's alarm into today's count forever.
    /// Stamping it once means it belongs to the day it was discovered and then
    /// ages out normally.
    func noteDiscoveredAlerting(alarmHash: Int, label: String, alarmIndex: Int, at date: Date = Date()) {
        mutate(alarmHash: alarmHash) { existing in
            if let existing { return existing }
            return UnresolvedRing(
                alarmHash: alarmHash,
                firstRingAt: date,
                openRingAt: date,
                unattendedSince: nil,
                label: label,
                alarmIndex: alarmIndex
            )
        }
    }

    // MARK: - Reading

    func rings() -> [UnresolvedRing] {
        Self.decode(defaults.dictionary(forKey: Self.storageKey))
    }

    /// The alarms slept through today, for the banner and the MQTT sensor.
    func report(now: Date = Date(), calendar: Calendar = .current) -> SleptThroughReport {
        SleptThroughResolution.report(rings(), now: now, calendar: calendar)
    }

    /// Test/maintenance hook — drops every entry. Never called in the app.
    func removeAll() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Storage

    /// Read → transform → prune → write, in one place so no caller can skip
    /// the pruning. A `nil` return from `transform` means "no change".
    private func mutate(alarmHash: Int, _ transform: (UnresolvedRing?) -> UnresolvedRing?) {
        var all = rings()
        let index = all.firstIndex { $0.alarmHash == alarmHash }
        guard let updated = transform(index.map { all[$0] }) else { return }
        if let index {
            guard all[index] != updated else { return }
            all[index] = updated
        } else {
            all.append(updated)
        }
        let pruned = SleptThroughResolution.prune(all, now: Date())
        defaults.set(Self.encode(pruned), forKey: Self.storageKey)
    }

    // MARK: Plist round-trip
    //
    // A plain `[String: [String: Any]]` of plist scalars, matching the
    // `AlertDeliveryLedger` precedent. Keys are short and FIXED — they are a
    // persisted contract, so renaming one silently orphans every entry an
    // older build wrote.

    private enum Field {
        static let first = "first"
        static let open = "open"
        static let unattended = "unattended"
        static let label = "label"
        static let index = "index"
    }

    static func encode(_ rings: [UnresolvedRing]) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for ring in rings {
            var row: [String: Any] = [
                Field.first: ring.firstRingAt.timeIntervalSince1970,
                Field.label: ring.label,
                Field.index: ring.alarmIndex,
            ]
            if let open = ring.openRingAt { row[Field.open] = open.timeIntervalSince1970 }
            if let latched = ring.unattendedSince { row[Field.unattended] = latched.timeIntervalSince1970 }
            out[String(ring.alarmHash)] = row
        }
        return out
    }

    /// Tolerant by design: anything unreadable is skipped, not thrown on.
    static func decode(_ raw: [String: Any]?) -> [UnresolvedRing] {
        guard let raw else { return [] }
        var out: [UnresolvedRing] = []
        for (key, value) in raw {
            guard let hash = Int(key),
                  let row = value as? [String: Any],
                  let first = row[Field.first] as? Double else { continue }
            out.append(UnresolvedRing(
                alarmHash: hash,
                firstRingAt: Date(timeIntervalSince1970: first),
                openRingAt: (row[Field.open] as? Double).map(Date.init(timeIntervalSince1970:)),
                unattendedSince: (row[Field.unattended] as? Double).map(Date.init(timeIntervalSince1970:)),
                label: row[Field.label] as? String ?? "",
                alarmIndex: row[Field.index] as? Int ?? 0
            ))
        }
        // Stable order so the report and the tests are deterministic.
        return out.sorted { $0.firstRingAt < $1.firstRingAt }
    }
}
