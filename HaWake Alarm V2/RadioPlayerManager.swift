//
//  RadioPlayerManager.swift
//  HaWake Alarm V2
//
//  Plays internet radio for listening (plus-menu Radio sheet), mirroring
//  SleepSoundManager's audio-session rules:
//  - Non-mixable .playback session so iOS treats us as the Now Playing app
//    (lock-screen media controls only appear for non-mixable sessions).
//  - Mutually exclusive with sleep sounds — starting one stops the other.
//  - Pauses when an alarm fires (AlarmSoundPlayer.play() calls
//    handleAlarmWillFire()); the user resumes manually from the active row.
//  - BackgroundAudioKeepAlive guards on isActive so a stray keep-alive
//    restart can't stomp the session and kill media controls.
//
//  Also owns the favorites list and last-played station persistence.
//

import Foundation
import AppIntents
import AVFoundation
import MediaPlayer

@MainActor
@Observable
final class RadioPlayerManager {
    static let shared = RadioPlayerManager()

    enum State {
        case stopped
        case playing
        case paused
    }

    private(set) var state: State = .stopped {
        didSet {
            guard oldValue != state else { return }
            // Published from a `didSet` rather than from each of the six
            // assignment sites, so a new transition can't forget to report
            // itself. No-ops when the integration is off.
            let settings = DeviceSettings.shared
            guard settings.mqttEnabled else { return }
            HAIntegrationRouter.shared.publishRadioState(settings: settings)
        }
    }
    private(set) var currentStation: RadioStation?
    private(set) var volume: Float = 1.0

    /// True while a stream has been asked to play but no audio has actually
    /// rendered yet — i.e. the station is still connecting/buffering. Drives
    /// the indeterminate spinner in RadioPlayCircle.
    ///
    /// Deliberately a SEPARATE flag rather than a `.connecting` State case:
    /// `state` is compared against `.playing` in ~20 places (including
    /// `ownsAudioSession`, the stall watchdog, and the reconnect guard), and a
    /// fourth case would silently flip all of them false during connection.
    /// This stays purely additive — `state` still becomes `.playing` the
    /// instant playback is requested, exactly as before.
    ///
    /// Set wherever a player starts (attachStreamObservers covers first play,
    /// reconnects, and re-attach) and cleared on the first periodic tick with a
    /// non-zero clock, which is the same "audio is genuinely rendering" signal
    /// RadioAlarmStreamer uses to confirm a stream.
    private(set) var isConnecting = false

    /// True while a radio session exists (playing or paused) — drives the
    /// active row in the alarm list.
    var isActive: Bool { state != .stopped }

    /// True while radio owns the non-mixable audio session. Unlike sleep
    /// sounds, a PAUSED radio session hands the session back to keep-alive
    /// (an AVPlayer holds no silent engine), so only .playing owns it.
    var ownsAudioSession: Bool { state == .playing }

    private var player: AVPlayer?

#if DEBUG
    /// Harness introspection only (-radioSleepFadeDebug).
    var debugPlayerVolume: Float? { player?.volume }
#endif
    /// Bumped on every start/stop; async completions check it so a stale
    /// task can't touch a newer session (sleep-sound generation pattern).
    private var sessionGeneration = 0
    /// Auto-stop after 30 minutes paused, mirroring sleep sounds.
    private var idleTimer: Timer?
    private var remoteCommandsConfigured = false

    // Stream resilience (RadioAlarmStreamer's confirm/stall pattern, adapted
    // for listening): item failure/end observers + a stall watchdog trigger
    // an auto-reconnect loop with backoff — a short gap in a sleep aid beats
    // permanent silence. If every attempt fails, the session STOPS for real,
    // so keep-alive restarts and the UI stops claiming playback.
    private var itemObservers: [NSObjectProtocol] = []
    private var timeObserverToken: Any?
    private var stallTimer: Timer?
    private var lastProgressSeconds: Double = 0
    private var stallStrikes = 0
    private var reconnectTask: Task<Void, Never>?
    /// Two consecutive no-progress checks fail over (10s of silence max).
    private let stallCheckInterval: TimeInterval = 5
    /// Backoff between reconnect attempts (~70s total before giving up).
    private let reconnectDelays: [TimeInterval] = [2, 5, 10, 20, 30]

    // Sleep timer (mirrors sleep sounds' scheduleEnd/fade-out)
    private(set) var sleepTimerEnd: Date?

