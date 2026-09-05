//
//  StreamAudioLevelMonitor.swift
//  HaWake Alarm V2
//
//  Dead-air defence for RadioAlarmStreamer. A stream can be technically
//  playable — its playback clock advances past 0.5s — while rendering pure
//  silence (an icecast station broadcasting dead air). The clock-only
//  confirmation in RadioAlarmStreamer would mute the ringing wav for such a
//  stream and leave the alarm ringing nothing. This file has two pieces:
//
//  - DeadAirPolicy: pure decision logic (no AVFoundation), so both the
//    confirmation gate and the post-confirmation watchdog verdict are unit
//    testable without an AVPlayer.
//  - StreamAudioLevelMonitor: a SIDE-CHANNEL meter. It opens its OWN
//    URLSession stream of the same URL, decodes the arriving bytes in chunks,
//    and reports whether audible samples are present.
//
//  Why a side channel and not an MTAudioProcessingTap. The tap was measured
//  INERT for live icecast streams on both macOS and the iOS simulator: the tap
//  is created and the audioMix installs, but the prepare/process callbacks
//  never fire for an AVPlayerItem backed by a live icecast URL, so it can never
//  report a level. The meter therefore streams the URL a second time itself and
//  decodes the bytes directly (ADTS/MP3 chunk decoding survives an arbitrary
//  byte boundary), which is what actually works. It runs independently of the
//  AVPlayer, so a muted (volume 0) prewarm still meters real levels.
//
//  Cost envelope. The meter streams the station over the network for as long as
//  it is attached, so it runs ONLY while an alarm-radio attempt / prewarm / ring
//  or a picker preview is live — the call sites bound its lifetime, and it caps
//  itself at 10 minutes defensively. At 128–320 kbps that is a few hundred KB
//  per minute; nothing runs when no alarm-radio activity is in flight.
//
//  The whole thing is FAIL-SOFT: if nothing ever decodes (a playlist / HLS /
//  OGG / ICY-metadata shape the AAC/MP3 chunk decoder can't open, a non-2xx
//  response, a dropped connection), `isMonitoring` stays false and every caller
//  treats audibility as UNKNOWN — behaviour identical to the clock-only world
//  before this file existed. It can only ever ADD a dead-air failover, never
//  remove tone.
//
//  Content gate. Amplitude alone cannot tell music/speech from loud static: a
//  station broadcasting noise peaks well above `audibleThreshold` yet carries
//  nothing to wake up to. So each AUDIBLE chunk is also run through Apple's
//  on-device SoundAnalysis classifier (SNClassifySoundRequest .version1), fed
//  from the SAME decoded PCM the meter already reads. Measured: synthetic
//  white/pink noise never exceeds ~0.30 confidence in any class, while real
//  speech/music reach ~0.75+ — so a class other than `silence` at ≥ 0.6
//  confidence (DeadAirPolicy.contentConfidenceThreshold) counts as content.
//  This gates ONLY the confirmation step, never mid-ring failover, and is
//  itself FAIL-SOFT: if the classifier can't be built or never produces a
//  result the gate stays inactive and mayConfirm reduces to amplitude-only.
//

import Foundation
import AVFoundation
import SoundAnalysis
import os

/// Decides when a stream's rendered audio counts as dead air. Pure logic so it
/// is testable without an AVPlayer; StreamAudioLevelMonitor supplies the inputs.
struct DeadAirPolicy {
    /// Linear sample peak above this counts as audible (~ -48 dBFS). Measured
    /// dead air peaks at -61 dBFS; real broadcast material peaks far above.
    static let audibleThreshold: Float = 0.004
    /// How long a CONFIRMED stream may render silence (while its clock advances)
    /// before it is declared dead air. Generous: talk-radio pauses are seconds.
    static let silenceWindow: TimeInterval = 12
    /// A SoundAnalysis classification at or above this confidence, for any class
    /// other than `silence`, counts as recognizable content. Measured on this
    /// machine: synthetic white/pink noise never exceeds ~0.30 confidence in any
    /// class, while real speech/music reach ~0.75+ within seconds — so 0.6 sits
    /// well clear of noise and comfortably below real material.
    static let contentConfidenceThreshold: Double = 0.6

