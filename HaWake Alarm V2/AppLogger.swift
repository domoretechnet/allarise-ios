//
//  AppLogger.swift
//  HaWake Alarm V2
//
//  Unified in-app debug logger with plain-text export.
//  Credentials, tokens and signed-URL parameters are redacted at WRITE time, so
//  they never reach the in-memory buffer or the log file. The wider personal-data
//  pass (alarm names, commands, alert content, SSIDs, hostnames, IPs) is applied
//  on export only — those stay readable in the in-app log viewer, which is what
//  the user needs when diagnosing their own connection.
//

import Foundation
import UIKit

enum AppLogCategory: String, CaseIterable {
    case alarm       = "ALARM"
    case mqtt        = "MQTT"
    case notification = "NOTIF"
    case network     = "NET"
    case audio       = "AUDIO"
    case general     = "APP"
    /// Alarm scheduling internals (DualAlarmCoordinator). Shown as a separate
    /// section in exported logs so scheduling details stay organised.
    case coordinator = "COORD"
}

struct AppLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let category: AppLogCategory
    let message: String

    var formatted: String {
        formattedWith(message: message)
    }

    func formattedWith(message: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return "[\(fmt.string(from: timestamp))] [\(category.rawValue)] \(message)"
    }
}

@MainActor
final class AppLogger {
    static let shared = AppLogger()

    private(set) var entries: [AppLogEntry] = []

    /// Maximum age for log entries (7 days)
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Maximum estimated size for all log entries (~9.98 MB)
    private let maxSizeBytes: Int = 9_980_000
    /// Average bytes per character for size estimation
    private let avgBytesPerEntry = 120
    /// Running estimate of the total size of `entries`, maintained incrementally
    /// so trimming never has to walk the whole array.
    private var estimatedSizeBytes = 0

    // MARK: - Disk Persistence

    /// On-disk log file inside Application Support
    nonisolated private static let logFileName = "allarise_app.log"

