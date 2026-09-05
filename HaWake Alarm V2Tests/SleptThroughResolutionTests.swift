//
//  SleptThroughResolutionTests.swift
//  HaWake Alarm V2Tests
//
//  The whole of slept-through detection that can be proven without hardware
//  (al-bee.5): the predicate and its grace window, the day boundary across
//  midnight / time zones / a clock that jumped, the ledger's two pruning
//  limbs, the collapse of Allarise's four AlarmKit tier UUIDs down to one
//  alarm, and the "absent or corrupt reads as nothing known" contract.
//
//  Hermetic: no AlarmKit, no broker, no windows, no ModelContainer. The ledger
//  runs against its own UserDefaults suite.
//
//  What is NOT provable here, and is listed in the bead instead: that a real
//  fired-and-unattended AlarmKit alarm is still resident as `.alerting` after
//  a reboot on iOS 27 (measured on 26.6 under `al-bee.4`), and that the
//  retained MQTT topics land on a real broker.
//
//  Reference: Documents/working-notes/PLAN-sleep-through-stack.md
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

// MARK: - Helpers

private let hash = 4242
private let grace = SleptThroughResolution.graceWindow

private func ring(
    firstRingAt: Date,
    openRingAt: Date? = nil,
    unattendedSince: Date? = nil,
    label: String = "Work",
    alarmIndex: Int = 3,
    alarmHash: Int = hash
) -> UnresolvedRing {
    UnresolvedRing(
        alarmHash: alarmHash,
        firstRingAt: firstRingAt,
        openRingAt: openRingAt,
        unattendedSince: unattendedSince,
        label: label,
        alarmIndex: alarmIndex
    )
}

/// A fixed calendar so the day-boundary tests do not depend on where the
/// machine running them happens to be.
private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func utcDate(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")!
    return f.date(from: iso)!
}

/// Ledger tests must anchor to the REAL clock, not a literal date: the ledger
/// prunes on every write against `Date()`, so a fixed timestamp would silently
/// start being dropped once it aged past `maxAge` — the test would go green for
/// the wrong reason today and red for the wrong reason next week. Rounded to a
/// whole second so the UserDefaults `Double` round-trip is exact.
private var anchorNow: Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()) }

/// 06:00 UTC on the same UTC day as `anchorNow`.
private func sixAMToday(_ now: Date) -> Date {
    utc.date(byAdding: .hour, value: 6, to: utc.startOfDay(for: now))!
}

// MARK: - The predicate

struct SleptThroughPredicateTests {

    @Test("A ring nobody has acted on yet is not slept through inside the grace window")
    func openInsideGrace() {
        let start = Date()
        let r = ring(firstRingAt: start, openRingAt: start)
        #expect(!SleptThroughResolution.isSleptThrough(r, now: start.addingTimeInterval(grace - 1)))
    }

    @Test("A ring left unattended past the grace window is slept through")
    func openPastGrace() {
        let start = Date()
        let r = ring(firstRingAt: start, openRingAt: start)
        #expect(SleptThroughResolution.isSleptThrough(r, now: start.addingTimeInterval(grace)))
        #expect(SleptThroughResolution.sleptThroughAt(r, now: start.addingTimeInterval(grace + 99)) == start)
    }

    // The case the definition exists to exclude.
    @Test("Dismissed 40 seconds late is NOT slept through")
    func dismissedFortySecondsLate() {
        let start = Date()
        var r = ring(firstRingAt: start, openRingAt: start)
        r = SleptThroughResolution.applyUserAction(to: r, at: start.addingTimeInterval(40))
        #expect(r.openRingAt == nil)
        #expect(r.unattendedSince == nil)
        #expect(!SleptThroughResolution.isSleptThrough(r, now: start.addingTimeInterval(60 * 60 * 6)))
    }

