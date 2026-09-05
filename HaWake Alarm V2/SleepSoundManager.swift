
//
//  SleepSoundManager.swift
//  HaWake Alarm V2
//
//  Manages sleep sound playback — looping ambient audio with optional timer,
//  fade-out, and automatic pause when an alarm fires.
//

import Foundation
import AVFoundation
import AudioToolbox
import Darwin
import MediaPlayer
import Observation
import UIKit

enum SleepSoundPlayState {
    case stopped, playing, paused
}

enum SleepSoundMode {
    case duration(TimeInterval)   // play for N seconds then stop
    case until(Date)              // play until a specific date (e.g. morning alarm)
    case indefinite               // play until manually stopped
}

@Observable
final class SleepSoundManager {
    static let shared = SleepSoundManager()

    private(set) var state: SleepSoundPlayState = .stopped
    private(set) var selectedSoundName: String = ""
    private(set) var endTime: Date? = nil
    private(set) var fadeOutDuration: TimeInterval = 0
    var volume: Double = 0.5

    var isActive: Bool { state != .stopped }

    /// Whether a claimed-active sleep sound is actually covering the audio
    /// session right now — the engine is running (playing, or muted during a
    /// pause) OR an interruption is in progress (nothing can run mid-
    /// interruption; recovery lands at `.ended`). When this is false while
    /// `isActive` is true, the session is a phantom — state says active but
    /// nothing holds it — and the keep-alive must step in rather than defer
    /// (al-cbf).
    var hasLiveCoverage: Bool { (engine?.isRunning ?? false) || isInterrupted }

    var timeRemaining: TimeInterval? {
        guard let endTime else { return nil }
        let remaining = endTime.timeIntervalSinceNow
        return remaining > 0 ? remaining : 0
    }

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var loopBuffer: AVAudioPCMBuffer?   // retained for ping-pong scheduling
    private var fadeTimer: Timer?
    private var endTimer: Timer?
    private var idleTimer: Timer?
    private var playbackStartTime: Date?
    /// Incremented on every changeSound/stop call. Background load tasks compare
    /// against this before scheduling onto the node — stale loads silently discard.
    private var soundChangeGeneration = 0
    // Guard flag: prevents restarting the engine during a known interruption
    // (alarm firing, phone call, etc.). Without it, the engine restart from
    // AVAudioEngineConfigurationChange would fight the interrupting audio.
    private var isInterrupted = false
    // Set by handleAlarmWillFire() so handleAlarmEnded() knows the pause was
    // ours to undo — a pause the user asked for is never resurrected.
    // Distinct from isInterrupted (phone calls etc.) so the two don't interfere.
    private var pausedByAlarm = false

    private init() {
        setupNotificationObservers()
        setupRemoteCommandCenter()
        // Start with commands disabled — iOS shows the lock-screen Now Playing
        // widget any time MPRemoteCommandCenter commands are enabled, even if
        // `nowPlayingInfo` is nil. We only want the widget visible while sleep
        // sounds are actually playing/paused.
        setRemoteCommandsEnabled(false)
    }

