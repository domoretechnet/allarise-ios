//
//  StoreManager.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import Foundation
import StoreKit
import Observation
import UIKit

@MainActor
@Observable
final class StoreManager {
    static let shared = StoreManager()
    
    // MARK: - Product IDs
    
    static let lifetimeID = "com.hawakeyetalarm.pro"
    static let monthlyID  = "com.hawakeyetalarm.pro.monthly1"

    /// One-time "tip jar" support products, cheapest → most generous. Non-consumable so
    /// each is restorable across devices; a supporter who wants to give again picks a
    /// different tier. Buying ANY of these (like any purchase) sets the permanent
    /// `hasSupported` flag, which suppresses the periodic support prompt forever.
    ///
    /// ⚠️ These IDs are a published contract the moment they ship — App Store Connect
    /// entitlements are keyed on them. Add new tiers; never rename or retype an existing one.
    static let tipIDs: [String] = [
        "com.hawakeyetalarm.support.tip1",   // $0.99
        "com.hawakeyetalarm.support.tip3",   // $2.99
        "com.hawakeyetalarm.support.tip10",  // $9.99
        "com.hawakeyetalarm.support.tip20b", // $19.99  (recreated — old …tip20 ID retired)
    ]

    /// Every product ID the app asks StoreKit to load — the two legacy Pro products plus
    /// the tip tiers.
    static var allProductIDs: [String] { [lifetimeID, monthlyID] + tipIDs }
    
    // MARK: - State
    
    private(set) var products: [Product] = []
    private(set) var purchasedProductIDs = Set<String>()

    /// True if the user originally downloaded the app before version 6 (beta testers / early adopters).
    private(set) var isEarlyAdopter: Bool = false

    /// The early-adopter cutoff currently in effect. Initialized to the baked-in
    /// `fallbackActivationDate`, then overwritten by the last successfully fetched
    /// server value (cached in UserDefaults). Anyone whose first install date is
    /// before this gets free Pro. Served from `allarise.app` so the launch/promo
    /// window can move without an app update.
    private(set) var activationCutoff: Date = StoreManager.fallbackActivationDate

    /// Server kill-switch for the whole early-adopter program. When false,
    /// `checkEarlyAdopter` never grants and ignores existing grants (without deleting
    /// them — flipping it back true restores grantees). Defaults true. Lets you force
    /// everyone (incl. App Review) to the paywall, then re-enable after approval.
    @ObservationIgnored private var earlyAdopterEnabled = true

    /// The currently-set debug install-date override, or nil when no override is active.
    /// Persisted in Keychain so overrides written in Debug builds survive into
    /// TestFlight/Release — enabling end-to-end IAP testing and install-date-gated
    /// default testing across build configurations.
    private(set) var installDateOverride: Date? = nil

    /// True when a debug install-date override is active.
    var installDateOverrideActive: Bool { installDateOverride != nil }

    var lifetimeProduct: Product? { products.first { $0.id == Self.lifetimeID } }
    var monthlyProduct:  Product? { products.first { $0.id == Self.monthlyID  } }

    /// Loaded tip products in the canonical cheapest → most generous order, filtered to
    /// those that actually loaded. Fail-soft: a tier not yet live in App Store Connect is
    /// simply absent — the support screen renders the ones it has, never an error.
    var tipProducts: [Product] {
        Self.tipIDs.compactMap { id in products.first { $0.id == id } }
    }

    /// Every **one-time** support option — the tip tiers *and* the lifetime — sorted by
    /// price, with anything the user already owns removed. In the free model the lifetime
    /// is just a larger one-time tip, so the support screen presents them together. Owned
    /// non-consumables drop out (they can't be bought twice), which also means a lifetime
    /// owner is never re-offered the lifetime, and a given tip tier disappears once used.
    var oneTimeSupportProducts: [Product] {
        let ids = Set(Self.tipIDs + [Self.lifetimeID])
        return products
            .filter { ids.contains($0.id) && !purchasedProductIDs.contains($0.id) }
            .sorted { $0.price < $1.price }
    }