    @Test("Dismissed hours later still counts, and is attributed to the ring, not the dismissal")
    func dismissedHoursLater() {
        let rang = utcDate("2026-08-05T06:00:00Z")
        var r = ring(firstRingAt: rang, openRingAt: rang)
        r = SleptThroughResolution.applyUserAction(to: r, at: utcDate("2026-08-05T13:00:00Z"))
        #expect(r.openRingAt == nil)
        #expect(r.unattendedSince == rang)
        // The attribution is the ring, so it lands on the morning it happened.
        #expect(SleptThroughResolution.sleptThroughAt(r, now: utcDate("2026-08-05T23:00:00Z")) == rang)
    }

    @Test("Once established, slept-through latches and a later action cannot clear it")
    func latchSurvivesLaterAction() {
        let rang = Date()
        var r = ring(firstRingAt: rang, openRingAt: rang)
        r = SleptThroughResolution.applyUserAction(to: r, at: rang.addingTimeInterval(grace + 60))
        #expect(r.unattendedSince != nil)
        // A second ring, attended promptly, must not erase the first fact.
        r = SleptThroughResolution.applyRingStarted(to: r, at: rang.addingTimeInterval(3600))
        r = SleptThroughResolution.applyUserAction(to: r, at: rang.addingTimeInterval(3610))
        #expect(r.unattendedSince == rang)
    }

    @Test("Re-presenting the same ring does not restart the clock")
    func rePresentIsIdempotent() {
        let start = Date()
        var r = ring(firstRingAt: start, openRingAt: start)
        // An unlock retry / second delivery tier claiming the same ring.
        r = SleptThroughResolution.applyRingStarted(to: r, at: start.addingTimeInterval(30))
        #expect(r.openRingAt == start)
        #expect(SleptThroughResolution.isSleptThrough(r, now: start.addingTimeInterval(grace)))
    }

    @Test("firstRingAt only ever moves earlier")
    func firstRingMovesEarlierOnly() {
        let start = Date()
        var r = ring(firstRingAt: start, openRingAt: nil)
        r = SleptThroughResolution.applyRingStarted(to: r, at: start.addingTimeInterval(-500))
        #expect(r.firstRingAt == start.addingTimeInterval(-500))
    }

    // Counting ALARMS, not ring events — PLAN-sleep-through-stack #4.
    @Test("Snoozed promptly, re-rung, then dismissed promptly: not slept through")
    func promptSnoozeCycleDoesNotCount() {
        let t0 = Date()
        var r = ring(firstRingAt: t0, openRingAt: t0)
        r = SleptThroughResolution.applyUserAction(to: r, at: t0.addingTimeInterval(20))          // snooze
        r = SleptThroughResolution.applyRingStarted(to: r, at: t0.addingTimeInterval(9 * 60))     // re-fire
        r = SleptThroughResolution.applyUserAction(to: r, at: t0.addingTimeInterval(9 * 60 + 15)) // dismiss
        #expect(!SleptThroughResolution.isSleptThrough(r, now: t0.addingTimeInterval(86_400)))
    }

    @Test("Snoozed only after sleeping past the grace window: slept through, and counted ONCE")
    func lateSnoozeCountsOnce() {
        let t0 = Date()
        var r = ring(firstRingAt: t0, openRingAt: t0)
        r = SleptThroughResolution.applyUserAction(to: r, at: t0.addingTimeInterval(grace + 120))  // late snooze
        r = SleptThroughResolution.applyRingStarted(to: r, at: t0.addingTimeInterval(20 * 60))     // re-fire
        r = SleptThroughResolution.applyUserAction(to: r, at: t0.addingTimeInterval(40 * 60))      // late again

        let report = SleptThroughResolution.report([r], now: t0.addingTimeInterval(3600), calendar: utc)
        #expect(report.count == 1)               // one ALARM, not two rings
        #expect(report.entries.first?.at == t0)  // attributed to the first unattended ring
    }

