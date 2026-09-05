//
//  SleepTimerTrackerCard.swift
//  HaWake Alarm V2
//
//  Home-screen card for an active sleep timer (al-2se). The list view owns
//  visibility; this always renders for the session it is given.
//
//  Not tappable by user decision (2026-08-13): the edit sheet's only real
//  action from here was Cancel, so the card is display-only. Cancelling is
//  the list row's native swipe action (wired in AlarmListView, same idiom as
//  the alarm rows' Delete). Wake-point editing lives behind Kids Sleep → the
//  kid's card.
//
//  Everything is derived from the timeline's tick — phase, countdown and the
//  moving position marker all come from SleepTimerLogic at the current
//  instant. No Timer, no stored clock: the state machine lives entirely in
//  the session's timestamps, so a once-per-second TimelineView redraw keeps
//  the card exact without any external ticking or transition events.
//
//  The stage bar's colors mirror the OK-to-wake LED the HA automation drives
//  (see Documents/27-SLEEP-TIMER-DEBUG.md): the ball shows the color the
//  light should currently be. Change one side only in agreement with the
//  other.
//

import SwiftUI

struct SleepTimerTrackerCard: View {
    let session: SleepTimerSession
    let settings: DeviceSettings
    let accentColor: Color

    @Environment(\.colorScheme) private var colorScheme

    // Same glass resolution as the alarm rows / SleepSoundActiveRow, so the
    // card is visually a peer of the rows under every wallpaper + glass
    // setting instead of a flat opaque slab above them.
    private var useDarkSettings: Bool {
        colorScheme == .dark
    }

    private var homeGlassVariant: Glass {
        guard settings.homeWallpaperEnabled else { return .identity }
        let variant = useDarkSettings ? settings.homeDarkGlassVariant : settings.homeGlassVariant
        switch variant {
        case 1: return .clear
        case 2:
            let r = useDarkSettings ? settings.homeDarkGlassTintRed : settings.homeGlassTintRed
            let g = useDarkSettings ? settings.homeDarkGlassTintGreen : settings.homeGlassTintGreen
            let b = useDarkSettings ? settings.homeDarkGlassTintBlue : settings.homeGlassTintBlue
            let opacity = useDarkSettings ? settings.homeDarkGlassTintOpacity : settings.homeGlassTintOpacity
            return .regular.tint(Color(red: r, green: g, blue: b).opacity(opacity))
        default: return .regular
        }
    }

    private var homeClearDimming: Double {
        let variant = useDarkSettings ? settings.homeDarkGlassVariant : settings.homeGlassVariant
        guard variant == 1 else { return 0 }
        return useDarkSettings ? settings.homeDarkGlassClearDimming : settings.homeGlassClearDimming
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let date = context.date
            let phase = SleepTimerLogic.phase(of: session, at: date)
            let next = SleepTimerLogic.nextTransition(of: session, after: date)

            Group {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        // .primary, not accent — matches the arm widget's
                        // house icon (user request 2026-08-13).
                        Image(systemName: symbol(for: phase))
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(session.kidName.isEmpty ? "Sleep Timer" : session.kidName) · \(phase.displayName)")
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(countdownText(phase: phase, next: next, at: date))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .contentTransition(.numericText())
                        }

                        Spacer(minLength: 8)
                    }

