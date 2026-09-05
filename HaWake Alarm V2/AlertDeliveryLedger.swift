//
//  AlertDeliveryLedger.swift
//  HaWake Alarm V2
//
//  Identity and resolution tracking for inbound Home Assistant alerts.
//
//  WHY THIS EXISTS
//  ---------------
//  An alert that arrives while the app is backgrounded posts a `MQTT_ALERT`
//  local notification, and tapping that notification restores the alert into
//  `PendingAlarmStore` so `checkAndShowPendingAlarm()` can present it. That
//  restore path is deliberate: the alert is transient (no SwiftData row, no
//  AlarmKit failsafe), so the notification is the ONLY way back to an alert the
//  user has not seen yet if the app died in between.
//
//  The cost was that the notification stays in Notification Center after the
//  alert has been dismissed, and tapping it days later re-presented — and
//  re-sounded — an alert the user had already dealt with (al-dhs).
//
//  The fix is a small ledger of alerts the user has already resolved, keyed on a
//  stable identity, checked at notification-tap time only:
//
//      suppress the reopen  ⟺  this identity was resolved AT OR AFTER the
//                              moment this notification was delivered
//
//  The timestamp half of that rule is what makes it safe to re-send the same
//  alert from Home Assistant. A NEW notification carrying identical text has a
//  delivery date later than the old dismissal, so it is allowed through; only
//  the notification that predates the dismissal is stale. Nothing here ever
//  suppresses an alert as it ARRIVES from Home Assistant — a live command from
//  HA always rings; a silent no-op would be the worse failure.
//
//  Nothing in this file is reachable from a real (SwiftData-backed) alarm, its
//  snooze failsafe, its grace period, or the `ALARM_BACKUP` recovery
//  notification. Those paths are untouched.
//

import Foundation

// MARK: - Identity

/// Stable identity for an inbound alert.
///
/// "Stable" here means **across launches**: `Swift.Hasher` is seeded per
/// process, so anything hashed with it changes value on every cold start and is
/// useless for matching a notification delivered by an earlier run of the app.
enum AlertIdentity {

    /// FNV-1a (64-bit), folded to a non-negative `Int`.
    /// Deterministic for a given string on every launch and every device.
    static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        // Mask the sign bit so the result is always a positive Int, matching the
        // `abs(hasher.finalize())` contract the alert alarm IDs had before.
        return Int(bitPattern: UInt(hash & 0x7FFF_FFFF_FFFF_FFFF))
    }

    /// Identity derived from what the user actually sees.
    ///
    /// Title and message are exactly the notification's `title` and `body`, so
    /// this can be recomputed from a delivered notification alone — including
    /// one posted by an older build that never wrote an identity into
    /// `userInfo`. That is what makes the dedupe work under version skew in
    /// both directions.
    static func content(title: String, message: String) -> String {
        // U+001F (unit separator) can't appear in a sane title, so
        // "ab" + "c" and "a" + "bc" cannot collide.
        return "c:\(stableHash(title + "\u{1F}" + message))"
    }

    /// Identity from an explicit `alert_id` supplied by Home Assistant.
    /// Returns nil for a blank id so the caller falls back to `content`.
    static func explicit(_ alertID: String) -> String? {
        let trimmed = alertID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "id:\(trimmed.lowercased())"
    }

    /// Every identity a delivered notification could be known by, most specific
    /// first. The explicit one is only present when the sending build wrote it;
    /// the content one is always derivable, which is the version-skew fallback.
    static func identities(userInfo: [AnyHashable: Any], title: String, body: String) -> [String] {
        var result: [String] = []
        if let stored = userInfo[AlertDeliveryLedger.identityUserInfoKey] as? String, !stored.isEmpty {
            result.append(stored)
        }
        let derived = content(title: title, message: body)
        if !result.contains(derived) { result.append(derived) }
        return result
    }
}

// MARK: - Ledger

/// Remembers which alerts the user has already resolved, and when.
///
/// Deliberately tiny and self-pruning: at most `maxEntries` rows, none older
/// than `maxAge`. It is a dedupe hint, not a record of anything — losing it
/// costs one stale re-open, never a missed alert.
final class AlertDeliveryLedger {

    static let shared = AlertDeliveryLedger()

    /// `userInfo` key carrying the identity a notification was posted with.
    static let identityUserInfoKey = "alertIdentity"
    /// `userInfo` key carrying the moment the alert was sent (epoch seconds).
    /// Preferred over `UNNotification.date` when present; the fallback keeps
    /// notifications from older builds working.
    static let sentAtUserInfoKey = "alertSentAt"

    /// Old entries are worthless — a notification that survived a week in
    /// Notification Center is not something the user is about to tap.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Hard cap so a chatty automation cannot grow UserDefaults without bound.
    static let maxEntries = 40

    private let storageKey = "HaWakeAlarm.resolvedAlerts"
    private let defaults: UserDefaults

    /// - Parameter userDefaults: injectable so tests get their own suite.
    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    /// Record that these identities refer to an alert the user has resolved
    /// (dismissed in-app, dismissed from the notification action, or dismissed
    /// remotely by Home Assistant).
    func markResolved(_ identities: [String], at date: Date = Date()) {
        let stamp = date.timeIntervalSince1970
        var map = storedMap()
        var changed = false
        for identity in identities where !identity.isEmpty {
            if (map[identity] ?? -.greatestFiniteMagnitude) < stamp {
                map[identity] = stamp
                changed = true
            }
        }
        guard changed else { return }
        defaults.set(pruned(map, now: date), forKey: storageKey)
    }

    /// True when this alert was resolved at or after `deliveredAt` — i.e. the
    /// notification being tapped is older than the dismissal, so re-opening it
    /// would resurrect something the user already dealt with.
    ///
    /// A newer delivery of the same content is NOT suppressed: its date is
    /// after the recorded resolution, so this returns false and the alert opens.
    func isResolved(identity: String, deliveredAt: Date) -> Bool {
        guard let resolvedAt = storedMap()[identity] else { return false }
        return resolvedAt >= deliveredAt.timeIntervalSince1970
    }

    /// Convenience for the notification-tap path: any known identity counts.
    func isResolved(anyOf identities: [String], deliveredAt: Date) -> Bool {
        identities.contains { isResolved(identity: $0, deliveredAt: deliveredAt) }
    }

    /// When this identity was last resolved, if ever. Diagnostics and tests.
    func resolvedDate(for identity: String) -> Date? {
        storedMap()[identity].map(Date.init(timeIntervalSince1970:))
    }

    /// Test/maintenance hook — drops every entry.
    func removeAll() {
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: - Storage

    private func storedMap() -> [String: Double] {
        defaults.dictionary(forKey: storageKey) as? [String: Double] ?? [:]
    }

    private func pruned(_ map: [String: Double], now: Date) -> [String: Double] {
        let cutoff = now.timeIntervalSince1970 - Self.maxAge
        var kept = map.filter { $0.value >= cutoff }
        guard kept.count > Self.maxEntries else { return kept }
        // Keep the newest; the oldest are the least likely to still have a
        // notification sitting in Notification Center.
        let survivors = kept.sorted { $0.value > $1.value }.prefix(Self.maxEntries)
        kept = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
        return kept
    }
}
