//
//  VerseOfDayService.swift
//  HaWake Alarm V2
//
//  Backend for the "Verse of the Day" feature. A small, self-contained service
//  that mirrors the app's existing service singletons (see HaWakeWeatherService
//  and RadioFaviconCache for idiom):
//
//    • Fetches a static JSON manifest hosted on GitHub Pages describing one verse
//      per local-calendar day, plus a portrait background image per day.
//    • Downloads ONLY the images it is missing for a rolling 7-day window
//      (today + next 6 days), plus yesterday's for the preview, straight to disk
//      via a URLSession download task — never into memory — and prunes anything
//      outside the window.
//    • Exposes today's verse as a plain value (`verseForToday()`), reading only
//      from disk/manifest with zero network, and falls back to a small bundled
//      set of public-domain (WEB) verses over a generated gradient when nothing
//      is cached for today.
//    • Exposes YESTERDAY's verse to the "Try It Out" preview (`previewVerse()`),
//      so tapping Preview Verse in the editor doesn't spoil the verse the user
//      will actually wake up to. Falls back to today's when yesterday is not in
//      the cached manifest — the preview never shows nothing.
//
//  Presentation policy is purely per-alarm: the future After-Alarm pipeline
//  decides which alarms show the card, and the user controls frequency by
//  choosing which alarms get the verse. This service owns NO suppression state —
//  it just answers `verseForToday()` (the same verse all day, from cache).
//
//  MEMORY DISCIPLINE (explicit constraint): this service NEVER decodes a UIImage.
//  It only moves downloaded files around on disk. The card view decodes at
//  display time with ImageIO downsampling sized to the screen — see
//  VerseOfDayCardView.
//
//  This file is BACKEND ONLY. Nothing here is wired into the alarm dismiss flow
//  or the editor; the only integration is an opportunistic `refreshIfNeeded()`
//  call at app launch / foregrounding.
//

import Foundation
import Observation

// MARK: - Public value type

/// A single day's verse, resolved for display. Pure value — carries a file URL
/// for the background image only when it is already cached on disk (otherwise
/// the card renders a generated gradient).
struct VerseOfDay: Identifiable, Sendable, Equatable {
    /// Local-calendar day key, "yyyy-MM-dd". Also the identity.
    let date: String
    let reference: String
    let text: String
    let translation: String
    /// A `file://` URL to the cached background image, or nil to use the
    /// generated gradient fallback.
    let imageURL: URL?
    /// True when this came from the bundled fallback set rather than the manifest.
    let isFallback: Bool

    var id: String { date }
}

/// What a "Try It Out" preview should put on screen: a verse, plus whether it is
/// yesterday's (which the card captions) or today's (the fallback, uncaptioned —
/// captioning it "Yesterday's verse" would be a lie).
struct VersePreview: Sendable, Equatable {
    let verse: VerseOfDay
    /// True when `verse` is yesterday's rather than today's.
    let isYesterday: Bool
}

// MARK: - Manifest wire models

/// Top-level manifest. Unknown keys are ignored by `Decodable` (forward compat).
nonisolated private struct VerseManifest: Decodable {
    let schemaVersion: Int
    let updated: String?
    let baseImageURL: String?
    let days: [VerseManifestDay]
}

nonisolated private struct VerseManifestDay: Decodable {
    let date: String
    let reference: String
    let text: String
    let translation: String
    let image: String?
}

// MARK: - Service

@MainActor @Observable
final class VerseOfDayService {
    static let shared = VerseOfDayService()

    /// Timestamp of the most recent *successful* refresh (for observers/UI). Not
    /// the throttle clock — that is persisted separately (see UserDefaults keys).
    private(set) var lastRefreshDate: Date?

    /// Guards against overlapping refreshes.
    private var isRefreshing = false

    private init() {}

    // MARK: Configuration

    /// Base URL of the hosted verse content — the `domoretechnet/hawake-verses`
    /// GitHub Pages site. This is the single source of truth for the URL.
    nonisolated static let contentBaseURL = URL(string: "https://domoretechnet.github.io/hawake-verses/")!

    nonisolated private static var manifestURL: URL {
        contentBaseURL.appendingPathComponent("manifest.json")
    }

    /// Highest manifest `schemaVersion` this build understands. A manifest newer
    /// than this is ignored (cache kept, update skipped) rather than mis-parsed.
    nonisolated private static let supportedSchemaVersion = 1

