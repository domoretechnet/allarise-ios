//
//  MissionConsolidationResolution.swift
//  HaWake Alarm V2
//
//  One decision, asked at every dismiss: now that this alarm is done, does the
//  user still owe the stack behind it any missions?
//
//  ═══════════════════════════════════════════════════════════════════════
//  THE PROBLEM
//  ═══════════════════════════════════════════════════════════════════════
//
//  Sleep through six alarms with five missions each and the app demands ~30
//  missions before the noise stops. Every one of those alarms rang, every one
//  is queued (`AlarmWindowManager.alarmQueue`), and today every one must be
//  dismissed in full. That is bad UX and arguably a wake-challenge
//  accessibility failure.
//
//  ═══════════════════════════════════════════════════════════════════════
//  THE POLICY: THE HARDEST SINGLE SET SURVIVES
//  ═══════════════════════════════════════════════════════════════════════
//
//  Decided in `Documents/working-notes/PLAN-sleep-through-stack.md`. Two
//  alternatives were rejected for reasons worth keeping visible:
//
//  * **"Newest alarm only"** — because THE BACKUP ALARM IS USUALLY THE WEAKER
//    ONE. People set a hard ladder at 06:00 and a plain tap at 06:30 as
//    insurance. Newest-only would let a sleeper escape the ladder with one tap,
//    which inverts the whole point of setting it.
//  * **"Union of distinct mission types"** — it synthesises a sequence the user
//    never configured, and it does not scale: as the mission vocabulary grows a
//    cap has to choose between types, and choosing needs a difficulty metric,
//    which is exactly the invented number this rule avoids.
//
//  Hardest-set-survives is monotonic (more slept-through alarms can only raise
//  the maximum), needs no invented metric, and every mission the user ends up
//  doing is one they configured themselves. Ranking, all from data that already
//  exists on the alarm:
//
//    1. `missionSequence.count`
//    2. tie-break: summed `Mission.calculatedGracePeriod` — the app's own
//       existing proxy for how long a mission takes
//    3. tie-break: the most recent alarm
//
//  ═══════════════════════════════════════════════════════════════════════
//  WHY THE ALARM JUST COMPLETED WINS TIES
//  ═══════════════════════════════════════════════════════════════════════
//
//  Rule 3 breaks ties **among the queued candidates only**. Against the alarm
//  the user has just finished, a tie collapses: a queued alarm survives only if
//  it is STRICTLY harder (more slots, or the same slots and more grace).
//
//  If it were otherwise, two identical alarms would make the user do the same
//  ladder twice — which is precisely the complaint this feature exists to fix,
//  and a "tie" means the survivor would demand nothing the user has not already
//  just done. Recency is a tie-break between two alarms that are both still
//  owed, not a reason to re-demand work already completed.
//
//  ═══════════════════════════════════════════════════════════════════════
//  A LATE-ARRIVING HARDER ALARM NEVER CHANGES WORK IN FLIGHT
//  ═══════════════════════════════════════════════════════════════════════
//
//  This type is only ever consulted at a **dismiss junction**, never while a
//  mission sequence is on screen. So an alarm that fires mid-mission — even a
//  much harder one — cannot retroactively add slots to what the user is doing.
//  It is queued exactly as today (silent until presented, per
//  `AlarmFireAudioResolution`), and it is considered for the first time when
//  the in-flight alarm is dismissed. At that point it is a normal member of the
//  stack: strictly harder, so it survives and is presented; not harder, so it
//  is collapsed.
//
//  The alternative — re-resolving continuously and swapping the requirement
//  under the user's fingers — is the hostile behaviour to avoid. The
//  requirement for a ring is fixed the moment that ring is presented.
//
//  ═══════════════════════════════════════════════════════════════════════
//  WHAT CONSOLIDATION MAY AND MAY NOT DO
//  ═══════════════════════════════════════════════════════════════════════
//
//  * It may only ever reduce **user-facing work after a ring is already
//    audible**. Nothing here is consulted by any path that schedules, arms or
//    fires an alarm; every AlarmKit tier is armed exactly as before, and the
//    memory-only queue dies with the process, so a crash or force-kill costs
//    the consolidation, never the alarm.
//  * It never reduces the number of rings or wake mechanisms. A collapsed alarm
//    already rang (or was queued behind a ring the user is attending); what it
//    loses is a second round of missions, not a wake event.
//  * `.alert` alarms never participate and are never collapsed. They are
//    transient Home Assistant notifications, not wake events, and are
//    special-cased throughout the app already.
//  * Snoozing collapses nothing (`PLAN-sleep-through-stack`, "the remaining
//    calls" #2). The queue drains one at a time on snooze exactly as today.
//
//  Precedent for the shape: `RingingGuardResolution`, `AlarmOverrideResolution`,
//  `AlarmDismissResolution`, `AlarmFireAudioResolution`,
//  `SleptThroughResolution`. No window, no audio session, no `ModelContainer`,
//  no `Date()` — every timestamp is passed in.
//

