//
//  MissionTypeGlyph.swift
//  HaWake Alarm V2
//
//  Small animated "vignette" glyphs that replace the abstract SF Symbols on the
//  mission-type tiles. Each MissionType gets a compact, custom SwiftUI-drawn
//  scene that SHOWS what the mission is (a tap ripple, a rocking phone, a rolling
//  marble in a target, a dropping tetromino, …) rather than a symbol.
//
//  Usage:
//    MissionTypeGlyph(type: .balanceBall, accent: accent, animated: true, delay: 0.5)
//
//  Sizing: the glyph renders into a fixed ~44×28 content box (see `body`'s frame).
//  Drop it in wherever an `Image(systemName: type.iconName)` used to sit.
//
//  Animation model
//  ---------------
//  Motion is driven by `TimelineView(.animation)` at a capped 30 fps — it ticks
//  ONLY while the view is on-screen (SwiftUI stops the timeline when a Form row
//  scrolls away), and each scene is a tiny Canvas so a redraw is GPU-cheap even
//  during the "rest" majority of the loop where the drawn output doesn't change.
//  A per-loop `phase` (0…1) is derived from the timeline date plus a `delay`, so
//  tiles laid out in a grid animate on staggered offsets instead of in lockstep.
//  Math is the exception: it drives a `.numericText()` content transition from a
//  `.task` loop (discrete digit swaps, no per-frame work).
//
//  Reduce Motion: when `@Environment(\.accessibilityReduceMotion)` is on (or the
//  caller passes `animated: false`, as the static slot cards do), every scene
//  renders a single pleasant "settled" frame and no timeline/task runs.
//

import SwiftUI

// MARK: - Public glyph

struct MissionTypeGlyph: View {
    let type: MissionType
    var accent: Color = .accentColor
    /// When false, renders a static first frame (used by the slot cards).
    var animated: Bool = false
    /// Loop offset in seconds so grid tiles stagger instead of moving together.
    var delay: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Resolved motion flag — Reduce Motion always wins.
    private var isAnimating: Bool { animated && !reduceMotion }

    var body: some View {
        Group {
            switch type {
            case .none:          TapGlyph(accent: accent, animated: isAnimating, delay: delay)
            case .shake:         ShakeGlyph(accent: accent, animated: isAnimating, delay: delay)
            case .math:          MathGlyph(accent: accent, animated: isAnimating, delay: delay)
            case .balanceBall:   BalanceGlyph(accent: accent, animated: isAnimating, delay: delay)
            case .blockDrop:     BlockDropGlyph(accent: accent, animated: isAnimating, delay: delay)
            case .meteor:        MeteorGlyph(accent: accent, animated: isAnimating, delay: delay)
            case .homeAssistant: HomeAssistantGlyph(accent: accent, animated: isAnimating, delay: delay)
            case .alert:         AlertGlyph(accent: accent)
            }
        }
        .frame(width: 44, height: 28)
    }
}

// MARK: - Shared looping canvas

/// A Canvas whose draw closure is fed a looping `phase` in 0…1. When `animated`
/// it drives from a 30 fps `TimelineView(.animation)` (auto-paused off-screen);
/// otherwise it draws a single frame at `staticPhase`.
private struct LoopingCanvas: View {
    var animated: Bool
    var period: Double = 3.6
    var delay: Double = 0
    /// Phase to freeze at when not animating — pick each scene's "settled" look.
    var staticPhase: Double
    let draw: (inout GraphicsContext, CGSize, Double) -> Void

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { ctx, size in
                    draw(&ctx, size, phase(for: timeline.date))
                }
            }
        } else {
            Canvas { ctx, size in
                draw(&ctx, size, staticPhase)
            }
        }
    }

    private func phase(for date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate + delay
        let m = t.truncatingRemainder(dividingBy: period)
        return (m < 0 ? m + period : m) / period
    }
}

// MARK: - Small math helpers

private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

