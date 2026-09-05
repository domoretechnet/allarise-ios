//
//  ActiveAlarmView.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import SwiftUI
import Combine
import CoreMotion

struct ActiveAlarmView: View {
    let alarm: Alarm
    let settings: DeviceSettings
    /// A ceiling on this ring's remaining snoozes, imposed when the alarm
    /// survived a consolidated stack (al-bee.7): the strictest allowance across
    /// every alarm folded into it. `nil` — the default, and every ring outside a
    /// stack — leaves the alarm's own allowance exactly as it is.
    var snoozeAllowanceCap: Int? = nil
    let onDismiss: () -> Void
    let onSnooze: () -> Void
    /// DEBUG screenshot harness: start directly on the mission screen.
    var debugStartInMission: Bool = false
    /// "Try It Out" preview host: render the REAL alarm experience (chrome, grace
    /// countdown, mission interaction) but GATE every audio / global / MQTT side
    /// effect behind `!previewMode`. The grace COUNTDOWN itself still runs — only
    /// its sound + shared-state mutations are suppressed, so a preview can never
    /// mute a real alarm, emit/react to MQTT, or play audio. Defaults false so
    /// every production call site is byte-for-byte unchanged.
    var previewMode: Bool = false

    @State private var currentTime = Date()
    /// True only once the FINAL slot completes (drives snooze hiding + audio guards).
    /// Intermediate slot completions advance `currentSlotIndex` and leave this false.
    @State private var missionCompleted = false
    /// Index into `alarm.missionSequence` of the slot currently being played. The
    /// sequence lives entirely inside this one presentation; only the final slot's
    /// completion calls `onDismiss()`. Never persisted — a re-fire restarts at 0.
    @State private var currentSlotIndex = 0
    /// When the slot on screen started — times the mission telemetry only.
    @State private var slotStartedAt: Date?

    // Grace period state
    @State private var gracePeriodActive = false
    @State private var gracePeriodRemaining: Double = 0
    /// The full grace duration this period started with (for the countdown ring).
    @State private var gracePeriodTotal: Double = 0
    @State private var gracePeriodTimer: Timer?
    @State private var soundMutedByGracePeriod = false
    @State private var gracePeriodStartTime: Date?
    /// Balance mission: unused grace time carried across set-down failures
    /// (nil = the grace period has never started). Re-engaging after a
    /// set-down resumes with this budget instead of a fresh full duration.
    @State private var graceBudgetRemaining: Double?

    // Grace activity-pause: the countdown must NOT tick while the user is actively
    // interacting with the dismiss control (tap/hold) or actively stacking bricks.
    /// True the entire time a finger is pressing a hold-to-dismiss control — the
    /// countdown is frozen (mirrors the `isPressingSnooze` pause).
    @State private var graceHoldEngaged = false
    /// A sliding pause window: each tap / brick input (or piece-lock / line-clear)
    /// sets this to `now + window`; the countdown stays frozen until it passes, so
    /// rapid interaction keeps the countdown frozen and it resumes once activity
    /// stops. nil = no active pause window.
    @State private var graceActivityPausedUntil: Date?
    /// Sliding-pause window lengths. Tap: short, so a moment after the last tap the
    /// countdown resumes. Bricks: longer, so watching a piece fall between inputs
    /// doesn't let the countdown sneak downward mid-play.
    private let tapGraceActivityWindow: Double = 1.2
    private let brickGraceActivityWindow: Double = 3.0
    
    // Snooze button hold-to-confirm state
    @State private var snoozeProgress: Double = 0
    @State private var isPressingSnooze = false
    @State private var snoozeDisplayLink: DisplayLinkTimer?
    @State private var snoozeFired = false  // Prevents double-tap consuming multiple snoozes
    @State private var alarmResolved = false  // Mutual exclusion: once dismiss or snooze fires, block the other

    /// Two-phase alarm flow: the landing screen (title + time + Snooze/Dismiss or
    /// Snooze/Start Mission), then the full-screen mission screen. HA alarms start
    /// directly in `.mission` (they're just waiting for a dismiss).
    enum AlarmPhase { case landing, mission }
    @State private var phase: AlarmPhase = .landing
    /// True while the snooze button is held long enough to have muted the alarm
    /// audio (hold-to-snooze). Releasing before completion resumes the sound.
    @State private var snoozeHoldMuted = false

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Home-theme wallpaper for the alarm surface (appearance-based)
    @State private var alarmWallpaper: UIImage?
    @Environment(\.colorScheme) private var colorScheme

    /// Resolved alarm color customization for the current appearance
    private var alarmColors: AlarmColorCustomization {
        settings.alarmColors(for: colorScheme)
    }
    
    // MARK: - Home theme (alarm screen follows the main app theme)

    /// The main app (home) theme's primary button color — Dismiss / Start Mission
    /// adopt it, and so does the hold-to-snooze press.
    ///
    /// Routed through `settings.armAccent(for:)` so the per-theme accent override
    /// reaches it (al-4gz). Snooze shares `HoldPressStyle` with the alarm list's
    /// skip chip, so leaving it on the raw slot while skip followed the override
    /// would split one visual language in two — and splitting it *within* this
    /// screen (snooze on the override, Dismiss on the slot) would be worse still.
    /// With no override set this is `resolvedArmButtonColor`, unchanged.
    private var themeButtonColor: Color {
        settings.armAccent(for: colorScheme)
    }

    private var homeWallpaperScaleValue: Double { colorScheme == .dark ? settings.homeDarkWallpaperScale : settings.homeWallpaperScale }
    private var homeWallpaperOffsetXValue: Double { colorScheme == .dark ? settings.homeDarkWallpaperOffsetX : settings.homeWallpaperOffsetX }
    private var homeWallpaperOffsetYValue: Double { colorScheme == .dark ? settings.homeDarkWallpaperOffsetY : settings.homeWallpaperOffsetY }
    private var homeWallpaperDimmingValue: Double { colorScheme == .dark ? settings.homeDarkWallpaperDimming : settings.homeWallpaperDimming }

    // MARK: - Screen background

