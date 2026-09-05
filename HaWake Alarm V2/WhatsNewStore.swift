//
//  WhatsNewStore.swift
//  HaWake Alarm V2
//
//  What happens when a product-update push is TAPPED.
//
//  THE PROBLEM THIS SOLVES. iOS collapses a notification banner to about two
//  lines. The full body is there — APNs allows ~4 KB and expanding the banner
//  shows all of it — but only if the user knows to pull it down, and tapping it
//  used to do nothing at all: the notification fell through every category branch
//  in `AppDelegate.userNotificationCenter(_:didReceive:)` and the app opened to
//  the alarm list with the announcement discarded.
//
//  So a tap now opens the release notes as a web page, in an in-app Safari view.
//  Deliberately a web page rather than native UI: the notes can then be as long
//  and as formatted as they need to be, and writing a new release's notes is
//  publishing a page rather than shipping an app update.
//
//  ── WHERE THE URL COMES FROM, AND WHY IT IS CHECKED ──────────────────────
//  A campaign may carry `whats_new_url` in its custom data. If it does not — or
//  if what it carries is not one of our pages — the tap falls back to
//  `AppLinks.whatsNew`. So a notification sent without the custom key still does
//  something sensible, which matters because that key is easy to forget in the
//  Firebase console.
//
//  The URL is validated against `AppLinks.isAllarisePage` before it is opened.
//  It arrives from a server, and a notification wearing this app's name and icon
//  lends its credibility to whatever page it opens. See that function for the
//  reasoning; the short version is that an app which opens any URL a remote
//  message names is a phishing vector waiting for a bad day.
//  ─────────────────────────────────────────────────────────────────────────
//
//  This is NOT gated on a separate consent. Receiving the notification at all
//  already required `productUpdatesOptIn`; reading the message you were sent is
//  the same act, not a new one. Nothing here reports back — no open tracking, no
//  analytics event — so it stays clear of the analytics toggle entirely.
//
//  ── THE BANNER ───────────────────────────────────────────────────────────
//  A notification is a single moment: miss it, swipe it away, glance at it on a
//  locked screen and forget, and the announcement is gone. So an arriving
//  announcement also raises a banner at the top of the alarm list, which stays
//  until whichever comes first:
//
//    • the user taps it        (they read it — `openAndDismiss`)
//    • the user dismisses it   (they chose not to — the ✕)
//    • 24 hours pass           (`Self.lifetime`, from when it was FIRST SEEN)
//
//  Both dismissals are recorded by announcement ID, so re-launching the app or
//  receiving the same campaign twice does not bring a dead banner back. The
//  24-hour clock starts when the announcement is first ingested, NOT at each
//  launch — otherwise an app opened daily would show the same banner forever.
//
//  HOW AN ANNOUNCEMENT IS NOTICED. `didReceive` only fires on a tap, so a
//  notification that was never tapped would never reach this store. Instead the
//  app also scans `getDeliveredNotifications()` on activation: anything still
//  sitting in Notification Center is picked up without needing a tap, background
//  execution, or a `content-available` payload.
//  ─────────────────────────────────────────────────────────────────────────
//

