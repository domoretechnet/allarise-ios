//
//  AlarmOverrideResolution.swift
//  HaWake Alarm V2
//
//  What a per-alarm Skip / Snooze section persists, and when an edit inside it
//  counts as "this alarm now has its own settings".
//
//  Extracted from `AlarmEditorView.saveAlarm()` for al-qcd, where the two rules
//  had drifted apart with no test to notice:
//
//    • The SAVE rule said "write the duration only when the section is marked
//      custom" (`if useCustomSkipMode { … } else { alarm.skipHoldDuration = nil }`).
//    • The MARK rule only ever fired `.onChange(of: skipAlarmMode)` — the MODE.
//
//  So dragging Hold Duration and pressing Save wrote `nil` and dropped the user
//  back to the global setting, silently. The value was on screen, the row showed
//  the new number, and it did not survive. That is the silent-no-op class
//  CLAUDE.md calls out (`days` / al-d44): a rejection would have been kinder.
//
//  Keeping both rules here, pure and side-effect free, is the point — the mark
//  rule and the save rule can now only disagree if a test says so.
//
//  Deliberately NOT changed: the *shape* of what gets written. An untouched
//  section still stores nil for every field, so the alarm keeps tracking the
//  global setting and a later change in Settings still reaches it. That
//  global-tracking is why the flag exists at all, and it is what option (b) —
//  "always save the duration" — would have quietly destroyed.
//

import Foundation

enum AlarmOverrideResolution {

    // MARK: - Marking a section custom

    /// Whether an edit inside a per-alarm section should mark that section as
    /// carrying its own override.
    ///
    /// Once custom, always custom for this editing session — the flag only ever
    /// latches on, so re-selecting the global value mid-drag cannot silently
    /// discard the rest of the user's edits.
    ///
    /// Landing exactly ON the global value does not create an override, which
    /// mirrors what the mode picker already did (`newValue != settings.…`) and
    /// keeps such an alarm following Settings afterwards rather than pinning it
    /// to today's number forever.
    static func marksCustom<Value: Equatable>(alreadyCustom: Bool,
                                              edited: Value,
                                              global: Value) -> Bool {
        alreadyCustom || edited != global
    }

    // MARK: - Skip

    /// The three stored fields a Skip section resolves to.
    struct SkipFields: Equatable {
        var mode: SkipAlarmMode?
        var holdDuration: Double?
        var allowSkipOnce: Bool
    }

    /// What to persist for Skip. `isCustom == false` yields the all-nil,
    /// follow-the-global shape the editor has always written.
    static func skipFields(isCustom: Bool,
                           mode: SkipAlarmMode,
                           holdDuration: Double) -> SkipFields {
        guard isCustom else {
            return SkipFields(mode: nil, holdDuration: nil, allowSkipOnce: true)
        }
        return SkipFields(
            mode: mode,
            // A duration is only meaningful for a hold; tap and disabled clear it
            // so a later switch back to Hold starts from the global again.
            holdDuration: mode == .hold ? holdDuration : nil,
            allowSkipOnce: mode != .disabled
        )
    }

    // MARK: - Snooze

    /// The three stored override fields a Snooze section resolves to.
    /// `snoozeDuration` is absent on purpose — it binds straight to the model and
    /// was never gated by the flag.
    struct SnoozeFields: Equatable {
        var mode: SnoozeMode?
        var holdDuration: Double?
        var maxCount: Int?
    }

    /// What to persist for Snooze. `isCustom == false` yields the all-nil,
    /// follow-the-global shape.
    static func snoozeFields(isCustom: Bool,
                             mode: SnoozeMode,
                             holdDuration: Double,
                             maxCount: Int) -> SnoozeFields {
        guard isCustom else {
            return SnoozeFields(mode: nil, holdDuration: nil, maxCount: nil)
        }
        return SnoozeFields(
            mode: mode,
            holdDuration: mode == .hold ? holdDuration : nil,
            maxCount: mode != .disabled ? maxCount : nil
        )
    }
}