    @ViewBuilder
    private var screenBackground: some View {
        // Landing always shows the global wallpaper, and so do the two waiting
        // surfaces — alerts and Home Assistant. Neither is a game: an alert is a
        // notification (opaque card + Dismiss) and HA is a wait-for-dismiss
        // screen, so the theme photo reads behind them without competing.
        // Real missions keep the clean surface unless the debug "Mission Wallpaper"
        // toggle is on, because a photo behind a game is a distraction.
        let showWallpaper = phase == .landing
            || currentMission.type == .alert
            || currentMission.type == .homeAssistant
            || settings.debugMissionWallpaperEnabled
        return ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            if showWallpaper {
                wallpaperLayer
            }
        }
    }

    /// The global (home-theme) wallpaper image plus its legibility scrim. Shared by
    /// the landing and mission backgrounds. Renders nothing when no wallpaper is set.
    @ViewBuilder
    private var wallpaperLayer: some View {
        if settings.homeWallpaperEnabled, let alarmWallpaper {
            GeometryReader { geo in
                Image(uiImage: alarmWallpaper)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(homeWallpaperScaleValue)
                    .offset(x: homeWallpaperOffsetXValue, y: homeWallpaperOffsetYValue)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
            // Legibility scrim: strongest at top/bottom (behind time + buttons),
            // lighter in the middle so the wallpaper still reads. Works in both
            // light and dark because it only darkens.
            LinearGradient(
                colors: [.black.opacity(0.45), .black.opacity(0.12), .black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            Color.black.opacity(homeWallpaperDimmingValue * 0.5).ignoresSafeArea()
        }
    }

    // MARK: - Landing content (title + time + Snooze / Dismiss / Start Mission)

    private var landingContent: some View {
        VStack(spacing: 0) {
            // Anchor the clock to the upper third — Lock Screen / StandBy grammar.
            Spacer(minLength: 48).frame(maxHeight: 150)
            VStack(spacing: 6) {
                // Label as a quiet caption above the hero clock ("GOOD MORNING" style).
                Text(alarm.label.uppercased())
                    .font(.subheadline.weight(.bold))
                    .tracking(2.5)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                // Time is the hero: full-height, tabular digits (no shimmy).
                // AM/PM is shown at the same size, and omitted entirely in
                // 24-hour/military locales.
                Text(clockFull(currentTime))
                    .font(.system(size: 92, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
            }
            .shadow(color: .black.opacity(0.5), radius: 12, y: 2)
            .padding(.horizontal, 24)

            Spacer()

            landingButtons
                .padding(.horizontal)
                .padding(.bottom, 44)
        }
        // Grace countdown ring for a solo multi-tap / hold Tap alarm. The landing
        // page has its buttons pinned to the bottom, so the pill is lifted above
        // them while keeping the mission screens' trailing-corner placement.
        .overlay(alignment: .bottomTrailing) {
            if gracePeriodActive && gracePeriodRemaining > 0 {
                MissionGracePill(remaining: gracePeriodRemaining, total: gracePeriodTotal, accent: themeButtonColor)
                    .padding(.trailing, 22)
                    .padding(.bottom, 140)
            }
        }
    }

    @ViewBuilder
    private var landingButtons: some View {
        // A SOLO Tap alarm stays on the landing page and its Dismiss chip IS the
        // tap/hold target: an empty sequence (single tap, DefaultStopIntent) or a
        // lone `.none` slot (multi-tap/hold, CompleteMissionIntent — gated here, not
        // a mission sub-view). Any real mission, or a multi-slot sequence (which may
        // START with a Tap slot), routes into the mission phase via "Start Mission",
        // where a Tap slot renders as a full-screen TapMissionView in the slot machine.
        let seq = alarm.missionSequence
        let soloTapLanding = seq.isEmpty || (seq.count == 1 && seq[0].type == .none)
        HStack(spacing: 16) {
            if snoozeButtonVisible {
                snoozeButton
            }
            if soloTapLanding {
                TapDismissControl(
                    mission: alarm.mission,
                    accent: themeButtonColor,
                    // First tap / hold press-down starts grace (multi-tap / hold
                    // only; single tap has none and this no-ops on duration 0).
                    // Either way it is engagement — even a single tap that has no
                    // grace means the user is dismissing THIS ring (al-bee.11).
                    onEngaged: { noteEngaged(); startGracePeriodIfNeeded() },
                    // Hold press freezes the countdown the whole time it's down.
                    onHoldChanged: { pressing in
                        if pressing { noteEngaged() }
                        graceHoldEngaged = pressing
                    },
                    // Each tap refreshes the short activity pause window.
                    onTap: { registerGraceActivity(window: tapGraceActivityWindow) },
                    onComplete: {
                        // Completing the dismiss ends grace (resumeSound:false), as
                        // every other mission does. Only when grace is actually
                        // running, so a single-tap dismiss stays byte-for-byte.
                        if gracePeriodActive { endGracePeriod(resumeSound: false) }
                        if !previewMode {
                            AppLogger.shared.log("Alarm dismiss completed (tap): '\(alarm.label)' mode=\(alarm.mission.tapDismissMode.rawValue) count=\(alarm.mission.tapCount)", category: .alarm)
                            AlarmSoundPlayer.shared.stop()
                        }
                        onDismiss()
                    }
                )
            } else {
                startMissionChip
            }
        }
    }

    /// The "Start Mission" chip shown when the alarm has a real mission sub-view.
    private var startMissionChip: some View {
        Text("Start Mission")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 85)
            // Theme color, but more translucent so the glass reads as glass.
            .glassEffect(.regular.tint(themeButtonColor.opacity(0.55)), in: .rect(cornerRadius: 20))
            // contentShape AFTER the glass so the whole 85pt height is tappable.
            .contentShape(Rectangle())
            .onTapGesture {
                AppLogger.shared.log("Start Mission tapped: '\(alarm.label)' mission=\(alarm.mission.type.rawValue)", category: .alarm)
                noteEngaged()   // al-bee.11: the requirement is now fixed for this ring.
                withAnimation(.easeInOut(duration: 0.25)) { phase = .mission }
            }
    }

    // MARK: - Mission content (full-screen, no wallpaper, no snooze/dismiss)

    private var missionContent: some View {
        // The sequence indicator lives in the bottom-LEADING corner, mirroring
        // the grace ring's bottom-trailing spot, so the two small rings read as
        // one family and neither collides with the instruction text every
        // mission type puts at the very top.
        missionSlotContent
            .overlay(alignment: .bottomLeading) {
                if alarm.missionSequence.count > 1 {
                    MissionSequencePill(current: currentSlotIndex + 1,
                                        total: alarm.missionSequence.count,
                                        accent: themeButtonColor)
                        // Mirror MissionGracePill's corner padding.
                        .padding(.leading, 22)
                        .padding(.bottom, 26)
                        .transition(.opacity)
                }
            }
    }

    private var missionSlotContent: some View {
        Group {
            if currentMission.type == .alert {
                // Alert alarms have no mission gate — the Dismiss chip is a
                // SIBLING below the alert card (never an overlay), so the card's
                // glow box ends above the chip instead of running behind it.
                VStack(spacing: 20) {
                    missionView
                    alertDismissButton
                        // Matches AlertContentView's own `.padding(.horizontal)`
                        // so the button's edges line up with the card above it.
                        .padding(.horizontal, 16)
                }
                .padding(.bottom, 40)
            } else {
                missionView
            }
        }
        // Fresh view identity per slot so a new mission subview is built (its
        // @State resets) when the sequence advances — balance set-down/banking
        // and math problems never leak across slots.
        .id(currentSlotIndex)
        // That fresh identity makes this fire exactly once per slot, and only
        // in the mission phase — the two things "a mission started" means.
        .onAppear { noteMissionSlotStarted() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Bottom Dismiss chip for MQTT alert alarms (no mission gate) — the shared
    /// full-width primary button, same as the HA fallback's manual dismiss.
    private var alertDismissButton: some View {
        Button {
            if !previewMode {
                AppLogger.shared.log("Alert dismissed: '\(alarm.label)'", category: .alarm)
                AlarmSoundPlayer.shared.stop()
            }
            onDismiss()
        } label: {
            PrimaryActionLabel(title: "Dismiss", fill: themeButtonColor)
        }
        .buttonStyle(.plain)
    }

    /// The mission for the slot currently being played. For an empty sequence
    /// (`.none`/`.alert` alarms) this falls back to slot 1 so `missionView` still
    /// renders EmptyView / AlertContentView exactly as before.
    private var currentMission: Mission {
        let seq = alarm.missionSequence
        guard !seq.isEmpty else { return alarm.mission }
        return seq[min(currentSlotIndex, seq.count - 1)]
    }

    /// Effective grace duration for a specific slot's mission: per-alarm override
    /// wins (when > 0), else the mission's own calculated grace. For slot 0 with a
    /// single mission this equals `alarm.effectiveGracePeriod(settings:)` exactly.
    private func effectiveGrace(for mission: Mission) -> Double {
        // A Tap mission earns grace only when it's a REAL mission (multi-tap or
        // hold). A plain single tap has none — byte-for-byte the old behavior.
        if mission.type == .none {
            guard mission.tapDismissIsMission else { return 0 }
        }
        if let custom = alarm.customGracePeriod, custom > 0 { return custom }
        return mission.calculatedGracePeriod
    }

    /// Telemetry for the slot now on screen. Alert cards are excluded: they are
    /// a notification surface with a Dismiss button, not a mission.
    private func noteMissionSlotStarted() {
        guard !previewMode, currentMission.type != .alert else { return }
        slotStartedAt = Date()
        Analytics.shared.log(.missionStarted(type: currentMission.type, slotIndex: currentSlotIndex))
    }

    /// Seconds spent on the slot now on screen, for the mission telemetry.
    private var secondsOnCurrentSlot: TimeInterval {
        slotStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// A slot finished. On the FINAL slot: today's completion path (stop sound,
    /// dismiss the whole alarm). On an intermediate slot: hand off to the next slot
    /// while staying muted.
    private func completeCurrentSlot(logLabel: String) {
        let seq = alarm.missionSequence
        let total = max(1, seq.count)
        AppLogger.shared.log("Mission slot completed (\(logLabel)): '\(alarm.label)' slot \(currentSlotIndex + 1)/\(total)", category: .alarm)

        if !previewMode, currentMission.type != .alert {
            Analytics.shared.log(.missionCompleted(type: currentMission.type, seconds: secondsOnCurrentSlot))
        }

        if currentSlotIndex >= seq.count - 1 {
            // FINAL slot — exactly today's single-mission completion path.
            endGracePeriod(resumeSound: false)
            if !previewMode { AlarmSoundPlayer.shared.stop() }
            missionCompleted = true
            onDismiss()
        } else {
            advanceToNextSlot()
        }
    }

    /// Hand off from an intermediate slot to the next one. The alarm STAYS MUTED:
    /// end the current grace without resuming sound, reset per-slot grace state, then
    /// immediately start the next slot's grace using that mission's own duration. The
    /// radio grace hold persists (endGracePeriod(resumeSound:false) never releases it,
    /// startGracePeriod re-enters the preservingRadioGraceHold path). If the next slot
    /// has no grace (e.g. an HA slot, duration 0), resume sound so it rings while the
    /// user works it, like a single HA mission today.
    private func advanceToNextSlot() {
        let seq = alarm.missionSequence
        let nextIndex = currentSlotIndex + 1
        guard nextIndex < seq.count else { return }
        let nextMission = seq[nextIndex]
        let nextDuration = effectiveGrace(for: nextMission)

        if nextDuration > 0 {
            // Stay muted across the handoff.
            endGracePeriod(resumeSound: false)
            graceBudgetRemaining = nil
            withAnimation(.easeInOut(duration: 0.3)) { currentSlotIndex = nextIndex }
            startGracePeriod(duration: nextDuration)
        } else {
            // Next slot has no grace period — bring sound back so it rings while
            // being worked on (its own onEngaged may still arm a fallback grace).
            endGracePeriod(resumeSound: true)
            graceBudgetRemaining = nil
            withAnimation(.easeInOut(duration: 0.3)) { currentSlotIndex = nextIndex }
        }
    }

    var body: some View {
        ZStack {
            switch phase {
            case .landing:
                landingContent
                    .transition(.opacity)
            case .mission:
                missionContent
                    .transition(.opacity)
            }
        }
        .background { screenBackground }
        .onAppear {
            loadAppearanceWallpaper()
            // HA and alert alarms skip the landing page: HA is just waiting for a
            // dismiss, alerts show their own content immediately.
            if alarm.mission.type == .homeAssistant || alarm.mission.type == .alert {
                phase = .mission
                // Jumping straight to the mission screen IS engagement (al-bee.11).
                noteEngaged()
            }
            if debugStartInMission { phase = .mission }
        }
        .onChange(of: colorScheme) { _, _ in
            loadAppearanceWallpaper()
        }
        .onReceive(timer) { _ in
            currentTime = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MQTTSnoozeAlarm"))) { _ in
            guard !previewMode else { return }   // Previews never react to MQTT.
            guard !alarmResolved else { return }
            if alarm.effectiveSnoozeMode(settings: settings) != .disabled {
                alarmResolved = true
                AppLogger.shared.log("MQTT snooze received: '\(alarm.label)'", category: .alarm)
                AlarmSoundPlayer.shared.stop()
                onSnooze()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MQTTDismissAlarm"))) { _ in
            guard !previewMode else { return }   // Previews never react to MQTT.
            guard !alarmResolved else { return }
            alarmResolved = true
            AppLogger.shared.log("MQTT dismiss received: '\(alarm.label)'", category: .alarm)
            AlarmSoundPlayer.shared.stop()
            onDismiss()
        }
        .task {
            guard !previewMode else { return }   // Previews never publish HA/MQTT state.
            // MQTT-hidden alarms (al-5a94) re-assert nothing: showAlarm never
            // published their ringing state in the first place.
            guard !alarm.excludeFromMQTT else { return }
            HAIntegrationRouter.shared.publishAlarmState(.ringing, settings: settings)
            // Per-alarm ringing state (reinforces the one set in showAlarm)
            if let currentAlarm = AlarmWindowManager.shared.currentAlarm, currentAlarm.alarmIndex > 0 {
                let maxSnoozes = currentAlarm.maxSnoozeCount ?? settings.defaultMaxSnoozeCount
                let ownRemaining = maxSnoozes == 0 ? Int.max : max(0, maxSnoozes - currentAlarm.snoozeCount)
                // A consolidated survivor reports the capped figure, so Home
                // Assistant sees the same allowance the user does (al-bee.7).
                let snoozesRemaining = min(ownRemaining, snoozeAllowanceCap ?? Int.max)
                let snoozeAllowed = HAIntegrationRouter.shared.isSnoozeAllowedForAlarm(currentAlarm, snoozesRemaining: snoozesRemaining, settings: settings)
                HAIntegrationRouter.shared.publishPerAlarmStateTransition(alarmIndex: currentAlarm.alarmIndex, state: .ringing, snoozeAllowed: snoozeAllowed, settings: settings)
            }
            // Grace period is NO LONGER started here automatically.
            // Instead, it starts when the user engages with the mission (first shake / first
            // number tap). This eliminates the race condition where checkAndShowPendingAlarm()
            // or the snooze timer restart sound before the grace period's stop() call.
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            guard !previewMode else { return }   // Preview grace never touches audio.
            // User is backgrounding the app during grace period — resume sound immediately.
            // Ignore brief resign events (< 2s after grace period start) because window
            // transitions and Live Activity state changes can trigger spurious resign/activate
            // cycles that would immediately cancel the grace period.
            if soundMutedByGracePeriod && !missionCompleted {
                let elapsed = gracePeriodStartTime.map { Date().timeIntervalSince($0) } ?? 0
                if elapsed >= 2.0 {
                    endGracePeriod(resumeSound: true)
                } else {
                    print("=== DIAG === Ignoring brief willResignActive during grace period (elapsed: \(String(format: "%.1f", elapsed))s)")
                }
            }
        }
        .onDisappear {
            // The alarm screen went away with a mission still open — snoozed,
            // dismissed from MQTT, or the window torn down under it.
            if !previewMode, phase == .mission, !missionCompleted, currentMission.type != .alert {
                Analytics.shared.log(.missionAbandoned(type: currentMission.type, seconds: secondsOnCurrentSlot))
            }
            gracePeriodTimer?.invalidate()
            gracePeriodTimer = nil
            // Global mute flag is never touched by a preview (a real alarm may own it).
            if !previewMode { AlarmWindowManager.shared.isGracePeriodMuted = false }
        }
    }

    /// Whether the snooze button should be visible
    private var snoozeButtonVisible: Bool {
        // No snooze for alert missions or after mission complete. Snooze is also
        // only offered at ZERO progress: once slot 1 completes (index advances past
        // 0) it hides for the rest of the sequence. Because snooze only exists at
        // zero progress, a snooze re-fire trivially restarts the whole sequence.
        guard alarm.mission.type != .alert, !missionCompleted, currentSlotIndex == 0 else { return false }

        // For HA-controlled snooze mode
        if alarm.effectiveSnoozeMode(settings: settings) == .homeAssistant {
            if HAIntegrationRouter.shared.isConnected {
                // MQTT connected — only HA can snooze, hide button
                return false
            } else {
                // MQTT offline — use fallback snooze mode
                return alarm.mission.haSnoozeFallback != .disabled
            }
        }
        
        // Standard snooze visibility
        return alarm.effectiveSnoozeMode(settings: settings) != .disabled
    }
    
    /// The effective snooze hold requirement, accounting for HA fallback when MQTT is offline
    private var effectiveSnoozeRequiresHold: Bool {
        if alarm.effectiveSnoozeMode(settings: settings) == .homeAssistant
            && !HAIntegrationRouter.shared.isConnected {
            return alarm.mission.haSnoozeFallback == .hold
        }
        return alarm.effectiveSnoozeMode(settings: settings) == .hold
    }
    
    /// The effective snooze hold duration, accounting for HA fallback when MQTT is offline
    private var effectiveSnoozeHoldDuration: Double {
        if alarm.effectiveSnoozeMode(settings: settings) == .homeAssistant
            && !HAIntegrationRouter.shared.isConnected {
            return alarm.mission.haSnoozeFallbackHoldDuration
        }
        return alarm.customSnoozeHoldDuration ?? settings.snoozeHoldDuration
    }
    
    // MARK: - Action Buttons Section

    @ViewBuilder
    private var missionView: some View {
        // Drive off the CURRENT slot's mission, not slot 1. onComplete routes
        // through completeCurrentSlot so intermediate slots advance and only the
        // final slot dismisses the whole alarm.
        let mission = currentMission
        switch mission.type {
        case .none:
            // A Tap slot inside the sequence (e.g. Math → Tap → Shake). Solo tap
            // alarms never reach here — they're gated on the landing chip — so this
            // only renders for a mid-sequence Tap step. Grace is 0 for tap slots, so
            // the alarm rings while this shows (advanceToNextSlot resumes sound on
            // the zero-grace handoff).
            TapMissionView(
                mission: mission,
                onComplete: {
                    completeCurrentSlot(logLabel: "tap")
                },
                onEngaged: {
                    startGracePeriodIfNeeded()
                },
                onHoldChanged: { pressing in graceHoldEngaged = pressing },
                onTap: { registerGraceActivity(window: tapGraceActivityWindow) },
                gracePeriodActive: gracePeriodActive,
                gracePeriodRemaining: gracePeriodRemaining,
                graceTotal: gracePeriodTotal,
                alarmColors: alarmColors,
                accent: themeButtonColor
            )

        case .shake:
            ShakeMissionView(
                mission: mission,
                onComplete: {
                    completeCurrentSlot(logLabel: "shake")
                },
                onEngaged: {
                    startGracePeriodIfNeeded()
                },
                gracePeriodActive: gracePeriodActive,
                gracePeriodRemaining: gracePeriodRemaining,
                graceTotal: gracePeriodTotal,
                alarmColors: alarmColors,
                accent: themeButtonColor
            )

        case .math:
            MathMissionView(
                mission: mission,
                onComplete: {
                    completeCurrentSlot(logLabel: "math")
                },
                onEngaged: {
                    startGracePeriodIfNeeded()
                },
                gracePeriodActive: gracePeriodActive,
                gracePeriodRemaining: gracePeriodRemaining,
                graceTotal: gracePeriodTotal,
                alarmColors: alarmColors,
                accent: themeButtonColor
            )

        case .balanceBall:
            BalanceBallMissionView(
                mission: mission,
                onComplete: {
                    completeCurrentSlot(logLabel: "balance")
                },
                onEngaged: {
                    if let budget = graceBudgetRemaining {
                        // Re-engagement after a set-down: resume with the
                        // unused budget. Below 5s it isn't worth a mute
                        // flicker — the alarm keeps ringing while they finish.
                        if budget >= 5 {
                            startGracePeriod(duration: budget)
                        }
                    } else {
                        startGracePeriodIfNeeded()
                        graceBudgetRemaining = effectiveGrace(for: mission)
                    }
                },
                onSetDown: {
                    // Phone set down mid-mission: bring the alarm sound back
                    // immediately (endGracePeriod banks the unused budget).
                    guard gracePeriodActive else { return }
                    AppLogger.shared.log("Balance mission set-down: '\(alarm.label)' — resuming sound", category: .alarm)
                    endGracePeriod(resumeSound: true)
                },
                onGraceEarned: { amount in
                    // Active balancing earns extra mute time (+2s per full
                    // second in-zone). Only meaningful while grace is running.
                    guard gracePeriodActive else { return }
                    gracePeriodRemaining += amount
                },
                gracePeriodActive: gracePeriodActive,
                gracePeriodRemaining: gracePeriodRemaining,
                graceTotal: gracePeriodTotal,
                alarmColors: alarmColors,
                accent: themeButtonColor
            )

        case .blockDrop:
            BlockDropMissionView(
                mission: mission,
                onComplete: {
                    completeCurrentSlot(logLabel: "blockDrop")
                },
                onEngaged: {
                    startGracePeriodIfNeeded()
                },
                onActivity: {
                    // Any input / piece-lock / line-clear refreshes the (longer)
                    // brick pause window so active stacking freezes the countdown.
                    registerGraceActivity(window: brickGraceActivityWindow)
                },
                gracePeriodActive: gracePeriodActive,
                gracePeriodRemaining: gracePeriodRemaining,
                graceTotal: gracePeriodTotal,
                alarmColors: alarmColors,
                accent: themeButtonColor
            )

        case .meteor:
            MeteorMissionView(
                mission: mission,
                onComplete: {
                    completeCurrentSlot(logLabel: "meteor")
                },
                onEngaged: {
                    startGracePeriodIfNeeded()
                },
                onActivity: {
                    // Meaningful pod travel (not kills, not a resting finger)
                    // refreshes the pause window so active aiming freezes the
                    // countdown — camping can't.
                    registerGraceActivity(window: brickGraceActivityWindow)
                },
                onReleased: {
                    // Letting go of the pod resumes the countdown immediately —
                    // no coasting through the pause window's tail.
                    graceActivityPausedUntil = nil
                },
                gracePeriodActive: gracePeriodActive,
                gracePeriodRemaining: gracePeriodRemaining,
                graceTotal: gracePeriodTotal,
                alarmColors: alarmColors,
                accent: themeButtonColor
            )

        case .homeAssistant:
            HADismissMissionView(
                mission: mission,
                onComplete: {
                    completeCurrentSlot(logLabel: "HA")
                },
                onEngaged: {
                    // Fallback grace substitutes only for THIS (the HA) slot.
                    startFallbackGracePeriodIfNeeded(gracePeriod: mission.haFallbackGracePeriod, fallbackMission: mission.dismissFallbackMission)
                },
                alarmColors: alarmColors,
                accent: themeButtonColor,
                previewMode: previewMode
            )

        case .alert:
            AlertContentView(
                mission: mission,
                alarmID: MQTTCommandHandler.alertAlarmID(title: alarm.label)
            )
        }
    }
    
    private func loadAppearanceWallpaper() {
        // The alarm screen follows the MAIN APP (home) theme, not a separate
        // alarm theme — load the home wallpaper for the current appearance.
        let key = settings.activeHomeWallpaperKey(forDark: colorScheme == .dark)
        alarmWallpaper = settings.loadWallpaper(for: key)
    }
    
    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Whether the current locale uses 24-hour time (no AM/PM).
    private var uses24HourClock: Bool {
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return !template.contains("a")
    }

    /// The numeric part of the clock ("2:44" / "14:44"), no AM/PM — that's shown
    /// separately. Explicit format so the locale template can't re-append a period.
    private func clockDigits(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = .current
        df.dateFormat = uses24HourClock ? "H:mm" : "h:mm"
        return df.string(from: date)
    }

    /// The AM/PM part ("" in 24-hour locales).
    private func clockPeriod(_ date: Date) -> String {
        guard !uses24HourClock else { return "" }
        let df = DateFormatter()
        df.locale = .current
        df.dateFormat = "a"
        return df.string(from: date)
    }

    /// Full hero clock string: "2:50 PM" (12-hour) or "14:50" (24-hour/military).
    private func clockFull(_ date: Date) -> String {
        let period = clockPeriod(date)
        return period.isEmpty ? clockDigits(date) : "\(clockDigits(date)) \(period)"
    }
    
    // MARK: - Alarm Screen Widget Card
    
    /// Whether this alarm has a mission that needs screen space (keypad, shake UI, etc.)
    private var hasMissionUI: Bool {
        alarm.mission.type == .math || alarm.mission.type == .shake || alarm.mission.type == .balanceBall || alarm.mission.type == .blockDrop || alarm.mission.type == .meteor
    }
    
    @ViewBuilder
    // MARK: - Grace Period (mute sound while mission is active)
    
    /// Latch this presentation as engaged (al-bee.11), so the queue-change
    /// mission consolidation can never roll the showing alarm into a stack once
    /// the user has started acting on it — the demanded set must not change under
    /// their fingers. Previews never touch the shared manager. Idempotent, so
    /// "when in doubt, call it": the bias is against consolidating.
    private func noteEngaged() {
        guard !previewMode else { return }
        AlarmWindowManager.shared.noteShowingAlarmEngaged()
    }

    private func startGracePeriodIfNeeded() {
        // Slot-aware: grace derives from the CURRENT slot's mission. For a single
        // mission alarm this equals alarm.effectiveGracePeriod(settings:) exactly.
        // Tap missions (multi-tap / hold) now report a non-zero grace via
        // effectiveGrace; a plain single tap stays at 0 and no-ops below.
        let mission = currentMission
        let duration = effectiveGrace(for: mission)
        guard duration > 0 else { return }

        startGracePeriod(duration: duration)
    }

    // MARK: - Grace countdown activity-pause

    /// True whenever the grace countdown must be held (not ticked): the snooze
    /// button is held, a hold-to-dismiss finger is down, or a tap/brick activity
    /// pause window is still open. Evaluated fresh on every timer tick.
    private var graceCountdownPaused: Bool {
        if isPressingSnooze { return true }
        if graceHoldEngaged { return true }
        if let until = graceActivityPausedUntil, Date() < until { return true }
        return false
    }

    /// Refresh the sliding activity-pause window (tap events, brick inputs, and
    /// brick piece-lock / line-clear events all call this). Pure @State — no audio
    /// or global side effect — so a preview pauses identically and silently.
    private func registerGraceActivity(window: Double) {
        graceActivityPausedUntil = Date().addingTimeInterval(window)
    }

    private func startGracePeriod(duration: Double) {
        // Guard against stacked countdown timers — the balance mission can
        // re-arm the grace period after a set-down, and its re-engagement
        // signal may fire while a grace period is already running.
        guard !gracePeriodActive else { return }

        // A running grace period is engagement (al-bee.11): the user is working
        // the ring, so its requirement must not be swapped by a later arrival.
        noteEngaged()

        // Audio + global-state mutations are gated in preview; the countdown below
        // still runs so the grace ring animates exactly like a live alarm, silent.
        if !previewMode {
            AppLogger.shared.log("Grace period started: '\(alarm.label)' duration=\(Int(duration))s mission=\(alarm.mission.type.rawValue)", category: .alarm)

            // Mute the alarm sound and notify AlarmWindowManager so its Task.detached
            // doesn't restart sound while the grace period is active.
            AlarmWindowManager.shared.isGracePeriodMuted = true
            // Keep any confirmed radio stream alive but silent through grace, then
            // stop the wav WITHOUT tearing the held stream down. A dismiss/snooze
            // during grace hits the default stop() and fully stops the stream.
            RadioAlarmStreamer.shared.beginGraceHold()
            AlarmSoundPlayer.shared.stop(preservingRadioGraceHold: true)
        }
        soundMutedByGracePeriod = true
        gracePeriodActive = true
        gracePeriodRemaining = duration
        gracePeriodTotal = duration
        gracePeriodStartTime = Date()

        // Start countdown timer (updates every second for UI).
        // The countdown pauses while the user is holding the snooze button
        // or scrolling notes so the grace period doesn't expire mid-interaction.
        gracePeriodTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            // Freeze while the user is actively interacting (snooze hold, dismiss
            // hold, or a tap/brick activity window) so grace can't expire mid-input.
            guard !graceCountdownPaused else { return }

            gracePeriodRemaining -= 1.0

            if gracePeriodRemaining <= 0 {
                endGracePeriod(resumeSound: true)
            }
        }
    }

    /// Start grace period for a fallback mission (dismiss or snooze fallback)
    private func startFallbackGracePeriodIfNeeded(gracePeriod: Double, fallbackMission: Mission) {
        let duration: Double
        if gracePeriod > 0 {
            duration = gracePeriod
        } else {
            // Auto: calculate from fallback mission difficulty
            duration = fallbackMission.calculatedGracePeriod
        }
        
        guard duration > 0 else { return }

        // A running grace period is engagement (al-bee.11).
        noteEngaged()

        if !previewMode {
            AlarmWindowManager.shared.isGracePeriodMuted = true
            // Hold any confirmed radio stream silent through grace (see startGracePeriod).
            RadioAlarmStreamer.shared.beginGraceHold()
            AlarmSoundPlayer.shared.stop(preservingRadioGraceHold: true)
        }
        soundMutedByGracePeriod = true
        gracePeriodActive = true
        gracePeriodRemaining = duration
        gracePeriodTotal = duration
        gracePeriodStartTime = Date()

        gracePeriodTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard !graceCountdownPaused else { return }

            gracePeriodRemaining -= 1.0

            if gracePeriodRemaining <= 0 {
                endGracePeriod(resumeSound: true)
            }
        }
    }

    private func endGracePeriod(resumeSound: Bool) {
        if !previewMode {
            AppLogger.shared.log("Grace period ended: '\(alarm.label)' resumeSound=\(resumeSound) missionCompleted=\(missionCompleted)", category: .alarm)
        }
        gracePeriodTimer?.invalidate()
        gracePeriodTimer = nil
        gracePeriodActive = false
        // Clear any lingering interaction-pause state so a later grace period
        // (e.g. the next slot) starts ticking cleanly.
        graceHoldEngaged = false
        graceActivityPausedUntil = nil
        // Bank the unused time for the balance mission's set-down/re-engage
        // cycle. At natural expiry this is 0, so a later re-engagement can't
        // re-mute the alarm with a stale budget.
        if graceBudgetRemaining != nil {
            graceBudgetRemaining = max(0, gracePeriodRemaining)
        }
        gracePeriodRemaining = 0
        // Global mute flag is never touched by a preview (a real alarm may own it).
        if !previewMode { AlarmWindowManager.shared.isGracePeriodMuted = false }

        // The visual muted state ALWAYS ends here (the grace ring disappears). Only a
        // real alarm brings audio back; a preview's grace expiry is silent by design.
        soundMutedByGracePeriod = false
        if resumeSound && !missionCompleted && !previewMode {
            resumeAlarmAudioAfterMute()
        }
    }

    /// Bring the alarm sound back after a mute (grace period OR snooze-hold release).
    /// Restores volume and radio-aware resumes the wav/stream. Shared so both mute
    /// paths use the exact same, already-hardened audio resume.
    private func resumeAlarmAudioAfterMute() {
        // Previews never produce sound (defense-in-depth; callers already gate this).
        guard !previewMode else { return }
        // Don't restart sound if the alarm was already snoozed or dismissed.
        guard AlarmWindowManager.shared.isShowingAlarm,
              AlarmWindowManager.shared.currentAlarm != nil else {
            return
        }
        // Cancel any in-progress fade-in and jump to the alarm's full target volume
        VolumeManager.shared.cancelFadeIn()
        let targetVolume = Float(alarm.effectiveVolumeLevel(settings: settings))
        VolumeManager.shared.setSystemVolume(to: targetVolume)
        // Resume the alarm sound (unlock since this is a legitimate restart)
        Task {
            let unlocked = AlarmSoundPlayer.shared.unlockIfRinging()
            let hasStation = RadioAlarmStreamer.shared.hasLastStation || (alarm.radioStationURL != nil)
            AppLogger.shared.log("Audio resume: unlocked=\(unlocked) hasStation=\(hasStation) holding=\(RadioAlarmStreamer.shared.isGraceHolding)", category: .alarm)
            guard unlocked else { return }
            // Restart the wav first (play() preserves a surviving held stream
            // because RadioAlarmStreamer.isGraceHolding is still true here), then
            // decide the stream's fate.
            await AlarmSoundPlayer.shared.play(soundID: alarm.soundName)
            if hasStation {
                if RadioAlarmStreamer.shared.endGraceHold() {
                    RadioAlarmStreamer.shared.resumeFromGraceHold()
                } else {
                    RadioAlarmStreamer.shared.reattemptLastStation()
                }
            }
        }
    }

    // MARK: - Snooze-hold silence

    /// While the user holds the snooze button (hold-to-snooze), the alarm goes
    /// silent — reusing the grace-period mute so the audio chain is identical.
    private func muteForSnoozeHold() {
        // Don't double-mute if a grace period is already muting (shouldn't happen
        // on the landing screen, where there is no active mission, but be safe).
        guard !snoozeHoldMuted, !gracePeriodActive else { return }
        snoozeHoldMuted = true
        if !previewMode {
            AlarmWindowManager.shared.isGracePeriodMuted = true
            RadioAlarmStreamer.shared.beginGraceHold()
            AlarmSoundPlayer.shared.stop(preservingRadioGraceHold: true)
        }
    }

    /// The user released the snooze button before completing the hold — the alarm
    /// "fires again": bring the sound back exactly like a grace-period resume.
    private func resumeFromSnoozeHold() {
        guard snoozeHoldMuted else { return }
        snoozeHoldMuted = false
        if !previewMode {
            AlarmWindowManager.shared.isGracePeriodMuted = false
            resumeAlarmAudioAfterMute()
        }
    }

    /// The hold completed and snooze is committing — clear the mute flags without
    /// resuming (snooze itself stops the audio and hides the window).
    private func clearSnoozeHoldMute() {
        snoozeHoldMuted = false
        if !previewMode { AlarmWindowManager.shared.isGracePeriodMuted = false }
    }

    // MARK: - Snooze Button with Hold-to-Confirm
    
    /// Snoozes this ring still allows: the alarm's own remaining count, floored
    /// by any consolidation cap. `Int.max` means unlimited, the app's existing
    /// meaning for a `maxSnoozeCount` of 0.
    private var snoozesLeft: Int {
        let maxSnoozes = alarm.maxSnoozeCount ?? settings.defaultMaxSnoozeCount
        let own = maxSnoozes == 0 ? Int.max : max(0, maxSnoozes - alarm.snoozeCount)
        return min(own, snoozeAllowanceCap ?? Int.max)
    }

    private var snoozeButton: some View {
        let snoozesLeft = self.snoozesLeft
        let canSnooze = snoozesLeft > 0
        let requiresHold = effectiveSnoozeRequiresHold
        
        // Glass tint: clear idle → dark tint on completion, gray when disabled
        // Reads as the same rising fill as the hold press, so it follows the
        // accent override too; with none set it stays the first stop of the
        // theme's snooze gradient (al-4gz).
        let completionColor = settings.snoozeCompletionAccent(for: colorScheme)
        let snoozeGlass: Glass = if !canSnooze {
            .regular.tint(.gray)
        } else if snoozeProgress >= 1.0 {
            .regular.tint(completionColor.opacity(0.5))
        } else {
            .regular
        }
        
        return VStack(spacing: 4) {
            Text("Snooze")
                .font(.title3)
            
            if gracePeriodActive && gracePeriodRemaining > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "speaker.slash.fill")
                        .font(.caption2)
                    Text("\(Int(gracePeriodRemaining))s")
                        .font(.caption2.monospacedDigit())
                }
                .foregroundStyle(alarmColors.resolvedGracePeriodColor)
            } else if canSnooze && snoozesLeft != Int.max {
                HStack(spacing: 4) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.caption2)
                    Text("\(snoozesLeft) snooze\(snoozesLeft == 1 ? "" : "s") left")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            } else if snoozesLeft <= 0 {
                Text("No snoozes left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 85)
        .glassEffect(snoozeGlass, in: .rect(cornerRadius: 16))
        .holdPress(progress: snoozeProgress, isHolding: isPressingSnooze, accent: themeButtonColor, cornerRadius: 16)
        .contentShape(Rectangle())
        .disabled(!canSnooze)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressingSnooze && canSnooze {
                        if requiresHold {
                            startSnoozeHold()
                        }
                    }
                }
                .onEnded { _ in
                    if requiresHold {
                        // Only reverse the hold animation if snooze didn't already fire
                        if !snoozeFired {
                            endSnoozeHold(completed: false)
                        }
                    } else if canSnooze && !snoozeFired {
                        // Instant snooze (tap) for alarms without hold requirement
                        // Guard with snoozeFired to prevent double-tap consuming multiple snoozes
                        snoozeFired = true
                        if !previewMode {
                            AppLogger.shared.log("Snooze tapped (instant): '\(alarm.label)' snoozesLeft=\(snoozesLeft)", category: .alarm)
                            AlarmSoundPlayer.shared.stop()
                        }
                        onSnooze()
                    }
                }
        )
    }
    
    private func startSnoozeHold() {
        if !previewMode {
            AppLogger.shared.log("Snooze hold started: '\(alarm.label)' holdDuration=\(effectiveSnoozeHoldDuration)s", category: .alarm)
        }
        noteEngaged()   // al-bee.11: acting on the ring latches its requirement.
        isPressingSnooze = true
        snoozeProgress = 0
        // Silence the alarm while the button is held. If they release before the
        // hold completes, resumeFromSnoozeHold() brings it back ("fires again").
        muteForSnoozeHold()

        let totalDuration = effectiveSnoozeHoldDuration
        
        // If duration is 0, instantly trigger
        if totalDuration == 0 {
            guard !snoozeFired else { return }
            snoozeFired = true
            if !previewMode { AlarmSoundPlayer.shared.stop() }
            onSnooze()
            isPressingSnooze = false
            return
        }
        
        // Wall clock, not tick count (al-hjb): DisplayLinkTimer's delta is the
        // nominal frame period, so summing it measures frames delivered — every
        // dropped frame lengthened the hold. Same fix as the skip hold (al-lwz).
        let started = Date()
        snoozeDisplayLink = DisplayLinkTimer { _ in
            snoozeProgress = min(Date().timeIntervalSince(started) / totalDuration, 1.0)

            if snoozeProgress >= 1.0 {
                snoozeDisplayLink?.stop()
                snoozeDisplayLink = nil
                guard !snoozeFired else { return }
                snoozeFired = true
                // Hold completed: clear the mute flags (don't resume) and commit snooze.
                clearSnoozeHoldMute()
                // Stop sound immediately when snoozing
                if !previewMode { AlarmSoundPlayer.shared.stop() }
                // Trigger the snooze action
                onSnooze()
                // Reset state
                snoozeProgress = 0
                isPressingSnooze = false
            }
        }
        snoozeDisplayLink?.start()
    }
    
    
    private func endSnoozeHold(completed: Bool) {
        snoozeDisplayLink?.stop()
        snoozeDisplayLink = nil

        if !completed {
            isPressingSnooze = false
            // Released before the hold finished — bring the alarm sound back.
            resumeFromSnoozeHold()

            // Snap the gradient back like a rubber band
            let reverseDuration: Double = 0.1
            let savedProgress = snoozeProgress
            guard savedProgress > 0 else { return }
            
            snoozeDisplayLink = DisplayLinkTimer { deltaTime in
                snoozeProgress -= deltaTime / reverseDuration * savedProgress
                if snoozeProgress <= 0 {
                    snoozeProgress = 0
                    snoozeDisplayLink?.stop()
                    snoozeDisplayLink = nil
                }
            }
            snoozeDisplayLink?.start()
        }
    }
}

// MARK: - Tap Mission View (Tap slot inside a multi-mission sequence)

/// A `.none` (Tap) mission rendered as a full-screen slot in the slot machine —
/// used when a Tap step sits inside a multi-mission sequence (e.g. Math → Tap →
/// Shake). Solo tap alarms are still gated on the landing-page chip and never use
/// this view. It centers the real `TapDismissControl`, so single-tap / multi-tap /
/// hold behave exactly as on the landing page, styled to match the other mission
/// screens (icon cue + instruction + centered control). A multi-tap / hold tap
/// slot runs a real grace period — the countdown mutes the alarm and the grace
/// pill shows, freezing while the user taps/holds — exactly like the solo landing
/// chip. A single-tap slot has no grace, so the alarm rings while it's shown and
/// the pill stays hidden.
struct TapMissionView: View {
    let mission: Mission
    let onComplete: () -> Void
    var onEngaged: (() -> Void)? = nil
    /// Hold-mode press-state (true while a finger is down) — freezes the countdown.
    var onHoldChanged: ((Bool) -> Void)? = nil
    /// Fired on each tap — refreshes the countdown's short activity-pause window.
    var onTap: (() -> Void)? = nil
    var gracePeriodActive: Bool = false
    var gracePeriodRemaining: TimeInterval = 0
    var graceTotal: TimeInterval = 0
    var alarmColors: AlarmColorCustomization = .default
    /// Accent from the main app theme (dismiss chip tint).
    var accent: Color = .accentColor

    private var isHold: Bool { mission.tapDismissMode == .hold }
    private var isMultiTap: Bool { mission.tapDismissMode == .tap && mission.tapCount > 1 }

    private var instruction: String {
        if isHold { return "Hold the button for \(Int(mission.tapHoldDuration))s to dismiss." }
        if isMultiTap { return "Tap the button \(mission.tapCount) times to dismiss." }
        return "Tap the button to dismiss."
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                Spacer()

                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 96, weight: .regular))
                    .foregroundStyle(.primary)
                    .padding(.bottom, 28)

                Text(instruction)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)
                    .padding(.bottom, 36)

                TapDismissControl(
                    mission: mission,
                    accent: accent,
                    // Grace starts on first interaction (like the other missions),
                    // and interaction freezes the countdown — so the callbacks are
                    // routed through the control, not fired on appear.
                    onEngaged: onEngaged,
                    onHoldChanged: onHoldChanged,
                    onTap: onTap,
                    onComplete: onComplete
                )
                    .padding(.horizontal, 32)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Multi-tap / hold tap slots run a real grace period; single-tap slots
            // don't, so the pill only appears for the former.
            if gracePeriodActive && gracePeriodRemaining > 0 {
                MissionGracePill(remaining: gracePeriodRemaining, total: graceTotal, accent: accent)
                    .padding(.trailing, 22)
                    .padding(.bottom, 26)
            }
        }
    }
}

