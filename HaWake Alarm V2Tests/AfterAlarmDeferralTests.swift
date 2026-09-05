//
//  AfterAlarmDeferralTests.swift
//  HaWake Alarm V2Tests
//
//  Cover for al-bee.1 — dismissing an alarm with another still queued used to
//  skip three things: the per-alarm MQTT `dismissed` publish, the sleep-sound
//  resume, and the whole after-alarm sequence. The first left Home Assistant
//  watching `alarm/<n>/state` on `ringing` forever; the last silently destroyed
//  notes the user had typed.
//
//  The tests that must never be "fixed" by loosening anything are the ones
//  asserting a single-alarm dismiss still behaves exactly as it always did, and
//  that a deferred sequence is never dropped.
//
//  Consolidation is covered by `AfterAlarmConsolidationTests` below: distinct
//  notes pages oldest-first, dedupe on text + command identity, one verse / one
//  weather / one app link, per-page attribution only when several alarms merge,
//  and a lone alarm reproducing its own order byte-for-byte. See
//  Documents/working-notes/PLAN-sleep-through-stack.md.
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

// MARK: - Helpers

private func contribution(
    hash: Int,
    label: String = "A",
    actions: [AfterAlarmAction] = [.weather],
    notes: String = "",
    commands: [MQTTCommand] = [],
    uri: String? = nil
) -> AfterAlarmContribution {
    AfterAlarmContribution(
        alarmHash: hash,
        alarmLabel: label,
        actions: actions,
        notes: notes,
        notesCommands: commands,
        dismissAppURI: uri
    )
}

private func command(_ name: String) -> MQTTCommand {
    MQTTCommand(name: name, icon: "bolt.fill",
                iconColorRed: 0.5, iconColorGreen: 0.5, iconColorBlue: 0.5)
}

/// The notes pages of the plan `queue` would present, in order.
private func notesPages(of queue: AfterAlarmDeferralQueue) -> [AfterAlarmNotesPage] {
    queue.consolidatedPlan().steps.compactMap { step in
        if case .notes(let page) = step { return page }
        return nil
    }
}

// MARK: - What a dismiss owes the alarm being dismissed

struct AlarmDismissResolutionTests {

    @Test("A stacked alarm still publishes its own dismissed state — al-bee.1")
    func queuedDismissStillPublishesPerAlarmState() {
        let outcome = AlarmDismissResolution.resolve(
            alarmIndex: 3,
            hasQueuedAlarms: true,
            hasAfterAlarmSteps: true
        )
        #expect(outcome.publishesPerAlarmDismissed)
    }

    // Sleep sounds moved out of this resolution in al-3jm — a dismiss stops
    // them, a snooze resumes them. See SleepSoundAlarmResolutionTests.

    @Test("An alarm with no MQTT index has no per-alarm topic to publish on")
    func unindexedAlarmPublishesNothingPerAlarm() {
        #expect(!AlarmDismissResolution.resolve(
            alarmIndex: 0, hasQueuedAlarms: false, hasAfterAlarmSteps: true
        ).publishesPerAlarmDismissed)
    }

    @Test("The global active-alarm topics are cleared only once nothing is queued")
    func globalStateClearedOnlyWhenQueueDrains() {
        #expect(!AlarmDismissResolution.resolve(
            alarmIndex: 1, hasQueuedAlarms: true, hasAfterAlarmSteps: false
        ).clearsGlobalActiveAlarm)
        #expect(AlarmDismissResolution.resolve(
            alarmIndex: 1, hasQueuedAlarms: false, hasAfterAlarmSteps: false
        ).clearsGlobalActiveAlarm)
    }

    @Test("A queued dismiss records its sequence but does not present it")
    func queuedDismissDefersTheFlow() {
        let outcome = AlarmDismissResolution.resolve(
            alarmIndex: 1, hasQueuedAlarms: true, hasAfterAlarmSteps: true
        )
        #expect(outcome.recordsAfterAlarmContribution)
        #expect(!outcome.drainsAfterAlarmFlows,
                "presenting now would paint the flow UNDER the next alarm's window — al-bee.3")
    }

    @Test("The last dismiss of a stack presents what was accumulated")
    func drainingDismissRunsTheFlows() {
        #expect(AlarmDismissResolution.resolve(
            alarmIndex: 1, hasQueuedAlarms: false, hasAfterAlarmSteps: true
        ).drainsAfterAlarmFlows)
    }

    @Test("A drained dismiss still drains owed sequences even with no steps of its own")
    func drainingDismissRunsEarlierFlowsWithNoStepsOfItsOwn() {
        let outcome = AlarmDismissResolution.resolve(
            alarmIndex: 1, hasQueuedAlarms: false, hasAfterAlarmSteps: false
        )
        #expect(!outcome.recordsAfterAlarmContribution)
        #expect(outcome.drainsAfterAlarmFlows,
                "an earlier alarm's deferred notes must not be stranded by a plain dismiss")
    }

    @Test("The reported per-alarm state stays the published `dismissed` string — al-d44")
    func stateStringIsPlainDismissed() {
        #expect(AlarmDismissResolution.perAlarmDismissState == .dismissed)
        #expect(AlarmDismissResolution.perAlarmDismissState.rawValue == "dismissed")
    }
}