    // Telemetry only — never read by playback. `sessionStartedAt` stamps a
    // confirmed start; `startedAsSleepSession` records whether a sleep timer was
    // ever armed for this session, so `stop()` can tell a sleep session ending
    // from casual listening being switched off.
    private var sessionStartedAt: Date?
    private var startedAsSleepSession = false
    private var sleepEndTimer: Timer?
    private var sleepFadeTimer: Timer?
    private var sleepFadeOutDuration: TimeInterval = 30

    // MARK: - Favorites persistence

    var favorites: [RadioStation] {
        didSet {
            if let data = try? JSONEncoder().encode(favorites) {
                UserDefaults.standard.set(data, forKey: "radioFavorites")
            }
            // Keep Siri/Shortcuts' suggested-station cache current — without
            // this, favorites added/removed mid-session don't appear until
            // the app next foregrounds.
            AllariseShortcuts.updateAppShortcutParameters()
            // Same reason, for Home Assistant: the retained
            // sensor/radio_stations_available topic was only ever written by
            // publishOnlineState, so a favourite toggled while connected never
            // reached the HACS "Radio Station" select — and a first connect with
            // no favourites left a retained "[]" pinning the dropdown to "none"
            // until the next reconnect. Mirrors CustomSoundManager.saveMetadata(),
            // which republishes the sleep-sound inventory on every mutation.
            HAIntegrationRouter.shared.publishRadioFavorites(settings: DeviceSettings.shared)
        }
    }

    /// Last station the user played from the Radio sheet (restored as the
    /// default selection next time).
    private(set) var lastStation: RadioStation? {
        didSet {
            if let station = lastStation, let data = try? JSONEncoder().encode(station) {
                UserDefaults.standard.set(data, forKey: "radioLastStation")
            }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "radioFavorites"),
           let decoded = try? JSONDecoder().decode([RadioStation].self, from: data) {
            favorites = decoded
        } else {
            favorites = []
        }
        if let data = UserDefaults.standard.data(forKey: "radioLastStation"),
           let decoded = try? JSONDecoder().decode(RadioStation.self, from: data) {
            lastStation = decoded
        }
        registerInterruptionObserver()
        registerNowPlayingRefreshObservers()
    }