    /// Confirmation gate: may the streamer mute the wav?
    /// Fail-soft in two layers. When the tap is not monitoring, audibility is
    /// unknown — allow (today's clock-only behavior). When monitoring but silent,
    /// block (dead air). When monitoring and audible, apply the content gate ONLY
    /// if the classifier actually produced a result (`contentGateActive`); if the
    /// classifier was unavailable the decision stays amplitude-only, exactly
    /// today's behavior.
    static func mayConfirm(isMonitoring: Bool, hasHeardAudio: Bool, contentGateActive: Bool, hasHeardContent: Bool) -> Bool {
        guard isMonitoring else { return true }        // fail-soft: audibility unknown
        guard hasHeardAudio else { return false }      // dead air
        return contentGateActive ? hasHeardContent : true
    }

    /// Post-confirmation dead-air verdict for one watchdog tick. Only ever true
    /// when the tap is monitoring AND playback progressed this tick (a paused/
    /// stalled player is the stall watchdog's job, not ours — an interruption
    /// pause must NOT accumulate toward dead air) AND no audible buffer has
    /// arrived within `silenceWindow` of `now` (using `monitoringSince` as the
    /// baseline when nothing was ever audible).
    ///
    /// UNCHANGED by the content gate on purpose: the classifier gates only the
    /// pre-confirmation mute decision. Once a stream is confirmed, only amplitude
    /// governs failover — a noise-classified but audible stream that was allowed
    /// to confirm (fail-soft) must not be torn down mid-ring by content scoring.
    static func isDeadAir(isMonitoring: Bool, clockAdvanced: Bool, lastAudibleAt: Date?, monitoringSince: Date?, now: Date) -> Bool {
        guard isMonitoring, clockAdvanced else { return false }
        guard let baseline = lastAudibleAt ?? monitoringSince else { return false }
        return now.timeIntervalSince(baseline) > silenceWindow
    }
}

/// Meters a radio station's genuinely-decodable audio level by streaming the
/// station's URL over its OWN URLSession and decoding the bytes in chunks —
/// independent of the AVPlayer that RadioAlarmStreamer plays. See the file
/// header for why the previous MTAudioProcessingTap approach was replaced (the
/// tap's callbacks never fire for live icecast items).
///
/// FAIL-SOFT: if nothing ever decodes (unsupported stream shape, a non-2xx
/// response, a dropped connection), `isMonitoring` stays false and callers
/// treat audibility as unknown — behavior identical to before this class
/// existed. It can only ever ADD a dead-air failover, never remove tone.
///
/// Thread-safety. The URLSession delivers on a serial delegate queue, where the
/// chunk write + decode runs (a background queue — the main thread is never
/// blocked). The published fields are guarded by an os_unfair_lock behind a
/// stable heap pointer, so the getters are safe to read from any thread while
/// the delegate queue writes.
final class StreamAudioLevelMonitor: NSObject, URLSessionDataDelegate {
    // MARK: Tunables

    /// Bytes to accumulate before a chunk is handed to the decoder. Big enough
    /// that an AAC/MP3 chunk cut at an arbitrary byte boundary still contains
    /// whole frames to decode; small enough to get a verdict within a second or
    /// two at broadcast bitrates.
    private static let chunkBytes = 48 * 1024
    /// Consecutive undecodable chunks that end monitoring (playlist/HLS/OGG/ICY
    /// path — a shape the AAC/MP3 chunk decoder cannot open).
    private static let maxStrikes = 3
    /// Frames read per PCM block while metering a decoded chunk.
    private static let readFrames: AVAudioFrameCount = 32_768
    /// Defensive lifetime cap. A ring never legitimately lasts this long; the
    /// cap stops a leaked meter from streaming forever. Hitting it just stops
    /// metering — state freezes as-is, it is NOT a failure signal.
    private static let maxLifetime: TimeInterval = 600