// MARK: - Tap-to-Dismiss landing control

/// The landing-screen Dismiss chip for a missionless ("Tap") alarm. Styled to
/// match the app's hold-to-confirm control family (glass base + shared
/// `HoldPressStyle`). Three behaviors, all gated right here on the landing page:
///   • Tap mode, count 1 → a single tap dismisses (byte-for-byte today's behavior)
///   • Tap mode, count N → each tap decrements a visible "N taps left" counter,
///     dismissing on the final tap
///   • Hold mode → the chip fills over `tapHoldDuration` via HoldPressStyle;
///     completing the hold dismisses (releasing early rubber-bands back)
/// Reused by MissionPreviewView so "Try It Out" exercises the real interaction.
struct TapDismissControl: View {
    let mission: Mission        // type == .none
    var accent: Color = .accentColor
    var height: CGFloat = 85
    var cornerRadius: CGFloat = 20
    /// First interaction (first tap or first hold press-down). The host starts the
    /// grace period here, matching the other missions' engagement semantics.
    var onEngaged: (() -> Void)? = nil
    /// Hold-mode press-state changes (true = finger down). The host freezes the
    /// grace countdown while pressed; only meaningful in hold mode.
    var onHoldChanged: ((Bool) -> Void)? = nil
    /// Fired on every tap (tap mode) so the host can refresh its short activity
    /// pause window — rapid tapping keeps the countdown frozen.
    var onTap: (() -> Void)? = nil
    /// Called once the tap count / hold completes.
    let onComplete: () -> Void

