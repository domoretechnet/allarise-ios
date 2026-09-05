//
//  Alarm.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import Foundation
import SwiftData

/// One step in the ordered after-alarm pipeline that runs once an alarm is
/// FULLY dismissed. Raw values are the stable ids persisted in
/// `Alarm.afterAlarmOrderData`.
///   • `.notes`   — show the full-page Notes screen (text + optional command
///     buttons), ported from V1's alarm-screen notes widget.
///   • `.verse`   — show the Verse of the Day card.
///   • `.weather` — show the existing Good Morning weather card.
///   • `.appLink` — open the alarm's configured dismiss app link. TERMINAL and
///     ALWAYS LAST (it leaves the app); the flow ends after it fires.
enum AfterAlarmAction: String, Codable, CaseIterable, Sendable {
    case notes
    case verse
    case weather
    case appLink
}

@Model
final class Alarm {
    /// Launch-stable identity. `persistentModelID.hashValue` is only stable
    /// within a single app session, but AlarmKit UUIDs, timer keys, and the
    /// UserDefaults recovery blobs must survive relaunches. Optional so that
    /// pre-existing alarms load cleanly; `migrateStableIDs` (app init) assigns
    /// one to any alarm that predates this field. Always read identity via
    /// `stableHash`, never `persistentModelID.hashValue`.
    var stableID: UUID?
    var time: Date
    var label: String
    var isEnabled: Bool
    /// Stored as comma-separated integers (e.g. "1,3,5"). Empty string = one-time.
    /// Using String instead of Set<Int> avoids SwiftData transformable faulting,
    /// which crashes when backing data is invalidated during iCloud merge deletes.
    var recurringDaysRaw: String = ""
    var soundName: String
    var snoozeDuration: Int
    var missionData: Data // Stores encoded Mission (SLOT 1 — full backward compatibility)
    /// Slots 2..5 of a multi-mission sequence, stored as JSON-encoded `[Mission]`.
    /// nil / empty = single-mission alarm (behaves exactly as before). Slot 1 stays
    /// in `missionData` so every existing reader (AlarmKit metadata, recovery blobs,
    /// MQTT, widgets, editor) keeps working unchanged. Optional with a default so
    /// SwiftData lightweight migration adds it to pre-existing alarms with no break.
    var extraMissionsData: Data? = nil
    var allowSkipOnce: Bool
    var skippedFireDate: Date? // The specific fire date being skipped (nil = not skipped)
    var lastFireDate: Date?
    var skipHoldDuration: Double? // Optional override for per-alarm setting (nil = use default)
    
    // Snooze tracking
    var isSnoozed: Bool = false
    var snoozeUntil: Date?
    var snoozeCount: Int = 0
    
    // Snooze configuration (nil = use defaults from settings)
    var maxSnoozeCount: Int? // Max number of snoozes allowed (nil = use default)
    var snoozeRequiresHold: Bool? // Legacy — migrated to snoozeModeRaw
    var customSnoozeHoldDuration: Double? // Custom hold duration for snooze (nil = use default)
    var snoozeModeRaw: String? // Per-alarm SnoozeMode override (nil = use default)
    var skipAlarmModeRaw: String? // Per-alarm SkipAlarmMode override (nil = use default)
    
    // Per-alarm volume override (nil = use global default from settings)
    var customVolumeLevel: Double?
    
    // Per-alarm grace period override (nil = use global default; 0 = use dynamic formula)
    var customGracePeriod: Double?
    
    // Per-alarm vibration override (nil = use global default from settings)
    var customVibrationEnabled: Bool?
    
    // Per-alarm fade-in override (nil = use global default from settings)
    var customFadeInEnabled: Bool?
    // Per-alarm fade-in duration in minutes (nil = use global default from settings)
    var customFadeInDuration: Int?
    
    // Per-alarm swipe command overrides (UUID string of MQTTCommand, nil = default swipe action)
    var swipeLeftCommandID: String?
    var swipeRightCommandID: String?

    // Show Morning Weather card after dismissing this alarm
    var showWeatherAfterAlarm: Bool = false

    // App links opened after dismiss/snooze (URL string, e.g. "shortcuts://run-shortcut?name=...").
    // Dismiss link fires at the end of the dismiss chain — after the Morning
    // Weather card closes when that's enabled. nil/empty = no link.
    var dismissAppURI: String?
    var snoozeAppURI: String?