    @Test("A user action on an alarm that never rang is a no-op, not a crash")
    func actionWithoutRing() {
        let t0 = Date()
        var r = ring(firstRingAt: t0, openRingAt: nil)
        r = SleptThroughResolution.applyUserAction(to: r, at: t0.addingTimeInterval(9_999))
        #expect(r.unattendedSince == nil)
        #expect(!SleptThroughResolution.isSleptThrough(r, now: t0.addingTimeInterval(86_400)))
    }

    // A clock that jumped backwards must under-report, never invent.
    @Test("A ring stamped in the future is not slept through")
    func backwardsClock() {
        let now = Date()
        let r = ring(firstRingAt: now.addingTimeInterval(7200), openRingAt: now.addingTimeInterval(7200))
        #expect(!SleptThroughResolution.isSleptThrough(r, now: now))
    }
}

// MARK: - "Today"

struct SleptThroughDayBoundaryTests {

    @Test("Only today's slept-through alarms are counted")
    func onlyToday() {
        let yesterday = ring(
            firstRingAt: utcDate("2026-08-04T06:00:00Z"),
            unattendedSince: utcDate("2026-08-04T06:00:00Z"),
            label: "Yesterday"
        )
        let today = ring(
            firstRingAt: utcDate("2026-08-05T06:30:00Z"),
            unattendedSince: utcDate("2026-08-05T06:30:00Z"),
            label: "Today",
            alarmHash: 99
        )
        let report = SleptThroughResolution.report(
            [yesterday, today],
            now: utcDate("2026-08-05T09:00:00Z"),
            calendar: utc
        )
        #expect(report.count == 1)
        #expect(report.entries.map(\.name) == ["Today"])
    }

    @Test("Crossing midnight drops the count to zero with no reset step")
    func midnightRollover() {
        // 23:45, so the ring is already past the 10-minute grace before midnight.
        let r = ring(
            firstRingAt: utcDate("2026-08-05T23:45:00Z"),
            openRingAt: utcDate("2026-08-05T23:45:00Z")
        )
        // Still the 5th, past grace.
        #expect(SleptThroughResolution.report([r], now: utcDate("2026-08-05T23:59:59Z"), calendar: utc).count == 1)
        // One second later it is the 6th and the ring belongs to yesterday.
        #expect(SleptThroughResolution.report([r], now: utcDate("2026-08-06T00:00:01Z"), calendar: utc).count == 0)
    }

    @Test("The day boundary follows the calendar it is given, not UTC")
    func timeZoneRepartitionsHistory() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!   // UTC+9

        let rang = utcDate("2026-08-05T22:00:00Z")             // 07:00 on the 6th in Tokyo
        let r = ring(firstRingAt: rang, unattendedSince: rang)
        let now = utcDate("2026-08-05T23:00:00Z")

        #expect(SleptThroughResolution.report([r], now: now, calendar: utc).count == 1)
        #expect(SleptThroughResolution.report([r], now: now, calendar: tokyo).count == 1)
        // Same instants, a day later in Tokyo terms: gone from "today".
        #expect(SleptThroughResolution.report([r], now: utcDate("2026-08-06T16:00:00Z"), calendar: tokyo).count == 0)
    }

    @Test("Entries are ordered by ring time, and the detail list is capped without lying about the count")
    func orderingAndCap() {
        let base = utcDate("2026-08-05T05:00:00Z")
        let rings = (0..<8).map { i in
            ring(
                firstRingAt: base.addingTimeInterval(Double(i) * 600),
                unattendedSince: base.addingTimeInterval(Double(i) * 600),
                label: "A\(i)",
                alarmHash: 1000 + i
            )
        }
        let report = SleptThroughResolution.report(
            rings,
            now: utcDate("2026-08-05T12:00:00Z"),
            calendar: utc,
            maxDetailEntries: 3
        )
        #expect(report.count == 8)
        #expect(report.entries.map(\.name) == ["A0", "A1", "A2"])
    }

    @Test("A blank label is reported as Untitled rather than an empty string")
    func blankLabel() {
        let t = utcDate("2026-08-05T06:00:00Z")
        let report = SleptThroughResolution.report(
            [ring(firstRingAt: t, unattendedSince: t, label: "")],
            now: utcDate("2026-08-05T07:00:00Z"),
            calendar: utc
        )
        #expect(report.entries.first?.name == "Untitled")
    }
}

