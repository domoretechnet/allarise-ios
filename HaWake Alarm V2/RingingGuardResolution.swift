//
//  RingingGuardResolution.swift
//  HaWake Alarm V2
//
//  Two decisions that the AlarmKit ringing-guard machinery makes on every tick
//  and every .alerting transition, pulled out of `AlarmKitScheduler` so they can
//  be tested without an AlarmKit session, a window, or a run loop.
//
//  Both existed inline and both were keyed on ONE piece of state — the global
//  `activeRingingAlarmID` — which is correct only while a single alarm is
//  involved. The 2026-08-05 dual-alarm incident (al-anx) is what happens when
//  two are:
//
//    06:25  alarm 1 fires, becomes the active ringing alarm, guard rolls.
//    06:30  alarm 2 fires while alarm 1 is still on screen. It is QUEUED, but
//           it also sets itself as the active ringing alarm.
//    +0s    alarm 1's roll tick sees activeRingingAlarmID != alarm 1 and STOPS
//           rolling — leaving alarm 1's guard armed at its last rolled time.
//    +6s    that guard reaches .alerting over the live session. The duplicate
//           guard did not catch it (currentlyRinging was alarm 2, and alarm 1
//           had rung via the timer path so handlingAlarmHash was nil), so the
//           whole fire path re-ran for alarm 1: it stopped the stream alarm 2
//           had just started, and the guard's own system alert interrupted the
//           audio session.
//
//  So the rule in both cases is the same: an alarm is still "live" when it is
//  the active ringing alarm, when it is the alarm on SCREEN, or (for the roller)
//  when it is waiting in the alarm queue. Losing the global ringing flag to a
//  second alarm must not disarm the first alarm's watchdog, and must not let
//  that watchdog fire over a session it no longer owns.
//
//  Reliability bias, deliberately asymmetric between the two:
//
//    • Guard rolling errs toward KEEPING the guard alive. Rolling one extra
//      cycle costs a cancel+reschedule; stopping one cycle early costs a
//      spurious full-volume system alert, or — if the process dies — no
//      watchdog at all. Every dismiss/snooze path still calls
//      `cancelRingingGuard`, which stops the roller explicitly, so this
//      belt-and-braces condition can never roll forever on its own.
//
//    • Duplicate suppression errs toward LETTING IT RING. Suppression is
//      silence, and silence is the one failure this app cannot have. It
//      therefore requires positive evidence that the alarm is already being
//      handled audibly — never identity alone.
//

import Foundation

enum RingingGuardResolution {

    // MARK: - Roll tick

    /// Whether the rolling ringing guard for `rolledAlarmID` should keep rolling.
    ///
    /// - Parameters:
    ///   - rolledAlarmID: the alarm hash this roller was started for.
    ///   - activeRingingAlarmID: `PendingAlarmStore.activeRingingAlarmID()` — the
    ///     GLOBAL ringing flag, which a second alarm firing takes over.
    ///   - showingAlarmID: `AlarmWindowManager.currentAlarmID` — the alarm whose
    ///     window is actually on screen.
    ///   - queuedAlarmIDs: alarms waiting behind the showing one. A queued alarm
    ///     is going to ring, so its guard must stay armed for the force-kill case.
    static func shouldKeepRolling(
        rolledAlarmID: Int,
        activeRingingAlarmID: Int?,
        showingAlarmID: Int?,
        queuedAlarmIDs: Set<Int>
    ) -> Bool {
        if activeRingingAlarmID == rolledAlarmID { return true }
        if showingAlarmID == rolledAlarmID { return true }
        if queuedAlarmIDs.contains(rolledAlarmID) { return true }
        return false
    }

    // MARK: - Duplicate .alerting suppression

    /// Whether an AlarmKit `.alerting` transition for `alarmHash` is a duplicate
    /// of a ring this process is already handling, and should be stopped instead
    /// of re-running the fire path.
    ///
    /// - Parameters:
    ///   - alarmHash: the alarm hash the alerting AlarmKit alarm maps to.
    ///   - handlingAlarmHash: set synchronously at the top of the fire path;
    ///     catches rapid-fire duplicates before any async UI work has completed.
    ///   - activeRingingAlarmID: the global ringing flag.
    ///   - showingAlarmID: the alarm whose window is on screen. The al-anx case:
    ///     the global flag has moved on to a second alarm, but THIS alarm is the
    ///     one the user is looking at, so its guard has nothing to rescue.
    ///   - isShowingAlarm: an alarm window exists at all.
    ///   - isAudioPlaying: the alarm player is producing audio.
    ///   - isFadeActive: a fade ramp is armed or running. Covers the window where
    ///     the player volume is ramping but `isPlaying` momentarily reads false
    ///     (audio-session reconfigure on foreground) — without it, re-entry would
    ///     re-run the whole fade from silence.
    static func isDuplicateAlerting(
        alarmHash: Int,
        handlingAlarmHash: Int?,
        activeRingingAlarmID: Int?,
        showingAlarmID: Int?,
        isShowingAlarm: Bool,
        isAudioPlaying: Bool,
        isFadeActive: Bool
    ) -> Bool {
        // Synchronous latch — no audio evidence needed, the fire path for this
        // exact hash is mid-flight in this very process.
        if handlingAlarmHash == alarmHash { return true }

        // The pre-existing rule: this hash owns the global ringing flag AND
        // something audible is already happening for the ring.
        if activeRingingAlarmID == alarmHash,
           isShowingAlarm || isAudioPlaying || isFadeActive {
            return true
        }

        // al-0j7: this hash is the alarm currently ON SCREEN. The window is the
        // fire path's own product — it only exists because this alarm already
        // rang — so a late guard for it can only do damage (restart the tone,
        // tear down another alarm's radio stream, interrupt the session).
        //
        // Keyed strictly on window identity: a nil `showingAlarmID`, or one
        // belonging to a different alarm, is NOT evidence and falls through to
        // ringing.
        if showingAlarmID == alarmHash, isShowingAlarm { return true }

        return false
    }
}