    /// Rolling window: today plus the next 6 days.
    nonisolated private static let windowDays = 7

    /// At most one network attempt per this interval.
    private static let refreshThrottle: TimeInterval = 6 * 60 * 60

    // MARK: UserDefaults keys

    private enum Keys {
        static let lastFetchAttempt = "verseOfDay.lastFetchAttempt"
    }

    // MARK: - Cache layout on disk
    //
    //   Caches/VerseOfDay/
    //       manifest.json          (verbatim copy of the last good manifest)
    //       images/
    //           2026-07-23.jpg      (portrait background, one per day)
    //           ...

    nonisolated private static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("VerseOfDay", isDirectory: true)
    }

    nonisolated private static var imagesDirectory: URL {
        cacheDirectory.appendingPathComponent("images", isDirectory: true)
    }

    nonisolated private static var cachedManifestURL: URL {
        cacheDirectory.appendingPathComponent("manifest.json")
    }

    // MARK: - Refresh (network)

    /// Opportunistic refresh. Safe to call on every launch / foreground: throttled
    /// to at most one network attempt per ~6h, runs off the main thread at
    /// `.utility` QoS, and fails silently when offline.
    ///
    /// - Parameter force: bypass the throttle (DEBUG harness only).
    func refreshIfNeeded(force: Bool = false) {
        guard !isRefreshing else { return }

        if !force {
            let now = Date()
            if let last = UserDefaults.standard.object(forKey: Keys.lastFetchAttempt) as? Date,
               now.timeIntervalSince(last) < Self.refreshThrottle {
                return
            }
        }

        // Record the attempt up front so a burst of foregrounding events collapses
        // to a single network hit even if this one fails.
        UserDefaults.standard.set(Date(), forKey: Keys.lastFetchAttempt)

        isRefreshing = true
        Task(priority: .utility) {
            let succeeded = await Self.performRefresh()
            await MainActor.run {
                self.isRefreshing = false
                if succeeded { self.lastRefreshDate = Date() }
            }
        }
    }

#if DEBUG
    /// DEBUG-only hard reset (Settings → Debug → "Reset Verse of the Day"):
    /// wipes the cached manifest and every cached image, clears the throttle
    /// clock, then re-fetches immediately. A plain `refreshIfNeeded(force:)`
    /// is NOT enough for "pull the new ones" — performRefresh skips any image
    /// file already on disk, so remote images replaced under the SAME filename
    /// (e.g. placeholder → real scene) would never re-download.
    func resetAndRefetch() {
        guard !isRefreshing else { return }
        try? FileManager.default.removeItem(at: Self.cachedManifestURL)
        try? FileManager.default.removeItem(at: Self.imagesDirectory)
        UserDefaults.standard.removeObject(forKey: Keys.lastFetchAttempt)
        lastRefreshDate = nil
        AppLogger.shared.log("VerseOfDay DEBUG reset: cache wiped, forcing refetch", category: .general)
        refreshIfNeeded(force: true)
    }