    /// True if the user owns the lifetime IAP or has an active monthly subscription.
    var isPro: Bool {
        purchasedProductIDs.contains(Self.lifetimeID) ||
        purchasedProductIDs.contains(Self.monthlyID)
    }

    // MARK: - Free model (2026-08)

    /// The app is free: every feature is unlocked for everyone. Purchases and the tip
    /// tiers still exist, but as *optional support* — they no longer gate any feature.
    /// Feature-gate sites read this instead of `effectiveIsPro`; it is a deliberate,
    /// self-documenting switch (flip to `effectiveIsPro` to restore paid gating).
    var featuresUnlocked: Bool { true }

    /// Keychain/iCloud-KVS key recording that the user has ever supported the project —
    /// bought any tip, the lifetime IAP, or the subscription. Set once, never cleared, so
    /// a lapsed subscriber (whose live entitlement is gone) is still recognised as a
    /// supporter and never re-prompted. Survives reinstalls (Keychain) and follows the
    /// Apple ID to a new device (KVS).
    nonisolated static let hasSupportedKey = "com.allarise.hasSupported"

    /// True once the user has ever made any supporting purchase.
    private(set) var hasSupported: Bool = KeychainHelper.shared.read(forKey: StoreManager.hasSupportedKey) == "true"

    /// A "supporter" is anyone we should never show the periodic support prompt to: they
    /// own a Pro product, have ever tipped, or are a complimentary early adopter (who were
    /// here first — we don't nag them). Existing purchasers therefore see nothing change.
    var isSupporter: Bool { isPro || hasSupported || isEarlyAdopter }

    /// Records a permanent "has supported" flag (idempotent) in Keychain and mirrors it to
    /// iCloud KVS off the main thread, so support recognition follows the Apple ID.
    func markHasSupported() {
        guard !hasSupported else { return }
        hasSupported = true
        KeychainHelper.shared.save("true", forKey: Self.hasSupportedKey)
        Task.detached(priority: .utility) {
            let store = NSUbiquitousKeyValueStore.default
            store.set(true, forKey: Self.hasSupportedKey)
            store.synchronize()
        }
        AppLogger.shared.log("Supporter status recorded (hasSupported = true)", category: .general)
    }

    #if DEBUG
    var forceProForTesting: Bool = false

    /// Debug-only: clears the persisted supporter flag (Keychain + iCloud KVS) so the
    /// support-prompt flow can be re-tested as a non-supporter.
    @MainActor
    func debugResetHasSupported() async {
        hasSupported = false
        KeychainHelper.shared.delete(forKey: Self.hasSupportedKey)
        await Task.detached(priority: .utility) {
            let store = NSUbiquitousKeyValueStore.default
            store.removeObject(forKey: Self.hasSupportedKey)
            store.synchronize()
        }.value
        AppLogger.shared.log("DEBUG: hasSupported reset (Keychain + iCloud)", category: .general)
    }
    #endif

    var effectiveIsPro: Bool {
        #if DEBUG
        return isPro || isEarlyAdopter || forceProForTesting
        #else
        return isPro || isEarlyAdopter
        #endif
    }
    
    @ObservationIgnored
    nonisolated(unsafe) private var updateListenerTask: Task<Void, Error>?

    /// Observer token for iCloud KVS external changes, so a grant/install date that
    /// syncs down from another device (e.g. on a brand-new phone) is applied without
    /// a relaunch. Removed in deinit.
    @ObservationIgnored
    nonisolated(unsafe) private var kvsObserver: NSObjectProtocol?

    /// Observer token for app-foreground, so subscription expiry (and the activation
    /// date) are re-checked on warm resume — not just on cold launch. Removed in deinit.
    @ObservationIgnored
    nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?

