//
//  AlertDeduplicationTests.swift
//  HaWake Alarm V2Tests
//
//  Covers the identity + resolution rules that stop a stale MQTT alert
//  notification from re-opening an alert the user already dismissed (al-dhs),
//  WITHOUT suppressing a genuinely new alert that happens to carry the same
//  words — the case Home Assistant hits whenever the same automation fires
//  twice.
//
//  Everything here is hermetic: no notifications, no windows, no broker. The
//  ledger is exercised against its own UserDefaults suite.
//
//  Reference: Documents/15-INBOUND-COMMANDS-REFERENCE.md → "Trigger Alert"
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

// MARK: - Identity

struct AlertIdentityTests {

    @Test("stableHash is deterministic within a run and never negative")
    func stableHashIsDeterministic() {
        let a = AlertIdentity.stableHash("Security Alert")
        let b = AlertIdentity.stableHash("Security Alert")
        #expect(a == b)
        #expect(a >= 0)
        #expect(AlertIdentity.stableHash("") >= 0)
    }

    // The whole point of not using Swift.Hasher: the value must be a pure
    // function of the string, so a notification delivered by an earlier launch
    // still matches. Pinning the literal makes an accidental algorithm swap
    // fail loudly instead of silently orphaning every stored alert key.
    @Test("stableHash is pinned to FNV-1a, so it survives a relaunch")
    func stableHashIsPinned() {
        // FNV-1a("a") = 0xaf63dc4c8601ec8c, sign bit masked off.
        #expect(AlertIdentity.stableHash("a") == 3_414_815_163_700_866_188)
        // Distinct inputs must not collide on anything we actually use.
        #expect(AlertIdentity.stableHash("Security Alert") != AlertIdentity.stableHash("Security Alerts"))
        #expect(AlertIdentity.stableHash("front_door") != AlertIdentity.stableHash("back_door"))
    }

    @Test("Content identity keys on title AND message")
    func contentIdentity() {
        let base = AlertIdentity.content(title: "Security Alert", message: "Motion at the front door")
        #expect(base == AlertIdentity.content(title: "Security Alert", message: "Motion at the front door"))
        #expect(base != AlertIdentity.content(title: "Security Alert", message: "Motion at the back door"))
        #expect(base != AlertIdentity.content(title: "Doorbell", message: "Motion at the front door"))
    }

    @Test("Title/message boundary cannot be shifted into a collision")
    func contentIdentitySeparator() {
        #expect(AlertIdentity.content(title: "ab", message: "c")
                != AlertIdentity.content(title: "a", message: "bc"))
    }

    @Test("Explicit alert_id is trimmed and case-insensitive; blank falls back")
    func explicitIdentity() {
        #expect(AlertIdentity.explicit("front_door") == AlertIdentity.explicit("  Front_Door "))
        #expect(AlertIdentity.explicit("front_door") != AlertIdentity.explicit("back_door"))
        #expect(AlertIdentity.explicit("") == nil)
        #expect(AlertIdentity.explicit("   ") == nil)
    }

    @Test("Explicit and content identities live in different namespaces")
    func identityNamespaces() {
        #expect(AlertIdentity.explicit("x")?.hasPrefix("id:") == true)
        #expect(AlertIdentity.content(title: "x", message: "y").hasPrefix("c:"))
    }

    // Version skew: a notification posted by an older build carries no identity
    // in userInfo. It must still be recognisable, which is exactly why the
    // content identity is derived from the notification's own title and body.
    @Test("Identity list falls back to content when userInfo carries nothing")
    func identityFallbackForOlderNotifications() {
        let derived = AlertIdentity.identities(userInfo: [:], title: "Security Alert", body: "Motion")
        #expect(derived == [AlertIdentity.content(title: "Security Alert", message: "Motion")])
    }

    @Test("Identity list keeps the carried identity first, content second")
    func identityListPrefersCarried() {
        let userInfo: [AnyHashable: Any] = [AlertDeliveryLedger.identityUserInfoKey: "id:front_door"]
        let derived = AlertIdentity.identities(userInfo: userInfo, title: "Security Alert", body: "Motion")
        #expect(derived.first == "id:front_door")
        #expect(derived.contains(AlertIdentity.content(title: "Security Alert", message: "Motion")))
        #expect(derived.count == 2)
    }

    @Test("An empty carried identity is ignored rather than stored")
    func identityListIgnoresEmpty() {
        let userInfo: [AnyHashable: Any] = [AlertDeliveryLedger.identityUserInfoKey: ""]
        let derived = AlertIdentity.identities(userInfo: userInfo, title: "T", body: "B")
        #expect(derived == [AlertIdentity.content(title: "T", message: "B")])
    }
}

// MARK: - Ledger

struct AlertDeliveryLedgerTests {

    /// Each test gets its own suite so nothing leaks between them or into the
    /// app's real defaults.
    private func makeLedger() -> (AlertDeliveryLedger, UserDefaults, String) {
        let name = "AlertDeliveryLedgerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (AlertDeliveryLedger(userDefaults: defaults), defaults, name)
    }

    private func tearDown(_ defaults: UserDefaults, _ name: String) {
        defaults.removePersistentDomain(forName: name)
    }

