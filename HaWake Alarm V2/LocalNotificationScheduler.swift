//
//  LocalNotificationScheduler.swift
//  HaWake Alarm V2
//
//  Alarmy-style implementation with true mission enforcement
//

import Foundation
import UserNotifications
import SwiftUI
import SwiftData
import AVFoundation
import BackgroundTasks
import Combine


final class LocalNotificationScheduler: AlarmScheduler {
    static let shared = LocalNotificationScheduler()
    
    private let notificationCenter = UNUserNotificationCenter.current()
    private let backgroundAudio = BackgroundAudioKeepAlive.shared
    
    // Timer-based alarm firing — fires alarm even when willPresent doesn't get called
    // (willPresent only fires when app is in foreground; when screen is locked, app goes to background)
    private var alarmTimers: [Int: Timer] = [:]
    
    // Track snooze timers separately so they can be cancelled when alarm is edited/saved
    // Accessed by AlarmWindowManager.scheduleSnoozeNotification
    var snoozeTimers: [Int: Timer] = [:]

    // Radio stream prewarm timers, armed at fireDate−25s for radio alarms whose
    // fire timer (primary or snooze re-fire) is running while the app is alive.
    // Entirely separate from the fire timers — they only kick off a silent,
    // volume-0 prewarm on RadioAlarmStreamer and NEVER affect fire-timer logic.
    private var prewarmTimers: [Int: Timer] = [:]

    /// Lead time before fire to begin a silent stream prewarm.
    private let radioPrewarmLeadSeconds: TimeInterval = 25

    private init() {}
    
    /// Cancel the in-app Timer for a specific alarm hash.
    /// Called by AlarmKitScheduler when AlarmKit is primary and fires first,
    /// to prevent the Timer backup from double-firing.
    @MainActor
    func cancelTimer(for alarmIDHash: Int) {
        let hadTimer = alarmTimers[alarmIDHash] != nil
        alarmTimers[alarmIDHash]?.invalidate()
        alarmTimers.removeValue(forKey: alarmIDHash)
        if hadTimer {
            AppLogger.shared.log("Timer cancelled for alarm hash=\(alarmIDHash) (AlarmKit primary fired first)", category: .alarm)
        }
        // NOTE: deliberately do NOT cancel the prewarm here. This path only
        // means AlarmKit is firing the SAME alarm first — a live prewarm should
        // remain so beginAttempt() (in handleAlarmAlerting) can still adopt it.
    }

    /// Arm a silent stream prewarm at fireDate−25s for a radio alarm whose fire
    /// timer (primary or snooze re-fire) is running while the app is alive. When
    /// fire is <25s away we skip it and let the fire path attempt normally. The
    /// prewarm timer only calls RadioAlarmStreamer.prewarmAttempt — it can never
    /// affect the fire timer. Non-radio alarms never call this (urlString nil is
    /// a no-op guard anyway).
    @MainActor
    func scheduleRadioPrewarm(alarmIDHash: Int, fireInterval: TimeInterval,
                              stationID: String?, stationName: String?, urlString: String?) {
        // Cancel any existing prewarm timer for this alarm first.
        prewarmTimers[alarmIDHash]?.invalidate()
        prewarmTimers.removeValue(forKey: alarmIDHash)

        guard let urlString, !urlString.isEmpty else { return }
        let prewarmInterval = fireInterval - radioPrewarmLeadSeconds
        guard prewarmInterval > 0 else {
            // Fire is within the lead window — the fire path attempts normally.
            AppLogger.shared.log("Radio prewarm skipped (fire in \(Int(fireInterval))s < lead) hash=\(alarmIDHash)", category: .alarm)
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: prewarmInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                AppLogger.shared.log("Radio prewarm timer fired hash=\(alarmIDHash)", category: .alarm)
                RadioAlarmStreamer.shared.prewarmAttempt(
                    stationID: stationID,
                    stationName: stationName,
                    urlString: urlString
                )
            }
            Task { @MainActor [weak self] in
                self?.prewarmTimers.removeValue(forKey: alarmIDHash)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        prewarmTimers[alarmIDHash] = timer
        AppLogger.shared.log("Radio prewarm scheduled \(Int(prewarmInterval))s out (fire in \(Int(fireInterval))s) hash=\(alarmIDHash)", category: .alarm)
    }

    /// Cancel a radio prewarm timer and tear down any active prewarm for the
    /// alarm (alarm disabled / deleted / rescheduled / snooze cancelled). Safe
    /// for non-radio alarms (both are no-ops). cancelPrewarm() only acts while
    /// the streamer is actually prewarming, so this never disturbs a ringing or
    /// grace-held stream.
    @MainActor
    func cancelRadioPrewarm(for alarmIDHash: Int) {
        prewarmTimers[alarmIDHash]?.invalidate()
        prewarmTimers.removeValue(forKey: alarmIDHash)
        RadioAlarmStreamer.shared.cancelPrewarm()
    }

    func requestAuthorization() async -> Bool {
        do {
            // Request notification permissions
            // Note: .criticalAlert requires special entitlement from Apple
            // Start with regular notifications, then add .criticalAlert after approval
            let granted = try await notificationCenter.requestAuthorization(
                options: [.alert, .sound, .badge]  // Add .criticalAlert when approved
            )
            
            // Don't start background audio immediately - only when needed
            // This reduces app startup time
            // backgroundAudio.start() // Moved to only start when alarm is about to fire
            
            return granted
        } catch {
            print("Failed to request notification authorization: \(error)")
            return false
        }
    }
    
    @MainActor
    func scheduleAlarm(_ alarm: AppAlarm, delay: TimeInterval = 0) async {
        guard alarm.isEnabled else {
            await cancelAlarm(alarm)
            return
        }

        guard let nextFire = alarm.nextFireDate() else {
            await cancelAlarm(alarm)
            return
        }

        // Cancel any existing notifications
        await cancelAlarm(alarm)

        // Pre-warm the alarm sound for faster playback
        await AlarmSoundPlayer.shared.prewarm(soundID: alarm.soundName)

        // Check for debug quick-fire override
        #if DEBUG
        let debugQuickFire = DeviceSettings.shared.debugQuickAlarmEnabled
        let debugDelay = DeviceSettings.shared.debugQuickAlarmDelay
        #else
        let debugQuickFire = false
        let debugDelay = 0
        #endif

        let effectiveFireDate = debugQuickFire ? Date().addingTimeInterval(TimeInterval(debugDelay)) : nextFire.addingTimeInterval(delay)
        print("✅ Alarm scheduled for \(effectiveFireDate)\(delay > 0 ? " (backup, +\(Int(delay))s)" : "")")
        AppLogger.shared.log("Alarm scheduled: '\(alarm.label)' fires at \(effectiveFireDate)\(delay > 0 ? " (backup)" : "")", category: .alarm)

        // Store vibration preference for alarm notifications.
        // When fade-in is active, always vibrate — audio starts quiet but
        // the user still needs tactile feedback.
        let alarmVibrationEnabled = alarm.effectiveVibrationEnabled(settings: DeviceSettings.shared)
        let alarmFadeInEnabled = alarm.effectiveFadeInEnabled(settings: DeviceSettings.shared)
        AlarmLiveActivityManager.shared.vibrationEnabled = alarmVibrationEnabled || alarmFadeInEnabled
        
        // Schedule an in-app timer to fire the alarm directly.
        // This is critical because willPresent delegate does NOT fire when the
        // app is in background (screen locked). The timer fires because the app
        // stays alive via BackgroundAudioKeepAlive.
        let alarmIDHash = alarm.stableHash
        let alarmLabel = alarm.label
        let missionType = alarm.mission.type
        let soundID = alarm.soundName
        let alarmVolume = alarm.effectiveVolumeLevel(settings: DeviceSettings.shared)
        let alarmVibration = alarm.effectiveVibrationEnabled(settings: DeviceSettings.shared)
        let alarmFadeIn = alarm.effectiveFadeInEnabled(settings: DeviceSettings.shared)
        let alarmFadeInSeconds = alarm.effectiveFadeInDurationSeconds(settings: DeviceSettings.shared)
        let radioStationID = alarm.radioStationID
        let radioStationName = alarm.radioStationName
        let radioStationURL = alarm.radioStationURL

        // Cancel any existing timer for this alarm
        alarmTimers[alarmIDHash]?.invalidate()
        
        // In debug quick-fire mode, override the interval
        let fireInterval = debugQuickFire ? TimeInterval(debugDelay) : nextFire.addingTimeInterval(delay).timeIntervalSinceNow
        if fireInterval <= 0 {
            // Fire date is in the past. If it's within 60 seconds, fire immediately
            // rather than silently dropping the alarm. Beyond 60s it's a stale
            // schedule and AlarmKit failsafe should have already handled it.
            if fireInterval > -60 {
                print("⚠️ Alarm fire date is slightly past (\(Int(-fireInterval))s ago), firing immediately")
                AppLogger.shared.log("Alarm fire date past by \(Int(-fireInterval))s — firing immediately: '\(alarmLabel)'", category: .alarm)
                // Tier 1: (re)scheduling found the alarm already overdue — this
                // ring is a recovery, not the timer hitting its mark.
                AlarmRingReporter.shared.willDeliver(path: .launchRecovery, expectedFire: effectiveFireDate)
                DualAlarmCoordinator.shared.cancelFailsafe(for: alarmIDHash)
                let store = PendingAlarmStore.shared
                store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                    alarmID: alarmIDHash,
                    label: alarmLabel,
                    missionType: missionType,
                    soundID: soundID,
                    volumeLevel: alarmVolume
                )
                store.setPendingAlarmFull(
                    alarmID: alarmIDHash,
                    label: alarmLabel,
                    missionType: missionType.rawValue,
                    soundID: soundID,
                    volumeLevel: alarmVolume
                )
                store.setActiveRingingAlarm(alarmIDHash)
                AlarmWindowManager.shared.checkAndShowPendingAlarm()
            } else {
                print("⚠️ Alarm fire date is far in the past (\(Int(-fireInterval))s ago), skipping timer")
            }
            return
        }
        
        if debugQuickFire {
            print("=== DIAG === Setting up alarm timer: fires in \(Int(fireInterval))s (DEBUG QUICK FIRE)")
        } else {
            print("=== DIAG === Setting up alarm timer: fires in \(Int(fireInterval))s at \(nextFire)")
        }
        
        let timer = Timer.scheduledTimer(withTimeInterval: fireInterval, repeats: false) { [weak self] _ in
            print("=== DIAG === ⏰ ALARM TIMER FIRED at \(Date()) for: \(alarmLabel)")
            
            Task { @MainActor in
                AppLogger.shared.log("Alarm FIRED: '\(alarmLabel)' mission=\(missionType.rawValue) sound=\(soundID) vol=\(String(format: "%.0f%%", alarmVolume * 100)) vibration=\(alarmVibration)", category: .alarm)

                // Tier: the in-app timer hit the exact time — the healthy path.
                // Claimed before any audio work so the ring is timed from when
                // it SHOULD have rung, not from when the window appeared.
                AlarmRingReporter.shared.willDeliver(path: .primaryTimer, expectedFire: effectiveFireDate)

                // NOTE: the AlarmKit +5s failsafe is intentionally NOT canceled here.
                // It stays armed until audible playback is confirmed below, so a
                // failed play() (missing file, session error) still gets the
                // AlarmKit backup at +5s.

                // Store pending alarm info (in-memory AND UserDefaults for force-close recovery)
                let store = PendingAlarmStore.shared
                store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                    alarmID: alarmIDHash,
                    label: alarmLabel,
                    missionType: missionType,
                    soundID: soundID,
                    volumeLevel: alarmVolume
                )
                store.setPendingAlarmFull(
                    alarmID: alarmIDHash,
                    label: alarmLabel,
                    missionType: missionType.rawValue,
                    soundID: soundID,
                    volumeLevel: alarmVolume
                )
                // Set independent active ringing alarm key (survives force-close cycles)
                store.setActiveRingingAlarm(alarmIDHash)
                print("=== DIAG === Stored pendingAlarm from timer (memory + UserDefaults + activeRinging)")

                // al-3ox: is another alarm already on screen? Then showAlarm()
                // below will QUEUE this one, and none of the audio work is ours
                // to do — every step of it lands on the alarm the user is
                // actually looking at, because the volume, the player and the
                // radio streamer are all single-slot. Asked here, before any of
                // it, rather than inferred from showAlarm()'s early return: the
                // system-volume prep and the player unlock both run BEFORE
                // showAlarm() and cannot be moved after it (showAlarm must stay
                // behind the snoozed/dismissed guard), so a return value from
                // showAlarm would arrive too late to stop them.
                let audio = AlarmFireAudioResolution.resolve(
                    firingAlarmID: alarmIDHash,
                    isShowingAlarm: AlarmWindowManager.shared.isShowingAlarm,
                    showingAlarmID: AlarmWindowManager.shared.currentAlarmID
                )
                if audio.queuedBehindShowingAlarm {
                    AppLogger.shared.log("Alarm FIRED while another is showing — audio left to the showing alarm: '\(alarmLabel)'", category: .alarm)
                }

                // Configure audio session FIRST — vibration and volume changes
                // need an active audio session to work from the lock screen.
                // (Skipped for a queued alarm: the showing alarm's session is
                // already active and configured, and re-activating a live one is
                // risk with no benefit for an alarm that will not make a sound.)
                if audio.runsAudioPipeline {
                    do {
                        let audioSession = AVAudioSession.sharedInstance()
                        if audioSession.category != .playAndRecord {
                            try AppAudioSession.setCategory(.playAndRecord, mode: .default, options: AppAudioSession.alarmFireCategoryOptions())
                        }
                        try AppAudioSession.setActive(true)
                    } catch {
                        print("⚠️ Audio session setup failed: \(error) — will try to play anyway")
                    }
                }

                // Start recurring alarm notifications for lock-screen presence and vibration.
                // When fade-in is active, always vibrate — the audio starts quiet but
                // the user still needs tactile feedback to know the alarm is firing.
                // In AlarmKit mode this timer path rarely fires (AlarmKit cancels the timer),
                // but set suppress flag as a safety net.
                AlarmLiveActivityManager.shared.vibrationEnabled = alarmVibration || alarmFadeIn
                AlarmLiveActivityManager.shared.suppressLockScreenNotifications = false
                AlarmLiveActivityManager.shared.startAlarmNotifications(
                    alarmLabel: alarmLabel,
                    alarmID: alarmIDHash
                )
                
                let settings = DeviceSettings.shared

                if audio.runsAudioPipeline {
                    // Set system volume to target immediately (before playback starts)
                    if alarmFadeIn {
                        VolumeManager.shared.prepareForFadeIn(to: Float(alarmVolume))
                    } else {
                        VolumeManager.shared.setSystemVolume(to: Float(alarmVolume))
                    }

                    // Unlock if alarm is still actively ringing (not snoozed/dismissed).
                    // unlockIfRinging() checks activeRingingAlarmID which is cleared
                    // synchronously by snooze/dismiss, catching the race.
                    guard AlarmSoundPlayer.shared.unlockIfRinging() else {
                        print("[ALARM-STATE] Timer alarm: sound skipped — alarm already snoozed/dismissed")
                        // Alarm was snoozed/dismissed before sound started — drop the
                        // +5s failsafe (parity with the snooze/dismiss flows).
                        DualAlarmCoordinator.shared.cancelFailsafe(for: alarmIDHash)
                        return
                    }
                } else if audio.cancelsRadioPrewarm {
                    // The player stays LOCKED for a queued alarm — that unlock was
                    // the whole of al-bee.2: while the showing alarm sits in a
                    // mission grace period its wav is stopped (and so locked), its
                    // radio stream is held silent, and beginAttempt() is refused by
                    // the isGracePeriodMuted guard — but unlockIfRinging() reads the
                    // GLOBAL ringing flag, which this fire just took, so the queued
                    // alarm's tone started into the deliberate silence.
                    //
                    // Its prewarm goes too: there is no fire here to adopt it, and a
                    // silent AVPlayer left streaming for the length of the showing
                    // alarm's missions is cellular data and battery for nothing.
                    // cancelPrewarm() is a no-op unless a prewarm is actually in
                    // flight, so it can never disturb the showing alarm's stream;
                    // presentDequeuedAlarm() attempts the station fresh.
                    RadioAlarmStreamer.shared.cancelPrewarm()
                }
                // Present the alarm UI BEFORE any audio work. Everything below
                // this point is either synchronous main-actor work that blocks
                // the run loop (AVAudioSession reconfiguration, AVAudioPlayer
                // construction inside play()) or a deliberate wait (the 1s silent
                // entry plus the radio confirmation grace). Leaving showAlarm()
                // at the tail meant a radio alarm could not paint its screen for
                // ~4.5s at best, and far longer when this task was queued behind
                // a foreground reschedule/MQTT burst — the user saw a ~15s gap
                // with the app already open. Presentation owes nothing to audio,
                // so it goes first; the window is idempotent and the ringing
                // state it reads is already committed to the store above.
                AlarmWindowManager.shared.showAlarm(
                    alarmID: alarmIDHash,
                    label: alarmLabel,
                    missionType: missionType,
                    soundID: soundID,
                    startSoundIfNeeded: false
                )

                // Everything below is the audio pipeline proper, and it belongs
                // to the alarm on screen — never to one that was just queued
                // (al-3ox). play() alone would tear down the showing alarm's
                // confirmed radio stream and start this alarm's tone; the fade
                // arm below would re-ramp a ring already minutes into its own.
                if audio.runsAudioPipeline {
                    // Always start at player volume 0 — 1-second silent entry before
                    // the full volume (or fade-in ramp) kicks in.
                    await AlarmSoundPlayer.shared.play(soundID: soundID, initialVolume: 0.0)
                    if AlarmSoundPlayer.shared.isPlaying {
                        // Audible playback established — safe to drop the +5s AlarmKit failsafe.
                        DualAlarmCoordinator.shared.cancelFailsafe(for: alarmIDHash)
                        AlarmRingReporter.shared.audioStarted()
                    }
                    // Re-check after play — snooze may have run during the await
                    guard AlarmWindowManager.shared.isShowingAlarm || PendingAlarmStore.shared.activeRingingAlarmID() != nil else {
                        print("[ALARM-STATE] Timer alarm: dismissed during play — stopping")
                        AlarmSoundPlayer.shared.stop()
                        return
                    }
                    // Radio layer: start the stream attempt DURING the silent
                    // entry so a healthy stream cuts in before the tone is ever
                    // heard. The tone stays the guaranteed wake-up: the extra
                    // grace below is capped, and the failsafe logic above is
                    // untouched (the wav is playing — silently — this whole time).
                    RadioAlarmStreamer.shared.beginAttempt(
                        stationID: radioStationID,
                        stationName: radioStationName,
                        urlString: radioStationURL
                    )
                    try? await Task.sleep(for: .seconds(1))
                    if radioStationURL != nil {
                        // Grace is tiered by how far along the stream already is —
                        // 0s for an adopted confirmed prewarm, longer for one still
                        // buffering, short for a cold start. See confirmationGrace.
                        await RadioAlarmStreamer.shared.waitForConfirmation(
                            upTo: RadioAlarmStreamer.shared.confirmationGrace
                        )
                    }
                    // Same post-await guard as the AlarmKit path: a fast dismiss
                    // during the silent entry / radio grace must not arm a fade (or
                    // raise volume) for a ring that no longer exists.
                    guard PendingAlarmStore.shared.activeRingingAlarmID() != nil else {
                        AppLogger.shared.log("Timer fire: dismissed during silent entry — skipping fade/volume raise", category: .audio)
                        return
                    }
                    // If the stream confirmed, this volume raise routes to the
                    // radio player and the wav stays muted (setPlayerVolume).
                    if alarmFadeIn {
                        VolumeManager.shared.startPlayerFadeInIfNeeded(duration: alarmFadeInSeconds)
                    } else if VolumeManager.shared.fadeActive {
                        // Same rule as the AlarmKit handler: never let a "no fade"
                        // branch stomp a ramp another path already armed for this ring.
                        VolumeManager.shared.ensureFadeRunning()
                    } else {
                        AlarmSoundPlayer.shared.setPlayerVolume(1.0)
                    }

                    // If playback failed (intermittent '!int' error), retry after a short delay
                    if !AlarmSoundPlayer.shared.isPlaying {
                        print("=== DIAG === First play attempt failed, retrying in 0.5s...")
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        await AlarmSoundPlayer.shared.play(soundID: soundID, initialVolume: 0.0)
                        if AlarmSoundPlayer.shared.isPlaying {
                            print("=== DIAG === Retry succeeded!")
                            // The volume-raise block above ran against the dead first
                            // player — re-apply it so the replacement player doesn't
                            // stay at volume 0 forever while isPlaying reads healthy.
                            if alarmFadeIn {
                                VolumeManager.shared.ensureFadeRunning()
                            } else {
                                AlarmSoundPlayer.shared.setPlayerVolume(1.0)
                            }
                            DualAlarmCoordinator.shared.cancelFailsafe(for: alarmIDHash)
                            AlarmRingReporter.shared.audioStarted()
                            // First play failed, so the earlier beginAttempt was a
                            // no-op (it guards on shouldBePlaying) — start the
                            // stream attempt now that the tone is up.
                            RadioAlarmStreamer.shared.beginAttempt(
                                stationID: radioStationID,
                                stationName: radioStationName,
                                urlString: radioStationURL
                            )
                        } else {
                            print("=== DIAG === Retry also failed — leaving AlarmKit +5s failsafe armed")
                            // Both attempts failed: the alarm is "ringing" with no
                            // confirmed audio. Worth its own event — the AlarmKit
                            // failsafe left armed above is the only thing that will
                            // actually wake the user.
                            AlarmRingReporter.shared.audioFailed()
                            // Clear fade state so the failsafe's alerting isn't
                            // swallowed by the duplicate guard (fadeActiveSnapshot).
                            VolumeManager.shared.cancelFadeIn()
                        }
                    }
                } else {
                    // Queued: no audio, so there is no playback to confirm and
                    // nothing to keep the +5s AlarmKit failsafe waiting for. See
                    // AlarmFireAudioResolution.cancelsAlarmKitFailsafeImmediately
                    // for why cancelling is parity with today AND the safer of the
                    // two options — an alert reaching .alerting interrupts the
                    // showing alarm's audio session, and the duplicate guard would
                    // suppress it on arrival anyway.
                    if audio.cancelsAlarmKitFailsafeImmediately {
                        DualAlarmCoordinator.shared.cancelFailsafe(for: alarmIDHash)
                    }
                }

                if settings.mqttEnabled && !alarm.excludeFromMQTT {
                    HAIntegrationRouter.shared.publishAlarmState(.ringing, settings: settings)
                    HAIntegrationRouter.shared.publishSnoozeCount(0, settings: settings)
                    HAIntegrationRouter.shared.publishSnoozesRemaining(0, settings: settings)
                }

                // Alarm UI was already presented before the audio work above.
                // Re-assert it here as a cheap safety net: showAlarm() is
                // idempotent, and this covers the narrow case where the window
                // could not be created on the first call (e.g. no active scene
                // yet). If it still cannot show, checkAndShowPendingAlarm picks
                // it up on unlock exactly as before.
                AlarmWindowManager.shared.showAlarm(
                    alarmID: alarmIDHash,
                    label: alarmLabel,
                    missionType: missionType,
                    soundID: soundID
                )
            }
            
            // Clean up timer reference
            Task { @MainActor [weak self] in
                self?.alarmTimers.removeValue(forKey: alarmIDHash)
            }
        }
        