    // MARK: Published state (guarded by `lockPtr`)

    /// The lock lives behind a stable heap pointer so its address never moves
    /// under the delegate queue.
    private let lockPtr = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var didDecode = false
    private var hasHeard = false
    private var lastAudible: Date?
    private var monitoringStart: Date?
    /// The classifier has produced at least one result (of any confidence) for
    /// this attempt. Stays false when classification never ran → fail-soft.
    private var contentGateActive = false
    /// Some classification result named a class other than `silence` at
    /// confidence ≥ DeadAirPolicy.contentConfidenceThreshold. Sticky once true.
    private var heardContent = false

    // MARK: Delegate-queue-only state

    /// Accumulates bytes until a chunk is ready. Touched only on the serial
    /// delegate queue.
    private var buffer = Data()
    /// The first file extension that opened successfully; later chunks try only
    /// this one. Delegate-queue-only.
    private var decodedExtension: String?
    /// Consecutive undecodable-chunk count. Delegate-queue-only.
    private var strikes = 0
    private var startedAt: Date?

    // MARK: Session

    private var session: URLSession?
    private var task: URLSessionDataTask?
    /// Set on detach / self-stop so a late delegate callback does no work.
    private var stopped = false

    override init() {
        lockPtr.initialize(to: os_unfair_lock())
        super.init()
    }

