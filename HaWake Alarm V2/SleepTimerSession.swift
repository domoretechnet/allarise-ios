//
//  SleepTimerSession.swift
//  HaWake Alarm V2
//
//  Debug-only sleep timer for Bryson's OK-to-wake light (al-2se).
//
//  The app is deliberately dumb here: it publishes the *schedule* (retained
//  JSON on one topic) at create/edit/cancel, and Home Assistant derives the
//  live phase from now() vs the timestamps. Nothing fires on the phone at
//  transition moments, so background execution never matters. The tracker UI
//  derives the identical phase locally via SleepTimerLogic.
//
//  State machine (derived, never stored):
//    before_bed → ringing (fixed window) → sleeping_1..4 (equal quarters of
//    ringing-end..wake) → off
//
//  Entities in HA are hand-written YAML (no HACS, no discovery) — the topic
//  below is the whole contract. Keep the payload keys stable.
//

import Foundation
import SwiftData

// MARK: - Model

enum SleepTimerType: String, Codable, CaseIterable {
    case nap
    case bedtime

    var displayName: String {
        switch self {
        case .nap: return "Nap"
        case .bedtime: return "Bedtime"
        }
    }
}

/// Raw values are the HA sensor states — automations trigger on these strings.
enum SleepTimerPhase: String, Codable, Equatable {
    case beforeBed = "before_bed"
    case ringing = "ringing"
    case sleeping1 = "sleeping_1"
    case sleeping2 = "sleeping_2"
    case sleeping3 = "sleeping_3"
    case sleeping4 = "sleeping_4"
    case off = "off"

    var displayName: String {
        switch self {
        case .beforeBed: return "Before Bed"
        case .ringing: return "Time for Bed"
        // One label for all four quarters — the quarter split matters to HA
        // automations, not to the parent reading the card.
        case .sleeping1, .sleeping2, .sleeping3, .sleeping4: return "Sleeping"
        case .off: return "Done"
        }
    }

    var isSleeping: Bool {
        switch self {
        case .sleeping1, .sleeping2, .sleeping3, .sleeping4: return true
        default: return false
        }
    }
}

/// One session per kid at a time; each kid's entities in HA are static,
/// keyed by the kid's slug in the topic path.
struct SleepTimerSession: Codable, Equatable, Identifiable {
    var id: UUID
    var type: SleepTimerType
    var createdAt: Date
    /// When the go-to-bed countdown ends ("ringing" starts).
    var bedTime: Date
    /// Expected wake — the draggable end of the timeline.
    var sleepEnd: Date
    /// First name of the kid this session tracks. Defaulted so the pure-logic
    /// tests can build sessions without caring about identity.
    var kidName: String = ""
    /// HA-side extra, chosen per kid at create time and carried in the
    /// payload for the automations to act on. The app itself does nothing
    /// with it. (A google_timer sibling existed for a day — removed
    /// 2026-08-14 after native Google Home timers proved impossible to set
    /// programmatically; do not repurpose the key.)
    var busyLightAudioEnabled: Bool = false
    /// When `sleepEnd` was last set — by the create sheet (== createdAt), a
    /// wake-point drag, or a stamped remote edit. Published as
    /// `sleep_end_updated_at` so a same-id remote can be ordered against the
    /// local copy: without it, a reconnect's own stale republish echo lands
    /// after HA's retained rewrite and silently reverts it (al-z9qx).
    var sleepEndUpdatedAt: Date

    var kidSlug: String { SleepTimerStore.slug(for: kidName) }

    // Hand-written decoding so sessions persisted (or published) before these
    // flags existed keep decoding — synthesized Decodable would throw on the
    // missing keys and silently drop live sessions on upgrade.
    enum CodingKeys: String, CodingKey {
        case id, type, createdAt, bedTime, sleepEnd, kidName
        case busyLightAudioEnabled
        case sleepEndUpdatedAt
    }

    init(id: UUID, type: SleepTimerType, createdAt: Date, bedTime: Date, sleepEnd: Date,
         kidName: String = "", busyLightAudioEnabled: Bool = false,
         sleepEndUpdatedAt: Date? = nil) {
        self.id = id
        self.type = type
        self.createdAt = createdAt
        self.bedTime = bedTime
        self.sleepEnd = sleepEnd
        self.kidName = kidName
        self.busyLightAudioEnabled = busyLightAudioEnabled
        // A freshly created session's wake point is as old as the session.
        self.sleepEndUpdatedAt = sleepEndUpdatedAt ?? createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        type = try c.decode(SleepTimerType.self, forKey: .type)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        bedTime = try c.decode(Date.self, forKey: .bedTime)
        sleepEnd = try c.decode(Date.self, forKey: .sleepEnd)
        kidName = try c.decodeIfPresent(String.self, forKey: .kidName) ?? ""
        busyLightAudioEnabled = try c.decodeIfPresent(Bool.self, forKey: .busyLightAudioEnabled) ?? false
        // Sessions persisted before the stamp existed: treat the wake point as
        // set at creation, the same default the memberwise init uses.
        sleepEndUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .sleepEndUpdatedAt) ?? createdAt
    }
}

// MARK: - Pure logic (unit-tested; no clock, no I/O)

