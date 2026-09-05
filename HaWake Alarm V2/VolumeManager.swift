//
//  VolumeManager.swift
//  HaWake Alarm V2
//
//  Volume control using MPVolumeView technique
//

import UIKit
import MediaPlayer
import AVFoundation

@MainActor
final class VolumeManager {
    static let shared = VolumeManager()
    
    private var volumeSlider: UISlider?
    private var originalVolume: Float?
    private var volumeView: MPVolumeView?

    // MARK: - User-volume tracking
    //
    // We cannot trust `AVAudioSession.outputVolume` *at alarm fire time*: by then
    // iOS/AlarmKit has already boosted the system output volume for the alert, so
    // reading it captures the boosted level (e.g. 75%) instead of the user's
    // pre-alarm level (e.g. 0%). Restoring to that boosted value is the bug.
    //
    // Instead we continuously observe `outputVolume` and persist the user's level
    // whenever *no* alarm is driving the volume, then restore to that tracked value.
    private let userVolumeKey = "vm.lastKnownUserVolume"
    private var volumeObservation: NSKeyValueObservation?
    private var pendingUserVolumePersist: DispatchWorkItem?
    /// True from the moment an alarm raises the volume until it is restored.
    /// While true, observed volume changes are NOT recorded as the user's level.
    private var isAlarmVolumeActive = false
    /// Short window after any programmatic volume set during which observed
    /// changes are ignored (covers our own slider writes and previews).
    private var suppressTrackingUntil = Date.distantPast

    private init() {
        setupVolumeControl()
        startObservingUserVolume()
    }
    
