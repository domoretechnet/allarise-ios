//
//  AlarmSound.swift
//  HaWake Alarm V2
//
//  Manages alarm sound files and playback
//

import Foundation
import AVFoundation
import MediaPlayer
import UIKit

struct AlarmSound: Identifiable, Hashable, Codable {
    let id: String  // File name without extension
    let displayName: String
    
    var fileName: String {
        return id + ".wav"  // Changed to .wav
    }
    
    var fileURL: URL? {
        // Custom sound — resolve from CustomSoundManager
        if id.hasPrefix("custom_") {
            return CustomSoundManager.shared.fileURL(forID: id)
        }
        // Try .wav in subdirectory first
        if let url = Bundle.main.url(forResource: id, withExtension: "wav", subdirectory: "AlarmSounds") {
            return url
        }
        // Try .wav in main bundle
        if let url = Bundle.main.url(forResource: id, withExtension: "wav") {
            return url
        }
        // Fallback to .m4a if .wav not found (backward compatibility)
        if let url = Bundle.main.url(forResource: id, withExtension: "m4a", subdirectory: "AlarmSounds") {
            return url
        }
        // Fallback to .m4a in main bundle
        return Bundle.main.url(forResource: id, withExtension: "m4a")
    }
    
    /// Get notification-compatible .wav version of this sound
    var notificationSoundURL: URL? {
        // Custom sound — check Library/Sounds/
        if id.hasPrefix("custom_") {
            if let name = CustomSoundManager.shared.notificationSoundName(forID: id) {
                let libSounds = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Sounds")
                    .appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: libSounds.path) {
                    return libSounds
                }
            }
            return nil
        }
        // Try .wav in AlarmSounds folder (same as in-app)
        if let url = Bundle.main.url(forResource: id, withExtension: "wav", subdirectory: "AlarmSounds") {
            return url
        }
        // Try .wav in main bundle
        if let url = Bundle.main.url(forResource: id, withExtension: "wav") {
            return url
        }
        // Try ConvertedAlarmSounds subdirectory
        if let url = Bundle.main.url(forResource: id, withExtension: "wav", subdirectory: "ConvertedAlarmSounds") {
            return url
        }
        // Try .aiff format
        if let url = Bundle.main.url(forResource: id, withExtension: "aiff") {
            return url
        }
        // Try .caf format
        if let url = Bundle.main.url(forResource: id, withExtension: "caf") {
            return url
        }
        return nil
    }
    
    /// Get the notification sound name (for UNNotificationSound)
    /// UNNotificationSound requires the path relative to the bundle root,
    /// including any subdirectory (e.g. "AlarmSounds/Alarm_Clock.wav").
    var notificationSoundName: String? {
        guard let url = notificationSoundURL else { return nil }
        guard let bundlePath = Bundle.main.resourcePath else { return url.lastPathComponent }
        let fullPath = url.path
        // Strip the bundle resource path prefix to get the relative path
        if fullPath.hasPrefix(bundlePath) {
            var relative = String(fullPath.dropFirst(bundlePath.count))
            if relative.hasPrefix("/") {
                relative = String(relative.dropFirst())
            }
            return relative
        }
        return url.lastPathComponent
    }
    
    /// Check if this sound has a notification-compatible version
    var hasNotificationVersion: Bool {
        return notificationSoundURL != nil
    }
    
    // Parse sound name from filename (e.g., "Classic_Alarm" -> "Classic Alarm")
    init(fileName: String) {
        // Remove extensions (.wav, .m4a, etc.)
        let nameWithoutExt = fileName
            .replacingOccurrences(of: ".wav", with: "")
            .replacingOccurrences(of: ".m4a", with: "")
            .replacingOccurrences(of: ".mp3", with: "")
        self.id = nameWithoutExt
        // Replace underscores with spaces for display
        self.displayName = nameWithoutExt.replacingOccurrences(of: "_", with: " ")
    }
    
    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

