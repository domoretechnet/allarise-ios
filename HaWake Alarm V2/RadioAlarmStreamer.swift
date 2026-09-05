//
//  RadioAlarmStreamer.swift
//  HaWake Alarm V2
//
//  Streams a per-alarm radio station WHILE the alarm rings, without ever
//  owning wake-up reliability. The contract:
//
//  - The alarm's local tone starts first through the untouched
//    AlarmSoundPlayer pipeline (AlarmKit +5s failsafe, fade-in, interruption
//    recovery all behave exactly as before).
//  - beginAttempt() runs concurrently. Only when the stream is CONFIRMED
//    rendering (playback clock advancing) is the wav muted — it keeps
//    looping at volume 0 as a hot standby.
//  - If the stream never starts (timeout), stalls, errors, or ends, the wav
//    is unmuted immediately at the correct fade volume. Stream failure can
//    never produce silence.
//  - Stream success/failure NEVER feeds into AlarmKit failsafe cancellation —
//    that stays gated on the wav's own isPlaying confirmation.
//
//  All dismiss/snooze paths converge on AlarmSoundPlayer.stop(), which calls
//  stop() here, so the stream can't outlive the alarm.
//

import Foundation
import AVFoundation

@MainActor
final class RadioAlarmStreamer {
    static let shared = RadioAlarmStreamer()

    /// True once the stream is confirmed rendering and the wav is muted.
    /// AlarmSoundPlayer.setPlayerVolume routes fade-ramp writes here while set.
    private(set) var isStreaming = false

    /// True while a mission grace period is holding the confirmed stream alive
    /// but silent. During a hold the player volume is pinned to 0 (fade-ramp
    /// forwards can't unmute it) and item-failure/stall handlers tear the stream
    /// down QUIETLY (there is no ringing wav to restore — the wav was stopped
    /// for the grace window). See beginGraceHold()/endGraceHold().
    private(set) var isGraceHolding = false

    /// True while a stream is being PRE-WARMED ahead of fire time: the player is
    /// running at a PINNED volume 0 (setVolume ignores writes, like isGraceHolding)
    /// and — crucially — nothing is ringing yet, so confirmation records state
    /// SILENTLY (no wav to mute, no click reported). A matching beginAttempt() at
    /// fire adopts the prewarm for an instant, tone-free takeover; any other
    /// teardown path kills it. See prewarmAttempt()/cancelPrewarm().
    private(set) var isPrewarming = false

    /// True once a prewarmed stream has confirmed (clock advanced) but is still
    /// being held silent, waiting for the fire-time adoption.
    private(set) var prewarmConfirmed = false

    private var player: AVPlayer?
    /// Meters the stream's genuinely-rendered audio level so a technically
    /// playable but SILENT stream (dead air) cannot mute the ringing wav. Nil
    /// when no attempt is live; fail-soft when the tap cannot attach — see
    /// StreamAudioLevelMonitor and DeadAirPolicy.
    private var levelMonitor: StreamAudioLevelMonitor?
    /// One-shot guard so a stream held for possible dead air logs the hold
    /// exactly once per attempt (reset in tearDown).
    private var loggedSilentHold = false
    private var timeObserverToken: Any?
    private var itemObservers: [NSObjectProtocol] = []
    private var confirmTimeoutTask: Task<Void, Never>?
    private var stallTimer: Timer?
    /// Runs only BETWEEN attempt and confirmation — see startPreConfirmWatchdog().
    private var preConfirmTimer: Timer?
    private var lastProgressSeconds: Double = 0
    private var stallStrikes = 0
    /// Invalidates every async callback from a previous attempt.
    private var generation = 0

    /// When the current RINGING attempt started (nil while prewarming or idle).
    /// Only used to time the `radioFellBackToTone` telemetry.
    private var attemptStartedAt: Date?

    /// The most recent station this streamer was asked to play — the source
    /// of truth for post-grace re-attempts (the Alarm model's radio fields
    /// can be nil even for an alarm that streamed at fire time).
    private var lastStationID: String?
    private var lastStationName: String?
    private var lastStationURL: String?

    /// Whether a re-attempt has a station to work with.
    var hasLastStation: Bool { lastStationURL != nil }

    /// The live stream gain, or nil when no stream player exists. Read by the
    /// fade telemetry in `VolumeManager` and the fade harnesses.
    var currentStreamVolume: Float? { player?.volume }

