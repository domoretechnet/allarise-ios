//
//  AppExitMonitor.swift
//  HaWake Alarm V2
//
//  The two kills that cost people their alarm are the two kills nothing else
//  in this app can see.
//
//  Because the app deliberately stays resident overnight (BackgroundAudioKeepAlive)
//  so the in-app Timer can fire, it spends the whole night inside two budgets it
//  would otherwise never touch: the jetsam memory limit and the background CPU
//  limit. Exceeding either gets the process terminated — the previous release
//  shipped a fix for exactly the background-CPU case. Neither termination is a
//  crash: there is no signal, no stack trace, and no report. A crash reporter
//  sees a perfectly clean session, and the user just sees an alarm that never
//  rang.
//
//  MetricKit is the only thing that counts them. iOS tallies exit reasons for
//  the process itself and hands over the totals in a payload, so this file adds
//  no measurement of its own: it registers a subscriber and waits. There is no
//  timer, no sampling, and no work at all on the nights when nothing goes wrong
//  — which matters, because polling for the CPU limit would spend the budget it
//  was trying to protect.
//
//  TIMING: payloads arrive roughly once every 24 hours, delivered on the next
//  launch after iOS finalises the day's report. So this is a trend instrument,
//  not an alert — "how often did we get killed this month, and for what" — and
//  an exit reported today may belong to a session days ago.
//
//  COUNTS ARE CUMULATIVE over the payload's own window, not deltas we track, so
//  nothing needs to be persisted across launches. Zeroes are dropped rather than
//  logged: a healthy day would otherwise emit six events saying nothing happened.
//

import Foundation
import MetricKit

/// Subscribes to MetricKit and reports OS-initiated process exits.
/// Registration only — see `start()`. Nothing here observes or polls.
@available(iOS 14.0, *)
final class AppExitMonitor: NSObject, MXMetricManagerSubscriber {

    static let shared = AppExitMonitor()

    /// MetricKit tolerates duplicate subscribers, but a double registration
    /// would deliver every payload twice and silently double every exit count.
    private static var isRegistered = false

    private override init() { super.init() }

    /// Registers for metric and diagnostic payloads. Safe to call repeatedly;
    /// only the first call subscribes.
    static func start() {
        guard !isRegistered else { return }
        isRegistered = true
        MXMetricManager.shared.add(shared)
    }

    // MARK: - MXMetricManagerSubscriber

    // Delivered on a system-owned queue, not the main thread. Everything below
    // reads plain integers out of the payload there and hops to the main actor
    // with those values only — `Analytics` is main-actor isolated and the
    // payload objects are not safe to carry across.

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        var exits: [ExitTally] = []
        for payload in payloads {
            guard let metric = payload.applicationExitMetrics else { continue }
            exits += Self.tallies(from: metric.foregroundExitData)
            exits += Self.tallies(from: metric.backgroundExitData)
        }
        guard !exits.isEmpty else { return }
        let reported = exits

        Task { @MainActor in
            for exit in reported {
                Analytics.shared.log(.appExitReported(reason: exit.reason,
                                                      count: exit.count,
                                                      wasBackground: exit.wasBackground))
            }
            AppLogger.shared.log(
                "MetricKit exit report: "
                + reported.map { "\($0.reason.rawValue)\($0.wasBackground ? "(bg)" : "(fg)")=\($0.count)" }
                    .joined(separator: ", "),
                category: .general
            )
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // No analytics event covers diagnostics, and deliberately so: a call
        // stack tree is the one thing in MetricKit that can carry identifying
        // detail. Only the counts are recorded, into the app's own log, because
        // a cpuException diagnostic is the direct evidence for a background-CPU
        // kill that `appExitReported` can only count after the fact.
        let crashes = payloads.reduce(0) { $0 + ($1.crashDiagnostics?.count ?? 0) }
        let hangs = payloads.reduce(0) { $0 + ($1.hangDiagnostics?.count ?? 0) }
        let cpuExceptions = payloads.reduce(0) { $0 + ($1.cpuExceptionDiagnostics?.count ?? 0) }
        let diskWrites = payloads.reduce(0) { $0 + ($1.diskWriteExceptionDiagnostics?.count ?? 0) }
        guard crashes + hangs + cpuExceptions + diskWrites > 0 else { return }

        Task { @MainActor in
            AppLogger.shared.log(
                "MetricKit diagnostics: crash=\(crashes), hang=\(hangs), "
                + "cpuException=\(cpuExceptions), diskWrite=\(diskWrites). "
                + "cpuException means iOS flagged us for CPU use — the budget that kills a resident app.",
                category: .general
            )
        }
    }

    // MARK: - Mapping

    private struct ExitTally {
        let reason: AppExitReason
        let count: Int
        let wasBackground: Bool
    }

    /// Foreground exits. The user was looking at the app, so these are ordinary
    /// reliability bugs rather than alarm-loss events — but a memory-limit exit
    /// here still says the app's footprint is too close to the ceiling at night.
    nonisolated private static func tallies(from data: MXForegroundExitData) -> [ExitTally] {
        nonZero([
            (.memoryLimit, data.cumulativeMemoryResourceLimitExitCount),
            (.badAccess,   data.cumulativeBadAccessExitCount),
            (.abnormal,    data.cumulativeAbnormalExitCount),
            (.watchdog,    data.cumulativeAppWatchdogExitCount),
            (.normal,      data.cumulativeNormalAppExitCount)
        ], wasBackground: false)
    }

    /// Background exits. This is the set that matters: every one of these
    /// happened while the app was holding itself alive waiting to ring.
    nonisolated private static func tallies(from data: MXBackgroundExitData) -> [ExitTally] {
        nonZero([
            (.memoryLimit,        data.cumulativeMemoryResourceLimitExitCount),
            // DEVICE-wide pressure, not our own ceiling: the phone ran out and
            // we were the cheapest thing to evict. Reported separately because
            // the remedy differs — "use less memory" fixes the line above, but
            // only "be resident less, or be cheaper to keep" fixes this one.
            (.systemMemoryPressure, data.cumulativeMemoryPressureExitCount),
            // Apple's name for the background CPU budget kill. Background-only
            // by construction — there is no foreground equivalent property,
            // because iOS only enforces the budget off screen.
            (.backgroundCPULimit, data.cumulativeCPUResourceLimitExitCount),
            (.badAccess,          data.cumulativeBadAccessExitCount),
            (.abnormal,           data.cumulativeAbnormalExitCount),
            (.watchdog,           data.cumulativeAppWatchdogExitCount),
            // Includes the user swiping the app out of the switcher, which is
            // the single most common way this app dies. Worth counting as the
            // baseline everything else is compared against.
            (.normal,             data.cumulativeNormalAppExitCount)
        ], wasBackground: true)
    }

    nonisolated private static func nonZero(_ pairs: [(AppExitReason, Int)],
                                            wasBackground: Bool) -> [ExitTally] {
        pairs.compactMap { reason, count in
            count > 0 ? ExitTally(reason: reason, count: count, wasBackground: wasBackground) : nil
        }
    }
}
