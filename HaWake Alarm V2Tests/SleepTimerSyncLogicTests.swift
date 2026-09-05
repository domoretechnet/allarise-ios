//
//  SleepTimerSyncLogicTests.swift
//  HaWake Alarm V2Tests
//
//  The cross-phone reconcile behind Bryson's OK-to-wake sessions (al-2se). Two
//  phones on one broker converge on the same roster and sessions via retained
//  MQTT; SleepTimerSyncLogic is the pure decision layer that keeps them from
//  clobbering each other or looping on their own echoes. The bug this guards:
//  a peer's active:true payload silently overwriting a newer local session, an
//  HA cancel resurrected by a connect-republish, or a roster edit on one phone
//  never reaching the other. Every branch is exercised decision-in / action-out
//  with no MQTTManager, no UserDefaults, and no wall clock — payload timestamps
//  are built from DateComponents through a FIXED Gregorian calendar and zone.
//

import Testing
import Foundation
@testable import HaWake_Alarm_V2

struct SleepTimerSyncLogicTests {

    // Fixed calendar/zone so every timestamp is deterministic and ISO-8601
    // round-trips exactly (whole seconds only).
    private static let zone = TimeZone(identifier: "America/Detroit")!
    private static var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }()

    private static func date(_ y: Int, _ mo: Int, _ d: Int,
                             _ h: Int, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = s
        comps.timeZone = zone
        return cal.date(from: comps)!
    }

    // Fixed UUIDs so identity comparisons are stable across a test.
    private static let idA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private static let idB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    // MARK: Payload builders (the shapes the publish helpers emit)

    private static func activePayload(id: UUID, kid: String, type: SleepTimerType,
                                      created: Date, bed: Date, end: Date,
                                      sleepEndUpdatedAt: Date? = nil) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var p: [String: Any] = [
            "active": true,
            "id": id.uuidString,
            "kid": kid,
            "type": type.rawValue,
            "created_at": iso.string(from: created),
            "bed_time": iso.string(from: bed),
            "sleep_end": iso.string(from: end),
            "device": "phone-a",
        ]
        if let sleepEndUpdatedAt { p["sleep_end_updated_at"] = iso.string(from: sleepEndUpdatedAt) }
        return p
    }

    private static func cancelPayload(cancelledAt: Date?) -> [String: Any] {
        var p: [String: Any] = ["active": false, "device": "phone-a"]
        if let cancelledAt { p["cancelled_at"] = ISO8601DateFormatter().string(from: cancelledAt) }
        return p
    }

    private static func rosterPayload(kids: [String], updatedAt: Date) -> [String: Any] {
        ["kids": kids, "updated_at": ISO8601DateFormatter().string(from: updatedAt), "device": "phone-a"]
    }

    private static func session(id: UUID, kid: String, type: SleepTimerType,
                                created: Date, bed: Date, end: Date,
                                sleepEndUpdatedAt: Date? = nil) -> SleepTimerSession {
        SleepTimerSession(id: id, type: type, createdAt: created,
                          bedTime: bed, sleepEnd: end, kidName: kid,
                          sleepEndUpdatedAt: sleepEndUpdatedAt)
    }

    // MARK: - reconcileSession: active:true

    @Test("session: no local session, unexpired remote → adopt the remote verbatim, no republish")
    func adoptWhenAbsent() {
        let created = Self.date(2026, 8, 13, 19, 45)
        let bed = Self.date(2026, 8, 13, 20, 0)
        let end = Self.date(2026, 8, 13, 22, 0)
        let payload = Self.activePayload(id: Self.idA, kid: "Bryson", type: .bedtime,
                                         created: created, bed: bed, end: end)
        let expected = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                    created: created, bed: bed, end: end)
        // Explicit `now` BEFORE sleep_end — the adopt path refuses an already-
        // expired remote (al-cmd), so the default wall clock (well past this
        // fixture's 2026 dates) would otherwise turn this into .ignore.
        let now = Self.date(2026, 8, 13, 21, 0)
        #expect(SleepTimerSyncLogic.reconcileSession(local: nil, payload: payload, now: now)
                == .adopt(expected))
    }

    @Test("session: no local session, remote sleep_end already passed → ignore (stale broker echo)")
    func adoptRefusedWhenExpired() {
        // The retained active:true schedule outlives the session on purpose;
        // adopting it on every connect resurrected the finished tracker card
        // (al-cmd). `now` is at/after sleep_end → refuse.
        let created = Self.date(2026, 8, 13, 19, 45)
        let bed = Self.date(2026, 8, 13, 20, 0)
        let end = Self.date(2026, 8, 13, 22, 0)
        let payload = Self.activePayload(id: Self.idA, kid: "Bryson", type: .bedtime,
                                         created: created, bed: bed, end: end)
        let now = Self.date(2026, 8, 14, 6, 0)  // past sleep_end
        #expect(SleepTimerSyncLogic.reconcileSession(local: nil, payload: payload, now: now)
                == .ignore)
    }

    @Test("session: expired active:true WITH a local session follows the existing rules (same-id apply)")
    func expiredRemoteWithLocalStillApplies() {
        // The expiry guard only governs adopt-from-absence. A same-id remote
        // whose sleep_end has passed is still a wake-point/type edit and must
        // apply as before — pinned with `now` past the remote's sleepEnd.
        let created = Self.date(2026, 8, 13, 19, 45)
        let bed = Self.date(2026, 8, 13, 20, 0)
        let localEnd = Self.date(2026, 8, 13, 22, 0)
        let remoteEnd = Self.date(2026, 8, 13, 23, 0)
        let local = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                 created: created, bed: bed, end: localEnd)
        let payload = Self.activePayload(id: Self.idA, kid: "Bryson", type: .nap,
                                         created: created, bed: bed, end: remoteEnd)
        let now = Self.date(2026, 8, 14, 6, 0)  // past remote sleepEnd
        #expect(SleepTimerSyncLogic.reconcileSession(local: local, payload: payload, now: now)
                == .applyRemoteFields(sleepEnd: remoteEnd, type: .nap, updatedAt: nil))
    }

    @Test("session: same id → apply the remote sleepEnd/type, no republish (a wake-point edit)")
    func sameIdApply() {
        let created = Self.date(2026, 8, 13, 19, 45)
        let bed = Self.date(2026, 8, 13, 20, 0)
        let localEnd = Self.date(2026, 8, 13, 22, 0)
        let remoteEnd = Self.date(2026, 8, 13, 23, 0)
        let local = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                 created: created, bed: bed, end: localEnd)
        // Same id, edited end AND type — both remote fields flow to local.
        let payload = Self.activePayload(id: Self.idA, kid: "Bryson", type: .nap,
                                         created: created, bed: bed, end: remoteEnd)
        #expect(SleepTimerSyncLogic.reconcileSession(local: local, payload: payload)
                == .applyRemoteFields(sleepEnd: remoteEnd, type: .nap, updatedAt: nil))
    }

    // MARK: - reconcileSession: same-id stamp ordering (al-z9qx)
    //
    // On reconnect the phone subscribes THEN republishes local, so for one
    // session HA's retained wake-target rewrite and the phone's own stale echo
    // both arrive as same-id payloads. `sleep_end_updated_at` orders them so the
    // echo can no longer silently revert the newer edit.

    @Test("session: same id, remote stamp strictly newer → apply and adopt the remote stamp (al-z9qx)")
    func sameIdNewerStampApplies() {
        // HA moved the wake point and restamped: its stamp out-ranks ours, so
        // the edit lands and the local stamp advances to it.
        let created = Self.date(2026, 8, 13, 19, 45)
        let bed = Self.date(2026, 8, 13, 20, 0)
        let localEnd = Self.date(2026, 8, 13, 22, 0)
        let remoteEnd = Self.date(2026, 8, 13, 23, 0)
        let localStamp = Self.date(2026, 8, 13, 20, 0)
        let remoteStamp = Self.date(2026, 8, 13, 21, 0)
        let local = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                 created: created, bed: bed, end: localEnd,
                                 sleepEndUpdatedAt: localStamp)
        let payload = Self.activePayload(id: Self.idA, kid: "Bryson", type: .bedtime,
                                         created: created, bed: bed, end: remoteEnd,
                                         sleepEndUpdatedAt: remoteStamp)
        #expect(SleepTimerSyncLogic.reconcileSession(local: local, payload: payload)
                == .applyRemoteFields(sleepEnd: remoteEnd, type: .bedtime, updatedAt: remoteStamp))
    }

    @Test("session: same id, remote stamp strictly older (the stale echo) → republish local (al-z9qx)")
    func sameIdOlderStampRepublishes() {
        // Our own retained republish echoes back after HA's newer rewrite; its
        // stamp is older, so we push the newer local copy back to the broker
        // rather than let the echo revert the wake point.
        let created = Self.date(2026, 8, 13, 19, 45)
        let bed = Self.date(2026, 8, 13, 20, 0)
        let localEnd = Self.date(2026, 8, 13, 23, 0)
        let remoteEnd = Self.date(2026, 8, 13, 22, 0)
        let localStamp = Self.date(2026, 8, 13, 21, 0)
        let remoteStamp = Self.date(2026, 8, 13, 20, 0)
        let local = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                 created: created, bed: bed, end: localEnd,
                                 sleepEndUpdatedAt: localStamp)
        let payload = Self.activePayload(id: Self.idA, kid: "Bryson", type: .bedtime,
                                         created: created, bed: bed, end: remoteEnd,
                                         sleepEndUpdatedAt: remoteStamp)
        #expect(SleepTimerSyncLogic.reconcileSession(local: local, payload: payload)
                == .republishLocal)
    }

    @Test("session: same id, equal stamp, identical content → ignore (the echo's fixed point) (al-z9qx)")
    func sameIdEqualStampIdenticalIgnores() {
        // The exact echo of our own publish — same stamp, same wake point and
        // type. Nothing to do; republishing on a tie would loop the broker.
        let created = Self.date(2026, 8, 13, 19, 45)
        let bed = Self.date(2026, 8, 13, 20, 0)
        let end = Self.date(2026, 8, 13, 22, 0)
        let stamp = Self.date(2026, 8, 13, 21, 0)
        let local = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                 created: created, bed: bed, end: end,
                                 sleepEndUpdatedAt: stamp)
        let payload = Self.activePayload(id: Self.idA, kid: "Bryson", type: .bedtime,
                                         created: created, bed: bed, end: end,
                                         sleepEndUpdatedAt: stamp)
        #expect(SleepTimerSyncLogic.reconcileSession(local: local, payload: payload)
                == .ignore)
    }

    @Test("session: same id, equal stamp, different sleepEnd → apply without adopting the stamp (al-z9qx)")
    func sameIdEqualStampDifferentContentApplies() {
        // A pass-through writer moved sleep_end without restamping. Apply the
        // change (never republish on a tie), but leave the local stamp alone.
        let created = Self.date(2026, 8, 13, 19, 45)
        let bed = Self.date(2026, 8, 13, 20, 0)
        let localEnd = Self.date(2026, 8, 13, 22, 0)
        let remoteEnd = Self.date(2026, 8, 13, 23, 0)
        let stamp = Self.date(2026, 8, 13, 21, 0)
        let local = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                 created: created, bed: bed, end: localEnd,
                                 sleepEndUpdatedAt: stamp)
        let payload = Self.activePayload(id: Self.idA, kid: "Bryson", type: .bedtime,
                                         created: created, bed: bed, end: remoteEnd,
                                         sleepEndUpdatedAt: stamp)
        #expect(SleepTimerSyncLogic.reconcileSession(local: local, payload: payload)
                == .applyRemoteFields(sleepEnd: remoteEnd, type: .bedtime, updatedAt: nil))
    }

    @Test("session: same id, remote UNSTAMPED, local stamped later → still apply (legacy writer keeps working) (al-z9qx)")
    func sameIdUnstampedRemoteApplies() {
        // An older app or a hand-written HA publish carries no
        // sleep_end_updated_at. It is treated as legacy and applied
        // unconditionally, even though the local copy has a newer stamp.
        let created = Self.date(2026, 8, 13, 19, 45)
        let bed = Self.date(2026, 8, 13, 20, 0)
        let localEnd = Self.date(2026, 8, 13, 22, 0)
        let remoteEnd = Self.date(2026, 8, 13, 23, 0)
        let localStamp = Self.date(2026, 8, 13, 21, 0)
        let local = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                 created: created, bed: bed, end: localEnd,
                                 sleepEndUpdatedAt: localStamp)
        // No sleepEndUpdatedAt in the payload — the legacy shape.
        let payload = Self.activePayload(id: Self.idA, kid: "Bryson", type: .bedtime,
                                         created: created, bed: bed, end: remoteEnd)
        #expect(SleepTimerSyncLogic.reconcileSession(local: local, payload: payload)
                == .applyRemoteFields(sleepEnd: remoteEnd, type: .bedtime, updatedAt: nil))
    }

    @Test("session: adopt-from-absence carries the remote stamp (al-z9qx)")
    func adoptCarriesStamp() {
        let created = Self.date(2026, 8, 13, 19, 45)
        let bed = Self.date(2026, 8, 13, 20, 0)
        let end = Self.date(2026, 8, 13, 22, 0)
        let stamp = Self.date(2026, 8, 13, 21, 0)
        let now = Self.date(2026, 8, 13, 21, 0)  // before end, so adopt (al-cmd)

        // Stamped payload → the adopted session keeps that stamp.
        let stamped = Self.activePayload(id: Self.idA, kid: "Bryson", type: .bedtime,
                                         created: created, bed: bed, end: end,
                                         sleepEndUpdatedAt: stamp)
        let stampedAction = SleepTimerSyncLogic.reconcileSession(local: nil, payload: stamped, now: now)
        guard case .adopt(let s) = stampedAction else {
            Issue.record("expected .adopt, got \(stampedAction)")
            return
        }
        #expect(s.sleepEndUpdatedAt == stamp)

        // Unstamped payload → the adopted session's stamp defaults to created_at.
        let unstamped = Self.activePayload(id: Self.idA, kid: "Bryson", type: .bedtime,
                                           created: created, bed: bed, end: end)
        let unstampedAction = SleepTimerSyncLogic.reconcileSession(local: nil, payload: unstamped, now: now)
        guard case .adopt(let u) = unstampedAction else {
            Issue.record("expected .adopt, got \(unstampedAction)")
            return
        }
        #expect(u.sleepEndUpdatedAt == created)
    }

    @Test("session: a legacy persisted session (no sleepEndUpdatedAt key) decodes with stamp == createdAt (al-z9qx)")
    func legacyPersistedSessionDecodes() {
        let created = Self.date(2026, 8, 13, 19, 45)
        let session = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                   created: created,
                                   bed: Self.date(2026, 8, 13, 20, 0),
                                   end: Self.date(2026, 8, 13, 22, 0),
                                   sleepEndUpdatedAt: Self.date(2026, 8, 13, 21, 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try! encoder.encode(session)
        // Strip the key, mimicking a session persisted before it existed.
        var dict = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "sleepEndUpdatedAt")
        let stripped = try! JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try! decoder.decode(SleepTimerSession.self, from: stripped)
        #expect(decoded.sleepEndUpdatedAt == created)
    }

    @Test("session: different id, remote created_at strictly newer → adopt remote")
    func differentIdNewerRemoteAdopts() {
        let bed = Self.date(2026, 8, 13, 20, 0)
        let end = Self.date(2026, 8, 13, 22, 0)
        let local = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                 created: Self.date(2026, 8, 13, 19, 45), bed: bed, end: end)
        let remoteCreated = Self.date(2026, 8, 13, 19, 50)
        let payload = Self.activePayload(id: Self.idB, kid: "Bryson", type: .bedtime,
                                         created: remoteCreated, bed: bed, end: end)
        let expected = Self.session(id: Self.idB, kid: "Bryson", type: .bedtime,
                                    created: remoteCreated, bed: bed, end: end)
        #expect(SleepTimerSyncLogic.reconcileSession(local: local, payload: payload) == .adopt(expected))
    }

    @Test("session: different id, local newer → republish local (broker converges to ours)")
    func differentIdLocalNewerRepublishes() {
        let bed = Self.date(2026, 8, 13, 20, 0)
        let end = Self.date(2026, 8, 13, 22, 0)
        let local = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                 created: Self.date(2026, 8, 13, 19, 50), bed: bed, end: end)
        let payload = Self.activePayload(id: Self.idB, kid: "Bryson", type: .bedtime,
                                         created: Self.date(2026, 8, 13, 19, 45), bed: bed, end: end)
        #expect(SleepTimerSyncLogic.reconcileSession(local: local, payload: payload) == .republishLocal)
    }

    @Test("session: different id, equal created_at → uuidString breaks the tie the SAME way on both phones")
    func differentIdTieBreaksOnUUID() {
        let created = Self.date(2026, 8, 13, 19, 45)
        let bed = Self.date(2026, 8, 13, 20, 0)
        let end = Self.date(2026, 8, 13, 22, 0)
        // idB > idA lexically. Phone holding A receives B → adopts; phone
        // holding B receives A → republishes. Both converge on B; "ties go
        // local" on both sides would ping-pong through the broker forever.
        let localA = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                  created: created, bed: bed, end: end)
        let payloadB = Self.activePayload(id: Self.idB, kid: "Bryson", type: .bedtime,
                                          created: created, bed: bed, end: end)
        let expectedB = Self.session(id: Self.idB, kid: "Bryson", type: .bedtime,
                                     created: created, bed: bed, end: end)
        #expect(SleepTimerSyncLogic.reconcileSession(local: localA, payload: payloadB) == .adopt(expectedB))

        let localB = expectedB
        let payloadA = Self.activePayload(id: Self.idA, kid: "Bryson", type: .bedtime,
                                          created: created, bed: bed, end: end)
        #expect(SleepTimerSyncLogic.reconcileSession(local: localB, payload: payloadA) == .republishLocal)
    }

    @Test("session: id-less active payload (HA bridge copy) is adoptable, not malformed")
    func idlessPayloadAdoptable() {
        let created = Self.date(2026, 8, 13, 19, 45)
        let bed = Self.date(2026, 8, 13, 20, 0)
        let end = Self.date(2026, 8, 13, 22, 0)
        var payload = Self.activePayload(id: Self.idA, kid: "Bryson", type: .bedtime,
                                         created: created, bed: bed, end: end)
        payload.removeValue(forKey: "id")

        // No local session → adopted (with a synthesized id, so only the
        // schedule fields are comparable). Explicit `now` before sleep_end so
        // the expiry guard (al-cmd) doesn't turn this adopt into .ignore.
        let now = Self.date(2026, 8, 13, 21, 0)
        let action = SleepTimerSyncLogic.reconcileSession(local: nil, payload: payload, now: now)
        guard case .adopt(let adopted) = action else {
            Issue.record("expected .adopt, got \(action)")
            return
        }
        #expect(adopted.kidName == "Bryson")
        #expect(adopted.createdAt == created)
        #expect(adopted.bedTime == bed)
        #expect(adopted.sleepEnd == end)

        // Local session with the same schedule (the bridge copy of OUR
        // session) → equal created_at, no remote id → local wins and its
        // republish stamps the id onto the broker.
        let local = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                 created: created, bed: bed, end: end)
        #expect(SleepTimerSyncLogic.reconcileSession(local: local, payload: payload) == .republishLocal)
    }

    // MARK: - reconcileSession: active:false (newer-cancel-wins)

    @Test("cancel: cancelled_at newer than local created_at → clear and echo with ITS timestamp")
    func cancelNewerClears() {
        let local = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                 created: Self.date(2026, 8, 13, 19, 45),
                                 bed: Self.date(2026, 8, 13, 20, 0), end: Self.date(2026, 8, 13, 22, 0))
        let cancelledAt = Self.date(2026, 8, 13, 21, 0)
        #expect(SleepTimerSyncLogic.reconcileSession(local: local, payload: Self.cancelPayload(cancelledAt: cancelledAt))
                == .clearAndEchoCancel(cancelledAt: cancelledAt))
    }

    @Test("cancel: cancelled_at older than local created_at → local wins (republish)")
    func cancelOlderRepublishes() {
        let local = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                 created: Self.date(2026, 8, 13, 21, 0),
                                 bed: Self.date(2026, 8, 13, 20, 0), end: Self.date(2026, 8, 13, 22, 0))
        let cancelledAt = Self.date(2026, 8, 13, 19, 45)
        #expect(SleepTimerSyncLogic.reconcileSession(local: local, payload: Self.cancelPayload(cancelledAt: cancelledAt))
                == .republishLocal)
    }

    @Test("cancel: no local session → ignore (echo or stale retained cancel)")
    func cancelNoSessionIgnored() {
        #expect(SleepTimerSyncLogic.reconcileSession(local: nil,
                payload: Self.cancelPayload(cancelledAt: Self.date(2026, 8, 13, 21, 0))) == .ignore)
    }

    @Test("cancel: missing cancelled_at with a local session → treated as not-newer, republish")
    func cancelMissingTimestampRepublishes() {
        let local = Self.session(id: Self.idA, kid: "Bryson", type: .bedtime,
                                 created: Self.date(2026, 8, 13, 19, 45),
                                 bed: Self.date(2026, 8, 13, 20, 0), end: Self.date(2026, 8, 13, 22, 0))
        #expect(SleepTimerSyncLogic.reconcileSession(local: local, payload: Self.cancelPayload(cancelledAt: nil))
                == .republishLocal)
    }

    // MARK: - reconcileSession: malformed active:true → ignore

    @Test("malformed: a bad/missing required field on active:true is ignored, never clobbers local")
    func malformedActiveIgnored() {
        let created = Self.date(2026, 8, 13, 19, 45)
        let bed = Self.date(2026, 8, 13, 20, 0)
        let end = Self.date(2026, 8, 13, 22, 0)
        func base() -> [String: Any] {
            Self.activePayload(id: Self.idA, kid: "Bryson", type: .bedtime, created: created, bed: bed, end: end)
        }
        // (A missing or non-UUID id is NOT malformed — it's the adoptable
        // HA-bridge shape, covered by idlessPayloadAdoptable.)
        // Unknown type string.
        var p = base(); p["type"] = "siesta"
        #expect(SleepTimerSyncLogic.reconcileSession(local: nil, payload: p) == .ignore)
        // Empty kid.
        p = base(); p["kid"] = ""
        #expect(SleepTimerSyncLogic.reconcileSession(local: nil, payload: p) == .ignore)
        // Unparseable timestamp.
        p = base(); p["bed_time"] = "yesterday"
        #expect(SleepTimerSyncLogic.reconcileSession(local: nil, payload: p) == .ignore)
    }

    // MARK: - reconcileRoster

    @Test("roster: strictly newer → replace in remote order, drop removed kids' sessions")
    func rosterNewerReplaces() {
        let localUpdated = Self.date(2026, 8, 13, 18, 0)
        let remoteUpdated = Self.date(2026, 8, 13, 19, 0)
        // Local has Bryson + Ada; remote dropped Ada and reordered.
        let action = SleepTimerSyncLogic.reconcileRoster(
            localKids: ["Bryson", "Ada"], localUpdatedAt: localUpdated,
            payload: Self.rosterPayload(kids: ["Ezra", "Bryson"], updatedAt: remoteUpdated))
        #expect(action == .replace(kids: ["Ezra", "Bryson"], updatedAt: remoteUpdated, droppedSlugs: ["ada"]))
    }

    @Test("roster: newer but no kid removed → replace with empty droppedSlugs")
    func rosterNewerNoDrops() {
        let action = SleepTimerSyncLogic.reconcileRoster(
            localKids: ["Bryson"], localUpdatedAt: Self.date(2026, 8, 13, 18, 0),
            payload: Self.rosterPayload(kids: ["Bryson", "Ezra"], updatedAt: Self.date(2026, 8, 13, 19, 0)))
        #expect(action == .replace(kids: ["Bryson", "Ezra"],
                                   updatedAt: Self.date(2026, 8, 13, 19, 0), droppedSlugs: []))
    }

    @Test("roster: older/equal and memberships differ → republish local")
    func rosterOlderMismatchRepublishes() {
        // Remote is older and its members differ → our roster wins.
        let older = SleepTimerSyncLogic.reconcileRoster(
            localKids: ["Bryson", "Ada"], localUpdatedAt: Self.date(2026, 8, 13, 19, 0),
            payload: Self.rosterPayload(kids: ["Bryson"], updatedAt: Self.date(2026, 8, 13, 18, 0)))
        #expect(older == .republishLocal)
        // Equal timestamp, different members → also republish.
        let equal = SleepTimerSyncLogic.reconcileRoster(
            localKids: ["Bryson", "Ada"], localUpdatedAt: Self.date(2026, 8, 13, 19, 0),
            payload: Self.rosterPayload(kids: ["Bryson"], updatedAt: Self.date(2026, 8, 13, 19, 0)))
        #expect(equal == .republishLocal)
    }

    @Test("roster: older/equal and memberships match → no-op (the echo's fixed point)")
    func rosterIdenticalNoOp() {
        // Same members (order aside), remote not newer → nothing to do.
        let action = SleepTimerSyncLogic.reconcileRoster(
            localKids: ["Bryson", "Ada"], localUpdatedAt: Self.date(2026, 8, 13, 19, 0),
            payload: Self.rosterPayload(kids: ["Ada", "Bryson"], updatedAt: Self.date(2026, 8, 13, 19, 0)))
        #expect(action == .noOp)
    }

    @Test("roster: malformed payload (missing kids or updated_at) → ignore")
    func rosterMalformedIgnored() {
        // Missing updated_at.
        var p: [String: Any] = ["kids": ["Bryson"], "device": "phone-a"]
        #expect(SleepTimerSyncLogic.reconcileRoster(localKids: ["Bryson"],
                localUpdatedAt: Self.date(2026, 8, 13, 18, 0), payload: p) == .ignore)
        // kids not an array of strings.
        p = ["kids": "Bryson", "updated_at": ISO8601DateFormatter().string(from: Self.date(2026, 8, 13, 19, 0))]
        #expect(SleepTimerSyncLogic.reconcileRoster(localKids: ["Bryson"],
                localUpdatedAt: Self.date(2026, 8, 13, 18, 0), payload: p) == .ignore)
        // Unparseable updated_at.
        p = ["kids": ["Bryson"], "updated_at": "soon"]
        #expect(SleepTimerSyncLogic.reconcileRoster(localKids: ["Bryson"],
                localUpdatedAt: Self.date(2026, 8, 13, 18, 0), payload: p) == .ignore)
    }
}
