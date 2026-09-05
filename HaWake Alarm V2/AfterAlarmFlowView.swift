//
//  AfterAlarmFlowView.swift
//  HaWake Alarm V2
//
//  The post-dismiss "after-alarm" pipeline host. Once the alarm stack has
//  drained (all missions complete — never on snooze, no alarm left ringing),
//  `AlarmWindowManager` presents this view in its own UIWindow and steps through
//  the CONSOLIDATED flow that `AfterAlarmDeferralQueue.consolidatedPlan()` built:
//
//      notes page(s)  →  verse card  →  weather card  →  app link (terminal)
//
//  A stack of one is just its own alarm's `afterAlarmActions` in order, so the
//  single-alarm flow is unchanged. When several alarms were slept through, the
//  plan is the merge — every distinct notes page (oldest contributor first), then
//  ONE verse, ONE weather and ONE app link. Multiple notes pages therefore run as
//  separate full-page steps, each with its own Continue, before the shared tail:
//  notes from alarm 1 → Continue → notes from alarm 2 → Continue → … → verse → …
//
//  This view is purely a SEQUENCER. It owns no presentation chrome of its own:
//  each visual step renders the exact same card the app already shipped
//  (`NotesAfterAlarmView`, `VerseOfDayCardView`, `GoodMorningWeatherView`),
//  full-screen, so a legacy weather-only alarm ([.weather]) is pixel-identical to
//  the old Good Morning card — the flow just happens to be the thing hosting it.
//  The terminal `.appLink` step has no UI; reaching it fires `onFinished`, which
//  the host uses to open the app link and tear the window down.
//
//  Invariants (guaranteed by the plan): `.appLink`, if present, is always last.
//  An empty plan never reaches here — the host skips presentation entirely,
//  matching today's no-weather dismiss.
//

import SwiftUI

struct AfterAlarmFlowView: View {
    /// Ordered steps to run. `.appLink` (if present) is always last. Each
    /// `.notes` step carries its own resolved page (text, buttons, attribution).
    let steps: [AfterAlarmFlowStep]
    /// Today's verse, resolved by the host once (zero-network disk read).
    let verse: VerseOfDay
    /// Wallpaper for the notes/weather cards, loaded once by the host exactly as
    /// the old weather-card path did (same key, same appearance).
    let wallpaper: UIImage?
    let wallpaperIsDark: Bool
    /// When true a Notes step reads `AfterAlarmNotesLive.shared` so Home
    /// Assistant can update the page while it is on screen. The runtime host sets
    /// this; previews and the editor's mock flow leave it false and render the
    /// static page content passed in each step.
    var liveNotes: Bool = false

    /// Fires just before a Notes step (other than the first, which the host has
    /// already seeded) is shown, so the live-notes store can re-key to that page's
    /// alarm and an MQTT write still lands on the right one. Re-seeding happens
    /// before the index change re-renders, so a merged page never flashes the
    /// previous page's content.
    var onNotesPageWillShow: (AfterAlarmNotesPage) -> Void = { _ in }
    /// Fires just as the weather card is about to appear — the host publishes
    /// the "awake" / day-started HA state here, matching the moment the old
    /// weather card published it (so app-link-only and verse-only flows, which
    /// never show weather, never publish "awake" — identical to before).
    var onWeatherWillAppear: () -> Void = {}
    /// Fires exactly once when the sequence reaches its terminal step (the
    /// app link, or simply the end). The host opens the app link and tears the
    /// hosting window down.
    var onFinished: () -> Void = {}

    /// Index into `steps` of the step currently on screen. Advances across card
    /// steps; the terminal app-link step is handled by `finish()`.
    @State private var index = 0
    @State private var finished = false

    var body: some View {
        ZStack {
            if index < steps.count {
                view(for: steps[index])
            } else {
                // Nothing left to show — terminal.
                Color.clear.onAppear(perform: finish)
            }
        }
        // Lifecycle only: the flow is presented once, and `index` changes once
        // per step. Nothing here runs per body pass.
        .onAppear {
            Analytics.shared.log(.afterAlarmShown(stepCount: steps.count))
            logStepViewed(at: index)
        }
        .onChange(of: index) { _, newIndex in
            logStepViewed(at: newIndex)
        }
    }

    /// Reports the step now on screen. The analytics vocabulary is deliberately
    /// its own enum (stable wire names), so map rather than reuse the raw value.
    private func logStepViewed(at index: Int) {
        guard index < steps.count else { return }
        let step: AfterAlarmStep
        switch steps[index] {
        case .notes:   step = .notes
        case .verse:   step = .verse
        case .weather: step = .weather
        case .appLink: step = .appLink
        }
        Analytics.shared.log(.afterAlarmStepViewed(step: step))
    }

    @ViewBuilder
    private func view(for step: AfterAlarmFlowStep) -> some View {
        switch step {
        case .notes(let page):
            // Text and buttons come from the live store rather than the captured
            // page, so an MQTT `notes` / `append_notes` write lands on the page
            // while the user is still reading it. The store is seeded to THIS
            // page's alarm (by the host for the first page, by `advance()` for the
            // rest), so a flow with no MQTT activity renders identically either way.
            NotesAfterAlarmView(
                notes: liveNotes ? AfterAlarmNotesLive.shared.notes : page.notes,
                commands: liveNotes ? AfterAlarmNotesLive.shared.commands : page.commands,
                attribution: page.attribution,
                wallpaper: wallpaper,
                onContinue: advance
            )
        case .verse:
            VerseOfDayCardView(verse: verse, onContinue: advance)
        case .weather:
            GoodMorningWeatherView(
                onDismiss: advance,
                wallpaperImage: wallpaper,
                wallpaperIsDark: wallpaperIsDark
            )
            .onAppear(perform: onWeatherWillAppear)
        case .appLink:
            // Terminal step has no UI. Defensive: `advance()` normally jumps
            // straight to `finish()` before ever landing here, but if it is the
            // first/only step we still finish cleanly (and the once-guard
            // keeps the app link firing exactly once).
            Color.clear.onAppear(perform: finish)
        }
    }

    /// Advance past the current card. If the next step is the terminal app link
    /// (which has no UI) or past the end, finish; otherwise show the next card,
    /// re-seeding the live-notes store first when that card is another notes page.
    private func advance() {
        let next = index + 1
        guard next < steps.count, steps[next] != .appLink else {
            finish()
            return
        }
        if case .notes(let page) = steps[next] { onNotesPageWillShow(page) }
        index = next
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinished()
    }
}
