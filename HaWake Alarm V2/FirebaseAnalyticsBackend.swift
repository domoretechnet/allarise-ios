//
//  FirebaseAnalyticsBackend.swift
//  HaWake Alarm V2
//
//  The Firebase implementation of `AnalyticsBackend`, and the ONLY file in the
//  app that knows Firebase exists. Nothing else imports it — swapping providers
//  or removing analytics entirely is a one-file change.
//
//  COMPILES WITH OR WITHOUT THE SDK. Every Firebase call is behind
//  `#if canImport(FirebaseCore)`, so:
//    • an open-source checkout with no Firebase package builds and runs, with
//      this backend simply doing nothing
//    • adding the package later ACTIVATES it with no code change
//  The app's launch wiring is unconditional for the same reason — see
//  `HaWake_Alarm_V2App`.
//
//  CONSENT ORDERING IS THE POINT. `FirebaseApp.configure()` is deliberately NOT
//  called at launch. In the EU consent must precede collection, so configuration
//  happens inside `start()`, which `Analytics` only calls once `analyticsOptIn`
//  is true. The Info.plist keys listed below are the belt to this braces: even
//  if something configures Firebase early, collection stays off until asked.
//
//  REQUIRED Info.plist keys (see Documents note in the setup checklist):
//      FIREBASE_ANALYTICS_COLLECTION_ENABLED                       = NO
//      FirebaseCrashlyticsCollectionEnabled                        = NO
//      FirebaseAppDelegateProxyEnabled                             = NO
//      FirebaseMessagingAutoInitEnabled                            = NO
//      GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS   = NO
//      GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED                    = NO
//
//  `FirebaseMessagingAutoInitEnabled` is the same idea for push: configuring the
//  shared app for ANALYTICS must not let FCM mint a registration token for
//  someone who declined product updates. `ProductUpdatePush` flips it per consent.
//
//  The ad/IDFV keys keep this out of App Tracking Transparency territory: with no
//  ad personalisation and no IDFV, none of it is "tracking" as ATT defines it,
//  so no tracking prompt is required.
//

import Foundation

#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseAnalytics)
import FirebaseAnalytics
#endif
#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif

// MARK: - Shared configuration

/// `FirebaseApp.configure()` is process-wide and must run exactly once, but TWO
/// independent consents can require it: analytics, and product-update push.
/// Someone may accept push and refuse analytics — configuring must therefore be
/// separable from collecting, which is what this type exists to express.
enum FirebaseBootstrap {
    private static var configured = false

    /// Idempotent. Safe to call from either consent path.
    @discardableResult
    static func configureIfNeeded() -> Bool {
        #if canImport(FirebaseCore)
        guard !configured else { return true }
        // A missing GoogleService-Info.plist would otherwise be a hard crash at
        // launch for anyone building a fork without one.
        guard FirebaseApp.app() != nil || Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            AppLogger.shared.log("Firebase: no GoogleService-Info.plist — analytics and push stay disabled", category: .general)
            return false
        }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        configured = true
        // Whichever consent got us here, if it was not ANALYTICS then any crash
        // report queued during an earlier consented run must go now. Analytics'
        // own launch path can't do this — it runs before push configures the app.
        #if canImport(FirebaseCrashlytics)
        if !UserDefaults.standard.bool(forKey: "analyticsOptIn") {
            Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)
            Crashlytics.crashlytics().deleteUnsentReports()
        }
        #endif
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Backend

final class FirebaseAnalyticsBackend: AnalyticsBackend {

    func start() {
        #if canImport(FirebaseAnalytics)
        guard FirebaseBootstrap.configureIfNeeded() else { return }
        FirebaseAnalytics.Analytics.setAnalyticsCollectionEnabled(true)
        #if canImport(FirebaseCrashlytics)
        // Crashlytics rides the same consent: a crash report is diagnostic data
        // about a person's device, so it is not exempt from the opt-in.
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        #endif
        AppLogger.shared.log("Analytics: Firebase collection enabled (user opted in)", category: .general)
        #endif
    }

    func stopAndPurge() {
        #if canImport(FirebaseAnalytics)
        FirebaseAnalytics.Analytics.setAnalyticsCollectionEnabled(false)
        // Withdrawal has to UNDO, not merely stop (GDPR Art. 7). `resetAnalyticsData`
        // clears the app-instance ID and the data held against it — without this,
        // opting out would leave the previously-collected profile intact.
        FirebaseAnalytics.Analytics.resetAnalyticsData()
        #if canImport(FirebaseCrashlytics)
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)
        // Turning collection off only stops FUTURE uploads. A crash captured
        // while consent existed is already queued on disk and would upload the
        // next time collection is re-enabled — withdrawal has to delete it.
        Crashlytics.crashlytics().deleteUnsentReports()
        #endif
        AppLogger.shared.log("Analytics: Firebase collection disabled and data reset (user opted out)", category: .general)
        #endif
    }

    /// Called at launch when consent is absent, so a report queued during an
    /// earlier consented run cannot survive as a pending upload. Only meaningful
    /// once something else (product-update push) has configured Firebase;
    /// touching Crashlytics before configuration would trap.
    func discardUnsentDiagnostics() {
        #if canImport(FirebaseCrashlytics)
        guard FirebaseApp.app() != nil else { return }
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)
        Crashlytics.crashlytics().deleteUnsentReports()
        #endif
    }

    func log(name: String, parameters: [String: Any]) {
        #if canImport(FirebaseAnalytics)
        FirebaseAnalytics.Analytics.logEvent(name, parameters: parameters.isEmpty ? nil : parameters)
        #endif
    }

    func setUserProperty(_ value: String?, forName name: String) {
        #if canImport(FirebaseAnalytics)
        FirebaseAnalytics.Analytics.setUserProperty(value, forName: name)
        #endif
    }
}