    // Notes shown on the full-page Notes after-alarm step, plus up to four
    // command buttons (UUID strings of MQTTCommand) rendered on that page.
    // Field names match V1's alarm-screen notes widget so the MQTT payload
    // fields (`notes`, `alarm_screen_commands`) map 1:1. Presence of any
    // content here is what surfaces `.notes` in `afterAlarmActions` for
    // alarms without an explicit order (and reconciles MQTT-driven drift).
    var alarmScreenNotes: String = ""
    var alarmScreenCommandID1: String?
    var alarmScreenCommandID2: String?
    var alarmScreenCommandID3: String?
    var alarmScreenCommandID4: String?

    // Ordered list of after-alarm actions to run once this alarm is FULLY
    // dismissed (all missions complete — never on snooze). Stored as a
    // JSON-encoded ordered `[String]` of action ids ("verse", "weather",
    // "appLink"), mirroring the `extraMissionsData` optional-blob pattern so
    // SwiftData lightweight migration adds it to pre-existing alarms with no
    // break. nil = derive the list from today's legacy per-alarm state (see the
    // `afterAlarmActions` accessor). This field stores ONLY order/enablement;
    // each action's CONFIG stays in its existing field (weather toggle,
    // dismissAppURI). Verse has no other field — its presence in the list IS
    // its enablement.
    var afterAlarmOrderData: Data? = nil

    // Radio station streamed while this alarm rings (nil = no radio).
    // Name + URL are a snapshot so 6am playback never depends on the
    // radio-browser directory API. soundName stays the guaranteed local
    // fallback tone (and the AlarmKit/notification sound).
    var radioStationID: String?
    var radioStationName: String?
    var radioStationURL: String?

    // MQTT source tracking
    var source: String = "local"    // "local" or "mqtt"
    var mqttID: String?             // HA-assigned ID for MQTT-created alarms
    var isEphemeral: Bool = false   // true = delete after firing (one-shot MQTT alarm)
    var alarmIndex: Int = 0         // Stable MQTT ID — auto-assigned, never reused (0 = not yet assigned)
    // Keep this alarm out of ALL MQTT/HA publishing — per-alarm topics, the
    // name-keyed globals (next/active/wake alarm name, counts) and the
    // slept-through ledger. alarmIndex == 0 alone is NOT enough: the global
    // sensors are name-keyed. Used by the Kids Sleep bedtime alarm, whose HA
    // story lives entirely on the kids_sleep tree (al-5a94).
    var excludeFromMQTT: Bool = false
    // Fire at the exact stored Date — seconds included — instead of resolving
    // hour/minute to the next daily occurrence. Used by the Kids Sleep bedtime
    // alarm, whose bed time can be 30 s away or "now": minute resolution zeroes
    // the seconds and rolls a just-passed minute to TOMORROW. Deliberately not
    // isEphemeral — quick-alarm-ness carries its own MQTT/Siri surfaces (see
    // the dismissal note in AlarmListView, al-5a94).
    var firesAtExactTime: Bool = false

    // Static default encoded mission data
    private static let defaultMissionData: Data = {
        let encoder = JSONEncoder()
        return (try? encoder.encode(Mission.defaultMission)) ?? Data([0x7B, 0x7D]) // "{}" in case encoding fails
    }()
    
    // Decoded-mission cache keyed by the raw missionData bytes, held in a
    // reference box so reads/writes never touch a tracked model property.
    // Keying on the data means direct missionData assignments (e.g. from
    // DismissAlarmIntent) invalidate the cache automatically.
    private final class MissionCache {
        var data: Data?
        var mission: Mission?
    }
    @Transient private var missionCache: MissionCache = MissionCache()

    // Computed property for mission (transient - not persisted directly)
    @Transient
    var mission: Mission {
        get {
            if let cached = missionCache.mission, missionCache.data == missionData {
                return cached
            }
            guard !missionData.isEmpty else {
                return Mission.defaultMission
            }
            let decoder = JSONDecoder()
            let decoded = (try? decoder.decode(Mission.self, from: missionData)) ?? Mission.defaultMission
            missionCache.data = missionData
            missionCache.mission = decoded
            return decoded
        }
        set {
            let encoder = JSONEncoder()
            if let encoded = try? encoder.encode(newValue) {
                missionData = encoded
            } else {
                missionData = Self.defaultMissionData
            }
            missionCache.data = missionData
            missionCache.mission = newValue
        }
    }