    private func setupVolumeControl() {
        // The MPVolumeView MUST be within the window bounds for iOS to suppress
        // the system volume HUD. A zero-size frame at the origin works — iOS
        // sees the view in the hierarchy and hides the HUD, while the view
        // itself is invisible (zero size + near-zero alpha).
        let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        volumeView.clipsToBounds = true
        volumeView.showsVolumeSlider = true // IMPORTANT: Must be true for slider to exist
        volumeView.setVolumeThumbImage(UIImage(), for: UIControl.State())
        volumeView.setMinimumVolumeSliderImage(UIImage(), for: UIControl.State())
        volumeView.setMaximumVolumeSliderImage(UIImage(), for: UIControl.State())
        volumeView.isUserInteractionEnabled = false
        volumeView.alpha = 0.001
        
        self.volumeView = volumeView
        
        // Add to key window
        DispatchQueue.main.async {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let windows = windowScene.windows
                for window in windows where window.isKeyWindow {
                    window.insertSubview(volumeView, at: 0)
                    break
                }
            }
            
            // Find the slider
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, let volumeView = self.volumeView else { return }
                self.findSlider(in: volumeView)
            }
        }
    }
    
    /// Make sure the MPVolumeView is actually in a window. At init time
    /// the key window may not exist yet, so this re-attaches it if needed.
    /// The view must be in the window hierarchy for iOS to suppress the
    /// system volume HUD when we change volume via the slider.
    private func ensureVolumeViewInWindow() {
        guard let vv = volumeView else { return }
        if vv.window != nil { return }  // already attached
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            for window in windowScene.windows where window.isKeyWindow {
                window.insertSubview(vv, at: 0)
                print("🔊 MPVolumeView re-attached to key window")
                // Re-find the slider since the view hierarchy may have changed
                if volumeSlider == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self, let vv = self.volumeView else { return }
                        self.findSlider(in: vv)
                    }
                }
                break
            }
        }
    }
    
    private func findSlider(in view: UIView) {
        for subview in view.subviews {
            if let slider = subview as? UISlider {
                volumeSlider = slider
                print("✅ Volume slider found and cached")
                return
            }
            findSlider(in: subview)
        }
    }
    
    /// Ensure the volume slider is ready for use. Call this before
    /// `setSystemVolume` when the slider may not yet be initialized.
    func ensureReady() async {
        if volumeSlider != nil { return }
        
        print("🔊 VolumeManager: slider not ready, reinitializing...")
        setupVolumeControl()
        
        // Wait for the slider to be found (setupVolumeControl uses async dispatches).
        // Poll up to 10 times at 50ms intervals (500ms total).
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            if volumeSlider != nil {
                print("🔊 VolumeManager: slider ready after reinit")
                return
            }
        }
        print("⚠️ VolumeManager: slider still not available after reinit")
    }
    
    // MARK: - User-Volume Tracking

    /// Begin observing the system output volume so we always know the user's
    /// most recent (non-alarm) media volume to restore to later.
    private func startObservingUserVolume() {
        let session = AVAudioSession.sharedInstance()
        // Seed once with the current value (at launch, assume no alarm is active).
        if UserDefaults.standard.object(forKey: userVolumeKey) == nil {
            UserDefaults.standard.set(session.outputVolume, forKey: userVolumeKey)
        }
        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            Task { @MainActor in self?.handleObservedVolumeChange(newValue) }
        }
    }

    /// The last system volume observed while no alarm was driving it — i.e. the
    /// user's media volume. `nil` only before the first observation is seeded.
    var lastKnownUserVolume: Float? {
        guard UserDefaults.standard.object(forKey: userVolumeKey) != nil else { return nil }
        return UserDefaults.standard.float(forKey: userVolumeKey)
    }

    private func persistUserVolume(_ value: Float) {
        UserDefaults.standard.set(min(max(value, 0.0), 1.0), forKey: userVolumeKey)
    }

    /// Suppress user-volume tracking for a short window. Call around any
    /// programmatic volume change (alarm set, fade prep, preview) so our own
    /// writes — and the brief system "alarm boost" spike that precedes them —
    /// are never recorded as the user's level.
    private func suppressTracking(for seconds: TimeInterval = 2.0) {
        suppressTrackingUntil = Date().addingTimeInterval(seconds)
    }

    private var trackingSuppressed: Bool {
        isAlarmVolumeActive || fadeActive || Date() < suppressTrackingUntil
    }

    private func handleObservedVolumeChange(_ newValue: Float) {
        if trackingSuppressed {
            pendingUserVolumePersist?.cancel()
            pendingUserVolumePersist = nil
            return
        }
        // Debounce: only treat a value as the user's once it's been stable ~1.5s.
        // The fleeting alarm-boost spike is overwritten by our own volume set
        // (which extends the suppression window) well before this fires.
        pendingUserVolumePersist?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.trackingSuppressed else { return }
            self.persistUserVolume(newValue)
            print("🎚️ Tracked user volume: \(Int(newValue * 100))%")
        }
        pendingUserVolumePersist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Fade-In

    private var fadeTimer: Timer?

    /// The player volume the fade ramp starts from (barely audible).
    /// The ramp starts from TRUE SILENCE. This was 0.05 ("barely audible"), but
    /// 5% of an alarm tone at the alarm's target system volume is plainly
    /// audible in a quiet bedroom — the fade appeared to "start loud" because
    /// its first instant was already a real sound. A fade means inaudible →
    /// full; vibration is forced on for the whole ramp (see Vibration During
    /// Fade-In), so silence at t=0 costs nothing in wake-up reliability.
    /// The radio stream keeps its OWN audible floor (`streamFadeFloor`) — its
    /// program material needs one; a synthesized tone does not.
    private let fadeStartPlayerVolume: Float = 0.0

    /// Wall-clock instant the player ramp began. The ramp is driven by elapsed
    /// time (not a step counter) so it can be *resumed* at the correct volume
    /// if the alarm sound is restarted mid-fade — on lock/unlock, audio-session
    /// reconfiguration, or AlarmKit re-entry — instead of jumping to full volume
    /// or starting over from silence.
    private var fadeStartDate: Date?
    private var fadeDuration: TimeInterval = 0

    /// True from `startPlayerFadeIn` until the ramp reaches full volume.
    /// Other code paths that set system volume (e.g. showAlarm,
    /// checkAndShowPendingAlarm) should check `fadeActive` and skip their
    /// volume override to avoid stomping the fade ramp.
    private(set) var isFadingIn = false

    /// True from `prepareForFadeIn` until the ramp actually starts (covers the
    /// ~1-second silent-entry window) or the fade is cancelled.
    private var pendingFade = false

    /// Whether a fade is armed or in progress. This is the authoritative
    /// "a fade is in flight" signal that restart/recovery/re-entry paths
    /// consult so they neither restart the sound at full volume nor re-run
    /// the fade from scratch.
    var fadeActive: Bool { pendingFade || isFadingIn }

    /// Non-isolated snapshot of `fadeActive` for callers that aren't on the
    /// MainActor (e.g. AlarmKit's `observeAlarmUpdates`, which can't `await`
    /// in its synchronous duplicate guard). Always written on the MainActor;
    /// reads are a best-effort guard so a momentarily stale value is harmless.
    nonisolated(unsafe) private(set) static var fadeActiveSnapshot = false

    private func updateFadeSnapshot() {
        Self.fadeActiveSnapshot = pendingFade || isFadingIn
    }

    /// Step 1 of the split fade-in flow (used with the 1-second soft entry).
    /// Saves the original volume, sets the system volume to the target level,
    /// and *arms* the fade so a restart during the silent-entry window resumes
    /// the fade instead of jumping to full volume.
    /// Call `startPlayerFadeIn(duration:)` after the soft entry delay to begin ramping.
    func prepareForFadeIn(to targetVolume: Float) {
        let target = min(max(targetVolume, 0.0), 1.0)
        isAlarmVolumeActive = true
        suppressTracking()
        ensureVolumeViewInWindow()
        if originalVolume == nil {
            // Use the tracked user volume, not the live reading — at fire time the
            // system has already boosted outputVolume for the alarm alert.
            let saved = lastKnownUserVolume ?? AVAudioSession.sharedInstance().outputVolume
            originalVolume = saved
            print("💾 Saved original volume: \(Int(saved * 100))% (\(lastKnownUserVolume != nil ? "tracked" : "live"))")
        }
        // A ramp already running for this ring must survive this call. Arming
        // clears fadeStartDate and drops the player back to silence, so a second
        // fire path reaching here (AlarmKit alerting after the timer path, a
        // resume, a snooze re-fire racing a ring) would restart a 5-minute fade
        // from zero — over and over, and the alarm never reaches full volume.
        // The system-volume target still gets applied; the ramp is left alone.
        guard !isFadingIn else {
            setSystemVolumeQuietly(to: target)
            AppLogger.shared.log("Fade prepare skipped — a ramp is already in flight (system volume set to \(Int(target * 100))%)", category: .audio)
            return
        }
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadeStartDate = nil
        isFadingIn = false
        pendingFade = true
        updateFadeSnapshot()
        setSystemVolumeQuietly(to: target)
        print("🔊 Fade-in prepared: system volume → \(Int(target * 100))%")
    }

    /// Step 2 of the split fade-in flow.
    /// Records the fade session and ramps the audio player's volume from ~5%
    /// to 100% over `duration` seconds. System volume must already be set
    /// (call `prepareForFadeIn` first).
    func startPlayerFadeIn(duration: TimeInterval) {
        fadeTimer?.invalidate()
        fadeTimer = nil

        fadeStartDate = Date()
        fadeDuration = max(0, duration)
        isFadingIn = true
        pendingFade = false
        updateFadeSnapshot()

        AlarmSoundPlayer.shared.setPlayerVolume(playerVolumeForCurrentFade())
        print("🔊 Fade-in ramp started: player \(Int(fadeStartPlayerVolume * 100))% → 100% over \(Int(duration))s")
        AppLogger.shared.log("Fade-in ramp started: \(Int(duration))s", category: .audio)
        armFadeTimer()
    }

    /// Start the ramp — or adopt the one already running.
    ///
    /// A single ring can reach a "start the fade" branch more than once: the
    /// in-app timer path fires, then the AlarmKit failsafe alerts (`cancel()`
    /// isn't guaranteed once iOS has queued delivery) and `handleAlarmAlerting`
    /// runs the same sequence. A second `startPlayerFadeIn` resets `fadeStartDate`
    /// and drops the player back to silence, restarting a 5-minute fade from
    /// zero every time — so the FIRST ramp wins and later callers just keep it
    /// ticking. Every fire path should prefer this over `startPlayerFadeIn`.
    func startPlayerFadeInIfNeeded(duration: TimeInterval) {
        guard isFadingIn else {
            startPlayerFadeIn(duration: duration)
            return
        }
        AppLogger.shared.log("Fade ramp already in flight — adopted, not restarted", category: .audio)
        ensureFadeRunning()
    }

    /// (Re)start the ramp timer for the *remainder* of the current fade session.
    /// Called by restart/foreground paths after they (re)start the alarm sound
    /// so an in-progress fade keeps ramping. No-op if no fade is in progress or
    /// the timer is already running.
    func ensureFadeRunning() {
        guard isFadingIn, fadeStartDate != nil, fadeTimer == nil else { return }
        AlarmSoundPlayer.shared.setPlayerVolume(playerVolumeForCurrentFade())
        armFadeTimer()
        print("🔊 Fade-in resumed: player at \(Int(playerVolumeForCurrentFade() * 100))%")
    }

    /// Marker the ramp passes to `setPlayerVolume` so its own writes are exempt
    /// from the "full volume during a fade" stomp warning.
    static let fadeRampCaller = "fadeRamp"

    private func armFadeTimer() {
        let stepInterval: TimeInterval = 1.0
        var tick = 0
        let timer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let volume = self.playerVolumeForCurrentFade()
                // Tagged so the stomp detector doesn't flag the ramp's own
                // final 1.0 write as an intruder.
                AlarmSoundPlayer.shared.setPlayerVolume(volume, caller: Self.fadeRampCaller)
                // Ramp telemetry every 10s: what the curve asked for vs what the
                // player actually ended up at. A divergence means some other path
                // is writing volume behind the ramp's back.
                tick += 1
                if tick % 10 == 0 {
                    let actual = AlarmSoundPlayer.shared.currentPlayerVolume
                    let stream = RadioAlarmStreamer.shared.currentStreamVolume
                    AppLogger.shared.log(
                        String(format: "Fade ramp t=%ds wants=%.2f player=%.2f stream=%@",
                               tick, volume, actual ?? -1,
                               stream.map { String(format: "%.2f", $0) } ?? "-"),
                        category: .audio)
                }
                if volume >= 1.0 {
                    timer.invalidate()
                    self.fadeTimer = nil
                    self.isFadingIn = false
                    self.fadeStartDate = nil
                    self.updateFadeSnapshot()
                    print("🔊 Fade-in complete: player volume 100%")
                    AppLogger.shared.log("Fade-in complete", category: .audio)
                }
            }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The player volume (0.05…1.0) for the current point in the fade, using a
    /// quadratic ease-in curve. Returns the start volume during the silent-entry
    /// window, and 1.0 when no fade is active or the fade has completed.
    func playerVolumeForCurrentFade() -> Float {
        if pendingFade { return fadeStartPlayerVolume }
        guard isFadingIn, let start = fadeStartDate, fadeDuration > 0 else { return 1.0 }
        let elapsed = Date().timeIntervalSince(start)
        let progress = Float(min(max(elapsed / fadeDuration, 0), 1))
        let eased = progress * progress  // quadratic ease-in
        return fadeStartPlayerVolume + (1.0 - fadeStartPlayerVolume) * eased
    }

    /// Inverse of the ramp curve: the fade POSITION (0…1) that produced
    /// `volume`. The ramp is `start + (1 - start)·p²`, so this is the square
    /// root of the normalized amplitude.
    ///
    /// Exists for players rendering DIFFERENT material than the alarm wav — the
    /// radio stream — so they can re-ease the same fade on a curve that suits
    /// broadcast audio instead of inheriting a curve tuned for a synthesized
    /// tone. Returns 0 at or below the fade floor, 1.0 when the fade is over.
    func fadePosition(forPlayerVolume volume: Float) -> Float {
        let clamped = min(max(volume, 0.0), 1.0)
        guard clamped > fadeStartPlayerVolume else { return 0 }
        let normalized = (clamped - fadeStartPlayerVolume) / (1.0 - fadeStartPlayerVolume)
        return sqrt(max(0, normalized))
    }

    /// Legacy combined fade-in (sets system volume + starts player ramp immediately).
    /// Prefer `prepareForFadeIn` + `startPlayerFadeIn` for new call sites.
    func fadeInVolume(to targetVolume: Float, duration: TimeInterval = 30) {
        prepareForFadeIn(to: targetVolume)
        startPlayerFadeIn(duration: duration)
    }

    /// Stop any in-progress or armed fade-in.
    ///
    /// `jumpToFull: true` (mid-ring cancels — grace-mute release, failed-retry
    /// recovery) also raises the player to 1.0, because the ring CONTINUES and
    /// must be audible. `jumpToFull: false` is for TEARDOWN callers
    /// (dismiss/snooze/background cleanup): the sound is about to stop, and
    /// device telemetry showed the old unconditional 1.0 write blasting the
    /// still-live radio stream at full volume for the ~250ms between dismiss
    /// and player teardown. State is cleared either way, so fade state never
    /// leaks into the next alarm (whose play() sets its own entry volume).
    ///
    /// `caller` defaults to `#function`, which Swift evaluates at the CALL SITE —
    /// so the log names whoever ended the fade. A fade that dies early is the
    /// single most common cause of "fade-in isn't working".
    func cancelFadeIn(jumpToFull: Bool = true, caller: String = #function) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        if fadeActive {
            let elapsed = fadeStartDate.map { Int(Date().timeIntervalSince($0)) }
            AppLogger.shared.log(
                "Fade CANCELLED by \(caller) after \(elapsed.map(String.init) ?? "0")s of \(Int(fadeDuration))s\(jumpToFull ? " — jumping to full volume" : " (teardown, volume left alone)")",
                category: .audio)
            if jumpToFull {
                AlarmSoundPlayer.shared.setPlayerVolume(1.0)
            }
        }
        pendingFade = false
        isFadingIn = false
        fadeStartDate = nil
        updateFadeSnapshot()
    }
    
    /// Set system volume to specified level (0.0 to 1.0).
    /// For alarm fire paths, prefer `setSystemVolumeBeforePlayback` which awaits
    /// slider availability and gives the OS time to apply the change.
    func setSystemVolume(to volume: Float) {
        let clampedVolume = min(max(volume, 0.0), 1.0)
        isAlarmVolumeActive = true
        suppressTracking()
        ensureVolumeViewInWindow()

        // Save original volume once (only if not already saved). Use the tracked
        // user volume, not the live reading — at fire time the system has already
        // boosted outputVolume for the alarm alert.
        if originalVolume == nil {
            let saved = lastKnownUserVolume ?? AVAudioSession.sharedInstance().outputVolume
            originalVolume = saved
            print("💾 Saved original volume: \(Int(saved * 100))% (\(lastKnownUserVolume != nil ? "tracked" : "live"))")
        }

        guard let slider = volumeSlider else {
            print("⚠️ Slider not found, setting up again...")
            setupVolumeControl()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.setSystemVolume(to: volume)
            }
            return
        }
        
        print("🔊 Setting volume to \(Int(clampedVolume * 100))%...")
        
        slider.setValue(clampedVolume, animated: false)
        slider.sendActions(for: .valueChanged)
        
        // Verify it worked
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let current = AVAudioSession.sharedInstance().outputVolume
            print("📊 Volume is now: \(Int(current * 100))%")
        }
    }

    /// Async variant for alarm fire paths: waits for the slider to be ready,
    /// sets the volume, then waits 150 ms for the OS to process the slider
    /// action before the caller starts audio playback. Without this wait,
    /// playback can begin at the old system volume and the change lands ~0.2s later.
    func setSystemVolumeBeforePlayback(to volume: Float) async {
        await ensureReady()
        setSystemVolume(to: volume)
        // Give the OS time to propagate the slider action to the audio hardware.
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
    }
    
    /// Restore volume to what it was before the alarm fired.
    /// Safe to call from any alarm-ending path (dismiss / snooze); a no-op if
    /// no original volume was saved (i.e. this app never raised the volume).
    func restoreOriginalVolume() {
        // Teardown: the ring is ending — never blast the (still-live) player
        // to full volume on the way out.
        cancelFadeIn(jumpToFull: false)
        guard let saved = originalVolume else {
            print("⚠️ No original volume to restore")
            return
        }

        print("🔄 Restoring to \(Int(saved * 100))%...")

        // Clear the saved value first so setSystemVolume doesn't re-save
        originalVolume = nil
        // The alarm no longer owns the volume; the restored level IS the user's
        // level, so seed the tracker with it and resume normal tracking.
        isAlarmVolumeActive = false
        persistUserVolume(saved)
        suppressTracking()

        applyVolumeWithRetry(saved, attemptsLeft: 4)
    }

    /// Apply `value` to the system volume, then verify it landed and re-apply a
    /// few times if it didn't.
    ///
    /// Restores frequently run during a window transition — the alarm window is
    /// being torn down and the next key window isn't established yet — where the
    /// MPVolumeView's slider isn't in a live key window and `setValue` is a
    /// silent no-op. A single attempt is therefore unreliable; the retry re-attaches
    /// the view and re-applies until the volume actually matches (or attempts run out).
    private func applyVolumeWithRetry(_ value: Float, attemptsLeft: Int) {
        ensureVolumeViewInWindow()
        if let slider = volumeSlider {
            slider.setValue(value, animated: false)
            slider.sendActions(for: .valueChanged)
        } else {
            // Slider not ready yet — rebuild it; the retry below will re-apply.
            setupVolumeControl()
        }

        guard attemptsLeft > 1 else {
            verifyVolumeRestore(expected: value)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let actual = AVAudioSession.sharedInstance().outputVolume
            if abs(actual - value) > 0.02 {
                print("🔁 Volume restore retry (\(attemptsLeft - 1) left): at \(Int(actual * 100))%, want \(Int(value * 100))%")
                self.applyVolumeWithRetry(value, attemptsLeft: attemptsLeft - 1)
            } else {
                print("✅ Volume restored correctly to \(Int(actual * 100))%")
            }
        }
    }
    
    /// Set system volume without saving/tracking original volume (for preview use)
    func setSystemVolumeQuietly(to volume: Float) {
        let clampedVolume = min(max(volume, 0.0), 1.0)
        suppressTracking()
        ensureVolumeViewInWindow()

        guard let slider = volumeSlider else {
            setupVolumeControl()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.setSystemVolumeQuietly(to: volume)
            }
            return
        }

        slider.setValue(clampedVolume, animated: false)
        slider.sendActions(for: .valueChanged)
    }

    /// Get current system volume
    func getCurrentVolume() -> Float {
        return AVAudioSession.sharedInstance().outputVolume
    }
    
    /// Force cleanup when app backgrounds
    func forceCleanup() {
        // Teardown path, same rule as restoreOriginalVolume.
        cancelFadeIn(jumpToFull: false)
        if let saved = originalVolume {
            originalVolume = nil
            isAlarmVolumeActive = false
            persistUserVolume(saved)
            suppressTracking()
            applyVolumeWithRetry(saved, attemptsLeft: 4)
        }
        // Keep the MPVolumeView in the window hierarchy — removing it
        // causes the system volume HUD to briefly flash on the home screen.
        // The view is invisible (alpha 0.001, zero-size frame) and costs
        // nothing to keep alive.
    }
    
    /// Check that the system volume actually matches what we tried to restore.
    /// Logs a warning via AppLogger if there's a mismatch so it shows up in debug logs.
    private func verifyVolumeRestore(expected: Float) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let actual = AVAudioSession.sharedInstance().outputVolume
            let diff = abs(actual - expected)
            // Allow a small tolerance — MPVolumeView snaps to discrete steps
            if diff > 0.02 {
                let msg = "Volume restore mismatch: expected \(Int(expected * 100))%, got \(Int(actual * 100))%"
                print("⚠️ \(msg)")
                AppLogger.shared.log(msg, category: .general)
            } else {
                print("✅ Volume restored correctly to \(Int(actual * 100))%")
            }
        }
    }
}
