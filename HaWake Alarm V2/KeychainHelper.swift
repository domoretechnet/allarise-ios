//
//  KeychainHelper.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import Foundation
import Security

/// `nonisolated` so it can be used from any actor/thread — under the project's
/// default-MainActor isolation it would otherwise be inferred `@MainActor`, which breaks
/// background Keychain access (StoreManager's iCloud reconcile, MQTT credential reads, etc.).
/// The underlying Security framework APIs are thread-safe.
nonisolated struct KeychainHelper {
    static let shared = KeychainHelper()

    private init() {}

    /// Store `value` under `key`, replacing any existing item.
    ///
    /// Returns `true` only when the value is definitely on disk. The result is
    /// `@discardableResult` because most call sites are `didSet` observers that
    /// have nothing useful to do about a failure, but the credential paths
    /// (MQTT username/password) do check it — see `DeviceSettings`.
    ///
    /// Never deletes before the new value is stored: an update-then-add, so a
    /// failed write leaves the previous value intact rather than destroying it.
    @discardableResult
    func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            print("KeychainHelper: save failed for key '\(key)' — value is not valid UTF-8")
            return false
        }

        // Match by account ONLY (no accessibility in the match), so a prior item is
        // found regardless of how it was stored — older items were saved without an
        // accessibility attribute (defaulting to WhenUnlocked).
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        // Store as AfterFirstUnlockThisDeviceOnly so the value stays readable during
        // background launches while the device is locked (this is an alarm app — it
        // reads MQTT credentials, the install date, etc. in the background). Without
        // this the default is WhenUnlocked, which returns errSecInteractionNotAllowed
        // when locked. ThisDeviceOnly keeps it off iCloud Keychain while still
        // surviving delete/reinstall on the same device. Updating the accessibility
        // alongside the data upgrades legacy WhenUnlocked items in place.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        guard updateStatus == errSecItemNotFound else {
            // Anything else (notably errSecInteractionNotAllowed on a locked device)
            // means we could not write — but the prior value is still there, which is
            // the whole point of not deleting first.
            print("KeychainHelper: save failed for key '\(key)' — update OSStatus \(updateStatus)")
            return false
        }

        var addQuery = matchQuery
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            print("KeychainHelper: save failed for key '\(key)' — add OSStatus \(addStatus)")
            return false
        }
        return true
    }

    /// Returns true ONLY when the Keychain definitely has no item for `key`
    /// (`errSecItemNotFound`). Any other status — including the device being locked
    /// (`errSecInteractionNotAllowed`) — returns false. Callers use this to decide
    /// whether to WRITE a value, so we must never report "absent" for an item we
    /// merely failed to read, which would overwrite real data (e.g. the install date).
    func isDefinitelyMissing(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: false
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecItemNotFound
    }

    func read(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        guard status == errSecSuccess,
              let data = dataTypeRef as? Data,
              let string = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                print("KeychainHelper: read failed for key '\(key)' — OSStatus \(status)")
            }
            return nil
        }

        return string
    }

    func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("KeychainHelper: delete failed for key '\(key)' — OSStatus \(status)")
        }
    }
}