enum SleepTimerLogic {
    /// Ringing is a 30-second SUB-STATE overlaying the start of the sleep
    /// span, not a prelude to it — the sleep quarters anchor at bedTime and
    /// "asleep at" IS bedTime (contract change 2026-08-13, matched by HA's
    /// template in the same pass).
    static let ringingWindow: TimeInterval = 30
    /// Nap wake defaults to countdown-end + 2 h.
    static let napDefaultSleepDuration: TimeInterval = 2 * 60 * 60
    /// Created 6 AM–6 PM → nap; otherwise bedtime.
    static let napWindowStartHour = 6
    static let napWindowEndHour = 18
    /// Bedtime sessions run until the next 6 AM.
    static let bedtimeWakeHour = 6
    /// OK-to-wake window: HA holds the light green this long after sleep_end,
    /// then turns it off. The app keeps the tracker card (and its green
    /// timeline section) alive for the same window.
    static let wakeWindowDuration: TimeInterval = 2 * 60 * 60

    static func detectedType(at creation: Date, calendar: Calendar = .current) -> SleepTimerType {
        let hour = calendar.component(.hour, from: creation)
        return (hour >= napWindowStartHour && hour < napWindowEndHour) ? .nap : .bedtime
    }

    static func defaultSleepEnd(type: SleepTimerType, bedTime: Date, calendar: Calendar = .current) -> Date {
        switch type {
        case .nap:
            return bedTime.addingTimeInterval(napDefaultSleepDuration)
        case .bedtime:
            let sixAM = DateComponents(hour: bedtimeWakeHour, minute: 0, second: 0)
            return calendar.nextDate(after: bedTime, matching: sixAM,
                                     matchingPolicy: .nextTime, direction: .forward)
                ?? bedTime.addingTimeInterval(8 * 60 * 60)
        }
    }

    /// When the ringing overlay ends — clamped so a wake point dragged inside
    /// the window can never invert it.
    static func ringingEnd(of session: SleepTimerSession) -> Date {
        min(session.bedTime.addingTimeInterval(ringingWindow), session.sleepEnd)
    }

    static func phase(of session: SleepTimerSession, at now: Date) -> SleepTimerPhase {
        if now < session.bedTime { return .beforeBed }
        if now >= session.sleepEnd { return .off }
        if now < ringingEnd(of: session) { return .ringing }
        let span = session.sleepEnd.timeIntervalSince(session.bedTime)
        guard span > 0 else { return .off }
        let quarter = min(3, Int(now.timeIntervalSince(session.bedTime) / span * 4))
        switch quarter {
        case 0: return .sleeping1
        case 1: return .sleeping2
        case 2: return .sleeping3
        default: return .sleeping4
        }
    }

    /// When the OK-to-wake window ends (light goes off in HA; card retires).
    static func wakeWindowEnd(of session: SleepTimerSession) -> Date {
        session.sleepEnd.addingTimeInterval(wakeWindowDuration)
    }

    /// The three interior quarter boundaries of the sleeping span — anchored
    /// at bedTime, since ringing overlays sleeping_1 rather than preceding
    /// it. Empty if the span is degenerate.
    static func quarterBoundaries(of session: SleepTimerSession) -> [Date] {
        let span = session.sleepEnd.timeIntervalSince(session.bedTime)
        guard span > 0 else { return [] }
        return (1...3).map { session.bedTime.addingTimeInterval(span * Double($0) / 4) }
    }

    /// Next phase-transition instant strictly after `now`, or nil once off.
    /// Drives the tracker card's countdown. Sorted because the ringing
    /// overlay's end is not ordered against the quarter boundaries for very
    /// short spans.
    static func nextTransition(of session: SleepTimerSession, after now: Date) -> Date? {
        var boundaries = [session.bedTime, ringingEnd(of: session)]
        boundaries.append(contentsOf: quarterBoundaries(of: session))
        boundaries.append(session.sleepEnd)
        return boundaries.sorted().first { $0 > now }
    }

    /// The retained JSON payload for the HA sensor. `nil` session → cancelled.
    /// Keys are a published contract with the hand-written HA YAML.
    static func mqttPayload(for session: SleepTimerSession?) -> [String: Any] {
        guard let session else { return ["active": false] }
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "active": true,
            "type": session.type.rawValue,
            "bed_time": iso.string(from: session.bedTime),
            "sleep_end": iso.string(from: session.sleepEnd),
            "created_at": iso.string(from: session.createdAt),
            // Orders same-id copies of one session (al-z9qx). A writer that
            // moves `sleep_end` must restamp this to its own now; a writer
            // that omits it is treated as legacy and applied unconditionally.
            "sleep_end_updated_at": iso.string(from: session.sleepEndUpdatedAt),
        ]
        if !session.kidName.isEmpty {
            payload["kid"] = session.kidName
        }
        // HA-side extra — automations key on this; the app only carries it.
        payload["busylight_audio"] = session.busyLightAudioEnabled
        return payload
    }
}

// MARK: - Cross-phone sync (pure decisions; the store executes the actions)