// MARK: - Pruning

struct SleptThroughPruneTests {

    @Test("Entries older than maxAge are dropped")
    func prunesByAge() {
        let now = Date()
        let old = ring(firstRingAt: now.addingTimeInterval(-SleptThroughResolution.maxAge - 60), alarmHash: 1)
        let fresh = ring(firstRingAt: now.addingTimeInterval(-60), alarmHash: 2)
        let kept = SleptThroughResolution.prune([old, fresh], now: now)
        #expect(kept.map(\.alarmHash) == [2])
    }

    @Test("The newest entries survive the entry cap")
    func prunesByCount() {
        let now = Date()
        let rings = (0..<10).map { i in
            ring(firstRingAt: now.addingTimeInterval(Double(-i) * 60), alarmHash: i)
        }
        let kept = SleptThroughResolution.prune(rings, now: now, maxEntries: 3)
        #expect(kept.count == 3)
        #expect(Set(kept.map(\.alarmHash)) == [0, 1, 2])
    }

    @Test("A future-stamped entry is kept, so a backwards clock cannot wipe live state")
    func futureEntrySurvivesPruning() {
        let now = Date()
        let future = ring(firstRingAt: now.addingTimeInterval(86_400), alarmHash: 7)
        #expect(SleptThroughResolution.prune([future], now: now).map(\.alarmHash) == [7])
    }

    @Test("lastActivity tracks the most recent of the three timestamps")
    func lastActivityPicksLatest() {
        let t = Date()
        let r = ring(
            firstRingAt: t,
            openRingAt: t.addingTimeInterval(100),
            unattendedSince: t.addingTimeInterval(50)
        )
        #expect(SleptThroughResolution.lastActivity(of: r) == t.addingTimeInterval(100))
    }
}

// MARK: - AlarmKit identity and dedupe

struct AlarmKitAlarmIdentityTests {

    @Test("The four tier UUIDs of one alarm are distinct")
    func tiersAreDistinct() {
        let ids = AlarmKitAlarmIdentity.allTierUUIDs(forAlarmHash: 987_654)
        #expect(ids.count == 4)
        #expect(Set(ids).count == 4)
    }

    // The whole point of the dedupe: four backup UUIDs are ONE alarm.
    @Test("All four tier UUIDs alerting collapse to a single alarm")
    func fourUUIDsCollapseToOne() {
        let h = 987_654
        let alerting = AlarmKitAlarmIdentity.allTierUUIDs(forAlarmHash: h)
        let hashes = AlarmKitAlarmIdentity.alarmHashes(forAlertingIDs: alerting, knownHashes: [h, 111, 222])
        #expect(hashes == [h])
    }

    @Test("Two alarms alerting yield two hashes")
    func twoAlarmsTwoHashes() {
        let a = 100_001, b = 200_002
        let alerting = [
            AlarmKitAlarmIdentity.uuid(forHash: a),
            AlarmKitAlarmIdentity.ringingGuardUUID(forAlarmHash: a),
            AlarmKitAlarmIdentity.weeklyBackupUUID(forAlarmHash: b),
        ]
        #expect(AlarmKitAlarmIdentity.alarmHashes(forAlertingIDs: alerting, knownHashes: [a, b]) == [a, b])
    }

    @Test("An id belonging to no known alarm is dropped, not guessed at")
    func unknownIDsDropped() {
        let hashes = AlarmKitAlarmIdentity.alarmHashes(
            forAlertingIDs: [UUID(), AlarmKitAlarmIdentity.uuid(forHash: 5)],
            knownHashes: [5]
        )
        #expect(hashes == [5])
    }