    private func setupNotificationObservers() {
        // AVAudioEngine stops itself when a configuration change occurs (e.g.,
        // when a SwiftUI sheet animation triggers an audio session reconfigure).
        // Restart it transparently so playback continues without crackling.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
        // Handle phone calls, Siri, alarms from other apps, etc.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        // Another media app taking over Now Playing (or a route swap, or a
        // mediaserverd reset) blanks nowPlayingInfo with nothing to restore
        // it — the widget stayed empty for the rest of the session. Republish.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshNowPlayingIfActive),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func refreshNowPlayingIfActive() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state == .playing else { return }
            // handleAlarmWillFire() deliberately clears nowPlayingInfo so the
            // media widget doesn't appear over the alarm UI, and the alarm's
            // own overrideOutputAudioPort(.speaker) posts a route change — so
            // republishing here would immediately undo that clear.
            guard !AlarmSoundPlayer.shared.shouldBePlaying else { return }
            self.updateNowPlayingInfo()
        }
    }

    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        // Posted synchronously on the engine's internal thread. Hop to main
        // before touching the engine: every other engine call in this class
        // runs on the main thread, and AVAudioEngine is not thread-safe — a
        // concurrent start() here while changeSound() is mid graph surgery
        // can wedge the engine's internal lock, after which the next engine
        // call on main blocks forever and the whole UI freezes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.state == .playing, !self.isInterrupted else { return }
            // By the time this runs, changeSound() has finished its reconnect
            // (and restarted the engine itself if needed) — only act when the
            // engine genuinely stayed down.
            guard let eng = self.engine, !eng.isRunning else { return }
            do {
                try eng.start()
                print("🔄 SleepSoundManager: engine restarted after configuration change")
            } catch {
                print("❌ SleepSoundManager: engine restart after config change failed — \(error)")
            }
        }
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        // Not guaranteed to arrive on main — serialize with the rest of the
        // engine calls (see handleEngineConfigurationChange).
        let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        DispatchQueue.main.async { [weak self] in
            self?.processAudioInterruption(type: type, optionsRaw: optionsRaw)
        }
    }

    private func processAudioInterruption(type: AVAudioSession.InterruptionType, optionsRaw: UInt) {
        switch type {
        case .began:
            isInterrupted = true
            BackgroundAudioKeepAlive.isAudioSessionInterrupted = true
            if state == .playing {
                engine?.pause()
                playerNode?.pause()
                // Don't change state — user didn't request pause, just hold position
                print("⏸ SleepSoundManager: audio interrupted (e.g., call/Siri)")
            }
            // If state == .paused the engine was running silently; iOS will stop it
            // automatically during the interruption — no action needed here.
            AppLogger.shared.log("SleepSoundManager: audio interruption began (state=\(state))", category: .audio)
        case .ended:
            isInterrupted = false
            BackgroundAudioKeepAlive.isAudioSessionInterrupted = false
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            AppLogger.shared.log("SleepSoundManager: audio interruption ended (state=\(state), shouldResume=\(shouldResume))", category: .audio)
            // A stopped session owes nothing. For .playing or .paused we must
            // NOT leave an active-but-dead session: iOS tears the engine down
            // during the interruption while our state still reads active, and a
            // keep-alive that trusts that state then defers forever with no
            // coverage (al-cbf). Recover regardless of `.shouldResume` — iOS
            // omits it for a reclaimed background session — but honour the
            // pause: a paused sound is restored to a running-but-muted engine,
            // never made audible.
            guard state != .stopped else { break }
            recoverAfterInterruption()
        @unknown default:
            break
        }
    }

    /// Restores audio coverage after an interruption ends: reactivates the
    /// session, restarts the engine, and re-arms the loop so the app keeps a
    /// live session in the background. Volume follows state — `.playing`
    /// becomes audible again, a `.paused` (user- or alarm-paused) sound stays
    /// muted and is never audibly resumed. If recovery fails, the sound is
    /// stopped and the keep-alive restarted: a stopped sound with a running
    /// keep-alive beats a phantom "active" session that keeps the real
    /// keep-alive deferred (al-cbf).
    private func recoverAfterInterruption() {
        // A sounding alarm owns the session (.playAndRecord + speaker
        // override); re-applying .playback here would stomp it mid-ring. The
        // ring's end path stops the sleep sound anyway (al-ecf), so leave
        // recovery to the alarm stack.
        if AlarmSoundPlayer.shared.shouldBePlaying {
            AppLogger.shared.log("SleepSoundManager: interruption recovery skipped — alarm owns the session", category: .audio)
            return
        }
        guard let eng = engine else {
            AppLogger.shared.log("SleepSoundManager: interruption recovery found no engine — stopping and restarting keep-alive", category: .audio)
            internalStop(restartKeepAlive: true)
            return
        }
        do {
            try AppAudioSession.setCategory(.playback, mode: .default)
            try AppAudioSession.setActive(true)
            if !eng.isRunning { try eng.start() }
            if let node = playerNode, !node.isPlaying {
                if let buffer = loopBuffer {
                    node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                }
                node.play()
            }
            // Never audibly resume a pause — only a .playing sound gets its volume back.
            eng.mainMixerNode.outputVolume = state == .playing ? Float(volume) : 0
            setRemoteCommandsEnabled(true)
            updateNowPlayingInfo()
            AppLogger.shared.log("SleepSoundManager: recovered audio session after interruption (state=\(state))", category: .audio)
        } catch {
            AppLogger.shared.log("SleepSoundManager: interruption recovery FAILED — \(error); stopping and restarting keep-alive", category: .audio)
            internalStop(restartKeepAlive: true)
        }
    }

    // MARK: - Buffer Loading

    /// Reads an audio file into a PCM buffer, stripping AAC encoder priming/remainder frames
    /// (if present), trimming trailing silence, and baking a crossfade at the loop point
    /// so the buffer loops with zero gap when scheduled with .loops.
    nonisolated static func loadLoopBuffer(from url: URL) throws -> AVAudioPCMBuffer {
        let audioFile = try AVAudioFile(forReading: url)
        let fullCount = AVAudioFrameCount(audioFile.length)
        guard let fullBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                                frameCapacity: fullCount) else {
            throw NSError(domain: "SleepSoundManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to allocate PCM buffer"])
        }
        try audioFile.read(into: fullBuffer)

        // Pass 1: Strip AAC encoder priming / remainder frames via packet table info.
        // This is only meaningful for compressed (AAC/m4a) files — other formats fall
        // through to workBuffer = fullBuffer and still get the silence-trim + crossfade.
        var workBuffer: AVAudioPCMBuffer = fullBuffer
        var fileID: AudioFileID?
        if AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID {
            defer { AudioFileClose(fileID) }
            var info = AudioFilePacketTableInfo()
            var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
            if AudioFileGetProperty(fileID, kAudioFilePropertyPacketTableInfo, &size, &info) == noErr,
               // mPrimingFrames is Int32 and can be 0 or (rarely) negative in some encoders.
               // mNumberValidFrames is Int64 and can theoretically be negative too.
               // AVAudioFrameCount is UInt32 — direct conversion of a negative value is a
               // Swift integer-overflow TRAP (hard crash, not a throw). Guard both values
               // before converting, and also verify their sum fits inside the decoded buffer
               // to prevent an out-of-bounds read in the initialize(from:) call below.
               info.mPrimingFrames >= 0, info.mNumberValidFrames > 0 {
                let priming = AVAudioFrameCount(info.mPrimingFrames)
                let valid   = AVAudioFrameCount(info.mNumberValidFrames)
                print("🔎 loadLoopBuffer: fullCount=\(fullCount) priming=\(priming) valid=\(valid)")
                if priming < fullCount,
                   valid <= fullCount,
                   priming &+ valid <= fullCount,
                   let trimmed = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                                  frameCapacity: valid) {
                    let ch = Int(audioFile.processingFormat.channelCount)
                    if let src = fullBuffer.floatChannelData, let dst = trimmed.floatChannelData {
                        for c in 0..<ch {
                            dst[c].initialize(from: src[c].advanced(by: Int(priming)), count: Int(valid))
                        }
                    }
                    trimmed.frameLength = valid
                    workBuffer = trimmed
                }
            } else {
                print("⚠️ loadLoopBuffer: no packet table info — skipping AAC priming trim")
            }
        }

        // Pass 2: Trim trailing silence so dead space at the end of the file doesn't
        // produce an audible gap at the loop point. Scans backwards in 4096-frame blocks.
        workBuffer = trimTrailingSilence(from: workBuffer)

        // Pass 3: Zero-crossing alignment.
        // Snap the loop region to zero crossings near both ends of the audio so the
        // join is at a natural silence point on both sides. Searching within a 50ms
        // window (2205 frames at 44.1 kHz) keeps the loop semantically intact.
        // Uses channel 0 for the search — standard practice for multi-channel files.
        let channels = Int(audioFile.processingFormat.channelCount)
        workBuffer = snapToZeroCrossings(buffer: workBuffer, searchWindow: 2205)
        let totalFrames = Int(workBuffer.frameLength)

        // Pass 4: Bake an equal-power crossfade into the last ~46ms of the buffer so the
        // amplitude envelope at the loop seam is smooth. When .loops restarts at frame 0,
        // the tail has already been blended with the head — no audible dip or pop.
        // This runs for ALL formats (not just AAC) because workBuffer always reaches here.
        let C = min(2048, totalFrames / 4)   // crossfade window (~46ms at 44.1 kHz)
        if C > 0, let pcm = workBuffer.floatChannelData {
            let pi_2 = Float.pi / 2.0
            for i in 0..<C {
                let angle   = Float(i) / Float(C) * pi_2
                let fadeOut = cos(angle) * cos(angle)   // 1 → 0
                let fadeIn  = sin(angle) * sin(angle)   // 0 → 1
                let endIdx  = totalFrames - C + i
                for ch in 0..<channels {
                    pcm[ch][endIdx] = pcm[ch][endIdx] * fadeOut + pcm[ch][i] * fadeIn
                }
            }
        }

        return workBuffer
    }

    /// Extracts the sub-region [zStart, zEnd] from the buffer, where zStart is the
    /// first zero crossing near frame 0 and zEnd is the last zero crossing near the
    /// final frame. Both sides of the loop seam are then at ~zero amplitude, which
    /// eliminates the click that occurs when the loop restarts at a non-zero sample.
    /// Returns the original buffer if no useful crossings are found or if the
    /// sub-region would be too small.
    nonisolated static func snapToZeroCrossings(
        buffer: AVAudioPCMBuffer,
        searchWindow: Int = 2205
    ) -> AVAudioPCMBuffer {
        guard let pcm = buffer.floatChannelData else { return buffer }
        let total    = Int(buffer.frameLength)
        let ch0      = pcm[0]
        let channels = Int(buffer.format.channelCount)

        // Find first zero crossing scanning forward from frame 0
        let zStart = firstZeroCrossing(in: ch0, from: 0, totalFrames: total, maxSearch: searchWindow)
        // Find last zero crossing scanning backward from final frame
        let zEnd   = lastZeroCrossing(in: ch0, before: total, maxSearch: searchWindow)

        // Require at least 4× the crossfade window of content to remain
        guard zEnd > zStart, (zEnd - zStart) >= 4 * 2048 else { return buffer }
        // Skip if there's nothing meaningful to trim
        guard zStart > 0 || zEnd < total - 1 else { return buffer }

        let newCount = zEnd - zStart
        guard let result = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                            frameCapacity: AVAudioFrameCount(newCount)) else {
            return buffer
        }
        if let src = buffer.floatChannelData, let dst = result.floatChannelData {
            for ch in 0..<channels {
                dst[ch].initialize(from: src[ch].advanced(by: zStart), count: newCount)
            }
        }
        result.frameLength = AVAudioFrameCount(newCount)
        print("🎯 loadLoopBuffer: zero-crossing snap zStart=\(zStart) zEnd=\(zEnd) (trimmed \(zStart) leading + \(total - zEnd) trailing frames)")
        return result
    }

    /// First zero crossing at or after `from`, within `maxSearch` frames.
    /// Returns `from` unchanged if none is found. Picks the sample closer to zero.
    private nonisolated static func firstZeroCrossing(
        in ch0: UnsafePointer<Float>,
        from: Int,
        totalFrames: Int,
        maxSearch: Int
    ) -> Int {
        let limit = min(from + maxSearch, totalFrames - 1)
        for i in from..<limit {
            if ch0[i] * ch0[i + 1] <= 0 {
                return abs(ch0[i]) <= abs(ch0[i + 1]) ? i : i + 1
            }
        }
        return from
    }

    /// Last zero crossing strictly before `before`, within `maxSearch` frames.
    /// Returns `before` unchanged if none is found. Picks the sample closer to zero.
    private nonisolated static func lastZeroCrossing(
        in ch0: UnsafePointer<Float>,
        before: Int,
        maxSearch: Int
    ) -> Int {
        let limit = max(before - maxSearch, 1)
        for i in stride(from: before - 1, through: limit, by: -1) {
            if ch0[i] * ch0[i + 1] <= 0 {
                return abs(ch0[i]) <= abs(ch0[i + 1]) ? i : i + 1
            }
        }
        return before
    }

    /// Scans backwards through a PCM buffer and removes trailing frames that fall
    /// below `silenceThreshold`. Returns the original buffer unchanged if the trailing
    /// silence is shorter than `minSilenceFrames` (avoids trimming natural fade-outs).
    nonisolated static func trimTrailingSilence(
        from buffer: AVAudioPCMBuffer,
        silenceThreshold: Float = 0.001,  // ~−60 dB
        minSilenceFrames: Int = 2205      // ~50 ms at 44.1 kHz — ignore tiny tail noise
    ) -> AVAudioPCMBuffer {
        guard let pcm = buffer.floatChannelData else { return buffer }
        let totalFrames = Int(buffer.frameLength)
        let channels    = Int(buffer.format.channelCount)
        let blockSize   = 4096

        var trimTo = totalFrames
        var block  = (totalFrames - 1) / blockSize

        outerLoop: while block >= 0 {
            let blockStart = block * blockSize
            let blockEnd   = min(blockStart + blockSize, totalFrames)
            for frame in stride(from: blockEnd - 1, through: blockStart, by: -1) {
                var peak: Float = 0
                for ch in 0..<channels {
                    let v = abs(pcm[ch][frame])
                    if v > peak { peak = v }
                }
                if peak > silenceThreshold {
                    trimTo = frame + 1
                    break outerLoop
                }
            }
            block -= 1
        }

        let silenceFrames = totalFrames - trimTo
        guard silenceFrames >= minSilenceFrames else { return buffer }

        let sampleRate = buffer.format.sampleRate
        print("✂️ loadLoopBuffer: trimming \(silenceFrames) trailing silence frames (~\(String(format: "%.0f", Double(silenceFrames) / sampleRate * 1000))ms)")

        guard let result = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                            frameCapacity: AVAudioFrameCount(trimTo)) else {
            return buffer
        }
        if let src = buffer.floatChannelData, let dst = result.floatChannelData {
            for ch in 0..<channels {
                dst[ch].initialize(from: src[ch], count: trimTo)
            }
        }
        result.frameLength = AVAudioFrameCount(trimTo)
        return result
    }

    // MARK: - Sound Discovery

    /// Directory where imported .hwsound files are stored (sandboxed, never shipped).
    static var importedSoundsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Sleep Sounds", isDirectory: true)
    }

    static func availableSounds() -> [String] {
        // Bundle sounds
        let subdir = Bundle.main.urls(forResourcesWithExtension: "m4a", subdirectory: "Sleep Sounds") ?? []
        let bundleURLs = subdir.isEmpty
            ? (Bundle.main.urls(forResourcesWithExtension: "m4a", subdirectory: nil) ?? [])
            : subdir
        let bundleNames = bundleURLs.map { $0.deletingPathExtension().lastPathComponent }

        // Imported sounds from Documents/Sleep Sounds/ (legacy)
        let importDir = importedSoundsDirectory
        let importedNames: [String]
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: importDir, includingPropertiesForKeys: nil
        ) {
            importedNames = contents
                .filter { $0.pathExtension.lowercased() == "m4a" }
                .map { $0.deletingPathExtension().lastPathComponent }
        } else {
            importedNames = []
        }

        // Custom sleep sounds from CustomSoundManager
        let customSounds = CustomSoundManager.shared.sleepSounds()
        let customNames = customSounds.map(\.id)

        // Legacy imports get migrated into CustomSoundManager at bootstrap but
        // the original file stays in Documents/Sleep Sounds — drop legacy
        // entries whose display name matches a custom sound so the migrated
        // copy doesn't show up twice.
        let customDisplayNames = Set(customSounds.map { $0.name.lowercased() })
        let dedupedImported = importedNames.filter {
            !customDisplayNames.contains(displayName(for: $0).lowercased())
        }

        return (bundleNames + dedupedImported + customNames)
            .filter { !displayName(for: $0).trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted()
    }

    /// Import a .hwsound file from the given URL into Documents/Sleep Sounds/.
    /// Returns the display name of the imported sound on success.
    @discardableResult
    static func importSound(from url: URL) throws -> String {
        let dir = importedSoundsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Strip the .hwsound extension; the file is stored as .m4a
        let baseName = url.deletingPathExtension().lastPathComponent
        let dest = dir.appendingPathComponent("\(baseName).m4a")

        // Access security-scoped resource if needed (Files app share)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return baseName
    }

    /// Resolves the URL for a sound file, checking custom sounds, Documents, then the bundle.
    ///
    /// `name` can arrive straight off the wire — `sleep_sound_start` takes a
    /// `sound` field and passes whatever string it finds through to here, where
    /// ".m4a" is appended and the result treated as a path. A name containing a
    /// separator or a parent reference therefore builds a path somewhere other
    /// than the sounds folder. Nothing outside the app sandbox is reachable, but
    /// "play whichever file this string points at" is not a contract worth
    /// offering to the network, so anything that is not a single safe path
    /// component is refused here. Every legitimate sound name — bundled,
    /// imported, or a `custom_<uuid>` id — passes unchanged.
    private static func soundURL(for name: String) -> URL? {
        guard MQTTStrings.isSafeFileComponent(name) else {
            print("⚠️ Sleep sound name is not a usable file name — refusing to resolve it")
            return nil
        }
        // Custom sleep sounds (prefixed with custom_)
        if name.hasPrefix("custom_") {
            return CustomSoundManager.shared.fileURL(forID: name)
        }
        let imported = importedSoundsDirectory.appendingPathComponent("\(name).m4a")
        if FileManager.default.fileExists(atPath: imported.path) {
            return imported
        }
        return Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "Sleep Sounds")
            ?? Bundle.main.url(forResource: name, withExtension: "m4a")
    }

    /// Converts a raw filename (e.g. "Brown_Noise") to a display name ("Brown Noise").
    /// For custom sounds, returns the user-set name from CustomSoundManager.
    static func displayName(for soundName: String) -> String {
        if soundName.hasPrefix("custom_"),
           let custom = CustomSoundManager.shared.sound(byID: soundName) {
            return custom.name
        }
        return soundName.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - Playback Control

    /// Convert a wall-clock `Date` to an `AVAudioTime` (host-time based) suitable for
    /// passing to `AVAudioPlayerNode.play(at:)`. Returns nil if `date` is more than
    /// 0.5 seconds in the past (caller should fall back to immediate playback) or
    /// more than one hour in the future (sanity guard).
    private static func avAudioHostTime(for date: Date) -> AVAudioTime? {
        let delay = date.timeIntervalSinceNow
        guard delay > -0.5 else { return nil }
        guard delay < 3_600 else { return nil }

        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        // mach_absolute_time ticks × (numer/denom) = nanoseconds
        // → mach ticks = nanoseconds × (denom/numer)
        let delayNanos = max(delay, 0) * 1_000_000_000.0
        let ratio = Double(info.denom) / Double(info.numer)
        let delayMach = UInt64(delayNanos * ratio)
        return AVAudioTime(hostTime: mach_absolute_time() + delayMach)
    }

    /// Start playing a sleep sound.
    ///
    /// - Parameters:
    ///   - scheduledStart: Optional wall-clock `Date` at which playback should begin.
    ///     Uses `AVAudioPlayerNode.play(at:)` (host-time scheduled) for sample-accurate
    ///     synchronisation across devices that share an NTP-synced clock.
    ///     Pass `nil` (default) to start immediately.
    func start(soundName: String, volume: Double, mode: SleepSoundMode, fadeOutDuration: TimeInterval, scheduledStart: Date? = nil) {
        // One Now Playing owner at a time — starting sleep sounds ends any
        // radio listening session (mirror of RadioPlayerManager.play()).
        RadioPlayerManager.shared.stop()

        // deactivateSession: false — start() may be REPLACING an already-playing
        // sound (Siri: "play Fan" while Rain plays runs the full start path, not
        // changeSound). Deactivating here opens a no-active-session window while
        // the new buffer loads; if the app is backgrounded (intent invoked from
        // the Shortcuts app), iOS suspends us the moment the intent returns and
        // the new engine never starts — old sound stops, new one never plays.
        internalStop(restartKeepAlive: false, deactivateSession: false)

        guard let url = Self.soundURL(for: soundName) else {
            print("❌ SleepSoundManager: '\(soundName).m4a' not found in bundle")
            restartKeepAliveIfNeeded()
            return
        }

        // Safety net alongside the retained session: guaranteed background
        // execution across the buffer-load handoff (same pattern as
        // BackgroundAudioKeepAlive.startAsync).
        let bgTask = UIApplication.shared.beginBackgroundTask {
            AppLogger.shared.log("SleepSoundManager: start() background task expired", category: .audio)
        }

        // Stop the keep-alive PLAYER before configuring the new audio session,
        // but keep the session active (deactivateSession: false). This avoids two problems:
        //
        // 1. Category conflict: BackgroundAudioKeepAlive uses `.playback + .mixWithOthers`.
        //    If both player and engine coexist while we switch to `.playback` (no mix),
        //    the keep-alive player is interrupted mid-setup, leaving the first engine silent.
        //
        // 2. Background suspension: Calling stop() with deactivateSession: true tells iOS
        //    the app is no longer an audio app. In the background iOS can then suspend us
        //    before the detached task below finishes starting the new engine. Retaining
        //    the active session keeps the app in background audio execution.
        BackgroundAudioKeepAlive.shared.stop(deactivateSession: false)

        // Stamp generation BEFORE the async task so that if changeSound() or
        // another start() fires while this 1GB+ buffer is still loading, the
        // stale task discards itself instead of overwriting the new engine.
        soundChangeGeneration += 1
        let myGeneration = soundChangeGeneration

        // Capture scheduledStart for the detached task (Date is Sendable).
        let capturedScheduledStart = scheduledStart

        // Load buffer and set up engine off the main thread to avoid blocking gestures.
        // All @Observable state mutations happen back on MainActor when ready.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try await MainActor.run { try AppAudioSession.setCategory(.playback, mode: .default) }
                // Larger buffer gives the render thread headroom against UI animation
                // CPU spikes (e.g. sheet/dialog presentations). 50ms is imperceptible
                // for ambient sleep sounds but prevents dropouts.
                try session.setPreferredIOBufferDuration(0.05)
                try await AppAudioSession.setActive(true)

                let buffer = try Self.loadLoopBuffer(from: url)

                let newEngine = AVAudioEngine()
                let node = AVAudioPlayerNode()
                newEngine.attach(node)
                newEngine.connect(node, to: newEngine.mainMixerNode, format: buffer.format)
                newEngine.mainMixerNode.outputVolume = Float(volume)
                try newEngine.start()

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // If changeSound() or a second start() fired while we were loading
                    // (e.g. a 1GB file taking 2+ minutes), discard this stale result.
                    guard self.soundChangeGeneration == myGeneration else {
                        print("⚠️ SleepSoundManager: start() stale load discarded (gen \(myGeneration) != \(self.soundChangeGeneration))")
                        newEngine.stop()
                        return
                    }
                    self.loopBuffer = buffer
                    // .loops repeats the buffer at the render-thread level — zero gap at the loop point
                    node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)

                    // Scheduled-sync start: compute host time from the target wall-clock date
                    // and pass it to play(at:). The engine is already running; the node holds
                    // silent until the host clock reaches the scheduled time, giving
                    // sample-accurate synchronisation across NTP-synced devices.
                    if let target = capturedScheduledStart,
                       let avTime = Self.avAudioHostTime(for: target) {
                        let lag = target.timeIntervalSinceNow
                        AppLogger.shared.log("SleepSoundManager: scheduled start in \(String(format: "%.3f", lag))s", category: .audio)
                        node.play(at: avTime)
                    } else {
                        if let target = capturedScheduledStart {
                            // avAudioHostTime returned nil — target was in the past
                            AppLogger.shared.log("SleepSoundManager: sync target missed by \(String(format: "%.3f", -target.timeIntervalSinceNow))s — starting immediately", category: .audio)
                        }
                        node.play()
                    }

                    self.engine = newEngine
                    self.playerNode = node
                    self.selectedSoundName = soundName
                    self.volume = volume
                    self.fadeOutDuration = fadeOutDuration
                    self.state = .playing
                    self.playbackStartTime = Date()
                    self.idleTimer?.invalidate()
                    self.idleTimer = nil
                    HAIntegrationRouter.shared.publishSleepSoundVolume(volume, settings: DeviceSettings.shared)
                    HAIntegrationRouter.shared.publishSleepSoundName(soundName, settings: DeviceSettings.shared)
                    self.setRemoteCommandsEnabled(true)
                    self.updateNowPlayingInfo()

                    switch mode {
                    case .duration(let seconds):
                        let end = Date().addingTimeInterval(seconds)
                        self.endTime = end
                        self.scheduleEnd(at: end, fadeOut: fadeOutDuration)
                    case .until(let date):
                        self.endTime = date
                        self.scheduleEnd(at: date, fadeOut: fadeOutDuration)
                    case .indefinite:
                        self.endTime = nil
                    }

                    // Session is genuinely playing at this point (a failed load
                    // never reaches here). 0 = indefinite.
                    let timerMinutes = self.endTime.map { max(0, Int($0.timeIntervalSinceNow / 60)) } ?? 0
                    Analytics.shared.log(.sleepSessionStarted(source: .sound, timerMinutes: timerMinutes))

                    // Keep-alive was already stopped synchronously before the detached
                    // task started (see the comment at the top of start()).
                    print("✅ SleepSoundManager: started '\(soundName)' (seamless loop)")
                }
            } catch {
                print("❌ SleepSoundManager: failed to start — \(error)")
                // Load or engine-start failed. Restore the keep-alive so the app
                // doesn't go to background without any audio coverage.
                await MainActor.run { [weak self] in self?.restartKeepAliveIfNeeded() }
            }
            await MainActor.run { UIApplication.shared.endBackgroundTask(bgTask) }
        }
    }

    func pause() {
        guard state == .playing else { return }
        // Mute the engine rather than truly stopping it. The engine keeps running
        // silently, which (a) keeps the AVAudioSession active so the app survives
        // in the background without BackgroundAudioKeepAlive, and (b) keeps HaWake
        // as the primary audio app so the Now Playing lock screen widget stays visible.
        engine?.mainMixerNode.outputVolume = 0
        state = .paused
        updateNowPlayingInfo()
        startIdleTimer()
        print("⏸ SleepSoundManager: paused (muted) by user")
        AppLogger.shared.log("SleepSoundManager: paused (muted) by user — engine retained as keep-alive", category: .audio)
    }

    func resume() {
        guard state == .paused else { return }

        // If the session end time already passed while we were paused, stop cleanly
        if let endTime, endTime <= Date() {
            internalStop(restartKeepAlive: true)
            print("⏹ SleepSoundManager: end time elapsed while paused — stopping on resume")
            return
        }

        // The engine was kept running at volume 0 during pause. If an external
        // interruption (phone call, alarm) stopped it fully, restart it and
        // reschedule the loop buffer before restoring volume.
        if !(engine?.isRunning ?? false) {
            do {
                try AppAudioSession.setCategory(.playback, mode: .default)
                try AppAudioSession.setActive(true)
                try engine?.start()
            } catch {
                print("❌ SleepSoundManager: session reactivation failed — \(error)")
            }
            if let buffer = loopBuffer {
                playerNode?.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                playerNode?.play()
                print("🔁 SleepSoundManager: rescheduled loop buffer after engine stop")
            }
        }

        engine?.mainMixerNode.outputVolume = Float(volume)
        state = .playing
        idleTimer?.invalidate()
        idleTimer = nil
        setRemoteCommandsEnabled(true)
        updateNowPlayingInfo()

        // Reschedule the end timer from the current time, since the timer fired (and was
        // suppressed) while paused — we need to re-arm it for the remaining duration.
        if let endTime {
            let fadeOut = fadeOutDuration
            scheduleEnd(at: endTime, fadeOut: fadeOut)
        }

        print("▶️ SleepSoundManager: resumed")
        AppLogger.shared.log("SleepSoundManager: resumed by user (engineRunning=\(engine?.isRunning ?? false))", category: .audio)
    }

    func stop() {
        internalStop(restartKeepAlive: true)
        print("⏹ SleepSoundManager: stopped by user")
        AppLogger.shared.log("SleepSoundManager: stopped by user", category: .audio)
    }

    func setVolume(_ newVolume: Double) {
        let v = max(0.0, min(1.0, newVolume))
        volume = v
        engine?.mainMixerNode.outputVolume = Float(v)
        let settings = DeviceSettings.shared
        HAIntegrationRouter.shared.publishSleepSoundVolume(v, settings: settings)
    }

    /// Swaps to a different sound. Always resumes playback with the new sound.
    /// Reuses the existing AVAudioEngine to avoid audio-session teardown/restart
    /// races that caused the first switch to silently fail.
    func changeSound(to soundName: String) {
        guard state != .stopped else { return }
        // Stop keep-alive and idle timer synchronously before any async work.
        BackgroundAudioKeepAlive.shared.stop()
        idleTimer?.invalidate()
        idleTimer = nil

        guard let url = Self.soundURL(for: soundName) else {
            print("❌ SleepSoundManager: '\(soundName).m4a' not found for sound change")
            return
        }

        // Update name immediately so the UI reflects the selection right away.
        selectedSoundName = soundName

        let currentVolume = volume
        let currentEndTime = endTime

        // Stamp the generation BEFORE any async work so in-flight loads discard.
        soundChangeGeneration += 1
        let myGeneration = soundChangeGeneration
        let wasPlaying = (state == .playing)

        let engineRunning = engine?.isRunning ?? false
        let nodeExists = playerNode != nil
        print("🔀 changeSound gen=\(myGeneration) to='\(soundName)' wasPlaying=\(wasPlaying) engineRunning=\(engineRunning) nodeExists=\(nodeExists)")

        // Ramp the mixer to silence over ~78ms before stopping the node.
        // playerNode.stop() is an immediate hard cut — if the waveform is non-zero
        // at that sample, it creates an audible click (especially on the first
        // switch when the audio hardware is freshly initialised). Ramping to 0
        // first means stop() is silent. 6 steps × 13ms = 78ms total.
        // node.stop() is deferred to the MainActor.run block after the ramp + load,
        // so stop() and scheduleBuffer() still execute on the same (main) actor.
        if wasPlaying, let mixer = engine?.mainMixerNode {
            let startVol = mixer.outputVolume
            let rampGen = myGeneration
            for i in 1...6 {
                // [weak self] + generation check: if stop() fires during the ramp,
                // internalStop increments the generation and engine becomes nil.
                // Capturing mixer strongly instead would keep an orphaned node alive
                // past the engine's lifetime and crash on outputVolume access.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.013 * Double(i)) { [weak self] in
                    guard let self, self.soundChangeGeneration == rampGen else { return }
                    self.engine?.mainMixerNode.outputVolume = startVol * (1.0 - Float(i) / 6.0)
                }
            }
        }

        // If the engine was paused (user manually paused before switching), restart
        // it here on the main thread. Resuming a paused engine is fast — it just
        // unblocks the existing I/O unit without hardware re-initialization.
        if let eng = engine, !eng.isRunning {
            print("🔀 changeSound gen=\(myGeneration): engine paused — restarting before load")
            do {
                try AppAudioSession.setCategory(.playback, mode: .default)
                try AppAudioSession.setActive(true)
                try eng.start()
            } catch {
                print("❌ SleepSoundManager: failed to resume engine for sound change — \(error)")
                return
            }
        }

        // Capture the EXISTING engine and node — we reuse them to avoid
        // audio-session teardown/restart races.
        let capturedEngine = engine
        let capturedNode = playerNode

        print("🔀 changeSound gen=\(myGeneration): captured engine=\(capturedEngine != nil) node=\(capturedNode != nil) — starting load")

        // Background task only loads the buffer from disk (the only slow part).
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                guard let eng = capturedEngine, let node = capturedNode else {
                    print("⚠️ changeSound gen=\(myGeneration): captured engine/node was nil — aborting load")
                    return
                }

                let buffer = try Self.loadLoopBuffer(from: url)
                print("🔀 changeSound gen=\(myGeneration): buffer loaded (\(buffer.frameLength) frames)")

                // Safety margin: ensure the 78ms ramp has fully completed even if
                // the file was in the OS cache and loaded faster than 78ms.
                if wasPlaying {
                    try? await Task.sleep(nanoseconds: 85_000_000)
                }

                await MainActor.run { [weak self] in
                    guard let self else {
                        print("⚠️ changeSound gen=\(myGeneration): self deallocated before MainActor.run")
                        return
                    }
                    let currentGen = self.soundChangeGeneration
                    let currentState = self.state
                    print("🔀 changeSound gen=\(myGeneration): MainActor.run — currentGen=\(currentGen) state=\(currentState) engineRunning=\(self.engine?.isRunning ?? false) nodeIsPlaying=\(node.isPlaying)")
                    // Abort if stop() fired or another changeSound overtook this load.
                    guard currentState != .stopped,
                          currentGen == myGeneration else {
                        print("⚠️ changeSound gen=\(myGeneration): stale — discarding (state=\(currentState) currentGen=\(currentGen))")
                        return
                    }
                    node.stop()                                            // silent — mixer is at 0

                    // Reconnect the node with the new buffer's format before scheduling.
                    // Sleep sound files have mixed formats (44.1kHz vs 48kHz, stereo vs mono —
                    // e.g. Sea_Waves is mono at 48kHz while others are stereo). AVAudioPlayerNode
                    // requires every scheduled buffer to match the node's connected output format.
                    // Calling scheduleBuffer with a mismatched format throws an NSException that
                    // Swift cannot catch, crashing the app. Reconnecting first fixes this.
                    // ONLY reconnect on an actual format change — every disconnect fires an
                    // AVAudioEngineConfigurationChange, and needless graph churn during rapid
                    // switching multiplies the notifications for no benefit.
                    // Set isInterrupted so the (main-hopped) config-change handler stands down
                    // until the eng.start() below has run.
                    if node.outputFormat(forBus: 0) != buffer.format {
                        self.isInterrupted = true
                        eng.disconnectNodeOutput(node)
                        eng.connect(node, to: eng.mainMixerNode, format: buffer.format)
                        self.isInterrupted = false
                    }

                    // Reconnecting may have stopped the engine (config change), and an audio
                    // interruption during the async buffer load can also stop it.
                    if !eng.isRunning {
                        do {
                            try AppAudioSession.setActive(true)
                            try eng.start()
                            print("🔀 changeSound gen=\(myGeneration): restarted engine after reconnect/interruption")
                        } catch {
                            print("❌ changeSound gen=\(myGeneration): engine restart failed — \(error)")
                            return
                        }
                    }

                    self.loopBuffer = buffer
                    eng.mainMixerNode.outputVolume = Float(currentVolume) // restore user volume
                    node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                    node.play()
                    self.state = .playing
                    print("✅ changeSound gen=\(myGeneration): node.play() called — engine running=\(eng.isRunning)")
                    self.selectedSoundName = soundName
                    self.endTime = currentEndTime
                    HAIntegrationRouter.shared.publishSleepSoundName(soundName, settings: DeviceSettings.shared)
                    self.updateNowPlayingInfo()
                    print("🔄 SleepSoundManager: changed sound to '\(soundName)'")
                }
            } catch {
                print("❌ SleepSoundManager: failed to change sound — \(error)")
            }
        }
    }

    /// Re-takes the shared audio session after another in-app audio user
    /// (e.g. SoundManagerView's preview player) is done with it. Our own
    /// setActive/category calls never post interruption notifications, so
    /// without this explicit handback the engine sits in .playing state over
    /// a dead session — silent, with no self-recovery path.
    func reassertSessionOwnership() {
        guard isActive else { return }
        do {
            try AppAudioSession.setCategory(.playback, mode: .default)
            try AppAudioSession.setActive(true)
        } catch {
            print("❌ SleepSoundManager: session reassert failed — \(error)")
        }
        if let eng = engine, !eng.isRunning {
            do {
                try eng.start()
                if let node = playerNode, !node.isPlaying {
                    if let buffer = loopBuffer {
                        node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                    }
                    node.play()
                }
                // Paused sessions keep the engine running muted by design.
                eng.mainMixerNode.outputVolume = state == .paused ? 0 : Float(volume)
                print("🔄 SleepSoundManager: engine restarted after session reassert")
            } catch {
                print("❌ SleepSoundManager: engine restart after reassert failed — \(error)")
            }
        }
        setRemoteCommandsEnabled(true)
        updateNowPlayingInfo()
    }

    // MARK: - Alarm Coordination

    /// Called by AlarmSoundPlayer before alarm audio starts.
    /// Pauses sleep sounds so the alarm session can take over.
    func handleAlarmWillFire() {
        guard state == .playing else { return }
        pausedByAlarm = true
        playerNode?.pause()
        engine?.pause()
        state = .paused
        // Clear Now Playing info and disable remote commands so the lock-screen
        // media widget doesn't appear (empty) over the alarm UI. Since al-ecf
        // the ring never resumes the sound: `handleAlarmEnded()` calls
        // `internalStop()` for every outcome, which leaves both cleared.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        setRemoteCommandsEnabled(false)
        restartKeepAliveIfNeeded()
        startIdleTimer()
        print("⏸ SleepSoundManager: paused — alarm fired")
    }

    /// Whether the current pause was caused by an alarm rather than by the user.
    /// Exposed so the (pure) `SleepSoundAlarmResolution` can decide without
    /// reaching into the engine.
    var isPausedByAlarm: Bool { pausedByAlarm }

    /// Applies what a finished ring owes the sleep sound it interrupted.
    ///
    /// **Since al-ecf (2026-08-06): an alarm always stops the sleep sound**, and
    /// it stays stopped whether the ring was snoozed or dismissed and whatever is
    /// queued. There is no auto-resume — the user restarts it manually. This
    /// supersedes al-3jm, where a snooze resumed the sound for the snooze
    /// interval. A pause the *user* asked for is still never touched.
    ///
    /// - Parameters:
    ///   - outcome: how the ring ended. No longer changes the result (al-ecf).
    ///   - hasQueuedAlarms: whether another alarm is stacked behind this one.
    ///     No longer changes the result (al-ecf).
    func handleAlarmEnded(_ outcome: SleepSoundAlarmResolution.RingOutcome, hasQueuedAlarms: Bool) {
        let action = SleepSoundAlarmResolution.resolve(
            outcome: outcome,
            pausedByAlarm: pausedByAlarm,
            hasQueuedAlarms: hasQueuedAlarms
        )
        switch action {
        case .none:
            break
        case .stop:
            // An alarm fired, so the sleep sound ends — no resume in any outcome
            // (al-ecf). End the session properly rather than leaving a muted
            // engine paused forever with a half-configured Now Playing widget.
            // `internalStop` clears `pausedByAlarm`, tears the engine down,
            // clears Now Playing / remote commands and hands the audio session
            // back (or to the keep-alive player).
            AppLogger.shared.log("Sleep sounds: stopping after alarm — no resume (al-ecf)", category: .audio)
            internalStop(restartKeepAlive: true)
        }
    }

    // MARK: - Private Helpers

    /// - Parameter deactivateSession: pass `false` when the caller immediately
    ///   reuses the audio session (start() replacing the current sound). The
    ///   session staying active is what keeps the app alive in the background
    ///   through the async engine handoff.
    private func internalStop(restartKeepAlive: Bool, deactivateSession: Bool = true) {
        soundChangeGeneration += 1   // invalidates any in-flight load tasks
        fadeTimer?.invalidate()
        endTimer?.invalidate()
        idleTimer?.invalidate()
        fadeTimer = nil
        endTimer = nil
        idleTimer = nil

        // Clear alarm-pause flag — if stop() is called the user ended sleep sounds
        // manually, so there's nothing to resume after the alarm.
        pausedByAlarm = false

        // Track whether the engine was actually running before we tear it down.
        // We must only deactivate the shared audio session when we were genuinely
        // playing — calling setActive(false) when the engine is nil (i.e. sleep
        // sounds were never started) kills the BackgroundAudioKeepAlive player.
        let wasRunning = engine != nil

        // Report the finished session before the start stamp is cleared below.
        // Covers every end path: user stop, timer/fade expiry, idle auto-stop.
        if let started = playbackStartTime {
            let actualMinutes = max(0, Int(Date().timeIntervalSince(started) / 60))
            Task { @MainActor in
                Analytics.shared.log(.sleepSessionEnded(source: .sound, actualMinutes: actualMinutes))
            }
        }

        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
        loopBuffer = nil

        state = .stopped
        selectedSoundName = ""
        endTime = nil
        fadeOutDuration = 0
        playbackStartTime = nil
        HAIntegrationRouter.shared.publishSleepSoundName("none", settings: DeviceSettings.shared)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        setRemoteCommandsEnabled(false)

        // Only the keep-alive loop will actually take over if (a) the caller
        // asked for it AND (b) App Persistence is enabled. When neither holds,
        // we need to revert the category and deactivate ourselves — otherwise
        // the session is left on .playback indefinitely after sleep sounds end.
        let willHandOffToKeepAlive = restartKeepAlive && DeviceSettings.shared.keepAliveNeeded

        if wasRunning && !willHandOffToKeepAlive && deactivateSession {
            // Only deactivate the shared audio session when we are NOT immediately
            // restarting BackgroundAudioKeepAlive. If we called setActive(false) first
            // and then dispatched a Task to restart the keep-alive, there would be a
            // brief window with no active audio session — iOS can suspend the app
            // during that gap, preventing the keep-alive from ever restarting.
            // (AlarmSound.swift uses the same pattern for the same reason.)
            // When we ARE restarting keep-alive, its startAsync() calls setActive(true)
            // with .mixWithOthers, which effectively takes over the session cleanly.
            // Deactivate FIRST, and in its own do/catch. Both calls used to sit
            // in one `do` with the category first — so when `setCategory(.ambient)`
            // threw (it can, on a session that is still active), `setActive(false)`
            // was skipped entirely and the session stayed live after the sleep
            // sound ended. Only a `print` recorded it, so it never reached the
            // audio log.
            do {
                try AppAudioSession.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                AppLogger.shared.log("SleepSoundManager: setActive(false) FAILED — \(error)", category: .audio)
            }
            do {
                // Revert category so the app isn't left advertising itself as a
                // background-audio app after playback ends.
                try AppAudioSession.setCategory(.ambient)
            } catch {
                AppLogger.shared.log("SleepSoundManager: setCategory(.ambient) FAILED — \(error)", category: .audio)
            }
        }

        if restartKeepAlive {
            restartKeepAliveIfNeeded()
        }
    }

    private func restartKeepAliveIfNeeded() {
        guard DeviceSettings.shared.keepAliveNeeded else { return }
        Task.detached(priority: .utility) {
            await BackgroundAudioKeepAlive.shared.startAsync()
        }
    }

    private func scheduleEnd(at date: Date, fadeOut: TimeInterval) {
        endTimer?.invalidate()
        // Begin fade-out `fadeOut` seconds before the end date (or at the end if no fade)
        let triggerDate = fadeOut > 0 ? date.addingTimeInterval(-fadeOut) : date
        let delay = max(0, triggerDate.timeIntervalSinceNow)
        endTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            // If paused (e.g. an alarm interrupted us), don't act — resume() will handle it
            guard case .playing = self.state else { return }
            if fadeOut > 0 {
                self.startFadeOut(duration: fadeOut)
            } else {
                self.stop()
            }
        }
    }

    private func startFadeOut(duration: TimeInterval) {
        guard let mixer = engine?.mainMixerNode else { stop(); return }
        let startVolume = mixer.outputVolume
        let steps = 20
        let interval = duration / Double(steps)
        let stepSize = startVolume / Float(steps)
        var step = 0

        fadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self, let m = self.engine?.mainMixerNode else { timer.invalidate(); return }
            step += 1
            let newVol = startVolume - stepSize * Float(step)
            if newVol <= 0 || step >= steps {
                timer.invalidate()
                self.stop()
            } else {
                m.outputVolume = newVol
            }
        }
    }

    // MARK: - Now Playing / Remote Controls

    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor [weak self] in
                if self?.state == .paused { self?.resume() }
            }
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor [weak self] in
                if self?.state == .playing { self?.pause() }
            }
            return .success
        }

        center.stopCommand.isEnabled = false

        // MPRemoteCommandCenter defaults EVERY command to enabled, and nothing
        // in the app ever touched these two — so the Dynamic Island and lock
        // screen showed skip-forward/back buttons that did nothing at all
        // (confirmed in an audio diagnostics dump: next/prev enabled while
        // play/pause/toggle/stop were false). Neither a sleep sound nor a live
        // radio stream has tracks to skip, so turn them off explicitly.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch self.state {
                case .playing: self.pause()
                case .paused:  self.resume()
                case .stopped: break
                }
            }
            return .success
        }
    }

    /// Enables/disables the MPRemoteCommandCenter commands used by sleep
    /// sounds. Disabling them hides the system Now Playing widget (the empty
    /// lock-screen media player that otherwise appears any time a `.playback`
    /// audio session is active + commands are registered).
    private func setRemoteCommandsEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = enabled
        center.pauseCommand.isEnabled = enabled
        center.togglePlayPauseCommand.isEnabled = enabled
    }

    private func updateNowPlayingInfo() {
        guard state != .stopped, !selectedSoundName.isEmpty else { return }

        let elapsed = playbackStartTime.map { Date().timeIntervalSince($0) } ?? 0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: Self.displayName(for: selectedSoundName),
            MPMediaItemPropertyArtist: "Allarise",
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
        ]

        if let endTime {
            // Timed session: show a real progress bar with the full session duration.
            let total = endTime.timeIntervalSince(playbackStartTime ?? Date())
            info[MPMediaItemPropertyPlaybackDuration] = max(0, total)
        } else {
            // Indefinite loop: use a large duration so the lock screen shows an
            // elapsed-time counter that advances naturally with playbackRate = 1.0.
            info[MPMediaItemPropertyPlaybackDuration] = 8 * 3600.0  // 8 hours
        }

        if let artwork = NowPlayingArtwork.appIcon() {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        // Auto-stop after 30 minutes of being paused
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: false) { [weak self] _ in
            self?.internalStop(restartKeepAlive: true)
            print("⏹ SleepSoundManager: auto-stopped after 30 min idle")
        }
    }
}


