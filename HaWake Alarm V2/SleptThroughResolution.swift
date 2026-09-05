//
//  SleptThroughResolution.swift
//  HaWake Alarm V2
//
//  The pure half of slept-through detection: what "slept through" MEANS, how a
//  day is bounded, how the unresolved-ring ledger prunes itself, and how the
//  four deterministic AlarmKit UUIDs we arm per alarm collapse back to one
//  alarm. No UserDefaults, no AlarmKit, no MQTT — those live in
//  `UnresolvedRingLedger` and `SleptThroughNotice`, which are thin over this.
//
//  Precedent: `RingingGuardResolution`, `AlarmOverrideResolution`,
//  `AlarmFireAudioResolution`, `AlarmKitConfigResolution`.
//
//
//  ═══════════════════════════════════════════════════════════════════════
//  WHAT "SLEPT THROUGH" MEANS, AND WHY THIS DEFINITION
//  ═══════════════════════════════════════════════════════════════════════
//
//  **An alarm is slept through when one of its rings went UNATTENDED for at
//  least the grace window.** "Unattended" means the user neither dismissed nor
//  snoozed it during that time. Nothing else counts as attending: presenting
//  the window is the app's doing, not the user's, and a system alert nobody
//  touches is precisely the thing being measured.
//
//  Four consequences, each deliberate:
//
//  1. **ALARMS ARE COUNTED, NOT RINGS** (settled in PLAN-sleep-through-stack,
//     "the remaining calls" #4). One ledger entry per alarm hash. A snoozed
//     alarm that is then slept through re-rings against the SAME entry, so it
//     is one alarm slept through, not two. "You slept through 3 alarms" is
//     what a person means.
//
//  2. **A LATE DISMISSAL STILL COUNTS.** The measurement is ring-start → first
//     user action, so an alarm the user finally deals with at 13:00 after it
//     rang at 06:00 is slept through, and is attributed to the day it RANG.
//     Deleting the entry on dismiss would have been simpler and wrong: it
//     would make the count depend on whether the user happened to tidy up.
//
//  3. **A DISMISSAL 40 SECONDS LATE DOES NOT COUNT.** That is the entire job
//     of the grace window. `graceWindow` is 10 minutes — comfortably longer
//     than a full five-slot mission ladder plus the reaction time of someone
//     who is genuinely awake, and comfortably shorter than any nap. It errs
//     LONG on purpose: over-reporting would tell a user they slept through an
//     alarm they actually got up for, which is worse than silence. The value
//     is a parameter everywhere below so it can be tuned by test, not by edit.
//
//  4. **SNOOZE ATTENDS THE RING IT ENDS, AND OPENS A NEW ONE.** Snoozing
//     within the grace window means the user was awake enough to press a
//     button; that ring was attended. The re-fire starts a fresh ring on the
//     same entry, judged on its own. So deliberate snoozing never inflates the
//     count, but snoozing at +12 minutes — having slept through most of the
//     ring — does, correctly.
//
//  Once an entry has been established as slept-through it LATCHES
//  (`unattendedSince`). A fact about the morning must not evaporate because
//  the user later tapped something.
//
//
//  ═══════════════════════════════════════════════════════════════════════
//  WHAT "TODAY" MEANS
//  ═══════════════════════════════════════════════════════════════════════
//
//  An entry belongs to the calendar day of the RING that made it slept-through
//  — `unattendedSince`, or the currently-open ring — evaluated in the device's
//  CURRENT calendar and time zone.
//
//  * **Midnight** needs no timer, no scheduled reset and no stored day string.
//    The count is a filter over absolute timestamps, so it falls to zero the
//    moment the day rolls, wherever that boundary happens to be. (A retained
//    MQTT value is only refreshed when the app next publishes — stated in
//    `Documents/12`, and the reason the app-side banner is not driven by it.)
//
//  * **Time-zone changes** re-partition history rather than freeze it. Fly
//    from New York to Tokyo and a 06:00 alarm may fall out of "today". That is
//    the honest answer: the user's today is where the user is. It can drop a
//    fact, never invent one.
//
//  * **Clock changes** cannot break it. Every duration is computed from stored
//    epoch timestamps and compared with `>=`, so a clock that jumps BACKWARDS
//    yields a negative interval, which fails the grace test and under-reports.
//    A clock that jumps forwards can only make an already-unattended ring look
//    more unattended, which it is. Nothing here can produce a negative count
//    or a crash from a nonsensical date.
//
//
//  ═══════════════════════════════════════════════════════════════════════
//  WHY LOSING THE LEDGER IS SAFE
//  ═══════════════════════════════════════════════════════════════════════
//
//  Same contract as `AlertDeliveryLedger`: **losing it costs accuracy, never a
//  missed alarm.** Nothing in this file, or in the ledger over it, is consulted
//  by any path that schedules, arms, fires, presents, snoozes or dismisses an
//  alarm. An absent or corrupt ledger reads as "nothing known" — an empty list
//  and a count of zero. It is deliberately kept away from
//  `HaWakeAlarm.pendingAlarm*` and `HaWakeAlarm.activeRingingAlarmID`, which
//  ARE recovery state, and it uses its own key.
//

