//
//  AlertContentView.swift
//  HaWake Alarm V2
//
//  Rich media alert view for MQTT alerts.
//  Supports image, video, audio URL, link, and mute button.
//

import SwiftUI
import AVKit

/// Scheme allowlist for the `link_url` field of an inbound MQTT alert.
///
/// `Documents/15-INBOUND-COMMANDS-REFERENCE.md` documents `link_url` as a
/// "tappable button that opens the URL in the browser" — web only — so http and
/// https are the whole documented contract. Anything else arriving over MQTT
/// (`tel:`, `sms:`, `file:`, a third-party app scheme) would be a remote party
/// choosing which app the phone launches, which the alert feature never promised.
///
/// This is deliberately NOT applied to the App Link feature
/// (`AppLinkPreviewView`): those URIs are typed by the user on the device and
/// launching another app by its custom scheme is the entire point of that feature.
enum AlertLinkPolicy {
    /// Schemes an MQTT-supplied alert link may open.
    static let allowedSchemes: Set<String> = ["http", "https"]

    /// Returns the URL to open, or `nil` when the string is unusable or carries a
    /// scheme an alert is not allowed to launch. Pure — safe to unit test.
    static func resolve(_ raw: String?) -> URL? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme)
        else { return nil }
        return url
    }

    /// The scheme we refused, for logging. `nil` when there was nothing to refuse
    /// (empty/absent link) or when the link was allowed.
    static func rejectedScheme(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return "(none)"
        }
        return allowedSchemes.contains(scheme) ? nil : scheme
    }
}

struct AlertContentView: View {
    let mission: Mission
    let alarmID: Int
    @Environment(\.colorScheme) private var colorScheme

    @State private var mediaPlayer: AVPlayer?
    @State private var isMediaPlaying = false
    @State private var isSoundStopped = false
    @State private var loopObserver: NSObjectProtocol?
    /// Drives the shield's slow breathing halo.
    @State private var shieldGlowExpanded = false

