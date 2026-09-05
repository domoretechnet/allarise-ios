//
//  SleepTimerBedtimeAlarmClaimTests.swift
//  HaWake Alarm V2Tests
//
//  Who owns a kid's bedtime alarm row, and when they let go of it (al-02is).
//
//  The bedtime alarm (al-5a94) is a real one-shot Alarm the sleep-timer store
//  creates at bedTime and tracks by stableID in a slug→id map. Two different
//  places delete that row — the dismissal path in AlarmListView the moment the
//  kid taps it off, and the store's own cancel / removeKid / expiry sweeps if it
//  never rang — so exactly one of them must end up holding the claim. If the
//  release leaked, a cancel after a dismissal would chase a row SwiftData has
//  already deleted; if it over-released, a second kid's alarm would be orphaned
//  in the list with nothing left pointing at it.
//
//  `releasingBedtimeAlarm` is the pure half of that hand-off: map in, owner and
//  remaining map out. No singleton, no ModelContainer, no UserDefaults.
//

import Testing
import Foundation
@testable import HaWake_Alarm_V2

struct SleepTimerBedtimeAlarmClaimTests {

    private static let brysonAlarm = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let siblingAlarm = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let strangerAlarm = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private static let map: [String: UUID] = [
        "bryson": brysonAlarm,
        "harper": siblingAlarm,
    ]

    @Test("A dismissed bedtime alarm names its kid and leaves the map")
    func releasesTheOwningKid() {
        let (slug, remaining) = SleepTimerStore.releasingBedtimeAlarm(Self.brysonAlarm, from: Self.map)
        #expect(slug == "bryson")
        #expect(remaining["bryson"] == nil)
    }

    @Test("Releasing one kid's alarm never disturbs a sibling's")
    func siblingClaimSurvives() {
        let (_, remaining) = SleepTimerStore.releasingBedtimeAlarm(Self.brysonAlarm, from: Self.map)
        #expect(remaining["harper"] == Self.siblingAlarm)
        #expect(remaining.count == 1)
    }

    @Test("An alarm we do not own is refused, and the map is untouched")
    func foreignAlarmIsNotClaimed() {
        // Every ordinary alarm dismissal runs through this lookup. Answering
        // "yes" for one of them would delete a real alarm out of the user's list.
        let (slug, remaining) = SleepTimerStore.releasingBedtimeAlarm(Self.strangerAlarm, from: Self.map)
        #expect(slug == nil)
        #expect(remaining == Self.map)
    }

    @Test("Releasing the same alarm twice is a no-op the second time")
    func releaseIsIdempotent() {
        // The dismissal path and a cancel racing on the same alarm: whoever
        // arrives second must be told "not mine" rather than pick another kid.
        let (_, once) = SleepTimerStore.releasingBedtimeAlarm(Self.brysonAlarm, from: Self.map)
        let (slug, twice) = SleepTimerStore.releasingBedtimeAlarm(Self.brysonAlarm, from: once)
        #expect(slug == nil)
        #expect(twice == once)
    }

    @Test("An empty map claims nothing")
    func emptyMapClaimsNothing() {
        let (slug, remaining) = SleepTimerStore.releasingBedtimeAlarm(Self.brysonAlarm, from: [:])
        #expect(slug == nil)
        #expect(remaining.isEmpty)
    }
}
