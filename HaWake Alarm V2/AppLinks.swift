//
//  AppLinks.swift
//  HaWake Alarm V2
//
//  Every link out to the Allarise website, in one place.
//
//  ┌───────────────────────────────────────────────────────────────────────┐
//  │  ⚠️  SHIP BLOCKER — PINNED TO THE BETA SITE                            │
//  │                                                                       │
//  │  Every build, including Release and App Store, currently opens        │
//  │  beta.allarise.app. Before the next PRODUCTION submission, flip       │
//  │  `pinnedHost` back to `nil` so App Store builds resolve to            │
//  │  allarise.app again — and only once the public site actually carries  │
//  │  the updated documents.                                              │
//  │                                                                       │
//  │  Tracked in Documents/TODO-BEFORE-PROD.md.                            │
//  └───────────────────────────────────────────────────────────────────────┘
//
//  WHY THIS EXISTS. The beta and the release build document different apps. The
//  TestFlight build ships features the App Store build doesn't, and — more to the
//  point — its Terms of Use and Privacy Policy differ from the public ones. When
//  `DeviceSettings.currentTermsVersion` is bumped the app blocks the user until
//  they agree, so the document that "Terms of Use" opens on that screen MUST be
//  the one they are being asked to agree to. Pointing a beta tester at the public
//  terms while demanding agreement to the beta terms is not consent to anything.
//
//  WHY PINNED RATHER THAN BUILD-CONDITIONAL. The conditional below is correct and
//  is kept intact, but it resolves TestFlight via the sandbox receipt, and a
//  receipt is not always present the first time a freshly installed TestFlight
//  build launches. A user who hit that window would be asked to agree to terms
//  while being shown the *public* document — the exact failure this file exists
//  to prevent. The beta is the only channel shipping right now, so the safe
//  resolution is to pin, and to make un-pinning a checklist item rather than an
//  inference. The pin is one line; the reasoning it protects is not.
//
//  DELIBERATELY NOT ROUTED: `activationdate.json`. That drives the early-adopter
//  Pro cutoff (`StoreManager`), not documentation, and pointing TestFlight at a
//  second copy would let the two sites disagree about who gets free Pro. It stays
//  hardcoded to allarise.app on purpose.
//

import Foundation

enum AppLinks {

    /// Set to force one host for every build. `nil` restores the normal
    /// beta-vs-release routing below. See the ship-blocker banner above.
    private static let pinnedHost: String? = nil

    /// True for local builds and TestFlight, false for App Store builds.
    ///
    /// `appStoreReceiptURL` is soft-deprecated in favour of `AppTransaction`,
    /// which is async and would leave the first render guessing; it still
    /// resolves correctly, and the one warning it costs is worth a synchronous
    /// answer. If it is ever removed, cache `AppTransaction.shared`'s
    /// `environment` at launch rather than resolving it per access.
    static let isBetaBuild: Bool = {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()

    /// What the links actually resolve to. Reported in the DEBUG Settings row so
    /// the pin is visible on-device rather than only in source.
    static var host: String {
        pinnedHost ?? (isBetaBuild ? "beta.allarise.app" : "allarise.app")
    }

    /// True when `host` is overriding what the build would otherwise choose —
    /// i.e. a Release build being sent to the beta site. Surfaced in Settings.
    static var isPinnedAwayFromBuildDefault: Bool {
        guard let pinnedHost else { return false }
        return pinnedHost != (isBetaBuild ? "beta.allarise.app" : "allarise.app")
    }

    private static func page(_ name: String) -> URL {
        // Force-unwrapped: the components are compile-time constants, so a failure
        // here is a typo in this file and nothing else.
        URL(string: "https://\(host)/\(name)")!
    }

    static var terms: URL { page("terms.html") }
    static var privacy: URL { page("privacy.html") }
    static var faq: URL { page("faq.html") }
    static var mqttBuilder: URL { page("mqtt-builder.html") }
    /// Release notes. Opened when a product-update push is tapped — see
    /// `WhatsNewStore`. Also the fallback when a campaign carries no URL of its
    /// own, so a notification sent without the custom key still lands somewhere.
    static var whatsNew: URL { page("whatsnew.html") }

    /// The App Store product page for Allarise (`id6760920796`). Used by the "share the
    /// app" flow. Not host-routed — both beta and release point at the same public
    /// listing, since that's where a shared link should always send a new user.
    static var appStore: URL { URL(string: "https://apps.apple.com/app/id6760920796")! }

    /// Whether a URL is one of ours, and therefore safe to open in-app.
    ///
    /// The push payload that drives `WhatsNewStore` arrives from a server. Even
    /// though that server is our own Firebase project, an app that opens whatever
    /// URL a remote message names is one compromised console away from being a
    /// phishing delivery mechanism — the notification carries our name and icon,
    /// so the page it opens inherits the user's trust in the app. Restricting to
    /// hosts we publish costs nothing and removes the whole class of problem.
    ///
    /// Both hosts are accepted regardless of which one this build links to, so a
    /// campaign is not silently broken by the beta pin.
    static func isAllarisePage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased() else { return false }
        return host == "allarise.app" || host == "beta.allarise.app"
    }

    /// For Markdown link syntax in `Text(...)`, which needs the string form.
    static var termsString: String { terms.absoluteString }
    static var privacyString: String { privacy.absoluteString }
}