import Foundation

// MARK: - AlarmKit identity

/// The deterministic UUIDs Allarise derives per alarm hash, in one pure place.
///
/// `AlarmKitScheduler` arms up to four AlarmKit alarms for a single user alarm
/// (main +5s failsafe, weekly backup, ringing guard, snooze failsafe), each on
/// its own UUID derived from the alarm's `stableHash`. A fired-and-unattended
/// AlarmKit alarm stays resident as `.alerting` indefinitely — through a
/// process death and through a reboot (measured, `al-bee.4`) — so reading the
/// inventory back is how a cold start learns that alarms rang with nobody
/// home. To count ALARMS rather than tiers, those four ids have to collapse to
/// one, which is what `alarmHashes(forAlertingIDs:knownHashes:)` does.
///
/// The masks and the hash→UUID formatting are duplicated nowhere:
/// `AlarmKitScheduler` calls into this type, so the two cannot drift.
enum AlarmKitAlarmIdentity {

    /// Tier masks. These are part of a PERSISTED identity — an AlarmKit alarm
    /// armed by an older build is still resident under the old id — so they
    /// must never change value.
    static let snoozeMask = 0x534E4F4F5A45      // "SNOOZE"
    static let ringingGuardMask = 0x524E47554152 // "RNGUAR"
    static let weeklyBackupMask = 0x574B4C59     // "WKLY"

    /// Converts an alarm ID hash to a consistent UUID.
    ///
    /// Byte-for-byte the algorithm `AlarmKitScheduler.alarmIDToUUID` has always
    /// used; moved here unchanged so it can be tested and so the reverse
    /// mapping below is provably the inverse of what we actually schedule.
    static func uuid(forHash hashValue: Int) -> UUID {
        var hashString = String(format: "%016x", abs(hashValue))
        while hashString.count < 32 {
            hashString = "0" + hashString
        }
        if hashString.count > 32 {
            hashString = String(hashString.prefix(32))
        }
        let uuidString = """
        \(hashString.prefix(8))-\
        \(hashString.dropFirst(8).prefix(4))-\
        \(hashString.dropFirst(12).prefix(4))-\
        \(hashString.dropFirst(16).prefix(4))-\
        \(hashString.dropFirst(20).prefix(12))
        """
        return UUID(uuidString: uuidString) ?? UUID()
    }

    static func snoozeUUID(forAlarmHash hash: Int) -> UUID {
        uuid(forHash: hash ^ snoozeMask)
    }

    static func ringingGuardUUID(forAlarmHash hash: Int) -> UUID {
        uuid(forHash: hash ^ ringingGuardMask)
    }

    static func weeklyBackupUUID(forAlarmHash hash: Int) -> UUID {
        uuid(forHash: hash ^ weeklyBackupMask)
    }

