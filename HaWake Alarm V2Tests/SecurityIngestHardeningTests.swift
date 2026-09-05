//
//  SecurityIngestHardeningTests.swift
//  HaWake Alarm V2Tests
//
//  Covers the two Batch-A hardening fixes from the 2026-08-03 security audit
//  (`Documents/reviews/2026-08-03/06-COMBINED-SECURITY-AND-DEAD-CODE-AUDIT.md`):
//
//  * SEC-01 — `DeviceSettings.extractZip` accepted `..` entries, reported success
//    on every failure, and allocated a buffer from an attacker-controlled size.
//  * NEW-IOS-01/04/05 — `snooze_duration`, `max_snooze_count` and `days` were
//    taken off MQTT unclamped / all-or-nothing.
//
//  Both sets are pure enough to test without a broker, a ModelContainer, or a
//  real preset file: the zip fixtures are built in memory here, and the ingest
//  helpers are static and side-effect free apart from logging.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

// MARK: - Zip fixtures

/// Build a single-entry "stored" (compression method 0) zip, with the declared
/// uncompressed size overridable so the oversize guard can be exercised.
private func makeStoredZip(fileName: String,
                           contents: Data,
                           declaredUncompressedSize: UInt32? = nil) -> Data {
    var out = Data()
    let nameBytes = Array(fileName.utf8)
    let uncompressed = declaredUncompressedSize ?? UInt32(contents.count)

    func append16(_ value: UInt16) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
    }
    func append32(_ value: UInt32) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    }

    out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])   // local file header signature
    append16(20)                                        // version needed
    append16(0)                                         // flags
    append16(0)                                         // compression method: stored
    append16(0)                                         // mod time
    append16(0)                                         // mod date
    append32(0)                                         // crc32 (unchecked by the extractor)
    append32(UInt32(contents.count))                    // compressed size
    append32(uncompressed)                              // uncompressed size
    append16(UInt16(nameBytes.count))                   // file name length
    append16(0)                                         // extra length
    out.append(contentsOf: nameBytes)
    out.append(contents)
    return out
}

/// A fresh empty directory under the temp dir, removed by the caller.
private func makeExtractionRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZipHardeningTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - SEC-01: zip extractor

struct ZipExtractionHardeningTests {

    @Test("A well-formed stored archive still extracts and reports success")
    func validArchiveExtracts() throws {
        let root = makeExtractionRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = Data("{\"name\":\"Test\"}".utf8)
        let ok = DeviceSettings.extractZip(data: makeStoredZip(fileName: "preset.json", contents: body), to: root)

        #expect(ok)
        let written = root.appendingPathComponent("preset.json")
        #expect(FileManager.default.fileExists(atPath: written.path))
        #expect(try Data(contentsOf: written) == body)
    }

    @Test("A nested entry extracts into a created subdirectory")
    func nestedEntryExtracts() {
        let root = makeExtractionRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let ok = DeviceSettings.extractZip(
            data: makeStoredZip(fileName: "package/preset.json", contents: Data("{}".utf8)),
            to: root
        )

        #expect(ok)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("package/preset.json").path))
    }

    @Test("A `..` entry fails the extraction and writes nothing outside the root")
    func traversalEntryIsRejected() {
        let root = makeExtractionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let escapeTarget = root.deletingLastPathComponent().appendingPathComponent("escape.txt")
        try? FileManager.default.removeItem(at: escapeTarget)

        let ok = DeviceSettings.extractZip(
            data: makeStoredZip(fileName: "../escape.txt", contents: Data("pwned".utf8)),
            to: root
        )

        #expect(ok == false)
        #expect(FileManager.default.fileExists(atPath: escapeTarget.path) == false)
        try? FileManager.default.removeItem(at: escapeTarget)
    }

    @Test("A deeply nested `..` entry is rejected too")
    func nestedTraversalEntryIsRejected() {
        let root = makeExtractionRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let ok = DeviceSettings.extractZip(
            data: makeStoredZip(fileName: "a/b/../../../escape.txt", contents: Data("pwned".utf8)),
            to: root
        )

        #expect(ok == false)
    }