#endif

    /// Does the actual fetch/download/prune. Nonisolated so it runs on the
    /// cooperative pool (never the main actor) and touches only thread-safe
    /// FileManager / URLSession / UserDefaults. Returns true if the manifest was
    /// fetched and applied.
    nonisolated private static func performRefresh() async -> Bool {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        // A default session is enough: waits for connectivity, low priority.
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        // A delegate-less URLSession retains itself (and its connection pool)
        // until invalidated. All work below is awaited before this scope exits,
        // so finish + invalidate on the way out — otherwise every ~6h refresh in
        // this long-lived, deliberately-resident process would leak a session.
        defer { session.finishTasksAndInvalidate() }

        // 1. Fetch + decode the manifest.
        let manifest: VerseManifest
        let rawManifestData: Data
        do {
            var request = URLRequest(url: manifestURL)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return false
            }
            manifest = try JSONDecoder().decode(VerseManifest.self, from: data)
            rawManifestData = data
        } catch {
            // Offline / malformed — keep whatever is cached, try again after throttle.
            return false
        }

        // Reject a manifest newer than we understand: keep the cache, skip update.
        guard manifest.schemaVersion <= supportedSchemaVersion else {
            return false
        }

        // 2. Persist the manifest verbatim for `verseForToday()` to read.
        try? rawManifestData.write(to: cachedManifestURL, options: .atomic)

        // 3. Resolve the image base (manifest overrides the constant default).
        let imageBase = manifest.baseImageURL.flatMap { URL(string: $0) }
            ?? contentBaseURL.appendingPathComponent("images/", isDirectory: true)

        // 4. Download only the images we are missing for today + next 6 days
        //    (then yesterday's, in step 4b).
        let wantedKeys = Set(dateKeys(daysFromToday: 0..<windowDays))
        let byDate = Dictionary(manifest.days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })

        // Downloads one day's image if the manifest has one and it is not already
        // on disk. Returns regardless of outcome — one failure must not stop the
        // rest of the window.
        func downloadImageIfMissing(forKey key: String) async {
            guard let day = byDate[key], let imageName = day.image, !imageName.isEmpty else { return }
            let destination = imagesDirectory.appendingPathComponent(key).appendingPathExtension("jpg")
            if fileManager.fileExists(atPath: destination.path) { return }

            let remoteURL = imageBase.appendingPathComponent(imageName)
            do {
                // download(from:) streams straight to a temp file on disk — the
                // image bytes never pass through memory.
                let (tempURL, response) = try await session.download(from: remoteURL)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    try? fileManager.removeItem(at: tempURL)
                    return
                }
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: tempURL, to: destination)
            } catch {
                // Skip this image; others may still succeed.
                return
            }
        }

        for key in wantedKeys.sorted() {
            await downloadImageIfMissing(forKey: key)
        }

        // 4b. Yesterday's image, LAST. The "Try It Out" preview shows yesterday's
        // verse so it doesn't spoil today's, and the card looks like the real
        // thing only if the artwork is there. The prune window below already
        // keeps this file once it exists, so on any day the app has run before
        // this is a no-op — it costs one extra download only on a cold cache.
        // Deliberately after the loop: nothing that can actually ring today
        // should ever queue behind a day that is already over.
        if let yesterdayKey = dateKeys(daysFromToday: -1..<0).first {
            await downloadImageIfMissing(forKey: yesterdayKey)
        }

        // 5. Prune anything outside the [yesterday ... today+6] window.
        pruneImages(keeping: Set(dateKeys(daysFromToday: -1..<windowDays)))

        return true
    }

    /// Remove cached images whose day-key is not in `validKeys`.
    nonisolated private static func pruneImages(keeping validKeys: Set<String>) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: imagesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            let key = file.deletingPathExtension().lastPathComponent
            if !validKeys.contains(key) {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    // MARK: - Read (zero network)

    /// Today's verse, resolved from the cached manifest + on-disk images. Never
    /// touches the network. Falls back to a bundled public-domain verse (with a
    /// generated gradient, `imageURL == nil`) when nothing is cached for today.
    nonisolated func verseForToday(_ date: Date = Date()) -> VerseOfDay {
        let key = Self.dateKey(for: date)

        if let day = Self.cachedDay(forKey: key) {
            let imageURL = Self.imageURLIfPresent(forKey: key)
            return VerseOfDay(
                date: key,
                reference: day.reference,
                text: day.text,
                translation: day.translation,
                imageURL: imageURL,
                isFallback: false
            )
        }

        return Self.fallbackVerse(for: date, key: key)
    }

    /// Yesterday's verse, from the cached manifest + on-disk images. Zero network.
    ///
    /// Returns nil — deliberately NOT a bundled fallback — when the manifest has
    /// no entry for yesterday. A bundled fallback keyed on yesterday's date would
    /// be a *different* verse than the one the user actually saw yesterday, so
    /// there is nothing honest to caption it with; the caller shows today's
    /// instead (see `previewVerse`).
    nonisolated func verseForYesterday(relativeTo date: Date = Date()) -> VerseOfDay? {
        guard let yesterday = Self.previousDay(before: date) else { return nil }
        let key = Self.dateKey(for: yesterday)
        guard let day = Self.cachedDay(forKey: key) else { return nil }

        return VerseOfDay(
            date: key,
            reference: day.reference,
            text: day.text,
            translation: day.translation,
            imageURL: Self.imageURLIfPresent(forKey: key),
            isFallback: false
        )
    }

    /// The verse a "Try It Out" preview should show: **yesterday's** when we have
    /// it, so previewing does not spoil the verse the user will wake up to;
    /// otherwise today's, exactly as before. The preview never shows nothing.
    ///
    /// The genuine post-alarm card (`AfterAlarmFlowView`, seeded by
    /// `LocalNotificationScheduler`) keeps using `verseForToday()` — only the
    /// preview looks backwards.
    nonisolated func previewVerse(relativeTo date: Date = Date()) -> VersePreview {
        Self.previewSelection(
            today: verseForToday(date),
            yesterday: verseForYesterday(relativeTo: date)
        )
    }

    /// The preview's selection rule, as a pure function of the two candidates —
    /// no disk, no clock — so it can be tested in isolation.
    nonisolated static func previewSelection(today: VerseOfDay, yesterday: VerseOfDay?) -> VersePreview {
        if let yesterday {
            return VersePreview(verse: yesterday, isYesterday: true)
        }
        return VersePreview(verse: today, isYesterday: false)
    }

    /// Reads and decodes the cached manifest, returning the entry for `key` if any.
    nonisolated private static func cachedDay(forKey key: String) -> VerseManifestDay? {
        guard let data = try? Data(contentsOf: cachedManifestURL),
              let manifest = try? JSONDecoder().decode(VerseManifest.self, from: data),
              manifest.schemaVersion <= supportedSchemaVersion else {
            return nil
        }
        return manifest.days.first { $0.date == key }
    }

    nonisolated private static func imageURLIfPresent(forKey key: String) -> URL? {
        let url = imagesDirectory.appendingPathComponent(key).appendingPathExtension("jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Date helpers

    /// Formatter for "yyyy-MM-dd" keyed on the *user's local* calendar/timezone.
    /// POSIX locale keeps the numeric format stable regardless of device locale.
    nonisolated private static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    nonisolated static func dateKey(for date: Date) -> String {
        keyFormatter.string(from: date)
    }

    /// Start of the local day *before* `date`. Calendar arithmetic, not
    /// `-86_400` — a DST spring-forward day is 23 hours long, and subtracting a
    /// flat day there lands back inside today. `calendar` is injectable so the
    /// rule can be tested against fixed time zones.
    nonisolated static func previousDay(before date: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date))
    }

    /// Local-calendar day keys for an offset range relative to today, e.g.
    /// `0..<7` → today + next 6 days; `-1..<7` → yesterday + today + next 6.
    nonisolated private static func dateKeys(daysFromToday range: Range<Int>) -> [String] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        return range.compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: startOfToday).map { dateKey(for: $0) }
        }
    }

    // MARK: - Bundled fallback (public-domain WEB verses, no image assets)

    private struct FallbackVerse {
        let reference: String
        let text: String
    }

    /// A small rotation of World English Bible (public-domain) verses. Rendered
    /// over a generated gradient by the card — deliberately NO bundled image
    /// assets, to keep the binary small.
    nonisolated private static let fallbackVerses: [FallbackVerse] = [
        FallbackVerse(reference: "Philippians 4:13",
                      text: "I can do all things through Christ, who strengthens me."),
        FallbackVerse(reference: "Isaiah 40:31",
                      text: "But those who wait for Yahweh will renew their strength. They will mount up with wings like eagles. They will run, and not be weary. They will walk, and not faint."),
        FallbackVerse(reference: "Joshua 1:9",
                      text: "Haven't I commanded you? Be strong and courageous. Don't be afraid, neither be dismayed, for Yahweh your God is with you wherever you go."),
        FallbackVerse(reference: "Psalm 46:1",
                      text: "God is our refuge and strength, a very present help in trouble."),
        FallbackVerse(reference: "Proverbs 3:5",
                      text: "Trust in Yahweh with all your heart, and don't lean on your own understanding."),
        FallbackVerse(reference: "Matthew 11:28",
                      text: "Come to me, all you who labor and are heavily burdened, and I will give you rest."),
        FallbackVerse(reference: "Lamentations 3:22-23",
                      text: "It is because of Yahweh's loving kindnesses that we are not consumed, because his compassion doesn't fail. They are new every morning. Great is your faithfulness."),
    ]

    /// Deterministically pick a fallback verse by day-of-year so the same day
    /// always shows the same verse.
    nonisolated private static func fallbackVerse(for date: Date, key: String) -> VerseOfDay {
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1
        let verse = fallbackVerses[(dayOfYear - 1 + fallbackVerses.count) % fallbackVerses.count]
        return VerseOfDay(
            date: key,
            reference: verse.reference,
            text: verse.text,
            translation: "WEB",
            imageURL: nil,
            isFallback: true
        )
    }
}