import Foundation

// MARK: - One alarm in the stack

/// An alarm in the stack, reduced to the facts the ranking needs.
///
/// Snapshotted by the caller at the dismiss junction. Nothing is re-read later:
/// an ephemeral alarm's SwiftData row is deleted when its dismissal is handled,
/// and reading it afterwards is a crash, not a blank value.
struct StackedAlarm: Equatable {

    /// `Alarm.stableHash` — the identity the queue, AlarmKit and the recovery
    /// paths all key on.
    let alarmID: Int

    /// `.alert` missions never participate in consolidation.
    let isAlert: Bool

    /// `Alarm.missionSequence.count`. The primary ranking key.
    let missionCount: Int

    /// Summed `Mission.calculatedGracePeriod` across the sequence — the app's
    /// own proxy for how long the set takes. First tie-break.
    let totalGracePeriod: Double

    /// When this alarm's ring began. Second tie-break, and only ever compared
    /// BETWEEN QUEUED ALARMS (see the header).
    let ringStartedAt: Date

    /// Snoozes this alarm still allows, `Int.max` for unlimited. Used for the
    /// strictest-allowance rule, never for ranking.
    let snoozesRemaining: Int

    init(
        alarmID: Int,
        isAlert: Bool,
        missionCount: Int,
        totalGracePeriod: Double,
        ringStartedAt: Date,
        snoozesRemaining: Int = MissionConsolidationResolution.unlimitedSnoozes
    ) {
        self.alarmID = alarmID
        self.isAlert = isAlert
        self.missionCount = missionCount
        self.totalGracePeriod = totalGracePeriod
        self.ringStartedAt = ringStartedAt
        self.snoozesRemaining = snoozesRemaining
    }
}

// MARK: - Resolution

enum MissionConsolidationResolution {

    /// Sentinel for "no limit". Mirrors the app's existing convention that a
    /// `maxSnoozeCount` of 0 means unlimited, normalised here so `min` works.
    static let unlimitedSnoozes = Int.max

    /// Two grace-period sums closer than this are the same difficulty. Guards
    /// the tie-break against floating-point noise from summing doubles.
    static let gracePeriodEpsilon: Double = 0.0001

    /// What the dismiss junction should do with the alarms still stacked behind
    /// the one just dismissed.
    struct Plan: Equatable {

        /// Queued alarms to dismiss WITHOUT presenting them. They were real wake
        /// events and the user is awake, so they are recorded as **dismissed** —
        /// not skipped, not failed — each publishing plain `dismissed` on its own
        /// `alarmIndex`. Never a new state string: every existing automation keys
        /// on `to: "dismissed"` and inventing one is the `al-d44` silent-no-op
        /// failure.
        let collapsedAlarmIDs: [Int]

        /// The queued alarm that survives because it is strictly harder than the
        /// one just dismissed, and is therefore still presented. `nil` when the
        /// alarm just dismissed was the hardest in the stack — then the whole
        /// wake queue collapses.
        let survivingQueuedAlarmID: Int?

        /// The strictest remaining snooze allowance across the whole stack,
        /// imposed on the survivor so a four-alarm stack cannot grant four
        /// alarms' worth of snoozes. `nil` when nothing was collapsed or when
        /// there is no survivor to impose it on. `Int.max` means every alarm in
        /// the stack allowed unlimited snoozes.
        let snoozeAllowance: Int?

        /// Nothing changes — today's behaviour, byte for byte.
        var isNoOp: Bool { collapsedAlarmIDs.isEmpty }
    }

    /// Today's behaviour: the queue drains one alarm at a time.
    static let noOp = Plan(collapsedAlarmIDs: [], survivingQueuedAlarmID: nil, snoozeAllowance: nil)

