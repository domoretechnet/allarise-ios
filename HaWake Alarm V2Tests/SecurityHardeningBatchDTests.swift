//
//  SecurityHardeningBatchDTests.swift
//  HaWake Alarm V2Tests
//
//  Covers the Batch-D hardening fixes from the 2026-08-03 security audit
//  (`Documents/reviews/2026-08-03/06-COMBINED-SECURITY-AND-DEAD-CODE-AUDIT.md`):
//
//  * SEC-06 — `KeychainHelper.save` was delete-then-add (a failed add destroyed
//    the prior value) and returned nothing.
//  * SEC-07 — MQTT `link_url` opened any scheme.
//  * SEC-08 — the MQTT client ID was `allarise-<deviceName>`, fully predictable.
//  * SEC-10 — credentials/tokens were written to the log buffer unredacted.
//
//  All four have a pure seam, so none of this needs a broker or a ModelContainer.
//  The Keychain tests run against the real Keychain in the test host and use a
//  unique account key per test so they cannot collide with app data.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

// MARK: - SEC-06 Keychain

// These need a SIGNED test host: build-for-testing with `CODE_SIGNING_ALLOWED=NO`
// leaves the app host without a keychain-access-group entitlement and every
// SecItem call fails with errSecMissingEntitlement. `.serialized` keeps the
// Keychain traffic one-at-a-time, which also makes any failure legible.
@Suite("SEC-06 Keychain save is atomic and reports failure", .serialized)
@MainActor
struct KeychainSaveTests {

    private func uniqueKey() -> String { "test.batchd.\(UUID().uuidString)" }

    @Test("A first save adds the item and reports success")
    func addPath() {
        let key = uniqueKey()
        defer { KeychainHelper.shared.delete(forKey: key) }

        #expect(KeychainHelper.shared.isDefinitelyMissing(forKey: key))
        #expect(KeychainHelper.shared.save("first", forKey: key))
        #expect(KeychainHelper.shared.read(forKey: key) == "first")
    }

    @Test("A second save updates in place rather than delete-then-add")
    func updatePath() {
        let key = uniqueKey()
        defer { KeychainHelper.shared.delete(forKey: key) }

        #expect(KeychainHelper.shared.save("first", forKey: key))
        #expect(KeychainHelper.shared.save("second", forKey: key))
        #expect(KeychainHelper.shared.read(forKey: key) == "second")
    }

    @Test("Repeated saves of the same value stay successful (didSet writes are idempotent)")
    func idempotentSave() {
        let key = uniqueKey()
        defer { KeychainHelper.shared.delete(forKey: key) }

        for _ in 0..<3 {
            #expect(KeychainHelper.shared.save("same", forKey: key))
        }
        #expect(KeychainHelper.shared.read(forKey: key) == "same")
    }

    @Test("Deleting leaves the key definitely missing, and a later save re-adds it")
    func deleteThenReAdd() {
        let key = uniqueKey()
        defer { KeychainHelper.shared.delete(forKey: key) }

        #expect(KeychainHelper.shared.save("value", forKey: key))
        KeychainHelper.shared.delete(forKey: key)
        #expect(KeychainHelper.shared.isDefinitelyMissing(forKey: key))
        #expect(KeychainHelper.shared.read(forKey: key) == nil)
        #expect(KeychainHelper.shared.save("again", forKey: key))
        #expect(KeychainHelper.shared.read(forKey: key) == "again")
    }

    @Test("An empty string is a legitimate value, not a failure")
    func emptyValue() {
        let key = uniqueKey()
        defer { KeychainHelper.shared.delete(forKey: key) }

        #expect(KeychainHelper.shared.save("", forKey: key))
        #expect(KeychainHelper.shared.read(forKey: key) == "")
    }
}

// MARK: - SEC-07 Alert link scheme allowlist

@Suite("SEC-07 MQTT alert links are http/https only")
@MainActor
struct AlertLinkPolicyTests {

    @Test("http and https links resolve", arguments: [
        "http://homeassistant.local:8123/lovelace/cameras",
        "https://example.com/dashboard",
        "HTTPS://EXAMPLE.COM/UPPER"
    ])
    func allowedSchemes(link: String) {
        #expect(AlertLinkPolicy.resolve(link) != nil)
        #expect(AlertLinkPolicy.rejectedScheme(link) == nil)
    }

    @Test("Non-web schemes are refused and named", arguments: [
        ("file:///etc/passwd", "file"),
        ("tel:+15555550123", "tel"),
        ("sms:+15555550123", "sms"),
        ("mailto:someone@example.com", "mailto"),
        ("shortcuts://run-shortcut?name=Unlock", "shortcuts"),
        ("javascript:alert(1)", "javascript")
    ])
    func blockedSchemes(link: String, scheme: String) {
        #expect(AlertLinkPolicy.resolve(link) == nil)
        #expect(AlertLinkPolicy.rejectedScheme(link) == scheme)
    }