    @Test("Empty inputs yield nothing rather than throwing")
    func emptyInputs() {
        #expect(AlarmKitAlarmIdentity.alarmHashes(forAlertingIDs: [], knownHashes: [1]).isEmpty)
        #expect(AlarmKitAlarmIdentity.alarmHashes(forAlertingIDs: [UUID()], knownHashes: []).isEmpty)
    }

    // The masks and the formatting are a PERSISTED identity — an AlarmKit alarm
    // armed by an older build is still resident under the old id. Pinning the
    // literals makes an accidental change fail loudly instead of silently
    // orphaning every scheduled backup.
    @Test("Tier masks and the hash→UUID formatting are pinned")
    func identityIsPinned() {
        #expect(AlarmKitAlarmIdentity.snoozeMask == 0x534E4F4F5A45)
        #expect(AlarmKitAlarmIdentity.ringingGuardMask == 0x524E47554152)
        #expect(AlarmKitAlarmIdentity.weeklyBackupMask == 0x574B4C59)
        #expect(AlarmKitAlarmIdentity.uuid(forHash: 1).uuidString.lowercased()
                == "00000000-0000-0000-0000-000000000001")
        #expect(AlarmKitAlarmIdentity.uuid(forHash: -1) == AlarmKitAlarmIdentity.uuid(forHash: 1))
    }
}

// MARK: - The ledger

struct UnresolvedRingLedgerTests {

    private func makeLedger() -> (UnresolvedRingLedger, UserDefaults, String) {
        let name = "UnresolvedRingLedgerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (UnresolvedRingLedger(userDefaults: defaults), defaults, name)
    }

    private func tearDown(_ defaults: UserDefaults, _ name: String) {
        defaults.removePersistentDomain(forName: name)
    }

