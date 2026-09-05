//
//  AfterAlarmDeferral.swift
//  HaWake Alarm V2
//
//  What a dismiss owes the alarm being dismissed, and where an after-alarm
//  sequence waits when the user is still working through a stack of alarms.
//
//  Background (al-bee.1). `dismissAlarm` used to do three things ONLY when the
//  alarm queue happened to be empty: publish the per-alarm `dismissed` state,
//  resume sleep sounds, and run the after-alarm sequence. So whenever a second
//  alarm was stacked behind the one being dismissed, Home Assistant saw that
//  alarm stuck on `ringing` forever and its notes / verse / weather / app link
//  were silently discarded — the "silent no-op" failure CLAUDE.md calls the
//  worst this project can have.
//
//  The publish and the sleep-sound handling are now unconditional (and since
//  al-ecf that handling always stops the sound — see SleepSoundAlarmResolution).
//  The SEQUENCE
//  cannot simply run in the queued branch: its window sits BELOW the alarm
//  window (`.alert` vs `.alert + 1`), so it would paint underneath the next
//  ringing alarm — the stale-window bug fixed in al-bee.3. Instead each
//  dismissed alarm's sequence is recorded here and the accumulated set runs at
//  the dismissal that finally finds the queue empty.
//
//  Consolidation lives here now (al-bee, "After-alarm consolidation" in
//  `Documents/working-notes/PLAN-sleep-through-stack.md`). Rather than replay one
//  full sequence per contributing alarm — which showed the verse and weather
//  cards N times — the banked contributions collapse into a SINGLE flow:
//
//    distinct notes pages (oldest contributor first) → verse → weather → app link
//
//  Notes pages are the only per-alarm content the user authored, so every DISTINCT
//  one survives (no cap — the user typed them, they want to see them). Identical
//  pages dedupe on identity = trimmed text + the ordered command-UUID list, hashed
//  with `AlertIdentity.stableHash` (FNV-1a, launch-stable — never `Swift.Hasher`,
//  which is per-process seeded). Verse and weather collapse to one each (verse is
//  a byte-identical per-day read; weather is not idempotent — each card is a fresh
//  CoreLocation + WeatherKit call that republishes `user_state=awake`). The app
//  link is one-shot and terminal: the most recent contributor that set one.
//
//  A stack of ONE is byte-for-byte today's single-alarm flow: its own action
//  order is preserved verbatim (a lone alarm the user ordered verse-before-notes
//  must still run verse first), and no attribution is shown. The canonical
//  notes-first reorder applies ONLY when more than one alarm merges.
//
//  Pure and value-typed on purpose, following the `RingingGuardResolution` /
//  `AlarmOverrideResolution` / `MissionConsolidationResolution` precedent, so the
//  ordering, dedupe and "what runs regardless of the queue" matrix are
//  unit-testable without a window, a broker or a ModelContainer.
//

import Foundation

// MARK: - One alarm's contribution

/// One dismissed alarm's after-alarm sequence, captured at that alarm's OWN
/// dismiss.
///
/// Snapshotted, never re-read later. An ephemeral alarm deletes its SwiftData
/// row when the `AlarmDismissed` notification is handled, so reading its
/// properties at the end of the stack is a crash, not a blank page — the same
/// hazard `AfterAlarmNotesLive` documents.
struct AfterAlarmContribution: Equatable {
    /// `Alarm.stableHash` of the contributing alarm. Keys the live-notes store
    /// so a Home Assistant `notes` write lands on the right page.
    let alarmHash: Int
    /// For logging only — the row it came from may be gone by the time this runs.
    let alarmLabel: String
    /// Resolved once, at dismiss. `.appLink` (when present) is already last.
    let actions: [AfterAlarmAction]
    let notes: String
    let notesCommands: [MQTTCommand]
    let dismissAppURI: String?

    init(
        alarmHash: Int,
        alarmLabel: String,
        actions: [AfterAlarmAction],
        notes: String = "",
        notesCommands: [MQTTCommand] = [],
        dismissAppURI: String? = nil
    ) {
        self.alarmHash = alarmHash
        self.alarmLabel = alarmLabel
        self.actions = actions
        self.notes = notes
        self.notesCommands = notesCommands
        self.dismissAppURI = dismissAppURI
    }

    /// Nothing to present and nothing to fire — today's plain dismiss.
    var isEmpty: Bool { actions.isEmpty }

    /// True when at least one step paints, i.e. a hosting window is needed.
    /// An app-link-only sequence fires the link directly, with no window,
    /// exactly as the old app-link-only dismiss path did.
    var hasCard: Bool {
        actions.contains(.notes) || actions.contains(.verse) || actions.contains(.weather)
    }

    /// True when this sequence would leave Allarise for another app.
    var opensAnotherApp: Bool {
        actions.contains(.appLink) && !(dismissAppURI ?? "").isEmpty
    }
}