    @State private var tapsRemaining: Int
    @State private var holdProgress: CGFloat = 0
    @State private var isHolding = false
    @State private var link: DisplayLinkTimer?
    @State private var fired = false
    /// The host's grace engagement is idempotent, but track the first interaction
    /// locally so `onEngaged` is reported exactly once per control.
    @State private var engaged = false

    init(mission: Mission,
         accent: Color = .accentColor,
         height: CGFloat = 85,
         cornerRadius: CGFloat = 20,
         onEngaged: (() -> Void)? = nil,
         onHoldChanged: ((Bool) -> Void)? = nil,
         onTap: (() -> Void)? = nil,
         onComplete: @escaping () -> Void) {
        self.mission = mission
        self.accent = accent
        self.height = height
        self.cornerRadius = cornerRadius
        self.onEngaged = onEngaged
        self.onHoldChanged = onHoldChanged
        self.onTap = onTap
        self.onComplete = onComplete
        _tapsRemaining = State(initialValue: max(1, mission.tapCount))
    }

    private var isHold: Bool { mission.tapDismissMode == .hold }
    private var isMultiTap: Bool { mission.tapDismissMode == .tap && mission.tapCount > 1 }

    var body: some View {
        VStack(spacing: 4) {
            Text(isHold ? "Hold to Dismiss" : "Dismiss")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            if isHold {
                // "Keep holding…" while pressed — same feedback as the skip button.
                Text(isHolding ? "Keep holding…" : "Hold \(Int(mission.tapHoldDuration))s")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .animation(.easeInOut(duration: 0.15), value: isHolding)
            } else if isMultiTap {
                Text("\(tapsRemaining) tap\(tapsRemaining == 1 ? "" : "s") left")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .glassEffect(.regular.tint(accent.opacity(0.55)), in: .rect(cornerRadius: cornerRadius))
        // Shared hold-to-confirm press treatment (arm/skip/snooze family). Only
        // active in hold mode; tap mode leaves the fill at zero.
        .holdPress(progress: isHold ? holdProgress : 0, isHolding: isHold ? isHolding : false, accent: accent, cornerRadius: cornerRadius)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if isHold { startHold() }
                }
                .onEnded { _ in
                    if isHold {
                        if !fired { endHold() }
                    } else {
                        handleTap()
                    }
                }
        )
        .onDisappear { link?.stop(); link = nil }
    }