    /// Every AlarmKit id this alarm can be resident under.
    static func allTierUUIDs(forAlarmHash hash: Int) -> [UUID] {
        [
            uuid(forHash: hash),
            snoozeUUID(forAlarmHash: hash),
            ringingGuardUUID(forAlarmHash: hash),
            weeklyBackupUUID(forAlarmHash: hash),
        ]
    }

    /// Collapse a set of resident AlarmKit ids down to the alarms they belong
    /// to. Four tiers of the same alarm yield ONE hash; an id belonging to no
    /// known alarm (a stale arm from a since-deleted alarm) is dropped rather
    /// than guessed at.
    ///
    /// - Parameters:
    ///   - alertingIDs: ids currently resident in the `.alerting` state.
    ///   - knownHashes: `stableHash` of every alarm we still know about, plus
    ///     any hash recovered from the scheduler's own persisted UUID map.
    static func alarmHashes(forAlertingIDs alertingIDs: [UUID], knownHashes: [Int]) -> Set<Int> {
        guard !alertingIDs.isEmpty, !knownHashes.isEmpty else { return [] }
        var reverse: [UUID: Int] = [:]
        for hash in knownHashes {
            for id in allTierUUIDs(forAlarmHash: hash) {
                // First writer wins: two alarms colliding on a tier UUID is
                // astronomically unlikely, and picking either is better than
                // dropping both.
                if reverse[id] == nil { reverse[id] = hash }
            }
        }
        return Set(alertingIDs.compactMap { reverse[$0] })
    }
}

// MARK: - Ledger entry

/// One alarm's unresolved-ring record. Value type; the storage layer owns
/// persistence and the pruning policy is `SleptThroughResolution.prune`.
struct UnresolvedRing: Equatable {

    /// The alarm's `stableHash` — the same identity AlarmKit, the pending
    /// store and the recovery paths all key on.
    let alarmHash: Int

    /// First time this alarm was ever seen ringing, for pruning and display.
    var firstRingAt: Date

    /// Start of a ring the user has not acted on yet. `nil` once dismissed or
    /// snoozed; set again by the next ring.
    var openRingAt: Date?

    /// Latched start of the first ring that went unattended past the grace
    /// window. Once set it is never cleared — see doc comment above.
    var unattendedSince: Date?

    /// The alarm's label at ring time, snapshotted because an ephemeral alarm's
    /// SwiftData row is deleted on dismiss and reading it later is a crash, not
    /// a blank string (the hazard `AfterAlarmNotesLive` documents).
    var label: String

    /// The alarm's MQTT index, or 0 when unknown. Published so an automation
    /// can identify the alarm without string-matching a label.
    var alarmIndex: Int
}

// MARK: - Report

/// What gets surfaced — to the home banner and to Home Assistant.
struct SleptThroughReport: Equatable {

    struct Entry: Equatable {
        let name: String
        let alarmIndex: Int
        /// The moment the slept-through ring STARTED, not the moment we noticed.
        let at: Date
    }

    let count: Int
    let entries: [Entry]

    static let empty = SleptThroughReport(count: 0, entries: [])
}

// MARK: - Resolution

enum SleptThroughResolution {

    /// How long a ring must go unattended before it counts. See consequence 3
    /// in the header for why this is 10 minutes and why it errs long.
    static let graceWindow: TimeInterval = 10 * 60

    /// Entries older than this are dropped. A week is far more history than a
    /// daily count needs; it exists only so a user who opens the app on Friday
    /// can still be told about Friday morning.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Hard cap so a pathological schedule cannot grow UserDefaults without
    /// bound. Newest survive.
    static let maxEntries = 60

    // MARK: Transitions

    /// A ring began for this alarm.
    ///
    /// Idempotent on an already-open ring: a re-present, an unlock retry or a
    /// second delivery tier claiming the same ring must NOT restart the clock,
    /// or a repeatedly-re-presented alarm could never age past the grace
    /// window. `firstRingAt` only ever moves earlier.
    static func applyRingStarted(to ring: UnresolvedRing, at date: Date) -> UnresolvedRing {
        var updated = ring
        if updated.openRingAt == nil { updated.openRingAt = date }
        if date < updated.firstRingAt { updated.firstRingAt = date }
        return updated
    }

