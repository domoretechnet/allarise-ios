//
//  MissionConsolidationResolutionTests.swift
//  HaWake Alarm V2Tests
//
//  Cover for al-bee.7: when the user sleeps through several alarms, only the
//  HARDEST single mission set survives; the rest are dismissed with it.
//
//  The tests that matter most are the ones asserting nothing changes: a stack of
//  ONE is the 99% case, and it must be provably today's behaviour. A resolver
//  that ever collapsed something there would silently drop a wake event the user
//  configured — far worse than the feature is valuable.
//
//  Consolidation is always on (product decision 2026-08-06); the
//  `combineStackedAlarms` setting was removed before ever shipping, so there is
//  no OFF path left to test.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

// MARK: - Fixtures

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func alarm(
    _ id: Int,
    missions: Int,
    grace: Double = 0,
    at offset: TimeInterval = 0,
    isAlert: Bool = false,
    snoozesRemaining: Int = MissionConsolidationResolution.unlimitedSnoozes
) -> StackedAlarm {
    StackedAlarm(
        alarmID: id,
        isAlert: isAlert,
        missionCount: missions,
        totalGracePeriod: grace,
        ringStartedAt: t0.addingTimeInterval(offset),
        snoozesRemaining: snoozesRemaining
    )
}

// MARK: - The 99% case: nothing to consolidate

struct MissionConsolidationNoOpTests {

    /// THE test. One alarm, nothing queued behind it — the overwhelmingly
    /// common dismissal. The plan must be the untouched no-op, field for field,
    /// so `dismissAlarm` runs exactly the code it ran before this feature.
    @Test("A stack of one produces today's behaviour verbatim")
    func stackOfOneIsUntouched() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 5, grace: 300),
            queued: []
        )
        #expect(plan.isNoOp)
        #expect(plan == MissionConsolidationResolution.noOp)
        #expect(plan.collapsedAlarmIDs.isEmpty)
        #expect(plan.survivingQueuedAlarmID == nil)
        #expect(plan.snoozeAllowance == nil)
    }

    /// A missionless (single-tap) alarm dismissed alone is still a no-op. Zero
    /// missions is not a reason to reach for the queue.
    @Test("A missionless alarm dismissed alone is a no-op")
    func missionlessSoloAlarmIsUntouched() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 0),
            queued: []
        )
        #expect(plan == MissionConsolidationResolution.noOp)
    }

    /// A queue that is nothing but alerts leaves the plan empty — alerts are
    /// never collapsed and never survive anything.
    @Test("A queue of only alerts is a no-op")
    func alertOnlyQueueIsNoOp() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 3, grace: 120),
            queued: [alarm(2, missions: 0, isAlert: true, snoozesRemaining: 0)]
        )
        #expect(plan == MissionConsolidationResolution.noOp)
    }
}

// MARK: - Ranking

struct MissionConsolidationRankingTests {