    nonisolated private static var logFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(logFileName)
    }

    /// Serial background writer that owns the file handle
    private let diskWriter: LogDiskWriter

    /// Log lines waiting to be flushed to disk
    private var pendingLines: [String] = []
    private var pendingBytes = 0
    private var flushScheduled = false
    /// Flush the buffer once it grows past this size…
    private let flushThresholdBytes = 16_384
    /// …or after this many seconds, whichever comes first
    private let flushInterval: TimeInterval = 3

    /// ISO-8601 formatter with milliseconds for disk log lines
    private static let diskFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    /// Human-readable full date+time formatter for exported log lines
    private static let exportFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    private init() {
        // Capture session start before any log() calls so the background loader
        // can exclude entries already added during this session (avoiding duplicates).
        let sessionStart = Date()
        // Set up the background writer immediately so new log entries can be
        // appended even before the historical load completes.
        diskWriter = LogDiskWriter(fileURL: Self.logFileURL)

        // Flush buffered lines when the app leaves the foreground so nothing
        // sits in memory while suspended; the terminate flush is synchronous
        // because the process may die before an async write runs.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingLines() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingLines(sync: true) }
        }

        // Load + compact the log file on a background thread. The file grows
        // unboundedly between clear() calls (trim only prunes in-memory entries),
        // so after 7 days of verbose logging it can be megabytes — enough to
        // freeze the main thread for 7+ seconds if read synchronously at launch.
        //
        // BOUNDED, OR THE WATCHDOG KILLS THE APP. This loader once read the
        // WHOLE file and ran `DateFormatter.date(from:)` on every line. At
        // 38 MB / ~350K lines that is minutes of ICU work at background QoS on
        // an e-core — and the instant the app backgrounded, the non-frontmost
        // CPU watchdog (80% over 60s) KILLED the process (cpu_resource_fatal),
        // so every alarm failed over to the full-volume AlarmKit failsafe. It
        // was also a death spiral: the compaction that would shrink the file
        // only ran if the parse FINISHED, so the file only ever grew. Hence:
        //   • read at most the trailing `maxLoadBytes` (seek, never whole-file);
        //   • age-filter by STRING compare — the timestamp format is
        //     lexicographically ordered, no ICU needed to discard a line;
        //   • DateFormatter only runs on the bounded set of KEPT lines;
        //   • compaction reuses the RAW kept lines (no re-formatting), and a
        //     truncated read forces compaction so an oversized file is cut
        //     back down on the very next launch.
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let url = Self.logFileURL

            // Tail read: at most maxLoadBytes, aligned to the next full line.
            let maxLoadBytes = 4 * 1024 * 1024
            var wasTruncated = false
            guard var data: Data = {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? handle.close() }
                guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
                if size > UInt64(maxLoadBytes) {
                    wasTruncated = true
                    try? handle.seek(toOffset: size - UInt64(maxLoadBytes))
                }
                return try? handle.readToEnd()
            }() else { return }
            if wasTruncated, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                data = data.subdata(in: data.index(after: newline)..<data.endIndex)
            }
            guard let text = String(data: data, encoding: .utf8) else { return }

            let ageCutoff = sessionStart.addingTimeInterval(-7 * 24 * 60 * 60)
            // DateFormatter is not thread-safe — create a local instance for this thread.
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            // The timestamp format sorts lexicographically — string compares
            // replace per-line date parsing for the cheap filters below.
            let cutoffString = fmt.string(from: ageCutoff)
            let sessionStartString = fmt.string(from: sessionStart)

            var loaded: [AppLogEntry] = []
            /// Raw kept lines, verbatim — reused for compaction so the rewrite
            /// never re-formats a single timestamp.
            var keptLines: [Substring] = []
            var hadStaleEntries = wasTruncated
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3 else { continue }
                let tsString = String(parts[0])
                if tsString < cutoffString { hadStaleEntries = true; continue }
                // Skip entries from this session — they're already in entries[] via log()
                if tsString >= sessionStartString { continue }
                guard let ts = fmt.date(from: tsString),
                      let cat = AppLogCategory(rawValue: String(parts[1])) else { continue }
                loaded.append(AppLogEntry(timestamp: ts, category: cat, message: String(parts[2])))
                keptLines.append(line)
            }

            // Build the compacted history here so the main thread never has to
            // assemble a multi-megabyte string.
            var compacted = ""
            if hadStaleEntries, !keptLines.isEmpty {
                compacted = keptLines.joined(separator: "\n") + "\n"
            }

            let finalLoaded = loaded
            let finalHadStale = hadStaleEntries
            let finalCompacted = compacted
            await MainActor.run { [weak self] in
                guard let self else { return }
                if finalHadStale {
                    // Rewrite the file as compacted history + this session's
                    // entries. Pending buffered lines are covered by the session
                    // entries, so drop them instead of flushing.
                    var sessionText = ""
                    for entry in self.entries {
                        sessionText += Self.diskLine(for: entry)
                    }
                    self.pendingLines.removeAll()
                    self.pendingBytes = 0
                    self.diskWriter.rewrite(with: finalCompacted + sessionText)
                }
                // Prepend historical entries; session entries are already at the end.
                self.entries.insert(contentsOf: finalLoaded, at: 0)
                self.estimatedSizeBytes += finalLoaded.reduce(0) { $0 + $1.message.utf8.count + self.avgBytesPerEntry }
                self.trimEntries()
            }
        }
    }

    func log(_ message: String, category: AppLogCategory = .general) {
        let clean = Self.redactSecrets(Self.stripEmojis(message))
        let entry = AppLogEntry(timestamp: Date(), category: category, message: clean)
        entries.append(entry)
        estimatedSizeBytes += clean.utf8.count + avgBytesPerEntry
        bufferForDisk(entry)
        trimEntries()
    }

    /// Remove entries older than 7 days and trim by estimated size (~9.98 MB).
    /// Entries are chronological, so both trims only ever drop from the front.
    private func trimEntries() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        var removeCount = 0
        while removeCount < entries.count, entries[removeCount].timestamp < cutoff {
            estimatedSizeBytes -= entries[removeCount].message.utf8.count + avgBytesPerEntry
            removeCount += 1
        }
        while removeCount < entries.count, estimatedSizeBytes > maxSizeBytes {
            estimatedSizeBytes -= entries[removeCount].message.utf8.count + avgBytesPerEntry
            removeCount += 1
        }
        if removeCount > 0 {
            entries.removeFirst(removeCount)
        }
    }

    func clear() {
        entries.removeAll()
        estimatedSizeBytes = 0
        pendingLines.removeAll()
        pendingBytes = 0
        diskWriter.rewrite(with: "")
    }

    // MARK: - Disk I/O

    private static func diskLine(for entry: AppLogEntry) -> String {
        "\(diskFormatter.string(from: entry.timestamp))\t\(entry.category.rawValue)\t\(entry.message)\n"
    }

    /// Buffer a single entry for the background writer
    private func bufferForDisk(_ entry: AppLogEntry) {
        let line = Self.diskLine(for: entry)
        pendingLines.append(line)
        pendingBytes += line.utf8.count
        if pendingBytes >= flushThresholdBytes {
            flushPendingLines()
        } else if !flushScheduled {
            flushScheduled = true
            let delay = flushInterval
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.flushPendingLines()
            }
        }
    }

    /// Hand buffered lines to the background writer
    private func flushPendingLines(sync: Bool = false) {
        flushScheduled = false
        guard !pendingLines.isEmpty else { return }
        let text = pendingLines.joined()
        pendingLines.removeAll()
        pendingBytes = 0
        diskWriter.append(text, sync: sync)
    }

    func entries(for category: AppLogCategory) -> [AppLogEntry] {
        entries.filter { $0.category == category }
    }

    // MARK: - Emoji Stripping

    /// Remove emoji characters from a string so log files stay clean plain text.
    private static func stripEmojis(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 0x1F300 && v <= 0x1FAFF { continue }  // Emoji pictographs
            if v >= 0x2600 && v <= 0x27BF   { continue }  // Misc symbols (warning, check mark, etc.)
            if v >= 0xFE00 && v <= 0xFE0F   { continue }  // Variation selectors
            if v == 0x200D                  { continue }  // Zero-width joiner
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    // MARK: - Secret Redaction (applied at WRITE time)

    /// Keywords that make it worth running the (more expensive) regexes below.
    /// A plain lowercased substring scan is cheap enough for the alarm path;
    /// almost no log line contains any of these, so the regexes rarely run.
    private static let secretHints = ["password", "passwd", "pwd", "token", "secret",
                                      "api_key", "apikey", "bearer", "signature", "sig=",
                                      "credential", "auth="]

    /// Redacts the highest-value secrets — credentials, tokens, signed-URL
    /// parameters — before the line is stored, so neither the in-memory buffer nor
    /// the on-disk log ever holds them. The broader PII pass (alarm names, SSIDs,
    /// hostnames, IPs) stays export-only on purpose: those are exactly what the
    /// in-app log viewer is for when diagnosing a connection problem, and stripping
    /// them at write time would leave the user's own diagnostics useless.
    private static let secretPatterns: [NSRegularExpression] = {
        let sources = [
            // key=value / key: value forms, quoted or bare
            "(?i)\\b(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|token|credential|auth)\\b\\s*[:=]\\s*\"?([^\\s\",;)&]+)\"?",
            // Authorization: Bearer <token>
            "(?i)\\bBearer\\s+([A-Za-z0-9._~+/=-]{8,})",
            // Signed-URL query parameters
            "(?i)[?&](?:sig|signature|token|access_token|api_key|apikey|key|password)=([^&\\s]+)"
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func redactSecrets(_ message: String) -> String {
        let lowered = message.lowercased()
        guard secretHints.contains(where: { lowered.contains($0) }) else { return message }

        var redacted = message
        for regex in secretPatterns {
            let matches = regex.matches(in: redacted, range: NSRange(redacted.startIndex..., in: redacted))
            // Replace the captured value only (group 1), back to front so earlier
            // ranges stay valid.
            for match in matches.reversed() where match.numberOfRanges > 1 {
                guard let range = Range(match.range(at: 1), in: redacted) else { continue }
                redacted.replaceSubrange(range, with: "[redacted]")
            }
        }
        return redacted
    }

    // MARK: - PII Sanitisation (used only on export)

    /// Regex that matches single-quoted strings up to 150 characters (alarm names, command names).
    private static let quotedNamePattern: NSRegularExpression? =
        try? NSRegularExpression(pattern: "'[^']{1,150}'")

    /// Regex that matches everything after "MQTT alert received: " on a line (alert title + message).
    private static let alertContentPattern: NSRegularExpression? =
        try? NSRegularExpression(pattern: "(?<=MQTT alert received: ).+", options: [])

    /// Regex that matches the payload portion of "PUB <topic> → <payload>" lines
    /// (alarm names, notes, fire times, sleep/wake state).
    private static let pubPayloadPattern: NSRegularExpression? =
        try? NSRegularExpression(pattern: "(PUB \\S+ →) .+")

    /// Regex that matches IPv4 addresses (resolved broker IPs, local addresses).
    private static let ipv4Pattern: NSRegularExpression? =
        try? NSRegularExpression(pattern: "\\b\\d{1,3}(?:\\.\\d{1,3}){3}\\b")

    /// Regexes for network identifiers in known log line shapes: SSIDs
    /// (NetworkMonitor "SSID:"/"WiFi:" lines) and broker hostnames
    /// (MQTTManager connect/switch lines).
    private static let networkIdentifierPatterns: [(regex: NSRegularExpression, template: String)] = {
        let patterns: [(String, String)] = [
            ("(?<=SSID: ).+?(?=,|\\)|$)", "[ssid]"),
            ("(?<=WiFi: ).+?(?= →|,|\\)|$)", "[ssid]"),
            ("(?<=Connecting to )\\S+", "[host]"),
            ("(?<=connected to )\\S+", "[host]"),
            ("(?<=Switching broker to )\\S+", "[host]"),
            ("(?<=broker switching: ).+", "[host] → [host]"),
        ]
        return patterns.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, template)
        }
    }()

    /// Sanitise a single log message for export: redacts alarm names, command names,
    /// MQTT publish payloads, alert content, broker hostnames, SSIDs, and IP addresses
    /// so personal data is not sent to the developer.
    private static func sanitizeForExport(_ message: String, category: AppLogCategory) -> String {
        var sanitized = message

        // Redact single-quoted strings (alarm names, command names) in relevant categories
        if category == .alarm || category == .mqtt || category == .coordinator {
            if let regex = quotedNamePattern {
                sanitized = regex.stringByReplacingMatches(
                    in: sanitized,
                    range: NSRange(sanitized.startIndex..., in: sanitized),
                    withTemplate: "'[name]'"
                )
            }
        }

        // Redact MQTT alert title + body
        if category == .mqtt, let regex = alertContentPattern {
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: NSRange(sanitized.startIndex..., in: sanitized),
                withTemplate: "[redacted]"
            )
        }

        // Redact MQTT publish payloads, keeping the topic
        if category == .mqtt, let regex = pubPayloadPattern {
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: NSRange(sanitized.startIndex..., in: sanitized),
                withTemplate: "$1 [payload redacted]"
            )
        }

        // Redact SSIDs and broker hostnames
        if category == .mqtt || category == .network {
            for (regex, template) in networkIdentifierPatterns {
                sanitized = regex.stringByReplacingMatches(
                    in: sanitized,
                    range: NSRange(sanitized.startIndex..., in: sanitized),
                    withTemplate: template
                )
            }
        }

        // Redact IPv4 addresses in any category
        if let regex = ipv4Pattern {
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: NSRange(sanitized.startIndex..., in: sanitized),
                withTemplate: "[ip]"
            )
        }

        return sanitized
    }

    // MARK: - Plain Text Export

    /// Builds the full diagnostic log as a sanitised plain-text string.
    func exportLogText() -> String {
        var text = "=== Allarise Debug Log ===\n"
        text += "Date: \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .long))\n"
        text += "App: \(appVersion) (\(buildNumber))\n"
        text += "Device: \(deviceModel)\n"
        text += "iOS: \(UIDevice.current.systemVersion)\n"
        text += "Entries: \(entries.count) (~\(estimatedSizeBytes / 1024) KB)\n"
        text += "Note: Alarm names, broker hostnames, IP addresses, and network names have been redacted.\n"
        text += "Note: MQTT entries are excluded — export them separately via Send MQTT Logs.\n"
        text += "==============================\n\n"

        // Main entries. MQTT is excluded: every publish logs a line and the app
        // publishes a large state surface, so MQTT traffic drowned out the
        // alarm/audio entries this log exists to show. It has its own export
        // (exportMQTTLogFile) rather than being duplicated here.
        // Coordinator is excluded too — shown as its own section below.
        for entry in entries where entry.category != .coordinator && entry.category != .mqtt {
            let sanitized = Self.sanitizeForExport(entry.message, category: entry.category)
            let ts = Self.exportFormatter.string(from: entry.timestamp)
            text += "[\(ts)] [\(entry.category.rawValue)] \(sanitized)\n"
        }

        // Coordinator section — alarm scheduling internals
        let coordEntries = entries.filter { $0.category == .coordinator }
        if !coordEntries.isEmpty {
            text += "\n=== ALARM COORDINATOR ===\n"
            for entry in coordEntries {
                let sanitized = Self.sanitizeForExport(entry.message, category: entry.category)
                let ts = Self.exportFormatter.string(from: entry.timestamp)
                text += "[\(ts)] [\(entry.category.rawValue)] \(sanitized)\n"
            }
        }

        return text
    }

    /// Exports the full diagnostic log as a plain-text .txt file. Returns the file URL for sharing.
    func exportLogFile() -> URL? {
        guard let data = exportLogText().data(using: .utf8) else { return nil }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("allarise-diagnostics.txt")
        try? data.write(to: fileURL)
        return fileURL
    }

    /// Exports the MQTT-only log as a plain-text .txt file. Returns the file URL for sharing.
    func exportMQTTLogFile() -> URL? {
        let mqttEntries = entries(for: .mqtt)

        var text = "=== Allarise MQTT Connection Log ===\n"
        text += "Date: \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .long))\n"
        text += "App: \(appVersion) (\(buildNumber))\n"
        text += "Device: \(deviceModel)\n"
        text += "iOS: \(UIDevice.current.systemVersion)\n"
        text += "Entries: \(mqttEntries.count)\n"
        text += "Note: Command names, publish payloads, alert content, broker hostnames, IP addresses, and network names have been redacted.\n"
        text += "==================================\n\n"

        for entry in mqttEntries {
            let sanitized = Self.sanitizeForExport(entry.message, category: entry.category)
            let ts = Self.exportFormatter.string(from: entry.timestamp)
            text += "[\(ts)] [\(entry.category.rawValue)] \(sanitized)\n"
        }

        guard let data = text.data(using: .utf8) else { return nil }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("allarise-mqtt-diagnostics.txt")
        try? data.write(to: fileURL)
        return fileURL
    }

    // MARK: - Device Info

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0)
            }
        }
        return model ?? UIDevice.current.model
    }
}

// MARK: - Background Disk Writer

/// Owns the on-disk log file. All file I/O runs on a private serial queue so
/// logging never blocks the main thread, and every write uses the throwing
/// FileHandle APIs so a failure can never crash alarm-time logging.
private final class LogDiskWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.allarise.AppLogger.disk", qos: .utility)
    private let fileURL: URL
    private var handle: FileHandle?

    init(fileURL: URL) {
        self.fileURL = fileURL
        queue.async { self.openHandle() }
    }

    private func openHandle() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    /// Append text to the log file. `sync` blocks until the write completes
    /// (used only when the app is terminating).
    func append(_ text: String, sync: Bool = false) {
        let work = { [self] in
            guard let data = text.data(using: .utf8) else { return }
            try? handle?.write(contentsOf: data)
        }
        if sync {
            queue.sync(execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    /// Replace the file contents atomically and reopen the handle at the new end.
    /// Atomic writes swap the file inode, so the handle must be reopened here —
    /// otherwise later appends would go to a deleted file.
    func rewrite(with text: String) {
        queue.async { [self] in
            try? handle?.close()
            handle = nil
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
            openHandle()
        }
    }
}