    @Test("An alert nobody dismissed is never suppressed")
    func unknownIdentityIsNotResolved() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        #expect(ledger.isResolved(identity: "c:1", deliveredAt: Date()) == false)
        #expect(ledger.resolvedDate(for: "c:1") == nil)
    }

    // THE BUG: notification arrives, user dismisses the alert, taps the leftover
    // notification later. That tap must not reopen anything.
    @Test("A notification older than the dismissal is suppressed")
    func staleNotificationIsSuppressed() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        let delivered = Date(timeIntervalSince1970: 1_000_000)
        let dismissed = delivered.addingTimeInterval(30)
        ledger.markResolved(["c:42"], at: dismissed)

        #expect(ledger.isResolved(identity: "c:42", deliveredAt: delivered))
    }

    // THE REGRESSION GUARD: Home Assistant re-sends the same alert. Identical
    // text, brand new notification — it must still open.
    @Test("A notification newer than the dismissal still opens")
    func resendIsNotSuppressed() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        let dismissed = Date(timeIntervalSince1970: 1_000_000)
        ledger.markResolved(["c:42"], at: dismissed)
        let redelivered = dismissed.addingTimeInterval(60)

        #expect(ledger.isResolved(identity: "c:42", deliveredAt: redelivered) == false)
    }

    @Test("A dismissal at the same instant as delivery still suppresses")
    func equalTimestampsSuppress() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        let moment = Date(timeIntervalSince1970: 1_000_000)
        ledger.markResolved(["c:42"], at: moment)
        #expect(ledger.isResolved(identity: "c:42", deliveredAt: moment))
    }

    @Test("Any known identity of a notification counts")
    func anyOfMatches() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        let delivered = Date(timeIntervalSince1970: 1_000_000)
        ledger.markResolved(["c:content"], at: delivered.addingTimeInterval(5))

        #expect(ledger.isResolved(anyOf: ["id:front_door", "c:content"], deliveredAt: delivered))
        #expect(ledger.isResolved(anyOf: ["id:front_door"], deliveredAt: delivered) == false)
        #expect(ledger.isResolved(anyOf: [], deliveredAt: delivered) == false)
    }

    @Test("Re-resolving keeps the newest timestamp, never moves it backwards")
    func resolutionTimeOnlyMovesForward() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        let later = Date(timeIntervalSince1970: 2_000_000)
        ledger.markResolved(["c:42"], at: later)
        ledger.markResolved(["c:42"], at: later.addingTimeInterval(-500))

        #expect(ledger.resolvedDate(for: "c:42")?.timeIntervalSince1970 == later.timeIntervalSince1970)
    }

    @Test("Entries older than maxAge are pruned on the next write")
    func agePruning() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        let now = Date()
        let ancient = now.addingTimeInterval(-(AlertDeliveryLedger.maxAge + 60))
        ledger.markResolved(["c:ancient"], at: ancient)
        #expect(ledger.resolvedDate(for: "c:ancient") != nil)

        ledger.markResolved(["c:fresh"], at: now)
        #expect(ledger.resolvedDate(for: "c:ancient") == nil)
        #expect(ledger.resolvedDate(for: "c:fresh") != nil)
    }

    @Test("The ledger stays bounded and keeps the newest entries")
    func countPruning() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        let base = Date()
        let overflow = AlertDeliveryLedger.maxEntries + 15
        for i in 0..<overflow {
            ledger.markResolved(["c:\(i)"], at: base.addingTimeInterval(Double(i)))
        }

        // Oldest dropped, newest kept, total capped.
        #expect(ledger.resolvedDate(for: "c:0") == nil)
        #expect(ledger.resolvedDate(for: "c:\(overflow - 1)") != nil)

        var kept = 0
        for i in 0..<overflow where ledger.resolvedDate(for: "c:\(i)") != nil { kept += 1 }
        #expect(kept <= AlertDeliveryLedger.maxEntries)
    }

    @Test("Blank identities are never stored")
    func blankIdentitiesIgnored() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        ledger.markResolved([""], at: Date())
        #expect(ledger.resolvedDate(for: "") == nil)
    }

    @Test("removeAll clears the ledger")
    func removeAllClears() {
        let (ledger, defaults, name) = makeLedger()
        defer { tearDown(defaults, name) }

        ledger.markResolved(["c:42"], at: Date())
        ledger.removeAll()
        #expect(ledger.resolvedDate(for: "c:42") == nil)
    }
}

// MARK: - Payload

@MainActor
struct AlertPayloadIdentityTests {

    @Test("alertAlarmID is a pure function of the title")
    func alertAlarmIDIsStable() {
        let first = MQTTCommandHandler.alertAlarmID(title: "Security Alert")
        #expect(first == MQTTCommandHandler.alertAlarmID(title: "Security Alert"))
        #expect(first >= 0)
        #expect(first != MQTTCommandHandler.alertAlarmID(title: "Doorbell"))
    }

    @Test("alert_id is optional and absent means no explicit identity")
    func explicitAlertIDAbsent() {
        #expect(MQTTCommandHandler.explicitAlertID(from: ["message": "hi"]) == nil)
    }

    @Test("alert_id accepts a string")
    func explicitAlertIDString() {
        #expect(MQTTCommandHandler.explicitAlertID(from: ["alert_id": "front_door"]) == "front_door")
    }

    // Permissive validation: an automation template that yields a number must
    // not be a silent no-op the way `days` was.
    @Test("alert_id accepts a number")
    func explicitAlertIDNumber() {
        #expect(MQTTCommandHandler.explicitAlertID(from: ["alert_id": 42]) == "42")
    }

    @Test("Without alert_id, two identical alerts share an identity")
    func contentIdentityMatchesForCarbonCopies() {
        let a = AlertIdentity.content(title: "Security Alert", message: "Motion detected")
        let b = AlertIdentity.content(title: "Security Alert", message: "Motion detected")
        #expect(a == b)
    }
}