/// Smoothstep 0→1 over [a,b].
private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    guard b > a else { return x < a ? 0 : 1 }
    let t = clamp((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
}

// MARK: - Tap (.none)

/// A mini button being tapped: an accent circle that visibly depresses toward
/// its ground shadow (twice per loop), each press emitting an expanding ripple
/// ring. No hand/finger — the tap is shown by the thing being tapped, which
/// reads cleanly at tile size on any tile in light and dark.
private struct TapGlyph: View {
    let accent: Color
    let animated: Bool
    let delay: Double

    private static let period = 3.6
    private static let taps: [Double] = [0.08, 0.42]
    private static let tapDur = 0.16

    /// Two taps per loop: each a quick down-and-up (0→1→0) via a sine bump.
    private static func press(at p: Double) -> Double {
        var v = 0.0
        for t in taps where p >= t && p <= t + tapDur {
            v = max(v, sin(.pi * (p - t) / tapDur))
        }
        return v
    }

    var body: some View {
        // A mini button being tapped: the accent circle visibly depresses (shrinks
        // and drops toward its shadow) twice per loop, each press emitting an
        // expanding ripple ring. No hand — the tap is shown by the thing tapped.
        LoopingCanvas(animated: animated, period: Self.period, delay: delay, staticPhase: 0.30) { ctx, size, p in
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.52)
            let pr = Self.press(at: p)

            // Expanding tap-ripple rings from the button's rim.
            for t in Self.taps {
                let peak = t + Self.tapDur / 2
                let local = (p - peak) / 0.34
                guard local > 0, local < 1 else { continue }
                let r = 8.5 + local * 9.0
                let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                ctx.stroke(ring, with: .color(accent.opacity((1 - local) * 0.55)),
                           style: StrokeStyle(lineWidth: 1.6))
            }

            // Soft ground shadow that shrinks/dims as the button presses down.
            let shW = 11.0 * (1 - 0.35 * pr)
            let shH = 2.6 * (1 - 0.35 * pr)
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - shW / 2, y: center.y + 6.6, width: shW, height: shH)),
                     with: .color(.black.opacity(0.14 * (1 - 0.5 * pr))))

            // The button: solid accent circle that depresses on each tap.
            let r = 7.2 * (1 - 0.12 * pr)
            let yOff = pr * 1.8
            let btnRect = CGRect(x: center.x - r, y: center.y - r + yOff, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: btnRect), with: .color(accent))

            // Top inner highlight for a hint of depth; flattens while pressed.
            var hl = Path()
            hl.addArc(center: CGPoint(x: center.x, y: center.y + yOff - r * 0.12), radius: r * 0.6,
                      startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
            ctx.stroke(hl, with: .color(.white.opacity(0.5 * (1 - 0.4 * pr))),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }
}

// MARK: - Shake (.shake)

/// A rounded-rect phone silhouette rocking a few degrees, with two little motion
/// arcs flanking it that brighten with the rock.
private struct ShakeGlyph: View {
    let accent: Color
    let animated: Bool
    let delay: Double

