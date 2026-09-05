//
//  RadioPlayCircle.swift
//  HaWake Alarm V2
//
//  The one play/pause/stop circle used everywhere a radio station can be
//  started or previewed. Before this existed, seven copies of the same button
//  were inlined across five files, each deriving its icon from a different
//  source (RadioPlayerManager.state, a raw `@State AVPlayer?`, a local Bool) —
//  so none of them could show that a station was still CONNECTING. A station
//  that takes ten seconds to buffer looked identical to one already playing.
//
//  The connecting state is passed in rather than read from a manager, because
//  the alarm-editor and sleep-sound preview buttons drive bare AVPlayers that
//  RadioPlayerManager never sees.
//

import SwiftUI

struct RadioPlayCircle: View {
    /// How the circle is filled. `.solid` paints an accent disc with a white
    /// glyph (station rows, now-playing cards); `.material` paints an accent
    /// glyph on ultraThinMaterial (the mini player over artwork, and the
    /// active-row play/pause bubbles).
    enum Fill {
        case solid(Color)
        case material(Color)
    }

    /// SF Symbol shown when idle — varies by context: "play.fill" everywhere,
    /// then "pause.fill" for real sessions vs "stop.fill" for previews.
    let systemImage: String
    /// Replaces the glyph with an indeterminate spinner while true.
    let isConnecting: Bool
    let diameter: CGFloat
    let fill: Fill

    /// Drives the continuous rotation. Kept in the view (not derived from a
    /// clock) so the animation starts fresh each time the spinner appears.
    @State private var spinning = false

    private var foreground: Color {
        switch fill {
        case .solid: return .white
        case .material(let accent): return accent
        }
    }

    var body: some View {
        ZStack {
            switch fill {
            case .solid(let accent):
                Circle().fill(accent)
            case .material:
                Circle().fill(.ultraThinMaterial)
            }

            if isConnecting {
                // A ~70% arc reads as motion at every size we use (24–36pt),
                // where a full ring would look static while it spins.
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(
                        foreground,
                        style: StrokeStyle(lineWidth: max(1.5, diameter * 0.09), lineCap: .round)
                    )
                    .frame(width: diameter * 0.5, height: diameter * 0.5)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(
                        .linear(duration: 0.85).repeatForever(autoreverses: false),
                        value: spinning
                    )
                    .onAppear { spinning = true }
                    .onDisappear { spinning = false }
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: diameter * 0.42, weight: .medium))
                    .foregroundStyle(foreground)
            }
        }
        .frame(width: diameter, height: diameter)
        // The spinner is decorative; the state it represents belongs on the
        // button that owns this view, so VoiceOver hears one coherent label.
        .accessibilityHidden(true)
    }
}