// MARK: - Deferral bookkeeping

struct AfterAlarmDeferralQueueTests {

    @Test("A sequence with no steps is never queued — an empty contribution adds nothing")
    func emptyContributionIsDropped() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, actions: []))

        #expect(queue.isEmpty)
    }

    @Test("Recorded contributions survive until removeAll, so an interrupted flow is not lost")
    func recordsSurviveUntilCleared() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, label: "6:00", actions: [.notes], notes: "take the pills"))
        queue.record(contribution(hash: 2, label: "6:30"))

        // A flow was presented, then a third alarm fired and tore the window down
        // without it ever finishing. The queue was NOT cleared, so the whole flow
        // is still owed and re-presents when the stack next drains.
        #expect(queue.count == 2)
        #expect(notesPages(of: queue).first?.notes == "take the pills")

        // Only completion clears it.
        queue.removeAll()
        #expect(queue.isEmpty)
    }

    @Test("removeAll clears everything owed")
    func removeAllClears() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1))
        queue.removeAll()
        #expect(queue.isEmpty)
    }
}

// MARK: - Consolidation into a single flow

struct AfterAlarmConsolidationTests {

    // --- Single alarm: byte-for-byte today's behaviour ---

    @Test("A lone alarm's plan is its own action order, verbatim, with no attribution")
    func singleAlarmPreservesItsOwnOrder() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, actions: [.notes, .verse, .weather],
                                  notes: "a"))

        let plan = queue.consolidatedPlan()
        #expect(plan.contributorCount == 1)
        #expect(plan.steps == [
            .notes(AfterAlarmNotesPage(alarmHash: 1, notes: "a", commands: [], attribution: nil)),
            .verse,
            .weather,
        ])
        #expect(plan.appLinkURI == nil)
    }

    @Test("A lone alarm ordered verse-before-notes still runs verse first")
    func singleAlarmCustomOrderNotReordered() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, actions: [.verse, .notes], notes: "a"))

        let plan = queue.consolidatedPlan()
        #expect(plan.steps == [
            .verse,
            .notes(AfterAlarmNotesPage(alarmHash: 1, notes: "a", commands: [], attribution: nil)),
        ])
    }

    @Test("A lone alarm with only an app link fires it directly — no card, no window")
    func singleAlarmAppLinkOnly() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, actions: [.appLink], uri: "shortcuts://run/only"))

        let plan = queue.consolidatedPlan()
        #expect(plan.steps == [.appLink])
        #expect(!plan.hasCard)
        #expect(plan.appLinkURI == "shortcuts://run/only")
    }

    // --- Merge: notes pages ---

    @Test("Distinct notes pages present oldest contributor first, before the tail")
    func mergedNotesAreOldestFirst() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, label: "6:00", actions: [.notes, .weather], notes: "first"))
        queue.record(contribution(hash: 2, label: "6:15", actions: [.notes], notes: "second"))
        queue.record(contribution(hash: 3, label: "6:30", actions: [.notes], notes: "third"))

        let plan = queue.consolidatedPlan()
        #expect(plan.contributorCount == 3)
        let pages = plan.steps.compactMap { step -> String? in
            if case .notes(let page) = step { return page.notes }
            return nil
        }
        #expect(pages == ["first", "second", "third"])
        // The tail follows the notes pages.
        #expect(plan.steps.last == .weather)
    }

    @Test("No cap on notes pages — six distinct pages show six steps")
    func noNotesPageCap() {
        var queue = AfterAlarmDeferralQueue()
        for i in 1...6 {
            queue.record(contribution(hash: i, label: "\(i)", actions: [.notes], notes: "note \(i)"))
        }
        #expect(notesPages(of: queue).count == 6)
    }

    @Test("Identical notes pages dedupe to one, keeping the oldest contributor")
    func identicalNotesPagesDedupe() {
        let shared = command("Coffee")
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, label: "6:00", actions: [.notes],
                                  notes: "take the pills", commands: [shared]))
        queue.record(contribution(hash: 2, label: "6:30", actions: [.notes],
                                  notes: "take the pills", commands: [shared]))

        let pages = notesPages(of: queue)
        #expect(pages.count == 1)
        #expect(pages.first?.attribution == "6:00", "the oldest contributor's page is the one kept")
    }

    @Test("Whitespace-only differences do not defeat dedupe")
    func dedupeIgnoresSurroundingWhitespace() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, label: "6:00", actions: [.notes], notes: "hi"))
        queue.record(contribution(hash: 2, label: "6:30", actions: [.notes], notes: "  hi\n"))

        #expect(notesPages(of: queue).count == 1)
    }

    @Test("Identity includes the command buttons — same text, different commands, two pages")
    func identityIncludesCommands() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, label: "6:00", actions: [.notes],
                                  notes: "same", commands: [command("Coffee")]))
        queue.record(contribution(hash: 2, label: "6:30", actions: [.notes],
                                  notes: "same", commands: [command("Lights")]))

        #expect(notesPages(of: queue).count == 2,
                "different command sets are different pages even with identical text")
    }

    // --- Merge: verse / weather / app link ---

    @Test("Verse and weather collapse to one each across the stack")
    func verseAndWeatherCollapse() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, actions: [.verse, .weather]))
        queue.record(contribution(hash: 2, actions: [.verse, .weather]))
        queue.record(contribution(hash: 3, actions: [.verse, .weather]))

        let plan = queue.consolidatedPlan()
        #expect(plan.steps.filter { $0 == .verse }.count == 1)
        #expect(plan.steps.filter { $0 == .weather }.count == 1)
    }

    @Test("Canonical order across a merge: notes → verse → weather → app link")
    func canonicalMergeOrder() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, label: "6:00", actions: [.weather]))
        queue.record(contribution(hash: 2, label: "6:15", actions: [.notes, .verse], notes: "n"))
        queue.record(contribution(hash: 3, label: "6:30", actions: [.appLink],
                                  uri: "shortcuts://run/third"))

        let plan = queue.consolidatedPlan()
        #expect(plan.steps == [
            .notes(AfterAlarmNotesPage(alarmHash: 2, notes: "n", commands: [], attribution: "6:15")),
            .verse,
            .weather,
            .appLink,
        ])
    }

    @Test("Only the most recent app link survives a stack — one app switch, not N")
    func appLinkIsMostRecentOnly() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, actions: [.notes, .appLink], notes: "first",
                                  uri: "shortcuts://run/first"))
        queue.record(contribution(hash: 2, actions: [.weather]))
        queue.record(contribution(hash: 3, actions: [.notes, .appLink], notes: "third",
                                  uri: "shortcuts://run/third"))

        let plan = queue.consolidatedPlan()
        #expect(plan.appLinkURI == "shortcuts://run/third")
        #expect(plan.steps.filter { $0 == .appLink }.count == 1)
        #expect(plan.steps.last == .appLink, "the app link stays terminal")
    }

    @Test("An empty app-link URI does not count as a link to fire")
    func emptyURIIsNotAnAppLink() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, actions: [.notes, .appLink], notes: "a", uri: ""))
        queue.record(contribution(hash: 2, actions: [.weather]))

        let plan = queue.consolidatedPlan()
        #expect(plan.appLinkURI == nil)
        #expect(!plan.steps.contains(.appLink))
    }

    @Test("A merge of app-link-only alarms fires one link with no window")
    func mergedAppLinkOnly() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 1, actions: [.appLink], uri: "shortcuts://run/first"))
        queue.record(contribution(hash: 2, actions: [.appLink], uri: "shortcuts://run/second"))

        let plan = queue.consolidatedPlan()
        #expect(plan.steps == [.appLink])
        #expect(!plan.hasCard)
        #expect(plan.appLinkURI == "shortcuts://run/second")
    }

    // --- Attribution ---

    @Test("Per-page attribution appears only when more than one alarm merges")
    func attributionOnlyOnMerge() {
        var single = AfterAlarmDeferralQueue()
        single.record(contribution(hash: 1, label: "6:00", actions: [.notes], notes: "solo"))
        #expect(notesPages(of: single).first?.attribution == nil)

        var merged = AfterAlarmDeferralQueue()
        merged.record(contribution(hash: 1, label: "6:00", actions: [.notes], notes: "a"))
        merged.record(contribution(hash: 2, label: "6:30", actions: [.notes], notes: "b"))
        let pages = notesPages(of: merged)
        #expect(pages.map(\.attribution) == ["6:00", "6:30"])
    }

    // --- Plan shape ---

    @Test("hasCard is false for a link-only plan and true once anything paints")
    func hasCardMatrix() {
        var linkOnly = AfterAlarmDeferralQueue()
        linkOnly.record(contribution(hash: 1, actions: [.appLink], uri: "shortcuts://run"))
        #expect(!linkOnly.consolidatedPlan().hasCard)

        for action in [AfterAlarmAction.notes, .verse, .weather] {
            var q = AfterAlarmDeferralQueue()
            q.record(contribution(hash: 1, actions: [action], notes: "x"))
            #expect(q.consolidatedPlan().hasCard, "\(action) is a painting step")
        }
    }

    @Test("firstNotesPage is the first notes step the host must seed live")
    func firstNotesPageIsTheHead() {
        var queue = AfterAlarmDeferralQueue()
        queue.record(contribution(hash: 7, label: "6:00", actions: [.notes], notes: "head"))
        queue.record(contribution(hash: 8, label: "6:30", actions: [.notes], notes: "tail"))

        let plan = queue.consolidatedPlan()
        #expect(plan.firstNotesPage?.alarmHash == 7)
        #expect(plan.firstNotesPage?.notes == "head")
    }
}