/// Two phones on one broker converge on the same roster and sessions via the
/// device-INDEPENDENT retained topics `{prefix}/kids_sleep/<slug>/state` and
/// `{prefix}/kids_sleep/roster`. Our own publishes echo back, so every branch
/// here has to terminate on the echo: same-id apply, older-cancel republish,
/// and identical-roster no-op are the fixed points that stop the loop.
///
/// Decision math only — no clock, no I/O, no MQTTManager, no UserDefaults —
/// so `SleepTimerSyncLogicTests` can drive every branch directly. The store
/// maps the topic slug to its local session/roster, calls in, and runs the
/// returned action.
enum SleepTimerSyncLogic {

    /// What to do with a message on a `<slug>/state` topic.
    enum SessionAction: Equatable {
        /// Malformed active:true payload, or an active:false for a kid we have
        /// no session for (an echo or a stale retained cancel).
        case ignore
        /// Take the remote session as ours (absent locally, or a different-id
        /// remote with a strictly newer `created_at`). No republish. The store
        /// also adds the kid to the local roster if missing, WITHOUT publishing
        /// the roster — the originating phone's roster publish holds authority.
        /// Never emitted for an already-expired remote adopted from absence —
        /// that stale broker echo is `.ignore`d instead (al-cmd).
        case adopt(SleepTimerSession)
        /// Same-id remote: a wake-point/type edit on the other phone or from
        /// HA. Apply the remote `sleepEnd`/`type` to the local session; no
        /// republish. `updatedAt` is the remote `sleep_end_updated_at` when
        /// present (the store adopts it as the local stamp); nil means a
        /// legacy unstamped writer, applied as before and the local stamp
        /// left alone.
        case applyRemoteFields(sleepEnd: Date, type: SleepTimerType, updatedAt: Date?)
        /// The local session wins — a different-id remote that is not newer, or
        /// an active:false cancel older than the local session. Republish local
        /// so the broker (and the peer) converge to it.
        case republishLocal
        /// A cancel newer than the local session: clear it and echo the cancel
        /// with ITS original timestamp, so a connect-republish race that left
        /// active:true on the broker converges to cancelled. The echo returns
        /// and no-ops (no local session), so this cannot loop.
        case clearAndEchoCancel(cancelledAt: Date)
    }

    /// What to do with a message on the `roster` topic.
    enum RosterAction: Equatable {
        /// Malformed payload — missing/unparseable `kids` or `updated_at`.
        case ignore
        /// Remote roster is strictly newer: replace the local kid list in remote
        /// order, stamp `updatedAt`, and drop the sessions of `droppedSlugs`
        /// (kids the remote removed) WITHOUT publishing cancels — the removing
        /// phone already published those.
        case replace(kids: [String], updatedAt: Date, droppedSlugs: [String])
        /// Remote is not newer and the rosters differ: republish local so the
        /// broker converges to ours.
        case republishLocal
        /// Remote is not newer and the rosters already match — the echo of our
        /// own publish. Nothing to do.
        case noOp
    }