    private func handleTap() {
        guard !fired else { return }
        reportEngagedIfNeeded()
        onTap?()                 // refresh the host's activity pause window
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        if isMultiTap && tapsRemaining > 1 {
            withAnimation(.snappy(duration: 0.12)) { tapsRemaining -= 1 }
            return
        }
        fired = true
        onComplete()
    }

    /// Report the first interaction to the host exactly once.
    private func reportEngagedIfNeeded() {
        guard !engaged else { return }
        engaged = true
        onEngaged?()
    }

    private func startHold() {
        guard !isHolding, !fired else { return }
        reportEngagedIfNeeded()
        onHoldChanged?(true)     // freeze the countdown while the finger is down
        isHolding = true
        holdProgress = 0
        let total = max(0.3, mission.tapHoldDuration)
        // Wall clock, not tick count (al-hjb) — see startSnoozeHold().
        let started = Date()
        link = DisplayLinkTimer { _ in
            holdProgress = min(Date().timeIntervalSince(started) / total, 1.0)
            if holdProgress >= 1.0 {
                link?.stop(); link = nil
                guard !fired else { return }
                fired = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onComplete()
            }
        }
        link?.start()
    }

    private func endHold() {
        link?.stop(); link = nil
        isHolding = false
        onHoldChanged?(false)    // released before completing — resume the countdown
        let saved = holdProgress
        guard saved > 0 else { return }
        // Rubber-band the fill back to empty on early release.
        link = DisplayLinkTimer { delta in
            holdProgress -= delta / 0.12 * saved
            if holdProgress <= 0 {
                holdProgress = 0
                link?.stop(); link = nil
            }
        }
        link?.start()
    }
}