    /// Resolve the stack at a dismiss junction.
    ///
    /// - Parameters:
    ///   - dismissed: the alarm the user has just completed.
    ///   - queued: the alarms still stacked behind it, in queue (FIFO) order.
    ///     A queued alarm whose row could not be read must be omitted by the
    ///     caller — an unknown alarm is presented normally, never collapsed.
    /// - Returns: the alarms to collapse, the survivor (if any) and the snooze
    ///   cap. Consolidation NEVER reorders the queue: it only removes entries,
    ///   so a queued `.alert` keeps its FIFO position and the survivor keeps
    ///   its own.
    ///
    /// Consolidation is ALWAYS ON — product decision 2026-08-06, superseding the
    /// 2026-08-05 "it's a setting" decision. The `DeviceSettings.combineStackedAlarms`
    /// toggle was removed before ever shipping, so there is no enable flag to
    /// honour here.
    static func resolve(
        dismissed: StackedAlarm,
        queued: [StackedAlarm]
    ) -> Plan {
        // An alert being dismissed is a notification being acknowledged, not a
        // wake event completed. It has no mission set to compare, and it must
        // never collapse a wake alarm.
        guard !dismissed.isAlert else { return noOp }

        // Alerts in the queue are left strictly alone, in place.
        let candidates = queued.filter { !$0.isAlert }
        guard !candidates.isEmpty else { return noOp }

        // The hardest queued alarm, ties between peers broken by recency.
        let strongest = candidates.dropFirst().reduce(candidates[0]) { best, next in
            isHarder(next, than: best) ? next : best
        }

        // A survivor must be STRICTLY harder than the work the user has just
        // finished — see "why the alarm just completed wins ties".
        let survivor: StackedAlarm? = isStrictlyHarderIgnoringRecency(strongest, than: dismissed)
            ? strongest
            : nil

        let collapsed = candidates.filter { $0.alarmID != survivor?.alarmID }
        guard !collapsed.isEmpty else { return noOp }

        // Strictest allowance across the WHOLE stack, the alarm just dismissed
        // included: the user's own configuration said this morning allowed at
        // most that many snoozes, and collapsing alarms must not buy more sleep
        // than any single one of them would have.
        let allowance: Int? = survivor.map { survivor in
            ([dismissed, survivor] + collapsed).map(\.snoozesRemaining).min() ?? unlimitedSnoozes
        }

        return Plan(
            collapsedAlarmIDs: collapsed.map(\.alarmID),
            survivingQueuedAlarmID: survivor?.alarmID,
            snoozeAllowance: allowance
        )
    }

    // MARK: - Queue-change resolution (al-bee.11)

    /// What a QUEUE-CHANGE resolution should do while an alarm is still on
    /// screen and unengaged.
    struct QueueChangePlan: Equatable {

        /// The strictly-harder queued alarm that justifies rolling the showing
        /// alarm into the stack, or `nil` to leave the showing alarm exactly as
        /// it is. When set, the caller drives the ORDINARY dismiss path on the
        /// showing alarm; the dismiss-junction resolver then collapses the
        /// weaker queued alarms and the dequeue presents this one. Nothing else
        /// belongs here — the collapse set, the snooze cap and the MQTT publish
        /// all fall out of that existing path, so this plan only names the alarm
        /// that justifies taking it.
        let promotedAlarmID: Int?

        /// Nothing changes — the showing alarm keeps its presentation.
        var isNoOp: Bool { promotedAlarmID == nil }
    }

    /// The showing alarm is left exactly as it is.
    static let noOpQueueChange = QueueChangePlan(promotedAlarmID: nil)