    private static func iso(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    static func reconcileSession(local: SleepTimerSession?, payload: [String: Any],
                                 now: Date = Date()) -> SessionAction {
        // active:false — the cancel path. Keep newer-cancel-wins exactly.
        if payload["active"] as? Bool == false {
            guard let local else { return .ignore }  // already clear — echo or stale
            if let cancelledAt = iso(payload["cancelled_at"]), cancelledAt > local.createdAt {
                return .clearAndEchoCancel(cancelledAt: cancelledAt)
            }
            return .republishLocal
        }

        // active:true — a schedule. The schedule fields are required; a
        // malformed payload is ignored rather than allowed to clobber a good
        // local session. "id" is OPTIONAL: HA-side bridge/manual publishes
        // predate or omit it, and must still be adoptable — an adopted id-less
        // session gets a fresh UUID (the adopting phone becomes its origin,
        // and its next republish stamps the id).
        guard payload["active"] as? Bool == true,
              let createdAt = iso(payload["created_at"]),
              let bedTime = iso(payload["bed_time"]),
              let sleepEnd = iso(payload["sleep_end"]),
              let typeStr = payload["type"] as? String, let type = SleepTimerType(rawValue: typeStr),
              let kid = payload["kid"] as? String, !kid.isEmpty
        else { return .ignore }

        let id = (payload["id"] as? String).flatMap(UUID.init(uuidString:))
        let sleepEndUpdatedAt = iso(payload["sleep_end_updated_at"])
        // The HA-side extra rides along on adoption; absent on old payloads.
        let remote = SleepTimerSession(
            id: id ?? UUID(), type: type, createdAt: createdAt,
            bedTime: bedTime, sleepEnd: sleepEnd, kidName: kid,
            busyLightAudioEnabled: payload["busylight_audio"] as? Bool ?? false,
            sleepEndUpdatedAt: sleepEndUpdatedAt)

        // Adopt-when-absent, but never resurrect an expired schedule. The
        // retained active:true schedule outlives the session on purpose — HA
        // reads "off" from the timestamps, so expiry never republishes and the
        // active:true payload lingers on the broker forever. On every connect
        // that stale echo would re-adopt into a fresh local session and bring
        // the finished tracker card back; refuse it here, using the SAME
        // predicate clearIfExpired uses (`now >= sleepEnd`) so the two agree
        // (al-cmd). Paths where a local session exists are untouched.
        guard let local else {
            return now >= remote.sleepEnd ? .ignore : .adopt(remote)
        }
        if let id, local.id == id {
            // Same session, possibly a different wake point. Order the two
            // copies on `sleep_end_updated_at` (al-z9qx): the reconnect path
            // subscribes and then republishes local, so HA's retained rewrite
            // and our own stale echo both arrive here for one session, echo
            // last. Unstamped → legacy writer, apply as before. Newer → apply.
            // Equal → the echo of our own publish, the loop's fixed point.
            // Older → the stale echo; republish local so the broker converges
            // to the newer wake point instead of keeping the reverted one.
            guard let remoteStamp = sleepEndUpdatedAt else {
                return .applyRemoteFields(sleepEnd: sleepEnd, type: type, updatedAt: nil)
            }
            if remoteStamp > local.sleepEndUpdatedAt {
                return .applyRemoteFields(sleepEnd: sleepEnd, type: type, updatedAt: remoteStamp)
            }
            if remoteStamp == local.sleepEndUpdatedAt {
                // Same stamp, different content: a writer that moved
                // `sleep_end` without restamping. Apply, never republish —
                // republishing on a tie would loop through the broker.
                if sleepEnd != local.sleepEnd || type != local.type {
                    return .applyRemoteFields(sleepEnd: sleepEnd, type: type, updatedAt: nil)
                }
                return .ignore
            }
            return .republishLocal
        }
        // Different (or absent) id — newer created_at wins. An exact tie
        // breaks on uuidString so both phones pick the SAME winner; "ties go
        // local" on both sides would republish forever through the broker.
        // An id-less tie goes local: the local session's republish overwrites
        // the bridge copy with the identical schedule plus its id.
        if createdAt > local.createdAt { return .adopt(remote) }
        if createdAt == local.createdAt, let id, id.uuidString > local.id.uuidString {
            return .adopt(remote)
        }
        return .republishLocal
    }

    static func reconcileRoster(localKids: [String], localUpdatedAt: Date,
                                payload: [String: Any]) -> RosterAction {
        guard let remoteKids = payload["kids"] as? [String],
              let updatedAt = iso(payload["updated_at"])
        else { return .ignore }

        if updatedAt > localUpdatedAt {
            let remoteSlugs = Set(remoteKids.map(SleepTimerStore.slug(for:)))
            let dropped = localKids.map(SleepTimerStore.slug(for:))
                .filter { !remoteSlugs.contains($0) }
            return .replace(kids: remoteKids, updatedAt: updatedAt, droppedSlugs: dropped)
        }
        // Not newer: converge on membership. Matching slugs (order aside) means
        // this is the echo of our own publish — the loop's fixed point.
        let localSlugs = Set(localKids.map(SleepTimerStore.slug(for:)))
        let remoteSlugs = Set(remoteKids.map(SleepTimerStore.slug(for:)))
        return localSlugs == remoteSlugs ? .noOp : .republishLocal
    }
}

// MARK: - Store (kid roster + one session per kid, survives force-kill)

@Observable
final class SleepTimerStore {
    static let shared = SleepTimerStore()

    private static let kidsKey = "sleepTimerKids"
    private static let sessionsKey = "sleepTimerSessions"
    private static let kidOptionsKey = "sleepTimerKidOptions"
    /// When the local roster was last changed, for cross-phone reconcile. Older
    /// installs have no stored value — .distantPast, so the first roster from a
    /// peer is always strictly newer and adopted.
    private static let rosterUpdatedAtKey = "sleepTimerRosterUpdatedAt"
    /// Pre-multi-kid single-session key; orphaned data, cleaned up on init.
    private static let legacySessionKey = "sleepTimerSession"

    /// Kid first names, in the order they were added (drives card order).
    private(set) var kids: [String] = []
    /// Active sessions keyed by kid slug.
    private(set) var sessions: [String: SleepTimerSession] = [:]

    /// Per-kid defaults for the HA-side extras, keyed by slug. Local-only —
    /// the chosen values ride each session's payload; these just remember the
    /// toggles between sessions. (Stored JSON may carry a defunct googleTimer
    /// key from 2026-08-14; unknown keys are ignored on decode.)
    struct KidOptions: Codable, Equatable {
        var busyLightAudio = false
        // Bedtime-alarm defaults (al-5a94). Optionals, not defaulted Bools:
        // synthesized Codable throws on a MISSING key for a non-optional, and
        // stored JSON from before these fields exists on every phone. nil
        // reads as "off" / "use the global default". The full set mirrors the
        // alarm editor's sound section: volume/vibrate/fade-in overrides and
        // the wake-up radio snapshot (id + name + URL, editor-style).
        var bedtimeAlarmEnabled: Bool?
        var bedtimeAlarmSoundID: String?
        var bedtimeAlarmVolume: Double?
        var bedtimeAlarmVibrate: Bool?
        var bedtimeAlarmFadeIn: Bool?
        var bedtimeAlarmFadeInDuration: Int?
        var bedtimeAlarmRadioID: String?
        var bedtimeAlarmRadioName: String?
        var bedtimeAlarmRadioURL: String?
    }
    private(set) var kidOptions: [String: KidOptions] = [:]

    func options(for kidName: String) -> KidOptions {
        kidOptions[Self.slug(for: kidName)] ?? KidOptions()
    }

