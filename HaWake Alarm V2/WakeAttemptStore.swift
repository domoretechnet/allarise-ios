//
//  WakeAttemptStore.swift
//  HaWake Alarm V2
//
//  Local-only measurement of the Dynamic-persistence wake ladder: every
//  BGAppRefreshTask submission, every wake, and every alarm fire is appended
//  to a JSON file in Application Support. Nothing here ever leaves the device
//  and no record contains anything identifying — the point is to answer, from
//  the developer's own devices, "how often does the ladder land inside the
//  window, and which delivery path actually rang the alarm".
//
//  Deliberately NOT Analytics: these records need timestamps and percentiles,
//  which the bucketed, consent-gated event vocabulary cannot express — and
//  they must exist regardless of the analytics opt-in because they never
//  leave the device. Viewed via Settings ▸ Diagnostics.
//
//  Appends are synchronous by design: the BG-task handler has a ~30s budget
//  and a hard setTaskCompleted obligation, so a record is written to disk
//  before anything slower runs. No network, ever.
//

import Foundation
import UIKit

struct WakeAttemptRecord: Codable, Identifiable {
    var id: Date { timestamp }

    let timestamp: Date
    /// "ladderSubmit" | "ladderWake" | "alarmFired"
    let kind: String
    /// ladderWake: activated | resubmitted | idle. alarmFired: the delivery
    /// path that claimed the ring (primaryTimer, alarmKitFailsafe, …).
    let outcome: String?
    /// ladderSubmit: the earliestBeginDate that was requested.
    let requestedBegin: Date?
    /// The next alarm fire the record was aimed at, when known.
    let nextFireDate: Date?

    // Conditions at the moment of the record — the schedule-time vs
    // launch-time split from the plan falls out of comparing a ladderSubmit
    // record with the ladderWake records that follow it.
    let mode: String
    let charging: Bool
    let lowPowerMode: Bool
    let batteryLevel: Float
    let thermalState: Int

    let deviceModel: String
    let osVersion: String
}

final class WakeAttemptStore {
    static let shared = WakeAttemptStore()

    /// Rolling cap — ~a season of nightly records, pruned oldest-first.
    private let maxRecords = 2000
    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("wake-ladder-log.json")
    }

    // MARK: Recording

    func recordLadderSubmit(requestedBegin: Date, nextFireDate: Date?) {
        append(makeRecord(kind: "ladderSubmit", outcome: nil, requestedBegin: requestedBegin, nextFireDate: nextFireDate))
    }

    func recordLadderWake(outcome: String, nextFireDate: Date?) {
        append(makeRecord(kind: "ladderWake", outcome: outcome, requestedBegin: nil, nextFireDate: nextFireDate))
        AppLogger.shared.log("WakeLadder: wake outcome=\(outcome)", category: .general)
    }

    /// One record per ring, from the AlarmRingReporter claim funnel — records
    /// WHICH tier delivered the alarm alongside the ladder history, so a
    /// night's story (submitted → woke → who rang) is reconstructable.
    func recordAlarmFired(path: String) {
        append(makeRecord(kind: "alarmFired", outcome: path, requestedBegin: nil, nextFireDate: nil))
    }

    // MARK: Reading (Diagnostics UI)

    func allRecords() -> [WakeAttemptRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decoder.decode([WakeAttemptRecord].self, from: data)) ?? []
    }

    // MARK: Internals

    private func makeRecord(kind: String, outcome: String?, requestedBegin: Date?, nextFireDate: Date?) -> WakeAttemptRecord {
        let device = UIDevice.current
        let charging = device.batteryState == .charging || device.batteryState == .full
        return WakeAttemptRecord(
            timestamp: Date(),
            kind: kind,
            outcome: outcome,
            requestedBegin: requestedBegin,
            nextFireDate: nextFireDate,
            mode: DeviceSettings.shared.appPersistenceMode.rawValue,
            charging: charging,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryLevel: device.batteryLevel,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            deviceModel: Self.modelIdentifier,
            osVersion: device.systemVersion
        )
    }

    private func append(_ record: WakeAttemptRecord) {
        var records = allRecords()
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        if let data = try? Self.encoder.encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let modelIdentifier: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()
}