extension AfterAlarmContribution {
    /// Capture an alarm's after-alarm sequence at the moment it is dismissed.
    ///
    /// Everything is resolved here and nothing is re-read later: the actions, the
    /// notes text, the command slots (UUID → `MQTTCommand`, missing/deleted
    /// commands drop out) and the terminal app link.
    @MainActor
    static func snapshot(of alarm: Alarm) -> AfterAlarmContribution {
        let commands = alarm.alarmScreenCommandIDs.compactMap { idString -> MQTTCommand? in
            guard let uuid = UUID(uuidString: idString) else { return nil }
            return DeviceSettings.shared.mqttCommands.first { $0.id == uuid }
        }
        return AfterAlarmContribution(
            alarmHash: alarm.stableHash,
            alarmLabel: alarm.label,
            actions: alarm.afterAlarmActions,
            notes: alarm.alarmScreenNotes,
            notesCommands: commands,
            dismissAppURI: alarm.dismissAppURI
        )
    }
}

// MARK: - Consolidated flow plan

/// One DISTINCT notes page in the consolidated after-alarm flow.
///
/// Snapshotted content, resolved at the contributing alarm's own dismiss. The
/// live-notes store re-keys to `alarmHash` as this page is shown, so a Home
/// Assistant `notes` write still lands on the right page even inside a merge.
struct AfterAlarmNotesPage: Equatable {
    /// `Alarm.stableHash` of the alarm this page came from — re-seeds
    /// `AfterAlarmNotesLive` as the page is presented so MQTT writes still land.
    let alarmHash: Int
    let notes: String
    let commands: [MQTTCommand]
    /// The source alarm's label, shown as a per-page caption. nil when a single
    /// alarm's flow runs (nothing to disambiguate); set only when a merge means
    /// the user is looking at pages from more than one alarm.
    let attribution: String?

    /// Launch-stable identity for dedupe: trimmed text + the ordered command-UUID
    /// list. FNV-1a via `AlertIdentity.stableHash`, never `Swift.Hasher` (its seed
    /// changes every launch). Attribution is deliberately NOT part of identity —
    /// two alarms carrying the same page collapse to one, keeping the oldest.
    var identity: Int {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandIDs = commands.map(\.id.uuidString).joined(separator: "\u{1F}")
        return AlertIdentity.stableHash(trimmed + "\u{1F}" + commandIDs)
    }
}

/// One step of the consolidated flow, in presentation order. `.appLink` is the
/// terminal, UI-less step and is always last when present.
enum AfterAlarmFlowStep: Equatable {
    case notes(AfterAlarmNotesPage)
    case verse
    case weather
    case appLink
}

/// The single flow that runs when the alarm stack has drained — the merge of
/// every banked contribution. Built by `AfterAlarmDeferralQueue.consolidatedPlan()`.
struct AfterAlarmFlowPlan: Equatable {
    /// Ordered steps. For a lone alarm this is its own `afterAlarmActions` order
    /// verbatim; for a merge it is canonical (notes pages → verse → weather →
    /// app link).
    var steps: [AfterAlarmFlowStep]
    /// The one terminal app link to fire, if any — the most recent contributor
    /// that set one. Held separately so an app-link-only plan (no cards) can fire
    /// it with no window, exactly as the old app-link-only dismiss path did.
    var appLinkURI: String?
    /// How many alarms merged into this plan. 1 == today's single-alarm flow, and
    /// is what suppresses per-page attribution.
    var contributorCount: Int

    /// Nothing to present and nothing to fire.
    var isEmpty: Bool { steps.isEmpty }

    /// A hosting window is needed only when at least one step paints.
    var hasCard: Bool {
        steps.contains {
            switch $0 {
            case .notes, .verse, .weather: return true
            case .appLink:                 return false
            }
        }
    }

    /// The first notes page in presentation order — the one the host seeds into
    /// `AfterAlarmNotesLive` before presenting so page one never flashes stale.
    var firstNotesPage: AfterAlarmNotesPage? {
        for step in steps {
            if case .notes(let page) = step { return page }
        }
        return nil
    }
}

// MARK: - The deferral queue

/// Bookkeeping for after-alarm sequences waiting for the alarm stack to drain,
/// oldest contributor first. Recording appends; `consolidatedPlan()` merges the
/// accumulated set into the single flow that runs once nothing is left ringing.
///
/// The queue is cleared only when that flow completes, never when it is torn down
/// mid-cards (another alarm firing): an interrupted flow must still be owed to the
/// user, so it re-presents in full when the stack next drains.
struct AfterAlarmDeferralQueue: Equatable {
    private(set) var pending: [AfterAlarmContribution] = []