    func setOptions(_ options: KidOptions, for kidName: String) {
        kidOptions[Self.slug(for: kidName)] = options
        if let data = try? Self.encoder.encode(kidOptions) {
            UserDefaults.standard.set(data, forKey: Self.kidOptionsKey)
        }
    }
    /// Roster version for cross-phone convergence; stamped on add/remove.
    private(set) var rosterUpdatedAt: Date = .distantPast

    // MARK: Bedtime alarm (al-5a94)

    /// The create-page choice to ALSO ring a real app alarm at `bedTime`.
    /// Mirrors the alarm editor's sound section: nil overrides fall back to
    /// the global defaults, exactly like a normal alarm.
    struct BedtimeAlarmChoice {
        var soundID: String
        var volume: Double?
        var vibrate: Bool?
        var fadeIn: Bool?
        var fadeInDuration: Int?
        var radioStation: RadioStation?
    }

    /// slug → `stableID` of that kid's bedtime alarm. Deliberately LOCAL-ONLY
    /// and never part of the session payload: the kids_sleep MQTT contract
    /// stays byte-identical, and a peer phone adopting the session simply has
    /// no local alarm (it keeps the HA light behavior; only the phone that
    /// created the session rings).
    private(set) var bedtimeAlarmIDs: [String: UUID] = [:]
    private static let bedtimeAlarmIDsKey = "sleepTimerBedtimeAlarmIDs"

    /// Active sessions in kid-roster order, for stable home-screen cards.
    var activeSessions: [SleepTimerSession] {
        kids.compactMap { sessions[Self.slug(for: $0)] }
    }

    /// Same sanitization as the MQTT device name, so kid topic segments are
    /// predictable from the name the user typed.
    static func slug(for name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
    }

    private init() {
        kids = UserDefaults.standard.stringArray(forKey: Self.kidsKey) ?? []
        if let data = UserDefaults.standard.data(forKey: Self.sessionsKey),
           let saved = try? Self.decoder.decode([String: SleepTimerSession].self, from: data) {
            sessions = saved
        }
        rosterUpdatedAt = (UserDefaults.standard.object(forKey: Self.rosterUpdatedAtKey) as? Date) ?? .distantPast
        if let data = UserDefaults.standard.data(forKey: Self.kidOptionsKey),
           let saved = try? Self.decoder.decode([String: KidOptions].self, from: data) {
            kidOptions = saved
        }
        if let data = UserDefaults.standard.data(forKey: Self.bedtimeAlarmIDsKey),
           let saved = try? Self.decoder.decode([String: UUID].self, from: data) {
            bedtimeAlarmIDs = saved
        }
        UserDefaults.standard.removeObject(forKey: Self.legacySessionKey)
        // Cold-launch guard: the scenePhase hook only fires on a foreground
        // transition, so a session that expired while the app was terminated
        // would show a stale card until then. Drop it now (al-cmd).
        clearIfExpired()
    }

    // Fixed strategies so persisted sessions survive formatter/locale changes.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    // MARK: Kid roster

    /// Adds a kid by first name. Rejects empties and slug collisions (two
    /// spellings that sanitize identically would share one MQTT topic).
    @discardableResult
    func addKid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Self.slug(for: trimmed)
        guard !trimmed.isEmpty, !slug.isEmpty,
              !kids.contains(where: { Self.slug(for: $0) == slug }) else { return false }
        kids.append(trimmed)
        persistKids()
        // Stamp and publish the roster so a peer phone converges on the new kid.
        // The DEBUG connect path subscribes to the whole kids_sleep subtree, so
        // no late per-kid subscription is needed.
        stampAndPublishRoster()
        return true
    }

    /// Removes a kid and cancels their session (publishing the off payload so
    /// the HA sensor doesn't hold a stale schedule forever).
    func removeKid(_ name: String) {
        let slug = Self.slug(for: name)
        if let session = sessions[slug] {
            sessions.removeValue(forKey: slug)
            persistSessions()
            MQTTManager.shared.publishSleepTimerCancel(kidSlug: slug, cancelledAt: Date(),
                                                       sleepEnd: session.sleepEnd,
                                                       settings: DeviceSettings.shared)
        }
        deleteBedtimeAlarm(forSlug: slug)
        kids.removeAll { Self.slug(for: $0) == slug }
        persistKids()
        stampAndPublishRoster()
    }

    // MARK: Sessions

    func session(for kidName: String) -> SleepTimerSession? {
        sessions[Self.slug(for: kidName)]
    }

    func start(_ newSession: SleepTimerSession, bedtimeAlarm: BedtimeAlarmChoice? = nil) {
        sessions[newSession.kidSlug] = newSession
        persistSessions()
        publishToHA(kidSlug: newSession.kidSlug)
        if let bedtimeAlarm {
            createBedtimeAlarm(for: newSession, choice: bedtimeAlarm)
        }
    }

    func updateSleepEnd(for kidName: String, to newEnd: Date, at now: Date = Date()) {
        let slug = Self.slug(for: kidName)
        guard var current = sessions[slug] else { return }
        current.sleepEnd = newEnd
        // Never let the stamp go backwards (a clock skew after a remote apply)
        // or the drag would lose to the copy it is replacing.
        current.sleepEndUpdatedAt = max(now, current.sleepEndUpdatedAt.addingTimeInterval(1))
        sessions[slug] = current
        persistSessions()
        publishToHA(kidSlug: slug)
    }