    var body: some View {
        LoopingCanvas(animated: animated, delay: delay, staticPhase: 0.12) { ctx, size, p in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let maxAngle = 9.0

            // Rock during the first half of the loop, eased in/out to zero; rest flat.
            let window = 0.5
            var angle = 0.0
            if p < window {
                let u = p / window
                let envelope = sin(.pi * u)          // 0→1→0, still at both ends
                angle = maxAngle * envelope * sin(2 * .pi * u * 3)
            }
            let intensity = abs(angle) / maxAngle

            // Flanking motion arcs (brighten with the rock; faint at rest).
            let arcOpacity = 0.18 + 0.62 * intensity
            for side in [-1.0, 1.0] {
                var arc = Path()
                let ax = cx + side * 12
                arc.addArc(center: CGPoint(x: ax, y: cy), radius: 5.5,
                           startAngle: .degrees(side > 0 ? -35 : 145),
                           endAngle: .degrees(side > 0 ? 35 : 215),
                           clockwise: false)
                ctx.stroke(arc, with: .color(accent.opacity(arcOpacity)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }

            // Phone body, rotated about its center.
            var pctx = ctx
            pctx.translateBy(x: cx, y: cy)
            pctx.rotate(by: .degrees(angle))
            pctx.translateBy(x: -cx, y: -cy)

            let bodyW = 13.0, bodyH = 22.0
            let body = Path(roundedRect: CGRect(x: cx - bodyW / 2, y: cy - bodyH / 2, width: bodyW, height: bodyH),
                            cornerRadius: 4, style: .continuous)
            pctx.fill(body, with: .color(accent.opacity(0.22)))
            pctx.stroke(body, with: .color(accent), lineWidth: 1.8)
            // Speaker slit + home dot for a phone read.
            let slit = Path(roundedRect: CGRect(x: cx - 2.5, y: cy - bodyH / 2 + 2.4, width: 5, height: 1.4),
                            cornerRadius: 0.7)
            pctx.fill(slit, with: .color(accent.opacity(0.8)))
            let home = Path(ellipseIn: CGRect(x: cx - 1.4, y: cy + bodyH / 2 - 4, width: 2.8, height: 2.8))
            pctx.stroke(home, with: .color(accent.opacity(0.8)), lineWidth: 1)
        }
    }
}

// MARK: - Math (.math)

/// A tiny equation in rounded monospaced digits whose numbers roll over each
/// loop via `.numericText()`.
private struct MathGlyph: View {
    let accent: Color
    let animated: Bool
    let delay: Double

    private static let pairs: [(a: String, op: String, b: String)] = [
        ("2", "+", "3"), ("5", "−", "1"), ("4", "+", "4")
    ]
    @State private var idx = 0

    var body: some View {
        let pair = Self.pairs[idx]
        HStack(spacing: 0.5) {
            Text(pair.a).contentTransition(.numericText())
            Text(pair.op).padding(.horizontal, 0.5)
            Text(pair.b).contentTransition(.numericText())
        }
        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
        .foregroundStyle(accent)
        .task(id: animated) {
            guard animated else { return }
            try? await Task.sleep(for: .seconds(delay))
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3.2))
                if Task.isCancelled { break }
                withAnimation(.snappy(duration: 0.4)) {
                    idx = (idx + 1) % Self.pairs.count
                }
            }
        }
    }
}

// MARK: - Balance Ball (.balanceBall)

/// A true-green target ring (matching the in-game dismiss zone) with the app's
/// actual glass "cat's-eye" marble — a translucent sphere holding an
/// intertwined blue/red flame core and a white specular highlight — that rolls
/// out and settles back inside. The core rotates slightly as the marble rolls.
private struct BalanceGlyph: View {
    let accent: Color
    let animated: Bool
    let delay: Double

    // Flame-core colors, matching RealisticMarble's blue/red ribbon.
    private static let coreBlue = Color(red: 0.20, green: 0.33, blue: 0.82)
    private static let coreRed  = Color(red: 0.74, green: 0.16, blue: 0.18)
    // Brighter green for the hold-progress arc that traces the target ring.
    private static let progressGreen = Color(red: 0.30, green: 0.95, blue: 0.42)