// MARK: - Display Link Timer (adaptive refresh rate)

private class DisplayLinkTimer {
    private var displayLink: CADisplayLink?
    private var onTick: ((Double) -> Void)?
    
    init(onTick: @escaping (Double) -> Void) {
        self.onTick = onTick
    }
    
    func start() {
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func tick(_ link: CADisplayLink) {
        let delta = link.targetTimestamp - link.timestamp
        onTick?(delta)
    }
    
    deinit {
        stop()
    }
}

// MARK: - Shake Motion Manager (persists across SwiftUI re-renders)

/// Wraps CMMotionManager in a class so it survives SwiftUI struct recreation.
/// Using a plain `let` on a struct causes a new CMMotionManager each re-render,
/// which silently breaks accelerometer updates.
@MainActor
final class ShakeMotionManager: ObservableObject {
    private let motionManager = CMMotionManager()
    private var isRunning = false
    
    var onShakeDetected: (() -> Void)?
    
    func start(threshold: Double) {
        guard !isRunning, motionManager.isAccelerometerAvailable else { return }
        isRunning = true
        
        motionManager.accelerometerUpdateInterval = 0.1
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let data = data else { return }
            
            let acceleration = sqrt(
                pow(data.acceleration.x, 2) +
                pow(data.acceleration.y, 2) +
                pow(data.acceleration.z, 2)
            )
            
            if acceleration > threshold {
                self?.onShakeDetected?()
            }
        }
    }
    