    @Test("An absolute-path entry is rejected")
    func absolutePathEntryIsRejected() {
        let root = makeExtractionRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let ok = DeviceSettings.extractZip(
            data: makeStoredZip(fileName: "/tmp/escape.txt", contents: Data("pwned".utf8)),
            to: root
        )

        #expect(ok == false)
    }

    @Test("A truncated archive returns false rather than reporting a partial import as success")
    func truncatedArchiveFails() {
        let root = makeExtractionRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let full = makeStoredZip(fileName: "preset.json", contents: Data(repeating: 0x41, count: 64))
        let truncated = full.prefix(full.count - 20)

        #expect(DeviceSettings.extractZip(data: Data(truncated), to: root) == false)
    }

    @Test("An oversized declared uncompressed size is refused before any allocation")
    func oversizedDeclaredSizeFails() {
        let root = makeExtractionRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // ~4 GiB declared from a 4-byte entry — the pre-fix allocation path.
        let zip = makeStoredZip(fileName: "preset.json",
                                contents: Data("tiny".utf8),
                                declaredUncompressedSize: UInt32.max)

        #expect(DeviceSettings.extractZip(data: zip, to: root) == false)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("preset.json").path) == false)
    }

    @Test("Garbage that is not a zip fails instead of returning success")
    func garbageDataFails() {
        let root = makeExtractionRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(DeviceSettings.extractZip(data: Data(repeating: 0x5A, count: 512), to: root) == false)
    }

    @Test("An archive with no entries fails")
    func emptyArchiveFails() {
        let root = makeExtractionRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // End-of-central-directory record only — a valid but empty zip.
        var eocd = Data([0x50, 0x4B, 0x05, 0x06])
        eocd.append(Data(repeating: 0, count: 26))

        #expect(DeviceSettings.extractZip(data: eocd, to: root) == false)
        #expect(DeviceSettings.extractZip(data: Data(), to: root) == false)
    }

    @Test("An unsupported compression method fails rather than silently skipping the entry")
    func unsupportedCompressionMethodFails() {
        let root = makeExtractionRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var zip = makeStoredZip(fileName: "preset.json", contents: Data("body".utf8))
        zip[8] = 12   // bzip2 — not handled
        zip[9] = 0

        #expect(DeviceSettings.extractZip(data: zip, to: root) == false)
    }
}

// MARK: - NEW-IOS-01/04/05: MQTT integer + days ingest

@MainActor
struct MQTTIngestClampTests {

    // MARK: snooze_duration