    private init() {
        let _smT = Date()
        func smElapsed(_ label: String) {
            let ms = Date().timeIntervalSince(_smT) * 1000
            print(String(format: "⏱️ [StoreManager.init] %@ — %.0f ms", label, ms))
        }
        print("⏱️ StoreManager init started")
        // Record first install date before anything else — must be synchronous so it
        // captures the true first-launch date, not a delayed async moment.
        Self.recordFirstInstallDateIfNeeded()
        smElapsed("recordFirstInstallDateIfNeeded")
        // Hydrate debug install-date override from Keychain (persists across
        // Debug → TestFlight builds so the override survives build switches).
        if let iso = KeychainHelper.shared.read(forKey: Self.firstInstallDateOverrideKey),
           let date = ISO8601DateFormatter().date(from: iso) {
            installDateOverride = date
        }
        smElapsed("installDateOverride")

        // Hydrate the cached server activation date (falls back to the baked-in
        // fallbackActivationDate when absent). Non-sensitive cache, so UserDefaults
        // rather than Keychain — it's re-fetched and refreshed on every launch.
        if let iso = UserDefaults.standard.string(forKey: Self.activationDateCacheKey),
           let date = ISO8601DateFormatter().date(from: iso) {
            activationCutoff = date
        }
        // Hydrate the cached server kill-switch (defaults true if never fetched).
        earlyAdopterEnabled = UserDefaults.standard.object(forKey: Self.earlyAdopterEnabledKey) as? Bool ?? true
        smElapsed("activationDateCache")

        // Resolve early-adopter status SYNCHRONOUSLY here — it's pure Keychain/
        // UserDefaults reads + date comparison, no network I/O. Doing it now means
        // the very first check of effectiveIsPro (e.g., when the user immediately
        // taps "New Alarm") already returns a value, instead of waiting for the
        // StoreKit product-load network call to complete first.
        //
        // A previously-earned grant is permanent (never revoked, even if the server
        // cutoff later moves earlier). Otherwise this is a provisional fail-closed
        // comparison against the cutoff currently known (cached server value, or the
        // baked-in fallback); the async refresh below finalizes it against the live
        // server value.
        if !earlyAdopterEnabled {
            isEarlyAdopter = false
        } else if earlyAdopterGranted {
            isEarlyAdopter = true
        } else if let installDate = Self.effectiveFirstInstallDate {
            isEarlyAdopter = installDate < activationCutoff
        }
        smElapsed("effectiveFirstInstallDate")
        print("⏱️ StoreManager early-adopter status resolved synchronously: \(isEarlyAdopter)")

        updateListenerTask = listenForTransactions()
        smElapsed("listenForTransactions")

        // Apply early-adopter grants/install dates that sync down from another device
        // after launch (e.g. on a new phone, KVS lands a few seconds late). object: nil
        // avoids touching NSUbiquitousKeyValueStore.default on the main thread here.
        kvsObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.syncEarlyAdopterWithiCloud() }
        }
        smElapsed("kvsObserver")

        // Re-check entitlements + activation date when the app returns to the foreground,
        // so an expired subscription loses access (and a moved cutoff is picked up) on a
        // warm resume rather than only on the next cold launch.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.updatePurchasedProducts()
                await self?.refreshActivationDate()
            }
        }
        smElapsed("foregroundObserver")

        // Load products and verify purchases in the background, then reconcile
        // early-adopter state with iCloud (which re-runs checkEarlyAdopter at the end).
        Task.detached(priority: .userInitiated) {
            print("⏱️ StoreManager refreshing activation date...")
            await self.refreshActivationDate()
            print("⏱️ StoreManager loading products...")
            await self.loadProducts()
            print("⏱️ StoreManager updating purchases...")
            await self.updatePurchasedProducts()
            print("⏱️ StoreManager reconciling early-adopter with iCloud...")
            await self.syncEarlyAdopterWithiCloud()
            print("✅ StoreManager initialization complete")
        }
        smElapsed("DONE")
    }

    deinit {
        let task = updateListenerTask
        task?.cancel()
        if let kvsObserver {
            NotificationCenter.default.removeObserver(kvsObserver)
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }
    
    // MARK: - Transaction Listener
    
    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)
                    await self.updatePurchasedProducts()
                    await transaction.finish()
                } catch {
                    print("Transaction verification failed: \(error)")
                }
            }
        }
    }
    
    // MARK: - Load Products
    
    @MainActor
    func loadProducts() async {
        let productIDs = Self.allProductIDs
        var delay: UInt64 = 1_000_000_000 // 1s, doubles each retry

        for attempt in 1...4 {
            do {
                let loadedProducts = try await Product.products(for: productIDs)
                if !loadedProducts.isEmpty {
                    products = loadedProducts.sorted { a, _ in a.id == Self.lifetimeID }
                    let ids = loadedProducts.map(\.id).joined(separator: ", ")
                    print("✅ Loaded \(loadedProducts.count) products (attempt \(attempt)): \(ids)")
                    AppLogger.shared.log("Loaded \(loadedProducts.count) IAP products: \(ids)", category: .general)
                    if monthlyProduct == nil {
                        AppLogger.shared.log("⚠️ Monthly product (\(Self.monthlyID)) did NOT load — check App Store Connect/StoreKit config", category: .general)
                    }
                    return
                }
                // Empty result — StoreKit not ready yet, retry
                print("⚠️ Product fetch returned empty (attempt \(attempt)), retrying…")
            } catch {
                print("❌ Failed to load products (attempt \(attempt)): \(error)")
            }
            if attempt < 4 {
                try? await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        // All retries exhausted — leave products empty so UI shows retry button
        print("❌ Product loading failed after all retries")
    }
    
    // MARK: - Purchase Status
    
    @MainActor
    func updatePurchasedProducts() async {
        var purchasedIDs: Set<String> = []
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                purchasedIDs.insert(transaction.productID)
            } catch {
                print("❌ Transaction verification failed: \(error)")
            }
        }
        purchasedProductIDs = purchasedIDs
        print("✅ Updated purchased products: \(purchasedIDs)")
        AppLogger.shared.log("Current entitlements: \(purchasedIDs.isEmpty ? "none" : purchasedIDs.sorted().joined(separator: ", "))", category: .general)

        // Any owned product — legacy Pro or a tip — makes the user a supporter forever.
        // This also covers existing purchasers and restores on a new device: the moment
        // their entitlement is seen, the permanent flag is set so they're never prompted.
        if !purchasedIDs.isEmpty {
            markHasSupported()
        }
    }
    
    // MARK: - Purchase
    
    func purchase(_ product: Product) async throws -> Transaction? {
        AppLogger.shared.log("StoreManager: calling purchase() for \(product.id)", category: .general)
        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await updatePurchasedProducts()
            // `currentEntitlements` can briefly lag a brand-new purchase — which surfaced
            // as "purchased but Pro not active" until the user hit Restore. Trust the
            // verified transaction we already hold: if it's active (not revoked, not past
            // its expiration), include its product NOW so activation is immediate.
            let isActive = transaction.revocationDate == nil
                && ((transaction.expirationDate.map { $0 > Date() }) ?? true)
            if isActive {
                purchasedProductIDs.insert(transaction.productID)
            }
            // A completed, verified purchase of ANY product is a support action — record
            // it immediately (don't wait on currentEntitlements catching up) so the support
            // prompt is suppressed from this moment on.
            markHasSupported()
            let iso = ISO8601DateFormatter()
            let exp = transaction.expirationDate.map { iso.string(from: $0) } ?? "none"
            AppLogger.shared.log(
                "StoreManager: purchase SUCCESS \(product.id) — env=\(transaction.environment.rawValue), expires=\(exp), active=\(isActive), effectiveIsPro=\(effectiveIsPro)",
                category: .general
            )
            return transaction

        case .userCancelled:
            AppLogger.shared.log("StoreManager: purchase CANCELLED for \(product.id)", category: .general)
            return nil

        case .pending:
            AppLogger.shared.log("StoreManager: purchase PENDING for \(product.id) (e.g. Ask to Buy)", category: .general)
            return nil

        @unknown default:
            AppLogger.shared.log("StoreManager: purchase UNKNOWN result for \(product.id)", category: .general)
            return nil
        }
    }
    
    func restorePurchases() async {
        try? await AppStore.sync()
        await updatePurchasedProducts()
    }
    
    // MARK: - Early Adopter Check

    /// The early-adopter cutoff baked into the build, used ONLY until/unless the server
    /// value is fetched. It's `.distantPast` so the fallback path can **never** grant —
    /// any install date is after it, so only a successful server fetch with a genuinely
    /// future cutoff can make someone an early adopter. Fully fail-closed.
    static let fallbackActivationDate: Date = .distantPast

    /// UserDefaults key for the cached "early adopter enabled" server flag.
    private static let earlyAdopterEnabledKey = "com.allarise.earlyAdopterEnabled"

    /// UserDefaults key for the last-applied grant epoch. When the server epoch exceeds
    /// this, existing grants are invalidated once (everyone re-derives from the current
    /// date) — without breaking the "a date change alone never revokes" guarantee.
    private static let grantEpochKey = "com.allarise.grantEpoch"

    /// Server-controlled activation date. Returns JSON: `{"activationDate":"<ISO8601>"}`.
    /// Hosted statically (GitHub Pages) so the launch/promo window can move without a
    /// new build. HTTPS-only; any fetch/parse failure falls back fail-closed.
    private static let activationDateURL = URL(string: "https://allarise.app/activationdate.json")!

    /// UserDefaults key caching the last successfully fetched activation date (ISO8601).
    private static let activationDateCacheKey = "com.allarise.activationDate.cache"

    /// Keychain key for a permanent early-adopter grant. Once written, the user keeps
    /// Pro forever — even across reinstalls and even if the server cutoff later moves
    /// earlier (e.g. when a launch promo ends). A grant is never revoked.
    /// `nonisolated` so the background iCloud-reconcile task can read it off the main actor.
    nonisolated private static let earlyAdopterGrantedKey = "com.allarise.earlyAdopter.granted"

    /// True if this device has a persisted permanent early-adopter grant.
    private var earlyAdopterGranted: Bool {
        KeychainHelper.shared.read(forKey: Self.earlyAdopterGrantedKey) == "true"
    }

    /// Writes the permanent early-adopter grant to Keychain, and mirrors it to iCloud
    /// KVS (off the main thread — first KVS access can block) so the lifetime grant
    /// follows the user's Apple ID to a new device.
    private func persistEarlyAdopterGrant() {
        KeychainHelper.shared.save("true", forKey: Self.earlyAdopterGrantedKey)
        Task.detached(priority: .utility) {
            let store = NSUbiquitousKeyValueStore.default
            store.set(true, forKey: Self.earlyAdopterGrantedKey)
            store.synchronize()
        }
    }

    /// Removes the permanent early-adopter grant from Keychain AND iCloud KVS. Debug-only
    /// path — used when changing the install-date override so the paywall/IAP flow can be
    /// re-tested as a non-early-adopter. Clearing KVS too prevents iCloud from immediately
    /// re-granting it via `syncEarlyAdopterWithiCloud`.
    private func clearEarlyAdopterGrant() {
        KeychainHelper.shared.delete(forKey: Self.earlyAdopterGrantedKey)
        Task.detached(priority: .utility) {
            let store = NSUbiquitousKeyValueStore.default
            store.removeObject(forKey: Self.earlyAdopterGrantedKey)
            store.synchronize()
        }
    }

    /// Like `clearEarlyAdopterGrant`, but **awaits** the iCloud KVS removal so a follow-up
    /// reconcile can't re-sync the grant back. Used by the grant-epoch invalidation.
    private func clearEarlyAdopterGrantEverywhere() async {
        KeychainHelper.shared.delete(forKey: Self.earlyAdopterGrantedKey)
        await Task.detached(priority: .utility) {
            let store = NSUbiquitousKeyValueStore.default
            store.removeObject(forKey: Self.earlyAdopterGrantedKey)
            store.synchronize()
        }.value
    }

    #if DEBUG
    /// Debug-only: wipes the permanent early-adopter grant from Keychain AND iCloud KVS,
    /// then re-derives status from the real install date vs the live cutoff. Lets you
    /// escape a sticky grant earned during prior override testing so you can exercise the
    /// non-early-adopter / paywall path. (Production never revokes a grant.)
    @MainActor
    func debugResetEarlyAdopterGrant() async {
        clearEarlyAdopterGrant()
        await checkEarlyAdopter()
        AppLogger.shared.log("DEBUG: early-adopter grant reset (Keychain + iCloud)", category: .general)
    }
    #endif

    /// Reconciles early-adopter state with iCloud Key-Value Store so a lifetime grant
    /// (and the original install date) follows the user's Apple ID to a new device —
    /// where the `ThisDeviceOnly` Keychain values don't migrate and there's no StoreKit
    /// receipt to restore. All KVS access runs off the main thread; first access to
    /// `NSUbiquitousKeyValueStore.default` can block for several seconds.
    func syncEarlyAdopterWithiCloud() async {
        await Task.detached(priority: .utility) {
            let store = NSUbiquitousKeyValueStore.default
            store.synchronize()

            // Install date — keep the EARLIEST known across this device and iCloud, and
            // push it both ways so every device converges on the true first-install date.
            let localDate = StoreManager.storedFirstInstallDate
            let kvsDate = store.string(forKey: StoreManager.firstInstallDateKey)
                .flatMap { ISO8601DateFormatter().date(from: $0) }
            if let earliest = [localDate, kvsDate].compactMap({ $0 }).min() {
                let iso = ISO8601DateFormatter().string(from: earliest)
                if earliest != localDate {
                    KeychainHelper.shared.save(iso, forKey: StoreManager.firstInstallDateKey)
                }
                if earliest != kvsDate {
                    store.set(iso, forKey: StoreManager.firstInstallDateKey)
                }
            }

            // Grant — union across this device and iCloud (a grant is lifetime and never
            // revoked, so "true anywhere" wins).
            let localGranted = KeychainHelper.shared.read(forKey: StoreManager.earlyAdopterGrantedKey) == "true"
            let kvsGranted = store.object(forKey: StoreManager.earlyAdopterGrantedKey) != nil
                && store.bool(forKey: StoreManager.earlyAdopterGrantedKey)
            if kvsGranted && !localGranted {
                KeychainHelper.shared.save("true", forKey: StoreManager.earlyAdopterGrantedKey)
            }
            if localGranted && !kvsGranted {
                store.set(true, forKey: StoreManager.earlyAdopterGrantedKey)
            }

            // Supporter flag — union across this device and iCloud, same as the grant.
            // "Has ever supported" is permanent, so true anywhere wins.
            let localSupported = KeychainHelper.shared.read(forKey: StoreManager.hasSupportedKey) == "true"
            let kvsSupported = store.object(forKey: StoreManager.hasSupportedKey) != nil
                && store.bool(forKey: StoreManager.hasSupportedKey)
            if kvsSupported && !localSupported {
                KeychainHelper.shared.save("true", forKey: StoreManager.hasSupportedKey)
            }
            if localSupported && !kvsSupported {
                store.set(true, forKey: StoreManager.hasSupportedKey)
            }
            store.synchronize()
        }.value

        // Reflect a supporter flag that synced down from another device into memory so the
        // prompt is suppressed without a relaunch.
        if KeychainHelper.shared.read(forKey: Self.hasSupportedKey) == "true" {
            hasSupported = true
        }

        // Back on the main actor: re-derive status with the reconciled inputs. If the
        // earliest install date now precedes the cutoff, checkEarlyAdopter grants and
        // re-persists (Keychain + KVS) automatically.
        await checkEarlyAdopter()
    }

    // MARK: - Activation Date Fetch

    /// JSON shape served at `activationdate.json`. `grantEpoch` and `earlyAdopterEnabled`
    /// are optional for backward compatibility (default 0 / true when absent).
    private struct ActivationDateResponse: Decodable {
        let activationDate: String
        let grantEpoch: Int?
        let earlyAdopterEnabled: Bool?
    }

    /// Resolved server config.
    private struct ActivationConfig {
        let cutoff: Date
        let grantEpoch: Int
        let enabled: Bool
    }

    /// Fetches the server config over HTTPS. Returns nil on ANY failure (network, non-2xx,
    /// malformed body, unparseable date) so callers fail closed — a missing/blocked
    /// endpoint never grants Pro, only a valid value can.
    private func fetchActivationConfig() async -> ActivationConfig? {
        var request = URLRequest(url: Self.activationDateURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                print("⚠️ Activation config fetch: non-2xx response")
                return nil
            }
            let decoded = try JSONDecoder().decode(ActivationDateResponse.self, from: data)
            guard let date = ISO8601DateFormatter().date(from: decoded.activationDate) else {
                print("⚠️ Activation config fetch: unparseable date '\(decoded.activationDate)'")
                return nil
            }
            return ActivationConfig(
                cutoff: date,
                grantEpoch: decoded.grantEpoch ?? 0,
                enabled: decoded.earlyAdopterEnabled ?? true
            )
        } catch {
            print("⚠️ Activation config fetch failed: \(error)")
            return nil
        }
    }

    /// Fetches the live activation date and, on success, updates `activationCutoff`
    /// and the UserDefaults cache. On failure leaves the current (cached or fallback)
    /// value in place — fail-closed and self-healing on a later online launch.
    @MainActor
    func refreshActivationDate() async {
        guard let config = await fetchActivationConfig() else {
            AppLogger.shared.log("Activation config fetch failed — keeping cutoff \(activationCutoff), enabled \(earlyAdopterEnabled) (fail-closed)", category: .general)
            return
        }
        activationCutoff = config.cutoff
        UserDefaults.standard.set(ISO8601DateFormatter().string(from: config.cutoff), forKey: Self.activationDateCacheKey)

        // Kill-switch.
        earlyAdopterEnabled = config.enabled
        UserDefaults.standard.set(config.enabled, forKey: Self.earlyAdopterEnabledKey)

        // Grant epoch: if the server epoch advanced past what we've applied, invalidate
        // existing grants ONCE so every device re-derives from the current date — this
        // un-grandfathers stale grants (e.g. App Review) without breaking "a date change
        // alone never revokes". Cleared from Keychain + iCloud (awaited) so the iCloud
        // reconcile that runs next can't immediately re-sync the grant back.
        let appliedEpoch = UserDefaults.standard.integer(forKey: Self.grantEpochKey)
        if config.grantEpoch > appliedEpoch {
            await clearEarlyAdopterGrantEverywhere()
            UserDefaults.standard.set(config.grantEpoch, forKey: Self.grantEpochKey)
            AppLogger.shared.log("Grant epoch advanced \(appliedEpoch) → \(config.grantEpoch) — existing grants invalidated", category: .general)
        }

        AppLogger.shared.log("Activation config refreshed: cutoff \(config.cutoff), epoch \(config.grantEpoch), enabled \(config.enabled)", category: .general)
    }

    /// Keychain key for the persisted first-install date.
    /// Keychain survives app reinstalls and updates, so this is set once and never changes.
    /// `nonisolated` so the background iCloud-reconcile task can read it off the main actor.
    nonisolated private static let firstInstallDateKey = "com.allarise.firstInstallDate"

    /// Keychain key for a debug override of the first-install date. When present, it
    /// replaces the real install date for early-adopter checks. Stored in Keychain so
    /// the override written in a Debug build persists into TestFlight/Release builds,
    /// letting you test the real IAP purchase flow as a non-early-adopter.
    fileprivate static let firstInstallDateOverrideKey = "com.allarise.firstInstallDate.override"

    /// Writes today's date to Keychain as the first install date — only if not already stored.
    /// Called synchronously in init() so it captures the true first-launch moment.
    ///
    /// Uses `isDefinitelyMissing` (errSecItemNotFound) rather than a nil read: a nil read
    /// can also mean the device was locked during a background launch, and treating that
    /// as "absent" would overwrite the real first-install date with today — corrupting
    /// early-adopter status. We only write when the item is genuinely not present.
    private static func recordFirstInstallDateIfNeeded() {
        guard KeychainHelper.shared.isDefinitelyMissing(forKey: firstInstallDateKey) else { return }
        let iso = ISO8601DateFormatter().string(from: Date())
        KeychainHelper.shared.save(iso, forKey: firstInstallDateKey)
        AppLogger.shared.log("First install date recorded: \(iso)", category: .general)
    }

    /// Returns the stored first install date from Keychain, or nil if not yet recorded.
    /// `nonisolated` so the background iCloud-reconcile task can read it off the main actor.
    nonisolated static var storedFirstInstallDate: Date? {
        guard let iso = KeychainHelper.shared.read(forKey: firstInstallDateKey) else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }

    /// Returns the install date to use for early-adopter checks. If a debug override
    /// is present in Keychain, returns that; otherwise returns the real install date.
    static var effectiveFirstInstallDate: Date? {
        if let iso = KeychainHelper.shared.read(forKey: firstInstallDateOverrideKey),
           let date = ISO8601DateFormatter().date(from: iso) {
            return date
        }
        return storedFirstInstallDate
    }

    /// Grants Pro to users whose first install date is before the early adopter cutoff.
    /// Uses Keychain (not AppTransaction) so it works reliably in TestFlight and after reinstalls.
    @MainActor
    func checkEarlyAdopter() async {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short

        // Server kill-switch: when disabled, no one is an early adopter — existing grants
        // are ignored (not deleted, so flipping back true restores them).
        guard earlyAdopterEnabled else {
            isEarlyAdopter = false
            AppLogger.shared.log("Early adopter program disabled by server flag — paywall active for all", category: .general)
            return
        }

        // A previously-earned grant is permanent and never revoked — even if the
        // server cutoff later moves earlier (e.g. when a launch promo ends).
        if earlyAdopterGranted {
            isEarlyAdopter = true
            AppLogger.shared.log("Early adopter — Pro granted (persisted permanent grant)", category: .general)
            return
        }

        guard let installDate = Self.effectiveFirstInstallDate else {
            AppLogger.shared.log("Early adopter check skipped — no first install date in Keychain", category: .general)
            return
        }

        let overrideSuffix = installDateOverrideActive ? " [DEBUG OVERRIDE ACTIVE]" : ""
        if installDate < activationCutoff {
            isEarlyAdopter = true
            persistEarlyAdopterGrant()
            AppLogger.shared.log("Early adopter — Pro granted & persisted (first install: \(fmt.string(from: installDate)), activation cutoff: \(fmt.string(from: activationCutoff)))\(overrideSuffix)", category: .general)
        } else {
            isEarlyAdopter = false
            AppLogger.shared.log("Not early adopter (first install: \(fmt.string(from: installDate)), activation cutoff: \(fmt.string(from: activationCutoff)))\(overrideSuffix)", category: .general)
        }
    }

    // MARK: - Debug Install Date Override

    /// Writes an arbitrary override install date to the Keychain. Used by the debug
    /// date picker in Settings → Testing to simulate any historical install date for
    /// default-bucket testing and IAP flow testing. Re-runs the early-adopter check
    /// so `isEarlyAdopter` updates immediately without an app restart.
    @MainActor
    func setInstallDateOverride(to date: Date) async {
        let iso = ISO8601DateFormatter().string(from: date)
        KeychainHelper.shared.save(iso, forKey: Self.firstInstallDateOverrideKey)
        installDateOverride = date
        // Clear any prior permanent grant so the override actually takes effect —
        // otherwise a granted device would stay Pro and the paywall/IAP flow couldn't
        // be re-tested as a non-early-adopter.
        clearEarlyAdopterGrant()
        AppLogger.shared.log("Install date override SET to \(date)", category: .general)
        await checkEarlyAdopter()
    }

    /// Enables the install-date override — writes `.distantFuture` to Keychain so the
    /// user appears as a non-early-adopter. Convenience wrapper around
    /// `setInstallDateOverride(to:)` preserved for the existing bool-toggle UI.
    @MainActor
    func enableInstallDateOverride() async {
        await setInstallDateOverride(to: .distantFuture)
    }

    /// Disables the install-date override — removes the Keychain key so the real
    /// first install date is used again, then re-runs the early-adopter check.
    @MainActor
    func disableInstallDateOverride() async {
        KeychainHelper.shared.delete(forKey: Self.firstInstallDateOverrideKey)
        installDateOverride = nil
        // Clear any grant earned while the override was active, then re-derive cleanly
        // from the real install date.
        clearEarlyAdopterGrant()
        AppLogger.shared.log("Install date override DISABLED (using real install date)", category: .general)
        await checkEarlyAdopter()
    }

    nonisolated func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
}

enum StoreError: Error {
    case failedVerification
}
