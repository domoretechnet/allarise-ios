import Foundation

// MARK: - What a finished ring owes the sleep sounds it interrupted

/// Pure decision logic for the sleep-sound stack when an alarm stops ringing.
///
/// **Product decision 2026-08-06 (al-ecf), superseding al-3jm:** an alarm going
/// off means the sleep sounds *stop*, and they stay stopped however the ring
/// ends — snooze, dismiss, or with another alarm still queued. There is no
/// auto-resume in any alarm outcome; the user restarts them manually, the same
/// way `RadioPlayerManager` already handles a radio sleep source.
///
/// This reverses the earlier al-3jm direction, where a snooze faded the sleep
/// sound back in for the snooze interval. The reasoning then was that a snooze
/// meant "going back to sleep"; the owner's call now is that the sounds simply
/// stop, so a half-slept snooze is never accompanied by rain the user has to go
/// silence by hand. The one rule carried over unchanged: a pause the *user*
/// asked for is never touched by an alarm — that is what `pausedByAlarm` guards.
///
/// Kept separate from `SleepSoundManager` so the decision is testable without an
/// audio engine — the same shape as `AlarmDismissResolution` and
/// `RingingGuardResolution`.
enum SleepSoundAlarmResolution {

    /// How the ring ended. Deliberately *not* the MQTT `AlarmState` vocabulary:
    /// this is a local input to an audio decision, not something on the wire.
    ///
    /// Since al-ecf the outcome no longer changes the result — both a dismiss
    /// and a snooze stop the sleep sound. It is kept because the call sites
    /// naturally carry it and it documents which ring endings this seam covers;
    /// if a future outcome ever needs different handling, the input is here.
    enum RingOutcome: Equatable {
        case dismissed
        case snoozed
    }

    enum Action: Equatable {
        /// Leave the sleep-sound stack exactly as it is.
        case none
        /// End the session cleanly (engine torn down, Now Playing cleared),
        /// rather than leaving it paused indefinitely.
        case stop
    }

    /// - Parameters:
    ///   - outcome: how this ring ended. No longer branches the decision
    ///     (al-ecf) — see the type doc comment.
    ///   - pausedByAlarm: whether *an alarm* paused the sleep sound. False when
    ///     the user paused it themselves (or it was never playing) — a
    ///     user-initiated pause must never be stopped out from under them.
    ///   - hasQueuedAlarms: whether another alarm is stacked behind this one.
    ///     No longer branches the decision (al-ecf): the sound stops at the
    ///     first ring, so there is nothing left for a later ring to resolve.
    static func resolve(
        outcome: RingOutcome,
        pausedByAlarm: Bool,
        hasQueuedAlarms: Bool
    ) -> Action {
        // Not ours to touch. This is the whole point of the `pausedByAlarm`
        // flag: a pause the user asked for outlives the alarm.
        guard pausedByAlarm else { return .none }

        // An alarm fired, so the sleep sound stops — and stays stopped whatever
        // the outcome or the queue. The user restarts it manually (al-ecf).
        return .stop
    }
}