    @Test("Ranked by mission count: the longest ladder survives")
    func rankedByMissionCount() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 1, grace: 20),
            queued: [
                alarm(2, missions: 2, grace: 60, at: 600),
                alarm(3, missions: 5, grace: 300, at: 1200),
                alarm(4, missions: 3, grace: 400, at: 1800),
            ]
        )
        #expect(plan.survivingQueuedAlarmID == 3)
        #expect(Set(plan.collapsedAlarmIDs) == [2, 4])
    }

    /// The rule the plan exists to protect: the BACKUP alarm is usually the
    /// weaker one. A hard ladder at 06:00 with a plain tap at 06:30 as insurance
    /// must not let the sleeper escape the ladder with one tap.
    @Test("The weaker later alarm never displaces the harder earlier one")
    func laterWeakerAlarmDoesNotWin() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 5, grace: 300),
            queued: [alarm(2, missions: 1, grace: 12, at: 1800)]
        )
        // The user has already done the hard set: nothing survives.
        #expect(plan.survivingQueuedAlarmID == nil)
        #expect(plan.collapsedAlarmIDs == [2])
    }

    @Test("Equal mission counts: the larger summed grace period wins")
    func tieBrokenBySummedGracePeriod() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 1, grace: 20),
            queued: [
                alarm(2, missions: 3, grace: 90, at: 600),
                alarm(3, missions: 3, grace: 240, at: 1200),
                alarm(4, missions: 3, grace: 150, at: 1800),
            ]
        )
        #expect(plan.survivingQueuedAlarmID == 3)
        #expect(Set(plan.collapsedAlarmIDs) == [2, 4])
    }

    /// Summed grace beats mission count only as a TIE-break — a shorter ladder
    /// with a huge grace budget must not outrank a longer one.
    @Test("Summed grace never overrides mission count")
    func gracePeriodIsOnlyATieBreak() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 1, grace: 10),
            queued: [
                alarm(2, missions: 2, grace: 9_999, at: 600),
                alarm(3, missions: 4, grace: 40, at: 1200),
            ]
        )
        #expect(plan.survivingQueuedAlarmID == 3)
        #expect(plan.collapsedAlarmIDs == [2])
    }

    @Test("Equal count and equal grace: the most recent queued alarm wins")
    func tieBrokenByRecency() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 1, grace: 20),
            queued: [
                alarm(2, missions: 3, grace: 120, at: 600),
                alarm(3, missions: 3, grace: 120, at: 2400),
                alarm(4, missions: 3, grace: 120, at: 1200),
            ]
        )
        #expect(plan.survivingQueuedAlarmID == 3)
        #expect(Set(plan.collapsedAlarmIDs) == [2, 4])
    }

    /// Recency breaks ties BETWEEN QUEUED ALARMS only. Against the set the user
    /// has just finished a tie collapses: re-demanding identical work is the
    /// complaint this feature exists to fix.
    @Test("A queued alarm identical to the one just completed is collapsed, not re-demanded")
    func dismissedAlarmWinsTies() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 3, grace: 120),
            queued: [alarm(2, missions: 3, grace: 120, at: 1800)]
        )
        #expect(plan.survivingQueuedAlarmID == nil)
        #expect(plan.collapsedAlarmIDs == [2])
    }

    /// Floating-point noise from summing doubles must not decide a tie.
    @Test("Grace sums within epsilon count as a tie")
    func gracePeriodEpsilonHoldsTheTie() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 3, grace: 120.0),
            queued: [alarm(2, missions: 3, grace: 120.000_01, at: 1800)]
        )
        #expect(plan.survivingQueuedAlarmID == nil)
        #expect(plan.collapsedAlarmIDs == [2])
    }

    @Test("A strictly harder queued alarm survives and is presented")
    func strictlyHarderQueuedAlarmSurvives() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 1, grace: 12),
            queued: [
                alarm(2, missions: 5, grace: 300, at: 600),
                alarm(3, missions: 1, grace: 12, at: 1200),
            ]
        )
        #expect(plan.survivingQueuedAlarmID == 2)
        #expect(plan.collapsedAlarmIDs == [3])
    }
}

// MARK: - Alerts never participate

struct MissionConsolidationAlertTests {

    @Test("A queued alert is neither collapsed nor a candidate to survive")
    func queuedAlertIsUntouched() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 4, grace: 200),
            queued: [
                alarm(2, missions: 0, at: 600, isAlert: true),
                alarm(3, missions: 1, grace: 12, at: 1200),
            ]
        )
        #expect(plan.collapsedAlarmIDs == [3])
        #expect(plan.collapsedAlarmIDs.contains(2) == false)
        #expect(plan.survivingQueuedAlarmID == nil)
    }

    /// An alert with a nominally huge mission set (it cannot have one, but the
    /// resolver must not depend on that) still never wins: with the alert out of
    /// the running the only candidate is alarm 3, which survives, so nothing is
    /// collapsed and both queued entries are presented exactly as today.
    @Test("An alert never outranks a wake alarm")
    func alertNeverWins() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 1, grace: 12),
            queued: [
                alarm(2, missions: 99, grace: 9_999, at: 600, isAlert: true),
                alarm(3, missions: 2, grace: 40, at: 1200),
            ]
        )
        #expect(plan == MissionConsolidationResolution.noOp)
    }

    /// Dismissing an ALERT is acknowledging a notification, not completing a
    /// wake event. It must never collapse the wake alarms behind it.
    @Test("Dismissing an alert collapses nothing")
    func dismissedAlertCollapsesNothing() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 0, isAlert: true),
            queued: [
                alarm(2, missions: 1, grace: 12, at: 600),
                alarm(3, missions: 5, grace: 300, at: 1200),
            ]
        )
        #expect(plan == MissionConsolidationResolution.noOp)
    }
}

