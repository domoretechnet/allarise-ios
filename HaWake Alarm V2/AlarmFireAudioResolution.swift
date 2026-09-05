//
//  AlarmFireAudioResolution.swift
//  HaWake Alarm V2
//
//  One decision, asked at every fire site: does THIS fire own the audio, or is
//  it about to be queued behind an alarm the user is already looking at?
//
//  `AlarmWindowManager.showAlarm` has always answered that question — a second
//  alarm firing while one is on screen is appended to the FIFO `alarmQueue` and
//  presented after the first is dismissed — but it answered it *invisibly*, with
//  an early `return` the caller could not see. So the fire path kept going and
//  ran the whole audio pipeline for an alarm that is not on screen and will not
//  be for minutes. Every step of that pipeline reaches through state that models
//  exactly ONE alarm:
//
//    • `VolumeManager` — one system volume, one fade ramp.
//    • `AlarmSoundPlayer` — one player, one lock.
//    • `RadioAlarmStreamer` — one `AVPlayer`, one generation counter.
//
//  On 2026-08-05 (al-anx / al-3ox) that meant alarm 2's fire at 06:30 tore down
//  alarm 1's confirmed radio stream, started alarm 2's station at volume 0, and
//  armed a fresh 60s fade over a ring that was already three minutes into its
//  own. The user heard the fallback tone for an alarm whose station was fine.
//  `Documents/reviews/2026-08-05/01-DUAL-ALARM-RADIO-DOWNGRADE-INCIDENT.md` has
//  the full chain.
//
//  The rule, matching the FIFO queue the app already implements: the alarm on
//  screen keeps the audio session, and a queued alarm stays silent until it is
//  presented (`presentDequeuedAlarm` then drives its own audio, radio included).
//  Presentation, recovery state, the notification/vibration loop, MQTT state and
//  the queue itself are untouched — ONLY the audio work is skipped.
//
//  Bias: this is the one place where doing less is safe, because the thing it
//  declines to do would land on an alarm that is *already ringing audibly*. It
//  therefore requires positive evidence of another alarm on screen — a nil or
//  matching window identity always runs the pipeline, exactly as before.
//

import Foundation

enum AlarmFireAudioResolution {

    /// What a fire path may do with the shared audio state.
    struct Decision: Equatable {
        /// Another alarm's window is on screen, so `showAlarm` will queue this
        /// alarm rather than present it.
        let queuedBehindShowingAlarm: Bool

        /// System-volume prep, player unlock, `play()`, the radio attempt and the
        /// fade ramp. Skipped only for a queued alarm.
        var runsAudioPipeline: Bool { !queuedBehindShowingAlarm }

        /// A queued alarm has no radio prewarm to adopt (it will cold-start on
        /// dequeue), and leaving one running keeps a silent `AVPlayer` pulling
        /// cellular data for however long the showing alarm's missions take.
        var cancelsRadioPrewarm: Bool { queuedBehindShowingAlarm }

        /// Drop the +5s AlarmKit failsafe immediately instead of waiting for our
        /// own confirmed playback.
        ///
        /// This is **parity, not a weakening**: today the queued alarm's `play()`
        /// succeeds (that is the bug) and the failsafe is cancelled ~2s later
        /// anyway. Leaving it armed would buy nothing — `RingingGuardResolution`
        /// .isDuplicateAlerting suppresses it on arrival, because the queued alarm
        /// owns `activeRingingAlarmID` while a window is showing — while costing
        /// the ring an audio-session interruption from the alert reaching
        /// `.alerting`, which is link 4 of the al-anx chain, and a full-volume
        /// system alert into a deliberate mission-grace silence.
        ///
        /// The wake-up itself is not at stake: an alarm window is on screen and
        /// the user is attending it. The force-kill hole (the queue is memory-only)
        /// is unchanged from today and tracked separately — step 4 of
        /// `Documents/working-notes/PLAN-sleep-through-stack.md`.
        var cancelsAlarmKitFailsafeImmediately: Bool { queuedBehindShowingAlarm }
    }

    /// - Parameters:
    ///   - firingAlarmID: the alarm hash whose fire path is running.
    ///   - isShowingAlarm: an alarm window exists at all
    ///     (`AlarmWindowManager.isShowingAlarm`).
    ///   - showingAlarmID: the alarm whose window is on screen
    ///     (`AlarmWindowManager.currentAlarmID`).
    static func resolve(
        firingAlarmID: Int,
        isShowingAlarm: Bool,
        showingAlarmID: Int?
    ) -> Decision {
        Decision(queuedBehindShowingAlarm: willQueue(
            firingAlarmID: firingAlarmID,
            isShowingAlarm: isShowingAlarm,
            showingAlarmID: showingAlarmID
        ))
    }

    /// Whether `showAlarm` will queue this alarm instead of presenting it.
    ///
    /// `showAlarm` itself calls this, so the fire site's pre-check and the queue
    /// branch can never drift apart. Deliberately identical to the condition it
    /// replaced, including the nil case: a window that is up with no identity is
    /// still a window, and the alarm behind it is queued.
    ///
    /// The same alarm re-entering its own fire path (`showingAlarmID ==
    /// firingAlarmID`) is NOT queued — `showAlarm` treats it as a duplicate and
    /// keeps the screen, and its audio pipeline still runs exactly as before,
    /// because that re-entry is how a recovery or unlock pickup restores a ring
    /// whose sound never started.
    static func willQueue(
        firingAlarmID: Int,
        isShowingAlarm: Bool,
        showingAlarmID: Int?
    ) -> Bool {
        guard isShowingAlarm else { return false }
        return showingAlarmID != firingAlarmID
    }
}