    @Test("A huge snooze_duration clamps to the editor maximum instead of overflowing later")
    func hugeSnoozeDurationClamps() {
        let payload: [String: Any] = ["snooze_duration": NSNumber(value: Int64(200_000_000_000_000_000))]
        #expect(MQTTCommandHandler.clampedInt(payload, key: "snooze_duration",
                                              range: MQTTCommandHandler.snoozeDurationRange) == 30)
    }

    @Test("A negative snooze_duration clamps to the minimum, never scheduling in the past")
    func negativeSnoozeDurationClamps() {
        let payload: [String: Any] = ["snooze_duration": -100]
        #expect(MQTTCommandHandler.clampedInt(payload, key: "snooze_duration",
                                              range: MQTTCommandHandler.snoozeDurationRange) == 1)
    }

    @Test("An in-range snooze_duration passes through untouched")
    func inRangeSnoozeDurationUnchanged() {
        let payload: [String: Any] = ["snooze_duration": 9]
        #expect(MQTTCommandHandler.clampedInt(payload, key: "snooze_duration",
                                              range: MQTTCommandHandler.snoozeDurationRange) == 9)
    }

    @Test("An absent field returns nil so the caller's default is preserved")
    func absentFieldReturnsNil() {
        #expect(MQTTCommandHandler.clampedInt([:], key: "snooze_duration",
                                              range: MQTTCommandHandler.snoozeDurationRange) == nil)
        // A non-numeric value is also treated as absent, as before the change.
        #expect(MQTTCommandHandler.clampedInt(["snooze_duration": "soon"], key: "snooze_duration",
                                              range: MQTTCommandHandler.snoozeDurationRange) == nil)
    }

    // MARK: max_snooze_count

    @Test("A negative max_snooze_count clamps to 0 rather than silently disabling snooze")
    func negativeMaxSnoozeCountClamps() {
        let payload: [String: Any] = ["max_snooze_count": -3]
        #expect(MQTTCommandHandler.clampedInt(payload, key: "max_snooze_count",
                                              range: MQTTCommandHandler.maxSnoozeCountRange) == 0)
    }

    @Test("max_snooze_count 0 stays 0 — it means unlimited downstream")
    func zeroMaxSnoozeCountPreserved() {
        let payload: [String: Any] = ["max_snooze_count": 0]
        #expect(MQTTCommandHandler.clampedInt(payload, key: "max_snooze_count",
                                              range: MQTTCommandHandler.maxSnoozeCountRange) == 0)
    }

    @Test("An over-large max_snooze_count clamps to the editor maximum")
    func hugeMaxSnoozeCountClamps() {
        let payload: [String: Any] = ["max_snooze_count": NSNumber(value: Int64.max)]
        #expect(MQTTCommandHandler.clampedInt(payload, key: "max_snooze_count",
                                              range: MQTTCommandHandler.maxSnoozeCountRange) == 20)
    }

    // MARK: days

    @Test("A mixed-type days array is parsed per element instead of collapsing to empty")
    func mixedTypeDaysParsed() {
        let payload: [String: Any] = ["days": [1, 2, "3"]]
        #expect(MQTTCommandHandler.parsedDays(from: payload) == Set([1, 2, 3]))
    }

    @Test("A plain [Int] days array behaves exactly as before")
    func intDaysUnchanged() {
        let payload: [String: Any] = ["days": [2, 3, 4, 5, 6]]
        #expect(MQTTCommandHandler.parsedDays(from: payload) == Set([2, 3, 4, 5, 6]))
    }

    @Test("Out-of-range and non-numeric elements are dropped, the rest survive")
    func outOfRangeDaysFiltered() {
        let payload: [String: Any] = ["days": [0, 1, 7, 8, "sunday", NSNull()]]
        #expect(MQTTCommandHandler.parsedDays(from: payload) == Set([1, 7]))
    }

    @Test("An absent days key returns nil so the caller leaves recurrence alone")
    func absentDaysReturnsNil() {
        #expect(MQTTCommandHandler.parsedDays(from: [:]) == nil)
        #expect(MQTTCommandHandler.parsedDays(from: ["days": "1,2,3"]) == nil)
    }

    @Test("An empty days array yields an empty set — an explicit one-shot")
    func emptyDaysIsEmptySet() {
        #expect(MQTTCommandHandler.parsedDays(from: ["days": [Int]()]) == Set<Int>())
    }
}

// MARK: - Batch B: hold durations (sibling of NEW-IOS-01)

/// `snooze_hold_duration` / `skip_hold_duration` were lower-bounded at 0.5 and
/// had no ceiling, so a payload could demand an unreachable hold. The editor
/// sliders are `0.5...30`; ingest now agrees with them.
@MainActor
struct MQTTHoldDurationClampTests {