// MARK: - Snooze allowance

struct MissionConsolidationSnoozeAllowanceTests {

    /// A four-alarm stack must not grant four alarms' worth of snoozes: the
    /// survivor inherits the STRICTEST remaining allowance in the stack.
    @Test("The survivor takes the strictest remaining allowance")
    func strictestAllowanceWins() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 1, grace: 12, snoozesRemaining: 3),
            queued: [
                alarm(2, missions: 5, grace: 300, at: 600, snoozesRemaining: 5),
                alarm(3, missions: 1, grace: 12, at: 1200, snoozesRemaining: 1),
                alarm(4, missions: 1, grace: 12, at: 1800, snoozesRemaining: 4),
            ]
        )
        #expect(plan.survivingQueuedAlarmID == 2)
        #expect(plan.snoozeAllowance == 1)
    }

    /// The alarm just dismissed is part of the stack for this purpose: the user
    /// already spent that morning's snoozes.
    @Test("The dismissed alarm's exhausted allowance binds the survivor")
    func dismissedAlarmAllowanceCounts() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 1, grace: 12, snoozesRemaining: 0),
            queued: [
                alarm(2, missions: 4, grace: 200, at: 600, snoozesRemaining: 9),
                alarm(3, missions: 1, grace: 12, at: 1200, snoozesRemaining: 9),
            ]
        )
        #expect(plan.survivingQueuedAlarmID == 2)
        #expect(plan.snoozeAllowance == 0)
    }

    @Test("Every alarm unlimited: the allowance stays unlimited")
    func allUnlimitedStaysUnlimited() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 1, grace: 12),
            queued: [
                alarm(2, missions: 3, grace: 120, at: 600),
                alarm(3, missions: 1, grace: 12, at: 1200),
            ]
        )
        #expect(plan.survivingQueuedAlarmID == 2)
        #expect(plan.snoozeAllowance == MissionConsolidationResolution.unlimitedSnoozes)
    }

    /// No survivor means no ring is left to snooze, so there is nothing to cap.
    @Test("No survivor: no allowance is imposed")
    func noSurvivorNoAllowance() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 5, grace: 300, snoozesRemaining: 2),
            queued: [alarm(2, missions: 1, grace: 12, at: 600, snoozesRemaining: 0)]
        )
        #expect(plan.survivingQueuedAlarmID == nil)
        #expect(plan.snoozeAllowance == nil)
    }

    @Test("snoozesRemaining normalises the app's 0-means-unlimited convention")
    func snoozesRemainingNormalisation() {
        #expect(MissionConsolidationResolution.snoozesRemaining(maxSnoozeCount: 0, snoozeCount: 7)
                == MissionConsolidationResolution.unlimitedSnoozes)
        #expect(MissionConsolidationResolution.snoozesRemaining(maxSnoozeCount: 3, snoozeCount: 1) == 2)
        // A count past the maximum can never read negative.
        #expect(MissionConsolidationResolution.snoozesRemaining(maxSnoozeCount: 3, snoozeCount: 9) == 0)
    }
}

// MARK: - A late-arriving harder alarm

struct MissionConsolidationLateArrivalTests {