        // Ensure the timer runs even in background by adding to common run loop mode
        RunLoop.main.add(timer, forMode: .common)
        alarmTimers[alarmIDHash] = timer

        // Radio prewarm: for a radio alarm whose fire is >25s out, silently
        // start the stream ~25s early so it's already confirmed at fire and
        // takes over instantly. Skipped for non-radio alarms; never affects the
        // fire timer or the tone/failsafe pipeline.
        scheduleRadioPrewarm(
            alarmIDHash: alarmIDHash,
            fireInterval: fireInterval,
            stationID: radioStationID,
            stationName: radioStationName,
            urlString: radioStationURL
        )
    }

    @MainActor
    func cancelAlarm(_ alarm: AppAlarm) async {
        // Cancel in-app timer
        let alarmIDHash = alarm.stableHash
        alarmTimers[alarmIDHash]?.invalidate()
        alarmTimers.removeValue(forKey: alarmIDHash)

        // Cancel any radio prewarm timer + tear down an active prewarm.
        cancelRadioPrewarm(for: alarmIDHash)

        // Only stop alarm notifications if THIS alarm is the one currently ringing.
        // Previously this was unconditional, which meant cancelling alarm B while
        // alarm A was ringing would kill A's vibration and lock-screen notifications.
        if let currentAlarm = AlarmWindowManager.shared.currentAlarm,
           currentAlarm.stableHash == alarmIDHash {
            AlarmLiveActivityManager.shared.stopAlarmNotifications()
        }
        
        print("✅ Cancelled alarm timer for \(alarm.label)")
        AppLogger.shared.log("Alarm cancelled: '\(alarm.label)' hash=\(alarmIDHash)", category: .alarm)
    }
    
    /// Cancel any active snooze notification and timer for the given alarm.
    /// Call this when saving alarm edits to clear lingering snooze state.
    @MainActor
    func cancelSnooze(for alarm: AppAlarm) {
        let alarmIDHash = alarm.stableHash
        let hadSnoozeTimer = snoozeTimers[alarmIDHash] != nil

        // Cancel snooze timer
        snoozeTimers[alarmIDHash]?.invalidate()
        snoozeTimers.removeValue(forKey: alarmIDHash)

        // Cancel any radio prewarm timer + tear down an active prewarm.
        cancelRadioPrewarm(for: alarmIDHash)

        // Stop alarm sound if currently playing
        AlarmSoundPlayer.shared.stop()

        // Clear any pending alarm store state for this alarm
        if let pending = PendingAlarmStore.shared.pendingAlarm, pending.alarmID == alarmIDHash {
            PendingAlarmStore.shared.pendingAlarm = nil
        }

        // Remove from alarm queue if queued
        AlarmWindowManager.shared.removeFromQueue(alarmID: alarmIDHash)

        // Cancel AlarmKit snooze failsafe
        AlarmKitScheduler.shared.cancelSnoozeFailsafe(forAlarmHash: alarmIDHash)

        print("✅ Cancelled snooze notification and timer for alarm \(alarmIDHash)")
        AppLogger.shared.log("Snooze cancelled: '\(alarm.label)' hash=\(alarmIDHash) hadTimer=\(hadSnoozeTimer)", category: .alarm)
    }
    
    func cancelAllAlarms() async {
        // Cancel all in-app timers
        for (_, timer) in alarmTimers {
            timer.invalidate()
        }
        alarmTimers.removeAll()

        // Cancel all snooze timers
        for (_, timer) in snoozeTimers {
            timer.invalidate()
        }
        snoozeTimers.removeAll()

        // Cancel all radio prewarm timers + tear down any active prewarm.
        for (_, timer) in prewarmTimers {
            timer.invalidate()
        }
        prewarmTimers.removeAll()
        RadioAlarmStreamer.shared.cancelPrewarm()

        // Clear the alarm queue
        AlarmWindowManager.shared.clearQueue()

        print("✅ Cancelled all alarm notifications and timers")
        AppLogger.shared.log("All alarm timers cancelled", category: .alarm)
    }
    
    // MARK: - Private Methods
    
}

// MARK: - Background Audio Keep-Alive

/// Whether the keep-alive should stand down for an active sleep sound, and
/// how. Pure so the branchy coverage check can be tested without an audio
/// engine (al-cbf): "sleep sounds active" is only a reason to defer when the
/// sleep engine is genuinely covering the session; a phantom active state
/// (engine torn down by an interruption, state stuck at .paused) must not keep
/// the keep-alive deferred forever with no coverage.
enum KeepAliveSleepDecision: Equatable {
    /// Sleep sounds hold the session with live coverage — do not stomp it.
    case deferToSleep
    /// Sleep claims active but nothing is covering the session — try to
    /// reassert its ownership, then re-decide against the fresh coverage.
    case reassertThenRecheck
    /// Sleep is not covering the session — start the keep-alive.
    case startKeepAlive

    static func decide(sleepActive: Bool, hasLiveCoverage: Bool) -> KeepAliveSleepDecision {
        guard sleepActive else { return .startKeepAlive }
        return hasLiveCoverage ? .deferToSleep : .reassertThenRecheck
    }
}

/// Plays silent audio in background to prevent app suspension
final class BackgroundAudioKeepAlive {
    static let shared = BackgroundAudioKeepAlive()
    
    private var audioPlayer: AVAudioPlayer?
    private(set) var isRunning = false
    private var healthCheckTimer: Timer?
    /// Incremented by stop(). An in-flight startAsync() compares against it
    /// (on the main actor) so a start that was superseded by a stop — e.g.
    /// SleepSoundManager taking over the session — discards itself instead of
    /// re-applying .mixWithOthers over the new owner's session.
    private var startGeneration = 0

    /// Coalesces rapid App Persistence changes. A burst — dragging the mode
    /// control off/on/dynamic/off, or a run of `app_persistence` MQTT commands —
    /// otherwise tears the keep-alive audio session down and rebuilds it several
    /// times in a row. That rapid `setActive(false)`→`setActive(true)` churn is
    /// where an externally-set system volume (e.g. Home Assistant's
    /// `set_system_volume`) can get reverted by the OS. Debouncing applies only
    /// the final settled state, so a burst causes one transition, not several.
    private var persistenceDebounce: Task<Void, Never>?
    private static let persistenceDebounceDelay: UInt64 = 350_000_000  // 350 ms

    static let bgTaskIdentifier = "com.hawake.keepalive-refresh"

    /// True while any audio interruption (phone call, Siri, alarm from another app)
    /// is in progress. Both BackgroundAudioKeepAlive and SleepSoundManager write this
    /// so applicationWillTerminate can suppress the "Oops, you closed the app!" alert
    /// when the termination was actually caused by iOS reclaiming resources during a call.
    nonisolated(unsafe) static var isAudioSessionInterrupted: Bool = false
    
    private init() {
        // Restart when a media app (Facebook, Spotify, etc.) stops playing and
        // releases the audio session — fired even while the app is backgrounded.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSilenceHint),
            name: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: AVAudioSession.sharedInstance()
        )
        // Restart after phone calls, Siri, alarm audio interruptions, etc.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    // MARK: - Silence hint (fast path while app is backgrounded but not suspended)

    @objc private func handleSilenceHint(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: typeValue) else { return }
        guard isRunning else { return }