    @Test("An over-range hold duration clamps to the slider maximum")
    func overRangeClamps() {
        #expect(MQTTCommandHandler.clampedDouble(["snooze_hold_duration": 3600],
                                                 key: "snooze_hold_duration",
                                                 range: MQTTCommandHandler.holdDurationRange) == 30)
        #expect(MQTTCommandHandler.clampedDouble(["skip_hold_duration": 30.1],
                                                 key: "skip_hold_duration",
                                                 range: MQTTCommandHandler.holdDurationRange) == 30)
    }

    @Test("An under-range or negative hold duration clamps to the slider minimum")
    func underRangeClamps() {
        #expect(MQTTCommandHandler.clampedDouble(["snooze_hold_duration": 0],
                                                 key: "snooze_hold_duration",
                                                 range: MQTTCommandHandler.holdDurationRange) == 0.5)
        #expect(MQTTCommandHandler.clampedDouble(["skip_hold_duration": -12.5],
                                                 key: "skip_hold_duration",
                                                 range: MQTTCommandHandler.holdDurationRange) == 0.5)
    }

    @Test("An in-range hold duration is passed through untouched")
    func inRangePreserved() {
        #expect(MQTTCommandHandler.clampedDouble(["snooze_hold_duration": 2.5],
                                                 key: "snooze_hold_duration",
                                                 range: MQTTCommandHandler.holdDurationRange) == 2.5)
    }

    @Test("An absent, non-numeric or non-finite value returns nil so the default stands")
    func absentReturnsNil() {
        #expect(MQTTCommandHandler.clampedDouble([:], key: "snooze_hold_duration",
                                                 range: MQTTCommandHandler.holdDurationRange) == nil)
        #expect(MQTTCommandHandler.clampedDouble(["skip_hold_duration": "long"],
                                                 key: "skip_hold_duration",
                                                 range: MQTTCommandHandler.holdDurationRange) == nil)
        #expect(MQTTCommandHandler.clampedDouble(["skip_hold_duration": Double.nan],
                                                 key: "skip_hold_duration",
                                                 range: MQTTCommandHandler.holdDurationRange) == nil)
    }
}

// MARK: - SEC-04: command freshness applies to every inbound path

/// `ts` stays OPTIONAL — a command without one must execute exactly as it always
/// has. What changed is that when a payload DOES carry one, the per-alarm and
/// bare-switch paths now apply the same window the JSON dispatcher always did.
struct MQTTCommandFreshnessTests {

    private var now: Double { Date().timeIntervalSince1970 }

    @Test("A fresh ts is accepted")
    func freshTimestampAccepted() {
        #expect(MQTTManager.staleAge(inPayload: ["ts": now - 5]) == nil)
        #expect(MQTTManager.staleAge(inPayload: ["ts": now]) == nil)
    }

    @Test("A stale ts is rejected, and the reported age is the real one")
    func staleTimestampRejected() throws {
        let age = try #require(MQTTManager.staleAge(inPayload: ["ts": now - 600]))
        #expect(age > 590 && age < 610)
    }

    @Test("A ts far in the FUTURE is rejected too — the window is symmetric")
    func futureTimestampRejected() {
        #expect(MQTTManager.staleAge(inPayload: ["ts": now + 600]) != nil)
    }

    @Test("An absent ts is accepted — backwards compatibility with every existing automation")
    func absentTimestampAccepted() {
        #expect(MQTTManager.staleAge(inPayload: [:]) == nil)
        #expect(MQTTManager.staleAge(inPayload: ["enabled": true]) == nil)
        #expect(MQTTManager.staleAge(inPayload: nil) == nil)
        // A non-numeric ts is not a timestamp; treated as absent rather than stale.
        #expect(MQTTManager.staleAge(inPayload: ["ts": "yesterday"]) == nil)
    }

    @Test("A bare non-JSON switch payload has no ts and executes as before")
    func bareStringPayloadAccepted() {
        #expect(MQTTManager.staleAge(inPayloadString: "ON") == nil)
        #expect(MQTTManager.staleAge(inPayloadString: "OFF") == nil)
        #expect(MQTTManager.staleAge(inPayloadString: "") == nil)
        #expect(MQTTManager.staleAge(inPayloadString: "12.5") == nil)
    }

    @Test("A JSON string payload carrying a stale ts is rejected on the string path too")
    func jsonStringPayloadHonoursTimestamp() {
        #expect(MQTTManager.staleAge(inPayloadString: "{\"enabled\": true, \"ts\": \(now - 3600)}") != nil)
        #expect(MQTTManager.staleAge(inPayloadString: "{\"enabled\": true, \"ts\": \(now)}") == nil)
    }

    @Test("The window is the documented 60 seconds")
    func windowIsSixtySeconds() {
        #expect(MQTTManager.commandFreshnessWindow == 60)
        #expect(MQTTManager.staleAge(inPayload: ["ts": now - 59]) == nil)
        #expect(MQTTManager.staleAge(inPayload: ["ts": now - 61]) != nil)
    }
}