    func cancel(kidName: String) {
        let slug = Self.slug(for: kidName)
        guard let session = sessions[slug] else { return }
        sessions.removeValue(forKey: slug)
        persistSessions()
        deleteBedtimeAlarm(forSlug: slug)
        MQTTManager.shared.publishSleepTimerCancel(kidSlug: slug, cancelledAt: Date(),
                                                   sleepEnd: session.sleepEnd,
                                                   settings: DeviceSettings.shared)
    }

    /// A message arrived on a `<slug>/state` topic — from HA, from a peer phone,
    /// or an echo of our own publish. The decision (adopt / apply / republish /
    /// cancel) is pure in `SleepTimerSyncLogic`; here we only carry it out.
    func reconcileRemoteSession(kidSlug: String, payload: [String: Any]) {
        switch SleepTimerSyncLogic.reconcileSession(local: sessions[kidSlug], payload: payload) {
        case .ignore:
            break
        case .adopt(let remote):
            // If a remote session displaces ours, our bedtime alarm belonged to
            // the displaced one — remove it. A no-op when we had no session.
            deleteBedtimeAlarm(forSlug: kidSlug)
            sessions[kidSlug] = remote
            persistSessions()
            // The originating phone's roster publish carries authority, so add
            // the kid locally without publishing OR stamping the roster — a
            // stamp could out-rank the authoritative roster still in flight.
            if !kids.contains(where: { Self.slug(for: $0) == kidSlug }) {
                kids.append(remote.kidName)
                persistKids()
            }
        case .applyRemoteFields(let sleepEnd, let type, let updatedAt):
            guard var current = sessions[kidSlug] else { break }
            current.sleepEnd = sleepEnd
            current.type = type
            if let updatedAt { current.sleepEndUpdatedAt = updatedAt }
            sessions[kidSlug] = current
            persistSessions()
        case .republishLocal:
            publishToHA(kidSlug: kidSlug)
        case .clearAndEchoCancel(let cancelledAt):
            let sleepEnd = sessions[kidSlug]?.sleepEnd
            sessions.removeValue(forKey: kidSlug)
            persistSessions()
            // A cancel from HA or the peer phone also takes the alarm with it.
            deleteBedtimeAlarm(forSlug: kidSlug)
            MQTTManager.shared.publishSleepTimerCancel(kidSlug: kidSlug, cancelledAt: cancelledAt,
                                                       sleepEnd: sleepEnd,
                                                       settings: DeviceSettings.shared)
        }
    }

    /// A message arrived on the `roster` topic. Newer roster replaces ours (and
    /// silently drops the sessions of kids it removed); an older/equal roster
    /// that differs from ours triggers a republish so the broker converges.
    func reconcileRemoteRoster(payload: [String: Any]) {
        switch SleepTimerSyncLogic.reconcileRoster(localKids: kids, localUpdatedAt: rosterUpdatedAt,
                                                   payload: payload) {
        case .ignore, .noOp:
            break
        case .replace(let newKids, let updatedAt, let droppedSlugs):
            kids = newKids
            rosterUpdatedAt = updatedAt
            persistKids()
            persistRosterUpdatedAt()
            let toDrop = droppedSlugs.filter { sessions[$0] != nil }
            if !toDrop.isEmpty {
                for slug in toDrop { sessions.removeValue(forKey: slug) }
                persistSessions()
            }
            // Alarm cleanup keys off droppedSlugs, not toDrop — an alarm entry
            // can outlive its session (e.g. expiry raced the roster update).
            for slug in droppedSlugs { deleteBedtimeAlarm(forSlug: slug) }
        case .republishLocal:
            MQTTManager.shared.publishSleepTimerRoster(kids: kids, updatedAt: rosterUpdatedAt,
                                                       settings: DeviceSettings.shared)
        }
    }

    /// Drop sessions whose wake time has passed — the card retires at wake
    /// (user decision 2026-08-14); HA's light independently stays green
    /// through its 2-hour window. No republish — the retained timestamps
    /// already read as "off"/awake in HA. Called on foreground AND from the
    /// list view's periodic sweep, so the card also disappears while the app
    /// sits open.
    func clearIfExpired(at now: Date = Date()) {
        let expired = sessions.filter { now >= $0.value.sleepEnd }
        guard !expired.isEmpty else { return }
        for slug in expired.keys {
            sessions.removeValue(forKey: slug)
            // Backstop only. A dismissed bedtime alarm deletes its own row at
            // dismissal and has already released its mapping (al-02is), so this
            // is a no-op in the normal case. It still matters for the alarm
            // nobody ever tapped off, which would otherwise sit in the list
            // disabled forever.
            deleteBedtimeAlarm(forSlug: slug)
        }
        persistSessions()
    }

    // MARK: Bedtime alarm lifecycle (al-5a94)