    var body: some View {
        LoopingCanvas(animated: animated, delay: delay, staticPhase: 0.7) { ctx, size, p in
            let ringC = CGPoint(x: size.width * 0.60, y: size.height * 0.5)
            let ringR = 8.5
            let marbleR = 5.5
            let restX = ringC.x
            let outX = size.width * 0.15
            // Marble rolls out and back within the first ~42% of the loop, then
            // rests inside the ring for the remainder.
            let window = 0.42

            // Green target ring (semantic — the real dismiss zone is green).
            let ringRect = CGRect(x: ringC.x - ringR, y: ringC.y - ringR, width: ringR * 2, height: ringR * 2)
            // Base ring is deliberately dim so the bright hold-progress arc
            // reads clearly against it.
            ctx.fill(Path(ellipseIn: ringRect), with: .color(.green.opacity(0.14)))
            ctx.stroke(Path(ellipseIn: ringRect), with: .color(.green.opacity(0.4)),
                       style: StrokeStyle(lineWidth: 1.8))

            // Hold-progress arc: while the marble is settled inside the ring (the
            // rest portion of the loop), a brighter-green arc traces the ring's
            // circumference and grows toward ~70% — it "starts to complete" but
            // never finishes, then fades just before the marble rolls back out.
            if p >= window {
                let grow = clamp((p - window) / (0.91 - window), 0, 1)   // 0 → 1
                let frac = grow * 0.70                                    // ≤ ~70% of the circle
                let fade = 1.0 - smoothstep(0.93, 1.0, p)                 // fade before roll-out
                if frac > 0.001 {
                    var arc = Path()
                    arc.addArc(center: ringC, radius: ringR,
                               startAngle: .degrees(-90),
                               endAngle: .degrees(-90 + frac * 360),
                               clockwise: false)
                    ctx.stroke(arc, with: .color(Self.progressGreen.opacity(fade)),
                               style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                }
            }

            var mx = restX
            if p < window {
                let u = p / window
                let s = sin(.pi * u)                 // 0→1→0: out and back
                mx = restX - (restX - outX) * s
            }
            let mc = CGPoint(x: mx, y: ringC.y)
            // Rolling rotation: arc length / radius as the marble travels.
            let roll = (restX - mx) / marbleR

            let mRect = CGRect(x: mc.x - marbleR, y: mc.y - marbleR, width: marbleR * 2, height: marbleR * 2)
            let circle = Path(ellipseIn: mRect)

            // Soft contact shadow.
            ctx.fill(Path(ellipseIn: mRect.offsetBy(dx: 0, dy: 1.4)),
                     with: .color(.black.opacity(0.18)))

            // Interior (glass body + flame core + rim shade), clipped to the sphere.
            var mctx = ctx
            mctx.clip(to: circle)

            // Translucent glass body, lit from the upper-left.
            mctx.fill(circle, with: .radialGradient(
                Gradient(colors: [Color(white: 0.88).opacity(0.55), Color(white: 0.42).opacity(0.72)]),
                center: CGPoint(x: mc.x - marbleR * 0.3, y: mc.y - marbleR * 0.35),
                startRadius: 0, endRadius: marbleR * 1.35))

            // Two intertwined blue/red flame teardrops, rotated with the roll.
            func flame(_ color: Color, baseAngle: Double, dx: Double) {
                var f = mctx
                f.translateBy(x: mc.x, y: mc.y)
                f.rotate(by: .radians(roll + baseAngle))
                f.translateBy(x: dx, y: 0)
                let h = marbleR * 1.55, w = marbleR * 0.58
                var path = Path()
                path.move(to: CGPoint(x: 0, y: h * 0.45))
                path.addQuadCurve(to: CGPoint(x: 0, y: -h * 0.55), control: CGPoint(x: w, y: -h * 0.05))
                path.addQuadCurve(to: CGPoint(x: 0, y: h * 0.45), control: CGPoint(x: -w, y: -h * 0.05))
                f.fill(path, with: .color(color.opacity(0.92)))
            }
            flame(Self.coreBlue, baseAngle: -0.24, dx: -marbleR * 0.26)
            flame(Self.coreRed,  baseAngle:  0.24, dx:  marbleR * 0.26)

            // Rim shade for spherical depth (darkens toward the edge).
            mctx.fill(circle, with: .radialGradient(
                Gradient(stops: [.init(color: .clear, location: 0.5),
                                 .init(color: .black.opacity(0.28), location: 1.0)]),
                center: mc, startRadius: 0, endRadius: marbleR))

            // Subtle glass rim + white specular highlight (on the unclipped ctx).
            ctx.stroke(circle, with: .color(.white.opacity(0.35)), lineWidth: 0.7)
            let hi = marbleR * 0.5
            ctx.fill(Path(ellipseIn: CGRect(x: mc.x - marbleR * 0.42 - hi / 2,
                                            y: mc.y - marbleR * 0.5 - hi / 2,
                                            width: hi, height: hi)),
                     with: .color(.white.opacity(0.92)))
        }
    }
}

// MARK: - Block Drop (.blockDrop)

/// A small board whose bottom row is one cell short of complete; a real vertical
/// I-tetromino drops into the gap, completing the line — which flashes white and
/// clears as the remnant settles, then resets. Drawn with the game's real piece
/// colors/bevel (BlockDropMissionView.drawBlock).
private struct BlockDropGlyph: View {
    let accent: Color
    let animated: Bool
    let delay: Double

