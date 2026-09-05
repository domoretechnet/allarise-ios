//
//  HoldPressStyle.swift
//  HaWake Alarm V2
//
//  Tactile "hold-to-confirm" treatment for the arm, skip, and snooze buttons.
//  Replaces the old gradient progress rings / glow with a physical 3D press:
//  the button sinks in (scale + deepening inner shadow) the longer it's held,
//  and a solid accent fill rises from the bottom to show progress. No ring,
//  no gradient.
//
//  Every layer here — the 0.32 rising fill, the 0.65 hold frame, and the wash
//  each call site paints behind its label — is a different opacity of ONE base
//  color. That is what gives the press its depth, and it is why a per-theme
//  accent override only has to move the base: the relationships survive and
//  nothing flattens. Callers pass that base in through `accent`, resolved by
//  `DeviceSettings.skipAccent(for:)` / `armAccent(for:)` so the override wins
//  and, when there is none, the theme's own slot renders unchanged.
//

import SwiftUI

struct HoldPressStyle: ViewModifier {
    /// 0…1 hold completion.
    var progress: CGFloat
    /// True while the finger is down (drives the immediate press-in).
    var isHolding: Bool
    /// Theme accent used for the rising fill and hold frame.
    var accent: Color
    var cornerRadius: CGFloat = 16

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius) }
    private var clamped: CGFloat { min(max(progress, 0), 1) }
    /// Inner-shadow thickness scales with the corner radius so small chips
    /// (skip/arm, r≈8) and large buttons (snooze, r≈16) both read right.
    private var shadowWidth: CGFloat { max(2.5, cornerRadius * 0.4) }

    /// Visible fill: the moment the finger lands it jumps to a small baseline so
    /// the press reads as "started" immediately. Progress is blended onto the
    /// remaining 88% — never clamped to a floor. A `max(clamped, 0.12)` here
    /// freezes the bar for the first 12% of the hold (3.6s of dead fill at a
    /// 30s duration) and stalls the *end* of the arm chip's disarm drain,
    /// which runs 1→0 (al-cd3).
    private var fillFraction: CGFloat { isHolding ? 0.12 + clamped * 0.88 : clamped }

    func body(content: Content) -> some View {
        content
            // Solid accent fill rising from the bottom = progress. Clean, flat.
            .overlay {
                GeometryReader { geo in
                    accent.opacity(0.32)
                        .frame(height: geo.size.height * fillFraction)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
            // Inner shadow → recessed / pressed-in look that deepens with the hold.
            .overlay {
                shape
                    .stroke(Color.black.opacity(0.6), lineWidth: shadowWidth)
                    .blur(radius: shadowWidth * 0.85)
                    .mask(shape.fill())
                    .opacity(isHolding ? Double(0.3 + 0.55 * clamped) : 0)
                    .allowsHitTesting(false)
            }
            // Thin solid accent frame while holding (not a gradient).
            .overlay {
                shape
                    .strokeBorder(accent.opacity(isHolding ? 0.65 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            // The physical press: sink in immediately, deeper as it fills.
            .scaleEffect(isHolding ? (0.97 - 0.035 * clamped) : 1.0)
            .brightness(isHolding ? -0.04 : 0)
            .animation(.easeOut(duration: 0.14), value: isHolding)
            .animation(.linear(duration: 0.05), value: clamped)
    }
}

extension View {
    /// Tactile hold-to-confirm press (see `HoldPressStyle`).
    func holdPress(progress: CGFloat, isHolding: Bool, accent: Color, cornerRadius: CGFloat = 16) -> some View {
        modifier(HoldPressStyle(progress: progress, isHolding: isHolding, accent: accent, cornerRadius: cornerRadius))
    }
}