    /// Resolve consolidation at a QUEUE CHANGE, not at a dismiss junction
    /// (al-bee.11).
    ///
    /// `resolve(dismissed:queued:isEnabled:)` above only ever runs when the user
    /// FINISHES an alarm, so it compares a queued alarm against work already
    /// done. That makes it one-directional: a queued alarm strictly HARDER than
    /// the one just dismissed survives intact, which is correct at a dismiss —
    /// but it means an ASCENDING stack (a weak alarm on screen, a harder one
    /// queued behind it, the user still asleep) is never resolved until the weak
    /// alarm is dismissed, by which point its set has already been demanded. The
    /// measured incident: a one-mission alarm showing unengaged, a three-mission
    /// alarm queued behind it, and the sleeper doing all four alarms' missions
    /// instead of three.
    ///
    /// This closes the gap from the other side. While the showing alarm is still
    /// UNENGAGED (landing phase, no grace period running, nothing tapped) and a
    /// queued alarm is STRICTLY harder than it, the showing alarm is rolled into
    /// the stack's dismissal — the same collapse the dismiss junction would have
    /// performed had the harder alarm been the one on screen. The caller does
    /// that by driving the ordinary dismiss path, so every downstream effect
    /// (collapsing the weaker queued alarms, the strictest-allowance snooze cap,
    /// the plain `dismissed` MQTT publish, presenting the survivor with its own
    /// audio) is the SAME code the dismiss junction already runs.
    ///
    /// Engagement latches the requirement PERMANENTLY: once `showingEngaged` is
    /// true this returns `noOpQueueChange` no matter what arrives afterwards, so
    /// the demanded set can never change under the user's fingers. It is the
    /// same guarantee the header's "a late-arriving harder alarm never changes
    /// work in flight" makes at the dismiss junction, enforced here at the queue
    /// change. Ties keep the showing alarm — a queued alarm that only equals the
    /// showing one's difficulty demands nothing new.
    ///
    /// - Parameters:
    ///   - showing: the alarm currently on screen. Its `ringStartedAt` is never
    ///     consulted — recency only breaks ties between queued candidates.
    ///   - showingEngaged: the user has interacted with the showing alarm (or a
    ///     grace period is muting it). When true, always a no-op.
    ///   - queued: the alarms stacked behind it, in queue (FIFO) order. A queued
    ///     alarm whose row could not be read must be omitted by the caller.
    ///
    /// Consolidation is ALWAYS ON — product decision 2026-08-06, superseding the
    /// 2026-08-05 "it's a setting" decision. The `DeviceSettings.combineStackedAlarms`
    /// toggle was removed before ever shipping, so there is no enable flag to
    /// honour here.
    static func resolveOnQueueChange(
        showing: StackedAlarm,
        showingEngaged: Bool,
        queued: [StackedAlarm]
    ) -> QueueChangePlan {
        // Once the user has touched the showing alarm, nothing re-resolves — the
        // requirement on screen is fixed for the rest of this presentation.
        guard !showingEngaged else { return noOpQueueChange }

        // An alert on screen is a transient notification being acknowledged, not
        // a wake set to swap out. It never participates.
        guard !showing.isAlert else { return noOpQueueChange }

        // Alerts in the queue are left strictly alone.
        let candidates = queued.filter { !$0.isAlert }
        guard !candidates.isEmpty else { return noOpQueueChange }

        // The hardest queued alarm, ties between peers broken by recency.
        let strongest = candidates.dropFirst().reduce(candidates[0]) { best, next in
            isHarder(next, than: best) ? next : best
        }

        // Only a STRICTLY harder queued alarm justifies rolling the showing
        // alarm into the stack — a tie keeps the showing alarm, whose set
        // already covers the queued work (see "why the alarm just completed wins
        // ties"). The same rule the dismiss junction applies, applied here.
        guard isStrictlyHarderIgnoringRecency(strongest, than: showing) else {
            return noOpQueueChange
        }

        return QueueChangePlan(promotedAlarmID: strongest.alarmID)
    }

    // MARK: Ranking

    /// The full ordering, recency included. Only ever used between two alarms
    /// that are both still owed — i.e. between queued candidates.
    static func isHarder(_ lhs: StackedAlarm, than rhs: StackedAlarm) -> Bool {
        if lhs.missionCount != rhs.missionCount { return lhs.missionCount > rhs.missionCount }
        if abs(lhs.totalGracePeriod - rhs.totalGracePeriod) > gracePeriodEpsilon {
            return lhs.totalGracePeriod > rhs.totalGracePeriod
        }
        return lhs.ringStartedAt > rhs.ringStartedAt
    }

    /// The ordering used against the alarm the user has just completed: equal
    /// difficulty is NOT harder, so the completed set wins and the queued alarm
    /// is collapsed.
    static func isStrictlyHarderIgnoringRecency(_ lhs: StackedAlarm, than rhs: StackedAlarm) -> Bool {
        if lhs.missionCount != rhs.missionCount { return lhs.missionCount > rhs.missionCount }
        return (lhs.totalGracePeriod - rhs.totalGracePeriod) > gracePeriodEpsilon
    }

    // MARK: Helpers for the caller

    /// Normalise an alarm's snooze configuration to a remaining count, with the
    /// app's "0 means unlimited" convention folded into `Int.max`.
    static func snoozesRemaining(maxSnoozeCount: Int, snoozeCount: Int) -> Int {
        guard maxSnoozeCount > 0 else { return unlimitedSnoozes }
        return max(0, maxSnoozeCount - snoozeCount)
    }
}