    /// Create the kid's tap-to-dismiss bedtime alarm — a REAL `Alarm` through
    /// the real engine (AlarmKit failsafe, force-kill recovery and all), never
    /// a parallel ring path. `excludeFromMQTT` + no `alarmIndex` keep it out of
    /// every HA surface; the kids_sleep tree is HA's whole picture of this.
    private func createBedtimeAlarm(for session: SleepTimerSession, choice: BedtimeAlarmChoice) {
        let slug = session.kidSlug
        deleteBedtimeAlarm(forSlug: slug)   // re-create is idempotent
        let alarm = Alarm(
            time: session.bedTime,
            label: "\(session.kidName) Sleep Alarm",
            isEnabled: true,
            soundName: choice.soundID,
            mission: Mission.defaultMission,                    // single tap to dismiss
            allowSkipOnce: false,
            snoozeModeRaw: SnoozeMode.disabled.rawValue,        // no snooze
            skipAlarmModeRaw: SkipAlarmMode.disabled.rawValue
        )
        alarm.customVolumeLevel = choice.volume
        alarm.customVibrationEnabled = choice.vibrate
        alarm.customFadeInEnabled = choice.fadeIn
        alarm.customFadeInDuration = choice.fadeInDuration
        // Wake-up radio, same snapshot the editor stores. The ring path streams
        // the station and falls back to the tone exactly as for a normal alarm.
        alarm.radioStationID = choice.radioStation?.id
        alarm.radioStationName = choice.radioStation?.name
        alarm.radioStationURL = choice.radioStation?.streamURL
        alarm.excludeFromMQTT = true
        // Bed time is an exact moment, possibly under a minute away or "now"
        // (al-is5q): fire at the stored second rather than the minute
        // resolution, which would ring up to 59 s early — or roll a
        // just-passed minute to tomorrow.
        alarm.firesAtExactTime = true
        guard let id = alarm.stableID else { return }
        bedtimeAlarmIDs[slug] = id
        persistBedtimeAlarmIDs()
        Task { @MainActor in
            guard let context = AlarmWindowManager.shared.modelContainer?.mainContext else { return }
            context.insert(alarm)
            try? context.save()
            await DualAlarmCoordinator.shared.scheduleAlarm(alarm)
        }
    }

    /// Which kid owns `alarmID`, and the map with that claim released. Pure, so
    /// the release rules are testable without a singleton, a ModelContainer or
    /// UserDefaults — the same split `SleepTimerLogic` uses for the phase math.
    ///
    /// Reverse lookup rather than a second slug→id dictionary: a household has a
    /// handful of kids, and one map cannot drift out of sync with itself.
    static func releasingBedtimeAlarm(_ alarmID: UUID, from map: [String: UUID])
        -> (slug: String?, remaining: [String: UUID]) {
        guard let slug = map.first(where: { $0.value == alarmID })?.key else {
            return (nil, map)
        }
        var remaining = map
        remaining.removeValue(forKey: slug)
        return (slug, remaining)
    }

    /// The kid whose bedtime alarm carries `alarmID`, if it is one of ours.
    func kidSlug(forBedtimeAlarmID alarmID: UUID) -> String? {
        Self.releasingBedtimeAlarm(alarmID, from: bedtimeAlarmIDs).slug
    }

    /// A bedtime alarm has been dismissed: give up the store's claim on it and
    /// report whether it was ours, so the dismissal path can delete the row.
    ///
    /// The row is a one-shot for tonight — once the kid has tapped it off it has
    /// done its whole job, so it leaves the alarm list immediately instead of
    /// sitting there disabled until the session expires at wake (owner request
    /// 2026-08-22, al-02is). The session itself is untouched: the tracker card
    /// and the HA light run on the retained `kids_sleep` timestamps and know
    /// nothing about the alarm.
    ///
    /// The caller deletes the SwiftData row rather than this store, because it
    /// already holds the alarm and its context. Forgetting the mapping here is
    /// what keeps a later `cancel`/`removeKid`/expiry sweep from chasing a row
    /// that is already gone.
    @discardableResult
    func claimDismissedBedtimeAlarm(alarmID: UUID) -> Bool {
        let (slug, remaining) = Self.releasingBedtimeAlarm(alarmID, from: bedtimeAlarmIDs)
        guard slug != nil else { return false }
        bedtimeAlarmIDs = remaining
        persistBedtimeAlarmIDs()
        return true
    }

    /// Delete the bedtime alarm tied to a slug, if any. Tolerates an alarm the
    /// user already removed from the alarm list by hand.
    private func deleteBedtimeAlarm(forSlug slug: String) {
        guard let id = bedtimeAlarmIDs.removeValue(forKey: slug) else { return }
        persistBedtimeAlarmIDs()
        Task { @MainActor in
            guard let context = AlarmWindowManager.shared.modelContainer?.mainContext,
                  let alarms = try? context.fetch(FetchDescriptor<Alarm>()),
                  let alarm = alarms.first(where: { $0.stableID == id }) else { return }
            await DualAlarmCoordinator.shared.cancelAlarm(alarm)
            context.delete(alarm)
            try? context.save()
        }
    }

    private func persistBedtimeAlarmIDs() {
        if let data = try? Self.encoder.encode(bedtimeAlarmIDs) {
            UserDefaults.standard.set(data, forKey: Self.bedtimeAlarmIDsKey)
        }
    }

    // MARK: MQTT

    func publishToHA(kidSlug: String) {
        guard let session = sessions[kidSlug] else { return }
        MQTTManager.shared.publishSleepTimerState(session, kidSlug: kidSlug,
                                                  settings: DeviceSettings.shared)
    }

