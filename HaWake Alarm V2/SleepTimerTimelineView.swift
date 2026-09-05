//
//  SleepTimerTimelineView.swift
//  HaWake Alarm V2
//
//  Reusable horizontal timeline for the debug-only sleep timer (al-2se).
//  Shared by the create sheet (now == nil) and the edit sheet (now == current
//  time, which locks the elapsed portion). All phase geometry comes from
//  SleepTimerLogic so this view and Home Assistant agree on the split.
//
//  Sections are painted in the OK-to-wake LED colors the deployed HA
//  automation drives: yellow (pre-bed countdown), red (bed time through the
//  whole sleep span — ringing included), green (the 2-hour wake window).
//

import SwiftUI

/// UI equivalents of the OK-to-wake LED colors — the HA device RGBs encode
/// brightness, not hue, so these are the app-palette stand-ins. Single source
/// for the timeline sections and the tracker card's ball; change only in
/// agreement with the HA-side ladder.
enum SleepTimerLED {
    static let beforeBed: Color = .yellow
    static let sleeping: Color = .red
    static let awake: Color = .green

    /// The color the physical light should show at `date` for this schedule.
    static func color(at date: Date, bedTime: Date, sleepEnd: Date) -> Color {
        if date < bedTime { return beforeBed }
        if date < sleepEnd { return sleeping }
        return awake
    }
}

struct SleepTimerTimelineView: View {
    let sessionStart: Date            // left anchor — creation moment (yellow starts here)
    let bedTime: Date                 // countdown end (red starts here)
    @Binding var sleepEnd: Date       // draggable right endpoint (the wake point)
    let minimumSleepEnd: Date         // clamp for dragging
    let maximumSleepEnd: Date         // clamp for dragging
    let accentColor: Color
    let now: Date?                    // nil in create mode; current time in edit mode
    /// Create-mode fine adjustment: when set, the bed-time dot becomes a
    /// draggable handle snapping to 1-MINUTE steps (the countdown stepper
    /// moves in 5s; this is the precision path) and the callback receives the
    /// new bed time. Edit mode leaves this nil — bed time is locked once the
    /// session is running.
    var onBedTimeDrag: ((Date) -> Void)? = nil

    // Frozen render domain for the duration of a drag. Without freezing, the
    // domain would follow sleepEnd and the x→date inversion would chase its own
    // tail; pinning it at grab time keeps the gesture linear and stable.
    @State private var dragDomainEnd: Date?

    private let trackHeight: CGFloat = 8
    private let rowHeight: CGFloat = 48
    private let handleHit: CGFloat = 44
    private let snapStep: TimeInterval = 5 * 60
    private let coordSpace = "sleepTimerTrack"

    // Dragging can never cross into the locked (already-elapsed) region.
    private var effectiveMin: Date {
        guard let now else { return minimumSleepEnd }
        return max(minimumSleepEnd, now)
    }

    // Throwaway session so the shared logic yields quarter ticks. Type is
    // irrelevant to those calculations.
    private var session: SleepTimerSession {
        SleepTimerSession(id: UUID(), type: .nap, createdAt: sessionStart,
                          bedTime: bedTime, sleepEnd: sleepEnd)
    }

    // Padding past the wake point so the right handle sits interior to the track
    // and has room to travel — doubles as space for the green wake section.
    private func headroom(after end: Date) -> TimeInterval {
        let span = end.timeIntervalSince(bedTime)
        return max(60 * 60, span * 0.35)
    }

    private var domainEnd: Date {
        dragDomainEnd ?? sleepEnd.addingTimeInterval(headroom(after: sleepEnd))
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                track(width: geo.size.width)
            }
            .frame(height: rowHeight)

