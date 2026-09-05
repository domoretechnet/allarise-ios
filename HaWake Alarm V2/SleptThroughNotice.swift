//
//  SleptThroughNotice.swift
//  HaWake Alarm V2
//
//  The reconciliation pass for slept-through alarms and its one surface: the
//  Home Assistant sensor (al-bee.5). This class now exists for detection and
//  MQTT publishing only.
//
//  The in-app "You slept through …" home banner was removed 2026-08-10 (user
//  decision); the detection + publish flow below is deliberately untouched.
//  Historical why for the banner design is preserved in
//  Documents/working-notes/PLAN-sleep-through-stack.md.
//
//  THE SAFE SEAM
//  -------------
//  `reconcile()` runs from `handleScenePhaseChange`, strictly AFTER
//  `checkAndShowPendingAlarm()` and inside the existing not-ringing guard
//  (`!isShowingAlarm && !hasPendingAlarm && !isPlaying && !alarmKitAlerting`).
//  That is the seam PLAN-sleep-through-stack defines: a ring is already
//  established or already over by the time anything here executes.
//
//  It **reads only and arms nothing** — no `schedule`, no `cancel`, no `stop`,
//  no notification, no timer, no change to what AlarmKit holds. If it throws
//  or misbehaves, an alarm still rings, because nothing in the alarm lifecycle
//  consults it. The one AlarmKit call it makes
//  (`AlarmKitScheduler.alertingAlarmHashes`) swallows its own errors and
//  returns an empty set.
//
//  Ordering note: it must run BEFORE `cleanupStaleAlarms`, which can stop
//  resident AlarmKit alarms. Read the inventory first or the cold-start
//  evidence is gone.
//
//  WHAT IT DELIBERATELY DOES NOT DO
//  --------------------------------
//  An alarm that expired unacknowledged does NOT resurrect its after-alarm
//  sequence — no cards, and above all no app link. Firing a Shortcut at 13:00
//  for an 06:00 alarm is an unbounded external side effect nobody asked for.
//  This surfaces the FACT; the stale content stays where it is.
//  (PLAN-sleep-through-stack, "the remaining calls" #1.)
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class SleptThroughNotice {

    static let shared = SleptThroughNotice()

    /// Today's slept-through alarms, recomputed from the ledger by `reconcile()`
    /// and `refresh()`; `.empty` until the first pass runs. Read by `publish()`
    /// to build the Home Assistant sensor payload.
    private(set) var report: SleptThroughReport = .empty

    private let ledger: UnresolvedRingLedger

    init(ledger: UnresolvedRingLedger = .shared) {
        self.ledger = ledger
    }

    // MARK: - Reconciliation

    /// Merge the AlarmKit inventory into the ledger, refresh the report and
    /// publish it.
    ///
    /// - Parameter knownAlarms: every alarm the app still knows about, so a
    ///   resident `.alerting` id can be mapped back to an alarm and named.
    func reconcile(knownAlarms: [(hash: Int, label: String, alarmIndex: Int)]) {
        // 1. Cold-start evidence: alarms AlarmKit is still presenting because
        //    nobody ever dealt with them. Four tier UUIDs collapse to one
        //    alarm inside `alertingAlarmHashes`.
        let alerting = AlarmKitScheduler.shared.alertingAlarmHashes(knownHashes: knownAlarms.map(\.hash))
        if !alerting.isEmpty {
            let byHash = Dictionary(knownAlarms.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
            for hash in alerting {
                let known = byHash[hash]
                ledger.noteDiscoveredAlerting(
                    alarmHash: hash,
                    label: known?.label ?? "Alarm",
                    alarmIndex: known?.alarmIndex ?? 0
                )
            }
            AppLogger.shared.log(
                "Slept-through reconcile: \(alerting.count) AlarmKit alarm(s) still alerting unattended",
                category: .alarm
            )
        }

        // 2. The ledger is now the union of what we saw ring and what AlarmKit
        //    is still holding. Recompute and publish.
        refresh()
        publish()
    }

    /// Recompute today's report from the ledger. Cheap; called by `reconcile()`
    /// before `publish()`.
    func refresh() {
        report = ledger.report()
    }

    /// Publish the count (and the small detail list) to Home Assistant.
    /// Additive: no existing topic, payload key or state value is touched.
    func publish(settings: DeviceSettings = .shared) {
        HAIntegrationRouter.shared.publishSleptThroughToday(report, settings: settings)
    }
}