    @Test("An absent ledger reads as nothing known, never an error")
    func absentLedgerIsEmpty() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }
        #expect(ledger.rings().isEmpty)
        #expect(ledger.report().count == 0)
    }

    @Test("A corrupt ledger degrades to empty rather than throwing")
    func corruptLedgerIsEmpty() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        // Wrong top-level type entirely.
        defaults.set("not a dictionary", forKey: UnresolvedRingLedger.storageKey)
        #expect(ledger.rings().isEmpty)

        // Right type, junk inside: unparseable key, wrong row type, missing
        // timestamp. One good row survives; nothing throws.
        defaults.set(
            [
                "not-an-int": ["first": 1.0],
                "12": "not a dictionary",
                "13": ["label": "no timestamp"],
                "14": ["first": 1_754_380_800.0, "label": "good", "index": 2],
            ],
            forKey: UnresolvedRingLedger.storageKey
        )
        let rings = ledger.rings()
        #expect(rings.map(\.alarmHash) == [14])
        #expect(rings.first?.label == "good")
    }

    @Test("An entry survives a round-trip through UserDefaults with every field intact")
    func roundTrip() throws {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        let t0 = anchorNow
        ledger.noteRingStarted(alarmHash: 77, label: "Work", alarmIndex: 4, at: t0)
        let stored = try #require(ledger.rings().first)
        #expect(stored.alarmHash == 77)
        #expect(stored.label == "Work")
        #expect(stored.alarmIndex == 4)
        #expect(stored.firstRingAt == t0)
        #expect(stored.openRingAt == t0)
        #expect(stored.unattendedSince == nil)

        // Late dismissal latches through the store, not just in memory.
        ledger.noteUserAction(alarmHash: 77, at: t0.addingTimeInterval(grace + 1))
        #expect(ledger.rings().first?.unattendedSince == t0)
        #expect(ledger.rings().first?.openRingAt == nil)
    }

    @Test("A user action for an alarm with no entry creates nothing")
    func actionWithoutEntryCreatesNothing() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }
        ledger.noteUserAction(alarmHash: 5)
        #expect(ledger.rings().isEmpty)
    }

    // Prevents yesterday's still-resident `.alerting` alarm being dragged into
    // today's count on every foreground, forever.
    @Test("Discovery is create-only: a second discovery never moves the timestamp")
    func discoveryIsCreateOnly() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        let now = anchorNow
        let yesterday = sixAMToday(now).addingTimeInterval(-86_400)
        ledger.noteDiscoveredAlerting(alarmHash: 9, label: "Work", alarmIndex: 1, at: yesterday)
        ledger.noteDiscoveredAlerting(alarmHash: 9, label: "Work", alarmIndex: 1, at: now)
        #expect(ledger.rings().first?.openRingAt == yesterday)
        // So it belongs to yesterday, and is absent from today's count.
        #expect(ledger.report(now: now, calendar: utc).count == 0)
    }

    @Test("Discovery never disturbs a live ring's own, more accurate, start time")
    func discoveryDoesNotOverwriteALiveRing() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        let now = anchorNow
        let rang = now.addingTimeInterval(-3 * 3600)
        ledger.noteRingStarted(alarmHash: 9, label: "Work", alarmIndex: 1, at: rang)
        ledger.noteDiscoveredAlerting(alarmHash: 9, label: "Work", alarmIndex: 1, at: now)
        #expect(ledger.rings().first?.openRingAt == rang)
    }

    @Test("A rename is picked up on the next ring")
    func labelRefreshes() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }
        let t0 = anchorNow
        ledger.noteRingStarted(alarmHash: 9, label: "Old", alarmIndex: 1, at: t0)
        ledger.noteUserAction(alarmHash: 9, at: t0.addingTimeInterval(5))
        ledger.noteRingStarted(alarmHash: 9, label: "New", alarmIndex: 2, at: t0.addingTimeInterval(600))
        #expect(ledger.rings().first?.label == "New")
        #expect(ledger.rings().first?.alarmIndex == 2)
    }

    @Test("Writes stay in their own key and never touch the recovery keys")
    func recoveryKeysUntouched() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        ledger.noteRingStarted(alarmHash: 1, label: "A", alarmIndex: 1)
        ledger.noteUserAction(alarmHash: 1)
        ledger.noteDiscoveredAlerting(alarmHash: 2, label: "B", alarmIndex: 2)

        // The suite's own persistent domain is exactly what this ledger wrote —
        // nothing named `HaWakeAlarm.activeRingingAlarmID` or
        // `HaWakeAlarm.pendingAlarm*`, which are alarm RECOVERY state. A bug
        // here must be structurally incapable of making the app believe an
        // alarm is (or is not) ringing.
        let domain = defaults.persistentDomain(forName: name) ?? [:]
        #expect(Set(domain.keys) == [UnresolvedRingLedger.storageKey])
    }

    @Test("The ledger prunes on write, so it cannot grow without bound")
    func prunesOnWrite() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }
        for i in 0..<(SleptThroughResolution.maxEntries + 20) {
            ledger.noteRingStarted(alarmHash: i, label: "A\(i)", alarmIndex: i)
        }
        #expect(ledger.rings().count <= SleptThroughResolution.maxEntries)
    }

    @Test("End to end: two alarms slept through this morning, one dismissed promptly")
    func endToEnd() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        let six = sixAMToday(anchorNow)
        ledger.noteRingStarted(alarmHash: 1, label: "First", alarmIndex: 1, at: six)
        ledger.noteRingStarted(alarmHash: 2, label: "Second", alarmIndex: 2, at: six.addingTimeInterval(1800))
        ledger.noteRingStarted(alarmHash: 3, label: "Third", alarmIndex: 3, at: six.addingTimeInterval(3600))
        // Only the third one woke them.
        ledger.noteUserAction(alarmHash: 3, at: six.addingTimeInterval(3610))

        let report = ledger.report(now: six.addingTimeInterval(4 * 3600), calendar: utc)
        #expect(report.count == 2)
        #expect(report.entries.map(\.name) == ["First", "Second"])
        #expect(report.entries.map(\.alarmIndex) == [1, 2])
        #expect(report.entries.first?.at == six)
    }
}