            labels
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .animation(.smooth, value: sleepEnd)
    }

    private func track(width w: CGFloat) -> some View {
        let total = domainEnd.timeIntervalSince(sessionStart)
        func x(_ date: Date) -> CGFloat {
            guard total > 0 else { return 0 }
            let f = date.timeIntervalSince(sessionStart) / total
            return min(max(CGFloat(f), 0), 1) * w
        }

        let boundaries = SleepTimerLogic.quarterBoundaries(of: session)
        let bedX = x(bedTime)
        let handleX = x(sleepEnd)
        let greenEndX = x(min(SleepTimerLogic.wakeWindowEnd(of: session), domainEnd))
        let lockedX = now.map { x(min($0, sleepEnd)) }
        let axisY = rowHeight / 2

        return ZStack(alignment: .leading) {
            // Base track + LED sections (yellow countdown, red sleep, green
            // wake window), butted edge-to-edge and clipped to one capsule so
            // the bar reads as a single continuous track.
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.secondary.opacity(0.15))
                    .frame(width: w, height: trackHeight)
                Rectangle()
                    .fill(SleepTimerLED.beforeBed.opacity(0.35))
                    .frame(width: max(0, bedX), height: trackHeight)
                Rectangle()
                    .fill(SleepTimerLED.sleeping.opacity(0.30))
                    .frame(width: max(0, handleX - bedX), height: trackHeight)
                    .offset(x: bedX)
                Rectangle()
                    .fill(SleepTimerLED.awake.opacity(0.30))
                    .frame(width: max(0, greenEndX - handleX), height: trackHeight)
                    .offset(x: handleX)

                // Elapsed portion (edit mode): dimmed so it reads as locked
                // while the section colors stay visible underneath.
                if let lockedX {
                    Rectangle()
                        .fill(.primary.opacity(0.10))
                        .frame(width: lockedX, height: trackHeight)
                }
            }
            .frame(width: w, height: trackHeight, alignment: .leading)
            .clipShape(Capsule())

            // Interior quarter tick marks.
            ForEach(Array(boundaries.enumerated()), id: \.offset) { _, b in
                Rectangle()
                    .fill(.secondary.opacity(0.5))
                    .frame(width: 1, height: trackHeight + 6)
                    .offset(x: x(b) - 0.5)
            }

            // Bed-time boundary dot — where yellow hands off to red. In create
            // mode it is itself a drag handle (1-minute snapping); the wake
            // handle is added after it, so overlapping hits favor the wake end.
            if let onBedTimeDrag {
                Circle()
                    .fill(accentColor)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
                    .shadow(radius: 1, y: 0.5)
                    .frame(width: handleHit, height: handleHit)
                    .contentShape(Circle())
                    .position(x: bedX, y: axisY)
                    .gesture(bedDragGesture(width: w, onBedTimeDrag))
            } else {
                Circle()
                    .fill(accentColor)
                    .frame(width: 12, height: 12)
                    .offset(x: bedX - 6)
            }

            // Now marker (edit mode): the ball wears the color the physical
            // light should currently show.
            if let now {
                let ledColor = SleepTimerLED.color(at: now, bedTime: bedTime, sleepEnd: sleepEnd)
                Circle()
                    .fill(ledColor)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: ledColor.opacity(0.6), radius: 4)
                    .offset(x: min(max(x(now) - 7, 0), w - 14))
            }

            // Draggable right handle with a generous hit area.
            ZStack {
                Circle()
                    .fill(accentColor)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
                    .shadow(radius: 1, y: 0.5)
            }
            .frame(width: handleHit, height: handleHit)
            .contentShape(Circle())
            .position(x: handleX, y: axisY)
            .gesture(dragGesture(width: w))
        }
        .frame(width: w, height: rowHeight, alignment: .leading)
        .coordinateSpace(name: coordSpace)
    }

    private func dragGesture(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordSpace))
            .onChanged { value in
                if dragDomainEnd == nil {
                    dragDomainEnd = sleepEnd.addingTimeInterval(headroom(after: sleepEnd))
                }
                guard let domEnd = dragDomainEnd, w > 0 else { return }
                let dom = domEnd.timeIntervalSince(sessionStart)
                guard dom > 0 else { return }
                let f = min(max(value.location.x / w, 0), 1)
                let raw = sessionStart.addingTimeInterval(Double(f) * dom)
                sleepEnd = clampAndSnap(raw)
            }
            .onEnded { _ in
                dragDomainEnd = nil
            }
    }

    private func bedDragGesture(width w: CGFloat, _ update: @escaping (Date) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordSpace))
            .onChanged { value in
                // Freeze the render domain exactly like the wake drag: bed time
                // feeds headroom(), so an unfrozen domain would chase the finger.
                if dragDomainEnd == nil {
                    dragDomainEnd = sleepEnd.addingTimeInterval(headroom(after: sleepEnd))
                }
                guard let domEnd = dragDomainEnd, w > 0 else { return }
                let dom = domEnd.timeIntervalSince(sessionStart)
                guard dom > 0 else { return }
                let f = min(max(value.location.x / w, 0), 1)
                let raw = sessionStart.addingTimeInterval(Double(f) * dom)
                // 1-minute snap; clamped to at least a minute out and clear of
                // the wake point's 30-minute minimum span.
                let t = raw.timeIntervalSinceReferenceDate
                let snapped = Date(timeIntervalSinceReferenceDate: (t / 60).rounded() * 60)
                let clamped = min(max(snapped, sessionStart.addingTimeInterval(60)),
                                  sleepEnd.addingTimeInterval(-30 * 60))
                update(clamped)
            }
            .onEnded { _ in
                dragDomainEnd = nil
            }
    }

    private func clampAndSnap(_ date: Date) -> Date {
        let t = date.timeIntervalSinceReferenceDate
        let snapped = Date(timeIntervalSinceReferenceDate: (t / snapStep).rounded() * snapStep)
        return min(max(snapped, effectiveMin), maximumSleepEnd)
    }

    /// Three labeled columns — Bed / Sleep / Wake — instead of loose values,
    /// so nothing floats without saying what it is.
    private var labels: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text("BED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(shortTime(bedTime))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .center, spacing: 1) {
                Text("SLEEP")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(durationText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text("WAKE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(shortTime(sleepEnd))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }
        }
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    private var durationText: String {
        let secs = max(0, Int(sleepEnd.timeIntervalSince(bedTime)))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 && m > 0 { return "\(h) hr \(m) min" }
        if h > 0 { return "\(h) hr" }
        return "\(m) min"
    }
}