    private let cols = 5
    private let rows = 4
    private let gapCol = 4

    var body: some View {
        LoopingCanvas(animated: animated, delay: delay, staticPhase: 0.24) { ctx, size, p in
            let cell = 6.0
            let boardW = cell * Double(cols)
            let boardH = cell * Double(rows)
            let ox = (size.width - boardW) / 2
            let oy = (size.height - boardH) / 2
            let boardRect = CGRect(x: ox - 1.5, y: oy - 1.5, width: boardW + 3, height: boardH + 3)

            // Board surface (kept chrome).
            let bg = Path(roundedRect: boardRect, cornerRadius: 4, style: .continuous)
            ctx.fill(bg, with: .color(Color(uiColor: .secondarySystemBackground)))
            ctx.clip(to: bg)

            func rect(col: Double, rowF: Double) -> CGRect {
                CGRect(x: ox + col * cell, y: oy + rowF * cell, width: cell, height: cell)
            }

            // Faint pit texture.
            for r in 0..<rows {
                for c in 0..<cols {
                    let pit = Path(roundedRect: rect(col: Double(c), rowF: Double(r)).insetBy(dx: 0.8, dy: 0.8),
                                   cornerRadius: cell * 0.16, style: .continuous)
                    ctx.fill(pit, with: .color(.primary.opacity(0.05)))
                }
            }

            let bottom = Double(rows - 1)
            func garbageCol(_ c: Int) { BlockDropMissionView.drawBlock(&ctx, rect: rect(col: Double(c), rowF: bottom), cell: .garbage) }
            func iCell(_ rowF: Double) { BlockDropMissionView.drawBlock(&ctx, rect: rect(col: Double(gapCol), rowF: rowF), cell: .i) }

            // Static frame: I-piece mid-fall above the nearly-complete row.
            guard animated else {
                for c in 0..<(cols - 1) { garbageCol(c) }
                for i in 0..<4 { iCell(-1.0 + Double(i)) }
                return
            }

            let fallEnd = 0.42, flashEnd = 0.54, clearEnd = 0.66

            // Nearly-complete bottom row (one gap at gapCol) up until it clears.
            if p < flashEnd {
                for c in 0..<(cols - 1) { garbageCol(c) }
            }

            if p < fallEnd {
                // FALL: the vertical I-piece drops into the well.
                let top = -4.5 + 4.5 * smoothstep(0, fallEnd, p)
                for i in 0..<4 { iCell(top + Double(i)) }
            } else if p < flashEnd {
                // LOCK + LINE FLASH: bottom row completed, brightening to white.
                for i in 0..<4 { iCell(Double(i)) }
                let flashA = 0.85 * sin(.pi * (p - fallEnd) / (flashEnd - fallEnd))
                for c in 0..<cols {
                    let f = Path(roundedRect: rect(col: Double(c), rowF: bottom).insetBy(dx: 0.8, dy: 0.8),
                                 cornerRadius: cell * 0.2, style: .continuous)
                    ctx.fill(f, with: .color(.white.opacity(flashA)))
                }
            } else if p < clearEnd {
                // CLEAR: the completed row vanishes; the I remnant drops one row.
                let du = smoothstep(flashEnd, clearEnd, p)
                for i in 0..<3 { iCell(Double(i) + du) }
            } else {
                // REST: remnant settled at the foot of the well before the reset.
                for i in 1...3 { iCell(Double(i)) }
            }
        }
    }
}

// MARK: - Meteor Defense (.meteor)

/// A tiny night panel: a rocky meteor falls while the pod's bolt rises to meet
/// it — they collide in a brief burst ring, then the loop resets. Mirrors the
/// real mission's look (radial-gradient meteor, capsule pod, accent bolt).
private struct MeteorGlyph: View {
    let accent: Color
    let animated: Bool
    let delay: Double