    // Decoded extra-missions cache, mirroring MissionCache: keyed on the raw
    // extraMissionsData bytes so a direct assignment invalidates it automatically.
    private final class ExtraMissionsCache {
        var data: Data?
        var missions: [Mission]?
    }
    @Transient private var extraMissionsCache: ExtraMissionsCache = ExtraMissionsCache()

    /// Slots 2..5 as a decoded `[Mission]` (empty when there are none). Mirrors the
    /// `mission`/`missionData` transient pattern exactly. Assigning an empty array
    /// clears `extraMissionsData` back to nil.
    @Transient
    var extraMissions: [Mission] {
        get {
            guard let data = extraMissionsData, !data.isEmpty else { return [] }
            if let cached = extraMissionsCache.missions, extraMissionsCache.data == data {
                return cached
            }
            let decoded = (try? JSONDecoder().decode([Mission].self, from: data)) ?? []
            extraMissionsCache.data = data
            extraMissionsCache.missions = decoded
            return decoded
        }
        set {
            if newValue.isEmpty {
                extraMissionsData = nil
                extraMissionsCache.data = nil
                extraMissionsCache.missions = []
                return
            }
            if let encoded = try? JSONEncoder().encode(newValue) {
                extraMissionsData = encoded
                extraMissionsCache.data = encoded
                extraMissionsCache.missions = newValue
            }
        }
    }