    init() {}

    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }

    /// Record a dismissed alarm's sequence. Contributions with no steps are
    /// dropped rather than queued — an empty contribution would add nothing to the
    /// merge.
    mutating func record(_ contribution: AfterAlarmContribution) {
        guard !contribution.isEmpty else { return }
        pending.append(contribution)
    }

    mutating func removeAll() {
        pending.removeAll()
    }

    /// Merge the accumulated contributions into the single flow to present now.
    ///
    /// Run at drain time, when no further contributions can arrive. See the file
    /// header for the per-step rules; the short version:
    ///
    ///  * **One alarm** — its own `afterAlarmActions` order, verbatim, no
    ///    attribution. Byte-for-byte today's single-alarm flow.
    ///  * **A merge** — canonical order: every DISTINCT notes page (oldest first,
    ///    deduped on `AfterAlarmNotesPage.identity`, no cap) → verse (once) →
    ///    weather (once) → the most recent app link (once, terminal). Each notes
    ///    page carries its source alarm's label as attribution.
    func consolidatedPlan() -> AfterAlarmFlowPlan {
        let contributors = pending          // oldest first
        let count = contributors.count

        // The terminal app link is the most recent contributor that set one — the
        // same rule the per-contributor collapse used, now expressed directly.
        let appLinkURI = contributors.last(where: { $0.opensAnotherApp })?.dismissAppURI

        // SINGLE contributor: preserve its own action order exactly. A lone alarm
        // the user ordered verse-before-notes must still run verse first, so the
        // canonical notes-first reorder below applies ONLY to a merge.
        if count == 1, let only = contributors.first {
            let steps: [AfterAlarmFlowStep] = only.actions.map { action in
                switch action {
                case .notes:
                    return .notes(AfterAlarmNotesPage(
                        alarmHash: only.alarmHash,
                        notes: only.notes,
                        commands: only.notesCommands,
                        attribution: nil
                    ))
                case .verse:   return .verse
                case .weather: return .weather
                case .appLink: return .appLink
                }
            }
            return AfterAlarmFlowPlan(steps: steps, appLinkURI: appLinkURI, contributorCount: 1)
        }

        // MERGE: distinct notes pages (oldest first) → verse → weather → app link.
        var pages: [AfterAlarmNotesPage] = []
        var seen = Set<Int>()
        for contribution in contributors where contribution.actions.contains(.notes) {
            let page = AfterAlarmNotesPage(
                alarmHash: contribution.alarmHash,
                notes: contribution.notes,
                commands: contribution.notesCommands,
                attribution: contribution.alarmLabel
            )
            guard seen.insert(page.identity).inserted else { continue }  // dedupe, keep oldest
            pages.append(page)
        }

        var steps: [AfterAlarmFlowStep] = pages.map { .notes($0) }
        if contributors.contains(where: { $0.actions.contains(.verse) })   { steps.append(.verse) }
        if contributors.contains(where: { $0.actions.contains(.weather) }) { steps.append(.weather) }
        if appLinkURI != nil { steps.append(.appLink) }

        return AfterAlarmFlowPlan(steps: steps, appLinkURI: appLinkURI, contributorCount: count)
    }
}

// MARK: - What a dismiss owes the dismissed alarm

/// The side effects a dismiss must perform, split by whether they belong to the
/// alarm being dismissed (unconditional) or to the device's global "an alarm is
/// active" state (only meaningful once nothing is left ringing).
///
/// Sleep sounds are *not* here: an alarm always stops them and they stay stopped
/// however the ring ends, a decision that lives in `SleepSoundAlarmResolution`
/// (al-ecf, superseding al-3jm).
enum AlarmDismissResolution {

    struct Outcome: Equatable {
        /// Publish `dismissed` on this alarm's own `alarm/<index>/state`.
        /// Unconditional for an indexed alarm — al-bee.1. Index 0 means the
        /// alarm was never assigned an MQTT id, so it has no topic.
        var publishesPerAlarmDismissed: Bool
        /// Clear the device-wide active-alarm topics and publish the global
        /// `dismissed`. Only when nothing is queued — a queued alarm is about to
        /// become the active alarm, and clearing would flap the entity.
        var clearsGlobalActiveAlarm: Bool
        /// Add this alarm's after-alarm sequence to the deferral queue.
        var recordsAfterAlarmContribution: Bool
        /// Present the accumulated after-alarm sequences now. Only when the
        /// stack has drained, so no flow paints under a ringing alarm.
        var drainsAfterAlarmFlows: Bool
    }

    static func resolve(
        alarmIndex: Int,
        hasQueuedAlarms: Bool,
        hasAfterAlarmSteps: Bool
    ) -> Outcome {
        Outcome(
            publishesPerAlarmDismissed: alarmIndex > 0,
            clearsGlobalActiveAlarm: !hasQueuedAlarms,
            recordsAfterAlarmContribution: hasAfterAlarmSteps,
            drainsAfterAlarmFlows: !hasQueuedAlarms
        )
    }

    /// The per-alarm state a dismissed alarm reports. Plain `dismissed`, never a
    /// new string: every existing automation with `to: "dismissed"` would
    /// silently miss anything else (the al-d44 failure).
    static let perAlarmDismissState: AlarmState = .dismissed
}
