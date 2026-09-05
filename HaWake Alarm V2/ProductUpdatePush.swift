//
//  ProductUpdatePush.swift
//  HaWake Alarm V2
//
//  Firebase Cloud Messaging, used for ONE thing: occasional product-update
//  announcements to people who ticked `productUpdatesOptIn`.
//
//  ── THE SAFETY RULE THIS FILE EXISTS TO ENFORCE ──────────────────────────
//  FirebaseMessaging, by default, SWIZZLES `UNUserNotificationCenterDelegate`
//  and the AppDelegate's remote-notification methods and inserts itself in
//  front of them. In a normal app that is a convenience. In this one it would
//  put an analytics SDK's swizzle directly in the path that delivers ALARMS,
//  which is the single thing the app must never get wrong.
//
//  So `FirebaseAppDelegateProxyEnabled = NO` is REQUIRED in Info.plist, and the
//  APNs token is handed to Messaging manually below. `AppDelegate` keeps sole
//  ownership of notification handling; nothing here registers as a
//  delegate, and nothing here inspects or intercepts a notification. If a future
//  change removes that Info.plist key, Messaging silently takes the delegate
//  back — hence the startup assertion.
//  ─────────────────────────────────────────────────────────────────────────
//
//  Push is INDEPENDENT of analytics consent. Someone may want release notes and
//  no telemetry, or the reverse. The only thing the two share is
//  `FirebaseBootstrap.configureIfNeeded()`.
//
//  Note there is no separate system permission to request: alarms already
//  require notification authorization, which is granted during onboarding. This
//  toggle decides whether we are ALLOWED to use it for announcements — a
//  product-level consent, not an OS one.
//

import Foundation
import UIKit
import UserNotifications

// FirebaseCore for `FirebaseApp`, used below to tell "never configured" apart
// from "configured and opted out" — unsubscribing before configuration would
// trap.
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

@MainActor
enum ProductUpdatePush {

    /// Everyone opted in subscribes to this; broadcasts are sent to the topic
    /// rather than to collected device tokens, so no token list is ever stored.
    private static let topic = "product_updates"

    private static var registeredForRemote = false

    /// Which APNs environment the token belongs to, stated rather than inferred.
    ///
    /// Messaging normally works this out from the `aps-environment` entitlement,
    /// but that inference runs through the AppDelegate proxy we deliberately
    /// disabled (see the file header). If it guesses wrong, APNs rejects every
    /// send with BadDeviceToken and Firebase reports the campaign as delivered —
    /// a silent failure with no signal anywhere. So we tell it.
    ///
    /// The mapping is exact for this project: development builds carry
    /// `aps-environment: development` (sandbox), and Release — App Store and
    /// TestFlight alike — carries production. If that entitlement is ever
    /// changed per-configuration, this must change with it.
    #if canImport(FirebaseMessaging)
    private static var apnsTokenType: MessagingAPNSTokenType {
        #if DEBUG
        .sandbox
        #else
        .prod
        #endif
    }
    #endif

    /// An APNs token that arrived before Firebase was configured. Without this
    /// the token is simply DROPPED, and every later `Messaging.token` call fails
    /// with "No APNS token specified before fetching FCM Token" — a dead end
    /// that only a relaunch clears.
    private static var pendingAPNSToken: Data?

    /// Re-reads `productUpdatesOptIn` and reconciles. Call at launch and whenever
    /// the toggle changes.
    static func refreshConsent() {
        let wants = DeviceSettings.shared.productUpdatesOptIn
        wants ? enable() : disable()
    }

    private static func enable() {
        #if canImport(FirebaseMessaging)
        guard FirebaseBootstrap.configureIfNeeded() else { return }
        assertProxyDisabled()

        // `FirebaseMessagingAutoInitEnabled = NO` in Info.plist stops FCM from
        // minting a registration token the moment the shared Firebase app is
        // configured — which the ANALYTICS consent alone can do. Auto-init is
        // therefore turned on here and nowhere else, so a token only ever exists
        // while push consent does. The setter persists, so the toggle also takes
        // effect immediately rather than at next launch.
        Messaging.messaging().isAutoInitEnabled = true

        // APNs registration only — this does NOT prompt. Authorization was
        // already granted for alarms; this just obtains the device token.
        if !registeredForRemote {
            UIApplication.shared.registerForRemoteNotifications()
            registeredForRemote = true
        }

        // Replay a token that beat configuration.
        if let pendingAPNSToken {
            Messaging.messaging().setAPNSToken(pendingAPNSToken, type: apnsTokenType)
            Self.pendingAPNSToken = nil
            AppLogger.shared.log("Push: applied buffered APNs token (\(apnsTokenType == .sandbox ? "sandbox" : "prod"))", category: .general)
            // Falls through to subscribeToTopic() below, which can now succeed.
        }

        subscribeToTopic()
        #endif
    }