        switch type {
        case .begin:
            // A primary audio app (Facebook, Spotify, etc.) started playing.
            // Mute the keep-alive player to zero so our .playback session doesn't
            // interfere with AirPods routing or the other app's audio controls.
            // We intentionally do NOT stop the player — stopping would deactivate our
            // .playback audio session, which is the only thing keeping the app alive
            // in the background. With .mixWithOthers, both sessions coexist; we just
            // go silent so the user's media app has full audio routing priority.
            audioPlayer?.volume = 0.0
            print("🔇 BackgroundAudioKeepAlive: primary audio started — muting keep-alive")
            AppLogger.shared.log("BackgroundAudioKeepAlive: muted (primary audio began)", category: .audio)

        case .end:
            // Primary audio stopped — restore near-silent volume.
            // Also clear the interrupted flag in case the primary app never sent
            // interruptionNotification(.ended).
            BackgroundAudioKeepAlive.isAudioSessionInterrupted = false
            if audioPlayer?.isPlaying ?? false {
                // Player is still running (just muted) — simply restore volume.
                audioPlayer?.volume = 0.01
                print("🔊 BackgroundAudioKeepAlive: primary audio ended — restoring keep-alive volume")
                AppLogger.shared.log("BackgroundAudioKeepAlive: unmuted (primary audio ended)", category: .audio)
            } else {
                // Player actually stopped (e.g. audio interruption during the muted window).
                // Restart it after a short delay to let the primary app's session fully release.
                print("✅ BackgroundAudioKeepAlive: primary audio ended, player stopped — restarting")
                AppLogger.shared.log("BackgroundAudioKeepAlive: restarting after primary audio ended", category: .audio)
                Task.detached(priority: .utility) {
                    try? await Task.sleep(nanoseconds: 750_000_000) // 0.75s
                    await self.startAsync()
                }
            }

        @unknown default:
            break
        }
    }

    // MARK: - BGAppRefreshTask (wake ladder + safety net when app was suspended)

    /// Re-aims the single pending BGAppRefreshTask request for the current
    /// mode. `.on` → +15 min heartbeat (the historical safety net); `.dynamic`
    /// → stepped toward the pre-alarm window per
    /// `PersistenceResidencyResolution.ladderEarliestBeginDate` — submitted
    /// UNCONDITIONALLY (charging and Low Power Mode are never gates: an
    /// unsubmitted task cannot fire when conditions improve); `.off` → nothing
    /// is submitted. Callable from any thread; the alarm-date lookup needs the
    /// MainActor, so this hops.
    func scheduleBackgroundRefresh() {
        Task { @MainActor in
            let mode = DeviceSettings.shared.appPersistenceMode
            let nextFire = mode == .dynamic
                ? DynamicPersistenceController.shared.currentNextFireDate()
                : nil
            guard let earliest = PersistenceResidencyResolution.ladderEarliestBeginDate(
                mode: mode, nextFireDate: nextFire
            ) else { return }
            self.submitBackgroundRefresh(earliestBeginDate: earliest, nextFireDate: nextFire)
        }
    }

    /// Submit (or replace — same identifier) the pending refresh request.
    func submitBackgroundRefresh(earliestBeginDate: Date, nextFireDate: Date? = nil) {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskIdentifier)
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
            // Only Dynamic submissions are ladder telemetry — recording the
            // .on heartbeat would be ~100 noise rows a night.
            if DeviceSettings.shared.appPersistenceMode == .dynamic {
                WakeAttemptStore.shared.recordLadderSubmit(
                    requestedBegin: earliestBeginDate, nextFireDate: nextFireDate
                )
            }
        } catch {
            // BGTaskSchedulerErrorCodeNotPermitted if user disabled Background App Refresh —
            // that is fine; the interruption handler still works while the app runs.
            print("⚠️ BackgroundAudioKeepAlive: could not schedule refresh task — \(error)")
        }
    }

    /// Called by AppDelegate's BGTaskScheduler handler when the OS wakes us up.
    func handleBackgroundRefreshTask(_ task: BGAppRefreshTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        Task { @MainActor in
            switch DeviceSettings.shared.appPersistenceMode {
            case .off:
                // Mode flipped to Off after this request was submitted —
                // do nothing, resubmit nothing, and the ladder ends here.
                task.setTaskCompleted(success: true)
            case .on:
                // Historical safety net: reschedule the next heartbeat FIRST
                // so a slot is never missed, then restart keep-alive if it
                // died while the app was suspended.
                self.scheduleBackgroundRefresh()
                if DeviceSettings.shared.keepAliveNeeded {
                    await self.startAsync()
                }
                task.setTaskCompleted(success: true)
            case .dynamic:
                // The wake ladder: classify, activate or resubmit, record.
                await DynamicPersistenceController.shared.handleLadderWake()
                task.setTaskCompleted(success: true)
            }
        }
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            BackgroundAudioKeepAlive.isAudioSessionInterrupted = true
            print("⚠️ BackgroundAudioKeepAlive: audio interrupted")
            AppLogger.shared.log("BackgroundAudioKeepAlive: audio interrupted", category: .audio)
        case .ended:
            BackgroundAudioKeepAlive.isAudioSessionInterrupted = false
            print("✅ BackgroundAudioKeepAlive: interruption ended, checking if restart needed")
            AppLogger.shared.log("BackgroundAudioKeepAlive: interruption ended, checking restart", category: .audio)
            // If we were running before the interruption, restart.
            // But only if no alarm sound is currently playing (AlarmSoundPlayer
            // will restart us when it stops).
            if isRunning && DeviceSettings.shared.keepAliveNeeded {
                Task { @MainActor in
                    let alarmPlaying = AlarmSoundPlayer.shared.shouldBePlaying
                    if !alarmPlaying {
                        print("✅ BackgroundAudioKeepAlive: restarting after interruption")
                        AppLogger.shared.log("BackgroundAudioKeepAlive: restarting after interruption", category: .audio)
                        Task.detached(priority: .utility) {
                            // Brief delay — some interruptors (phone apps, Siri) hold the
                            // audio session open briefly after sending .ended. Waiting avoids
                            // a silent setActive(true) failure on the first attempt.
                            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                            await self.startAsync()
                        }
                    } else {
                        print("ℹ️ BackgroundAudioKeepAlive: alarm sound active, will restart when it stops")
                        AppLogger.shared.log("BackgroundAudioKeepAlive: alarm sound active, deferring restart", category: .audio)
                    }
                }
            } else if !DeviceSettings.shared.keepAliveNeeded {
                print("ℹ️ BackgroundAudioKeepAlive: App Persistence disabled, not restarting")
            }
        @unknown default:
            break
        }
    }
    
    /// Asynchronous version for app launch - doesn't block main thread.
    func startAsync() async {
        // Never touch the session while an alarm is (or should be) sounding.
        // Callers like SleepSoundManager.handleAlarmWillFire() restart keep-alive
        // from a detached task right as an alarm fires; re-applying .playback
        // here would revert the alarm's .playAndRecord category and drop its
        // speaker override mid-ring. AlarmSoundPlayer.stop() clears
        // shouldBePlaying before restarting keep-alive, so the legitimate
        // after-alarm restart is unaffected.
        let (alarmActive, sleepActive, sleepCoverage, radioActive, myGeneration) = await MainActor.run {
            (AlarmSoundPlayer.shared.shouldBePlaying,
             SleepSoundManager.shared.isActive,
             SleepSoundManager.shared.hasLiveCoverage,
             RadioPlayerManager.shared.ownsAudioSession,
             self.startGeneration)
        }
        if alarmActive {
            AppLogger.shared.log("BackgroundAudioKeepAlive: alarm sounding — deferring start to avoid session stomp", category: .audio)
            return
        }
        // Radio playback owns a non-mixable .playback session for the same
        // Now Playing reason as sleep sounds — stomping it kills media controls.
        if radioActive {
            AppLogger.shared.log("BackgroundAudioKeepAlive: radio playing — deferring start to avoid session stomp", category: .audio)
            return
        }
        // Sleep sounds own the audio session while active — including .paused,
        // where the engine keeps running silently AS the keep-alive. Their
        // session is non-mixable .playback on purpose: that is what makes the
        // app eligible for the lock-screen / Dynamic Island Now Playing
        // controls. Re-applying .mixWithOthers here would silently revoke that
        // eligibility (a mixable session is never the Now Playing app) — the
        // cause of intermittently missing media controls.
        //
        // BUT "active" is not the same as "covered": an interruption can tear
        // the engine down and leave state stuck at .paused over a dead session
        // (al-cbf). Deferring on that phantom leaves the app with NO audio
        // coverage while backgrounded with an alarm armed. Only defer when the
        // sleep engine is genuinely running, or an interruption is in progress
        // (recovery lands at `.ended`). Otherwise reassert its ownership; if
        // that still can't bring the engine up, fall through and start the
        // keep-alive rather than leave the session uncovered.
        switch KeepAliveSleepDecision.decide(sleepActive: sleepActive, hasLiveCoverage: sleepCoverage) {
        case .startKeepAlive:
            break
        case .deferToSleep:
            AppLogger.shared.log("BackgroundAudioKeepAlive: sleep sounds active with live coverage — deferring start to avoid session stomp", category: .audio)
            return
        case .reassertThenRecheck:
            let recovered = await MainActor.run { () -> Bool in
                SleepSoundManager.shared.reassertSessionOwnership()
                return SleepSoundManager.shared.hasLiveCoverage
            }
            if recovered {
                AppLogger.shared.log("BackgroundAudioKeepAlive: sleep sounds active — session reasserted, deferring start", category: .audio)
                return
            }
            AppLogger.shared.log("BackgroundAudioKeepAlive: sleep claims active but no live coverage after reassert — starting keep-alive", category: .audio)
        }

        // Always re-apply the keep-alive category BEFORE the early-exit check.
        // Another caller (AlarmSoundPlayer, phone call, Siri) may
        // have switched the shared session to .playAndRecord + .defaultToSpeaker
        // — which forces output through the built-in speaker and breaks
        // Bluetooth / CarPlay routing. Our silent player can keep running under
        // that category because .mixWithOthers is preserved, so the old
        // early-exit would return with the session still stuck on .playAndRecord
        // after the interrupting source finished. Re-applying here makes
        // startAsync() idempotent for category state, not just for player state.
        // Re-checked against generation + sleep state because the entry check
        // above ran in an earlier main-actor hop.
        // Gate on live coverage, not bare `isActive`: the decision above may
        // have deliberately chosen to proceed while sleep state is still
        // .paused-but-uncovered (al-cbf). A genuinely covered sleep session
        // (engine running, or interruption in progress) still aborts here.
        let categoryApplied = await MainActor.run { () -> Bool in
            guard self.startGeneration == myGeneration,
                  !SleepSoundManager.shared.hasLiveCoverage,
                  !RadioPlayerManager.shared.ownsAudioSession else { return false }
            do {
                try AppAudioSession.setCategory(
                    .playback, mode: .default, options: [.mixWithOthers]
                )
            } catch {
                AppLogger.shared.log(
                    "BackgroundAudioKeepAlive: category re-apply failed — \(error)",
                    category: .audio
                )
            }
            return true
        }
        guard categoryApplied else {
            AppLogger.shared.log("BackgroundAudioKeepAlive: start superseded before category apply — aborting", category: .audio)
            return
        }

        // If already running and player is actually playing, skip
        if isRunning, let player = audioPlayer, player.isPlaying {
            return
        }
        // Reset state if player stopped unexpectedly (e.g., audio interruption)
        isRunning = false
        
        // Create the keep-alive audio file if it doesn't exist yet.
        await createKeepAliveAudioFileAsync()
        
        guard let url = getKeepAliveAudioURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            print("❌ Keep-alive audio file not available")
            AppLogger.shared.log("BackgroundAudioKeepAlive: audio file unavailable", category: .audio)
            return
        }
        
        // Move to main thread for audio session setup.
        // Also request background execution time as a safety net while we restart
        // audio — this gives ~30 seconds of guaranteed execution even if the audio
        // player momentarily stops, preventing iOS from suspending the app mid-restart.
        await MainActor.run {
            // Final staleness check: file creation above can take time on first
            // launch, and a sleep-sound start (which stops us and takes the
            // session) may have happened since the checks at entry.
            guard self.startGeneration == myGeneration,
                  !AlarmSoundPlayer.shared.shouldBePlaying,
                  !SleepSoundManager.shared.hasLiveCoverage,
                  !RadioPlayerManager.shared.ownsAudioSession else {
                AppLogger.shared.log("BackgroundAudioKeepAlive: start superseded before player setup — aborting", category: .audio)
                return
            }

            let bgTask = UIApplication.shared.beginBackgroundTask {
                AppLogger.shared.log("BackgroundAudioKeepAlive: background task expired", category: .audio)
            }

            do {
                // Configure audio session for background keep-alive.
                // Must use .playback (not .ambient) — only .playback grants background
                // audio execution via UIBackgroundModes:audio. .ambient is silenced by
                // iOS in the background and cannot keep the app alive.
                // .mixWithOthers lets Facebook, Spotify, etc. play alongside us without
                // interruption. When a primary media app starts, we mute the player to
                // 0.0 (via handleSilenceHint) so there is no audible or routing conflict;
                // when it stops we restore volume to 0.01.
                try AppAudioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try AppAudioSession.setActive(true)
                
                // Create and configure audio player
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.numberOfLoops = -1  // Loop forever
                audioPlayer?.volume = 0.01  // Nearly silent (can't be 0.0)
                audioPlayer?.prepareToPlay()
                let started = audioPlayer?.play() ?? false
                
                if started {
                    isRunning = true
                    print("✅ Background audio started asynchronously - app will stay alive")
                    AppLogger.shared.log("BackgroundAudioKeepAlive: started successfully", category: .audio)
                } else {
                    print("❌ Background audio player.play() returned false (async)")
                    AppLogger.shared.log("BackgroundAudioKeepAlive: player.play() returned false", category: .audio)
                    audioPlayer = nil
                }
            } catch {
                print("❌ Failed to start background audio: \(error)")
                AppLogger.shared.log("BackgroundAudioKeepAlive: failed to start: \(error)", category: .audio)
            }
            
            UIApplication.shared.endBackgroundTask(bgTask)
        }
    }
    
    /// Legacy synchronous version - kept for compatibility but should use startAsync()
    func start() {
        guard !isRunning else { return }
        
        createKeepAliveAudioFile()
        
        guard let url = getKeepAliveAudioURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            print("❌ Keep-alive audio file not available")
            return
        }
        
        do {
            // Use .playback + .mixWithOthers (see startAsync for rationale)
            try AppAudioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AppAudioSession.setActive(true)

            // Create and configure audio player
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1  // Loop forever
            audioPlayer?.volume = 0.01
            audioPlayer?.prepareToPlay()
            let started = audioPlayer?.play() ?? false
            
            if started {
                isRunning = true
                print("✅ Background audio started - app will stay alive")
            } else {
                print("❌ Background audio player.play() returned false")
                audioPlayer = nil
            }
        } catch {
            print("❌ Failed to start background audio: \(error)")
        }
    }
    
    /// Stop the keep-alive player.
    ///
    /// Pass `deactivateSession: false` when the caller is about to immediately
    /// reuse the audio session (e.g. SleepSoundManager starting a new engine).
    /// Keeping the session active prevents iOS from suspending the app in the
    /// background during the handoff window between stop and the new engine start.
    func stop(deactivateSession: Bool = true) {
        startGeneration += 1   // cancels any in-flight startAsync()
        audioPlayer?.stop()
        audioPlayer = nil
        isRunning = false
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        if deactivateSession {
            // DEACTIVATE FIRST, then revert the category — and never let one
            // failure hide the other.
            //
            // This used to be `try? setCategory(.ambient)` followed by
            // `_ = try? setActive(false, …)`. Setting the category on a session
            // that is still active can throw, and `try?` swallowed it silently:
            // the session deactivated (so the shadow flipped to false and looked
            // correct) while the category stayed `.playback`, leaving the app
            // still advertising itself as a background-audio app. Deactivating
            // first is also what the category change wants — configuring a
            // category is reliable on an INACTIVE session.
            do {
                _ = try AppAudioSession.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                AppLogger.shared.log("BackgroundAudioKeepAlive: setActive(false) FAILED — \(error)", category: .audio)
            }
            do {
                try AppAudioSession.setCategory(.ambient)
            } catch {
                AppLogger.shared.log("BackgroundAudioKeepAlive: setCategory(.ambient) FAILED — \(error)", category: .audio)
            }
            let category = AVAudioSession.sharedInstance().category.rawValue
            print("⏸️ Background audio stopped (category=\(category), session deactivated)")
            AppLogger.shared.log("BackgroundAudioKeepAlive: stopped, session deactivated, category=\(category)", category: .audio)
        } else {
            print("⏸️ Background audio player stopped (session kept active for handoff)")
            AppLogger.shared.log("BackgroundAudioKeepAlive: player stopped, session retained", category: .audio)
        }
    }
    
    /// Act on an App Persistence change: start or stop the keep-alive player.
    ///
    /// The caller writes `DeviceSettings.backgroundKeepAliveEnabled`; this makes
    /// the setting actually mean something. Shared by every surface that can
    /// flip it — the Settings tiles and the `app_persistence` MQTT command —
    /// because the OFF branch is *not* the obvious `stop()`.
    ///
    /// `stop()` defaults to `deactivateSession: true`, which sets the category
    /// to `.ambient` and calls `setActive(false)`. That killed a playing sleep
    /// sound or radio sleep session outright, and per `18-SLEEP-SOUNDS.md` our
    /// own `setActive(false)` posts no interruption notification, so the engine
    /// cannot detect it and never recovers.
    ///
    /// While either manager is active it IS the background audio (both call
    /// `stop()` when they take over), so there is no keep-alive player left to
    /// tear down — only the session, which belongs to them. They deactivate it
    /// themselves when they finish, and their stop paths only restart keep-alive
    /// when `keepAliveNeeded`, which is already false by then. Persistence still
    /// ends correctly.
    @MainActor
    func applyPersistenceChange(enabled: Bool) {
        // Coalesce a rapid burst of changes into one settled transition (see
        // `persistenceDebounce`). Each new change supersedes the pending one, so
        // only the final state is applied.
        persistenceDebounce?.cancel()
        persistenceDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.persistenceDebounceDelay)
            guard !Task.isCancelled else { return }
            self.applyPersistenceChangeNow(enabled: enabled)
        }
    }

    /// The actual keep-alive start/stop, run once per *settled* persistence
    /// state. Split out so `applyPersistenceChange` can debounce it.
    @MainActor
    private func applyPersistenceChangeNow(enabled: Bool) {
        // Already in the requested state — a redundant session transition is
        // exactly the churn we are trying to avoid.
        guard enabled != isRunning else { return }

        let volBefore = AVAudioSession.sharedInstance().outputVolume
        if enabled {
            Task.detached(priority: .utility) {
                await BackgroundAudioKeepAlive.shared.startAsync()
                await MainActor.run {
                    BackgroundAudioKeepAlive.shared.startHealthCheck()
                    BackgroundAudioKeepAlive.shared.logPersistenceVolume(before: volBefore, phase: "start")
                }
            }
        } else {
            let sessionOwnedElsewhere = SleepSoundManager.shared.isActive
                || RadioPlayerManager.shared.isActive
            stop(deactivateSession: !sessionOwnedElsewhere)
            logPersistenceVolume(before: volBefore, phase: "stop")
        }
    }

    /// Diagnostic: did the keep-alive session transition move the system output
    /// volume? A drift here (no alarm driving it) is the "volume flipped when I
    /// changed persistence" symptom — logged so a real-device repro leaves
    /// evidence in the audio log. Sampled after a short settle because any OS
    /// volume reversion lands just after `setActive`.
    @MainActor
    func logPersistenceVolume(before: Float, phase: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            let after = AVAudioSession.sharedInstance().outputVolume
            let delta = after - before
            if abs(delta) > 0.02 {
                AppLogger.shared.log(
                    String(format: "Persistence %@: system volume moved %.0f%% → %.0f%% (Δ%+.0f%%) across session transition",
                           phase, before * 100, after * 100, delta * 100),
                    category: .audio)
            } else {
                AppLogger.shared.log(
                    String(format: "Persistence %@: system volume steady at %.0f%%", phase, after * 100),
                    category: .audio)
            }
        }
    }

    /// Periodically verifies the audio player is actually playing.
    /// Catches silent failures that the interruption handler misses (e.g., iOS
    /// reclaimed the audio session without sending an interruption notification).
    func startHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard DeviceSettings.shared.keepAliveNeeded else {
                // App Persistence was turned off — stop the health check
                self.healthCheckTimer?.invalidate()
                self.healthCheckTimer = nil
                return
            }
            if self.isRunning, !(self.audioPlayer?.isPlaying ?? false) {
                // Player should be playing but isn't — restart it
                print("⚠️ BackgroundAudioKeepAlive: health check detected stopped player, restarting")
                Task { @MainActor in
                    AppLogger.shared.log("BackgroundAudioKeepAlive: health check restart (player stopped unexpectedly)", category: .audio)
                }
                Task.detached(priority: .utility) {
                    await self.startAsync()
                }
            }
        }
        RunLoop.main.add(healthCheckTimer!, forMode: .common)
        print("✅ BackgroundAudioKeepAlive: health check timer started (30s interval)")
    }
    
    private func getKeepAliveAudioURL() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // .caf is Apple's native container for LinearPCM — no format/container mismatch.
        return docs.appendingPathComponent("keepalive.caf")
    }

    private func createKeepAliveAudioFileAsync() async {
        createKeepAliveAudioFile()
    }

    private func createKeepAliveAudioFile() {
        guard let outputURL = getKeepAliveAudioURL() else { return }

        // Skip if file already exists and is valid.
        if FileManager.default.fileExists(atPath: outputURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let size = attrs[.size] as? Int, size > 1000 {
            return
        }

        try? FileManager.default.removeItem(at: outputURL)

        let sampleRate: Double = 44100
        let duration: Double = 5.0           // 5-second loop
        let numSamples = Int(sampleRate * duration)

        // LinearPCM in a .caf container is the canonical Apple format — AVAudioFile
        // and AVAudioPlayer both handle it natively with no transcoding.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        do {
            let audioFile = try AVAudioFile(forWriting: outputURL, settings: settings)

            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                               frameCapacity: AVAudioFrameCount(numSamples)) else {
                print("❌ BackgroundAudioKeepAlive: failed to create audio format/buffer")
                return
            }

            buffer.frameLength = AVAudioFrameCount(numSamples)
            if let ch = buffer.floatChannelData?[0] {
                // 100 Hz sine wave at 0.002 amplitude — non-zero so iOS recognises it
                // as active audio, completely inaudible at the 0.01 player volume.
                for i in 0..<numSamples {
                    ch[i] = 0.002 * Float(sin(2.0 * .pi * 100.0 * Double(i) / sampleRate))
                }
            }

            try audioFile.write(from: buffer)
            print("✅ BackgroundAudioKeepAlive: created keepalive.caf (\(numSamples) frames)")
        } catch {
            print("❌ BackgroundAudioKeepAlive: failed to create keepalive.caf: \(error)")
        }
    }
}

// MARK: - Alarm Window Manager

/// Manages the full-screen alarm window that blocks all interaction
@MainActor
final class AlarmWindowManager: ObservableObject {
    static let shared = AlarmWindowManager()

    private var alarmWindow: UIWindow?
    private var weatherWindow: UIWindow?
    /// Window hosting the post-dismiss after-alarm flow (verse → weather →
    /// app link). At `.alert` level, below the alarm's `.alert + 1`, so a newly
    /// firing alarm covers it — same as the old weather card.
    ///
    /// Because it only COVERS the flow, every path that presents an alarm window
    /// or a new flow must tear this down first (al-bee.3). It used to be released
    /// solely by its own `onFinished`, so a second flow overwrote the reference
    /// while the first was still visible: the user was dropped back onto the
    /// earlier alarm's stale cards and a `UIWindow` leaked each time.
    private var afterAlarmWindow: UIWindow?
    /// After-alarm sequences owed to alarms that were dismissed while others were
    /// still stacked behind them (al-bee.1). Drained at the dismissal that finds
    /// the queue empty. Memory-only, exactly like `alarmQueue`.
    private var deferredAfterAlarmFlows = AfterAlarmDeferralQueue()
    @Published var currentAlarm: AppAlarm?
    /// The original alarm hash used for scheduling/recovery.
    /// For DB alarms this equals Alarm.stableHash (launch-stable, derived from
    /// stableID); for synthetic (cache-reconstructed) alarms it preserves the
    /// original hash so ringing guards and pending-alarm lookups use the
    /// correct key.
    private(set) var currentAlarmID: Int? {
        didSet { Self.currentAlarmIDSnapshot = currentAlarmID }
    }
    private(set) var modelContainer: ModelContainer?

    // MARK: - Non-isolated snapshots
    // The AlarmKit observer loop (`AlarmKitScheduler.handleAlarmAlerting`) and
    // the ringing-guard roll timer both run OFF the main actor and need to know
    // which alarm is on screen / queued. Mirroring the state into plain statics
    // — the same shape as `VolumeManager.fadeActiveSnapshot` — keeps those hot,
    // latency-sensitive paths from hopping actors just to read an Int.

    nonisolated(unsafe) private(set) static var currentAlarmIDSnapshot: Int?
    nonisolated(unsafe) private(set) static var queuedAlarmIDsSnapshot: Set<Int> = []

    // MARK: - Alarm Queue
    // When an alarm fires while another is already showing, it goes into this queue.
    // After the current alarm is dismissed or snoozed, the next queued alarm is shown.

    struct QueuedAlarm: Equatable {
        let alarmID: Int
        let label: String
        let missionType: MissionType
        let soundID: String
        /// When this alarm was queued — i.e. when its ring began, since a fire
        /// that finds another alarm on screen queues immediately. Feeds the
        /// recency tie-break in `MissionConsolidationResolution`. Not part of
        /// `==`, which stays identity-only so the dedupe check is unchanged.
        var queuedAt: Date = Date()

        static func == (lhs: QueuedAlarm, rhs: QueuedAlarm) -> Bool {
            lhs.alarmID == rhs.alarmID
        }
    }

    private var alarmQueue: [QueuedAlarm] = [] {
        didSet {
            Self.queuedAlarmIDsSnapshot = Set(alarmQueue.map(\.alarmID))
        }
    }

    /// Snooze caps imposed by mission consolidation, keyed by alarm hash.
    ///
    /// When a stack collapses into one surviving alarm, that alarm must not
    /// inherit the whole stack's snoozes: the cap is the STRICTEST remaining
    /// allowance across every alarm that was folded into it. Memory-only and
    /// deliberately so — exactly like `alarmQueue` and like mission progress,
    /// a force-kill may demand more work, never less. Entries are cleared when
    /// the alarm is finally dismissed, so a snooze re-fire still honours the cap.
    private var consolidatedSnoozeCaps: [Int: Int] = [:]

    /// Whether the user has interacted with the alarm currently on screen
    /// (al-bee.11). Reset to `false` at every fresh presentation
    /// (`presentAlarmWindow`, `showAlertAlarm`, and so every dequeue that routes
    /// through them) and set `true` by `noteShowingAlarmEngaged()` from
    /// `ActiveAlarmView`. Consulted only by the queue-change consolidation: once
    /// the showing alarm is engaged, a later-arriving harder alarm can no longer
    /// roll it into the stack, so the demanded set never changes under the user's
    /// fingers. Memory-only and per-presentation, exactly like `alarmQueue`.
    private var showingAlarmEngaged = false

    // MARK: - Sleep/Wake State Machine (for MQTT)
    private var currentUserState: String = "unknown"
    private var userStateResetTimer: Timer?

    /// Set by ActiveAlarmView when the grace period mutes sound.
    /// showAlarm()'s Task.detached checks this to avoid restarting sound
    /// after the grace period has stopped it.
    var isGracePeriodMuted = false
    
    // MARK: - Backup Alarm Notification (Tier 2 Recovery)
    
    static let backupAlarmNotificationID = "hawake_backup_alarm"
    