    /// Re-sync every active session's retained topic (called from the MQTT
    /// connect path so sessions created while offline still reach HA).
    func republishAllToHA() {
        for slug in sessions.keys { publishToHA(kidSlug: slug) }
    }

    /// Re-publish the roster on connect so a peer converges. Skipped when empty
    /// — publishing an empty roster on every connect would plant a stray
    /// retained topic on the broker of anyone who never used the feature. A
    /// newer retained roster arriving afterwards still wins via reconcile.
    func republishRosterIfNonEmpty() {
        guard !kids.isEmpty else { return }
        MQTTManager.shared.publishSleepTimerRoster(kids: kids, updatedAt: rosterUpdatedAt,
                                                   settings: DeviceSettings.shared)
    }

    private func stampAndPublishRoster() {
        rosterUpdatedAt = Date()
        persistRosterUpdatedAt()
        MQTTManager.shared.publishSleepTimerRoster(kids: kids, updatedAt: rosterUpdatedAt,
                                                   settings: DeviceSettings.shared)
    }

    private func persistKids() {
        UserDefaults.standard.set(kids, forKey: Self.kidsKey)
    }

    private func persistSessions() {
        if let data = try? Self.encoder.encode(sessions) {
            UserDefaults.standard.set(data, forKey: Self.sessionsKey)
        }
    }

    private func persistRosterUpdatedAt() {
        UserDefaults.standard.set(rosterUpdatedAt, forKey: Self.rosterUpdatedAtKey)
    }
}

// MARK: - MQTT publish (device-independent kids_sleep tree; HA + peers derive
//         everything else. Retopiced from the old per-device path so two phones
//         in one household see the same sessions and roster.)

extension MQTTManager {
    /// `{prefix}/kids_sleep/<slug>/state`. Retained regardless of the user's
    /// retain preference — the whole design depends on the schedule surviving
    /// HA restarts and app absence. `id` carries session identity (echo and
    /// different-id detection during reconcile); `device` is origin metadata for
    /// debugging only and is never read by any decision.
    func publishSleepTimerState(_ session: SleepTimerSession, kidSlug: String, settings: DeviceSettings) {
        guard isConnected, !kidSlug.isEmpty else { return }
        let topic = "\(settings.mqttTopicPrefix)/kids_sleep/\(kidSlug)/state"
        var payload = SleepTimerLogic.mqttPayload(for: session)
        payload["id"] = session.id.uuidString
        payload["device"] = settings.sanitizedDeviceName
        publish(topic: topic, payload: payload, retain: true)
    }

    /// Cancels are stamped so both sides can apply newer-cancel-wins: HA
    /// publishes the same shape from its cancel script, and
    /// `SleepTimerSyncLogic.reconcileSession` compares `cancelled_at` against
    /// the local session's `created_at`. The cancelled session's `sleep_end`
    /// rides along so HA can tell a live-session cancel (grants the cancel
    /// green window) from clearing an already-expired card (must NOT grant a
    /// fresh window) — `cancelled_at < sleep_end` is the HA-side gate, with
    /// absent `sleep_end` falling back to always-grant for compatibility.
    func publishSleepTimerCancel(kidSlug: String, cancelledAt: Date, sleepEnd: Date? = nil,
                                 settings: DeviceSettings) {
        guard isConnected, !kidSlug.isEmpty else { return }
        let topic = "\(settings.mqttTopicPrefix)/kids_sleep/\(kidSlug)/state"
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "active": false,
            "cancelled_at": iso.string(from: cancelledAt),
            "device": settings.sanitizedDeviceName,
        ]
        if let sleepEnd {
            payload["sleep_end"] = iso.string(from: sleepEnd)
        }
        publish(topic: topic, payload: payload, retain: true)
    }

    /// `{prefix}/kids_sleep/roster` — the shared kid list. `updated_at` drives
    /// newer-wins reconcile across phones; `device` is origin metadata only.
    func publishSleepTimerRoster(kids: [String], updatedAt: Date, settings: DeviceSettings) {
        guard isConnected else { return }
        let topic = "\(settings.mqttTopicPrefix)/kids_sleep/roster"
        let payload: [String: Any] = [
            "kids": kids,
            "updated_at": ISO8601DateFormatter().string(from: updatedAt),
            "device": settings.sanitizedDeviceName,
        ]
        publish(topic: topic, payload: payload, retain: true)
    }

    /// One-time sweep of the OLD per-device topics `{prefix}/{device}/sleep_timer/
    /// <slug>/state` this build no longer writes — an empty retained payload so
    /// the broker stops serving the stale schedule. Guarded by a UserDefaults
    /// flag so it runs once per install.
    func clearLegacySleepTimerTopics(settings: DeviceSettings) {
        let flagKey = "sleepTimerLegacyTopicsCleared"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        let device = settings.sanitizedDeviceName
        for kid in SleepTimerStore.shared.kids {
            let slug = SleepTimerStore.slug(for: kid)
            let topic = "\(settings.mqttTopicPrefix)/\(device)/sleep_timer/\(slug)/state"
            publish(topic: topic, payload: "", retain: true)
        }
        UserDefaults.standard.set(true, forKey: flagKey)
    }
}