    /// True when beginAttempt() adopted a prewarm that had NOT yet confirmed.
    /// The stream is already buffering from ~25s before fire, so it is far more
    /// likely to land than a cold attempt — the fire paths spend a longer silent
    /// grace on it (see confirmationGrace).
    private(set) var adoptedInFlightPrewarm = false

    /// How long a fire path should hold the tone silent waiting for the stream.
    ///
    /// This window is SILENT (the wav plays at volume 0 throughout), so it is
    /// paid out of wake-up reliability and must stay tight for a cold start —
    /// a dead station must not buy 10s of nothing. The tone unmuting is not
    /// final either way: a stream that confirms later still cuts in via
    /// confirmStream(). So the tiers only decide "how long before the user
    /// hears the tone at all", never whether the radio gets to play.
    var confirmationGrace: TimeInterval {
        if isStreaming { return 0 }               // adopted a confirmed prewarm — already live
        if adoptedInFlightPrewarm { return 8 }    // buffering since T-25s — worth the wait
        return 3                                  // cold start — keep the silence short
    }

    /// Re-run the last attempt (post-grace resume path).
    func reattemptLastStation() {
        beginAttempt(stationID: lastStationID, stationName: lastStationName, urlString: lastStationURL)
    }

    /// How long the stream may take to produce audio before we give up.
    /// The wav is audible the whole time, so this is not a silent window —
    /// slow stations regularly take ~15s to start, so the window is generous;
    /// a longer wait costs nothing in wake-up reliability.
    private let confirmTimeout: TimeInterval = 30
    /// Stall watchdog interval; two consecutive no-progress checks fail over.
    private let stallCheckInterval: TimeInterval = 3

    private init() {}

    // MARK: - Public