    /// Schedule a local notification that fires 10 seconds from now.
    /// If the user force-closes the app, this notification alerts them
    /// to reopen so the alarm can resume. Cancelled on dismiss/snooze/foreground.
    func scheduleBackupAlarmNotification(alarmID: Int, label: String, soundID: String, volumeLevel: Double?) {
        let content = UNMutableNotificationContent()
        content.title = "Your alarm is still ringing!"
        content.body = "\(label) — Tap to open Allarise and dismiss your alarm."
        content.sound = .defaultCritical
        content.categoryIdentifier = "ALARM_BACKUP"
        content.interruptionLevel = .critical
        content.userInfo = [
            "alarmID": alarmID,
            "label": label,
            "soundID": soundID,
            "isBackupAlarm": true
        ]
        if let vol = volumeLevel {
            content.userInfo["volumeLevel"] = vol
        }
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.backupAlarmNotificationID,
            content: content,
            trigger: trigger
        )
        
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.backupAlarmNotificationID])
        center.add(request) { error in
            if let error {
                print("❌ Failed to schedule backup alarm notification: \(error)")
            } else {
                print("📱 Backup alarm notification scheduled (10s delay) for: \(label)")
                Task { @MainActor in
                    AppLogger.shared.log("Backup notification scheduled (10s): '\(label)' alarmID=\(alarmID)", category: .notification)
                }
            }
        }
    }
    
    /// Cancel the backup notification (alarm was resolved or app returned to foreground).
    func cancelBackupAlarmNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.backupAlarmNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.backupAlarmNotificationID])
    }

    private init() {
        // Listen for app becoming active to show pending alarms.
        // Use UIApplication.didBecomeActiveNotification because UIScene.didActivateNotification
        // does NOT fire when the phone is simply unlocked (scene goes inactive->active, not deactivated->activated).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("=== DIAG === didBecomeActiveNotification observer fired")
            Task { @MainActor [weak self] in
                print("=== DIAG === didBecomeActiveNotification -> calling checkAndShowPendingAlarm()")
                self?.checkAndShowPendingAlarm()
            }
        }
        
        // Also listen for scene activation. This fires on COLD LAUNCH when the
        // window scene first becomes ready — critical for the AlarmKit intent
        // handoff where CompleteMissionIntent stores a pending alarm but the
        // window scene wasn't available yet when showAlarm() was called.
        NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("=== DIAG === UIScene.didActivateNotification fired")
            Task { @MainActor [weak self] in
                // Only check if there's actually a pending alarm and we're not already showing one
                if PendingAlarmStore.shared.pendingAlarm != nil || PendingAlarmStore.shared.hasPendingAlarm() {
                    if !(self?.isShowingAlarm ?? false) {
                        print("=== DIAG === Scene activated with pending alarm — calling checkAndShowPendingAlarm()")
                        self?.checkAndShowPendingAlarm()
                    }
                }
            }
        }
    }
    
    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
        print("=== DIAG === AlarmWindowManager.modelContainer SET")
    }
    
    /// Ensures the existing alarm window is key and visible (e.g., after opening via Live Activity deep link).
    /// Returns true if an alarm window was made visible.
    @discardableResult
    func ensureAlarmWindowVisible() -> Bool {
        if let window = alarmWindow {
            print("=== DIAG === ensureAlarmWindowVisible: re-keying alarm window, hidden=\(window.isHidden), level=\(window.windowLevel.rawValue)")
            window.windowLevel = .alert + 1
            window.isHidden = false
            window.makeKeyAndVisible()
            return true
        }
        print("=== DIAG === ensureAlarmWindowVisible: no alarm window exists, isShowingAlarm=\(isShowingAlarm)")
        return false
    }
    
    /// Called when app becomes active — check if there's a pending alarm to show
    func checkAndShowPendingAlarm() {
        print("[ALARM-STATE] checkAndShowPendingAlarm() called at \(Date())")
        print("[ALARM-STATE] checkAndShowPendingAlarm: isShowingAlarm=\(isShowingAlarm), isPlaying=\(AlarmSoundPlayer.shared.isPlaying), pendingInMemory=\(PendingAlarmStore.shared.pendingAlarm != nil), pendingInUserDefaults=\(PendingAlarmStore.shared.hasPendingAlarm())")

        let store = PendingAlarmStore.shared

        // First check in-memory pending alarm (set by primary timer path)
        // Then check UserDefaults (set by CompleteMissionIntent when app was killed)
        if store.pendingAlarm == nil, store.hasPendingAlarm() {
            print("[ALARM-STATE] checkAndShowPendingAlarm: no in-memory alarm but found UserDefaults alarm, consuming...")
            if let info = store.consumePendingAlarm() {
                store.pendingAlarm = info
                print("[ALARM-STATE] checkAndShowPendingAlarm: resolved from UserDefaults: label=\(info.label), mission=\(info.missionType.rawValue), sound=\(info.soundID)")
            }
        }

        // Final fallback: if both in-memory and normal UserDefaults pending alarm
        // are empty, check the independent "active ringing alarm" key. This key is
        // set in presentAlarmWindow and ONLY cleared on explicit dismiss/snooze,
        // so it survives any number of force-close/reopen cycles.
        if store.pendingAlarm == nil {
            if let activeID = store.activeRingingAlarmID() {
                print("[ALARM-STATE] checkAndShowPendingAlarm: FALLBACK — recovering from activeRingingAlarm=\(activeID)")
                // Try to reconstruct alarm info from the storedInfo cache
                if let info = store.retrieveAlarmInfo(alarmID: activeID) {
                    store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                        alarmID: activeID,
                        label: info.label,
                        missionType: MissionType(rawValue: info.missionType) ?? .none,
                        soundID: info.soundID,
                        volumeLevel: info.volumeLevel
                    )
                    print("[ALARM-STATE] checkAndShowPendingAlarm: FALLBACK recovered: label=\(info.label), mission=\(info.missionType)")
                } else {
                    // storedInfo cache is also gone — use minimal info
                    store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                        alarmID: activeID,
                        label: "Alarm",
                        missionType: .none,
                        soundID: "Alarm_Clock",
                        volumeLevel: nil
                    )
                    print("[ALARM-STATE] checkAndShowPendingAlarm: FALLBACK recovered with minimal info (no storedInfo cache)")
                }
            }
        }

        guard let pending = store.pendingAlarm else {
            print("[ALARM-STATE] checkAndShowPendingAlarm: NO pending alarm found (activeRingingAlarm=\(store.activeRingingAlarmID().map(String.init) ?? "nil")), ensuring existing window visible")
            ensureAlarmWindowVisible()
            return
        }

        print("[ALARM-STATE] checkAndShowPendingAlarm: found pending alarm: label=\(pending.label), alarmID=\(pending.alarmID), mission=\(pending.missionType.rawValue), sound=\(pending.soundID)")
        
        // Re-configure audio session to ensure sound works after lock/unlock transition.
        // Skip if the grace period has muted sound — changing the audio category could
        // trigger an interruption notification that interferes with the muted state.
        if !isGracePeriodMuted {
            do {
                try AppAudioSession.setCategory(.playAndRecord, mode: .default, options: AppAudioSession.alarmFireCategoryOptions())
                try AppAudioSession.setActive(true)
                print("✅ Audio session reconfigured for alarm playback")
            } catch {
                print("❌ Failed to reconfigure audio session: \(error)")
            }
        }

        // If the alarm window is already showing (created while screen was locked),
        // just clear the pending alarm, re-ensure sound, re-ensure volume, and
        // retry Live Activity if it failed while in the background.
        if isShowingAlarm {
            print("[ALARM-STATE] checkAndShowPendingAlarm: alarm window ALREADY showing, clearing pending and re-ensuring sound")
            store.pendingAlarm = nil
            
            // App returned to foreground with alarm showing — cancel the backup notification
            // (no longer needed since the in-app alarm UI is handling it)
            cancelBackupAlarmNotification()

            // Retry alarm notifications if not already running.
            let mgr = AlarmLiveActivityManager.shared
            if !mgr.hasActiveNotifications {
                print("[ALARM-STATE] checkAndShowPendingAlarm: no alarm notifications — starting")
                mgr.suppressLockScreenNotifications = false
                mgr.startAlarmNotifications(
                    alarmLabel: pending.label,
                    alarmID: pending.alarmID
                )
            }

            // Sound and volume re-ensure (async because play() is async)
            // Skip for "silent" alerts — media alerts use AVPlayer in
            // AlertContentView instead of the alarm sound player.
            Task { @MainActor in
                // Guard: the alarm may have been dismissed while this task was
                // queued behind other main-actor work (e.g. a foreground MQTT
                // reconciliation burst). Without this check, the task can run
                // after dismissAlarm() has already stopped sound and hidden the
                // window, calling unlock() + play() with no alarm on screen.
                guard self.isShowingAlarm else {
                    print("[ALARM-STATE] checkAndShowPendingAlarm: sound task skipped — alarm dismissed before task ran")
                    return
                }
                if pending.soundID == "silent" {
                    print("[ALARM-STATE] checkAndShowPendingAlarm: soundID=silent (media alert), skipping alarm sound")
                } else if self.isGracePeriodMuted {
                    print("[ALARM-STATE] checkAndShowPendingAlarm: grace period active, NOT restarting sound")
                } else if !AlarmSoundPlayer.shared.isPlaying {
                    guard AlarmSoundPlayer.shared.unlockIfRinging() else {
                        print("[ALARM-STATE] checkAndShowPendingAlarm: sound skipped — alarm already snoozed/dismissed")
                        return
                    }
                    // If a fade is in flight, restart at the fade's current volume
                    // and re-arm the ramp — otherwise the sound would come back at
                    // full volume (default initialVolume) and abandon the fade.
                    let resumeVolume = VolumeManager.shared.fadeActive
                        ? VolumeManager.shared.playerVolumeForCurrentFade() : 1.0
                    print("[ALARM-STATE] checkAndShowPendingAlarm: starting alarm sound on unlock (vol=\(resumeVolume))")
                    await AlarmSoundPlayer.shared.play(soundID: pending.soundID, initialVolume: resumeVolume, isResume: true)
                    // A ring whose audio only got going here (e.g. the fire
                    // path couldn't play while locked) is still the first
                    // confirmation for that ring — the reporter ignores it if
                    // playback was already confirmed.
                    if AlarmSoundPlayer.shared.isPlaying { AlarmRingReporter.shared.audioStarted() }
                    VolumeManager.shared.ensureFadeRunning()
                    // Re-check after play — snooze may have run during the await
                    if !self.isShowingAlarm {
                        print("[ALARM-STATE] checkAndShowPendingAlarm: alarm dismissed during play — stopping")
                        AlarmSoundPlayer.shared.stop()
                    }
                } else {
                    print("[ALARM-STATE] checkAndShowPendingAlarm: sound already playing")
                    // Sound survived in the background but the ramp timer may have
                    // been suspended — resume it for the remainder of the fade.
                    VolumeManager.shared.ensureFadeRunning()
                }
                // Skip volume override for silent/media alerts and fade-ins.
                if pending.soundID != "silent" && !VolumeManager.shared.fadeActive {
                    let settings = DeviceSettings.shared
                    let volume = pending.volumeLevel ?? settings.alarmVolumeLevel
                    VolumeManager.shared.setSystemVolume(to: Float(volume))
                }
            }
            return
        }

        // Model container no longer required for initial display — showAlarm()
        // will use cached alarm data if DB isn't ready yet.
        print("[ALARM-STATE] checkAndShowPendingAlarm: ✅ all checks passed (modelContainer=\(modelContainer != nil ? "set" : "nil")), calling showAlarm(label=\(pending.label), mission=\(pending.missionType.rawValue))")
        // Clear pending alarm BEFORE showing to prevent duplicate triggers
        store.pendingAlarm = nil

        // Tier 1: if no tier claimed this ring, we got here from activation —
        // the app found an alarm that was pending/ringing while it was gone.
        AlarmRingReporter.shared.willDeliverIfUnclaimed(path: .launchRecovery, expectedFire: nil)

        showAlarm(
            alarmID: pending.alarmID,
            label: pending.label,
            missionType: pending.missionType,
            soundID: pending.soundID
        )
    }
    
    /// - Parameter startSoundIfNeeded: When true (the default, and every
    ///   recovery/unlock caller) a detached task restarts the alarm sound if
    ///   nothing is playing 200ms from now. The fire paths pass FALSE: they
    ///   present the window first and then start the sound themselves, at
    ///   volume 0 for the silent entry that lets a radio stream cut in before
    ///   the tone is heard. Left true there, the detached task would observe
    ///   isPlaying == false (play() simply hasn't run yet), start the tone at
    ///   FULL volume, and race a second player against the fire path's own.
    func showAlarm(alarmID: Int, label: String, missionType: MissionType, soundID: String, startSoundIfNeeded: Bool = true) {
        let startTime = CFAbsoluteTimeGetCurrent()
        print("[ALARM-STATE] showAlarm() called: alarmID=\(alarmID), label=\(label), mission=\(missionType.rawValue), soundID=\(soundID)")
        AppLogger.shared.log("showAlarm: '\(label)' mission=\(missionType.rawValue)", category: .alarm)

        // If an alarm is already showing, queue this one instead of dropping it.
        // The predicate lives in AlarmFireAudioResolution because the fire paths
        // now ask the same question BEFORE doing any audio work (al-3ox) — one
        // source of truth so the pre-check and this branch cannot drift apart.
        if isShowingAlarm {
            // But if the currently-showing alarm IS this alarm, the caller is a
            // duplicate (e.g., checkAndShowPendingAlarm firing on scenePhase
            // .active while the original timer-primary showAlarm is still in
            // flight). Without this guard the duplicate gets queued, and the
            // user's dismiss drains the queue — re-presenting the same alarm
            // and forcing them to dismiss a second time.
            if !AlarmFireAudioResolution.willQueue(
                firingAlarmID: alarmID,
                isShowingAlarm: isShowingAlarm,
                showingAlarmID: currentAlarmID
            ) {
                print("[ALARM-STATE] showAlarm: SKIPPED (same alarm already on screen): \(label)")
                AppLogger.shared.log("showAlarm: same alarm already showing — skipping '\(label)'", category: .alarm)
                return
            }
            let queued = QueuedAlarm(alarmID: alarmID, label: label, missionType: missionType, soundID: soundID)
            if !alarmQueue.contains(queued) {
                alarmQueue.append(queued)
                print("[ALARM-STATE] showAlarm: QUEUED (already showing alarm): \(label), queueSize=\(alarmQueue.count)")
                AppLogger.shared.log("Alarm queued (another showing): '\(label)' queueSize=\(alarmQueue.count)", category: .alarm)

                // al-bee.11: the queue just CHANGED. If the alarm on screen is
                // still unengaged and this newcomer is strictly harder, roll the
                // showing alarm into the stack instead of waiting for the dismiss
                // junction — otherwise an ascending stack consolidates nothing
                // and the sleeper does every set. Deferred to a Task so it runs
                // AFTER the firing alarm's fire path unwinds: dismissing the
                // showing alarm re-entrantly mid-call is exactly what to avoid.
                let showingID = currentAlarmID
                let queuedID = alarmID
                if let showingID {
                    Task { @MainActor in
                        self.resolveQueueChangeConsolidation(showingID: showingID, queuedID: queuedID)
                    }
                }
            } else {
                print("[ALARM-STATE] showAlarm: SKIPPED (already in queue): \(label)")
            }
            return
        }
        
        // ✅ Publish alarm state and active alarm info to MQTT.
        // MQTT-hidden alarms (excludeFromMQTT, al-5a94) publish nothing here:
        // the name-keyed globals below would otherwise leak them to HA even
        // though they carry no alarmIndex.
        let settings = DeviceSettings.shared
        let mqttHidden = dbAlarm(forHash: alarmID)?.excludeFromMQTT ?? false
        if !mqttHidden {
            HAIntegrationRouter.shared.publishAlarmState(.ringing, settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmName(label, settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmMission(missionType.rawValue.lowercased(), settings: settings)
        }

        // Publish "waking" state on first alarm of morning — skip alert alarms,
        // which are transient security/notification alarms and should never
        // be treated as a wake-up event or update wake_alarm_name. MQTT-hidden
        // alarms likewise: a kids bedtime alarm ringing at 19:30 is not the
        // user waking up.
        if missionType != .alert && !mqttHidden && currentUserState != "waking" && currentUserState != "awake" {
            currentUserState = "waking"
            HAIntegrationRouter.shared.publishUserState("waking", settings: settings)
            HAIntegrationRouter.shared.publishWakeAlarmName(label, settings: settings)
        }

        // Ensure alarm sound is playing. Always attempt playback even when locked —
        // AVAudioPlayer with .playback category works on physical devices from background.
        // The backup notification is kept as an additional fallback when locked.
        // NOTE: We check isGracePeriodMuted to avoid restarting sound after the grace
        // period (in ActiveAlarmView) has already stopped it for the mission screen.
        if startSoundIfNeeded {
        Task.detached(priority: .userInitiated) {
            // Small delay to let ActiveAlarmView.task fire first, which may start
            // the grace period and mute sound. Without this, the detached task
            // races with the grace period and can restart sound after it was stopped.
            try? await Task.sleep(nanoseconds: 200_000_000)

            // Check if alarm was already dismissed before we got here
            let stillShowing = await AlarmWindowManager.shared.isShowingAlarm
            if !stillShowing {
                print("=== DIAG === Sound check: alarm already dismissed, skipping sound start")
                return
            }

            let isMutedByGracePeriod = await AlarmWindowManager.shared.isGracePeriodMuted
            if isMutedByGracePeriod {
                print("=== DIAG === Sound check: grace period active, skipping sound restart")
                return
            }

            let isCurrentlyPlaying = await AlarmSoundPlayer.shared.isPlaying
            print("=== DIAG === Sound check: isPlaying=\(isCurrentlyPlaying)")
            if !isCurrentlyPlaying {
                // Double-check grace period hasn't started since our last check
                let stillMuted = await AlarmWindowManager.shared.isGracePeriodMuted
                if stillMuted {
                    print("=== DIAG === Sound check: grace period became active, skipping")
                    return
                }

                // Double-check alarm is still showing (user may have dismissed during checks)
                let alarmStillUp = await AlarmWindowManager.shared.isShowingAlarm
                if !alarmStillUp {
                    print("=== DIAG === Sound check: alarm dismissed during checks, skipping")
                    return
                }

                // If a fade is in flight, restart at the fade's current volume and
                // re-arm the ramp so we don't come back at full volume and lose the fade.
                let fadeActive = await VolumeManager.shared.fadeActive
                let resumeVolume: Float = fadeActive ? await VolumeManager.shared.playerVolumeForCurrentFade() : 1.0
                print("=== DIAG === Starting/restarting alarm sound (vol=\(resumeVolume))")
                await AlarmSoundPlayer.shared.play(soundID: soundID, initialVolume: resumeVolume, isResume: true)
                await VolumeManager.shared.ensureFadeRunning()
                print("=== DIAG === Sound play() returned, isPlaying=\(await AlarmSoundPlayer.shared.isPlaying)")

                // Retry if first attempt failed (intermittent '!int' audio session error)
                let playing = await AlarmSoundPlayer.shared.isPlaying
                if !playing {
                    print("=== DIAG === showAlarm: first play failed, retrying in 0.5s...")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    // Final check before retry
                    let finalCheck = await AlarmWindowManager.shared.isShowingAlarm
                    if !finalCheck {
                        print("=== DIAG === Sound retry: alarm dismissed, skipping retry")
                        return
                    }
                    await AlarmSoundPlayer.shared.play(soundID: soundID, initialVolume: resumeVolume, isResume: true)
                    await VolumeManager.shared.ensureFadeRunning()
                    print("=== DIAG === showAlarm: retry result isPlaying=\(await AlarmSoundPlayer.shared.isPlaying)")
                }
                // Playback outcome for this ring. Only reported while the alarm
                // is still up — a dismiss during the attempts is not a silent
                // start, it's a user who was already awake.
                if await AlarmWindowManager.shared.isShowingAlarm {
                    if await AlarmSoundPlayer.shared.isPlaying {
                        await AlarmRingReporter.shared.audioStarted()
                    } else {
                        await AlarmRingReporter.shared.audioFailed()
                    }
                }
            }
        }
        }
        
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            print("=== DIAG === showAlarm: No window scene available — re-storing pending alarm for retry")
            // Re-store the pending alarm so it can be picked up when the scene becomes available
            // (e.g., didBecomeActiveNotification, or the intent's retry loop)
            PendingAlarmStore.shared.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                alarmID: alarmID,
                label: label,
                missionType: missionType,
                soundID: soundID,
                volumeLevel: nil
            )
            return
        }
        print("=== DIAG === Window scene found: \(windowScene.activationState.rawValue) (0=unattached,1=foregroundActive,2=foregroundInactive,3=background)")
        
        // Alert mission type: transient alarm (not from DB). Create in-memory and show immediately.
        if missionType == .alert {
            showAlertAlarm(alarmID: alarmID, label: label, soundID: soundID, windowScene: windowScene, startTime: startTime)
            return
        }
        
        print("🔔 [PERF] Pre-checks completed at \((CFAbsoluteTimeGetCurrent() - startTime) * 1000)ms")
        
        // FAST PATH: Try to reconstruct alarm from cache for instant display.
        // This avoids waiting for SwiftData on cold start.
        if let cachedAlarm = PendingAlarmStore.shared.reconstructAlarm(alarmID: alarmID) {
            print("🚀 [PERF] Cache hit — showing alarm instantly without DB fetch")
            presentAlarmWindow(
                alarm: cachedAlarm,
                alarmID: alarmID,
                windowScene: windowScene,
                startTime: startTime,
                isSynthetic: true
            )
            return
        }
        
        // SLOW PATH: Cache miss — fall back to DB fetch.
        guard let container = modelContainer else {
            print("=== DIAG === showAlarm: modelContainer is nil and no cache — re-storing pending alarm for retry")
            PendingAlarmStore.shared.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                alarmID: alarmID,
                label: label,
                missionType: missionType,
                soundID: soundID,
                volumeLevel: nil
            )
            return
        }
        print("=== DIAG === Cache miss — fetching alarm from DB")
        
        Task {
            let context = container.mainContext
            let descriptor = FetchDescriptor<AppAlarm>()
            
            let alarms: [AppAlarm]
            do {
                alarms = try context.fetch(descriptor)
                print("=== DIAG === Fetched \(alarms.count) alarms from DB")
            } catch {
                print("=== DIAG === DB FETCH ERROR: \(error)")
                return
            }
            
            let alarm: AppAlarm
            if let exact = alarms.first(where: { $0.stableHash == alarmID }) {
                alarm = exact
            } else if let byLabel = alarms.first(where: { $0.label == label }) {
                // Transition fallback: recovery blobs written by pre-stableID
                // versions carry the legacy session hash. Label match is safe
                // enough (the user sees the label on screen); the old
                // "first enabled alarm" fallback was removed — presenting and
                // dismissing an arbitrary alarm is worse than not presenting.
                print("=== DIAG === Hash mismatch but found alarm by label: \(label)")
                alarm = byLabel
            } else {
                print("=== DIAG === ALARM NOT FOUND: looking for stableHash=\(alarmID), label=\(label), available: \(alarms.map { "\($0.label)=\($0.stableHash)" })")
                return
            }
            
            print("=== DIAG === Found alarm in DB: \(alarm.label)")
            
            await MainActor.run {
                presentAlarmWindow(
                    alarm: alarm,
                    alarmID: alarmID,
                    windowScene: windowScene,
                    startTime: startTime,
                    isSynthetic: false
                )
            }
        }
    }
    
    /// Present the alarm window with either a DB-backed or cache-reconstructed alarm.
    private func presentAlarmWindow(
        alarm: AppAlarm,
        alarmID: Int,
        windowScene: UIWindowScene,
        startTime: CFAbsoluteTime,
        isSynthetic: Bool
    ) {
        let uiStart = CFAbsoluteTimeGetCurrent()
        let settings = DeviceSettings.shared

        // A new presentation begins here — for a fresh fire and for a dequeued
        // alarm alike, since `presentDequeuedAlarm` routes back through
        // `showAlarm`. The engagement latch must track THIS ring (al-bee.11).
        showingAlarmEngaged = false

        // An after-alarm flow from an earlier alarm must go away, not just be
        // covered (al-bee.3): the alarm window sits above it, and leaving it
        // resident dropped the user back onto stale cards after this alarm was
        // dealt with. Its contribution stays queued and is re-presented when the
        // stack drains.
        teardownAfterAlarmWindow()

        // Set volume — but never while a fade is armed or in progress, or this
        // would stomp the fade's carefully-set system volume / ramp.
        let effectiveVolume = alarm.effectiveVolumeLevel(settings: settings)
        if !VolumeManager.shared.fadeActive {
            VolumeManager.shared.setSystemVolume(to: Float(effectiveVolume))
        }

        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .black
        
        print("🪟 [PERF] Window created at \((CFAbsoluteTimeGetCurrent() - uiStart) * 1000)ms")
        
        let alarmView = ActiveAlarmView(
            alarm: alarm,
            settings: settings,
            // Present when this ring survived a consolidated stack: the alarms
            // folded into it must not hand it their snoozes (al-bee.7). nil for
            // every ordinary ring, which is every ring outside a stack.
            snoozeAllowanceCap: consolidatedSnoozeCaps[alarmID],
            onDismiss: {
                if isSynthetic {
                    self.dismissWithDBAlarm(syntheticAlarm: alarm, alarmID: alarmID)
                } else {
                    self.dismissAlarm(alarm: alarm, alarmID: alarmID)
                }
            },
            onSnooze: {
                if isSynthetic {
                    self.snoozeWithDBAlarm(syntheticAlarm: alarm, alarmID: alarmID)
                } else if let container = self.modelContainer {
                    self.snoozeAlarm(alarm: alarm, alarmID: alarmID, context: container.mainContext)
                }
            }
        )
        
        print("📱 [PERF] ActiveAlarmView created at \((CFAbsoluteTimeGetCurrent() - uiStart) * 1000)ms")
        
        // Attach model container if available (synthetic alarms may not have one yet)
        let hostingController: UIHostingController<AnyView>
        if let container = modelContainer {
            hostingController = UIHostingController(rootView: AnyView(alarmView.modelContainer(container)))
        } else {
            hostingController = UIHostingController(rootView: AnyView(alarmView))
        }
        hostingController.view.backgroundColor = .black
        
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        
        self.alarmWindow = window
        self.currentAlarm = alarm
        self.currentAlarmID = alarmID

        // Telemetry: the alarm window is the single funnel every delivery tier
        // reaches, and the first point where the alarm's shape is known.
        AlarmRingReporter.shared.ringBegan(
            missionCount: alarm.missionSequence.count,
            usedRadio: alarm.radioStationURL != nil
        )

        // Stop the AlarmKit failsafe now that in-app UI is handling it.
        DualAlarmCoordinator.shared.cancelFailsafe(for: alarmID)
        AlarmKitScheduler.shared.stopCurrentAlertingAlarm()
        DualAlarmCoordinator.shared.cancelRingingGuard(forAlarmHash: alarmID)

        // Re-persist the pending alarm to UserDefaults for Tier 1 recovery.
        // consumePendingAlarm() cleared UserDefaults during checkAndShowPendingAlarm(),
        // so if the user force-closes again, cold start would find nothing.
        // This ensures every force-close cycle has UserDefaults data to recover from.
        let missionTypeRaw = alarm.mission.type.rawValue
        PendingAlarmStore.shared.setPendingAlarmFull(
            alarmID: alarmID,
            label: alarm.label,
            missionType: missionTypeRaw,
            soundID: alarm.soundName,
            volumeLevel: alarm.customVolumeLevel
        )

        // Set the independent "active ringing alarm" key. Unlike the pending alarm
        // keys (which are consumed/cleared by checkAndShowPendingAlarm, the .active
        // handler stale check, etc.), this key is ONLY cleared on explicit dismiss
        // or snooze. It acts as the ultimate fallback for force-close recovery.
        PendingAlarmStore.shared.setActiveRingingAlarm(alarmID)

        // Open an unresolved-ring entry (al-bee.5). Written here because this
        // is the one funnel every delivery tier reaches and the ringing key is
        // already being written, so it costs nothing new on the hot path. It
        // is a SEPARATE UserDefaults key and nothing in the alarm lifecycle
        // reads it — losing it costs accuracy, never an alarm.
        //
        // Alert alarms are excluded: an inbound Home Assistant alert is a
        // transient notification, not a wake event, and an unacknowledged one
        // is not a slept-through alarm. MQTT-hidden alarms are excluded too —
        // the ledger feeds the HA slept-through sensor, which would leak the
        // hidden alarm's label (al-5a94).
        if alarm.mission.type != .alert && !alarm.excludeFromMQTT {
            UnresolvedRingLedger.shared.noteRingStarted(
                alarmHash: alarmID,
                label: alarm.label,
                alarmIndex: alarm.alarmIndex
            )
        }

        // Proactively schedule a new ringing guard (Tier 3 recovery).
        // The .background scene phase handler also schedules a guard, but it
        // may not fire during a force-kill (SIGKILL gives no grace period).
        // Scheduling here ensures the guard exists before any possible kill.
        Task {
            await DualAlarmCoordinator.shared.scheduleRingingGuard(alarm: alarm, alarmID: alarmID)
        }

        // Schedule a backup local notification (Tier 2 recovery).
        scheduleBackupAlarmNotification(
            alarmID: alarmID,
            label: alarm.label,
            soundID: alarm.soundName,
            volumeLevel: alarm.customVolumeLevel
        )
        
        // Publish active alarm info to MQTT
        if alarm.alarmIndex > 0 {
            HAIntegrationRouter.shared.activeAlarmIndex = alarm.alarmIndex
            HAIntegrationRouter.shared.publishActiveAlarmIndex(alarm.alarmIndex, settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmName(alarm.label, settings: settings)
            
            let daysString: String
            let recurDays = alarm.safeRecurringDays
            if recurDays.isEmpty {
                daysString = "one-time"
            } else {
                let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                let sortedDays = recurDays.sorted()
                daysString = sortedDays.compactMap { $0 >= 1 && $0 <= 7 ? dayNames[$0] : nil }.joined(separator: ",")
            }
            HAIntegrationRouter.shared.publishActiveAlarmDays(daysString, settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmFireTime(alarm.nextFireDate(), settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmSnoozeFireTime(nil, settings: settings)
            
            let maxSnoozes = alarm.maxSnoozeCount ?? settings.defaultMaxSnoozeCount
            let snoozesRemaining = maxSnoozes == 0 ? Int.max : max(0, maxSnoozes - alarm.snoozeCount)
            let snoozeAllowed = HAIntegrationRouter.shared.isSnoozeAllowedForAlarm(alarm, snoozesRemaining: snoozesRemaining, settings: settings)
            HAIntegrationRouter.shared.publishPerAlarmStateTransition(alarmIndex: alarm.alarmIndex, state: .ringing, snoozeAllowed: snoozeAllowed, settings: settings)
        }
        
        // Clear pending alarm if scene is foreground
        let sceneState = windowScene.activationState
        if sceneState == .foregroundActive || sceneState == .foregroundInactive {
            PendingAlarmStore.shared.pendingAlarm = nil
            print("=== DIAG === Cleared pendingAlarm (scene is foreground)")
        } else {
            print("=== DIAG === Keeping pendingAlarm (scene is \(sceneState.rawValue), not foreground)")
        }
        
        // Start alarm notifications (vibration + lock-screen presence).
        // In AlarmKit mode, suppress lock-screen notifications — AlarmKit provides its own.
        if !AlarmLiveActivityManager.shared.hasActiveNotifications {
            AlarmLiveActivityManager.shared.suppressLockScreenNotifications = false
            AlarmLiveActivityManager.shared.startAlarmNotifications(
                alarmLabel: alarm.label,
                alarmID: alarmID
            )
        }
        
        let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("=== DIAG === SUCCESS: Alarm window displayed! TOTAL TIME: \(totalTime)ms, synthetic=\(isSynthetic)")
        print("=== DIAG === alarmWindow=\(String(describing: self.alarmWindow)), isShowingAlarm=\(self.isShowingAlarm)")
    }
    
    /// Show an alert mission alarm (transient — not backed by a SwiftData alarm).
    /// Creates an in-memory Alarm object with alert mission data from PendingAlarmStore.
    private func showAlertAlarm(alarmID: Int, label: String, soundID: String, windowScene: UIWindowScene, startTime: CFAbsoluteTime) {
        print("🚨 showAlertAlarm: creating transient alert alarm")

        // A new presentation begins — reset the engagement latch to track it
        // (al-bee.11). An alert never triggers a queue-change swap anyway, but
        // the flag must not carry over from a previous ring.
        showingAlarmEngaged = false

        // Same reason as presentAlarmWindow — this window is above the flow's
        // (al-bee.3).
        teardownAfterAlarmWindow()

        // Build an alert mission with title/message from PendingAlarmStore
        var mission = Mission()
        mission.type = .alert
        if let alertInfo = PendingAlarmStore.shared.retrieveAlertInfo(alarmID: alarmID) {
            mission.alertTitle = alertInfo.title
            mission.alertMessage = alertInfo.message
        } else {
            mission.alertTitle = label
        }
        
        // Create a transient Alarm (not inserted into any ModelContext)
        let alarm = AppAlarm(
            time: Date(),
            label: label,
            isEnabled: true,
            soundName: soundID,
            mission: mission
        )
        
        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 2  // Above regular alarm windows
        window.backgroundColor = .black
        
        let alarmView = ActiveAlarmView(
            alarm: alarm,
            settings: DeviceSettings.shared,
            onDismiss: {
                self.dismissAlertAlarm(alarmID: alarmID, label: label)
            },
            onSnooze: {
                // Alert alarms don't support snooze — this callback is unused
            }
        )
        
        let hostingController = UIHostingController(rootView: alarmView)
        hostingController.view.backgroundColor = .black
        
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        
        self.alarmWindow = window
        self.currentAlarm = alarm
        self.currentAlarmID = alarmID
        
        // Stop the AlarmKit alarm now that in-app UI is handling it
        DualAlarmCoordinator.shared.cancelFailsafe(for: alarmID)
        DualAlarmCoordinator.shared.cancelRingingGuard(forAlarmHash: alarmID)
        
        // Alert alarms publish "alert" as the index
        HAIntegrationRouter.shared.activeAlarmIndex = nil  // Alert alarms have no per-alarm index
        HAIntegrationRouter.shared.publishActiveAlarmIndex(nil, settings: DeviceSettings.shared)
        HAIntegrationRouter.shared.publishActiveAlarmDays("none", settings: DeviceSettings.shared)
        HAIntegrationRouter.shared.publishActiveAlarmFireTime(nil, settings: DeviceSettings.shared)
        HAIntegrationRouter.shared.publishActiveAlarmSnoozeFireTime(nil, settings: DeviceSettings.shared)
        
        // Clear pending alarm if foreground
        let sceneState = windowScene.activationState
        if sceneState == .foregroundActive || sceneState == .foregroundInactive {
            PendingAlarmStore.shared.pendingAlarm = nil
        }
        
        // Start alarm notifications for the alert.
        // When fade-in is active, always vibrate — audio starts quiet but
        // the user still needs tactile feedback.
        let alertSettings = DeviceSettings.shared
        let alertVibrationEnabled = alertSettings.alarmVibrationEnabled
        AlarmLiveActivityManager.shared.vibrationEnabled = alertVibrationEnabled || alertSettings.alarmFadeInEnabled
        AlarmLiveActivityManager.shared.startAlarmNotifications(
            alarmLabel: label,
            alarmID: alarmID
        )
        
        let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("🚨 Alert alarm window displayed! TOTAL TIME: \(totalTime)ms")
    }
    
    /// Dismiss a transient alert alarm (no DB operations needed).
    private func dismissAlertAlarm(alarmID: Int, label: String) {
        // FIRST: kill audio immediately.
        AlarmSoundPlayer.shared.stop()

        print("✅ Dismissing alert alarm: \(label)")
        AppLogger.shared.log("Alert dismissed: '\(label)'", category: .alarm)

        // Stop alarm notifications
        AlarmLiveActivityManager.shared.stopAlarmNotificationsInBackground()

        // Retire the alert's own notification. Once the alert has been
        // dismissed, that notification has no job left: an alert is transient —
        // no SwiftData row, no snooze, no grace period, no AlarmKit failsafe —
        // so nothing recovers THROUGH it the way a real alarm recovers through
        // `ALARM_BACKUP`. Leaving it in Notification Center is what let a tap
        // days later re-present (and re-sound) an alert the user had already
        // dealt with (al-dhs). Recorded in the ledger as well, because iOS keeps
        // no promise that removal reaches a copy already mirrored to the Watch,
        // and because the app may have been relaunched since.
        let resolvedTitle = PendingAlarmStore.shared.retrieveAlertInfo(alarmID: alarmID)?.title
            ?? currentAlarm?.mission.alertTitle
            ?? label
        let resolvedMessage = PendingAlarmStore.shared.retrieveAlertInfo(alarmID: alarmID)?.message
            ?? currentAlarm?.mission.alertMessage
            ?? ""
        let delivery = PendingAlarmStore.shared.retrieveAlertDelivery(alarmID: alarmID)
        var resolvedIdentities: [String] = []
        if let identity = delivery?.identity { resolvedIdentities.append(identity) }
        resolvedIdentities.append(AlertIdentity.content(title: resolvedTitle, message: resolvedMessage))
        AlertDeliveryLedger.shared.markResolved(resolvedIdentities)

        var alertNotificationIDs = ["mqtt-alert-\(alarmID)", "nws-alert-\(alarmID)"]
        if let carried = delivery?.notificationID, !alertNotificationIDs.contains(carried) {
            alertNotificationIDs.append(carried)
        }
        let alertNotificationCenter = UNUserNotificationCenter.current()
        alertNotificationCenter.removeDeliveredNotifications(withIdentifiers: alertNotificationIDs)
        alertNotificationCenter.removePendingNotificationRequests(withIdentifiers: alertNotificationIDs)

        // Clean up alert info, media info, and active ringing state
        PendingAlarmStore.shared.clearAlertInfo(alarmID: alarmID)
        PendingAlarmStore.shared.clearAlertDelivery(alarmID: alarmID)
        PendingAlarmStore.shared.clearAlertMediaInfo(alarmID: alarmID)
        PendingAlarmStore.shared.clearActiveRingingAlarm()
        // Clear UserDefaults pending alarm keys so checkAndShowPendingAlarm cannot
        // re-trigger this alert after it has been dismissed (ghost alert fix).
        PendingAlarmStore.shared.clearPersistedPendingAlarm()
        AlarmKitScheduler.shared.clearHandlingAlarm()

        self.alarmWindow?.isHidden = true
        self.alarmWindow = nil
        self.currentAlarm = nil
        self.currentAlarmID = nil
        self.isGracePeriodMuted = false

        // Restore volume
        VolumeManager.shared.restoreOriginalVolume()
        
        // Show next queued alarm, or publish dismissed state
        if let next = alarmQueue.first {
            alarmQueue.removeFirst()
            presentDequeuedAlarm(next)
        } else {
            let settings = DeviceSettings.shared
            HAIntegrationRouter.shared.publishAlarmState(.dismissed, settings: settings)
            HAIntegrationRouter.shared.activeAlarmIndex = nil
            HAIntegrationRouter.shared.publishActiveAlarmIndex(nil, settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmName(nil, settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmDays("none", settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmFireTime(nil, settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmSnoozeFireTime(nil, settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmMission("none", settings: settings)
            HAIntegrationRouter.shared.publishSnoozeCount(0, settings: settings)
            HAIntegrationRouter.shared.publishSnoozesRemaining(0, settings: settings)
            
            // No weather card for HA-initiated alert alarms — they are not
            // wake-up alarms and should never trigger the Good Morning screen.
        }
    }
    
    /// Dismiss handler for cache-reconstructed (synthetic) alarms.
    /// Fetches the real DB alarm for proper state mutation, falling back to the synthetic one.
    private func dismissWithDBAlarm(syntheticAlarm: AppAlarm, alarmID: Int) {
        if let container = modelContainer {
            let context = container.mainContext
            let descriptor = FetchDescriptor<AppAlarm>()
            if let alarms = try? context.fetch(descriptor),
               let dbAlarm = alarms.first(where: { $0.stableHash == alarmID })
                           ?? alarms.first(where: { $0.label == syntheticAlarm.label }) {
                print("=== DIAG === dismissWithDBAlarm: found real alarm in DB")
                dismissAlarm(alarm: dbAlarm, alarmID: alarmID)
                return
            }
        }
        // Fallback: use synthetic alarm (snooze state won't persist to DB)
        print("=== DIAG === dismissWithDBAlarm: DB not available, using synthetic alarm")
        dismissAlarm(alarm: syntheticAlarm, alarmID: alarmID)
    }
    
    /// Snooze handler for cache-reconstructed (synthetic) alarms.
    /// Fetches the real DB alarm for proper state mutation, falling back to the synthetic one.
    private func snoozeWithDBAlarm(syntheticAlarm: AppAlarm, alarmID: Int) {
        if let container = modelContainer {
            let context = container.mainContext
            let descriptor = FetchDescriptor<AppAlarm>()
            if let alarms = try? context.fetch(descriptor),
               let dbAlarm = alarms.first(where: { $0.stableHash == alarmID })
                           ?? alarms.first(where: { $0.label == syntheticAlarm.label }) {
                print("=== DIAG === snoozeWithDBAlarm: found real alarm in DB")
                snoozeAlarm(alarm: dbAlarm, alarmID: alarmID, context: context)
                return
            }
            // DB alarm not found by hash or label — fall back to synthetic
            print("=== DIAG === snoozeWithDBAlarm: DB alarm not found, using synthetic alarm")
            snoozeAlarm(alarm: syntheticAlarm, alarmID: alarmID, context: context)
        } else {
            // No model container available — perform snooze actions directly
            // so the alarm UI still dismisses (snooze state won't persist to DB)
            print("⚠️ snoozeWithDBAlarm: modelContainer is nil — performing direct snooze")
            performDirectSnooze(alarm: syntheticAlarm, alarmID: alarmID)
        }
    }

    /// Emergency snooze fallback when no ModelContainer is available.
    /// Performs all the side-effects of a snooze (hide window, schedule timers,
    /// update cache) without requiring a SwiftData context.
    private func performDirectSnooze(alarm: AppAlarm, alarmID: Int) {
        AppLogger.shared.log("Direct snooze (no DB): '\(alarm.label)' count=\(alarm.snoozeCount + 1)", category: .alarm)

        // Stop sound immediately — snooze button already calls stop() before onSnooze(),
        // but this covers the MQTT/HA path. Also locks the player.
        AlarmSoundPlayer.shared.stop()

        // Restore the user's media volume for the snooze interval (re-raised on re-fire).
        VolumeManager.shared.restoreOriginalVolume()

        // Cancel ringing guard and backup notification
        DualAlarmCoordinator.shared.cancelRingingGuard(forAlarmHash: alarmID)
        cancelBackupAlarmNotification()
        PendingAlarmStore.shared.clearPersistedPendingAlarm()
        PendingAlarmStore.shared.clearActiveRingingAlarm()
        // Close the unresolved ring (al-bee.5) — same rule as snoozeAlarm.
        UnresolvedRingLedger.shared.noteUserAction(alarmHash: alarmID)
        AlarmKitScheduler.shared.clearHandlingAlarm()

        // Update snooze state on synthetic alarm
        alarm.isSnoozed = true
        alarm.snoozeCount += 1

        // Closes the ring (the snooze re-fire opens a new one).
        AlarmRingReporter.shared.ringEnded(outcome: .snoozed, snoozeCount: alarm.snoozeCount)

        let snoozeInterval = TimeInterval(alarm.snoozeDuration * 60)
        alarm.snoozeUntil = Date().addingTimeInterval(snoozeInterval)

        // Snapshot the app link before the async work below — the same discipline
        // the after-alarm flow uses (al-bee.1).
        let snoozeAppURI = alarm.snoozeAppURI

        // Update cached alarm info
        PendingAlarmStore.shared.storeFullAlarmInfo(alarmID: alarmID, alarm: alarm)

        // CRITICAL: Schedule AlarmKit failsafe and THEN dismiss the UI.
        // See comment in snoozeAlarm() for full rationale.
        Task { @MainActor in
            // 0. Stop the original alerting AlarmKit alarm so iOS clears its system notification.
            //    Without this, the AlarmKit alarm stays in .alerting state and iOS continues
            //    showing its notification banner / lock screen UI after the user snoozes.
            AlarmKitScheduler.shared.stopCurrentAlertingAlarm()

            // 1. Schedule AlarmKit snooze failsafe (survives force-kill)
            if let snoozeUntil = alarm.snoozeUntil {
                let failsafeOK = await AlarmKitScheduler.shared.scheduleSnoozeFailsafe(
                    alarm: alarm,
                    alarmID: alarmID,
                    snoozeUntil: snoozeUntil
                )
                if failsafeOK {
                    print("[ALARM-STATE] performDirectSnooze: AlarmKit failsafe confirmed scheduled before window dismiss")
                } else {
                    print("[ALARM-STATE] performDirectSnooze: ⚠️ AlarmKit failsafe FAILED — snooze re-fire depends on the in-app timer only")
                    AppLogger.shared.log("Snooze failsafe UNCONFIRMED for '\(alarm.label)' — force-kill during snooze will not be covered", category: .alarm)
                }
            }

            // 2. Publish snooze state to MQTT
            let settings = DeviceSettings.shared
            HAIntegrationRouter.shared.publishAlarmState(.snoozed, settings: settings)
            HAIntegrationRouter.shared.publishSnoozeCount(alarm.snoozeCount, settings: settings)
            let maxSnoozes = alarm.maxSnoozeCount ?? settings.defaultMaxSnoozeCount
            let remaining = maxSnoozes == 0 ? Int.max : max(0, maxSnoozes - alarm.snoozeCount)
            HAIntegrationRouter.shared.publishSnoozesRemaining(remaining, settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmSnoozeFireTime(alarm.snoozeUntil, settings: settings)

            // 3. Stop alarm notifications
            AlarmLiveActivityManager.shared.stopAlarmNotificationsInBackground()

            // 4. NOW hide the alarm window (failsafe is confirmed scheduled)
            self.alarmWindow?.isHidden = true
            self.alarmWindow = nil
            self.currentAlarm = nil
            self.currentAlarmID = nil
            self.isGracePeriodMuted = false

            // 5. Schedule the in-app snooze timer (fires when app is alive)
            await self.scheduleSnoozeNotification(alarm: alarm, alarmID: alarmID)

            // 6. Show next queued alarm if any. The per-alarm snooze app link
            // fires either way (al-bee.1) — gating it on an empty queue silently
            // dropped the link the user configured whenever a second alarm was
            // stacked behind this one. Fired AFTER the dequeued alarm is presented
            // so the next ring is never delayed by an app switch.
            let hasQueuedAlarms = !self.alarmQueue.isEmpty
            if let next = self.alarmQueue.first {
                self.alarmQueue.removeFirst()
                self.presentDequeuedAlarm(next)
            }

            // 7. Sleep sounds stop for good once an alarm has fired — no resume
            // on snooze (al-ecf, superseding al-3jm). The user restarts them
            // manually. Same step in snoozeAlarm().
            SleepSoundManager.shared.handleAlarmEnded(.snoozed, hasQueuedAlarms: hasQueuedAlarms)

            self.openAppLink(snoozeAppURI)
        }
    }
    
    // MARK: - Morning Weather Card
    
    /// Debug: force-show the weather card ignoring cooldown and settings.
    /// Call from a test button — remove before shipping.
    func showWeatherCardPreview() {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert
        window.backgroundColor = .clear

        let (wallpaper, isDark) = loadWeatherWallpaper()

        let weatherView = GoodMorningWeatherView(
            onDismiss: {
                window.isHidden = true
                self.weatherWindow = nil
            },
            wallpaperImage: wallpaper,
            wallpaperIsDark: isDark
        )

        let hostingController = UIHostingController(rootView: weatherView)
        hostingController.view.backgroundColor = .clear
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        self.weatherWindow = window
    }
    
    /// Step through the consolidated after-alarm flow once the alarm stack has
    /// fully drained: notes page(s) → verse card → weather card → app link
    /// (terminal). `AfterAlarmFlowView` sequences the cards; this method owns the
    /// presentation window and the terminal app-link fire.
    ///
    /// The `plan` is the merge of every banked contribution (see
    /// `AfterAlarmDeferralQueue.consolidatedPlan()`). For a single slept-through
    /// alarm it is that alarm's own action order, so backward compatibility is
    /// exact — the legacy four cases the old `showWeatherCardIfEligible` handled
    /// (`[]`, `[.weather]`, `[.appLink]`, `[.weather, .appLink]`) all reproduce
    /// verbatim. For several alarms it carries every distinct notes page plus one
    /// verse / weather / app link.
    ///
    /// The plan's content is a SNAPSHOT (al-bee.1): the flow may run long after
    /// the alarms it belongs to were dismissed, and an ephemeral alarm's SwiftData
    /// row is deleted on dismiss. `onComplete` fires when the flow reaches its
    /// terminal step — the caller uses it to clear the drained queue.
    private func runAfterAlarmFlow(
        plan: AfterAlarmFlowPlan,
        onComplete: @escaping () -> Void
    ) {
        // Never let a second flow overwrite a visible one (al-bee.3). Teardown
        // does NOT fire the outgoing flow's app link — it was interrupted, not
        // completed.
        teardownAfterAlarmWindow()

        let steps = plan.steps
        guard !steps.isEmpty else {
            onComplete()
            return
        }

        let appLinkURI = plan.appLinkURI

        // Fire the terminal app link at most once. `AfterAlarmFlowView` only
        // reaches its terminal step a single time, but guard anyway.
        var didFireAppLink = false
        let fireAppLinkOnce: () -> Void = { [weak self] in
            guard !didFireAppLink else { return }
            didFireAppLink = true
            self?.openAppLink(appLinkURI)   // no-op for nil/empty
        }

        // No visual step (app-link-only) → no window to present; fire directly,
        // exactly as the old app-link-only dismiss path did.
        guard plan.hasCard else {
            fireAppLinkOnce()
            onComplete()
            return
        }

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first
        else {
            // Can't present — don't swallow the terminal app link.
            fireAppLinkOnce()
            onComplete()
            return
        }

        // MEMORY DISCIPLINE: only decode the (large, full-screen) home wallpaper
        // when a step actually paints it. The Notes and Weather cards use it; the
        // Verse card renders its own downloaded, downsampled background and ignores
        // the wallpaper entirely. The old weather path loaded it ONLY inside
        // presentWeatherCard (i.e. only when the weather card was shown); loading
        // it unconditionally here would pin a ~24 MB wallpaper bitmap in the
        // NSCache on EVERY dismiss — including verse-only flows that never show it —
        // right as the user puts the phone down and the app backgrounds, raising
        // overnight jetsam risk for a process that deliberately stays resident
        // (see MemoryPressureMonitor / BackgroundAudioKeepAlive).
        let usesWallpaper = steps.contains { step in
            switch step {
            case .notes, .weather: return true
            case .verse, .appLink: return false
            }
        }
        let (wallpaper, isDark) = usesWallpaper
            ? loadWeatherWallpaper()
            : (nil, UITraitCollection.current.userInterfaceStyle == .dark)
        let verse = VerseOfDayService.shared.verseForToday()

        // Seed the live store for the FIRST notes page so an MQTT `notes` /
        // `append_notes` write arriving while it is up lands on screen. Keyed by
        // that page's alarm hash so a write aimed at a different alarm is ignored;
        // `AfterAlarmFlowView` re-keys the store as it advances to later pages.
        if let firstPage = plan.firstNotesPage {
            AfterAlarmNotesLive.shared.begin(
                alarmHash: firstPage.alarmHash,
                notes: firstPage.notes,
                commands: firstPage.commands
            )
        }

        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert  // Below alarm's .alert + 1 so new alarms cover it
        window.backgroundColor = .clear

        let flowView = AfterAlarmFlowView(
            steps: steps,
            verse: verse,
            wallpaper: wallpaper,
            wallpaperIsDark: isDark,
            liveNotes: true,
            onNotesPageWillShow: { page in
                AfterAlarmNotesLive.shared.begin(
                    alarmHash: page.alarmHash,
                    notes: page.notes,
                    commands: page.commands
                )
            },
            onWeatherWillAppear: { [weak self] in self?.publishAwakeState() },
            onFinished: { [weak self] in
                fireAppLinkOnce()
                self?.teardownAfterAlarmWindow(window)
                onComplete()
            }
        )

        let hostingController = UIHostingController(rootView: flowView)
        hostingController.view.backgroundColor = .clear
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        self.afterAlarmWindow = window
    }

    /// Hide and release the after-alarm flow window that is currently presented,
    /// if any. Called before presenting an alarm window or another flow (al-bee.3).
    ///
    /// Deliberately does NOT fire the flow's terminal app link: a torn-down flow
    /// was interrupted, not completed, and switching apps out from under a ringing
    /// alarm would be worse than losing the link. The interrupted contribution
    /// stays at the head of `deferredAfterAlarmFlows`, so it is re-presented when
    /// the stack drains.
    private func teardownAfterAlarmWindow() {
        guard let window = afterAlarmWindow else { return }
        teardownAfterAlarmWindow(window)
    }

    /// Teardown for a specific flow window. The stored reference is cleared only
    /// when it still points at this window, so a late `onFinished` from an older
    /// flow can never orphan a newer one.
    private func teardownAfterAlarmWindow(_ window: UIWindow) {
        AfterAlarmNotesLive.shared.end()
        window.isHidden = true
        if afterAlarmWindow === window { afterAlarmWindow = nil }
    }

    /// Present the after-alarm flow owed to the drained alarm stack, if any.
    ///
    /// The banked contributions merge into ONE consolidated flow (see
    /// `AfterAlarmDeferralQueue.consolidatedPlan()`): every distinct notes page,
    /// oldest contributor first, each its own full-page step with a Continue,
    /// followed by one verse, one weather and one app link. A stack of one is that
    /// alarm's own flow, unchanged. No further contributions can arrive — the stack
    /// has drained — so this is the last safe moment to decide the merge.
    ///
    /// The queue is cleared only when the flow COMPLETES. If it is torn down first
    /// (another alarm firing), nothing is cleared, so the whole flow is re-presented
    /// when the stack next drains — an interrupted sequence is never dropped.
    private func runDeferredAfterAlarmFlows() {
        guard !deferredAfterAlarmFlows.isEmpty else { return }
        let plan = deferredAfterAlarmFlows.consolidatedPlan()
        if plan.contributorCount > 1 {
            AppLogger.shared.log("After-alarm: consolidated flow for \(plan.contributorCount) alarms (\(plan.steps.count) steps)", category: .alarm)
        }
        runAfterAlarmFlow(plan: plan) { [weak self] in
            self?.deferredAfterAlarmFlows.removeAll()
        }
    }

    /// Publish the "awake" / day-started HA state. Called from the flow as the
    /// weather card is about to appear — the exact moment the old weather card
    /// published it, so flows that never show weather never publish "awake"
    /// (identical to before).
    private func publishAwakeState() {
        let settings = DeviceSettings.shared
        currentUserState = "awake"
        HAIntegrationRouter.shared.publishUserState("awake", settings: settings)
        HAIntegrationRouter.shared.publishDayStartedAt(
            ISO8601DateFormatter().string(from: Date()), settings: settings
        )
        startUserStateResetTimer()
    }

    /// Open a user-configured app link (deep link / Shortcut URL) after a
    /// dismiss or snooze completes. No-op for nil/empty/invalid strings.
    private func openAppLink(_ uriString: String?) {
        guard let trimmed = uriString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed) else { return }
        AppLogger.shared.log("Opening app link: \(trimmed)", category: .alarm)
        UIApplication.shared.open(url)
    }

    /// Load the wallpaper for the weather card. The app has a single wallpaper
    /// setting — the card uses the same home-theme wallpaper as the home list and
    /// alarm screen. Returns the image and the appearance it was loaded for (so the
    /// force-dark card can still position it with the matching home props).
    private func loadWeatherWallpaper() -> (image: UIImage?, isDark: Bool) {
        let settings = DeviceSettings.shared
        let isDark = UITraitCollection.current.userInterfaceStyle == .dark

        guard settings.homeWallpaperEnabled else { return (nil, isDark) }
        let key = settings.activeHomeWallpaperKey(forDark: isDark)
        return (settings.loadWallpaper(for: key), isDark)
    }
    
    /// Reset user_state to "unknown" after 16 hours
    private func startUserStateResetTimer() {
        userStateResetTimer?.invalidate()
        userStateResetTimer = Timer.scheduledTimer(withTimeInterval: 16 * 3600, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.currentUserState = "unknown"
                let s = DeviceSettings.shared
                HAIntegrationRouter.shared.publishUserState("unknown", settings: s)
                HAIntegrationRouter.shared.publishWakeAlarmName("none", settings: s)
                HAIntegrationRouter.shared.publishDayStartedAt("none", settings: s)
            }
        }
    }
    
    /// Present an alarm dequeued after a dismiss/snooze of the previous one.
    /// The dismiss/snooze path calls AlarmSoundPlayer.stop() (which LOCKS the
    /// player) and clears the ringing/pending state of the finished alarm.
    /// Without re-arming both here, the dequeued alarm's window appears but
    /// every play() is rejected by the lock — it rings silently.
    private func presentDequeuedAlarm(_ next: QueuedAlarm) {
        let store = PendingAlarmStore.shared
        store.setActiveRingingAlarm(next.alarmID)
        store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
            alarmID: next.alarmID,
            label: next.label,
            missionType: next.missionType,
            soundID: next.soundID,
            volumeLevel: nil
        )
        store.setPendingAlarmFull(
            alarmID: next.alarmID,
            label: next.label,
            missionType: next.missionType.rawValue,
            soundID: next.soundID,
            volumeLevel: nil
        )
        AlarmSoundPlayer.shared.unlock()

        // Alert alarms are transient security/notification alarms, never a wake
        // event (they don't even reach the DB), so they keep today's exact path:
        // showAlertAlarm presents and showAlarm's own sound task starts the tone.
        // Everything below resolves a per-alarm volume, which an alert has no
        // concept of.
        guard next.missionType != .alert else {
            showAlarm(alarmID: next.alarmID, label: next.label, missionType: next.missionType, soundID: next.soundID)
            return
        }

        // Radio: a dequeued alarm never attempted its stream (al-fzd). QueuedAlarm
        // deliberately carries no radio fields — it is a presentation record, and
        // the station is a property of the alarm — so re-resolve from the store by
        // hash, the same source the AlarmKit fire path uses.
        let radio = resolveRadioFields(alarmID: next.alarmID)

        // Drive the audio here for EVERY dequeued alarm, radio or tone-only
        // (al-be2), so the dequeued ring gets the same treatment as a fire:
        // system volume established first, silent (volume 0) entry, concurrent
        // stream attempt where there is a station, capped confirmation grace,
        // tone as the guaranteed fallback.
        //
        // showAlarm's own sound task cannot do this. It starts the tone at FULL
        // player volume on top of whatever the user's media volume happens to be
        // — the dismiss/snooze that drained the queue called
        // restoreOriginalVolume(), which put that volume back and cancelled the
        // fade — so alarm 2 rang at the user's normal listening level, ignoring
        // its own volume setting entirely. It also never calls beginAttempt,
        // which is why a dequeued radio alarm always rang tone-only.
        //
        // No fresh fade is armed, in either direction. The ramp was deliberately
        // cancelled on dismiss, and re-arming one here would insert new silence
        // into a wake-up that is already late by the length of the previous
        // alarm's missions. The alarm rings at its own resolved volume — where a
        // fade would have ended anyway — which is also what it would have done
        // had it fired alone with fade-in off.
        showAlarm(
            alarmID: next.alarmID,
            label: next.label,
            missionType: next.missionType,
            soundID: next.soundID,
            startSoundIfNeeded: false
        )
        Task { @MainActor in
            // The dismiss/snooze that drained the queue restored the user's
            // system volume (restoreOriginalVolume) and cancelled any fade, so
            // this ring has to establish its own level exactly like a fire does.
            let volume = self.resolveAlarmVolume(alarmID: next.alarmID)
            await VolumeManager.shared.setSystemVolumeBeforePlayback(to: volume)

            guard PendingAlarmStore.shared.activeRingingAlarmID() == next.alarmID,
                  !self.isGracePeriodMuted,
                  AlarmSoundPlayer.shared.unlockIfRinging() else {
                AppLogger.shared.log("Dequeued alarm: '\(next.label)' resolved before audio started — skipping", category: .alarm)
                return
            }
            await AlarmSoundPlayer.shared.play(soundID: next.soundID, initialVolume: 0.0)
            if !AlarmSoundPlayer.shared.isPlaying {
                // Same single retry the fire paths do for the intermittent
                // '!int' audio-session error.
                try? await Task.sleep(nanoseconds: 500_000_000)
                await AlarmSoundPlayer.shared.play(soundID: next.soundID, initialVolume: 0.0)
            }
            guard PendingAlarmStore.shared.activeRingingAlarmID() == next.alarmID else {
                AlarmSoundPlayer.shared.stop()
                return
            }
            // Tone-only alarms skip the stream attempt and its grace, but keep the
            // 1-second silent entry — the fire paths take it unconditionally too.
            if let radioURL = radio.url {
                RadioAlarmStreamer.shared.beginAttempt(
                    stationID: radio.id,
                    stationName: radio.name,
                    urlString: radioURL
                )
            }
            try? await Task.sleep(for: .seconds(1))
            if radio.url != nil {
                await RadioAlarmStreamer.shared.waitForConfirmation(
                    upTo: RadioAlarmStreamer.shared.confirmationGrace
                )
            }
            // A dismiss during the silent entry / radio grace must not raise a
            // volume or arm a ramp for a ring that no longer exists.
            guard PendingAlarmStore.shared.activeRingingAlarmID() == next.alarmID else {
                AppLogger.shared.log("Dequeued alarm: dismissed during silent entry — skipping volume raise", category: .audio)
                return
            }
            // If the stream confirmed, this raise routes to the radio player and
            // the wav stays muted as hot standby (setPlayerVolume).
            if VolumeManager.shared.fadeActive {
                VolumeManager.shared.ensureFadeRunning()
            } else {
                AlarmSoundPlayer.shared.setPlayerVolume(1.0)
            }
            if AlarmSoundPlayer.shared.isPlaying {
                AlarmRingReporter.shared.audioStarted()
            } else {
                AlarmRingReporter.shared.audioFailed()
            }
            AppLogger.shared.log("Dequeued alarm: '\(next.label)' vol=\(String(format: "%.0f%%", volume * 100)) station='\(radio.name ?? radio.url ?? "none")' streaming=\(RadioAlarmStreamer.shared.isStreaming) isPlaying=\(AlarmSoundPlayer.shared.isPlaying)", category: .alarm)
        }
    }

    // MARK: - Mission consolidation (al-bee.7)

    /// Latch the alarm currently on screen as engaged (al-bee.11). Called from
    /// `ActiveAlarmView` at every point the user interacts with the ring — a
    /// Start Mission tap, an HA/alert alarm reaching its mission screen, a snooze
    /// press-and-hold, a dismiss/grace hold, or a grace period starting. Once set
    /// the queue-change consolidation leaves this presentation alone, so a
    /// harder alarm arriving later can never swap the demanded set out from under
    /// the user. Idempotent.
    func noteShowingAlarmEngaged() {
        showingAlarmEngaged = true
    }

    /// Resolve mission consolidation at a QUEUE CHANGE (al-bee.11).
    ///
    /// `applyMissionConsolidation` only runs at a dismiss junction, so it
    /// compares a queued alarm against work already completed — an ascending
    /// stack (a weak alarm showing, a strictly harder one queued behind it, the
    /// user still asleep) is never resolved until the weak alarm is dismissed, by
    /// which point its set has already been demanded. This closes that gap: while
    /// the showing alarm is still UNENGAGED and a queued alarm is strictly
    /// harder, the showing alarm is rolled into the stack by driving the ordinary
    /// `dismissAlarm` path — which then collapses the weaker queued alarms,
    /// imposes the strictest snooze cap and presents the harder alarm with its
    /// own audio. All of that is the SAME code the dismiss junction runs; this
    /// only decides whether to take it.
    ///
    /// Scheduled from `showAlarm`'s queue branch as a `Task` so it runs after the
    /// firing alarm's fire path unwinds — the showing alarm must never be
    /// dismissed re-entrantly mid-call. Every precondition is therefore
    /// re-verified against live state here.
    @MainActor
    private func resolveQueueChangeConsolidation(showingID: Int, queuedID: Int) {
        // Consolidation is always on (product decision 2026-08-06).

        // The showing alarm may have been dismissed or replaced, or the queued
        // entry drained, while this task waited to run. Re-verify both.
        guard isShowingAlarm, currentAlarmID == showingID else { return }
        guard let entry = alarmQueue.first(where: { $0.alarmID == queuedID }) else { return }

        // No DB row (synthetic-only / ephemeral / deleted) → present normally,
        // never collapse an alarm we cannot rank.
        guard let showingRow = dbAlarm(forHash: showingID) else { return }

        // Engagement — or an active grace mute, belt and braces — latches the
        // requirement permanently for this presentation.
        let engaged = showingAlarmEngaged || isGracePeriodMuted

        // The showing alarm is by construction the OLDEST ring; its timestamp is
        // never consulted (recency only breaks ties between queued alarms).
        let showing = stackedAlarm(for: showingRow, alarmID: showingID, ringStartedAt: .distantPast)

        // Same omission rule as the dismiss junction: an unrankable entry stays
        // queued and is presented as today.
        let queued: [StackedAlarm] = alarmQueue.compactMap { q in
            guard let row = dbAlarm(forHash: q.alarmID) else { return nil }
            return stackedAlarm(for: row, alarmID: q.alarmID, ringStartedAt: q.queuedAt)
        }

        let plan = MissionConsolidationResolution.resolveOnQueueChange(
            showing: showing,
            showingEngaged: engaged,
            queued: queued
        )
        guard !plan.isNoOp else { return }   // silent by design — no log

        AppLogger.shared.log(
            "Mission consolidation (queue change): showing '\(showingRow.label)' unengaged, queued '\(entry.label)' is strictly harder — rolling the showing alarm into the stack",
            category: .alarm
        )

        // Drive the ordinary dismiss path. It records the showing alarm as
        // `dismissed` on its own index, runs `applyMissionConsolidation` against
        // the rest of the queue (collapsing the weaker alarms and computing the
        // snooze cap including this alarm's allowance) and presents the promoted
        // alarm via `presentDequeuedAlarm` with its own audio.
        dismissAlarm(alarm: showingRow, alarmID: showingID)
    }

    /// The DB row for an alarm hash, or nil for a synthetic / alert / deleted
    /// alarm. Read-only lookup — no mutation, no save.
    private func dbAlarm(forHash hash: Int) -> AppAlarm? {
        guard let container = modelContainer,
              let alarms = try? container.mainContext.fetch(FetchDescriptor<AppAlarm>()) else {
            return nil
        }
        return alarms.first { $0.stableHash == hash }
    }

    /// Reduce an alarm to the facts `MissionConsolidationResolution` ranks on.
    private func stackedAlarm(for alarm: AppAlarm, alarmID: Int, ringStartedAt: Date) -> StackedAlarm {
        let settings = DeviceSettings.shared
        let sequence = alarm.missionSequence
        let maxSnoozes = alarm.maxSnoozeCount ?? settings.defaultMaxSnoozeCount
        return StackedAlarm(
            alarmID: alarmID,
            isAlert: alarm.mission.type == .alert,
            missionCount: sequence.count,
            // The app's own existing proxy for how long a mission set takes.
            totalGracePeriod: sequence.reduce(0) { $0 + $1.calculatedGracePeriod },
            ringStartedAt: ringStartedAt,
            snoozesRemaining: MissionConsolidationResolution.snoozesRemaining(
                maxSnoozeCount: maxSnoozes,
                snoozeCount: alarm.snoozeCount
            )
        )
    }

    /// Ask the resolution what the stack behind `dismissedAlarm` still owes, and
    /// apply the QUEUE half of the answer (remove the collapsed entries, record
    /// the survivor's snooze cap). The collapsed alarms' own dismissals are
    /// performed later by `collapseStackedAlarm`, after the dismissing alarm has
    /// banked its after-alarm contribution, so the drained flows stay in
    /// oldest-contributor-first order.
    ///
    /// Runs at the dismiss junction only — never while a mission is on screen —
    /// so a harder alarm arriving mid-mission cannot change work in flight.
    private func applyMissionConsolidation(dismissedAlarm: AppAlarm, alarmID: Int) -> MissionConsolidationResolution.Plan {
        // Consolidation is always on (product decision 2026-08-06); it only ever
        // has work to do when something is queued behind the dismissed alarm.
        guard !alarmQueue.isEmpty else {
            return MissionConsolidationResolution.noOp
        }

        // The alarm on screen is by construction the OLDEST ring in the stack —
        // everything else fired while it was showing. Its timestamp is never
        // consulted anyway: recency only breaks ties BETWEEN queued alarms.
        let dismissed = stackedAlarm(for: dismissedAlarm, alarmID: alarmID, ringStartedAt: .distantPast)

        // An entry with no DB row (a synthetic alarm, an inbound alert, a row
        // deleted under us) is OMITTED rather than guessed at: it cannot be
        // ranked, so it is neither a candidate to survive nor eligible to be
        // collapsed, and it stays queued and is presented exactly as today.
        let queued: [StackedAlarm] = alarmQueue.compactMap { entry in
            guard let row = dbAlarm(forHash: entry.alarmID) else { return nil }
            return stackedAlarm(for: row, alarmID: entry.alarmID, ringStartedAt: entry.queuedAt)
        }

        let plan = MissionConsolidationResolution.resolve(
            dismissed: dismissed,
            queued: queued
        )
        guard !plan.isNoOp else { return plan }

        let collapsed = Set(plan.collapsedAlarmIDs)
        alarmQueue.removeAll { collapsed.contains($0.alarmID) }

        // The survivor must not inherit the whole stack's snoozes.
        if let survivor = plan.survivingQueuedAlarmID,
           let cap = plan.snoozeAllowance,
           cap != MissionConsolidationResolution.unlimitedSnoozes {
            consolidatedSnoozeCaps[survivor] = cap
        }

        AppLogger.shared.log(
            "Mission consolidation: collapsing \(plan.collapsedAlarmIDs.count) stacked alarm(s), survivor=\(plan.survivingQueuedAlarmID.map(String.init) ?? "none (dismissed alarm was hardest)") snoozeCap=\(plan.snoozeAllowance.map { $0 == MissionConsolidationResolution.unlimitedSnoozes ? "∞" : "\($0)" } ?? "none")",
            category: .alarm
        )
        return plan
    }

    /// Dismiss a stacked alarm the user never had to look at.
    ///
    /// It was a real wake event and the user is awake, so it is recorded as
    /// **dismissed** — not skipped, not failed. Everything a normal dismissal
    /// owes the alarm ITSELF happens here: snooze state reset, plain `dismissed`
    /// published on its own index (never a new state string — every automation
    /// keys on `to: "dismissed"`), its after-alarm sequence banked so nobody's
    /// notes are destroyed, and the `AlarmDismissed` post that clears its
    /// AlarmKit tiers (stop-then-cancel, via `DualAlarmCoordinator.cancelAlarm`)
    /// and reschedules it through the normal path.
    ///
    /// What it deliberately does NOT do is anything global: no audio, no volume,
    /// no window, no device-wide alarm state. Those belong to the dismissal that
    /// finds the stack empty.
    private func collapseStackedAlarm(alarmID: Int) {
        guard let alarm = dbAlarm(forHash: alarmID) else {
            // Cannot happen — `applyMissionConsolidation` only collapses alarms
            // it resolved a row for — but a missing row must never be a crash.
            AppLogger.shared.log("Mission consolidation: no row for collapsed alarm hash=\(alarmID) — skipped", category: .alarm)
            return
        }

        // Snapshot BEFORE the AlarmDismissed post, which lets an ephemeral alarm
        // delete its SwiftData row. Reading it afterwards is a crash, not a
        // blank page (the hazard AfterAlarmNotesLive documents).
        let contribution = AfterAlarmContribution.snapshot(of: alarm)
        let alarmIndex = alarm.alarmIndex
        let label = alarm.label
        let settings = DeviceSettings.shared

        DualAlarmCoordinator.shared.cancelFailsafe(for: alarmID)
        DualAlarmCoordinator.shared.cancelRingingGuard(forAlarmHash: alarmID)
        // Close the unresolved ring (al-bee.5) — a no-op when this alarm never
        // opened one. The entry is NOT deleted: it still slept through.
        UnresolvedRingLedger.shared.noteUserAction(alarmHash: alarmID)

        alarm.isSnoozed = false
        alarm.snoozeUntil = nil
        alarm.snoozeCount = 0
        consolidatedSnoozeCaps.removeValue(forKey: alarmID)

        NotificationCenter.default.post(
            name: NSNotification.Name("AlarmDismissed"),
            object: nil,
            userInfo: ["alarmID": alarmID, "alarmLabel": label]
        )

        if alarmIndex > 0 {
            HAIntegrationRouter.shared.publishPerAlarmStateTransition(
                alarmIndex: alarmIndex,
                state: AlarmDismissResolution.perAlarmDismissState,
                snoozeAllowed: false,
                settings: settings
            )
            HAIntegrationRouter.shared.publishPerAlarmSnoozesRemaining(alarmIndex: alarmIndex, remaining: 0, settings: settings)
            HAIntegrationRouter.shared.publishPerAlarmSnoozeFireTime(alarmIndex: alarmIndex, snoozeUntil: nil, settings: settings)
        }

        // Its notes / verse / weather / app link still bank and drain with the
        // rest of the stack. Consolidating the SEQUENCE is a separate bead.
        deferredAfterAlarmFlows.record(contribution)

        AppLogger.shared.log("Alarm collapsed into the stack's dismissal: '\(label)' index=\(alarmIndex)", category: .alarm)
    }

    /// The stored station for an alarm hash. The recovery blob does NOT cache
    /// radio fields, so this is DB-only and returns all-nil for a synthetic
    /// (cache-reconstructed) alarm — which degrades to a tone-only ring, never
    /// to a failure.
    private func resolveRadioFields(alarmID: Int) -> (id: String?, name: String?, url: String?) {
        guard let container = modelContainer,
              let alarms = try? container.mainContext.fetch(FetchDescriptor<AppAlarm>()),
              let match = alarms.first(where: { $0.stableHash == alarmID }) else {
            return (nil, nil, nil)
        }
        return (match.radioStationID, match.radioStationName, match.radioStationURL)
    }

    /// The target system volume for an alarm hash: its per-alarm override when
    /// it has one, otherwise the global setting.
    private func resolveAlarmVolume(alarmID: Int) -> Float {
        let settings = DeviceSettings.shared
        if let container = modelContainer,
           let alarms = try? container.mainContext.fetch(FetchDescriptor<AppAlarm>()),
           let match = alarms.first(where: { $0.stableHash == alarmID }),
           let custom = match.customVolumeLevel {
            return Float(custom)
        }
        return Float(settings.alarmVolumeLevel)
    }

    private func dismissAlarm(alarm: AppAlarm, alarmID: Int) {
        // FIRST: kill audio immediately so the user gets instant feedback.
        // stop() also locks the player, preventing any queued async Tasks
        // from restarting sound via unlock()+play().
        AlarmSoundPlayer.shared.stop()

        print("✅ Dismissing alarm window for ID: \(alarmID)")
        AppLogger.shared.log("Alarm dismissed: '\(alarm.label)' snoozeCount=\(alarm.snoozeCount)", category: .alarm)

        // Snapshot the after-alarm sequence and the alarm's own MQTT index BEFORE
        // anything else touches the model. The `AlarmDismissed` post below lets an
        // ephemeral alarm delete its SwiftData row, and the sequence may not run
        // until the rest of the stack has been dealt with (al-bee.1) — reading
        // these later is a crash, not a blank page.
        let contribution = AfterAlarmContribution.snapshot(of: alarm)
        let alarmIndex = alarm.alarmIndex

        // Closes the ring — read before the snooze state is reset below.
        AlarmRingReporter.shared.ringEnded(outcome: .dismissed, snoozeCount: alarm.snoozeCount)

        // Cancel ringing guard (if active) since alarm is being dismissed
        DualAlarmCoordinator.shared.cancelRingingGuard(forAlarmHash: alarmID)

        // Cancel backup alarm notification and clear ALL persisted recovery state
        cancelBackupAlarmNotification()
        PendingAlarmStore.shared.clearPersistedPendingAlarm()
        PendingAlarmStore.shared.clearActiveRingingAlarm()
        // Close the unresolved ring (al-bee.5). The entry is NOT deleted: a
        // dismissal hours late is still a slept-through morning, and it must
        // still be counted for the day the alarm actually rang.
        UnresolvedRingLedger.shared.noteUserAction(alarmHash: alarmID)
        AlarmKitScheduler.shared.clearHandlingAlarm()

        // Reset snooze state
        alarm.isSnoozed = false
        alarm.snoozeUntil = nil
        alarm.snoozeCount = 0

        // Stop alarm notifications.
        AlarmLiveActivityManager.shared.stopAlarmNotificationsInBackground()

        // Post notification so AlarmListView can update the alarm model
        NotificationCenter.default.post(
            name: NSNotification.Name("AlarmDismissed"),
            object: nil,
            userInfo: ["alarmID": alarmID, "alarmLabel": alarm.label]
        )

        self.alarmWindow?.isHidden = true
        self.alarmWindow = nil
        self.currentAlarm = nil
        self.currentAlarmID = nil

        // Clear grace period flag so next alarm fire isn't blocked
        self.isGracePeriodMuted = false

        // Restore volume
        VolumeManager.shared.restoreOriginalVolume()

        // Mission consolidation (al-bee.7). Resolved HERE, before the dismiss
        // outcome below, because collapsing the stack can empty the queue and
        // the outcome depends on whether anything is still queued.
        //
        // With an empty queue — the 99% case — this is a total no-op and the
        // rest of this function is byte-for-byte what it was. The setting is the
        // other exit: OFF returns the same no-op before looking at anything.
        //
        // Only the QUEUE is mutated here. Each collapsed alarm's own dismissal
        // runs further down, after this alarm has banked its after-alarm
        // sequence, so the drained flows keep oldest-contributor-first order.
        self.consolidatedSnoozeCaps.removeValue(forKey: alarmID)
        let consolidation = applyMissionConsolidation(dismissedAlarm: alarm, alarmID: alarmID)

        // What this dismiss owes the alarm itself vs. the device's global state.
        // The per-alarm publish and the sleep-sound resume used to sit in the
        // queue-empty branch below, so a stacked alarm was left on `ringing` in
        // Home Assistant forever (al-bee.1).
        let resolution = AlarmDismissResolution.resolve(
            alarmIndex: alarmIndex,
            hasQueuedAlarms: !alarmQueue.isEmpty,
            hasAfterAlarmSteps: !contribution.isEmpty
        )
        let settings = DeviceSettings.shared

        if resolution.clearsGlobalActiveAlarm && !alarm.excludeFromMQTT {
            // Nothing left ringing — publish the global dismissed state and clear
            // the active-alarm topics. Skipped while alarms are queued: one of them
            // is about to become the active alarm, and clearing would flap the
            // entity. Published FIRST, so the message order a single-alarm dismiss
            // puts on the wire is unchanged. An MQTT-hidden alarm (al-5a94) skips
            // the whole block: its ring never set the global state, so a
            // "dismissed" here would flap HA idle → dismissed for an alarm HA
            // never saw.
            HAIntegrationRouter.shared.publishAlarmState(.dismissed, settings: settings)
            HAIntegrationRouter.shared.activeAlarmIndex = nil
            HAIntegrationRouter.shared.publishActiveAlarmIndex(nil, settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmName(nil, settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmDays("none", settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmFireTime(nil, settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmSnoozeFireTime(nil, settings: settings)
            HAIntegrationRouter.shared.publishActiveAlarmMission("none", settings: settings)
            HAIntegrationRouter.shared.publishSnoozeCount(0, settings: settings)
            HAIntegrationRouter.shared.publishSnoozesRemaining(0, settings: settings)
        }

        // Per-alarm dismissed state — unconditional. Plain `dismissed`, never a
        // new state string: every automation with `to: "dismissed"` depends on it.
        if resolution.publishesPerAlarmDismissed {
            HAIntegrationRouter.shared.publishPerAlarmStateTransition(alarmIndex: alarmIndex, state: AlarmDismissResolution.perAlarmDismissState, snoozeAllowed: false, settings: settings)
            HAIntegrationRouter.shared.publishPerAlarmSnoozesRemaining(alarmIndex: alarmIndex, remaining: 0, settings: settings)
            HAIntegrationRouter.shared.publishPerAlarmSnoozeFireTime(alarmIndex: alarmIndex, snoozeUntil: nil, settings: settings)
        }

        // End any sleep sound this ring paused — the user completed the alarm,
        // they are awake, so the rain does not fade back in (al-3jm). Stopping
        // rather than resuming also removes the stacked-alarm blip (al-bee.1):
        // nothing plays for a fraction of a second between two rings. A sleep
        // sound the *user* paused is left alone.
        SleepSoundManager.shared.handleAlarmEnded(.dismissed, hasQueuedAlarms: !alarmQueue.isEmpty)

        // Record this alarm's after-alarm sequence (verse → weather → app link, or
        // whatever it configured). It runs now if nothing is queued; otherwise it
        // waits for the stack to drain rather than painting UNDER the next alarm's
        // window — which is the al-bee.3 stale-card bug.
        if resolution.recordsAfterAlarmContribution {
            deferredAfterAlarmFlows.record(contribution)
            if !resolution.drainsAfterAlarmFlows {
                AppLogger.shared.log("After-alarm: deferring sequence for '\(contribution.alarmLabel)' — \(alarmQueue.count) alarm(s) still queued", category: .alarm)
            }
        }

        // Now dismiss every alarm the user was spared. After this alarm's own
        // record, because they fired later and the flows drain oldest first.
        for collapsedID in consolidation.collapsedAlarmIDs {
            collapseStackedAlarm(alarmID: collapsedID)
        }

        // Show next queued alarm, or run the after-alarm sequences owed by every
        // alarm in the drained stack (oldest contributor first).
        if let next = alarmQueue.first {
            alarmQueue.removeFirst()
            print("=== DIAG === Dequeuing next alarm: \(next.label) (alarmID=\(next.alarmID)), remaining=\(alarmQueue.count)")
            AppLogger.shared.log("Alarm queue: dequeuing '\(next.label)' after dismiss, remaining=\(alarmQueue.count)", category: .alarm)
            presentDequeuedAlarm(next)
        } else if resolution.drainsAfterAlarmFlows {
            // For a single alarm this is byte-for-byte the old behavior: one
            // contribution, presented immediately. [.weather] shows the Good
            // Morning card, [.appLink] fires the dismiss link, [] does nothing.
            runDeferredAfterAlarmFlows()
        }
    }
    
    private func snoozeAlarm(alarm: AppAlarm, alarmID: Int, context: ModelContext) {
        print("💤 Snoozing alarm for ID: \(alarmID)")
        let _maxForLog = alarm.maxSnoozeCount ?? DeviceSettings.shared.defaultMaxSnoozeCount
        AppLogger.shared.log("Alarm snoozed: '\(alarm.label)' count=\(alarm.snoozeCount + 1)/\(_maxForLog == 0 ? "∞" : "\(_maxForLog)") duration=\(alarm.snoozeDuration)min", category: .alarm)

        // Stop sound immediately — the snooze button already calls stop() before
        // onSnooze(), but this covers the MQTT/HA snooze path which doesn't.
        // stop() also locks the player, preventing queued async Tasks from restarting.
        AlarmSoundPlayer.shared.stop()

        // Restore the user's media volume for the snooze interval — no alarm sound
        // is playing during snooze, so the volume we raised must come back down.
        // The snooze re-fire re-raises (and re-saves) it. Done while the alarm
        // window is still up so the MPVolumeView slider is in a live key window.
        VolumeManager.shared.restoreOriginalVolume()

        // Cancel ringing guard (if active) since alarm is being snoozed
        DualAlarmCoordinator.shared.cancelRingingGuard(forAlarmHash: alarmID)

        // Cancel backup alarm notification and clear ALL persisted recovery state
        cancelBackupAlarmNotification()
        PendingAlarmStore.shared.clearPersistedPendingAlarm()
        PendingAlarmStore.shared.clearActiveRingingAlarm()
        // Close the unresolved ring (al-bee.5). A snooze ATTENDS the ring it
        // ends — the user pressed a button — but does not resolve the alarm:
        // the re-fire opens a new ring on the same entry, so a
        // snoozed-then-slept-through alarm still counts once, not twice.
        UnresolvedRingLedger.shared.noteUserAction(alarmHash: alarmID)
        AlarmKitScheduler.shared.clearHandlingAlarm()

        // Update snooze state
        alarm.isSnoozed = true
        alarm.snoozeCount += 1

        // Closes the ring (the snooze re-fire opens a new one).
        AlarmRingReporter.shared.ringEnded(outcome: .snoozed, snoozeCount: alarm.snoozeCount)

        // In debug quick-snooze mode, override duration to seconds instead of minutes
        #if DEBUG
        let snoozeInterval: TimeInterval
        if DeviceSettings.shared.debugQuickSnoozeEnabled {
            snoozeInterval = TimeInterval(DeviceSettings.shared.debugQuickSnoozeDelay)
            print("🐛 DEBUG: Quick snooze in \(DeviceSettings.shared.debugQuickSnoozeDelay)s")
        } else {
            snoozeInterval = TimeInterval(alarm.snoozeDuration * 60)
        }
        #else
        let snoozeInterval = TimeInterval(alarm.snoozeDuration * 60)
        #endif
        alarm.snoozeUntil = Date().addingTimeInterval(snoozeInterval)

        // Snapshot the app link before the async work below (al-bee.1).
        let snoozeAppURI = alarm.snoozeAppURI

        // Save context
        try? context.save()

        // Update cached alarm info so ringing guard picks up correct snooze count
        PendingAlarmStore.shared.storeFullAlarmInfo(alarmID: alarmID, alarm: alarm)

        // CRITICAL: Schedule the AlarmKit snooze failsafe and THEN dismiss the UI.
        // This is wrapped in a single Task so we await the failsafe schedule()
        // before hiding the alarm window. If the window is hidden first (in
        // synchronous code), the user can swipe-kill before the async schedule()
        // call in a fire-and-forget Task completes, leaving no AlarmKit alarm.
        Task { @MainActor in
            // 1. Schedule AlarmKit snooze failsafe (survives force-kill)
            if let snoozeUntil = alarm.snoozeUntil {
                let failsafeOK = await AlarmKitScheduler.shared.scheduleSnoozeFailsafe(
                    alarm: alarm,
                    alarmID: alarmID,
                    snoozeUntil: snoozeUntil
                )
                if failsafeOK {
                    print("[ALARM-STATE] snoozeAlarm: AlarmKit failsafe confirmed scheduled before window dismiss")
                } else {
                    print("[ALARM-STATE] snoozeAlarm: ⚠️ AlarmKit failsafe FAILED — snooze re-fire depends on the in-app timer only")
                    AppLogger.shared.log("Snooze failsafe UNCONFIRMED for '\(alarm.label)' — force-kill during snooze will not be covered", category: .alarm)
                }
            }

            // 2. Publish snooze state to MQTT
            let snoozeSettings = DeviceSettings.shared
            HAIntegrationRouter.shared.publishAlarmState(.snoozed, settings: snoozeSettings)
            HAIntegrationRouter.shared.publishSnoozeCount(alarm.snoozeCount, settings: snoozeSettings)
            let maxSnoozes = alarm.maxSnoozeCount ?? snoozeSettings.defaultMaxSnoozeCount
            let remaining = maxSnoozes == 0 ? Int.max : max(0, maxSnoozes - alarm.snoozeCount)
            HAIntegrationRouter.shared.publishSnoozesRemaining(remaining, settings: snoozeSettings)
            HAIntegrationRouter.shared.publishActiveAlarmSnoozeFireTime(alarm.snoozeUntil, settings: snoozeSettings)
            
            // Per-alarm snoozed state + snoozes remaining
            if alarm.alarmIndex > 0 {
                let snoozeAllowed = HAIntegrationRouter.shared.isSnoozeAllowedForAlarm(alarm, snoozesRemaining: remaining, settings: snoozeSettings)
                HAIntegrationRouter.shared.publishPerAlarmStateTransition(alarmIndex: alarm.alarmIndex, state: .snoozed, snoozeAllowed: snoozeAllowed, settings: snoozeSettings)
                HAIntegrationRouter.shared.publishPerAlarmSnoozesRemaining(alarmIndex: alarm.alarmIndex, remaining: remaining, settings: snoozeSettings)
                HAIntegrationRouter.shared.publishPerAlarmSnoozeFireTime(alarmIndex: alarm.alarmIndex, snoozeUntil: alarm.snoozeUntil, settings: snoozeSettings)
            }

            // 3. Stop alarm notifications — they'll restart when snooze ends
            AlarmLiveActivityManager.shared.stopAlarmNotificationsInBackground()

            // 4. NOW hide the alarm window (failsafe is confirmed scheduled)
            self.alarmWindow?.isHidden = true
            self.alarmWindow = nil
            self.currentAlarm = nil
            self.currentAlarmID = nil
            self.isGracePeriodMuted = false

            // 5. Schedule the in-app snooze timer (fires when app is alive)
            await self.scheduleSnoozeNotification(alarm: alarm, alarmID: alarmID)

            // 6. Show next queued alarm if any are waiting. The per-alarm snooze
            // app link fires either way (al-bee.1) — it used to be dropped
            // silently whenever another alarm was stacked behind this one. Fired
            // AFTER the dequeued alarm is presented so the next ring is never
            // delayed by an app switch.
            let hasQueuedAlarms = !self.alarmQueue.isEmpty
            if let next = self.alarmQueue.first {
                self.alarmQueue.removeFirst()
                print("=== DIAG === Dequeuing next alarm after snooze: \(next.label) (alarmID=\(next.alarmID)), remaining=\(self.alarmQueue.count)")
                self.presentDequeuedAlarm(next)
            }

            // 7. Sleep sounds stop for good once an alarm has fired — snoozing
            // no longer brings them back (al-ecf, superseding al-3jm). The user
            // restarts them manually.
            SleepSoundManager.shared.handleAlarmEnded(.snoozed, hasQueuedAlarms: hasQueuedAlarms)

            self.openAppLink(snoozeAppURI)
        }
    }
    
    private func scheduleSnoozeNotification(alarm: AppAlarm, alarmID: Int) async {
        guard let snoozeUntil = alarm.snoozeUntil else { return }
        
        // Store vibration preference for the snooze re-fire.
        // When fade-in is active, always vibrate — audio starts quiet but
        // the user still needs tactile feedback.
        let snoozeVibrationEnabled = alarm.effectiveVibrationEnabled(settings: DeviceSettings.shared)
        let snoozeFadeInEnabled = alarm.effectiveFadeInEnabled(settings: DeviceSettings.shared)
        AlarmLiveActivityManager.shared.vibrationEnabled = snoozeVibrationEnabled || snoozeFadeInEnabled
        
        // NOTE: the AlarmKit snooze failsafe is NOT scheduled here. Both callers
        // (snoozeAlarm and performDirectSnooze) schedule + confirm it BEFORE
        // hiding the alarm window. Re-scheduling here cancelled and re-created
        // the just-confirmed failsafe, opening a second unprotected window.

        // Schedule an in-app timer for the snooze.
        // This ensures the alarm fires even if the phone is locked.
        let alarmLabel = alarm.label
        let missionType = alarm.mission.type
        let soundID = alarm.soundName
        let snoozeAlarmVolume = alarm.effectiveVolumeLevel(settings: DeviceSettings.shared)
        let snoozeAlarmVibration = alarm.effectiveVibrationEnabled(settings: DeviceSettings.shared)
        let snoozeFadeIn = alarm.effectiveFadeInEnabled(settings: DeviceSettings.shared)
        let snoozeFadeInSeconds = alarm.effectiveFadeInDurationSeconds(settings: DeviceSettings.shared)
        let radioStationID = alarm.radioStationID
        let radioStationName = alarm.radioStationName
        let radioStationURL = alarm.radioStationURL

        let fireInterval = snoozeUntil.timeIntervalSinceNow
        guard fireInterval > 0 else { return }
        
        print("=== DIAG === Setting up snooze timer: fires in \(Int(fireInterval))s")
        
        // Cancel any existing snooze timer for this alarm
        LocalNotificationScheduler.shared.snoozeTimers[alarmID]?.invalidate()
        
        let timer = Timer.scheduledTimer(withTimeInterval: fireInterval, repeats: false) { _ in
            print("=== DIAG === ⏰ SNOOZE TIMER FIRED at \(Date()) for: \(alarmLabel)")
            
            Task { @MainActor in
                AppLogger.shared.log("Snooze timer fired: '\(alarmLabel)'", category: .alarm)
                // A snooze re-fire is a fresh ring, delivered by the in-app
                // timer at the snooze's due time.
                AlarmRingReporter.shared.willDeliver(path: .primaryTimer, expectedFire: snoozeUntil)
                PendingAlarmStore.shared.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                    alarmID: alarmID,
                    label: alarmLabel,
                    missionType: missionType,
                    soundID: soundID,
                    volumeLevel: snoozeAlarmVolume
                )
                
                // Cancel AlarmKit snooze failsafe — primary timer fired successfully
                AppLogger.shared.log("Snooze re-fire: cancelling AlarmKit failsafe (timer fired first) hash=\(alarmID)", category: .alarm)
                AlarmKitScheduler.shared.cancelSnoozeFailsafe(forAlarmHash: alarmID)
                // Mark alarm as actively ringing so the duplicate guard in handleAlarmAlerting
                // correctly suppresses the AlarmKit snooze failsafe if it fires late.
                PendingAlarmStore.shared.setActiveRingingAlarm(alarmID)
                
                // Clear snooze-active flags on the alarm model — the snooze period is over.
                // Without this, isSnoozed stays true in SwiftData if the alarm
                // dismissal doesn't complete (e.g., app killed during re-ring).
                // NOTE: snoozeCount is intentionally preserved so max-snooze
                // enforcement works across multiple snooze cycles. It is only
                // reset to 0 in dismissAlarm() when the alarm is fully dismissed.
                if let container = AlarmWindowManager.shared.modelContainer {
                    let ctx = container.mainContext
                    if let allAlarms = try? ctx.fetch(FetchDescriptor<AppAlarm>()),
                       let dbAlarm = allAlarms.first(where: { $0.stableHash == alarmID }) {
                        dbAlarm.isSnoozed = false
                        dbAlarm.snoozeUntil = nil
                        try? ctx.save()
                    }
                }
                
                // Same question the primary fire path asks (al-3ox): a snooze
                // re-fire landing while a DIFFERENT alarm is on screen is queued
                // by showAlarm below, so the audio below is not ours — it would
                // tear down the showing alarm's confirmed stream, move the system
                // volume and unlock the player into a mission grace period's
                // silence. Sibling path to the primary timer, identical defect,
                // fixed the same way; nothing changes for a lone re-fire.
                let audio = AlarmFireAudioResolution.resolve(
                    firingAlarmID: alarmID,
                    isShowingAlarm: AlarmWindowManager.shared.isShowingAlarm,
                    showingAlarmID: AlarmWindowManager.shared.currentAlarmID
                )
                let settings = DeviceSettings.shared

                if audio.runsAudioPipeline {
                    do {
                        let audioSession = AVAudioSession.sharedInstance()
                        if audioSession.category != .playAndRecord {
                            try AppAudioSession.setCategory(.playAndRecord, mode: .default, options: AppAudioSession.alarmFireCategoryOptions())
                        }
                        try AppAudioSession.setActive(true)
                    } catch {
                        print("❌ Failed to configure audio session from snooze timer: \(error)")
                    }

                    if snoozeFadeIn {
                        VolumeManager.shared.fadeInVolume(to: Float(snoozeAlarmVolume), duration: snoozeFadeInSeconds)
                    } else {
                        VolumeManager.shared.setSystemVolume(to: Float(snoozeAlarmVolume))
                    }
                    AlarmSoundPlayer.shared.unlock()
                    // Start silent; the tone volume comes up after the radio
                    // grace window below (or immediately for non-radio alarms).
                    await AlarmSoundPlayer.shared.play(soundID: soundID, initialVolume: 0.0)
                    // Playback outcome for the re-fire. This path has no retry, so
                    // a miss here is the silent start.
                    if AlarmSoundPlayer.shared.isPlaying {
                        AlarmRingReporter.shared.audioStarted()
                    } else {
                        AlarmRingReporter.shared.audioFailed()
                    }

                    // Radio layer for the snooze re-fire — stream attempt gets a
                    // capped head start so it can cut in before the tone.
                    RadioAlarmStreamer.shared.beginAttempt(
                        stationID: radioStationID,
                        stationName: radioStationName,
                        urlString: radioStationURL
                    )
                    if radioStationURL != nil {
                        // Tiered by how far along the stream already is — see
                        // RadioAlarmStreamer.confirmationGrace.
                        await RadioAlarmStreamer.shared.waitForConfirmation(
                            upTo: RadioAlarmStreamer.shared.confirmationGrace
                        )
                    }
                    if !snoozeFadeIn && !VolumeManager.shared.fadeActive {
                        // Routes to the radio player when the stream confirmed;
                        // otherwise unmutes the tone. Fade snoozes are driven by
                        // the fadeInVolume ramp started above — and a ramp left in
                        // flight by anything else is never stomped to full here.
                        AlarmSoundPlayer.shared.setPlayerVolume(1.0)
                    }
                } else {
                    AppLogger.shared.log("Snooze re-fire while another alarm is showing — queued silent, audio left to the showing alarm: '\(alarmLabel)'", category: .alarm)
                    // No fire here to adopt the re-fire's prewarm, and the
                    // dequeue path attempts the station fresh. No-op unless a
                    // prewarm is actually in flight.
                    if audio.cancelsRadioPrewarm {
                        RadioAlarmStreamer.shared.cancelPrewarm()
                    }
                }

                if settings.mqttEnabled {
                    HAIntegrationRouter.shared.publishAlarmState(.ringing, settings: settings)
                    HAIntegrationRouter.shared.publishSnoozeCount(0, settings: settings)
                    HAIntegrationRouter.shared.publishSnoozesRemaining(0, settings: settings)
                }
                
                // Start alarm notifications for the snooze re-fire.
                // When fade-in is active, always vibrate — audio starts quiet but
                // the user still needs tactile feedback.
                AlarmLiveActivityManager.shared.vibrationEnabled = snoozeAlarmVibration || snoozeFadeIn
                AlarmLiveActivityManager.shared.suppressLockScreenNotifications = false
                AlarmLiveActivityManager.shared.startAlarmNotifications(
                    alarmLabel: alarmLabel,
                    alarmID: alarmID
                )
                
                AlarmWindowManager.shared.showAlarm(
                    alarmID: alarmID,
                    label: alarmLabel,
                    missionType: missionType,
                    soundID: soundID
                )
                
                // Clean up snooze timer reference
                LocalNotificationScheduler.shared.snoozeTimers.removeValue(forKey: alarmID)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        LocalNotificationScheduler.shared.snoozeTimers[alarmID] = timer

        // Radio prewarm for the snooze re-fire: start the stream silently ~25s
        // before the snooze expires so it's confirmed at re-fire. Skipped when
        // the snooze is <25s or the alarm has no station; never touches the
        // snooze fire timer.
        LocalNotificationScheduler.shared.scheduleRadioPrewarm(
            alarmIDHash: alarmID,
            fireInterval: fireInterval,
            stationID: radioStationID,
            stationName: radioStationName,
            urlString: radioStationURL
        )
    }

    var isShowingAlarm: Bool {
        alarmWindow != nil
    }

    // MARK: - Alarm Queue Management

    /// Remove a specific alarm from the queue (e.g., when its snooze is cancelled or alarm is deleted).
    func removeFromQueue(alarmID: Int) {
        let removed = alarmQueue.filter { $0.alarmID == alarmID }
        alarmQueue.removeAll { $0.alarmID == alarmID }
        if !removed.isEmpty {
            print("=== DIAG === Removed \(removed.count) alarm(s) from queue for alarmID=\(alarmID), queue size=\(alarmQueue.count)")
        }
    }

    /// Clear the entire alarm queue (e.g., when cancelling all alarms).
    func clearQueue() {
        let count = alarmQueue.count
        alarmQueue.removeAll()
        if count > 0 {
            print("=== DIAG === Cleared alarm queue (\(count) alarms removed)")
        }
    }

}