    var body: some View {
        LoopingCanvas(animated: animated, delay: delay, staticPhase: 0.3) { ctx, size, p in
            let panel = CGRect(x: 2, y: 0, width: size.width - 4, height: size.height)
            let bg = Path(roundedRect: panel, cornerRadius: 5, style: .continuous)
            ctx.fill(bg, with: .linearGradient(
                Gradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22),
                                  Color(red: 0.16, green: 0.17, blue: 0.30)]),
                startPoint: panel.origin, endPoint: CGPoint(x: panel.minX, y: panel.maxY)))
            ctx.clip(to: bg)

            // Stars.
            for (sx, sy) in [(0.22, 0.18), (0.78, 0.12), (0.55, 0.3), (0.15, 0.55), (0.85, 0.5)] {
                let r = 0.9
                ctx.fill(Path(ellipseIn: CGRect(x: panel.minX + panel.width * sx, y: panel.height * sy, width: r, height: r)),
                         with: .color(.white.opacity(0.5)))
            }

            let midX = panel.midX
            let podY = panel.maxY - 5.5

            // Pod: capsule + accent dome.
            let body = CGRect(x: midX - 6.5, y: podY, width: 13, height: 4)
            ctx.fill(Path(roundedRect: body, cornerRadius: 2), with: .color(Color(white: 0.8)))
            ctx.fill(Path(ellipseIn: CGRect(x: midX - 2, y: podY - 3, width: 4, height: 4)), with: .color(accent))

            let meteorR = 4.2
            let meteorTopY = -meteorR
            let hitY = panel.height * 0.42

            func drawMeteor(at y: Double) {
                let rect = CGRect(x: midX - meteorR, y: y - meteorR, width: meteorR * 2, height: meteorR * 2)
                ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(colors: [Color(red: 0.88, green: 0.66, blue: 0.48),
                                      Color(red: 0.72, green: 0.48, blue: 0.34),
                                      Color(red: 0.45, green: 0.28, blue: 0.20)]),
                    center: CGPoint(x: midX - 1.5, y: y - 1.5), startRadius: 0, endRadius: meteorR * 1.6))
                ctx.fill(Path(ellipseIn: CGRect(x: midX + 0.6, y: y + 0.4, width: 1.6, height: 1.6)),
                         with: .color(Color(red: 0.45, green: 0.28, blue: 0.20).opacity(0.6)))
            }

            // Static frame: meteor mid-fall over the pod.
            guard animated else {
                drawMeteor(at: panel.height * 0.3)
                return
            }

            let hitP = 0.55, burstEnd = 0.78

            if p < hitP {
                // Meteor falls toward the collision point.
                let y = meteorTopY + (hitY - meteorTopY) * smoothstep(0, hitP, p)
                drawMeteor(at: y)
                // Bolt rises once the meteor is on its way.
                if p > 0.18 {
                    let bp = smoothstep(0.18, hitP, p)
                    let by = (podY - 4) + (hitY + meteorR + 2 - (podY - 4)) * bp
                    ctx.fill(Path(roundedRect: CGRect(x: midX - 1, y: by, width: 2, height: 5), cornerRadius: 1),
                             with: .color(accent))
                }
            } else if p < burstEnd {
                // Burst ring expands and fades.
                let bp = smoothstep(hitP, burstEnd, p)
                let r = meteorR * (0.8 + 1.6 * bp)
                ctx.stroke(Path(ellipseIn: CGRect(x: midX - r, y: hitY - r, width: r * 2, height: r * 2)),
                           with: .color(Color(red: 0.88, green: 0.66, blue: 0.48).opacity(0.9 * (1 - bp))),
                           lineWidth: 1.6)
                ctx.fill(Path(ellipseIn: CGRect(x: midX - r * 0.4, y: hitY - r * 0.4, width: r * 0.8, height: r * 0.8)),
                         with: .color(.white.opacity(0.6 * (1 - bp))))
            }
            // Tail of the loop: quiet sky before the reset.
        }
    }
}