    /// The user dismissed or snoozed. Closes the open ring, latching
    /// slept-through first if that ring had already run past the grace window.
    static func applyUserAction(
        to ring: UnresolvedRing,
        at date: Date,
        grace: TimeInterval = graceWindow
    ) -> UnresolvedRing {
        var updated = ring
        if let open = updated.openRingAt, elapsed(from: open, to: date) >= grace {
            if updated.unattendedSince == nil { updated.unattendedSince = open }
        }
        updated.openRingAt = nil
        return updated
    }

    // MARK: Predicate

    /// The start of the ring that makes this alarm slept-through, or `nil`.
    ///
    /// Latched first, so a fact already established survives; otherwise the
    /// currently-open ring is judged against the grace window.
    static func sleptThroughAt(
        _ ring: UnresolvedRing,
        now: Date,
        grace: TimeInterval = graceWindow
    ) -> Date? {
        if let latched = ring.unattendedSince { return latched }
        if let open = ring.openRingAt, elapsed(from: open, to: now) >= grace { return open }
        return nil
    }

    static func isSleptThrough(
        _ ring: UnresolvedRing,
        now: Date,
        grace: TimeInterval = graceWindow
    ) -> Bool {
        sleptThroughAt(ring, now: now, grace: grace) != nil
    }

    // MARK: Reporting

    /// The alarms slept through on the calendar day containing `now`.
    ///
    /// Sorted by ring time so "the first one you slept through" reads first.
    /// `calendar` is injected purely so tests can pin a time zone; production
    /// always passes the live `Calendar.current`, which is what makes the day
    /// boundary follow the device.
    static func report(
        _ rings: [UnresolvedRing],
        now: Date,
        calendar: Calendar = .current,
        grace: TimeInterval = graceWindow,
        maxDetailEntries: Int = 10
    ) -> SleptThroughReport {
        let today = rings.compactMap { ring -> (UnresolvedRing, Date)? in
            guard let at = sleptThroughAt(ring, now: now, grace: grace) else { return nil }
            guard calendar.isDate(at, inSameDayAs: now) else { return nil }
            return (ring, at)
        }
        .sorted { $0.1 < $1.1 }

        let entries = today.prefix(maxDetailEntries).map { pair in
            SleptThroughReport.Entry(
                name: pair.0.label.isEmpty ? "Untitled" : pair.0.label,
                alarmIndex: pair.0.alarmIndex,
                at: pair.1
            )
        }
        // The count is the honest total; only the detail list is capped.
        return SleptThroughReport(count: today.count, entries: Array(entries))
    }

    // MARK: Pruning

    /// Drop entries older than `maxAge`, then keep at most `maxEntries`,
    /// newest first. Pure so both limbs are testable without touching disk.
    static func prune(
        _ rings: [UnresolvedRing],
        now: Date,
        maxAge: TimeInterval = maxAge,
        maxEntries: Int = maxEntries
    ) -> [UnresolvedRing] {
        let cutoff = now.addingTimeInterval(-maxAge)
        // A clock that jumped backwards would otherwise wipe live entries, so
        // an entry stamped in the FUTURE is kept, not pruned.
        let fresh = rings.filter { lastActivity(of: $0) >= cutoff }
        guard fresh.count > maxEntries else { return fresh }
        return Array(fresh.sorted { lastActivity(of: $0) > lastActivity(of: $1) }.prefix(maxEntries))
    }

    /// The most recent moment this entry meant anything.
    static func lastActivity(of ring: UnresolvedRing) -> Date {
        var latest = ring.firstRingAt
        if let open = ring.openRingAt, open > latest { latest = open }
        if let latched = ring.unattendedSince, latched > latest { latest = latched }
        return latest
    }

    // MARK: Helpers

    /// Signed interval, so a backwards clock jump reads negative and fails the
    /// grace test rather than wrapping into a huge positive.
    private static func elapsed(from start: Date, to end: Date) -> TimeInterval {
        end.timeIntervalSince(start)
    }
}