                    SleepStageBar(session: session, now: date, phase: phase)
                        .frame(height: 18)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if !settings.homeWallpaperEnabled {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
                    } else if homeClearDimming > 0 {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black.opacity(homeClearDimming))
                    }
                }
                .glassEffect(homeGlassVariant, in: .rect(cornerRadius: 16))
                .overlay {
                    if settings.homeWallpaperEnabled {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
                    }
                }
                .contentShape(Rectangle())
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func symbol(for phase: SleepTimerPhase) -> String {
        switch phase {
        case .beforeBed: return "hourglass"
        case .ringing: return "bed.double.fill"
        case .sleeping1, .sleeping2, .sleeping3, .sleeping4: return "moon.zzz.fill"
        case .off: return "sun.max.fill"
        }
    }

    private func countdownText(phase: SleepTimerPhase, next: Date?, at now: Date) -> String {
        switch phase {
        case .beforeBed:
            guard let next else { return "" }
            return "Bed in \(shortRemaining(until: next, from: now))"
        case .ringing:
            // "Asleep at" is bedTime itself — ringing overlays the first
            // moments of sleep, it doesn't delay it.
            return "Asleep at \(clockTime(session.bedTime))"
        case .sleeping1, .sleeping2, .sleeping3, .sleeping4:
            // Compact units — the spelled-out form truncated on narrower
            // widths and the user chose shorter text over smaller text.
            return "Wakes \(clockTime(session.sleepEnd)) · \(coarseRemaining(until: session.sleepEnd, from: now))"
        case .off:
            // The card lives through the OK-to-wake window, like the light.
            return "Awake until \(clockTime(SleepTimerLogic.wakeWindowEnd(of: session)))"
        }
    }

    private func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Minutes while ≥ 60 s out, seconds inside the final minute — live-updating.
    private func shortRemaining(until target: Date, from now: Date) -> String {
        let seconds = max(0, target.timeIntervalSince(now))
        if seconds >= 60 {
            let minutes = Int((seconds / 60).rounded(.up))
            return "\(minutes) min"
        }
        return "\(Int(seconds)) sec"
    }

    /// Hours + minutes in compact units ("9h 45m"), no seconds — the sleeping
    /// span is long enough that a per-second tail would only jitter.
    private func coarseRemaining(until target: Date, from now: Date) -> String {
        let totalMinutes = max(0, Int(target.timeIntervalSince(now) / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
}

/// The full session as a horizontal stage track — yellow countdown, red sleep
/// span, green wake window — and a moving ball at "now" carrying the color the
/// OK-to-wake light should currently show (SleepTimerLED is the shared
/// mapping). Domain is createdAt → wake-window end, matching the light's
/// whole lifecycle.
private struct SleepStageBar: View {
    let session: SleepTimerSession
    let now: Date
    let phase: SleepTimerPhase

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackHeight: CGFloat = 6
            let ballColor = SleepTimerLED.color(at: now, bedTime: session.bedTime,
                                                sleepEnd: session.sleepEnd)

            ZStack(alignment: .leading) {
                // Stage segments in LED colors, butted edge-to-edge and
                // clipped to one capsule so the bar reads as a single
                // continuous track. Elapsed portions render stronger than
                // what's still ahead.
                ZStack(alignment: .leading) {
                    ForEach(segments(), id: \.start) { segment in
                        let x0 = width * fraction(of: segment.start)
                        let x1 = width * fraction(of: segment.end)
                        Rectangle()
                            .fill(segment.color.opacity(segment.end <= now ? 0.55 : 0.22))
                            .frame(width: max(0, x1 - x0), height: trackHeight)
                            .offset(x: x0)
                    }
                }
                .frame(width: width, height: trackHeight, alignment: .leading)
                .clipShape(Capsule())

                // The moving ball: where the session is right now, in the
                // color the LED should currently be.
                Circle()
                    .fill(ballColor)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: ballColor.opacity(0.6), radius: 4)
                    .offset(x: min(max(width * fraction(of: now) - 7, 0), width - 14))
            }
            .frame(height: geo.size.height)
        }
        .accessibilityHidden(true)
    }

    private struct Segment {
        let start: Date
        let end: Date
        let color: Color
    }

    private func segments() -> [Segment] {
        [
            Segment(start: session.createdAt, end: session.bedTime,
                    color: SleepTimerLED.beforeBed),
            Segment(start: session.bedTime, end: session.sleepEnd,
                    color: SleepTimerLED.sleeping),
            Segment(start: session.sleepEnd, end: SleepTimerLogic.wakeWindowEnd(of: session),
                    color: SleepTimerLED.awake),
        ].filter { $0.end > $0.start }
    }

    /// Position of a date along the createdAt → wake-window-end domain, clamped.
    private func fraction(of date: Date) -> CGFloat {
        let domainEnd = SleepTimerLogic.wakeWindowEnd(of: session)
        let span = domainEnd.timeIntervalSince(session.createdAt)
        guard span > 0 else { return 1 }
        return CGFloat(min(max(date.timeIntervalSince(session.createdAt) / span, 0), 1))
    }
}