    deinit {
        detach()
        lockPtr.deinitialize(count: 1)
        lockPtr.deallocate()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lockPtr); defer { os_unfair_lock_unlock(lockPtr) }
        return body()
    }

    // MARK: - Published reads (get-only from outside)

    /// At least one chunk has decoded successfully — the meter is live.
    var isMonitoring: Bool { withLock { didDecode } }
    /// Some decoded chunk peaked above DeadAirPolicy.audibleThreshold.
    var hasHeardAudio: Bool { withLock { hasHeard } }
    /// Wall-clock of the most recent audible chunk.
    var lastAudibleAt: Date? { withLock { lastAudible } }
    /// When the first chunk decoded successfully.
    var monitoringSince: Date? { withLock { monitoringStart } }
    /// The content classifier has produced at least one result this attempt.
    /// While false the content gate is inactive and confirmation is amplitude-only.
    var isContentGateActive: Bool { withLock { contentGateActive } }
    /// A classification other than `silence` reached the content confidence
    /// threshold — the stream carries recognizable content, not just loud noise.
    var hasHeardContent: Bool { withLock { heardContent } }

    // MARK: - Lifecycle

    /// Begin the side-channel meter: stream `url` over an own ephemeral
    /// URLSession and decode the arriving bytes in chunks. Replaces the old
    /// `attach(to:)` — no AVPlayerItem is involved.
    func attach(url: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1   // serial delegate delivery
        queue.name = "allarise.levelmeter"
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        startedAt = Date()

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    /// Cancel the URLSession task, clear buffers, and drop the session. Safe to
    /// call twice and from deinit. The per-chunk temp files are always removed
    /// in a `defer` at decode time, so nothing lingers on disk to clean up here.
    func detach() {
        stopped = true
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()   // releases the session's +1 on self
        session = nil
        // `buffer` is deliberately NOT cleared here: it is delegate-queue-only
        // state, and a detach from the main thread can race a mid-flight
        // didReceive. The cancelled task and `stopped` flag end its growth; the
        // memory goes with the monitor.
    }

    // MARK: - URLSessionDataDelegate (serial delegate queue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // MIME type is ignored — decode failure is the gate. A non-2xx status is
        // a hard fail-soft: cancel and never monitor.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped else { return }

        // Defensive lifetime cap — just stop metering; state freezes as-is.
        if let startedAt, Date().timeIntervalSince(startedAt) > Self.maxLifetime {
            cancelAndStop()
            return
        }

        buffer.append(data)
        if buffer.count >= Self.chunkBytes {
            let chunk = buffer
            buffer = Data()
            decodeChunk(chunk)
        }
    }

    // completion / error → nothing special. State freezes (fail-soft); no retry,
    // no logging. (Implementing the delegate method is unnecessary — the absence
    // of further callbacks is the freeze.)

    // MARK: - Decoding

    private func decodeChunk(_ chunk: Data) {
        guard !stopped else { return }

        // Once one extension has opened a chunk, only ever try that one.
        let candidates = decodedExtension.map { [$0] } ?? ["aac", "mp3"]

        for ext in candidates {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("allarise-levelmeter-\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                try chunk.write(to: tmp)
                // Opening picks the parser off the extension — that is why the
                // candidate list exists (AVAudioFile has no type-hint option).
                let file = try AVAudioFile(forReading: tmp)
                // The file opened → this counts as a successful decode. Metering
                // reads what it can; a mid-read throw on the partial trailing
                // frames is expected and still a success. The decoded PCM buffers
                // are kept so content classification can reuse them without
                // opening the file a second time.
                let (peak, buffers) = meterPeak(file)
                decodedExtension = ext
                recordSuccess(peak: peak)
                // Content gate: only classify AUDIBLE chunks, and only until some
                // content is confirmed. Silent chunks are dead air's job already.
                // Any classification failure is swallowed inside and never affects
                // the amplitude path above.
                if peak > DeadAirPolicy.audibleThreshold {
                    classifyContent(format: file.processingFormat, buffers: buffers)
                }
                return
            } catch {
                continue   // this parser couldn't open the chunk — try the next
            }
        }

        // Neither extension opened the chunk.
        strikes += 1
        if strikes >= Self.maxStrikes {
            cancelAndStop()   // fail-soft: unsupported stream shape
        }
    }

    /// Read the decoded file in PCM blocks and return the max absolute sample
    /// across all channels AND the decoded buffers, so content classification can
    /// reuse the same PCM without opening the file twice. A throw mid-read
    /// (partial trailing frames) ends the read and returns whatever was metered so
    /// far. A fresh buffer is allocated per block (rather than reusing one) so the
    /// collected buffers each hold their own frames for the analyzer to consume.
    private func meterPeak(_ file: AVAudioFile) -> (peak: Float, buffers: [AVAudioPCMBuffer]) {
        let format = file.processingFormat   // always deinterleaved float PCM
        let channelCount = Int(format.channelCount)
        var peak: Float = 0
        var buffers: [AVAudioPCMBuffer] = []
        while true {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.readFrames) else {
                break
            }
            do {
                try file.read(into: pcm)
            } catch {
                break   // partial read — meter what decoded
            }
            let frames = Int(pcm.frameLength)
            if frames == 0 { break }   // EOF
            if let channels = pcm.floatChannelData {
                for c in 0..<channelCount {
                    let samples = channels[c]
                    var i = 0
                    while i < frames {
                        let m = abs(samples[i])
                        if m > peak { peak = m }
                        i += 1
                    }
                }
            }
            buffers.append(pcm)
        }
        return (peak, buffers)
    }

    // MARK: - Content classification (SoundAnalysis)

    /// Run Apple's on-device sound classifier over one audible chunk's PCM,
    /// reusing the buffers the meter already decoded. A fresh analyzer + request
    /// per chunk (positions from 0) is the intended pattern — SNAudioStreamAnalyzer
    /// requires monotonically increasing frame positions PER analyzer. Every call
    /// that can throw is wrapped so a failure silently skips classification for
    /// this chunk WITHOUT touching the amplitude path: if the analyzer/request
    /// can't even be built, the gate stays inactive and confirmation reduces to
    /// amplitude-only (fail-soft). Runs on the serial delegate queue.
    private func classifyContent(format: AVAudioFormat, buffers: [AVAudioPCMBuffer]) {
        // Once content is confirmed, stop classifying — metering continues for the
        // dead-air watchdog, but the classifier's work is done.
        if withLock({ heardContent }) { return }
        guard !buffers.isEmpty else { return }

        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            applyWindowDuration(to: request)
            let analyzer = SNAudioStreamAnalyzer(format: format)
            // The analyzer holds the observer WEAKLY; `observer` is kept alive in
            // this scope through completeAnalysis(), which is where a stream
            // analyzer delivers its results.
            let observer = ContentClassificationObserver(monitor: self)
            try analyzer.add(request, withObserver: observer)
            var framePosition: AVAudioFramePosition = 0
            for buffer in buffers {
                analyzer.analyze(buffer, atAudioFramePosition: framePosition)
                framePosition += AVAudioFramePosition(buffer.frameLength)
            }
            analyzer.completeAnalysis()
            // Drop analyzer/observer here — never retained beyond the chunk.
        } catch {
            // Construction / add threw — skip classification for this chunk.
            // The gate stays inactive unless an earlier chunk already activated it.
            return
        }
    }

    /// Prefer a 1.0s analysis window when the request's constraint permits it;
    /// otherwise fall back to the constraint's minimum. Guarded so an unexpected
    /// constraint shape never throws past us — we simply leave the default window.
    private func applyWindowDuration(to request: SNClassifySoundRequest) {
        let oneSecond = CMTime(seconds: 1.0, preferredTimescale: 1000)
        switch request.windowDurationConstraint {
        case .enumeratedDurations(let durations):
            if durations.contains(where: { CMTimeCompare($0, oneSecond) == 0 }) {
                request.windowDuration = oneSecond
            } else if let minDuration = durations.min(by: { CMTimeCompare($0, $1) < 0 }) {
                request.windowDuration = minDuration
            }
        case .durationRange(let range):
            let minimumDuration = range.start
            let maximumDuration = range.end
            if CMTimeCompare(oneSecond, minimumDuration) >= 0,
               CMTimeCompare(oneSecond, maximumDuration) <= 0 {
                request.windowDuration = oneSecond
            } else {
                request.windowDuration = minimumDuration
            }
        @unknown default:
            break   // leave the request's default window untouched
        }
    }

    /// Called by the observer (possibly on a SoundAnalysis internal queue) for
    /// each classification result. Writes ONLY through the lock — it never touches
    /// delegate-queue-only state (buffer/strikes/decodedExtension). Sticky booleans.
    fileprivate func noteClassification(_ result: SNClassificationResult) {
        var heardContentNow = false
        for classification in result.classifications {
            // `silence` is a real version1 class and must NOT satisfy the gate.
            if classification.identifier != "silence",
               classification.confidence >= DeadAirPolicy.contentConfidenceThreshold {
                heardContentNow = true
                break
            }
        }
        withLock {
            contentGateActive = true
            if heardContentNow { heardContent = true }
        }
    }

    private func recordSuccess(peak: Float) {
        strikes = 0
        let now = Date()
        let audible = peak > DeadAirPolicy.audibleThreshold
        withLock {
            if monitoringStart == nil { monitoringStart = now }
            didDecode = true
            if audible {
                hasHeard = true
                lastAudible = now
            }
        }
    }

    private func cancelAndStop() {
        stopped = true
        task?.cancel()
    }
}

/// Bridges SoundAnalysis results back into the monitor's locked content state.
/// Kept deliberately tiny: it forwards each classification result and does no
/// scoring of its own (the threshold check lives in `noteClassification`, next to
/// the lock). Retained by the monitor for the duration of one chunk's analysis;
/// SNAudioStreamAnalyzer holds it only weakly.
private final class ContentClassificationObserver: NSObject, SNResultsObserving {
    private weak var monitor: StreamAudioLevelMonitor?

    init(monitor: StreamAudioLevelMonitor) {
        self.monitor = monitor
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        monitor?.noteClassification(classification)
    }

    // request(_:didFailWithError:) and requestDidComplete(_:) are intentionally
    // unimplemented — a failed or completed request just means no (more) content
    // results, which the fail-soft gate already handles.
}
