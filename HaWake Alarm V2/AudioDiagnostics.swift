//
//  AudioDiagnostics.swift
//  HaWake Alarm V2
//
//  Audio state introspection + always-on production logging.
//
//  Two public surfaces:
//
//  1. `printState(label:)` — one-shot verbose dump. Used by the Settings
//     "Dump Audio State" button, the debug live-monitor sheet, and LLDB:
//
//        (lldb) po AudioDiagnostics.printState()
//
//  2. `startMonitoring()` — installs observers + a 30-second heartbeat that
//     writes compact one-line snapshots to AppLogger. Emits:
//       - on every session activation / deactivation (via AppAudioSession)
//       - on every route change (Bluetooth, CarPlay, headphones, etc.)
//       - on every interruption (phone, Siri) and media-services reset
//       - periodically, de-duped (a heartbeat emits only if state changed)
//     Always on, no DEBUG gate — production logs were the missing piece when
//     debugging the Bluetooth/CarPlay-after-alarm regression.
//

import AVFoundation
import Foundation
import MediaPlayer

enum AudioDiagnostics {

    // MARK: - Public API

    /// Captures a formatted dump of the current audio state and returns it as
    /// a single multi-line string. Does not print or log — callers decide what
    /// to do with the result. Used by `printState(label:)` (console + logger)
    /// and by the debug live-monitor sheet (rendered in a SwiftUI Text view).
    @MainActor
    static func captureState(label: String = "dump") -> String {
        var lines: [String] = []
        let bar = String(repeating: "─", count: 64)
        lines.append(bar)
        lines.append("🎧 AUDIO DIAGNOSTICS [\(label)] @ \(Self.timestamp())")
        lines.append(bar)

        // MARK: AVAudioSession
        let session = AVAudioSession.sharedInstance()
        lines.append("AVAudioSession")
        lines.append("  isActive (shadow): \(AppAudioSession.isActive) — \(AppAudioSession.lastStateChangeReason)")
        if let lastActive = AppAudioSession.lastActivationAt {
            lines.append("  lastActivated:  \(Self.timeAgo(lastActive))")
        }
        if let lastInactive = AppAudioSession.lastDeactivationAt {
            lines.append("  lastDeactivated: \(Self.timeAgo(lastInactive))")
        }
        lines.append("  category:       \(session.category.rawValue)")
        lines.append("  mode:           \(session.mode.rawValue)")
        lines.append("  options:        \(describe(options: session.categoryOptions))")
        lines.append("  otherPlaying:   \(session.isOtherAudioPlaying)")
        lines.append("  secondarySilenceHint: \(session.secondaryAudioShouldBeSilencedHint)")
        lines.append("  sampleRate:     \(String(format: "%.0f", session.sampleRate)) Hz")
        lines.append("  ioBufferDur:    \(String(format: "%.4f", session.ioBufferDuration)) s")
        lines.append("  outputVolume:   \(String(format: "%.2f", session.outputVolume))")
        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }
        let inputs = session.currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }
        lines.append("  route.outputs:  \(outputs.isEmpty ? "—" : outputs.joined(separator: ", "))")
        lines.append("  route.inputs:   \(inputs.isEmpty ? "—" : inputs.joined(separator: ", "))")

        // MARK: MPNowPlayingInfoCenter
        lines.append("MPNowPlayingInfoCenter")
        if let info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            let title = info[MPMediaItemPropertyTitle] as? String ?? "—"
            let artist = info[MPMediaItemPropertyArtist] as? String ?? "—"
            let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
            let elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
            let duration = info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0
            lines.append("  title:          \(title)")
            lines.append("  artist:         \(artist)")
            lines.append("  playbackRate:   \(rate)")
            lines.append("  elapsed:        \(String(format: "%.1f", elapsed)) s")
            lines.append("  duration:       \(String(format: "%.1f", duration)) s")
        } else {
            lines.append("  (nowPlayingInfo is nil — no metadata published)")
        }

        // MARK: MPRemoteCommandCenter
        let commandCenter = MPRemoteCommandCenter.shared()
        lines.append("MPRemoteCommandCenter")
        lines.append("  playCommand.enabled:           \(commandCenter.playCommand.isEnabled)")
        lines.append("  pauseCommand.enabled:          \(commandCenter.pauseCommand.isEnabled)")
        lines.append("  togglePlayPauseCommand.enabled: \(commandCenter.togglePlayPauseCommand.isEnabled)")
        lines.append("  stopCommand.enabled:           \(commandCenter.stopCommand.isEnabled)")
        lines.append("  nextTrackCommand.enabled:      \(commandCenter.nextTrackCommand.isEnabled)")
        lines.append("  previousTrackCommand.enabled:  \(commandCenter.previousTrackCommand.isEnabled)")

        // MARK: App audio subsystems
        lines.append("App audio subsystems")
        let ssm = SleepSoundManager.shared
        lines.append("  SleepSoundManager.state:          \(ssm.state)")
        let sleepName = ssm.selectedSoundName.isEmpty ? "—" : ssm.selectedSoundName
        lines.append("  SleepSoundManager.selectedName:   \(sleepName)")
        lines.append("  SleepSoundManager.volume:         \(ssm.volume)")
        let asp = AlarmSoundPlayer.shared
        lines.append("  AlarmSoundPlayer.isPlaying:       \(asp.isPlaying)")

        lines.append(bar)

        return lines.joined(separator: "\n")
    }

    /// Captures a snapshot AND writes it to both the Xcode console and
    /// `AppLogger` (category `.audio`).
    @MainActor
    @discardableResult
    static func printState(label: String = "dump") -> String {
        let output = captureState(label: label)
        print(output)
        AppLogger.shared.log("AudioDiagnostics [\(label)]\n\(output)", category: .audio)
        return output
    }

    // MARK: - Monitoring

    /// Installs a route-change observer and starts the 30-second heartbeat.
    /// Call once at app launch, after `AppAudioSession.installObservers()`.
    /// Safe to call multiple times — subsequent calls are no-ops.
    @MainActor
    static func startMonitoring() {
        guard !monitoringInstalled else { return }
        monitoringInstalled = true

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { notification in
            let reasonRaw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            let reasonText = routeChangeReasonText(reasonRaw)
            Task { @MainActor in logTransition(reason: "route change: \(reasonText)") }
        }

        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in logHeartbeat() }
        }

        // Seed the last-snapshot baseline so the first heartbeat doesn't log
        // "unchanged" against an empty previous value.
        lastCompactSnapshot = compactState()
        lastRouteDescription = currentRouteDescription()
        AppLogger.shared.log("AudioMonitor: started — \(lastCompactSnapshot)", category: .audio)
    }

    /// Emits a one-line state snapshot tagged with the given reason.
    /// Called from AppAudioSession on every shadow transition, and from
    /// the route/interruption observers.
    @MainActor
    static func logTransition(reason: String) {
        let snapshot = compactState()
        AppLogger.shared.log("AudioTransition [\(reason)] \(snapshot)", category: .audio)
        lastCompactSnapshot = snapshot

        let route = currentRouteDescription()
        if route != lastRouteDescription {
            AppLogger.shared.log("AudioRoute: \(route)", category: .audio)
            lastRouteDescription = route
        }
    }

    // MARK: - Private

    nonisolated(unsafe) private static var monitoringInstalled = false
    nonisolated(unsafe) private static var heartbeatTimer: Timer?
    nonisolated(unsafe) private static var lastCompactSnapshot: String = ""
    nonisolated(unsafe) private static var lastRouteDescription: String = ""

    @MainActor
    private static func logHeartbeat() {
        let snapshot = compactState()
        if snapshot == lastCompactSnapshot {
            AppLogger.shared.log("AudioHeartbeat: unchanged (30s)", category: .audio)
        } else {
            AppLogger.shared.log("AudioHeartbeat: \(snapshot)", category: .audio)
            lastCompactSnapshot = snapshot
        }

        let route = currentRouteDescription()
        if route != lastRouteDescription {
            AppLogger.shared.log("AudioRoute: \(route)", category: .audio)
            lastRouteDescription = route
        }
    }

    /// One-line compact state used by the heartbeat and transition logs.
    /// Route outputs are deliberately excluded here — they're logged
    /// separately only when they change.
    @MainActor
    private static func compactState() -> String {
        let session = AVAudioSession.sharedInstance()
        let cat = session.category.rawValue
            .replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        let mode = session.mode.rawValue
            .replacingOccurrences(of: "AVAudioSessionMode", with: "")
        let opts = describe(options: session.categoryOptions)
        let active = AppAudioSession.isActive
        let other = session.isOtherAudioPlaying
        let silHint = session.secondaryAudioShouldBeSilencedHint
        let ssm = SleepSoundManager.shared
        let asp = AlarmSoundPlayer.shared
        return "cat=\(cat) mode=\(mode) opt=\(opts) active=\(active) other=\(other) silHint=\(silHint) ssm=\(ssm.state) asp=\(asp.isPlaying)"
    }

    @MainActor
    private static func currentRouteDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }
        let inputs = route.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }
        let o = outputs.isEmpty ? "—" : outputs.joined(separator: ",")
        let i = inputs.isEmpty ? "—" : inputs.joined(separator: ",")
        return "out=[\(o)] in=[\(i)]"
    }

    private static func routeChangeReasonText(_ raw: UInt) -> String {
        switch AVAudioSession.RouteChangeReason(rawValue: raw) {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        case .none, .some: return "raw(\(raw))"
        }
    }

    // MARK: - Formatting helpers

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    private static func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 1 {
            return "just now"
        } else if interval < 60 {
            return "\(Int(interval))s ago"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m \(Int(interval.truncatingRemainder(dividingBy: 60)))s ago"
        } else {
            let h = Int(interval / 3600)
            let m = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(h)h \(m)m ago"
        }
    }

    private static func describe(options: AVAudioSession.CategoryOptions) -> String {
        var names: [String] = []
        if options.contains(.mixWithOthers)                  { names.append("mixWithOthers") }
        if options.contains(.duckOthers)                     { names.append("duckOthers") }
        if options.contains(.allowBluetoothHFP)              { names.append("allowBluetoothHFP") }
        if options.contains(.allowBluetoothA2DP)             { names.append("allowBluetoothA2DP") }
        if options.contains(.allowAirPlay)                   { names.append("allowAirPlay") }
        if options.contains(.defaultToSpeaker)               { names.append("defaultToSpeaker") }
        if options.contains(.interruptSpokenAudioAndMixWithOthers) {
            names.append("interruptSpokenAudioAndMixWithOthers")
        }
        if options.contains(.overrideMutedMicrophoneInterruption) {
            names.append("overrideMutedMicrophoneInterruption")
        }
        return names.isEmpty ? "[]" : "[\(names.joined(separator: ", "))]"
    }
}