    /// The ordered after-alarm actions this alarm runs once FULLY dismissed.
    ///
    /// EXPLICIT: when `afterAlarmOrderData` is present, decode its ordered ids
    /// (unknown ids dropped, duplicates removed, `.appLink` forced last).
    ///
    /// LEGACY DERIVATION (field nil — every alarm that predates the editor):
    /// derive the list from today's existing per-alarm state so behavior is
    /// byte-for-byte identical until the editor writes an explicit order —
    ///   • `.weather` if `showWeatherAfterAlarm` is on (the same condition that
    ///     shows the Good Morning card today), then
    ///   • `.appLink` if a non-empty `dismissAppURI` is configured.
    /// Yielding `[]`, `[.weather]`, `[.appLink]`, or `[.weather, .appLink]` —
    /// exactly the four cases the old dismiss chain already handled.
    @Transient
    var afterAlarmActions: [AfterAlarmAction] {
        get {
            if let data = afterAlarmOrderData,
               let ids = try? JSONDecoder().decode([String].self, from: data) {
                var actions = Self.normalizeAfterAlarm(ids.compactMap(AfterAlarmAction.init(rawValue:)))
                // Read-time reconciliation against the legacy appLink CONFIG field.
                // MQTT inbound commands mutate `dismissAppURI` directly, never the
                // explicit order, so the two can drift apart. Reconcile on read:
                //   • an explicit `.appLink` whose URI is now empty is DROPPED — the
                //     terminal open-app step would otherwise fire with no URL;
                //   • a non-empty URI set by MQTT while `.appLink` is missing from the
                //     explicit order is APPENDED (last, per the invariant), so an
                //     MQTT-configured link still fires even on an explicitly-ordered
                //     alarm.
                let hasURI = !(dismissAppURI?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                if actions.contains(.appLink) && !hasURI {
                    actions.removeAll { $0 == .appLink }
                } else if !actions.contains(.appLink) && hasURI {
                    actions.append(.appLink)
                }
                // Same reconciliation for `.notes` against its CONFIG fields
                // (notes text / command slots), which MQTT mutates directly:
                // no content → the step would render an empty page, drop it;
                // content set while `.notes` is missing → append it (before the
                // terminal appLink, via normalize).
                if actions.contains(.notes) && !hasNotesContent {
                    actions.removeAll { $0 == .notes }
                } else if !actions.contains(.notes) && hasNotesContent {
                    actions = Self.normalizeAfterAlarm(actions + [.notes])
                }
                return actions
            }
            // Legacy derivation from existing per-alarm fields (field nil, or
            // corrupt data): notes, then weather, then app link.
            var derived: [AfterAlarmAction] = []
            if hasNotesContent { derived.append(.notes) }
            if showWeatherAfterAlarm { derived.append(.weather) }
            if let uri = dismissAppURI?.trimmingCharacters(in: .whitespacesAndNewlines),
               !uri.isEmpty {
                derived.append(.appLink)
            }
            return derived
        }
        set {
            afterAlarmOrderData = try? JSONEncoder().encode(
                Self.normalizeAfterAlarm(newValue).map(\.rawValue)
            )
        }
    }

    /// The non-nil notes-page command slots, in slot order (UUID strings of
    /// `MQTTCommand`).
    @Transient
    var alarmScreenCommandIDs: [String] {
        [alarmScreenCommandID1, alarmScreenCommandID2,
         alarmScreenCommandID3, alarmScreenCommandID4].compactMap { $0 }
    }

    /// True when the Notes after-alarm step has something to show: notes text,
    /// or at least one command button.
    @Transient
    var hasNotesContent: Bool {
        !alarmScreenNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !alarmScreenCommandIDs.isEmpty
    }

    /// Enforce the accessor invariant: drop duplicates (keeping first
    /// occurrence) and force `.appLink` — the terminal, app-leaving action — to
    /// be last. Unknown ids are already dropped upstream by `init(rawValue:)`.
    static func normalizeAfterAlarm(_ actions: [AfterAlarmAction]) -> [AfterAlarmAction] {
        var seen = Set<AfterAlarmAction>()
        var result: [AfterAlarmAction] = []
        for action in actions where action != .appLink {
            if seen.insert(action).inserted { result.append(action) }
        }
        if actions.contains(.appLink) { result.append(.appLink) }
        return result
    }

    /// The ordered list of missions this alarm requires to dismiss: slot 1
    /// (`mission`) first, then the extras. `.alert` slots are always excluded (they
    /// are internal, never a dismiss gate).
    ///
    /// Tap (`.none`) slots are now first-class, combinable missions. A `.none` slot
    /// is INCLUDED in the sequence when EITHER:
    ///   (a) it demands more than a single tap — a hold, or a multi-tap count
    ///       (`tapDismissIsMission`) — making it a real mission on its own; OR
    ///   (b) the alarm is multi-slot (more than one non-`.alert` slot), so even a
    ///       count-1 Tap slot stays as a "tap to continue" step in the sequence.
    /// A SOLO single-tap `.none` alarm (one slot, count 1, no hold) yields an EMPTY
    /// sequence and behaves byte-for-byte like today's missionless alarm: empty →
    /// DefaultStopIntent (background stop), landing-page single-tap dismiss.
    ///
    /// Everything downstream — AlarmKit intent selection (`isEmpty` → DefaultStop,
    /// else CompleteMission), snooze gating, the progress label, and the recovery
    /// blob — follows automatically from this list.
    @Transient
    var missionSequence: [Mission] {
        // Every non-`.alert` slot, in order. `.none` Tap slots are kept here so the
        // multi-slot test below can see them; solo single-taps are dropped after.
        let slots = ([mission] + extraMissions).filter { $0.type != .alert }
        // "Multi-slot" = the alarm has more than one dismiss step. In that case even
        // a plain single-tap slot is a real step and stays in the sequence.
        let multiSlot = slots.count > 1
        var seq: [Mission] = []
        for m in slots {
            if m.type == .none {
                if m.tapDismissIsMission || multiSlot { seq.append(m) }
            } else {
                seq.append(m)
            }
        }
        return seq
    }

    // Computed accessor for recurringDays (stored as raw string to avoid faulting crash)
    @Transient
    var recurringDays: Set<Int> {
        get {
            guard !recurringDaysRaw.isEmpty else { return [] }
            return Set(recurringDaysRaw.split(separator: ",").compactMap { Int($0) })
        }
        set {
            recurringDaysRaw = newValue.sorted().map(String.init).joined(separator: ",")
        }
    }
    
    // Computed per-alarm snooze mode (nil = use default from settings)
    @Transient
    var alarmSnoozeMode: SnoozeMode? {
        get {
            if let raw = snoozeModeRaw {
                return SnoozeMode(rawValue: raw)
            }
            // Migrate from legacy snoozeRequiresHold
            if let legacyHold = snoozeRequiresHold {
                return legacyHold ? .hold : .tap
            }
            return nil
        }
        set {
            snoozeModeRaw = newValue?.rawValue
            // Clear legacy field
            snoozeRequiresHold = nil
        }
    }
    
    // Computed per-alarm skip alarm mode (nil = use default from settings)
    @Transient
    var alarmSkipMode: SkipAlarmMode? {
        get {
            if let raw = skipAlarmModeRaw {
                return SkipAlarmMode(rawValue: raw)
            }
            // Migrate from legacy allowSkipOnce + skipHoldDuration
            // (only if these have been explicitly set by the user)
            return nil
        }
        set {
            skipAlarmModeRaw = newValue?.rawValue
        }
    }
    
    /// Effective snooze mode for this alarm, falling back to global settings
    func effectiveSnoozeMode(settings: DeviceSettings) -> SnoozeMode {
        alarmSnoozeMode ?? settings.snoozeMode
    }
    
    /// Effective volume level for this alarm, falling back to global settings
    func effectiveVolumeLevel(settings: DeviceSettings) -> Double {
        customVolumeLevel ?? settings.alarmVolumeLevel
    }
    
    /// Effective grace period duration for this alarm
    /// Returns the grace period in seconds, or nil if mission is none
    func effectiveGracePeriod(settings: DeviceSettings) -> Double? {
        guard mission.type != .none else { return nil }
        
        // Per-alarm override takes priority (0 = use auto-calculated)
        if let custom = customGracePeriod {
            return custom > 0 ? custom : mission.calculatedGracePeriod
        }
        
        // Default: use auto-calculated grace period
        return mission.calculatedGracePeriod
    }
    
    /// Effective vibration enabled for this alarm, falling back to global settings
    func effectiveVibrationEnabled(settings: DeviceSettings) -> Bool {
        customVibrationEnabled ?? settings.alarmVibrationEnabled
    }
    
    /// Effective fade-in enabled for this alarm, falling back to global settings
    func effectiveFadeInEnabled(settings: DeviceSettings) -> Bool {
        customFadeInEnabled ?? settings.alarmFadeInEnabled
    }
    
    /// Effective fade-in duration in seconds for this alarm, falling back to global settings.
    /// A stored value of 0 means 30 seconds; all other values are in minutes.
    func effectiveFadeInDurationSeconds(settings: DeviceSettings) -> TimeInterval {
        let storedValue = customFadeInDuration ?? settings.alarmFadeInDuration
        if storedValue == 0 { return 30 }
        return TimeInterval(storedValue * 60)
    }
    
    /// Effective skip alarm mode for this alarm, falling back to global settings
    func effectiveSkipMode(settings: DeviceSettings) -> SkipAlarmMode {
        if let mode = alarmSkipMode {
            return mode
        }
        // Legacy: if allowSkipOnce was explicitly set to false, treat as disabled
        if !allowSkipOnce {
            return .disabled
        }
        return settings.skipAlarmMode
    }
    
    init(
        time: Date = Date(),
        label: String = "Alarm",
        isEnabled: Bool = true,
        recurringDays: Set<Int> = [],
        soundName: String = "Default",
        snoozeDuration: Int = 9,
        mission: Mission = Mission.defaultMission,
        allowSkipOnce: Bool = true,
        skippedFireDate: Date? = nil,
        lastFireDate: Date? = nil,
        skipHoldDuration: Double? = nil,
        isSnoozed: Bool = false,
        snoozeUntil: Date? = nil,
        snoozeCount: Int = 0,
        maxSnoozeCount: Int? = nil,
        snoozeRequiresHold: Bool? = nil,
        customSnoozeHoldDuration: Double? = nil,
        snoozeModeRaw: String? = nil,
        skipAlarmModeRaw: String? = nil
    ) {
        self.stableID = UUID()
        self.time = time
        self.label = label
        self.isEnabled = isEnabled
        self.recurringDaysRaw = recurringDays.sorted().map(String.init).joined(separator: ",")
        self.soundName = soundName
        self.snoozeDuration = snoozeDuration
        // Encode mission with proper error handling
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(mission) {
            self.missionData = encoded
        } else {
            // Fallback to pre-encoded default mission
            self.missionData = Self.defaultMissionData
        }
        self.allowSkipOnce = allowSkipOnce
        self.skippedFireDate = skippedFireDate
        self.lastFireDate = lastFireDate
        self.skipHoldDuration = skipHoldDuration
        self.isSnoozed = isSnoozed
        self.snoozeUntil = snoozeUntil
        self.snoozeCount = snoozeCount
        self.maxSnoozeCount = maxSnoozeCount
        self.snoozeRequiresHold = snoozeRequiresHold
        self.customSnoozeHoldDuration = customSnoozeHoldDuration
        self.snoozeModeRaw = snoozeModeRaw
        self.skipAlarmModeRaw = skipAlarmModeRaw
    }
    
    /// Launch-stable integer identity derived from `stableID`. Used everywhere
    /// the app previously used `persistentModelID.hashValue` (AlarmKit UUID
    /// derivation, timer dictionary keys, UserDefaults recovery blobs, MQTT
    /// alarm lookups). Falls back to the legacy session-scoped hash only for
    /// alarms not yet migrated (migrateStableIDs runs before any scheduling).
    /// The top bit is masked off so the value is always non-negative —
    /// alarmIDToUUID() takes abs(), and abs(Int.min) would trap.
    var stableHash: Int {
        guard let id = stableID else { return persistentModelID.hashValue }
        let b = id.uuid
        let v = (UInt64(b.0) << 56) | (UInt64(b.1) << 48) | (UInt64(b.2) << 40) | (UInt64(b.3) << 32)
              | (UInt64(b.4) << 24) | (UInt64(b.5) << 16) | (UInt64(b.6) << 8) | UInt64(b.7)
        return Int(bitPattern: UInt(v & 0x7FFF_FFFF_FFFF_FFFF))
    }

    // Whether the next fire is currently being skipped
    var isSkipped: Bool {
        guard let skipped = skippedFireDate else { return false }
        // Skip is active if the skipped date is still in the future
        return skipped > Date()
    }
    
    /// True when this alarm has been deleted from its SwiftData context.
    /// Accessing lazy-loaded properties (like `recurringDays`) on a detached
    /// model object causes a fatal error, so callers should check this first.
    /// Note: this only catches objects whose context reference is already nil.
    /// Objects invalidated during an iCloud merge may still have a context —
    /// use the delete-cooldown pattern to avoid those.
    var isDetached: Bool {
        modelContext == nil
    }

    /// Alias kept so existing call sites don't need updating.
    /// Now that `recurringDays` reads from `recurringDaysRaw` (a plain String),
    /// there is no faulting risk — this just returns `recurringDays`.
    var safeRecurringDays: Set<Int> {
        recurringDays
    }
    
    // Check if alarm is recurring
    var isRecurring: Bool {
        !recurringDaysRaw.isEmpty
    }
    
    // Get next fire date
    func nextFireDate(from date: Date = Date()) -> Date? {
        guard isEnabled else { return nil }
        
        let calendar = Calendar.current
        let now = date
        
        // Ephemeral (quick) alarms store an exact absolute fire time —
        // return it directly so the timer fires at the precise second.
        if isEphemeral {
            if lastFireDate != nil { return nil }
            return time > now ? time : nil
        }

        // Exact-time one-shots (Kids Sleep bedtime alarm): the stored Date IS
        // the fire time. A "bed now" alarm is already a moment past its time by
        // the time scheduling runs, so a just-passed date is still returned —
        // the scheduler's overdue path (≤60 s) rings it immediately instead of
        // this method rolling it to tomorrow.
        if firesAtExactTime {
            if lastFireDate != nil { return nil }
            if time > now { return time }
            return now.timeIntervalSince(time) <= 60 ? time : nil
        }

        // Get time components from alarm time
        // Zero out seconds so alarms fire exactly on the minute (DatePicker only sets hour/minute,
        // but the underlying Date may carry arbitrary seconds)
        var alarmComponents = calendar.dateComponents([.hour, .minute], from: time)
        alarmComponents.second = 0
        
        if isRecurring {
            // For recurring alarms, find the next matching day
            var nextDate: Date?
            
            for dayOffset in 0..<15 { // Check today and next 14 days (extra range to find the occurrence after a skipped one)
                guard let checkDate = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
                
                let weekday = calendar.component(.weekday, from: checkDate)
                
                // Check if this weekday is in recurringDays
                if safeRecurringDays.contains(weekday) {
                    // Create the alarm time for this date
                    var components = calendar.dateComponents([.year, .month, .day], from: checkDate)
                    components.hour = alarmComponents.hour
                    components.minute = alarmComponents.minute
                    components.second = alarmComponents.second
                    
                    guard let alarmDate = calendar.date(from: components) else { continue }
                    
                    // Skip if this date matches the skipped fire date
                    if let skipped = skippedFireDate,
                       calendar.isDate(alarmDate, equalTo: skipped, toGranularity: .minute) {
                        continue
                    }
                    
                    // If this time hasn't passed yet (or it's a future day), use it
                    if alarmDate > now {
                        nextDate = alarmDate
                        break
                    }
                }
            }
            
            return nextDate
        } else {
            // For one-time alarms
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = alarmComponents.hour
            components.minute = alarmComponents.minute
            components.second = alarmComponents.second
            
            guard let alarmDate = calendar.date(from: components) else { return nil }
            
            // Check if this alarm has already fired
            if lastFireDate != nil {
                // If it has fired, one-time alarms should NOT reschedule
                // Return nil so the alarm doesn't show a "next fire" time
                return nil
            }
            
            // If the time hasn't passed yet today, schedule for today
            if alarmDate > now {
                return alarmDate
            }
            
            // If the time has passed today but hasn't fired yet, schedule for tomorrow
            // (This handles the case when creating a new alarm in the evening)
            return calendar.date(byAdding: .day, value: 1, to: alarmDate)
        }
    }

    // MARK: - Duplication
    //
    // ┌───────────────────────────────────────────────────────────────────────┐
    // │  ADDING A NEW STORED PROPERTY TO `Alarm`? YOU MUST TOUCH THIS METHOD. │
    // └───────────────────────────────────────────────────────────────────────┘
    //
    // This lives on the model, next to the properties it mirrors, precisely so
    // that it is visible when a property is added. It used to live in
    // `AlarmListView.duplicateAlarm` as a hand-maintained list of assignments,
    // and every feature added after that list was written was silently dropped
    // when a user duplicated an alarm — mission slots 2–5, the whole After-Alarm
    // sequence, the notes and their four command buttons, and the radio station.
    // The analytics event fired right after it even read those fields back and
    // reported them empty, which is how the drift went unnoticed.
    //
    // Every stored property belongs in exactly ONE of the three groups below.
    // `AlarmDuplicationTests` fails if a property is added without being
    // classified, so this comment is enforced rather than aspirational.

    /// Creates an independent copy of this alarm.
    ///
    /// - Parameters:
    ///   - label: The new alarm's name. Callers pass a de-duplicated name.
    ///   - alarmIndex: Index for the copy. Ephemeral alarms take 0.
    /// - Returns: An unsaved `Alarm`; the caller inserts it into the context.
    func duplicate(label newLabel: String, alarmIndex newIndex: Int) -> Alarm {
        // GROUP 1 — NEW IDENTITY. Must differ, or the copy is not a copy.
        //   stableID   assigned fresh by init()
        //   label      caller supplies a de-duplicated name
        //   alarmIndex caller supplies the next free index
        //   isEnabled  a duplicate arrives switched off, so it cannot ring
        //              unnoticed at a time the user has not reviewed
        let copy = Alarm(
            time: time,
            label: newLabel,
            isEnabled: false,
            recurringDays: safeRecurringDays,
            soundName: soundName,
            snoozeDuration: snoozeDuration,
            mission: mission,
            allowSkipOnce: allowSkipOnce,
            skipHoldDuration: skipHoldDuration,
            maxSnoozeCount: maxSnoozeCount,
            customSnoozeHoldDuration: customSnoozeHoldDuration,
            snoozeModeRaw: snoozeModeRaw,
            skipAlarmModeRaw: skipAlarmModeRaw
        )

        // GROUP 2 — COPIED. Everything that makes this alarm what it is.
        // Missions
        copy.extraMissionsData = extraMissionsData
        // Sound / feel
        copy.customVolumeLevel = customVolumeLevel
        copy.customVibrationEnabled = customVibrationEnabled
        copy.customGracePeriod = customGracePeriod
        copy.customFadeInEnabled = customFadeInEnabled
        copy.customFadeInDuration = customFadeInDuration
        // Radio as an alarm source
        copy.radioStationID = radioStationID
        copy.radioStationName = radioStationName
        copy.radioStationURL = radioStationURL
        // After-Alarm sequence
        copy.afterAlarmOrderData = afterAlarmOrderData
        copy.showWeatherAfterAlarm = showWeatherAfterAlarm
        copy.dismissAppURI = dismissAppURI
        copy.snoozeAppURI = snoozeAppURI
        // Notes page and its four command buttons
        copy.alarmScreenNotes = alarmScreenNotes
        copy.alarmScreenCommandID1 = alarmScreenCommandID1
        copy.alarmScreenCommandID2 = alarmScreenCommandID2
        copy.alarmScreenCommandID3 = alarmScreenCommandID3
        copy.alarmScreenCommandID4 = alarmScreenCommandID4
        // Row swipe commands
        copy.swipeLeftCommandID = swipeLeftCommandID
        copy.swipeRightCommandID = swipeRightCommandID
        // Legacy snooze flag — still read by the migration path, so carry it.
        copy.snoozeRequiresHold = snoozeRequiresHold
        // Ephemeral-ness is a property of the alarm, not of this instance's run.
        copy.isEphemeral = isEphemeral
        copy.alarmIndex = newIndex
        // MQTT-hidden-ness is likewise a property of the alarm — a duplicate of
        // a hidden alarm must not suddenly start publishing to HA.
        copy.excludeFromMQTT = excludeFromMQTT
        // Exact-time firing is part of what the alarm is, like ephemeral-ness.
        copy.firesAtExactTime = firesAtExactTime

        // GROUP 3 — DELIBERATELY RESET. Runtime state and provenance. Copying
        // any of these would carry another alarm's history onto a new one.
        //   isSnoozed / snoozeUntil / snoozeCount  live snooze state
        //   skippedFireDate                        a skip applies to one occurrence
        //   lastFireDate                           this copy has never fired
        //   source                                 the copy was made in-app
        //   mqttID                                 HA's ID belongs to the original
        // All keep their `init()` defaults; assigning them here would be the bug.

        return copy
    }

    /// The model's own stored-property names, read from SwiftData's schema at
    /// runtime rather than hand-listed.
    ///
    /// This exists solely so `AlarmDuplicationTests` can detect a property that
    /// was added without being handled in `duplicate(label:alarmIndex:)`. Deriving
    /// it from the schema is the whole point — a hand-written list here would have
    /// exactly the same drift problem the test is meant to catch.
    static var storedPropertyNamesForDuplicationAudit: [String] {
        // `Schema.PropertyMetadata` is storage-only and exposes no name, so go via
        // the built Schema, whose entity properties do. Transients are excluded:
        // they are caches, never part of an alarm's identity.
        guard let entity = Schema([Alarm.self]).entities.first else { return [] }
        return entity.properties.filter { !$0.isTransient }.map(\.name)
    }
}

// MARK: - Locale-aware weekday helpers

/// Provides locale-aware day ordering and weekend/weekday detection.
/// Internal day numbering (1=Sun … 7=Sat) is never changed — only display order adapts.
enum LocaleWeekday {
    /// Returns day numbers 1-7 ordered by the locale's first day of the week.
    static func orderedDayNumbers(calendar: Calendar = .current) -> [Int] {
        let first = calendar.firstWeekday // 1=Sun, 2=Mon, etc.
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    // Cache of computed weekend sets keyed by calendar/locale/firstWeekday —
    // the 7 `nextDate` searches are too slow to run per row render. A locale
    // change produces a new key, so stale entries are simply never read again.
    private static let weekendCacheLock = NSLock()
    nonisolated(unsafe) private static var weekendCache: [String: Set<Int>] = [:]

    /// Returns the set of weekend day numbers (1-7) for the current locale.
    static func weekendDayNumbers(calendar: Calendar = .current) -> Set<Int> {
        let key = "\(calendar.identifier)|\(calendar.locale?.identifier ?? "")|\(calendar.firstWeekday)"
        weekendCacheLock.lock()
        defer { weekendCacheLock.unlock() }
        if let cached = weekendCache[key] {
            return cached
        }
        // Calendar.weekendRange is unavailable on older OS; use dateComponents approach.
        var weekend = Set<Int>()
        // Check each weekday by creating a date for it and testing isDateInWeekend
        let ref = Date()
        for wd in 1...7 {
            if let d = calendar.nextDate(after: ref, matching: DateComponents(weekday: wd), matchingPolicy: .nextTime) {
                if calendar.isDateInWeekend(d) {
                    weekend.insert(wd)
                }
            }
        }
        weekendCache[key] = weekend
        return weekend
    }

    /// Returns the set of weekday (non-weekend) day numbers for the current locale.
    static func weekdayNumbers(calendar: Calendar = .current) -> Set<Int> {
        Set(1...7).subtracting(weekendDayNumbers(calendar: calendar))
    }
}