    /// Phone calls / Siri pause the player at the system level; without this
    /// the app kept claiming .playing over a dead session and keep-alive
    /// never came back. Mirror the interruption into pause(), and honor the
    /// system's resume hint when the interruption ends.
    private func registerInterruptionObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            Task { @MainActor [weak self] in
                self?.handleInterruption(type: type, options: options)
            }
        }
    }

    /// Re-publish Now Playing after a route change. Another media app becoming
    /// "the" Now Playing owner (or a route swap, or a mediaserverd reset)
    /// leaves our nowPlayingInfo nil with nothing to restore it — the widget
    /// stayed blank for the rest of the session even though audio kept
    /// playing. Nothing in the app observed route changes at all before this;
    /// the only observer was a logger in AudioDiagnostics.
    private func registerNowPlayingRefreshObservers() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .playing else { return }
                // A ringing alarm deliberately clears nowPlayingInfo so the
                // media widget doesn't sit on top of the alarm UI — and the
                // alarm's own overrideOutputAudioPort(.speaker) POSTS a route
                // change, so without this guard we would immediately undo that
                // clear. Also excludes .paused: a paused session has nothing
                // worth restoring.
                guard !AlarmSoundPlayer.shared.shouldBePlaying else { return }
                self.publishNowPlaying()
            }
        }
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            if state == .playing {
                pause()
            }
        case .ended:
            if options.contains(.shouldResume), state == .paused,
               !AlarmSoundPlayer.shared.shouldBePlaying {
                resume()
            }
        @unknown default:
            break
        }
    }

    func isFavorite(_ station: RadioStation) -> Bool {
        favorites.contains { $0.id == station.id }
    }

    func toggleFavorite(_ station: RadioStation) {
        if let index = favorites.firstIndex(where: { $0.id == station.id }) {
            favorites.remove(at: index)
        } else {
            favorites.append(station)
        }
    }

    /// Rename a favorite in place (custom display name — the stream and
    /// station identity are unchanged).
    func renameFavorite(_ station: RadioStation, to newName: String) {
        guard let index = favorites.firstIndex(where: { $0.id == station.id }) else { return }
        favorites[index].name = newName
    }

    // MARK: - Playback

    /// - Returns: whether the audio session was successfully activated. False
    ///   means playback will NOT be audible yet (the AVPlayer is still created
    ///   and will start once a usable session exists — e.g. when the app is
    ///   foregrounded). Callers that report success to the user, like
    ///   StartRadioIntent, must check this rather than `isActive`: `state` is
    ///   set to .playing regardless, so `isActive` cannot distinguish real
    ///   playback from a silently-failed background activation.
    @discardableResult
    func play(station: RadioStation) -> Bool {
        guard let url = URL(string: station.streamURL) else { return false }

        // Never fight a ringing alarm for the session.
        guard !AlarmSoundPlayer.shared.shouldBePlaying else { return false }

        // Mutual exclusion with sleep sounds — one Now Playing owner at a time.
        if SleepSoundManager.shared.isActive {
            SleepSoundManager.shared.stop()
        }

        sessionStartedAt = Date()
        startedAsSleepSession = false

        sessionGeneration += 1
        idleTimer?.invalidate()
        idleTimer = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownStreamObservers()
        player?.pause()
        player = nil

        // Radio IS the background audio while it plays. deactivateSession:false
        // matters: we reactivate immediately below, and tearing the session down
        // first opens a window with NO active session at all. SleepSoundManager
        // .start() passes false for exactly this reason.
        BackgroundAudioKeepAlive.shared.stop(deactivateSession: false)

        do {
            // Non-mixable .playback → Now Playing eligibility (media controls).
            try AppAudioSession.setCategory(.playback)
            try AppAudioSession.setActive(true)
        } catch {
            // Typically CannotStartPlaying (561015905) from a background launch
            // without audio-start rights.
            //
            // We must NOT fall through to state = .playing here. Doing so makes
            // ownsAudioSession true, which causes BackgroundAudioKeepAlive
            // .startAsync() to refuse (its radio guard) — leaving the app with
            // no active session AND no keep-alive, i.e. suspendable, with the
            // alarm timer dead until the user next opens the app. Bail out
            // instead and hand the session back to keep-alive.
            print("📻 Radio: audio session activation failed — \(error)")
            AppLogger.shared.log("Radio: audio session activation failed — \(error.localizedDescription)", category: .general)
            restartKeepAliveIfNeeded()
            return false
        }

        let newPlayer = AVPlayer(url: url)
        newPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        newPlayer.volume = volume
        newPlayer.play()
        player = newPlayer
        currentStation = station
        state = .playing
        attachStreamObservers(to: newPlayer, generation: sessionGeneration)
        lastStation = station
        // Re-arm any pending sleep timer under the new session generation
        // (the timer deliberately survives station switches).
        armSleepTimer()

        configureRemoteCommands()
        publishNowPlaying()
        RadioBrowserAPI.shared.reportClick(stationID: station.id)
        AppLogger.shared.log("Radio: playing '\(station.name)'", category: .general)
        return true
    }

    /// Hand background audio back to keep-alive when radio fails to take the
    /// session. Mirrors SleepSoundManager.restartKeepAliveIfNeeded — and must
    /// run only once `state` is NOT .playing, or keep-alive's ownsAudioSession
    /// guard refuses to start.
    private func restartKeepAliveIfNeeded() {
        guard DeviceSettings.shared.keepAliveNeeded else { return }
        Task.detached(priority: .utility) {
            await BackgroundAudioKeepAlive.shared.startAsync()
        }
    }

    func pause() {
        guard state == .playing else { return }
        player?.pause()
        state = .paused
        // Pausing mid-connect abandons the attempt — don't leave a spinner on
        // a paused row.
        isConnecting = false
        publishNowPlaying()
        startIdleTimer()
        // Paused radio no longer holds background audio — keep-alive takes over.
        if DeviceSettings.shared.keepAliveNeeded {
            Task.detached(priority: .utility) {
                await BackgroundAudioKeepAlive.shared.startAsync()
            }
        }
    }

    func resume() {
        guard state == .paused, let player else { return }
        guard !AlarmSoundPlayer.shared.shouldBePlaying else { return }
        // Sleep timer elapsed while paused (e.g. during an alarm) — end cleanly.
        if let end = sleepTimerEnd, end.timeIntervalSinceNow <= 0 {
            stop()
            return
        }
        idleTimer?.invalidate()
        idleTimer = nil
        BackgroundAudioKeepAlive.shared.stop()
        do {
            try AppAudioSession.setCategory(.playback)
            try AppAudioSession.setActive(true)
        } catch {
            print("📻 Radio: session reactivation failed — \(error)")
        }
        player.play()
        state = .playing
        // A reconnect abandoned mid-pause leaves no observers; re-attach so
        // the watchdog catches a dead player and kicks off a fresh reconnect.
        if timeObserverToken == nil {
            attachStreamObservers(to: player, generation: sessionGeneration)
        }
        armSleepTimer()
        publishNowPlaying()
    }

    func stop() {
        guard state != .stopped else { return }

        // Emitted here rather than at each caller: user stop, sleep-timer
        // expiry, alarm takeover and replacement-by-sleep-sound all converge on
        // this method, so one call site can't drift out of step with the starts.
        if startedAsSleepSession, let startedAt = sessionStartedAt {
            let minutes = Int(Date().timeIntervalSince(startedAt) / 60)
            Analytics.shared.log(.sleepSessionEnded(source: .radio, actualMinutes: minutes))
        }
        sessionStartedAt = nil
        startedAsSleepSession = false
        // Only a PLAYING radio session owns the shared audio session. When
        // paused, keep-alive has already taken the session back (see pause())
        // — deactivating it here would kill the live keep-alive loop in the
        // background (e.g. the 30-min idle auto-stop, swipe-stop of a paused
        // row, or sleep sounds starting over paused radio) and let iOS
        // suspend the app.
        let ownedSession = (state == .playing)
        sessionGeneration += 1
        idleTimer?.invalidate()
        idleTimer = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownStreamObservers()
        cancelSleepTimerInternal()
        player?.pause()
        player = nil
        currentStation = nil
        state = .stopped
        isConnecting = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        // Never touch the shared session while an alarm is (or should be)
        // sounding — stopping radio mid-ring must not tear down the alarm's
        // .playAndRecord session. AlarmSoundPlayer.stop() handles the session
        // when the alarm ends.
        if ownedSession && !AlarmSoundPlayer.shared.shouldBePlaying {
            // Hand the session DIRECTLY to keep-alive rather than deactivating
            // first. The old order — synchronous setActive(false), then a
            // detached keep-alive restart — left a window with no active
            // session at all, which is precisely the ordering that
            // SleepSoundManager.internalStop and AlarmSoundPlayer.stop both
            // avoid by design (iOS suspends the app in that window, and the
            // in-app alarm timer dies with it). It matters most here because
            // the callers are overnight: the sleep-timer fade-out, the 30-min
            // idle auto-stop, and reconnect exhaustion.
            //
            // Leaving the session active until keep-alive re-arms it is safe:
            // keep-alive reconfigures to .playback + .mixWithOthers itself, and
            // nothing is rendering audio in the meantime (the player is gone).
            if DeviceSettings.shared.keepAliveNeeded {
                Task.detached(priority: .utility) {
                    await BackgroundAudioKeepAlive.shared.startAsync()
                }
            } else {
                // No keep-alive to hand off to — release the session properly
                // so other apps can resume.
                do {
                    try AppAudioSession.setActive(false, options: .notifyOthersOnDeactivation)
                } catch {
                    print("📻 Radio: session deactivation failed — \(error)")
                }
            }
        }
    }

    func setVolume(_ newVolume: Float) {
        volume = min(max(newVolume, 0.0), 1.0)
        player?.volume = volume
    }

    // MARK: - Stream resilience

    /// Progress observer + terminal-event observers + stall watchdog for the
    /// current player (RadioAlarmStreamer's pattern, minus the wav standby).
    private func attachStreamObservers(to player: AVPlayer, generation: Int) {
        guard let item = player.currentItem else { return }
        lastProgressSeconds = 0
        stallStrikes = 0
        // A fresh player has produced no audio yet — spinner on. Covers first
        // play and the resume-time re-attach. NOT the reconnect loop: that
        // calls attachStreamObservers only AFTER confirming the new stream, so
        // the spinner stays off during the ~70s of backoff.
        isConnecting = true

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 10),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                // The clock advancing past zero means audio is genuinely
                // rendering, not merely "loading" — connection is over.
                if self.isConnecting, time.seconds > 0 {
                    self.isConnecting = false
                }
                self.lastProgressSeconds = time.seconds
            }
        }

        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleStreamFailure(generation: generation, reason: "item failed") }
        })
        itemObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleStreamFailure(generation: generation, reason: "stream ended") }
        })

        startStallWatchdog(generation: generation)
    }

    private func teardownStreamObservers() {
        stallTimer?.invalidate()
        stallTimer = nil
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        for observer in itemObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        itemObservers = []
        lastProgressSeconds = 0
        stallStrikes = 0
    }

    /// Two consecutive no-progress checks while nominally playing → failure.
    /// Skips checks while paused or while a reconnect is already running.
    private func startStallWatchdog(generation: Int) {
        stallTimer?.invalidate()
        var lastChecked = lastProgressSeconds
        stallTimer = Timer.scheduledTimer(withTimeInterval: stallCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation,
                      self.state == .playing, self.reconnectTask == nil else { return }
                if self.lastProgressSeconds <= lastChecked {
                    self.stallStrikes += 1
                    if self.stallStrikes >= 2 {
                        self.handleStreamFailure(generation: generation, reason: "stalled")
                        return
                    }
                } else {
                    self.stallStrikes = 0
                }
                lastChecked = self.lastProgressSeconds
            }
        }
    }

    private func handleStreamFailure(generation: Int, reason: String) {
        guard sessionGeneration == generation, state == .playing, reconnectTask == nil else { return }
        guard let station = currentStation else {
            stop()
            return
        }
        Analytics.shared.log(.radioStreamFailed(forSleep: startedAsSleepSession))
        print("📻 Radio: stream failure (\(reason)) — attempting reconnect")
        AppLogger.shared.log("Radio: stream \(reason) — attempting reconnect", category: .general)
        stallTimer?.invalidate()
        stallTimer = nil
        reconnectTask = Task { @MainActor [weak self] in
            await self?.runReconnectLoop(station: station, generation: generation)
        }
    }

    /// Backoff reconnect loop: rebuild the player, wait up to 10s for the
    /// playback clock to advance (genuine audio, not just "loading"), repeat
    /// per `reconnectDelays`. Success re-arms the observers; exhaustion stops
    /// the session for real (keep-alive restarts, UI shows stopped).
    private func runReconnectLoop(station: RadioStation, generation: Int) async {
        defer {
            if sessionGeneration == generation { reconnectTask = nil }
        }
        guard let url = URL(string: station.streamURL) else {
            stop()
            return
        }
        for (attempt, delay) in reconnectDelays.enumerated() {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, sessionGeneration == generation, state == .playing else { return }
            AppLogger.shared.log("Radio: reconnect attempt \(attempt + 1)/\(reconnectDelays.count)", category: .general)

            teardownStreamObservers()
            // Preserve the CURRENT player volume, not the stored user level —
            // a reconnect landing mid-sleep-fade otherwise snaps back to full
            // volume until the next fade step writes it down again.
            let carryVolume = player?.volume ?? volume
            player?.pause()
            let newPlayer = AVPlayer(url: url)
            newPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
            newPlayer.volume = sleepFadeTimer != nil ? carryVolume : volume
            newPlayer.play()
            player = newPlayer

            let deadline = Date().addingTimeInterval(10)
            var confirmed = false
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, sessionGeneration == generation, state == .playing else { return }
                if newPlayer.currentTime().seconds > 0.5 {
                    confirmed = true
                    break
                }
            }
            if confirmed {
                AppLogger.shared.log("Radio: stream recovered", category: .general)
                attachStreamObservers(to: newPlayer, generation: generation)
                publishNowPlaying()
                return
            }
        }
        AppLogger.shared.log("Radio: reconnect failed — stopping session", category: .general)
        stop()
    }

    // MARK: - Sleep timer

    /// Schedule (or clear, with nil) a sleep timer ending after N minutes
    /// with the default 30-second fade — the quick toolbar-menu path.
    func setSleepTimer(minutes: Int?) {
        guard let minutes, minutes > 0 else {
            cancelSleepTimerInternal()
            return
        }
        setSleepTimer(end: Date().addingTimeInterval(TimeInterval(minutes * 60)), fadeOut: 30)
    }

    /// Schedule (or clear, with nil) a sleep timer ending at a specific time
    /// with a custom fade-out — the Sleep Sounds page path ("Until Next
    /// Alarm" / duration + fade settings). fadeOut 0 = hard stop at end.
    func setSleepTimer(end: Date?, fadeOut: TimeInterval) {
        guard let end, end.timeIntervalSinceNow > 0 else {
            cancelSleepTimerInternal()
            return
        }
        sleepFadeOutDuration = max(0, fadeOut)
        sleepTimerEnd = end
        startedAsSleepSession = true
        armSleepTimer()
        AppLogger.shared.log("Radio sleep timer set: ends in \(Int(end.timeIntervalSinceNow))s, fade \(Int(sleepFadeOutDuration))s", category: .general)
    }

    private func cancelSleepTimerInternal() {
        sleepTimerEnd = nil
        sleepEndTimer?.invalidate()
        sleepEndTimer = nil
        sleepFadeTimer?.invalidate()
        sleepFadeTimer = nil
    }

    /// Arm the end timer for the current sleepTimerEnd (no-op when unset).
    /// Fires at end - fade; if paused when it fires, it does nothing —
    /// resume() re-arms or stops (mirrors the sleep-sound end timer).
    private func armSleepTimer() {
        sleepEndTimer?.invalidate()
        sleepEndTimer = nil
        guard let end = sleepTimerEnd else { return }
        let generation = sessionGeneration
        let fadeStart = max(0.1, end.timeIntervalSinceNow - sleepFadeOutDuration)
        sleepEndTimer = Timer.scheduledTimer(withTimeInterval: fadeStart, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation, self.state == .playing else {
                    AppLogger.shared.log("Radio sleep timer fired but session changed/paused — no fade", category: .general)
                    return
                }
                if self.sleepFadeOutDuration < 1 {
                    AppLogger.shared.log("Radio sleep timer elapsed — hard stop (no fade)", category: .general)
                    self.stop()
                } else {
                    AppLogger.shared.log("Radio sleep fade-out started: \(Int(self.sleepFadeOutDuration))s", category: .general)
                    self.startSleepFadeOut()
                }
            }
        }
    }

    private func startSleepFadeOut() {
        sleepFadeTimer?.invalidate()
        let generation = sessionGeneration
        let steps = 20
        let stepInterval = sleepFadeOutDuration / Double(steps)
        let startVolume = player?.volume ?? volume
        var step = 0
        sleepFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation, self.state == .playing else {
                    timer.invalidate()
                    return
                }
                step += 1
                if step >= steps {
                    timer.invalidate()
                    AppLogger.shared.log("Radio sleep fade-out complete — stopping", category: .general)
                    self.stop()
                } else {
                    // Player-only ramp; the stored `volume` is untouched so
                    // the next session starts at the user's level.
                    self.player?.volume = startVolume * (1.0 - Float(step) / Float(steps))
                }
            }
        }
    }

    /// Called from AlarmSoundPlayer.play() before the alarm session takes
    /// over — pause (don't stop) so the user can resume after dismissing.
    func handleAlarmWillFire() {
        guard state == .playing else { return }
        player?.pause()
        state = .paused
        // Sets state directly rather than calling pause(), so clear this the
        // way pause() would — an alarm firing mid-connect otherwise leaves a
        // spinner turning forever on a paused row.
        isConnecting = false
        startIdleTimer()
    }

    /// Re-applies our session after another in-app audio user (e.g. Sound
    /// Manager preview) hands it back. Mirrors SleepSoundManager's
    /// reassertSessionOwnership — our own setActive(false) posts no
    /// interruption notification, so an explicit handback is the only way
    /// media controls come back.
    func reassertSessionOwnership() {
        guard state == .playing, let player else { return }
        do {
            try AppAudioSession.setCategory(.playback)
            try AppAudioSession.setActive(true)
        } catch {
            print("📻 Radio: session reassert failed — \(error)")
        }
        if player.timeControlStatus != .playing {
            player.play()
        }
        publishNowPlaying()
    }

    // MARK: - Private

    private func startIdleTimer() {
        idleTimer?.invalidate()
        let generation = sessionGeneration
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation, self.state == .paused else { return }
                self.stop()
            }
        }
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state == .playing ? self.pause() : self.resume()
            }
            return .success
        }
    }

    private func publishNowPlaying() {
        guard let station = currentStation else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: station.name,
            MPMediaItemPropertyArtist: "Allarise Radio",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
        if !station.tags.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = station.subtitle
        }
        if let artwork = NowPlayingArtwork.appIcon() {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