    func stop() {
        motionManager.stopAccelerometerUpdates()
        isRunning = false
    }
    
    deinit {
        motionManager.stopAccelerometerUpdates()
    }
}

// MARK: - Shared mission grace pill (sound-muted countdown)

/// Grace-period indicator shown at the top of mission screens: a small ring that
/// unwinds as the "sound muted" grace time runs out, with the seconds + a muted
/// speaker glyph inside. The ring is tinted with the app theme accent.
struct MissionGracePill: View {
    let remaining: TimeInterval
    var total: TimeInterval = 0
    var accent: Color = .secondary

    var body: some View {
        let progress = total > 0 ? max(0, min(1, remaining / total)) : 0
        ZStack {
            Circle()
                .stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)
            VStack(spacing: 0) {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 6))
                Text("\(Int(ceil(remaining)))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(.secondary)
        }
        .frame(width: 34, height: 34)
    }
}

// MARK: - Shared mission sequence pill ("mission 2 of 3")

/// Sequence indicator for multi-mission alarms: a small ring that fills as
/// slots are completed, with the "2/3" position and a checkered flag inside.
/// Deliberately the same 34pt footprint, stroke weights and secondary content
/// treatment as `MissionGracePill` — it sits in the opposite bottom corner, and
/// the two must read as one family of quiet status rings.
struct MissionSequencePill: View {
    /// 1-based slot currently being played.
    let current: Int
    let total: Int
    var accent: Color = .secondary

    var body: some View {
        let progress = total > 0 ? Double(current) / Double(total) : 0
        ZStack {
            Circle()
                .stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)
            VStack(spacing: 0) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 6))
                Text("\(current)/\(total)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(.secondary)
        }
        .frame(width: 34, height: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mission \(current) of \(total)")
    }
}

// MARK: - Shake Mission View

struct ShakeMissionView: View {
    let mission: Mission
    let onComplete: () -> Void
    var onEngaged: (() -> Void)? = nil
    var gracePeriodActive: Bool = false
    var gracePeriodRemaining: TimeInterval = 0
    var graceTotal: TimeInterval = 0
    var alarmColors: AlarmColorCustomization = .default
    /// Accent from the main app theme (progress bar).
    var accent: Color = .accentColor
    var compact: Bool = false

    @State private var shakeCount = 0
    @State private var startTime = Date()
    @State private var elapsedTime: TimeInterval = 0
    @State private var isCurrentlyShaking = false
    @State private var lastShakeTime: Date?
    @State private var completed = false
    @State private var hasEngaged = false
    @State private var wiggle = false
    @StateObject private var motionManager = ShakeMotionManager()
    
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private let idleTimeout: TimeInterval = 1.0 // Consider idle after 1 second without shaking
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
            Spacer()