    /// Subscribing REQUIRES an APNs token — FCM has to mint a registration token
    /// first, and refuses to without one. That token arrives asynchronously from
    /// Apple, typically seconds after `enable()` runs, so the first attempt
    /// normally fails with "No APNS token specified before fetching FCM Token"
    /// and nothing is subscribed. Hence this is called TWICE: optimistically
    /// from `enable()`, and again from `setAPNSToken` once the precondition
    /// actually holds. Subscribing twice is a no-op, so the redundant call is
    /// cheaper than the race.
    private static func subscribeToTopic() {
        #if canImport(FirebaseMessaging)
        Messaging.messaging().subscribe(toTopic: topic) { error in
            if let error {
                AppLogger.shared.log("Push: subscribe to \(topic) failed — \(error.localizedDescription)", category: .general)
            } else {
                AppLogger.shared.log("Push: subscribed to \(topic)", category: .general)
            }
        }
        #endif
    }

    private static func disable() {
        #if canImport(FirebaseMessaging)
        // Only meaningful if Firebase was ever configured; otherwise there is
        // nothing subscribed to unsubscribe from.
        guard FirebaseApp.app() != nil else { return }
        // Stop FCM re-minting a token behind the withdrawal. Must come before
        // deleteToken below, or auto-init simply issues a fresh one.
        Messaging.messaging().isAutoInitEnabled = false
        Messaging.messaging().unsubscribe(fromTopic: topic) { error in
            if let error {
                AppLogger.shared.log("Push: unsubscribe from \(topic) failed — \(error.localizedDescription)", category: .general)
            } else {
                AppLogger.shared.log("Push: unsubscribed from \(topic)", category: .general)
            }
        }
        // Drops the FCM registration token, so withdrawal removes the identifier
        // rather than just stopping the sends.
        Messaging.messaging().deleteToken { _ in }
        #endif
    }

    /// The APNs token, handed over MANUALLY because the delegate proxy is off.
    /// Called from `AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken`.
    static func setAPNSToken(_ deviceToken: Data) {
        #if canImport(FirebaseMessaging)
        guard FirebaseApp.app() != nil else {
            // Hold it rather than discard it — `enable()` replays it once
            // Firebase configures.
            pendingAPNSToken = deviceToken
            AppLogger.shared.log("Push: APNs token buffered (Firebase not configured yet)", category: .general)
            return
        }
        Messaging.messaging().setAPNSToken(deviceToken, type: apnsTokenType)
        AppLogger.shared.log("Push: APNs token handed to Messaging (\(apnsTokenType == .sandbox ? "sandbox" : "prod"))", category: .general)

        // The earlier attempt from `enable()` almost certainly failed against
        // this very precondition. Retry now.
        if DeviceSettings.shared.productUpdatesOptIn {
            subscribeToTopic()
        }
        #endif
    }

    #if DEBUG
    /// Push state as a readable block, for the DEBUG row in Settings.
    ///
    /// Exists because a silent non-delivery has four indistinguishable causes —
    /// Firebase never configured, no APNs token, no FCM token, or a topic that
    /// was never subscribed. This separates them, and hands over the
    /// registration token so a single device can be targeted with Firebase's
    /// "Send test message" instead of guessing at topic fan-out.
    static func fetchDiagnostics(_ completion: @escaping (String) -> Void) {
        #if canImport(FirebaseMessaging)
        var lines: [String] = []
        let configured = FirebaseApp.app() != nil
        let optedIn = DeviceSettings.shared.productUpdatesOptIn
        let registered = UIApplication.shared.isRegisteredForRemoteNotifications
        lines.append("Firebase configured: \(configured)")
        lines.append("Opted in: \(optedIn)")
        lines.append("Registered w/ APNs: \(registered)")

        guard configured else {
            lines.append(optedIn
                ? "→ Opted in but not configured. Relaunch the app."
                : "→ Turn on Product Updates first.")
            completion(lines.joined(separator: "\n"))
            return
        }

        // Asking for the FCM token before the APNs token exists fails with
        // "No APNS token specified", which reads like a broken key but only
        // means the round trip to Apple hasn't finished. Kick registration and
        // say so, rather than reporting a failure that isn't one.
        guard Messaging.messaging().apnsToken != nil else {
            UIApplication.shared.registerForRemoteNotifications()
            lines.append("APNs token: not yet received")
            lines.append("→ Registration requested. Wait ~10s and tap again.")
            lines.append("→ Still nothing? Device must be online, and the")
            lines.append("   Push Notifications capability must be on the App ID.")
            completion(lines.joined(separator: "\n"))
            return
        }
        lines.append("APNs token: received (\(apnsTokenType == .sandbox ? "sandbox" : "prod"))")

        Messaging.messaging().token { token, error in
            if let token {
                lines.append("FCM token: \(token)")
            } else {
                lines.append("FCM token: FAILED — \(error?.localizedDescription ?? "unknown")")
            }
            Task { @MainActor in completion(lines.joined(separator: "\n")) }
        }
        #else
        completion("FirebaseMessaging not linked in this build.")
        #endif
    }
    #endif

    /// Fails loudly in DEBUG if the proxy is ever re-enabled — see the file
    /// header. A silent regression here would put Messaging in front of alarm
    /// notification delivery, and the symptom would be a missed alarm.
    private static func assertProxyDisabled() {
        let enabled = Bundle.main.object(forInfoDictionaryKey: "FirebaseAppDelegateProxyEnabled") as? Bool
        if enabled != false {
            let message = "FirebaseAppDelegateProxyEnabled must be NO — Messaging would swizzle the notification delegate that delivers alarms."
            AppLogger.shared.log("Push: \(message)", category: .general)
            assertionFailure(message)
        }
    }
}