// MARK: - Contribution shape

struct AfterAlarmContributionTests {

    @Test("An app-link-only sequence needs no window")
    func appLinkOnlyHasNoCard() {
        let c = contribution(hash: 1, actions: [.appLink], uri: "shortcuts://run")
        #expect(!c.isEmpty)
        #expect(!c.hasCard, "firing the link directly is the pre-existing behaviour")
    }

    @Test("Any visual step requires a hosting window")
    func cardStepsNeedAWindow() {
        #expect(contribution(hash: 1, actions: [.notes]).hasCard)
        #expect(contribution(hash: 1, actions: [.verse]).hasCard)
        #expect(contribution(hash: 1, actions: [.weather]).hasCard)
        #expect(contribution(hash: 1, actions: [.weather, .appLink]).hasCard)
    }

    @Test("No steps means nothing to present and nothing to fire")
    func noStepsIsEmpty() {
        #expect(contribution(hash: 1, actions: []).isEmpty)
    }

    @Test("The snapshot captures the alarm's sequence, notes and link at dismiss time")
    @MainActor
    func snapshotCapturesTheAlarmsOwnValues() {
        let alarm = Alarm(label: "6:00")
        alarm.alarmScreenNotes = "take the pills"
        alarm.dismissAppURI = "shortcuts://run-shortcut?name=Morning"

        let snapshot = AfterAlarmContribution.snapshot(of: alarm)

        #expect(snapshot.alarmHash == alarm.stableHash)
        #expect(snapshot.alarmLabel == "6:00")
        #expect(snapshot.notes == "take the pills")
        #expect(snapshot.dismissAppURI == "shortcuts://run-shortcut?name=Morning")
        #expect(snapshot.actions == alarm.afterAlarmActions)
        #expect(snapshot.actions.contains(.notes))
        #expect(snapshot.actions.last == .appLink, "the terminal open-app step stays last")
    }

    /// The whole point of snapshotting: an ephemeral alarm's SwiftData row is
    /// deleted while the sequence is still owed, so the captured value must not
    /// track the model afterwards.
    @Test("The snapshot does not track later edits to the alarm")
    @MainActor
    func snapshotIsAValue() {
        let alarm = Alarm(label: "6:00")
        alarm.alarmScreenNotes = "take the pills"

        let snapshot = AfterAlarmContribution.snapshot(of: alarm)
        alarm.alarmScreenNotes = ""

        #expect(snapshot.notes == "take the pills")
    }
}