            // Animated phone — wiggles to cue the user to shake.
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 104, weight: .regular))
                .foregroundStyle(.primary)
                .rotationEffect(.degrees(wiggle ? 8 : -8))
                .scaleEffect(isCurrentlyShaking ? 1.08 : 1.0)
                .animation(.easeInOut(duration: 0.32).repeatForever(autoreverses: true), value: wiggle)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: isCurrentlyShaking)
                .padding(.bottom, 20)

            Text("Shake to dismiss")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 32)

            // Big remaining number — counts down with each shake / second.
            if mission.shakeMode == .count {
                Text("\(max(0, mission.shakeCount - shakeCount))")
                    .font(.system(size: 92, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text("shakes left")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                Text("\(Int(max(0, Double(mission.shakeDuration) - elapsedTime)))s")
                    .font(.system(size: 92, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text(isCurrentlyShaking ? "Keep shaking" : "Move the phone to start")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Grace countdown ring — bottom-right, consistent across missions.
            if gracePeriodActive && gracePeriodRemaining > 0 {
                MissionGracePill(remaining: gracePeriodRemaining, total: graceTotal, accent: accent)
                    .padding(.trailing, 22)
                    .padding(.bottom, 26)
            }
        }
        .onAppear {
            wiggle = true
            startShakeDetection()
        }
        .onDisappear {
            motionManager.stop()
        }
        .onReceive(timer) { currentTime in
            // Check if we're still shaking (within timeout)
            if let lastShake = lastShakeTime {
                isCurrentlyShaking = currentTime.timeIntervalSince(lastShake) < idleTimeout
            } else {
                isCurrentlyShaking = false
            }
            
            // For duration mode, only increment elapsed time when actively shaking
            if mission.shakeMode == .duration {
                if isCurrentlyShaking {
                    elapsedTime += 0.1
                }
                
                if elapsedTime >= Double(mission.shakeDuration) {
                    if shakeCount > 0 && !completed { // Need at least one shake
                        completed = true
                        onComplete()
                    }
                }
            }
        }
    }
    
    private func startShakeDetection() {
        motionManager.onShakeDetected = { [self] in
            shakeCount += 1
            lastShakeTime = Date()
            isCurrentlyShaking = true

            // Only start the grace period (mute sound) if the user is actually
            // looking at the alarm screen. Shakes while the app is backgrounded
            // (e.g., picking up the phone from a Live Activity banner tap) still
            // count toward the mission but won't mute the alarm prematurely.
            if !hasEngaged && UIApplication.shared.applicationState == .active {
                hasEngaged = true
                onEngaged?()
            }

            if mission.shakeMode == .count && shakeCount >= mission.shakeCount && !completed {
                completed = true
                onComplete()
            }
        }
        motionManager.start(threshold: mission.shakeIntensity.threshold)
    }
}

// MARK: - Math Mission View

struct MathMissionView: View {
    let mission: Mission
    let onComplete: () -> Void
    var onEngaged: (() -> Void)? = nil
    var gracePeriodActive: Bool = false
    var gracePeriodRemaining: TimeInterval = 0
    var graceTotal: TimeInterval = 0
    var alarmColors: AlarmColorCustomization = .default
    /// Accent from the main app theme (used for the Submit key).
    var accent: Color = .accentColor
    var compact: Bool = false

    @State private var problems: [MathProblem] = []
    @State private var currentProblemIndex = 0
    @State private var userAnswer = ""
    @State private var showError = false
    @State private var hasEngaged = false
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Answer box + keypad as one group, centered vertically.
            VStack(spacing: 0) {
                Spacer()

                if currentProblemIndex < problems.count {
                    let problem = problems[currentProblemIndex]
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(problem.question)
                            .font(.system(size: 32, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(userAnswer.isEmpty ? "0" : userAnswer)
                            .font(.system(size: 80, weight: .light, design: .rounded))
                            .foregroundStyle(showError ? Color.red : .primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 18)
                    .animation(.snappy(duration: 0.15), value: userAnswer)
                    .animation(.easeInOut(duration: 0.2), value: showError)
                }

                keypad
                    .padding(.horizontal, 22)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Reserve the bottom-right corner for the grace ring so the keypad
            // (which is centered) doesn't collide with it.
            .padding(.bottom, 76)

            // Grace countdown ring, tucked in the bottom-right corner.
            if gracePeriodActive && gracePeriodRemaining > 0 {
                MissionGracePill(remaining: gracePeriodRemaining, total: graceTotal, accent: accent)
                    .padding(.trailing, 22)
                    .padding(.bottom, 26)
            }
        }
        .onAppear {
            if problems.isEmpty {
                generateProblems()
            }
            if UIApplication.shared.applicationState == .active {
                engageIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            engageIfNeeded()
        }
    }

    // MARK: - Calculator keypad (iOS-style circular keys)

    private var keypad: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)
        return LazyVGrid(columns: cols, spacing: 14) {
            ForEach(1...9, id: \.self) { d in
                digitKey("\(d)")
            }
            // Back: neutral circle with a theme-accent icon.
            circleKey(fill: Color(uiColor: .secondarySystemFill)) {
                Image(systemName: "delete.left").font(.title2.weight(.regular))
                    .foregroundStyle(accent)
            } action: {
                if !userAnswer.isEmpty { userAnswer.removeLast(); tapHaptic() }
                showError = false
            }
            digitKey("0")
            // Submit: solid theme-accent circle when ready (strong "done"),
            // neutral with an accent check when idle. Disabled until a digit.
            circleKey(fill: userAnswer.isEmpty ? Color(uiColor: .secondarySystemFill) : accent) {
                Image(systemName: "checkmark").font(.title2.weight(.semibold))
                    .foregroundStyle(userAnswer.isEmpty ? accent.opacity(0.5) : .white)
            } action: {
                checkAnswer()
            }
            .disabled(userAnswer.isEmpty)
        }
    }

    private func digitKey(_ s: String) -> some View {
        circleKey(fill: Color(uiColor: .secondarySystemFill)) {
            Text(s)
                .font(.system(size: 33, weight: .regular, design: .rounded))
                .foregroundStyle(.primary)
        } action: {
            engageIfNeeded()
            userAnswer.append(s)
            showError = false
            tapHaptic()
        }
    }

    private func circleKey<Content: View>(fill: Color, @ViewBuilder label: () -> Content, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // The Circle (flexible) drives the square sizing so every key is the
            // same column-width circle — icons and digits alike. (A non-resizable
            // SF Symbol can't drive the square, which is why icon keys lost their
            // circle before.)
            ZStack {
                Circle().fill(fill)
                label()
            }
            .frame(width: 78, height: 78)          // fixed, comfortable size
            .frame(maxWidth: .infinity)            // center within the grid column
        }
        .buttonStyle(.plain)
    }

    private func engageIfNeeded() {
        if !hasEngaged {
            hasEngaged = true
            onEngaged?()
        }
    }

    // MARK: - Haptics
    private func tapHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    private func successHaptic() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    private func errorHaptic() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func generateProblems() {
        var newProblems: [MathProblem] = []
        
        for _ in 0..<mission.mathProblemCount {
            newProblems.append(.generate(for: mission.mathDifficulty))
        }
        
        problems = newProblems
        
        // Log all generated problems
        let logger = AppLogger.shared
        logger.log("Math mission started: \(problems.count) problems, difficulty=\(mission.mathDifficulty.rawValue)", category: .alarm)
        for (i, p) in problems.enumerated() {
            logger.log("Math problem \(i + 1)/\(problems.count): \(p.question) = \(p.answer)", category: .alarm)
        }
    }
    
    private func checkAnswer() {
        let trimmed = userAnswer.trimmingCharacters(in: .whitespaces)
        let problem = problems[currentProblemIndex]
        
        guard let answerInt = Int(trimmed) else {
            AppLogger.shared.log("Math \(currentProblemIndex + 1)/\(problems.count): \"\(problem.question)\" — user typed \"\(trimmed)\" (invalid input), correct answer=\(problem.answer)", category: .alarm)
            showError = true
            userAnswer = ""
            return
        }
        
        let isCorrect = answerInt == problem.answer
        AppLogger.shared.log("Math \(currentProblemIndex + 1)/\(problems.count): \"\(problem.question)\" — user typed \(answerInt), correct answer=\(problem.answer), \(isCorrect ? "CORRECT" : "WRONG")", category: .alarm)
        
        if isCorrect {
            showError = false
            userAnswer = ""
            successHaptic()

            if currentProblemIndex + 1 < problems.count {
                currentProblemIndex += 1
            } else {
                AppLogger.shared.log("Math mission complete: all \(problems.count) problems solved", category: .alarm)
                onComplete()
            }
        } else {
            showError = true
            userAnswer = ""
            errorHaptic()
        }
    }
}

// MARK: - Home Assistant Dismiss Mission View

struct HADismissMissionView: View {
    let mission: Mission
    let onComplete: () -> Void
    var onEngaged: (() -> Void)? = nil
    var alarmColors: AlarmColorCustomization = .default
    /// Accent from the main app theme (HA icon + manual dismiss).
    var accent: Color = .accentColor
    /// "Try It Out" preview host — never emits telemetry (see ActiveAlarmView).
    var previewMode: Bool = false
    @State private var mqttManager = HAIntegrationRouter.shared
    @State private var pulseScale: CGFloat = 1.0
    @State private var showFallback = false
    /// The fallback is reported once per presentation, not per re-render.
    @State private var loggedFallback = false

    var body: some View {
        Group {
            if mqttManager.isConnected && !showFallback {
                // MQTT connected — waiting for HA to dismiss
                waitingForHAView
            } else {
                // MQTT disconnected — show fallback
                fallbackView
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MQTTDismissAlarm"))) { _ in
            onComplete()
        }
        .onChange(of: mqttManager.isConnected) { _, connected in
            if !connected {
                // Immediately show fallback when MQTT disconnects
                showFallback = true
            }
        }
    }
    
    private var waitingForHAView: some View {
        VStack {
            Spacer()
            VStack(spacing: 18) {
                Image(systemName: "house.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(accent)
                    .scaleEffect(pulseScale)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                            pulseScale = 1.14
                        }
                    }
                    .padding(.bottom, 2)

                Text("Waiting for Home Assistant")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text("Send a dismiss command from Home Assistant to turn off this alarm.")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 7) {
                    // Accent, not a literal green: "connected" is accent-colored
                    // everywhere else (the MQTT status dots, the gear-bubble
                    // ring), and this dot must read as the same family.
                    Circle().fill(accent).frame(width: 9, height: 9)
                    Text("Connected").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 20)
            .themedCard(accent: accent)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    /// The offline counterpart to `waitingForHAView`'s pulsing house.
    ///
    /// Deliberately the SAME `house.fill` the rest of the app uses (the waiting
    /// state above, and Home Assistant's row in Settings). `house.slash.fill`
    /// says "offline" in one glyph, but its silhouette differs from `house.fill`
    /// — no door, different roof proportions — so it read as a different house.
    ///
    /// Offline is carried the same way the connected state carries live: by color
    /// and motion. That one is accent and pulses; this one is grey and still. And
    /// unlike the old wifi.slash badge, a single glyph has one color to resolve,
    /// so `.secondary` handles both appearances for free — the badge needed a
    /// house, disc and slash color that stayed distinct in light AND dark, and in
    /// light mode all three landed within a few percent of each other.
    private var offlineHouse: some View {
        Image(systemName: "house.fill")
            .font(.system(size: 68))
            .foregroundStyle(.secondary)
    }

    private var manualDismissButton: some View {
        Button {
            AlarmSoundPlayer.shared.stop()
            onComplete()
        } label: {
            PrimaryActionLabel(title: "Dismiss", fill: accent)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var fallbackView: some View {
        VStack(spacing: 0) {
            // .blockDrop / .meteor aren't offered as HA fallbacks (see
            // FallbackMissionSectionView.availableTypes) so they fall through
            // to manual dismiss like the other non-fallback types.
            switch mission.haFallbackMission {
            case .none, .homeAssistant, .alert:
                Spacer()
                // Everything on ONE card, mirroring the connected state's
                // icon/title/subtitle. The status used to be a separate banner
                // pinned to the top of the page, which put "offline" and the
                // instruction that follows from it at opposite ends of the
                // screen — and repeated the wifi.slash the badge already shows.
                VStack(spacing: 18) {
                    offlineHouse
                    VStack(spacing: 8) {
                        // The disconnect glyph rides WITH the title rather than
                        // being layered onto the house. Beside the words it needs
                        // no knock-out and no contrast tuning, so it survives both
                        // appearances, and the house stays the same `house.fill`
                        // the rest of the app draws.
                        HStack(spacing: 9) {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.secondary.opacity(0.16)))
                            Text("Home Assistant offline")
                                .font(.title2.bold())
                                .foregroundStyle(.primary)
                        }
                        Text("Dismiss manually to turn off the alarm.")
                            .font(.title3)
                            .foregroundStyle(.primary)
                    }
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .padding(.horizontal, 20)
                .themedCard(accent: accent)
                .padding(.horizontal, 16)
                Spacer()
                manualDismissButton
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)

            case .shake:
                ShakeMissionView(mission: mission.dismissFallbackMission, onComplete: onComplete, onEngaged: onEngaged, accent: accent)

            case .math:
                MathMissionView(mission: mission.dismissFallbackMission, onComplete: onComplete, onEngaged: onEngaged, accent: accent)

            case .balanceBall:
                BalanceBallMissionView(mission: mission.dismissFallbackMission, onComplete: onComplete, onEngaged: onEngaged, accent: accent)

            case .blockDrop:
                BlockDropMissionView(mission: mission.dismissFallbackMission, onComplete: onComplete, onEngaged: onEngaged, accent: accent)

            case .meteor:
                MeteorMissionView(mission: mission.dismissFallbackMission, onComplete: onComplete, onEngaged: onEngaged, accent: accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The broker was unreachable, so the user is dismissing through the
        // fallback instead of through Home Assistant. Lives here rather than on
        // the old banner so it still fires for the mission fallbacks.
        .onAppear {
            guard !previewMode, !loggedFallback else { return }
            loggedFallback = true
            Analytics.shared.log(.haMissionFellBack)
        }
    }
}

#Preview {
    let alarm = Alarm(
        label: "Wake Up",
        mission: Mission(type: .math)
    )
    
    ActiveAlarmView(
        alarm: alarm,
        settings: DeviceSettings.shared,
        onDismiss: {},
        onSnooze: {}
    )
}