    /// The requirement in flight is whatever was resolved when the ring was
    /// presented. This type is consulted only at a dismiss junction, so the
    /// arrival of a harder alarm cannot add slots to the sequence on screen —
    /// modelled here as the two resolutions that actually happen.
    @Test("A harder alarm arriving mid-mission is absorbed at the NEXT dismiss, not the current one")
    func lateHarderAlarmDoesNotChangeWorkInFlight() {
        // 06:00 fires with a one-tap set; 06:30's five-mission ladder and a
        // second one-tap alarm are queued behind it. At 06:00's dismiss the
        // ladder is strictly harder, so it survives and the tap is collapsed.
        let first = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 1, grace: 12),
            queued: [
                alarm(2, missions: 5, grace: 300, at: 1800),
                alarm(4, missions: 1, grace: 12, at: 2400),
            ]
        )
        #expect(first.survivingQueuedAlarmID == 2)
        #expect(first.collapsedAlarmIDs == [4])

        // While the user works alarm 2's ladder, a HARDER alarm 3 fires and is
        // queued. No resolution runs — the sequence on screen is untouched,
        // which is the whole guarantee. Alarm 3 is considered for the first time
        // when alarm 2 is finally dismissed, and is presented rather than
        // grafted onto the ladder the user was already doing.
        let second = MissionConsolidationResolution.resolve(
            dismissed: alarm(2, missions: 5, grace: 300),
            queued: [alarm(3, missions: 7, grace: 600, at: 3600)]
        )
        // Nothing to collapse — one candidate, and it survives — so the plan is
        // the no-op and alarm 3 is dequeued in the ordinary way.
        #expect(second == MissionConsolidationResolution.noOp)
    }

    /// The same arrival, but the late alarm is NOT harder: it is collapsed at
    /// the dismiss it arrived behind, and the user does nothing more.
    @Test("A late alarm no harder than the one in flight is collapsed at its dismiss")
    func lateWeakerAlarmIsCollapsed() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(2, missions: 5, grace: 300),
            queued: [alarm(3, missions: 2, grace: 60, at: 3600)]
        )
        #expect(plan.survivingQueuedAlarmID == nil)
        #expect(plan.collapsedAlarmIDs == [3])
    }

    /// Monotonicity: more slept-through alarms can only ever raise the surviving
    /// requirement, never lower it.
    @Test("Adding a weaker alarm to a stack never lowers the surviving requirement")
    func consolidationIsMonotonic() {
        let dismissed = alarm(1, missions: 1, grace: 12)
        let hard = alarm(2, missions: 5, grace: 300, at: 600)
        let weak = alarm(3, missions: 1, grace: 12, at: 1200)

        let withoutWeak = MissionConsolidationResolution.resolve(
            dismissed: dismissed, queued: [hard]
        )
        let withWeak = MissionConsolidationResolution.resolve(
            dismissed: dismissed, queued: [hard, weak]
        )
        // Without the weak alarm nothing collapses and the hard one is simply
        // dequeued; with it, the hard one still stands and only the weak one is
        // dropped. Either way the user's remaining work is alarm 2's ladder —
        // adding a slept-through alarm never reduced it.
        #expect(withoutWeak == MissionConsolidationResolution.noOp)
        #expect(withWeak.survivingQueuedAlarmID == 2)
        #expect(withWeak.collapsedAlarmIDs == [3])
    }
}

// MARK: - Queue-change resolution (al-bee.11)

/// The dismiss junction only compares a queued alarm against work already done,
/// so an ASCENDING stack (a weak alarm showing, a harder one queued behind it)
/// consolidated nothing and the sleeper did every set. `resolveOnQueueChange`
/// closes that gap while the showing alarm is still UNENGAGED. Engagement is
/// absolute: once the user has touched the ring, nothing re-resolves.
struct MissionConsolidationQueueChangeTests {

    /// The measured incident: a one-mission alarm showing unengaged, a
    /// three-mission alarm queued behind it. The harder alarm is promoted so the
    /// showing alarm rolls into the stack instead of demanding its own set first.
    @Test("Ascending stack, unengaged: the strictly harder queued alarm is promoted")
    func ascendingUnengagedPromotes() {
        let plan = MissionConsolidationResolution.resolveOnQueueChange(
            showing: alarm(3, missions: 1, grace: 20),
            showingEngaged: false,
            queued: [alarm(4, missions: 3, grace: 120, at: 600)]
        )
        #expect(plan.promotedAlarmID == 4)
        #expect(plan.isNoOp == false)
    }

    /// The latch is absolute: the identical stack, but the user has engaged the
    /// showing alarm, must never swap the requirement under their fingers.
    @Test("Engaged showing alarm: never re-resolved, whatever arrives")
    func engagedShowingIsNoOp() {
        let plan = MissionConsolidationResolution.resolveOnQueueChange(
            showing: alarm(3, missions: 1, grace: 20),
            showingEngaged: true,
            queued: [alarm(4, missions: 3, grace: 120, at: 600)]
        )
        #expect(plan == MissionConsolidationResolution.noOpQueueChange)
    }

    /// A tie keeps the showing alarm — a queued alarm of equal difficulty
    /// demands nothing the showing ring does not already.
    @Test("Equal difficulty queued: the showing alarm is kept")
    func equalQueuedIsNoOp() {
        let plan = MissionConsolidationResolution.resolveOnQueueChange(
            showing: alarm(3, missions: 3, grace: 120),
            showingEngaged: false,
            queued: [alarm(4, missions: 3, grace: 120, at: 600)]
        )
        #expect(plan == MissionConsolidationResolution.noOpQueueChange)
    }