    /// Start a stream attempt for the ringing alarm. Safe to call with nil
    /// fields (no-op). Called from the fire paths right after the local tone
    /// is confirmed playing.
    func beginAttempt(stationID: String?, stationName: String?, urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else {
            // Every fire path calls this — a ring with NO station must scope
            // out any previous alarm's memory, or a tone-only alarm's
            // post-grace resume would resurrect the PREVIOUS alarm's station
            // via reattemptLastStation(). Also drop any pending prewarm; its
            // adoption chance is gone and it must not linger silently.
            lastStationID = nil
            lastStationName = nil
            lastStationURL = nil
            cancelPrewarm()
            return
        }
        // Is there a live prewarm for THIS exact station to ADOPT? Capture this
        // BEFORE overwriting the last-attempt fields below (they hold the
        // prewarm's URL until this call runs).
        let adoptPrewarm = isPrewarming && player != nil && lastStationURL == urlString
        // Remember the station for the post-grace re-attempt: the resume path
        // can't rely on the Alarm model (its radioStationURL can be nil even
        // when the fire path streamed — the station rides in the fire payload).
        lastStationID = stationID
        lastStationName = stationName
        lastStationURL = urlString
        // Only stream while the alarm pipeline is actually ringing.
        guard AlarmSoundPlayer.shared.shouldBePlaying else { return }
        // Never start (audibly) into a muted grace window — the fire path and
        // an instantly-starting mission can race, and a stream confirming
        // mid-grace would break the silence contract. The post-grace resume
        // re-attempts via reattemptLastStation() once the mute lifts.
        guard !AlarmWindowManager.shared.isGracePeriodMuted else {
            print("📻 RadioAlarmStreamer: attempt skipped — grace period muted")
            return
        }

        // ADOPT a matching prewarm instead of tearing it down: the stream is
        // already buffered (and maybe confirmed) from ~25s before fire, so it
        // takes over instantly and the tone is never heard.
        if adoptPrewarm {
            attemptStartedAt = Date()  // telemetry only — see attemptStartedAt
            isPrewarming = false
            if prewarmConfirmed {
                // Confirmed & buffered → run the confirm handoff NOW, so
                // isStreaming is true before the fire path's waitForConfirmation
                // even starts. Mirrors confirmStream() minus the watchdog, which
                // is already running from the prewarm confirmation.
                isStreaming = true
                AlarmSoundPlayer.shared.radioStreamDidConfirm()  // mute the ringing wav
                setVolume(VolumeManager.shared.playerVolumeForCurrentFade())
                if let stationID {
                    RadioBrowserAPI.shared.reportClick(stationID: stationID)
                }
                print("📻 RadioAlarmStreamer: adopted confirmed prewarm — instant takeover")
                AppLogger.shared.log("Radio alarm: adopted confirmed prewarm '\(stationName ?? "station")' vol=\(Int((player?.volume ?? 0) * 100))%", category: .alarm)
            } else {
                // Still in-flight → keep the existing player/observers running and
                // let the normal confirmation path complete it (the wav rings only
                // if it still hasn't confirmed after the grace, exactly as today).
                adoptedInFlightPrewarm = true
                print("📻 RadioAlarmStreamer: adopted in-flight prewarm — awaiting confirmation")
                AppLogger.shared.log("Radio alarm: adopted in-flight prewarm '\(stationName ?? "station")'", category: .alarm)
            }
            return
        }

        // A fresh attempt supersedes any lingering grace-hold / prewarm
        // bookkeeping (including a prewarm for a DIFFERENT url — torn down and
        // replaced normally by tearDown below).
        isGraceHolding = false
        tearDown(restoreWav: false)
        generation += 1
        let myGeneration = generation
        attemptStartedAt = Date()  // telemetry only — set after tearDown clears it

        print("📻 RadioAlarmStreamer: attempting '\(stationName ?? "station")'")
        AppLogger.shared.log("Radio alarm: attempting stream '\(stationName ?? urlString)'", category: .alarm)

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        newPlayer.volume = 0  // silent until confirmed; wav is ringing
        newPlayer.play()
        player = newPlayer

        // Meter the rendered audio so dead air can't confirm. Fail-soft: if the
        // tap never attaches, the gate below reduces to the clock-only check.
        let monitor = StreamAudioLevelMonitor()
        monitor.attach(url: url)
        levelMonitor = monitor

        // Confirmation: the playback clock advancing past ~0.5s means audio
        // is genuinely rendering (buffered + decoding), not just "loading".
        timeObserverToken = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 10),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.generation == myGeneration else { return }
                if !self.isStreaming, time.seconds > 0.5 {
                    // Clock advanced — but a dead-air stream advances too. Mute
                    // the wav only when audio is actually being heard (or when
                    // metering is unavailable: fail-soft allows).
                    if DeadAirPolicy.mayConfirm(isMonitoring: self.levelMonitor?.isMonitoring ?? false,
                                                hasHeardAudio: self.levelMonitor?.hasHeardAudio ?? false,
                                                contentGateActive: self.levelMonitor?.isContentGateActive ?? false,
                                                hasHeardContent: self.levelMonitor?.hasHeardContent ?? false) {
                        self.confirmStream(stationID: stationID, stationName: stationName)
                    } else if !self.loggedSilentHold {
                        self.loggedSilentHold = true
                        // Pick the message by whether anything is audible: a loud
                        // stream held here is blocked by the content gate (noise);
                        // a silent one is possible dead air.
                        if self.levelMonitor?.hasHeardAudio == true {
                            print("📻 RadioAlarmStreamer: stream rendering but no content confirmed yet — holding tone")
                            AppLogger.shared.log("Radio alarm: stream rendering but no content confirmed yet — holding tone", category: .alarm)
                        } else {
                            print("📻 RadioAlarmStreamer: stream rendering but silent — holding tone (possible dead air)")
                            AppLogger.shared.log("Radio alarm: stream is rendering but silent — holding tone (possible dead air)", category: .alarm)
                        }
                    }
                }
                self.lastProgressSeconds = time.seconds
            }
        }

        // Give up quietly if the stream never starts — wav is already ringing.
        confirmTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.confirmTimeout ?? 20))
            guard let self, self.generation == myGeneration, !self.isStreaming else { return }
            if let monitor = self.levelMonitor, monitor.isMonitoring, monitor.hasHeardAudio,
               monitor.isContentGateActive, !monitor.hasHeardContent, self.lastProgressSeconds > 0.5 {
                // Loud the whole time, but the classifier never recognized any
                // content — noise/static, not a broadcast. (Checked BEFORE the
                // dead-air variant: a noise stream has hasHeardAudio == true, so
                // it can only ever match here.)
                print("📻 RadioAlarmStreamer: stream is loud but carries no recognizable content (noise?) — alarm tone continues")
                AppLogger.shared.log("Radio alarm: stream is loud but carries no recognizable content (noise?) — alarm tone continues", category: .alarm)
            } else if let monitor = self.levelMonitor, monitor.isMonitoring, !monitor.hasHeardAudio, self.lastProgressSeconds > 0.5 {
                // The clock advanced the whole time but nothing was ever audible.
                print("📻 RadioAlarmStreamer: stream never produced audio (dead air) — alarm tone continues")
                AppLogger.shared.log("Radio alarm: stream never produced audio (dead air) — alarm tone continues", category: .alarm)
            } else {
                print("📻 RadioAlarmStreamer: stream never started — staying on alarm tone")
                AppLogger.shared.log("Radio alarm: stream timed out, alarm tone continues", category: .alarm)
            }
            self.logFellBackToTone()
            self.tearDown(restoreWav: false)
        }

        // Terminal item events after confirmation → immediate wav failover.
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleStreamFailure(generation: myGeneration, reason: "item failed") }
        })
        itemObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleStreamFailure(generation: myGeneration, reason: "stream ended") }
        })

        startPreConfirmWatchdog()
    }

    /// Pre-warm a stream ~25s AHEAD of fire time while the app is alive (the
    /// persistent-mode primary timer / snooze re-fire timer). Like beginAttempt
    /// but WITHOUT the shouldBePlaying guard — nothing is ringing yet. The player
    /// runs at a PINNED volume 0 (setVolume ignores writes while isPrewarming),
    /// reusing the confirmation machinery so the stream is buffered/confirmed
    /// BEFORE fire; beginAttempt() then adopts it for an instant, tone-free
    /// takeover. On confirm it does NOT mute a wav (none is ringing) and does NOT
    /// report the click — it records the confirmed state and stays silent.
    /// Failures/stalls during prewarm tear down QUIETLY (no wav to restore).
    /// NEVER touches the audio session, category, Now Playing, or system volume —
    /// it is a bare AVPlayer riding whatever session already exists.
    func prewarmAttempt(stationID: String?, stationName: String?, urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else { return }
        // Never disturb a stream that is actually ringing or being held for a
        // grace period — a real alarm owns the streamer. The upcoming alarm's
        // fire path will attempt normally.
        //
        // The skip guards run BEFORE the last-station bookkeeping on purpose
        // (al-033). Storing the station first meant a prewarm that then skipped
        // still repointed lastStation* at the UPCOMING alarm — so the RINGING
        // alarm's post-grace `reattemptLastStation()` would come back on a
        // different alarm's station. A skipped prewarm must leave no trace.
        guard !isStreaming, !isGraceHolding else {
            print("📻 RadioAlarmStreamer: prewarm skipped — a stream is already active")
            AppLogger.shared.log("Radio alarm: prewarm skipped — stream active for another alarm (streaming=\(isStreaming), graceHold=\(isGraceHolding)) station='\(stationName ?? urlString)'", category: .alarm)
            return
        }
        // Don't prewarm into a muted grace window (e.g. a previous alarm's
        // mission). A prewarm stays silent regardless, but skip to be safe.
        guard !AlarmWindowManager.shared.isGracePeriodMuted else {
            print("📻 RadioAlarmStreamer: prewarm skipped — grace period muted")
            AppLogger.shared.log("Radio alarm: prewarm skipped — grace period muted, station='\(stationName ?? urlString)'", category: .alarm)
            return
        }

        // Store the last-attempt fields exactly as beginAttempt does (source of
        // truth for the fire-time adoption match and any post-grace re-attempt).
        lastStationID = stationID
        lastStationName = stationName
        lastStationURL = urlString

        // Supersede any lingering prewarm bookkeeping (also clears the flags).
        tearDown(restoreWav: false)
        isPrewarming = true
        prewarmConfirmed = false
        generation += 1
        let myGeneration = generation

        print("📻 RadioAlarmStreamer: prewarming '\(stationName ?? "station")' (silent, volume 0)")
        AppLogger.shared.log("Radio alarm: prewarming stream '\(stationName ?? urlString)'", category: .alarm)

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        newPlayer.volume = 0  // pinned silent throughout prewarm
        newPlayer.play()
        player = newPlayer

        // Meter rendered audio during the prewarm too, so a dead-air station
        // does not confirm silently and get adopted at fire. Fail-soft as above.
        let monitor = StreamAudioLevelMonitor()
        monitor.attach(url: url)
        levelMonitor = monitor

        timeObserverToken = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 10),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.generation == myGeneration else { return }
                if !self.isStreaming, !self.prewarmConfirmed, time.seconds > 0.5 {
                    if DeadAirPolicy.mayConfirm(isMonitoring: self.levelMonitor?.isMonitoring ?? false,
                                                hasHeardAudio: self.levelMonitor?.hasHeardAudio ?? false,
                                                contentGateActive: self.levelMonitor?.isContentGateActive ?? false,
                                                hasHeardContent: self.levelMonitor?.hasHeardContent ?? false) {
                        if self.isPrewarming {
                            self.prewarmDidConfirm()
                        } else {
                            // beginAttempt adopted this prewarm before it confirmed —
                            // finish the normal confirm handoff now (mute wav, raise).
                            self.confirmStream(stationID: stationID, stationName: stationName)
                        }
                    } else if !self.loggedSilentHold {
                        self.loggedSilentHold = true
                        // See beginAttempt: loud → content gate hold; silent → dead air.
                        if self.levelMonitor?.hasHeardAudio == true {
                            print("📻 RadioAlarmStreamer: stream rendering but no content confirmed yet — holding tone")
                            AppLogger.shared.log("Radio alarm: stream rendering but no content confirmed yet — holding tone", category: .alarm)
                        } else {
                            print("📻 RadioAlarmStreamer: stream rendering but silent — holding tone (possible dead air)")
                            AppLogger.shared.log("Radio alarm: stream is rendering but silent — holding tone (possible dead air)", category: .alarm)
                        }
                    }
                }
                self.lastProgressSeconds = time.seconds
            }
        }

        // Give up quietly if the prewarm never starts — nothing is ringing.
        confirmTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.confirmTimeout ?? 20))
            guard let self, self.generation == myGeneration,
                  !self.isStreaming, !self.prewarmConfirmed else { return }
            if let monitor = self.levelMonitor, monitor.isMonitoring, monitor.hasHeardAudio,
               monitor.isContentGateActive, !monitor.hasHeardContent, self.lastProgressSeconds > 0.5 {
                // Loud but no recognizable content — noise-like. Checked BEFORE
                // the dead-air variant (a noise stream has hasHeardAudio == true).
                print("📻 RadioAlarmStreamer: prewarm was noise-like — torn down quietly")
                AppLogger.shared.log("Radio alarm: prewarm was noise-like — torn down quietly", category: .alarm)
            } else if let monitor = self.levelMonitor, monitor.isMonitoring, !monitor.hasHeardAudio, self.lastProgressSeconds > 0.5 {
                print("📻 RadioAlarmStreamer: prewarm was dead air — torn down quietly")
                AppLogger.shared.log("Radio alarm: prewarm was dead air — torn down quietly", category: .alarm)
            } else {
                print("📻 RadioAlarmStreamer: prewarm never confirmed — tearing down quietly")
                AppLogger.shared.log("Radio alarm: prewarm timed out, torn down quietly", category: .alarm)
            }
            self.tearDown(restoreWav: false)
        }

        // Terminal item events → quiet teardown while prewarming (handleStreamFailure
        // checks isPrewarming); after adoption they drive the normal wav failover.
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleStreamFailure(generation: myGeneration, reason: "prewarm item failed") }
        })
        itemObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleStreamFailure(generation: myGeneration, reason: "prewarm stream ended") }
        })

        startPreConfirmWatchdog()
    }

    /// A prewarmed stream just confirmed. Stay SILENT — there is no wav to mute
    /// and the click is reported only at the fire-time adoption. Start the stall
    /// watchdog so a stall during the prewarm window tears down quietly, leaving
    /// the fire path to attempt fresh.
    private func prewarmDidConfirm() {
        prewarmConfirmed = true
        print("📻 RadioAlarmStreamer: prewarm confirmed — holding silent until fire")
        AppLogger.shared.log("Radio alarm: prewarm confirmed, holding silent until fire", category: .alarm)
        startStallWatchdog()
    }

    /// Cancel an in-progress prewarm (alarm cancelled / rescheduled / disabled
    /// before fire). No-op unless actively prewarming — it must NEVER disturb a
    /// stream that is really ringing or being held for a grace period.
    func cancelPrewarm() {
        guard isPrewarming else { return }
        print("📻 RadioAlarmStreamer: prewarm cancelled")
        AppLogger.shared.log("Radio alarm: prewarm cancelled", category: .alarm)
        tearDown(restoreWav: false)  // clears isPrewarming / prewarmConfirmed
    }

    /// Silent-grace helper for the fire paths: block until the stream
    /// confirms, the attempt dies, or `seconds` elapse — whichever is first.
    /// Lets a healthy stream cut in BEFORE the alarm tone is ever heard,
    /// while a dead stream only delays the tone by the capped grace window.
    func waitForConfirmation(upTo seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isStreaming || player == nil { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Interruption recovery

    /// Resume a stream that an audio-session interruption left PAUSED.
    ///
    /// `AlarmSoundPlayer.attemptResume` re-activates the session and restarts
    /// the wav — and only the wav. AVPlayer is paused by the same interruption
    /// and is never told to resume, so a stream that had not yet CONFIRMED sat
    /// at volume 0 with a playback clock that could no longer advance: no
    /// confirmation, no stall watchdog (that only started at confirmStream), and
    /// the fade telemetry reporting stream=0.00 for the rest of the ring. The
    /// user heard the fallback tone with a perfectly healthy station attached
    /// (al-xhy, 2026-08-05 dual-alarm incident).
    ///
    /// Covers all three player states — confirmed, adopted-in-flight, and
    /// prewarming — because all three ride the one AVPlayer. Safe to call
    /// repeatedly and when idle; the 30s confirm timeout and the tone fallback
    /// are untouched, so this can only ever ADD radio, never remove tone.
    func resumeAfterInterruption() {
        guard let player else { return }
        // Only nudge a player that is meant to be running: a confirmed stream, a
        // prewarm holding for its fire, or an in-flight attempt for a wav that
        // is still ringing.
        guard isStreaming || isPrewarming || AlarmSoundPlayer.shared.shouldBePlaying else { return }
        guard player.timeControlStatus != .playing else { return }
        player.play()
        print("📻 RadioAlarmStreamer: resumed stream after audio interruption")
        AppLogger.shared.log("Radio alarm: stream resumed after interruption (confirmed=\(isStreaming), prewarm=\(isPrewarming))", category: .alarm)
        // An unconfirmed attempt has no stall watchdog yet — make sure the
        // pre-confirmation nudge is running so a player that pauses again
        // still gets retried instead of sitting silent until the timeout.
        if !isStreaming && !prewarmConfirmed {
            startPreConfirmWatchdog()
        }
    }

    /// Forwarded fade-ramp / volume writes while streaming.
    func setVolume(_ volume: Float) {
        // During a grace hold OR a prewarm the stream MUST stay silent no matter
        // what fade ramps or volume restores forward here — a grace hold is
        // deliberately muted, and a prewarm rides at volume 0 until fire adopts
        // it. Pin to 0 and ignore the requested level.
        if isGraceHolding || isPrewarming {
            player?.volume = 0
            return
        }
        player?.volume = streamVolume(forToneVolume: volume)
    }

    /// Ease applied to the fade POSITION. Gentler than the tone's quadratic
    /// (p²) so the stream becomes present earlier in the window, steeper than
    /// linear so it still climbs like a fade rather than arriving loud.
    private let streamFadeEase: Float = 1.5

    /// Map the alarm tone's fade volume to the STREAM volume for the same
    /// moment in the fade.
    ///
    /// NOT a function of the tone's amplitude — of its fade POSITION. Reusing
    /// the amplitude means picking between two bad options: pass it through and
    /// broadcast material is inaudible for minutes, or compress it (the old
    /// `sqrt(volume)`) and the stream opens at 22% and is past half volume
    /// halfway in. The position lets the stream run its OWN curve over the
    /// same window.
    ///
    /// The curve starts from TRUE SILENCE. An earlier revision added a 6%
    /// floor ("broadcast material needs an audible floor") — device telemetry
    /// showed that floor as a plainly audible radio onset in second one of a
    /// minutes-long fade, reported as "the fade doesn't start at 0". A fade
    /// means silence → full; p^1.5 (vs the tone's p²) is what keeps the radio
    /// coming up EARLIER in the window than the tone would, without a floor:
    /// ~3% at a tenth in, ~9% at a fifth, ~35% halfway, 100% at the end.
    /// Full volume (fade off, or fade complete) passes through unchanged.
    private func streamVolume(forToneVolume volume: Float) -> Float {
        let clamped = min(max(volume, 0.0), 1.0)
        guard clamped > 0 else { return 0 }
        guard clamped < 1.0 else { return 1.0 }
        let position = VolumeManager.shared.fadePosition(forPlayerVolume: clamped)
        return pow(position, streamFadeEase)
    }

    // MARK: - Grace hold (mission grace period)

    /// Begin holding a confirmed stream alive but silent through a mission
    /// grace period. No-op when there is no confirmed stream to hold (a
    /// re-attempt after grace will start fresh instead). Playback continues;
    /// the player is pinned to volume 0 and stays there until endGraceHold().
    func beginGraceHold() {
        guard isStreaming, player != nil else { return }  // nothing to hold
        isGraceHolding = true
        player?.volume = 0
        print("📻 RadioAlarmStreamer: grace hold begun — stream muted, kept alive")
        AppLogger.shared.log("Radio alarm: grace hold — stream held silent", category: .alarm)
    }

    /// End a grace hold. Returns true if the held stream is STILL alive and
    /// confirmed (caller re-establishes hot standby via resumeFromGraceHold);
    /// false if the hold died mid-grace or there was never a stream (caller
    /// starts a fresh beginAttempt). Clears the hold flag either way.
    func endGraceHold() -> Bool {
        let wasHolding = isGraceHolding
        isGraceHolding = false
        let survived = wasHolding && isStreaming && player != nil
        AppLogger.shared.log("Radio alarm: grace hold ended survived=\(survived)", category: .alarm)
        return survived
    }

    /// Post-grace re-establishment for a stream that survived the hold: the
    /// wav has just been restarted, so re-mute it into hot standby and raise
    /// the (already-confirmed) stream to the post-grace volume. Reuses the
    /// confirm/standby machinery — no new 30s confirm window is run.
    func resumeFromGraceHold() {
        guard isStreaming, player != nil else { return }
        AlarmSoundPlayer.shared.radioStreamDidConfirm()  // mute the restarted wav
        setVolume(VolumeManager.shared.playerVolumeForCurrentFade())
        print("📻 RadioAlarmStreamer: resumed held stream at post-grace volume")
        AppLogger.shared.log("Radio alarm: held stream resumed after grace", category: .alarm)
    }

    /// Tear down without touching the wav (dismiss/snooze/new alarm paths —
    /// the wav's own lifecycle is handled by AlarmSoundPlayer). Always clears
    /// any grace hold: this is the full-stop that every dismiss/snooze path
    /// (including mid-grace) converges on, so the held stream can't leak.
    func stop() {
        isGraceHolding = false
        tearDown(restoreWav: false)
    }

    // MARK: - Private

    private func confirmStream(stationID: String?, stationName: String?) {
        isStreaming = true
        // Wav becomes the hot standby: muted but still looping, so watchdogs
        // and restart paths see a playing alarm, and failover is instant.
        AlarmSoundPlayer.shared.radioStreamDidConfirm()
        // Join at the correct fade volume (1.0 when no fade is running),
        // mapped to the stream's perceptual curve.
        setVolume(VolumeManager.shared.playerVolumeForCurrentFade())
        if let stationID {
            RadioBrowserAPI.shared.reportClick(stationID: stationID)
        }
        print("📻 RadioAlarmStreamer: stream confirmed — alarm tone muted (standby)")
        AppLogger.shared.log("Radio alarm: stream playing '\(stationName ?? "station")' vol=\(Int((player?.volume ?? 0) * 100))%", category: .alarm)
        startStallWatchdog()
    }

    /// Watchdog for the window BETWEEN attempt and confirmation, where nothing
    /// else was watching the player at all.
    ///
    /// The 30s confirm timeout is the terminal fallback and stays exactly as it
    /// was — but it only ever concludes "this station never started", and tears
    /// the attempt down. An audio-session interruption PAUSES the AVPlayer, and
    /// a paused player's clock cannot advance, so a perfectly good station looks
    /// identical to a dead one and the ring silently downgrades to the tone.
    /// This re-issues play() every few seconds while the attempt is still
    /// unconfirmed. It never mutes the wav and never confirms anything itself.
    private func startPreConfirmWatchdog() {
        preConfirmTimer?.invalidate()
        let myGeneration = generation
        preConfirmTimer = Timer.scheduledTimer(withTimeInterval: stallCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == myGeneration else { return }
                // Confirmed (or torn down) → the stall watchdog owns it now.
                guard !self.isStreaming, !self.prewarmConfirmed, let player = self.player else {
                    self.preConfirmTimer?.invalidate()
                    self.preConfirmTimer = nil
                    return
                }
                guard player.timeControlStatus == .paused else { return }
                print("📻 RadioAlarmStreamer: unconfirmed stream is paused — re-issuing play()")
                AppLogger.shared.log("Radio alarm: unconfirmed stream paused — re-issuing play()", category: .alarm)
                player.play()
            }
        }
    }

    private func startStallWatchdog() {
        // Confirmation has happened — the pre-confirmation nudge has no job left.
        preConfirmTimer?.invalidate()
        preConfirmTimer = nil
        stallStrikes = 0
        var lastChecked = lastProgressSeconds
        let myGeneration = generation
        stallTimer?.invalidate()
        stallTimer = Timer.scheduledTimer(withTimeInterval: stallCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // The watchdog covers both a confirmed live stream and a
                // confirmed-but-silent prewarm (a stall during the prewarm
                // window tears down quietly via handleStreamFailure).
                guard let self, self.generation == myGeneration,
                      self.isStreaming || self.isPrewarming else { return }
                let advanced = self.lastProgressSeconds > lastChecked
                if self.lastProgressSeconds <= lastChecked {
                    self.stallStrikes += 1
                    if self.stallStrikes >= 2 {
                        self.handleStreamFailure(generation: myGeneration, reason: "stalled")
                        return
                    }
                } else {
                    self.stallStrikes = 0
                }
                // A confirmed stream that goes SILENT while its clock keeps
                // advancing (dead air) is not a stall — fail over to the tone.
                // clockAdvanced gates this off when the player is merely paused
                // (interruption), which is the stall watchdog's territory.
                if let monitor = self.levelMonitor,
                   DeadAirPolicy.isDeadAir(isMonitoring: monitor.isMonitoring,
                                           clockAdvanced: advanced,
                                           lastAudibleAt: monitor.lastAudibleAt,
                                           monitoringSince: monitor.monitoringSince,
                                           now: Date()) {
                    self.handleStreamFailure(generation: myGeneration, reason: "dead air")
                    return
                }
                lastChecked = self.lastProgressSeconds
            }
        }
    }

    private func handleStreamFailure(generation failedGeneration: Int, reason: String) {
        guard generation == failedGeneration else { return }
        // During a grace hold OR a prewarm there is no ringing wav to fail back
        // to — the grace window stopped the wav, and a prewarm runs before fire.
        // Tear down quietly: endGraceHold() then reports the stream died (resume
        // re-attempts fresh), and a torn-down prewarm leaves the fire path to
        // attempt normally — exactly as if no prewarm had ever run.
        if isGraceHolding || isPrewarming {
            print("📻 RadioAlarmStreamer: stream failure (\(reason)) during \(isPrewarming ? "prewarm" : "grace hold") — tearing down quietly")
            AppLogger.shared.log("Radio alarm: stream \(reason) during \(isPrewarming ? "prewarm" : "grace hold") — quiet teardown", category: .alarm)
            tearDown(restoreWav: false)
            return
        }
        print("📻 RadioAlarmStreamer: stream failure (\(reason)) — restoring alarm tone")
        AppLogger.shared.log("Radio alarm: stream \(reason) — alarm tone restored", category: .alarm)
        logFellBackToTone()
        tearDown(restoreWav: true)
    }

    /// The tone is carrying the alarm because the stream never confirmed,
    /// stalled, errored, or ended. Emitted from the two failover paths only —
    /// never from a quiet prewarm/grace-hold teardown, where nothing is ringing
    /// and there is no tone to fall back TO.
    private func logFellBackToTone() {
        let attempted = attemptStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        Analytics.shared.log(.radioFellBackToTone(secondsAttempted: attempted))
    }

    private func tearDown(restoreWav: Bool) {
        generation += 1
        confirmTimeoutTask?.cancel()
        confirmTimeoutTask = nil
        stallTimer?.invalidate()
        stallTimer = nil
        preConfirmTimer?.invalidate()
        preConfirmTimer = nil
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        for observer in itemObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        itemObservers = []
        player?.pause()
        player = nil
        levelMonitor?.detach()
        levelMonitor = nil
        loggedSilentHold = false
        lastProgressSeconds = 0
        stallStrikes = 0
        attemptStartedAt = nil
        // Any teardown clears prewarm bookkeeping — a prewarm can never outlive
        // its player.
        isPrewarming = false
        prewarmConfirmed = false
        adoptedInFlightPrewarm = false

        let wasStreaming = isStreaming
        isStreaming = false
        if restoreWav && wasStreaming {
            // Unmute the standby wav at the correct fade volume.
            AlarmSoundPlayer.shared.radioStreamDidFail()
        }
    }
}