    /// The app accent — the shield, the title, and the card's border and ambient
    /// glow all tint to match the app chrome, replacing the old fixed red.
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }

    /// Long alerts (multi-paragraph NWS text) read badly centered — they get
    /// leading alignment; short one/two-liners stay centered.
    private var messageIsLong: Bool {
        guard let message = mission.alertMessage else { return false }
        return message.count > 140 || message.contains("\n")
    }

    /// Whether this appearance gets the accent glows at all — matches
    /// `ThemedCardSurface`, which owns the card's own glow rules.
    private var glowsEnabled: Bool { colorScheme == .dark }

    private var mediaInfo: (mediaURL: String?, imageURL: String?, videoURL: String?, linkURL: String?, playSound: Bool)? {
        PendingAlarmStore.shared.retrieveAlertMediaInfo(alarmID: alarmID)
    }
    
    var body: some View {
        // ViewThatFits sizes the card to its content when the alert is short (a
        // title + a line of text no longer sits inside a full-screen empty box)
        // and falls back to a scrolling card when it isn't — long NWS alerts run
        // several paragraphs and must never be clipped.
        ViewThatFits(in: .vertical) {
            cardContent
            ScrollView { cardContent }
                // Bottom fade so a clipped paragraph reads as "there's more
                // below" instead of as a rendering glitch at the card's edge.
                .mask(scrollFadeMask)
        }
        .themedCard(accent: accent)
        // Applied AFTER the clip so the mute control floats in the card's corner
        // and stays put while long alerts scroll underneath it.
        .overlay(alignment: .topTrailing) { muteButton }
        .padding(.horizontal)
        .onAppear {
            handleOnAppear()
        }
        .onDisappear {
            mediaPlayer?.pause()
            mediaPlayer = nil
            if let observer = loopObserver {
                NotificationCenter.default.removeObserver(observer)
                loopObserver = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
            // Re-attempt media playback when app returns to foreground.
            // AVPlayer may fail to start while the app is still in the background.
            if mediaInfo?.mediaURL != nil && !(mediaPlayer?.rate ?? 0 > 0) {
                playMediaAudio()
            }
        }
    }
    
    // MARK: - Card content

    private var scrollFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.93),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// The stack the card wraps, shared by both `ViewThatFits` branches.
    private var cardContent: some View {
        VStack(spacing: 24) {
            headerSection
            imageSection
            videoSection
            mediaAudioSection
            linkSection
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, messageIsLong ? 22 : 28)
        .padding(.horizontal, 20)
    }

    // MARK: - Shield

    /// The shield, tinted to the app accent, over a soft halo that breathes in and
    /// out. The halo is deliberately near-invisible — it should register as the
    /// card quietly being alive, not as a pulsing beacon. It shrinks for long
    /// alerts so the header doesn't push the warning text below the fold.
    private var shieldBadge: some View {
        let glyph: CGFloat = messageIsLong ? 44 : 56
        // The frame hugs the glyph — the halo spreads past it via blur and scale,
        // which draw outside the bounds. Sizing the frame to the halo instead
        // would bake a ring of dead space between the shield and the title.
        let box: CGFloat = glyph * 1.15
        return Image(systemName: "exclamationmark.shield.fill")
            .font(.system(size: glyph))
            .foregroundStyle(accent)
            .frame(width: box, height: box)
            .background {
                // Dark mode only — on the light card this halo read as a smudge
                // around the shield rather than as light coming off it.
                if glowsEnabled {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [accent.opacity(0.30), accent.opacity(0)],
                                center: .center,
                                startRadius: 0,
                                endRadius: box * 0.5
                            )
                        )
                        .blur(radius: 12)
                        .scaleEffect(shieldGlowExpanded ? 1.55 : 1.15)
                        .opacity(shieldGlowExpanded ? 1.0 : 0.45)
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                    shieldGlowExpanded = true
                }
            }
    }

    // MARK: - Header (icon, title, message)

    @ViewBuilder
    private var headerSection: some View {
        // Shield and title are ONE unit — a tight nested stack, so the outer
        // 24pt rhythm falls between the title and the message instead of
        // stranding the shield above its own heading.
        VStack(spacing: 8) {
            shieldBadge

            if let title = mission.alertTitle {
                // The shared card-title treatment: .title2.bold()/.primary, the
                // same as the Notes and Home Assistant cards. The accent and its
                // breathing glow now live only on the shield, so one element
                // carries the alert's identity instead of two.
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let message = mission.alertMessage {
            Text(message)
                // `.primary` instead of hard-coded white: on the light appearance
                // white body text was all but invisible against the card.
                .font(.title3)
                .foregroundStyle(.primary)
                .multilineTextAlignment(messageIsLong ? .leading : .center)
                .frame(maxWidth: .infinity, alignment: messageIsLong ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    // MARK: - Image
    
    @ViewBuilder
    private var imageSection: some View {
        if let imageURLString = mediaInfo?.imageURL,
           let imageURL = URL(string: imageURLString) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 250)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                case .failure:
                    Label("Failed to load image", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                case .empty:
                    ProgressView()
                        .frame(height: 100)
                @unknown default:
                    EmptyView()
                }
            }
            .padding(.horizontal)
        }
    }
    
    // MARK: - Video
    
    @ViewBuilder
    private var videoSection: some View {
        if let videoURLString = mediaInfo?.videoURL,
           let videoURL = URL(string: videoURLString) {
            VideoAlertPlayer(url: videoURL)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
        }
    }
    
    // MARK: - Media Audio
    
    @ViewBuilder
    private var mediaAudioSection: some View {
        if mediaInfo?.mediaURL != nil && !DeviceSettings.shared.alertLoopMedia {
            HStack(spacing: 12) {
                Button {
                    playMediaAudio()
                } label: {
                    chipLabel(
                        isMediaPlaying ? "Playing..." : "Play Audio",
                        systemImage: isMediaPlaying ? "speaker.wave.3.fill" : "play.circle.fill",
                        prominent: true
                    )
                }
                .disabled(isMediaPlaying)

                Button {
                    playMediaAudio()
                } label: {
                    chipLabel("Repeat", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    /// Shared chip styling for the card's actions. The prominent variant is the
    /// accent fill with white text (same pairing as the screen's Dismiss button);
    /// the rest are material chips, which stay legible in both appearances — the
    /// old fixed purple/orange fills didn't match the app chrome and the
    /// white-on-white mute chip vanished on the light theme.
    private func chipLabel(_ title: String, systemImage: String, prominent: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                if prominent {
                    Capsule().fill(accent.opacity(0.9))
                } else {
                    Capsule().fill(.ultraThinMaterial)
                        .overlay(Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 1))
                }
            }
    }
    
    // MARK: - Link
    
    @ViewBuilder
    private var linkSection: some View {
        // Only http/https links from an MQTT alert get a button. A blocked scheme
        // hides the button but leaves the rest of the alert intact — the message
        // still has to reach the user.
        if let linkURL = AlertLinkPolicy.resolve(mediaInfo?.linkURL) {
            Button {
                UIApplication.shared.open(linkURL)
            } label: {
                chipLabel("Open Link", systemImage: "link")
            }
        }
    }
    
    // MARK: - Mute

    /// Mute lives in the card's top-right corner rather than in the content flow.
    /// It's a utility control, not part of the alert's message, and inlining it
    /// under the text made it read as a step in the alert. Accent-tinted, and it
    /// goes grey once the sound is already stopped.
    @ViewBuilder
    private var muteButton: some View {
        // Only for text-only alerts with play_sound=true
        if mediaInfo?.mediaURL == nil && mediaInfo?.playSound != false {
            Button {
                guard !isSoundStopped else { return }
                isSoundStopped = true
                AlarmSoundPlayer.shared.stop()
            } label: {
                Image(systemName: isSoundStopped ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSoundStopped ? Color.secondary : accent)
                    .frame(width: 44, height: 44)
                    // A plain outlined circle — no fill. The tinted disc behind it
                    // read as a soft halo around the glyph rather than as a button,
                    // and it was the only glow left on the light card. An outline
                    // matches the card's own thin-border language.
                    .background {
                        Circle().strokeBorder(
                            isSoundStopped
                                ? Color.secondary.opacity(0.3)
                                : accent.opacity(0.55),
                            lineWidth: 1.5
                        )
                    }
            }
            .padding(12)
            .accessibilityLabel(isSoundStopped ? "Sound stopped" : "Stop sound")
            .disabled(isSoundStopped)
        }
    }
    
    // MARK: - Actions
    
    private func handleOnAppear() {
        // Haptic feedback if alert vibration is enabled
        if DeviceSettings.shared.alertVibrationEnabled {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
        }
        
        // If media_url is present, stop alarm sound (media audio replaces it)
        if mediaInfo?.mediaURL != nil {
            AlarmSoundPlayer.shared.stop()
            playMediaAudio()
        }
        // If play_sound is false, stop alarm sound
        if mediaInfo?.playSound == false {
            AlarmSoundPlayer.shared.stop()
        }
    }
    
    private func playMediaAudio() {
        guard let mediaURLString = mediaInfo?.mediaURL,
              let url = URL(string: mediaURLString) else { return }
        
        // Ensure audio session is configured for playback (may not be set up
        // when play_sound=false since handleSecurityAlert skips it).
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            print("❌ Failed to configure audio session for media playback: \(error)")
        }
        
        // Apply the requested volume (from MQTT payload) before playback.
        // Falls back to the user's configured media alert volume if none specified.
        let pending = PendingAlarmStore.shared.pendingAlarm
        let requestedVolume = pending?.volumeLevel ?? DeviceSettings.shared.mediaAlertVolume
        let effectiveVolume = Float(min(max(requestedVolume, 0.0), 1.0))
        VolumeManager.shared.setSystemVolume(to: effectiveVolume)
        
        // Stop any existing playback and remove old loop observer
        mediaPlayer?.pause()
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }
        
        let player = AVPlayer(url: url)
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        mediaPlayer = player
        isMediaPlaying = true
        
        let shouldLoop = DeviceSettings.shared.alertLoopMedia
        
        // Observe when playback finishes — loop if enabled, otherwise mark done
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            if shouldLoop {
                let delay = DeviceSettings.shared.alertLoopDelay
                if delay > 0 {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(delay))
                        await player?.seek(to: .zero)
                        player?.play()
                    }
                } else {
                    player?.seek(to: .zero)
                    player?.play()
                }
            } else {
                isMediaPlaying = false
            }
        }
        
        player.play()
    }
}

/// Inline video for a media alert. Wraps `VideoPlayer` but watches the player
/// item's `status` so an unreachable or unsupported clip shows a "Failed to
/// load video" label instead of a silent black rectangle — the twin of the
/// `case .failure` branch on the image path. Without this, an unsupported
/// container (MKV, WebM) or a URL the phone can't reach reads as "nothing
/// happened", which is exactly how a real media failure was first reported.
private struct VideoAlertPlayer: View {
    @State private var player: AVPlayer
    @State private var failed = false
    @State private var statusObservation: NSKeyValueObservation?

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        Group {
            if failed {
                Label("Failed to load video", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                VideoPlayer(player: player)
            }
        }
        .onAppear {
            // AVPlayerItem.status flips to .failed on load/decode failure. The
            // KVO callback can arrive off the main thread, so hop back before
            // mutating view state.
            statusObservation = player.currentItem?.observe(\.status, options: [.new]) { item, _ in
                if item.status == .failed {
                    Task { @MainActor in failed = true }
                }
            }
        }
        .onDisappear {
            statusObservation?.invalidate()
            statusObservation = nil
            player.pause()
        }
    }
}