    /// A weaker queued alarm never displaces the showing one — the dismiss
    /// junction already collapses it correctly when the showing alarm is done.
    @Test("Descending stack: a weaker queued alarm never promotes")
    func descendingIsNoOp() {
        let plan = MissionConsolidationResolution.resolveOnQueueChange(
            showing: alarm(3, missions: 5, grace: 300),
            showingEngaged: false,
            queued: [alarm(4, missions: 1, grace: 12, at: 600)]
        )
        #expect(plan == MissionConsolidationResolution.noOpQueueChange)
    }

    /// An alert on screen is a transient notification, never a wake set to swap.
    @Test("Showing an alert: never promotes anything")
    func showingAlertIsNoOp() {
        let plan = MissionConsolidationResolution.resolveOnQueueChange(
            showing: alarm(3, missions: 0, isAlert: true),
            showingEngaged: false,
            queued: [alarm(4, missions: 3, grace: 120, at: 600)]
        )
        #expect(plan == MissionConsolidationResolution.noOpQueueChange)
    }

    /// Queued alerts are filtered out — an alert-only queue promotes nothing even
    /// though its nominal mission count is huge.
    @Test("Queued alerts are filtered: an alert-only queue is a no-op")
    func queuedAlertsFilteredOut() {
        let plan = MissionConsolidationResolution.resolveOnQueueChange(
            showing: alarm(3, missions: 1, grace: 20),
            showingEngaged: false,
            queued: [alarm(4, missions: 99, grace: 9_999, at: 600, isAlert: true)]
        )
        #expect(plan == MissionConsolidationResolution.noOpQueueChange)
    }

    /// With several queued alarms the strongest is chosen recency-inclusively
    /// between candidates, but promotion still requires strictly-harder-ignoring
    /// -recency versus the showing alarm.
    @Test("Multiple queued: strongest picked recency-inclusively, promoted only if strictly harder")
    func multipleQueuedPicksStrongest() {
        // Alarms 4 and 5 tie on count and grace; recency breaks it towards 5,
        // and 5 (3 missions) is strictly harder than the showing 1-mission alarm.
        let plan = MissionConsolidationResolution.resolveOnQueueChange(
            showing: alarm(3, missions: 1, grace: 20),
            showingEngaged: false,
            queued: [
                alarm(4, missions: 3, grace: 120, at: 600),
                alarm(5, missions: 3, grace: 120, at: 1200),
                alarm(6, missions: 2, grace: 80, at: 1800),
            ]
        )
        #expect(plan.promotedAlarmID == 5)
    }

    /// The strongest queued alarm tying the showing one's difficulty is not
    /// strictly harder, so nothing promotes even with several queued.
    @Test("Multiple queued but none strictly harder than the showing alarm: no-op")
    func multipleQueuedNoneStrictlyHarder() {
        let plan = MissionConsolidationResolution.resolveOnQueueChange(
            showing: alarm(3, missions: 3, grace: 120),
            showingEngaged: false,
            queued: [
                alarm(4, missions: 3, grace: 120, at: 600),
                alarm(5, missions: 1, grace: 12, at: 1200),
            ]
        )
        #expect(plan == MissionConsolidationResolution.noOpQueueChange)
    }
}

// MARK: - Queue ordering

struct MissionConsolidationOrderingTests {

    /// Consolidation only ever REMOVES entries. It must never reorder, or a
    /// queued alert would jump position and the FIFO contract the queue
    /// documents would stop holding.
    @Test("Collapsed ids are reported in queue order")
    func collapsedIDsPreserveQueueOrder() {
        let plan = MissionConsolidationResolution.resolve(
            dismissed: alarm(1, missions: 5, grace: 300),
            queued: [
                alarm(2, missions: 1, grace: 12, at: 600),
                alarm(3, missions: 0, at: 900, isAlert: true),
                alarm(4, missions: 2, grace: 40, at: 1200),
                alarm(5, missions: 1, grace: 12, at: 1800),
            ]
        )
        #expect(plan.collapsedAlarmIDs == [2, 4, 5])
        #expect(plan.survivingQueuedAlarmID == nil)
    }
}
