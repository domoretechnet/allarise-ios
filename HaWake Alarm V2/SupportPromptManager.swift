//
//  SupportPromptManager.swift
//  HaWake Alarm V2
//
//  Drives the periodic "support the project" prompt in the free model.
//
//  The app is free and fully unlocked. This tracks how many DISTINCT days the user has
//  actually opened the app (foreground/active — not background wake-ups), and surfaces a
//  gentle support prompt once that count crosses a threshold. The prompt is never shown to
//  a supporter (anyone who has ever tipped/purchased, or a complimentary early adopter).
//
//  Cadence, measured in active-use days so a light user isn't rushed. The prompt is shown
//  at MOST 3 times, at fixed active-day marks, then never again:
//    • prompt 1 at 30 active days
//    • prompt 2 at 45 active days
//    • prompt 3 at 125 active days
//    • after the 3rd prompt   → never again
//    • any support/tip        → never again (StoreManager.hasSupported ⇒ isSupporter)
//  Both "Not Now" and a completed share simply advance to the next scheduled prompt; a
//  contribution stops the schedule permanently.
//
//  State is persisted in UserDefaults and mirrored to iCloud KVS so a reinstall or a new
//  device doesn't reset someone to day zero. Pure resolution logic lives in
//  `SupportPromptResolution` (below) so the cadence is unit-testable without any storage.
//

import Foundation
import Observation

/// Pure, storage-free resolution of the support-prompt cadence. Kept separate from
/// `SupportPromptManager` so both the "should we prompt?" decision and the schedule
/// arithmetic can be exercised in tests with no UserDefaults/iCloud/Keychain.
enum SupportPromptResolution {
    /// Absolute active-use-day marks at which each prompt is shown — prompt 1 at day 30,
    /// prompt 2 at day 45, prompt 3 at day 125. The array length is also the HARD CAP on
    /// how many times the prompt is ever shown; after the last mark it never appears again.
    static let promptThresholds = [30, 45, 125]

    /// Hard cap on how many times the prompt is ever shown.
    static var maxPrompts: Int { promptThresholds.count }

    /// The active-day mark at which the prompt numbered `promptCount` (0-based: the 1st
    /// prompt is index 0) is due, or nil once every prompt has been shown (the cap).
    static func threshold(forPromptCount promptCount: Int) -> Int? {
        guard promptCount >= 0, promptCount < promptThresholds.count else { return nil }
        return promptThresholds[promptCount]
    }

    /// Whether the prompt is due: not a supporter, still under the cap, and the active-day
    /// count has reached the mark for the next unseen prompt.
    static func shouldPrompt(isSupporter: Bool, activeDayCount: Int, promptCount: Int) -> Bool {
        guard !isSupporter else { return false }
        guard let threshold = threshold(forPromptCount: promptCount) else { return false }
        return activeDayCount >= threshold
    }
}

@MainActor
@Observable
final class SupportPromptManager {
    static let shared = SupportPromptManager()

    // MARK: - Persistence keys (UserDefaults + iCloud KVS, same key names)

    // `nonisolated` so the off-main-actor iCloud-KVS mirror task can read them.
    nonisolated private static let activeDayCountKey   = "com.allarise.support.activeDayCount"
    nonisolated private static let lastCreditedDayKey  = "com.allarise.support.lastCreditedDay"
    nonisolated private static let promptCountKey      = "com.allarise.support.promptCount"

    // MARK: - State

    /// Distinct days the app has been opened to the foreground.
    private(set) var activeDayCount: Int
    /// How many times the prompt has already been shown (and acted on). Once this reaches
    /// `SupportPromptResolution.maxPrompts`, the prompt is never shown again.
    private(set) var promptCount: Int

    /// The active-day mark at which the next prompt is due, or nil once the cap is reached.
    /// Derived from `promptCount` — the schedule is fixed, so nothing to persist here.
    var nextPromptThreshold: Int? {
        SupportPromptResolution.threshold(forPromptCount: promptCount)
    }
    /// The last calendar day (yyyy-MM-dd, user's local calendar) already credited, so a day
    /// is counted at most once no matter how many times the app is foregrounded that day.
    private var lastCreditedDay: String

    /// Day formatter in the user's current calendar/timezone. `yyyy-MM-dd` sorts
    /// lexicographically in chronological order, which the iCloud reconcile relies on.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        let defaults = UserDefaults.standard
        activeDayCount = defaults.integer(forKey: Self.activeDayCountKey)
        promptCount = defaults.integer(forKey: Self.promptCountKey)
        lastCreditedDay = defaults.string(forKey: Self.lastCreditedDayKey) ?? ""