// MARK: - Alarm Sound Manager

final class AlarmSoundManager {
    static let shared = AlarmSoundManager()
    
    // Cache the sounds to avoid repeated bundle scanning
    private var cachedSounds: [AlarmSound]?
    
    private init() {}

    /// Clears the cached sounds so the next call to getAllSounds() re-scans.
    func invalidateCache() {
        cachedSounds = nil
    }

    /// Get all available alarm sounds from the AlarmSounds folder + custom tones
    func getAllSounds() -> [AlarmSound] {
        // Return cached sounds if available
        if let cached = cachedSounds {
            return cached
        }

        // Try to find .wav files first
        var soundURLs = Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: "AlarmSounds")

        // If not found in subdirectory, try in main bundle
        if soundURLs == nil || soundURLs?.isEmpty == true {
            soundURLs = Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: nil)
        }

        // If still no .wav files, fall back to .m4a (backward compatibility)
        if soundURLs == nil || soundURLs?.isEmpty == true {
            soundURLs = Bundle.main.urls(forResourcesWithExtension: "m4a", subdirectory: "AlarmSounds")
        }

        if soundURLs == nil || soundURLs?.isEmpty == true {
            soundURLs = Bundle.main.urls(forResourcesWithExtension: "m4a", subdirectory: nil)
        }

        var sounds: [AlarmSound]
        if let soundURLs = soundURLs, !soundURLs.isEmpty {
            sounds = soundURLs.map { url in
                let fileName = url.lastPathComponent
                return AlarmSound(fileName: fileName)
            }.sorted { $0.displayName < $1.displayName }
        } else {
            print("⚠️ No alarm sounds found in bundle")
            sounds = [AlarmSound(id: "default", displayName: "Default")]
        }

        // Append custom alarm tones
        let customTones = CustomSoundManager.shared.alarmTones().map { custom in
            AlarmSound(id: custom.id, displayName: custom.name)
        }
        sounds.append(contentsOf: customTones)

        print("✅ Found \(sounds.count) alarm sounds (\(customTones.count) custom): \(sounds.map { $0.displayName })")

        // Cache the results
        cachedSounds = sounds
        return sounds
    }

    /// Resolve a sound handle, most specific match first.
    ///
    /// The order is deliberate and additive — every pass below the first is a
    /// FALLBACK reached only after the more specific ones fail, so nothing that
    /// resolved before can start resolving to something else:
    ///
    ///   1. exact `AlarmSound.id` — the filename stem (`Alarm_Clock`) for bundled
    ///      tones, `custom_<UUID>` for imported ones. What the app itself stores.
    ///   2. custom tone by MQTT name (display name, spaces → underscores),
    ///      case-insensitively.
    ///   3. tolerant match (`MQTTStrings.matchKey`) against every id and display
    ///      name we know.
    ///
    /// Pass 3 exists because the value comes back off the Home Assistant wire in
    /// whatever shape an automation author typed, and the alarm-sounds dropdown
    /// the app publishes is not the only source: "Alarm Clock" (spaces, the way
    /// the app displays it) used to resolve to nothing, and `sound:` failing to
    /// resolve is silent — `create_alarm` just falls back to the default tone and
    /// the user gets the wrong sound with no error anywhere.
    func getSound(id: String) -> AlarmSound? {
        if let sound = getAllSounds().first(where: { $0.id == id }) {
            return sound
        }
        // Fallback: try matching custom sounds by MQTT name (underscored display name)
        if let custom = CustomSoundManager.shared.soundByMQTTName(id, category: .alarmTone) {
            return AlarmSound(id: custom.id, displayName: custom.name)
        }
        let key = MQTTStrings.matchKey(id.replacingOccurrences(of: "_", with: " "))
        guard !key.isEmpty else { return nil }
        return getAllSounds().first { sound in
            MQTTStrings.matchKey(sound.id.replacingOccurrences(of: "_", with: " ")) == key
                || MQTTStrings.matchKey(sound.displayName) == key
        }
    }
    
    /// Get the default alarm sound (first available, or fallback)
    func getDefaultSound() -> AlarmSound {
        if let firstSound = getAllSounds().first {
            return firstSound
        }
        // Fallback if no sounds in bundle
        return AlarmSound(id: "default", displayName: "Default")
    }
}