import CryptoKit
import Foundation
import SafariServices
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class WhatsNewStore {
    static let shared = WhatsNewStore()

    /// Set when an announcement should be opened; the root view presents it in a
    /// Safari sheet and clears it. Non-nil means "show this now".
    var pendingURL: URL?

    /// The announcement currently worth showing as a banner, or nil. Already
    /// filtered for dismissal and expiry — the view can render it unconditionally.
    var banner: Announcement? {
        // Consent first. Reading `productUpdatesOptIn` here also makes the banner
        // observe it, so switching the toggle off removes the banner immediately
        // rather than at the next launch.
        guard DeviceSettings.shared.productUpdatesOptIn else { return nil }
        guard let stored, !dismissedIDs.contains(stored.id) else { return nil }
        guard Date().timeIntervalSince(stored.firstSeen) < Self.lifetime else { return nil }
        return stored
    }

    /// How long a banner survives if the user neither taps nor dismisses it.
    static let lifetime: TimeInterval = 24 * 60 * 60

    // MARK: - Payload keys
    //
    // All optional. A campaign with none of them still works: the tap falls back
    // to `AppLinks.whatsNew` and the banner borrows the notification's own title
    // and body. That matters because these are easy to forget in the console.
    private static let urlKey = "whats_new_url"
    private static let summaryKey = "whats_new_summary"
    private static let idKey = "whats_new_id"

    // MARK: - Persistence

    private static let storedKey = "whatsNewAnnouncement"
    private static let dismissedKey = "whatsNewDismissedIDs"
    /// Bounded so a long-lived install cannot grow this without limit. Oldest
    /// first, and 20 is far more announcements than could plausibly be live.
    private static let maxDismissed = 20

    struct Announcement: Codable, Identifiable, Equatable {
        let id: String
        let title: String
        let summary: String
        let urlString: String
        let firstSeen: Date

        var url: URL { URL(string: urlString) ?? AppLinks.whatsNew }
    }

    // Persistence is written EXPLICITLY by `persist()` rather than from a `didSet`
    // on these properties. `@Observable` rewrites stored properties into computed
    // ones, and layering a property observer on that is a subtlety this file does
    // not need to depend on — an explicit call at each mutation site is two extra
    // lines and leaves nothing to reason about.
    private var stored: Announcement?
    private var dismissedIDs: [String]

    private init() {
        dismissedIDs = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        if let data = UserDefaults.standard.data(forKey: Self.storedKey) {
            stored = try? JSONDecoder().decode(Announcement.self, from: data)
        }
    }

    private func persist() {
        if let stored, let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storedKey)
        }
        UserDefaults.standard.set(dismissedIDs, forKey: Self.dismissedKey)
    }

    /// Records a dismissal, bounded. Shared by the ✕, by a tap, and by expiry —
    /// all three must make the announcement stay gone.
    private func markDismissed(_ id: String) {
        if !dismissedIDs.contains(id) {
            dismissedIDs.append(id)
            if dismissedIDs.count > Self.maxDismissed {
                dismissedIDs.removeFirst(dismissedIDs.count - Self.maxDismissed)
            }
        }
    }

    // MARK: - Ingest

    /// Records an announcement so the banner can show it. Safe to call repeatedly
    /// with the same notification — the ID keeps it from resetting its own clock
    /// or resurrecting itself after a dismissal.
    func ingest(userInfo: [AnyHashable: Any], title: String, body: String) {
        // An opted-out user should not be receiving these at all, but the
        // activation scan reads Notification Center, which can still hold
        // announcements delivered before they switched the toggle off.
        guard DeviceSettings.shared.productUpdatesOptIn else { return }
        let id = announcementID(userInfo: userInfo, title: title, body: body)
        guard !dismissedIDs.contains(id) else { return }
        // Already tracking this one: leave `firstSeen` alone, or the 24-hour
        // window restarts every time the app opens.
        guard stored?.id != id else { return }

        let summary = (userInfo[Self.summaryKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        stored = Announcement(
            id: id,
            title: title.isEmpty ? "What's New" : title,
            summary: (summary?.isEmpty == false ? summary! : body),
            urlString: destination(from: userInfo).absoluteString,
            firstSeen: Date()
        )
        persist()
        AppLogger.shared.log("What's New: announcement banner armed (id: \(id))", category: .notification)
    }

    /// Re-reads `productUpdatesOptIn` and reconciles. Call from BOTH toggle sites
    /// — Settings and the data-preferences prompt.
    ///
    /// The `banner` guard already hides it, but hiding is not undoing. This app
    /// holds withdrawal to a higher bar everywhere else — analytics purges what it
    /// gathered, push deletes its registration token — and a stored announcement
    /// that merely stops rendering would come back the moment the toggle was
    /// flipped on again, which is not what "stop showing me product updates"
    /// means. Retiring it properly also stops the activation scan re-arming it
    /// from a notification still sitting in Notification Center.
    func refreshConsent() {
        guard !DeviceSettings.shared.productUpdatesOptIn, stored != nil else { return }
        AppLogger.shared.log("What's New: announcement retired — product updates switched off", category: .notification)
        dismiss()
    }

    /// Drops an announcement that has outlived `lifetime`.
    ///
    /// `banner` already filters on expiry, but that is a computed check: nothing
    /// re-renders merely because time passed, and this app deliberately stays
    /// resident overnight, so a session open for more than a day would keep
    /// showing a banner that should have gone. Clearing the stored value is an
    /// observable change, so calling this on activation makes the deadline real.
    func pruneExpired() {
        guard let stored else { return }
        guard Date().timeIntervalSince(stored.firstSeen) >= Self.lifetime else { return }
        AppLogger.shared.log("What's New: announcement expired after 24h (id: \(stored.id))", category: .notification)
        // Recorded as dismissed, not just cleared — otherwise the next
        // delivered-notification scan would find it still sitting in Notification
        // Center and raise it again with a fresh 24-hour clock.
        dismiss()
    }

    /// Pulls anything already sitting in Notification Center. Called on activation,
    /// so an announcement that was delivered while the app was closed — and never
    /// tapped — still raises the banner.
    func ingestDeliveredNotifications() {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            // ONLY the newest. Ingesting every delivered push in a loop looks
            // harmless and is not: with two announcements sitting in Notification
            // Center, each pass armed one then the other, so `stored` alternated
            // and `firstSeen` was rewritten on every activation — the 24-hour
            // deadline could never be reached. One announcement is on screen at a
            // time, so only the latest one is a candidate.
            guard let newest = notifications
                .filter({ $0.request.trigger is UNPushNotificationTrigger })
                .max(by: { $0.date < $1.date })
            else { return }
            let content = newest.request.content
            Task { @MainActor in
                self.ingest(userInfo: content.userInfo, title: content.title, body: content.body)
            }
        }
    }

    /// Stable identity for an announcement. Prefers an explicit `whats_new_id`;
    /// otherwise derives one from the content, so the same campaign seen twice is
    /// recognised as the same thing and a dismissal sticks.
    ///
    /// The content fallback hashes with SHA-256 and NOT `String.hashValue`.
    /// Swift seeds its hasher randomly per process, so `hashValue` gave the same
    /// announcement a different id on every launch — `dismissedIDs` could never
    /// match, and any product-update push still sitting in Notification Center
    /// re-armed the banner every single time the app started. That is why the
    /// banner came back after each install.
    private func announcementID(userInfo: [AnyHashable: Any], title: String, body: String) -> String {
        if let explicit = (userInfo[Self.idKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        let digest = SHA256.hash(data: Data("\(title)|\(body)".utf8))
        return "auto-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Actions

    /// Tapped the banner: open the page and retire it.
    func openAndDismiss() {
        guard let banner else { return }
        pendingURL = banner.url
        dismiss()
    }

    /// Dismissed without reading, or retired after being read.
    func dismiss() {
        guard let stored else { return }
        markDismissed(stored.id)
        self.stored = nil
        persist()
    }

    /// Called from the notification tap handler. Opens the page immediately, and
    /// retires the banner — a tap IS reading it, so it must not then appear in
    /// the app as though it were unread.
    @discardableResult
    func handleTap(userInfo: [AnyHashable: Any], title: String = "", body: String = "") -> Bool {
        let id = announcementID(userInfo: userInfo, title: title, body: body)
        markDismissed(id)
        if stored?.id == id { stored = nil }
        persist()
        pendingURL = destination(from: userInfo)
        return true
    }

    /// The campaign's URL when it has a usable one, ours otherwise. Kept separate
    /// so the fallback logic is readable on its own.
    func destination(from userInfo: [AnyHashable: Any]) -> URL {
        guard let raw = userInfo[Self.urlKey] as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return AppLinks.whatsNew
        }
        guard AppLinks.isAllarisePage(url) else {
            // Loud, because the alternative is a campaign that silently sends
            // everyone to the generic page and nobody knowing why.
            AppLogger.shared.log(
                "What's New: ignoring off-site \(Self.urlKey) (host: \(url.host() ?? "none")) — falling back",
                category: .notification
            )
            return AppLinks.whatsNew
        }
        return url
    }
}

// MARK: - Presentation

/// In-app Safari, matching the pattern already used by onboarding and the NWS
/// disclaimer. Kept file-private for the same reason those are: it is three lines
/// and a shared version would only add a file to import.
private struct WhatsNewSafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

extension View {
    /// Presents release notes when a product-update push is tapped. Attach once,
    /// at the app's root.
    func whatsNewSheet() -> some View {
        modifier(WhatsNewSheetModifier())
    }
}

private struct WhatsNewSheetModifier: ViewModifier {
    @State private var store = WhatsNewStore.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .sheet(item: $store.pendingURL) { url in
                WhatsNewSafariView(url: url)
                    .ignoresSafeArea()
            }
            // On activation rather than `onAppear`: an announcement can arrive
            // while the app sits in the background, and the root view does not
            // appear again when it returns.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                // Consent, then expiry, then ingest. Order matters: an announcement
                // that should be gone must be retired and RECORDED before the scan
                // can find the same notification still in Notification Center and
                // re-arm it with a fresh clock.
                store.refreshConsent()
                store.pruneExpired()
                store.ingestDeliveredNotifications()
            }
            .task {
                store.refreshConsent()
                store.pruneExpired()
                store.ingestDeliveredNotifications()
            }
    }
}

// MARK: - Banner

/// Sits at the top of the alarm list. Styled after `BackgroundRefreshBanner` so
/// the two read as the same kind of object, but in the accent colour rather than
/// orange — this is news, not a warning, and the warning banners must keep their
/// visual monopoly on "something is wrong".
struct WhatsNewBanner: View {
    @State private var store = WhatsNewStore.shared
    private let settings = DeviceSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let announcement = store.banner {
            HStack(spacing: 12) {
                Button {
                    store.openAndDismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.white)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(announcement.title)
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Text(announcement.summary)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            // Explicit call to action rather than a bare chevron.
                            // The summary is deliberately short, so without this
                            // there is nothing telling the user that more exists —
                            // a chevron alone reads as "expands", not "opens the
                            // full release notes".
                            HStack(spacing: 3) {
                                Text("Read the full list of improvements")
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.top, 3)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Separate hit target: dismissing without reading has to be
                // possible, or a banner that outstays its welcome has no exit
                // except waiting a day.
                Button {
                    store.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(settings.appAccent(for: colorScheme).opacity(0.9))
            )
            .padding(.horizontal)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