        reconcileWithiCloud()
    }

    // MARK: - Queries

    /// True when the support prompt is due: not a supporter, under the prompt cap, and
    /// enough active-use days have accrued. Reads live supporter status from `StoreManager`.
    var shouldPrompt: Bool {
        SupportPromptResolution.shouldPrompt(
            isSupporter: StoreManager.shared.isSupporter,
            activeDayCount: activeDayCount,
            promptCount: promptCount
        )
    }

    // MARK: - Recording

    /// Credit one active-use day if today hasn't already been counted. Call when the app
    /// becomes active (foreground). Cheap and idempotent per calendar day.
    func recordActiveDayIfNeeded() {
        let today = Self.dayFormatter.string(from: Date())
        guard today != lastCreditedDay else { return }
        lastCreditedDay = today
        activeDayCount += 1
        persist()
        let next = nextPromptThreshold.map(String.init) ?? "—"
        AppLogger.shared.log("Support prompt: active day \(activeDayCount) (\(today)); shown \(promptCount)/\(SupportPromptResolution.maxPrompts); next at \(next)", category: .general)
    }

    // MARK: - Prompt outcomes

    /// User tapped "Not Now" (or swiped away) — advance to the next scheduled prompt.
    func handleDismissed() {
        advanceAfterPrompt(reason: "dismissed")
    }

    /// User completed a share — advance to the next scheduled prompt, same as a dismiss.
    func handleShared() {
        advanceAfterPrompt(reason: "shared")
    }

    // No `handleSupported()` is needed: buying anything sets `StoreManager.hasSupported`,
    // which makes `isSupporter` true, which makes `shouldPrompt` permanently false.

    /// Counts the just-shown prompt and moves the threshold to the next gap, or leaves the
    /// schedule at the cap (where `shouldPrompt` stays false forever).
    private func advanceAfterPrompt(reason: String) {
        promptCount += 1
        if let next = nextPromptThreshold {
            AppLogger.shared.log("Support prompt \(reason) — shown \(promptCount)/\(SupportPromptResolution.maxPrompts); next at \(next) active days", category: .general)
        } else {
            AppLogger.shared.log("Support prompt \(reason) — reached cap of \(SupportPromptResolution.maxPrompts); no further prompts", category: .general)
        }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(activeDayCount, forKey: Self.activeDayCountKey)
        defaults.set(lastCreditedDay, forKey: Self.lastCreditedDayKey)
        defaults.set(promptCount, forKey: Self.promptCountKey)

        // Mirror to iCloud KVS off the main thread — first access can block briefly.
        let count = activeDayCount, day = lastCreditedDay, shown = promptCount
        Task.detached(priority: .utility) {
            let store = NSUbiquitousKeyValueStore.default
            store.set(count, forKey: Self.activeDayCountKey)
            store.set(day, forKey: Self.lastCreditedDayKey)
            store.set(shown, forKey: Self.promptCountKey)
            store.synchronize()
        }
    }

    /// Merge in any state that synced from another device. Everything takes the max — more
    /// active days seen anywhere, further along the prompt schedule, and more prompts
    /// already shown all win, which is the "least-naggy state wins" rule and keeps the cap
    /// honoured across devices. The credited day takes the later (lexicographically greater)
    /// yyyy-MM-dd string.
    private func reconcileWithiCloud() {
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()

        let kvsCount = Int(store.longLong(forKey: Self.activeDayCountKey))
        let kvsPromptCount = Int(store.longLong(forKey: Self.promptCountKey))
        let kvsDay = store.string(forKey: Self.lastCreditedDayKey) ?? ""

        var changed = false
        if kvsCount > activeDayCount { activeDayCount = kvsCount; changed = true }
        if kvsPromptCount > promptCount { promptCount = kvsPromptCount; changed = true }
        if kvsDay > lastCreditedDay { lastCreditedDay = kvsDay; changed = true }

        if changed { persist() }
    }

    #if DEBUG
    /// Debug-only: reset the counter, schedule, and prompt count so the flow can be re-tested.
    func debugReset() {
        activeDayCount = 0
        promptCount = 0
        lastCreditedDay = ""
        persist()
    }

    /// Debug-only: make the prompt immediately due (still suppressed for supporters and
    /// once the cap is reached). No-op at the cap, where there's no next threshold.
    func debugForceDue() {
        if let threshold = nextPromptThreshold {
            activeDayCount = threshold
            persist()
        }
    }
    #endif
}