// MARK: - Alarm Sound Player (Simplified)

@MainActor
final class AlarmSoundPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AlarmSoundPlayer()
    
    private var audioPlayer: AVAudioPlayer?

    /// The live player gain, or nil when nothing is loaded. Read by the fade
    /// telemetry in `VolumeManager` (shipping, not DEBUG-only — a fade that
    /// misbehaves on a real overnight alarm has to be diagnosable from the
    /// in-app log) and by the `-radioFadeDebug` / `-alarmFireFadeDebug` harnesses.
    var currentPlayerVolume: Float? { audioPlayer?.volume }
    private var preparedPlayers: [String: AVAudioPlayer] = [:]
    private var currentSoundID: String?
    private(set) var shouldBePlaying = false
    
    /// When true, play() calls are rejected. Set by stop(), cleared by unlock().
    /// Prevents race conditions where detached tasks or timers restart audio
    /// after the alarm has been dismissed.
    private(set) var isLocked = false
    
    private override init() {
        super.init()
        // Listen for audio session interruptions (e.g., notification sounds)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }
    
    /// Pre-warm an audio player to reduce latency when alarm fires
    func prewarm(soundID: String) async {
        guard preparedPlayers[soundID] == nil else { 
            print("⚡ Sound already pre-warmed: \(soundID)")
            return 
        }
        
        guard let sound = AlarmSoundManager.shared.getSound(id: soundID),
              let url = sound.fileURL else {
            print("❌ Cannot prewarm sound: \(soundID) - file not found")
            return
        }
        
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1  // Loop until stopped
            player.volume = 1.0
            player.prepareToPlay()  // Pre-load into memory
            
            self.preparedPlayers[soundID] = player
            print("✅ Pre-warmed sound: \(sound.displayName)")
        } catch {
            print("❌ Failed to prewarm sound \(soundID): \(error)")
        }
    }
    
    /// Allow play() calls again. Call this when a new alarm legitimately starts.
    func unlock() {
        isLocked = false
    }

    /// Unlock the player only if an alarm is actively ringing.
    /// Returns true if unlocked, false if the alarm was already resolved (snoozed/dismissed).
    /// Use this in async Tasks that may execute after snooze/dismiss to prevent
    /// restarting sound on a resolved alarm.
    func unlockIfRinging() -> Bool {
        guard PendingAlarmStore.shared.activeRingingAlarmID() != nil else {
            print("🔇 unlockIfRinging() — alarm resolved, staying locked")
            return false
        }
        isLocked = false
        return true
    }
    
    /// - Parameter isResume: True when this is a RECOVERY restart of an alarm
    ///   that is already ringing (unlock/foreground pickup, the showAlarm sound
    ///   watchdog) rather than a fresh fire. Recovery must not tear down the
    ///   radio stream: those paths never call beginAttempt() afterwards, so a
    ///   confirmed, playing stream killed here is gone for good and the user
    ///   drops to the tone mid-alarm. Fresh fires keep passing false — they DO
    ///   need the teardown to stop a previous alarm's stream shadowing this one
    ///   (a tone-only alarm's beginAttempt only cancels prewarms, it does not
    ///   stop a live stream), and their own beginAttempt() follows immediately.
    func play(soundID: String, initialVolume: Float = 1.0, isResume: Bool = false, caller: String = #function) async {
        if isLocked {
            print("🔇 play() blocked — player is locked after dismiss")
            return
        }
        print("🔊 Playing alarm sound: \(soundID)")
        // Every (re)start records the volume it enters at. The fire paths pass
        // 0.0 for the silent entry; a resume mid-fade must pass the fade's
        // current level. A 1.0 here while a fade is armed is the audible
        // "fade didn't start from zero" bug, and this line names the caller.
        if VolumeManager.shared.fadeActive || initialVolume >= 0.99 {
            AppLogger.shared.log(
                String(format: "Alarm sound start: '%@' at %.2f (resume=%@, fadeActive=%@) via %@",
                       soundID, initialVolume, isResume ? "Y" : "N",
                       VolumeManager.shared.fadeActive ? "Y" : "N", caller),
                category: .audio)
        }

        // Pause sleep sounds before reconfiguring the audio session. This prevents
        // the engine config-change notification from racing with the category switch
        // and attempting to restart the sleep-sound engine mid-alarm.
        SleepSoundManager.shared.handleAlarmWillFire()

        // Same for a radio listening session, and clear any alarm stream from
        // a previous alarm so a stale stream can't shadow this one's audio.
        // EXCEPTION: while a mission grace period is holding a confirmed stream
        // alive (muted), this wav restart is the post-grace resume — tearing
        // the held stream down here would defeat it. isGraceHolding is only
        // ever true across that deliberate resume; every real dismiss/snooze
        // goes through stop() (default preservingRadioGraceHold: false), which
        // fully stops the held stream, so this skip cannot leak audio.
        // SECOND EXCEPTION: a prewarm in flight for the alarm that is firing
        // right now. Every fire path calls play() BEFORE beginAttempt(), so
        // tearing down here would destroy the prewarm microseconds before the
        // adoption check reads it — making RadioAlarmStreamer's whole adoption
        // branch unreachable and forcing every radio alarm to cold-start (the
        // tone then wins the ~4s grace). beginAttempt() immediately follows and
        // either adopts this prewarm (URL match) or tears it down itself, so
        // nothing can linger: a station mismatch hits tearDown() in the fresh
        // -attempt path, and a tone-only alarm hits cancelPrewarm() in the
        // nil-URL guard.
        RadioPlayerManager.shared.handleAlarmWillFire()
        if !RadioAlarmStreamer.shared.isGraceHolding
            && !RadioAlarmStreamer.shared.isPrewarming
            && !isResume {
            RadioAlarmStreamer.shared.stop()
        }

        // Always use .playAndRecord to bypass the mute switch (like phone calls/Alarmy).
        // This works from both foreground and background.
        // See AppAudioSession.alarmFireCategoryOptions() for the rationale behind
        // the specific options set (mix-with-others for background activation,
        // duck-others for volume dominance, and CarPlay-aware routing).
        let appState = UIApplication.shared.applicationState
        let category: AVAudioSession.Category = .playAndRecord
        let options = AppAudioSession.alarmFireCategoryOptions()
        
        print("🔊 Audio category: \(category == .playAndRecord ? ".playAndRecord" : ".playback") (appState=\(appState.rawValue))")

        // Configure the audio session. Skip reconfiguration if it's already in
        // the desired category to avoid the intermittent '!int' error
        // (NSOSStatusErrorDomain 560557684) that occurs when setCategory is
        // called while another player (BackgroundAudioKeepAlive) is active on
        // the same session. With .mixWithOthers, keep-alive's silent loop
        // coexists with the alarm cleanly.
        let audioSession = AVAudioSession.sharedInstance()
        let needsReconfigure = (audioSession.category != category)
        
        if needsReconfigure {
            do {
                try AppAudioSession.setCategory(category, mode: .default, options: options)
                try AppAudioSession.setActive(true)
                print("🔊 Audio session reconfigured to \(category == .playAndRecord ? ".playAndRecord" : ".playback")")
            } catch {
                print("⚠️ Failed to reconfigure audio session: \(error) — will try to play anyway")
            }
        } else {
            // Session is already the right category; just ensure it's active
            do {
                try AppAudioSession.setActive(true)
            } catch {
                print("⚠️ Failed to activate audio session: \(error)")
            }
            print("🔊 Audio session already \(category == .playAndRecord ? ".playAndRecord" : ".playback") — skipping reconfiguration")
        }
        
        // Clear Now Playing info so the lock screen doesn't show an empty media player widget.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        // Force audio to the built-in speaker for Bluetooth/AirPlay/AirPods routes.
        // Skip when CarPlay is the active output: overrideOutputAudioPort(.speaker)
        // redirects audio to the iPhone's built-in speaker, which iOS physically
        // mutes while CarPlay owns the audio session — producing total silence.
        // Omitting the override lets iOS route naturally through the car speakers,
        // which is also the better UX (the user is in their car).
        // This override is temporary — it resets on the next audio session
        // reconfiguration (e.g. when BackgroundAudioKeepAlive switches back to
        // .playback after dismissal).
        let hasCarPlay = audioSession.currentRoute.outputs
            .contains { $0.portType == .carAudio }
        if !hasCarPlay {
            do {
                try audioSession.overrideOutputAudioPort(.speaker)
                print("🔊 Audio output overridden to built-in speaker")
            } catch {
                print("⚠️ Failed to override audio output to speaker: \(error)")
            }
        } else {
            print("🔊 CarPlay connected — audio routing through car speakers")
        }
        
        // Stop any player we already own before replacing the reference.
        // Without this, a previous alarm's infinitely-looping player keeps
        // ringing untracked (and unstoppable) after the overwrite when two
        // alarms overlap.
        if let existing = audioPlayer {
            existing.stop()
            audioPlayer = nil
        }

        // Try to use pre-warmed player first
        if let preparedPlayer = preparedPlayers[soundID] {
            print("⚡ Using pre-warmed player for fast start")
            
            preparedPlayer.delegate = self
            preparedPlayer.volume = initialVolume
            // Re-prepare in case the audio session changed since prewarm
            preparedPlayer.prepareToPlay()
            let started = preparedPlayer.play()
            if started {
                audioPlayer = preparedPlayer
                currentSoundID = soundID
                shouldBePlaying = true
                print("✅ Alarm sound playing (pre-warmed): \(soundID)")
                return
            } else {
                print("⚠️ Pre-warmed player.play() returned false, falling back to new player")
                // Clear the failed pre-warmed player so we don't try it again
                preparedPlayers.removeValue(forKey: soundID)
            }
        }
        
        // Fall back to regular initialization if no pre-warmed player
        guard let sound = AlarmSoundManager.shared.getSound(id: soundID),
              let url = sound.fileURL else {
            print("❌ Sound file not found: \(soundID)")
            return
        }
        
        do {
            // Create and configure player
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1  // Loop until stopped
            audioPlayer?.volume = initialVolume
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            currentSoundID = soundID
            shouldBePlaying = true
            
            print("✅ Alarm sound playing: \(sound.displayName)")
        } catch {
            print("❌ Failed to play alarm sound: \(error)")
        }
    }
    
    /// Stop the alarm wav and, normally, the per-alarm radio stream.
    ///
    /// `preservingRadioGraceHold` is passed ONLY by the mission grace-mute path,
    /// which has just called RadioAlarmStreamer.beginGraceHold() to keep a
    /// confirmed stream alive (muted) through the silent grace window. When it
    /// is true AND a hold is actually active, the stream is left running.
    ///
    /// INVARIANT: every dismiss/snooze path calls stop() with the default
    /// (false), so the held stream is ALWAYS fully torn down on dismiss/snooze —
    /// even mid-grace — and can never leak audio past the alarm. A second stop()
    /// while holding therefore fully stops the held stream.
    func stop(preservingRadioGraceHold: Bool = false) {
        shouldBePlaying = false
        isLocked = true
        currentSoundID = nil
        let holdingStream = preservingRadioGraceHold && RadioAlarmStreamer.shared.isGraceHolding
        if !holdingStream {
            RadioAlarmStreamer.shared.stop()
        }
        audioPlayer?.stop()
        audioPlayer = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        print("🔇 Alarm sound stopped (locked)")

        // A held grace stream still needs the LIVE audio session. Deactivating
        // it (or bouncing the category through keep-alive) silences the held
        // AVPlayer, its clock stops advancing, and the stall watchdog kills
        // the "held" stream within ~6s — the post-grace resume then finds it
        // dead and falls over to the tone. Leave the session untouched; the
        // grace window always ends in either the resume path (play()
        // re-asserts the session) or a default stop() (full teardown).
        if holdingStream { return }

        // If App Persistence is on, restart the keep-alive loop. startAsync()
        // re-applies .playback + .mixWithOthers and keeps the session active
        // via beginBackgroundTask so iOS can't suspend us in the transition.
        //
        // If App Persistence is off, keep-alive isn't running anyway. Revert
        // the category and deactivate so we stop advertising as a
        // background-audio app; .notifyOthersOnDeactivation tells other audio
        // apps the interruption is over.
        if DeviceSettings.shared.keepAliveNeeded {
            Task.detached(priority: .utility) {
                await BackgroundAudioKeepAlive.shared.startAsync()
            }
        } else {
            do {
                try AppAudioSession.setCategory(.ambient)
                try AppAudioSession.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("❌ AlarmSound: session deactivation failed — \(error)")
            }
        }
    }
    
    var isPlaying: Bool {
        return audioPlayer?.isPlaying ?? false
    }
    
    /// Set the audio player's volume (0.0–1.0) without touching system volume.
    /// Used by VolumeManager for fade-in: system volume is set once to the
    /// target level, then player volume ramps from low to 1.0 over time.
    /// This avoids repeated MPVolumeView slider changes that trigger the
    /// system volume HUD when the app is backgrounded.
    func setPlayerVolume(_ volume: Float, caller: String = #function) {
        // A full-volume write while a fade is mid-ramp is a BUG, not a fade:
        // some restart/resume path is jumping the alarm to full and the ramp's
        // next tick will quietly paper over it (~1s of loud audio). `caller`
        // is evaluated at the call site, so the log names the culprit. The
        // ramp's own writes never trip this — they only reach 1.0 at the end,
        // by which point the fade has cleared itself.
        if volume >= 0.99, VolumeManager.shared.fadeActive, caller != VolumeManager.fadeRampCaller {
            AppLogger.shared.log(
                "Fade STOMPED: \(caller) set full volume while a fade was in flight",
                category: .audio)
        }
        // While a per-alarm radio stream is confirmed playing, the wav is a
        // muted hot standby — fade-ramp writes drive the stream's volume
        // instead, and the wav stays silent until the stream fails.
        if RadioAlarmStreamer.shared.isStreaming {
            RadioAlarmStreamer.shared.setVolume(volume)
            audioPlayer?.volume = 0
        } else {
            audioPlayer?.volume = min(max(volume, 0.0), 1.0)
        }
    }

    /// Radio stream confirmed rendering — mute the wav but keep it looping
    /// as a hot standby (watchdogs still see a playing alarm; failover is
    /// instant and silent-gap-free).
    func radioStreamDidConfirm() {
        audioPlayer?.volume = 0
    }

    /// Radio stream failed after confirmation — unmute the standby wav at
    /// the correct fade volume.
    func radioStreamDidFail() {
        audioPlayer?.volume = VolumeManager.shared.playerVolumeForCurrentFade()
    }
    
    // MARK: - AVAudioPlayerDelegate
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // With numberOfLoops = -1 this shouldn't happen, but restart if it does
        if shouldBePlaying {
            print("⚠️ Alarm sound finished unexpectedly — restarting")
            player.play()
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("❌ Alarm audio decode error: \(String(describing: error))")
    }
    
    // MARK: - Audio Interruption Handling
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            print("⚠️ Audio session interrupted (e.g., notification sound)")
            AppLogger.shared.log("Audio interruption BEGAN (shouldBePlaying=\(shouldBePlaying), isPlaying=\(isPlaying))", category: .audio)
            // The iOS 27 beta has been observed to interrupt the session without
            // ever delivering .ended. Don't wait passively — check back shortly.
            if shouldBePlaying {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.resumeIfSilenced(reason: "no .ended within 2s of interruption")
                }
            }
        case .ended:
            print("✅ Audio interruption ended")
            AppLogger.shared.log("Audio interruption ENDED (shouldBePlaying=\(shouldBePlaying))", category: .audio)
            if shouldBePlaying {
                attemptResume(reason: "interruption ended")
            }
        @unknown default:
            break
        }
    }

    /// Watchdog entry point: if the alarm should be sounding but the player has
    /// gone quiet (e.g., an audio-session interruption that never delivered
    /// .ended), force the session back and resume. Safe to call repeatedly.
    func resumeIfSilenced(reason: String) {
        guard shouldBePlaying, !isPlaying else { return }
        AppLogger.shared.log("Alarm audio silenced unexpectedly — forcing resume (\(reason))", category: .audio)
        attemptResume(reason: reason)
    }

    /// Re-activate the audio session and resume playback.
    /// Always uses .playAndRecord to bypass the mute switch.
    private func attemptResume(reason: String) {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try AppAudioSession.setCategory(.playAndRecord, mode: .default, options: AppAudioSession.alarmFireCategoryOptions())
            try AppAudioSession.setActive(true)
            let hasCarPlay = audioSession.currentRoute.outputs
                .contains { $0.portType == .carAudio }
            if !hasCarPlay {
                try audioSession.overrideOutputAudioPort(.speaker)
            }
            // play() returning false means the player object is unusable
            // (seen after system-alarm interruptions on iOS 27 beta). Logging
            // "resumed" on a false return hid real failures — verify it.
            let resumed = audioPlayer?.play() ?? false
            // The radio stream rides a SEPARATE AVPlayer, paused by the same
            // interruption and — until al-xhy — never resumed by anything. An
            // unconfirmed stream then had no watchdog either, so it stayed
            // silent at volume 0 for the rest of the ring while the tone carried
            // the alarm. No-op when there is no stream.
            RadioAlarmStreamer.shared.resumeAfterInterruption()
            if resumed {
                print("✅ Alarm sound resumed after interruption (CarPlay=\(hasCarPlay))")
                AppLogger.shared.log("Alarm audio resumed (\(reason), CarPlay=\(hasCarPlay))", category: .audio)
            } else {
                print("⚠️ Resume play() returned false — recreating player")
                AppLogger.shared.log("Alarm audio resume play()==false (\(reason)) — recreating player", category: .audio)
                recreatePlayerForResume(reason: reason)
            }
        } catch {
            print("❌ Failed to resume after interruption: \(error)")
            AppLogger.shared.log("Alarm audio resume FAILED (\(reason)): \(error.localizedDescription)", category: .audio)
            recreatePlayerForResume(reason: reason)
        }
    }

    /// Last resort for a failed resume: rebuild the player from scratch via the
    /// full play() path, preserving the current fade volume if a fade is running.
    private func recreatePlayerForResume(reason: String) {
        guard let soundID = currentSoundID else { return }
        Task { @MainActor in
            let resumeVolume: Float = VolumeManager.shared.fadeActive
                ? VolumeManager.shared.playerVolumeForCurrentFade()
                : 1.0
            await self.play(soundID: soundID, initialVolume: resumeVolume)
            AppLogger.shared.log("Alarm audio player recreated (\(reason)) isPlaying=\(self.isPlaying)", category: .audio)
        }
    }
}