    @Test("Absent or blank links are simply absent — nothing to warn about")
    func emptyLinks() {
        #expect(AlertLinkPolicy.resolve(nil) == nil)
        #expect(AlertLinkPolicy.rejectedScheme(nil) == nil)
        #expect(AlertLinkPolicy.resolve("   ") == nil)
        #expect(AlertLinkPolicy.rejectedScheme("   ") == nil)
    }

    @Test("A scheme-less string is refused rather than guessed at")
    func schemeless() {
        #expect(AlertLinkPolicy.resolve("homeassistant.local/dashboard") == nil)
        #expect(AlertLinkPolicy.rejectedScheme("homeassistant.local/dashboard") != nil)
    }

    @Test("Surrounding whitespace does not defeat the allowlist")
    func trimmed() {
        #expect(AlertLinkPolicy.resolve("  https://example.com  ") != nil)
        #expect(AlertLinkPolicy.rejectedScheme("  file:///tmp/x  ") == "file")
    }
}

// MARK: - SEC-08 Client ID

@Suite("SEC-08 MQTT client ID carries a stable random suffix")
@MainActor
struct MQTTClientIDTests {

    private func scratchDefaults() -> UserDefaults {
        let suite = "test.batchd.clientid.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    @Test("The suffix is generated once and then reused")
    func suffixIsStable() {
        let defaults = scratchDefaults()
        let first = MQTTManager.clientIDSuffix(defaults: defaults)
        let second = MQTTManager.clientIDSuffix(defaults: defaults)
        #expect(first == second)
        #expect(first.count == 8)
        #expect(defaults.string(forKey: MQTTManager.clientIDSuffixKey) == first)
    }

    @Test("Two installs get different suffixes, so the ID is not guessable from the name")
    func suffixDiffersPerInstall() {
        let a = MQTTManager.mqttClientID(deviceName: "bedroom", defaults: scratchDefaults())
        let b = MQTTManager.mqttClientID(deviceName: "bedroom", defaults: scratchDefaults())
        #expect(a != b)
        #expect(a.hasPrefix("allarise-bedroom-"))
        #expect(b.hasPrefix("allarise-bedroom-"))
    }

    @Test("The client ID is stable across calls for one install")
    func clientIDIsStable() {
        let defaults = scratchDefaults()
        let first = MQTTManager.mqttClientID(deviceName: "bedroom", defaults: defaults)
        let second = MQTTManager.mqttClientID(deviceName: "bedroom", defaults: defaults)
        #expect(first == second)
    }

    @Test("A very long device name is truncated so brokers' length limits hold")
    func lengthCap() {
        let defaults = scratchDefaults()
        let id = MQTTManager.mqttClientID(deviceName: String(repeating: "a", count: 400), defaults: defaults)
        #expect(id.count <= 100)
        #expect(id.hasPrefix("allarise-"))
    }
}

// MARK: - SEC-10 Write-time secret redaction

@Suite("SEC-10 Secrets are redacted before the log line is stored")
@MainActor
struct LogSecretRedactionTests {

    @Test("Credential and token forms lose their value", arguments: [
        "MQTT connect password=hunter2 host=broker",
        "MQTT connect password: hunter2",
        "Fetched with api_key=abcdef123456",
        "Header Authorization: Bearer eyJhbGciOiJIUzI1NiJ9",
        "GET https://example.com/media.jpg?sig=abc123def456&w=100"
    ])
    func secretsRedacted(line: String) {
        let redacted = AppLogger.redactSecrets(line)
        #expect(redacted.contains("[redacted]"))
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("abcdef123456"))
        #expect(!redacted.contains("eyJhbGciOiJIUzI1NiJ9"))
        #expect(!redacted.contains("abc123def456"))
    }

    @Test("Ordinary diagnostic lines are left completely alone")
    func ordinaryLinesUntouched() {
        let lines = [
            "Connecting to homeassistant.local:1883",
            "PUB allarise/bedroom/state → {\"armed\":true}",
            "Alarm 'Wake up' scheduled for 06:30",
            "SSID: HomeNet, host 192.168.1.10"
        ]
        for line in lines {
            #expect(AppLogger.redactSecrets(line) == line)
        }
    }

    @Test("The surrounding context survives so the line stays diagnosable")
    func contextSurvives() {
        let redacted = AppLogger.redactSecrets("MQTT connect password=hunter2 host=broker")
        #expect(redacted.contains("MQTT connect"))
        #expect(redacted.contains("host=broker"))
    }
}