// MARK: - Home Assistant (.homeAssistant)

/// A house outline with two signal-wave arcs that pulse outward above it.
private struct HomeAssistantGlyph: View {
    let accent: Color
    let animated: Bool
    let delay: Double

    var body: some View {
        LoopingCanvas(animated: animated, delay: delay, staticPhase: 0.25) { ctx, size, p in
            let cx = size.width * 0.5
            let baseY = size.height * 0.86
            let roofY = size.height * 0.44
            let midY = (baseY + roofY) / 2
            let hw = 8.0

            // Signal-wave arcs, emanating from the roof apex.
            let apex = CGPoint(x: cx, y: roofY)
            let window = 0.5
            func wave(_ index: Int) {
                let baseR = 3.5 + Double(index) * 4.0
                var r = baseR
                var opacity = 0.22
                if p < window {
                    let u = clamp(p / window - Double(index) * 0.18, 0, 1)
                    r = baseR + u * 5.0
                    opacity = (1 - u) * 0.75 + 0.15
                }
                var arc = Path()
                arc.addArc(center: apex, radius: r,
                           startAngle: .degrees(-150), endAngle: .degrees(-30), clockwise: false)
                ctx.stroke(arc, with: .color(accent.opacity(opacity)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            wave(0)
            wave(1)

            // House body.
            var house = Path()
            house.move(to: CGPoint(x: cx - hw, y: baseY))
            house.addLine(to: CGPoint(x: cx - hw, y: midY))
            house.addLine(to: CGPoint(x: cx, y: roofY))
            house.addLine(to: CGPoint(x: cx + hw, y: midY))
            house.addLine(to: CGPoint(x: cx + hw, y: baseY))
            house.closeSubpath()
            ctx.fill(house, with: .color(accent.opacity(0.20)))
            ctx.stroke(house, with: .color(accent), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))

            // Door.
            let door = Path(roundedRect: CGRect(x: cx - 1.8, y: baseY - 5, width: 3.6, height: 5),
                            cornerRadius: 0.8)
            ctx.stroke(door, with: .color(accent.opacity(0.85)), lineWidth: 1)
        }
    }
}

// MARK: - Alert (.alert) — not shown in pickers; trivial static bell.

private struct AlertGlyph: View {
    let accent: Color
    var body: some View {
        Image(systemName: "bell.fill")
            .font(.title3)
            .foregroundStyle(accent)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Mission glyphs") {
    let accent = Color.blue
    return ScrollView {
        VStack(spacing: 24) {
            ForEach([false, true], id: \.self) { animated in
                Text(animated ? "Animated" : "Static").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    ForEach(Array(MissionType.userVisible.enumerated()), id: \.element) { i, type in
                        VStack(spacing: 6) {
                            MissionTypeGlyph(type: type, accent: accent, animated: animated, delay: Double(i) * 0.5)
                            Text(type.shortLabel).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 70)
                        .background(RoundedRectangle(cornerRadius: 16).fill(accent.opacity(0.28)))
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
    }
}
#endif
