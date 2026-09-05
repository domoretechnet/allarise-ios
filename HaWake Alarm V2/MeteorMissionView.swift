//
//  MeteorMissionView.swift
//  HaWake Alarm V2
//
//  "Meteor Defense" dismissal mission: soft glossy meteors drift down a night-sky
//  panel; the player drags a hovering pod that fires light darts upward while a
//  finger is held on the panel. Destroying N meteors (per difficulty) dismisses
//  the alarm. Meteors that reach the shield line at the bottom just shatter
//  harmlessly — progress never goes backward, so the mission can never dead-end
//  (mirrors Block Drop's board-reset rule).
//
//  Visual identity is deliberately ORIGINAL: rounded radial-gradient meteors with
//  crater specks (drawn like the balance mission's marble), a capsule pod with a
//  glass dome, and a shimmering shield line — no pixel-art sprites, no marching
//  formations, no borrowed names or sounds. Gameplay "shoot falling objects" is a
//  mechanic; the expression here is ours.
//
//  Controls: drag anywhere on the panel to slide the pod. Firing happens while
//  the finger is DOWN — no tapping per shot, but the mission can't complete
//  itself if the player falls back asleep. Letting go leaves a short momentum
//  burst (5 bolts the first time, 1 after that) before the pod powers down and
//  a "hold to fire" cue appears.
//
//  KEEP MOVING: a pod that sits still for 2 seconds gets an on-panel "Keep
//  moving!" warning (with a haptic); only if it STILL hasn't moved 2 seconds
//  after that does the destroyed count wipe back to the full target. Moving
//  during the warning window cancels it with no penalty — slow tracking is
//  play, and a warned player deserves a beat to react. Leaked meteors still
//  cost nothing — the only way to lose progress is to keep ignoring the
//  warning, which closes the "park the finger under the spawn column and doze"
//  loophole while leaving the mission impossible to dead-end.
//

import SwiftUI
import Combine

// MARK: - Config

/// Resolved tuning for one game: the mission's difficulty preset with any
/// per-alarm overrides applied, clamped to sane gameplay bounds (mirrors
/// BlockDropConfig).
struct MeteorConfig {
    var targets = 12
    var fireInterval = 0.55
    var descentSpeed: CGFloat = 38
    var spawnInterval = 1.2
    var maxConcurrent = 5

    init() {}

    init(mission: Mission) {
        let difficulty = mission.meteorDifficulty
        targets = min(max(mission.effectiveMeteorTargets, 1), 60)
        fireInterval = min(max(mission.effectiveMeteorFireInterval, 0.2), 2.0)
        descentSpeed = difficulty.descentSpeed
        spawnInterval = difficulty.spawnInterval
        maxConcurrent = difficulty.maxConcurrent
    }
}

// MARK: - Game model

/// Continuous-motion engine on a 30 Hz tick. All positions are in PANEL points
/// (the view reports its size before start), meteors sway on a sine so pure
/// camping under the spawn column doesn't trivially clear the wave.
@MainActor
final class MeteorGameModel: ObservableObject {
    struct Meteor: Identifiable {
        let id = UUID()
        var x: CGFloat            // sway CENTER, pts
        var y: CGFloat            // pts, grows downward
        var radius: CGFloat
        var swayPhase: Double
        var swayAmplitude: CGFloat
        var tint: Int             // 0...2, picks one of three meteor palettes
        var spin: Double          // crater-pattern seed

        /// Rendered x after sway.
        func renderX(time: Double) -> CGFloat {
            x + swayAmplitude * CGFloat(sin(time * 0.9 + swayPhase))
        }
    }

    struct Bolt: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
    }

    struct Burst: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
        var radius: CGFloat
        var age: Double = 0       // 0 → 1 over burstLifetime
        var tint: Int
    }

    // Published render state
    @Published private(set) var meteors: [Meteor] = []
    @Published private(set) var bolts: [Bolt] = []
    @Published private(set) var bursts: [Burst] = []
    @Published private(set) var destroyed = 0
    @Published var podX: CGFloat = 0.5 * 320   // pts; re-centered in start()
    @Published private(set) var shieldFlash: Double = 0
    @Published private(set) var completed = false
    @Published private(set) var isHolding = false
    /// Bolts still owed after the finger lifted (momentum burst).
    @Published private(set) var graceShotsRemaining = 0
    /// Bumped every time a stalled pod wipes progress (see `idleWarnInterval`
    /// / `idleGraceInterval`), so the view can flash a "meteors reset" notice.
    /// A counter rather than a Bool so back-to-back resets each register.
    @Published private(set) var idleResets = 0
    /// True while the pod has been parked past the warning threshold but the
    /// grace window is still open — the view shows "Keep moving!" and any real
    /// travel clears it before the reset lands.
    @Published private(set) var idleWarningActive = false
    private(set) var elapsed: Double = 0

    /// True when the pod is powered down and the player must touch to resume.
    var needsHold: Bool { !isHolding && graceShotsRemaining == 0 }

    var targetCount: Int { config.targets }

    var onCompleted: (() -> Void)?
    /// Fired only when the pod travels a meaningful distance (see
    /// `activityDistance`) so the host can refresh its grace pause window.
    /// Deliberately NOT fired on destroys or micro-jitter: a camping pod's
    /// passive kills and a resting finger must not freeze the countdown —
    /// only real aiming does.
    var onActivity: (() -> Void)?

    private(set) var config = MeteorConfig()
    private var panelSize: CGSize = .zero
    private var timer: Timer?
    private var timeSinceSpawn: Double = 0
    private var timeSinceShot: Double = 0
    private var releaseCount = 0
    /// Anchor for the movement-based activity ping: the pod x at the last
    /// counted activity. Re-anchored on every ping and on each new touch.
    private var lastActivityX: CGFloat = 0

    /// Seconds the pod may sit still before the "Keep moving!" warning shows.
    /// A parked finger under the spawn column racks up passive kills, which is
    /// the one way this mission could be beaten while half asleep; wiping the
    /// count makes continuous aiming the only route to the end.
    private let idleWarnInterval: Double = 2.0
    /// Seconds AFTER the warning before progress actually resets to the full
    /// target. Start moving within this window and nothing is lost — the
    /// penalty is for ignoring the warning, not for pausing mid-aim.
    private let idleGraceInterval: Double = 2.0
    /// Travel (pts) that counts as "still moving" for the idle timer. MUCH
    /// smaller than `activityDistance`: slowly tracking one meteor is real play
    /// and must not cost the player their progress — only a genuinely parked
    /// pod does. (The 12pt ping is a different, coarser question: is the player
    /// engaged enough to pause the grace countdown.)
    private let idleMoveDistance: CGFloat = 4
    /// Seconds since the pod last moved meaningfully, and the x it was at then.
    private var timeSinceMove: Double = 0
    private var lastMoveX: CGFloat = 0

    private let firstReleaseGraceShots = 5
    private let repeatReleaseGraceShots = 1
    /// Pod travel (pts from the anchor) that counts as one activity ping.
    /// Big enough that a stationary finger's jitter never triggers it, small
    /// enough that any genuine aim adjustment does.
    private let activityDistance: CGFloat = 12

    private let tick: Double = 1.0 / 30.0
    private let boltSpeed: CGFloat = 420      // pts/s upward
    private let burstLifetime: Double = 0.45
    private let podHalfWidth: CGFloat = 30

    func start(config: MeteorConfig, panelSize: CGSize) {
        self.config = config
        self.panelSize = panelSize
        meteors = []
        bolts = []
        bursts = []
        destroyed = 0
        elapsed = 0
        timeSinceSpawn = 10   // spawn the first meteor immediately
        timeSinceShot = 0
        completed = false
        isHolding = false
        graceShotsRemaining = 0
        releaseCount = 0
        idleResets = 0
        idleWarningActive = false
        podX = panelSize.width / 2
        lastMoveX = podX
        lastActivityX = podX
        timeSinceMove = 0

        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Drag input: clamp the pod inside the panel. Activity pings only on
    /// meaningful travel from the anchor — resting a finger on the panel does
    /// not read as playing.
    func movePod(to x: CGFloat) {
        guard panelSize.width > 0 else { return }
        podX = min(max(x, podHalfWidth), panelSize.width - podHalfWidth)
        // Any real travel keeps the idle-reset timer at bay (small threshold)
        // and withdraws an open "Keep moving!" warning — moving inside the
        // grace window means no penalty.
        if abs(podX - lastMoveX) >= idleMoveDistance {
            lastMoveX = podX
            timeSinceMove = 0
            idleWarningActive = false
        }
        // Bigger travel additionally pings the host's grace-pause window.
        if abs(podX - lastActivityX) >= activityDistance {
            lastActivityX = podX
            onActivity?()
        }
    }

    /// Finger down/up. Firing only runs while holding; letting go grants a
    /// small momentum burst (generous the first time, a single bolt after)
    /// so the mission can't complete itself if the player dozes off.
    func setHolding(_ holding: Bool) {
        guard holding != isHolding else { return }
        isHolding = holding
        if holding {
            graceShotsRemaining = 0
            // A fresh touch must actually travel before it counts as activity —
            // but it does buy a clean 2s idle window to get moving in.
            lastActivityX = podX
            lastMoveX = podX
            timeSinceMove = 0
            idleWarningActive = false
        } else {
            releaseCount += 1
            graceShotsRemaining = releaseCount == 1 ? firstReleaseGraceShots : repeatReleaseGraceShots
        }
    }

    private func step() {
        guard !completed, panelSize != .zero else { return }
        elapsed += tick

        // Stalled pod → warn first, then progress back to the full target.
        // Deliberately runs whether or not the finger is down: "not moving" is
        // the condition, and a held-but-parked pod is exactly the camping case
        // this closes. Only engages when there IS progress to lose, so the
        // pre-first-kill idle at mission start is silent. Movement clears the
        // warning in movePod / setHolding via timeSinceMove = 0.
        timeSinceMove += tick
        if destroyed > 0 {
            if timeSinceMove >= idleWarnInterval + idleGraceInterval {
                destroyed = 0
                timeSinceMove = 0
                idleWarningActive = false
                idleResets += 1
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            } else if timeSinceMove >= idleWarnInterval && !idleWarningActive {
                idleWarningActive = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }

        // Spawn — capped concurrency keeps the panel readable.
        timeSinceSpawn += tick
        if timeSinceSpawn >= config.spawnInterval && meteors.count < config.maxConcurrent {
            timeSinceSpawn = 0
            spawnMeteor()
        }

        // Fire from the pod dome — only while held, or during the short
        // momentum burst right after a release.
        timeSinceShot += tick
        if isHolding || graceShotsRemaining > 0 {
            if timeSinceShot >= config.fireInterval {
                timeSinceShot = 0
                bolts.append(Bolt(x: podX, y: panelSize.height - podBaseInset - 26))
                if !isHolding { graceShotsRemaining -= 1 }
            }
        } else {
            // Keep the cadence primed so the first bolt comes out promptly
            // when the player grabs the pod again.
            timeSinceShot = min(timeSinceShot, config.fireInterval)
        }

        // Advance bolts.
        for i in bolts.indices {
            bolts[i].y -= boltSpeed * tick
        }
        bolts.removeAll { $0.y < -20 }

        // Advance meteors; leakers shatter on the shield (no progress penalty).
        var leaked = false
        for i in meteors.indices {
            meteors[i].y += config.descentSpeed * tick
        }
        let shieldY = panelSize.height - shieldInset
        meteors.removeAll { m in
            if m.y + m.radius >= shieldY {
                leaked = true
                bursts.append(Burst(x: m.renderX(time: elapsed), y: shieldY - 6, radius: m.radius * 0.8, tint: m.tint))
                return true
            }
            return false
        }
        if leaked {
            shieldFlash = 1
        } else if shieldFlash > 0 {
            shieldFlash = max(0, shieldFlash - tick * 2.5)
        }

        // Bolt ↔ meteor collisions.
        var destroyedIDs: Set<UUID> = []
        var spentBolts: Set<UUID> = []
        for bolt in bolts {
            for meteor in meteors where !destroyedIDs.contains(meteor.id) {
                let dx = meteor.renderX(time: elapsed) - bolt.x
                let dy = meteor.y - bolt.y
                if dx * dx + dy * dy <= (meteor.radius + 6) * (meteor.radius + 6) {
                    destroyedIDs.insert(meteor.id)
                    spentBolts.insert(bolt.id)
                    break
                }
            }
        }
        if !destroyedIDs.isEmpty {
            for meteor in meteors where destroyedIDs.contains(meteor.id) {
                bursts.append(Burst(x: meteor.renderX(time: elapsed), y: meteor.y, radius: meteor.radius, tint: meteor.tint))
            }
            meteors.removeAll { destroyedIDs.contains($0.id) }
            bolts.removeAll { spentBolts.contains($0.id) }
            destroyed += destroyedIDs.count
            // No onActivity here: kills are the RESULT of aiming — the movement
            // that earned them already pinged. Letting kills refresh the pause
            // would let a camped pod freeze the countdown forever.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if destroyed >= targetCount {
                completed = true
                stop()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCompleted?()
                return
            }
        }

        // Age bursts.
        for i in bursts.indices {
            bursts[i].age += tick / burstLifetime
        }
        bursts.removeAll { $0.age >= 1 }
    }

    private func spawnMeteor() {
        let radius = CGFloat.random(in: 16...24)
        let amplitude = CGFloat.random(in: 10...34)
        let margin = radius + amplitude + 6
        let x = CGFloat.random(in: margin...(max(margin + 1, panelSize.width - margin)))
        meteors.append(Meteor(
            x: x,
            y: -radius,
            radius: radius,
            swayPhase: Double.random(in: 0...(2 * .pi)),
            swayAmplitude: amplitude,
            tint: Int.random(in: 0...2),
            spin: Double.random(in: 0...(2 * .pi))
        ))
    }

    // Layout constants shared with the view
    let shieldInset: CGFloat = 54
    let podBaseInset: CGFloat = 64
}

// MARK: - Mission view

struct MeteorMissionView: View {
    let mission: Mission
    let onComplete: () -> Void
    var onEngaged: (() -> Void)? = nil
    var onActivity: (() -> Void)? = nil
    /// Fired the moment the finger lifts, so the host can cancel any open
    /// activity-pause window — the grace countdown resumes immediately on
    /// release instead of coasting through the window's tail.
    var onReleased: (() -> Void)? = nil
    var gracePeriodActive: Bool = false
    var gracePeriodRemaining: TimeInterval = 0
    var graceTotal: TimeInterval = 0
    var alarmColors: AlarmColorCustomization = .default
    /// Accent from the main app theme (progress, grace ring, pod glow).
    var accent: Color = .accentColor
    var compact: Bool = false

    @StateObject private var game = MeteorGameModel()
    @State private var hasEngaged = false
    @State private var hintPulse = false
    /// Shows the "keep moving" notice for a beat after an idle reset, so the
    /// counter jumping back up never reads as a bug.
    @State private var showIdleResetNotice = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 14) {
                if !compact { header }
                progressBar
                panel
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 72)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if gracePeriodActive && gracePeriodRemaining > 0 {
                MissionGracePill(remaining: gracePeriodRemaining, total: graceTotal, accent: accent)
                    .padding(.trailing, 22)
                    .padding(.bottom, 26)
            }
        }
        .onDisappear { game.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Blast the falling meteors")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(max(0, game.targetCount - game.destroyed))")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.25), value: game.destroyed)
                    Text(game.targetCount - game.destroyed == 1 ? "meteor left" : "meteors left")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var progressBar: some View {
        let progress = min(1, Double(game.destroyed) / Double(max(1, game.targetCount)))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(uiColor: .tertiarySystemFill))
                Capsule()
                    .fill(accent)
                    .frame(width: max(8, geo.size.width * progress))
                    .opacity(progress > 0 ? 1 : 0)
            }
        }
        .frame(height: 10)
    }

    // MARK: Sky panel

    private var panel: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                Canvas { ctx, size in
                    drawSky(&ctx, size: size)
                    drawShield(&ctx, size: size)
                    for burst in game.bursts { drawBurst(&ctx, burst) }
                    for bolt in game.bolts { drawBolt(&ctx, bolt) }
                    for meteor in game.meteors { drawMeteor(&ctx, meteor, time: game.elapsed) }
                    drawPod(&ctx, size: size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { holdToFireHint }
            // Panel-anchored (not header-anchored) so it also shows in compact
            // mode, where the header and its counter are hidden.
            .overlay(alignment: .top) { idleResetNotice }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        engageIfNeeded()
                        game.setHolding(true)
                        game.movePod(to: value.location.x)
                    }
                    .onEnded { _ in
                        game.setHolding(false)
                        onReleased?()
                    }
            )
            .onAppear {
                game.onCompleted = onComplete
                game.onActivity = onActivity
                game.start(config: MeteorConfig(mission: mission), panelSize: geo.size)
            }
            .onChange(of: game.idleResets) { _, newValue in
                guard newValue > 0 else { return }   // start() zeroing it isn't a reset
                withAnimation(.snappy(duration: 0.2)) { showIdleResetNotice = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    // Only this reset's own timer may hide it — a reset that
                    // landed while we slept owns the notice now.
                    guard game.idleResets == newValue else { return }
                    withAnimation(.easeOut(duration: 0.3)) { showIdleResetNotice = false }
                }
            }
        }
    }

    private func engageIfNeeded() {
        guard !hasEngaged else { return }
        hasEngaged = true
        onEngaged?()
    }

    /// Pulsing prompt shown whenever the pod is powered down — at mission start
    /// and after every release once the momentum burst runs out.
    @ViewBuilder private var holdToFireHint: some View {
        if game.needsHold && !game.completed {
            HStack(spacing: 7) {
                Image(systemName: "hand.draw.fill")
                    .font(.subheadline)
                Text("Hold & slide to fire")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(accent.opacity(0.85), in: Capsule())
            .opacity(hintPulse ? 1 : 0.55)
            .scaleEffect(hintPulse ? 1 : 0.96)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: hintPulse)
            .padding(.bottom, game.podBaseInset + 32)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .onAppear { hintPulse = true }
            .onDisappear { hintPulse = false }
        }
    }

    /// Two-stage idle notice. While the grace window is open an amber
    /// "Keep moving!" warning shows — start moving and it just goes away.
    /// If the reset actually lands, the red notice takes over for two seconds
    /// so the counter jumping back to the full target reads as a rule, not a
    /// glitch.
    @ViewBuilder private var idleResetNotice: some View {
        ZStack {
            if showIdleResetNotice && !game.completed {
                noticePill(icon: "arrow.counterclockwise",
                           text: "Meteors reset — keep moving",
                           color: .red)
            } else if game.idleWarningActive && !game.completed {
                noticePill(icon: "exclamationmark.triangle.fill",
                           text: "Keep moving!",
                           color: .orange)
            }
        }
        .animation(.snappy(duration: 0.2), value: game.idleWarningActive)
    }

    private func noticePill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.85), in: Capsule())
        .padding(.top, 16)
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Drawing

    /// Three meteor palettes — warm rock, cool slate, dusk violet. All soft and
    /// rounded; nothing pixelated, nothing creature-like.
    private static let meteorPalettes: [(body: Color, light: Color, dark: Color)] = [
        (Color(red: 0.72, green: 0.48, blue: 0.34), Color(red: 0.88, green: 0.66, blue: 0.48), Color(red: 0.45, green: 0.28, blue: 0.20)),
        (Color(red: 0.48, green: 0.55, blue: 0.64), Color(red: 0.68, green: 0.75, blue: 0.83), Color(red: 0.29, green: 0.34, blue: 0.42)),
        (Color(red: 0.56, green: 0.45, blue: 0.68), Color(red: 0.74, green: 0.63, blue: 0.86), Color(red: 0.35, green: 0.27, blue: 0.45)),
    ]

    private func drawSky(_ ctx: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.18),
                              Color(red: 0.12, green: 0.13, blue: 0.26)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        // Fixed pseudo-random starfield — deterministic so it doesn't twinkle-jump.
        var seed: UInt64 = 0x5EED
        func nextUnit() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
        }
        for _ in 0..<42 {
            let p = CGPoint(x: nextUnit() * size.width, y: nextUnit() * size.height * 0.9)
            let r = 0.6 + nextUnit() * 1.1
            ctx.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: r, height: r)),
                     with: .color(.white.opacity(0.18 + Double(nextUnit()) * 0.25)))
        }
    }

    private func drawShield(_ ctx: inout GraphicsContext, size: CGSize) {
        let y = size.height - game.shieldInset
        let line = Path { p in
            p.move(to: CGPoint(x: 12, y: y))
            p.addLine(to: CGPoint(x: size.width - 12, y: y))
        }
        let glow = 0.35 + 0.45 * game.shieldFlash
        ctx.stroke(line, with: .color(accent.opacity(glow)), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1, 7]))
    }

    private func drawMeteor(_ ctx: inout GraphicsContext, _ meteor: MeteorGameModel.Meteor, time: Double) {
        let palette = Self.meteorPalettes[meteor.tint % Self.meteorPalettes.count]
        let x = meteor.renderX(time: time)
        let rect = CGRect(x: x - meteor.radius, y: meteor.y - meteor.radius,
                          width: meteor.radius * 2, height: meteor.radius * 2)
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [palette.light, palette.body, palette.dark]),
            center: CGPoint(x: x - meteor.radius * 0.35, y: meteor.y - meteor.radius * 0.35),
            startRadius: 0, endRadius: meteor.radius * 1.6))
        // Crater specks, seeded per-meteor so they don't crawl.
        for i in 0..<3 {
            let angle = meteor.spin + Double(i) * 2.1
            let dist = meteor.radius * (0.28 + 0.16 * CGFloat(i))
            let cr = meteor.radius * (0.16 - 0.03 * CGFloat(i))
            let cx = x + dist * CGFloat(cos(angle))
            let cy = meteor.y + dist * CGFloat(sin(angle))
            ctx.fill(Path(ellipseIn: CGRect(x: cx - cr, y: cy - cr, width: cr * 2, height: cr * 2)),
                     with: .color(palette.dark.opacity(0.55)))
        }
    }

    private func drawBolt(_ ctx: inout GraphicsContext, _ bolt: MeteorGameModel.Bolt) {
        let rect = CGRect(x: bolt.x - 2.5, y: bolt.y - 9, width: 5, height: 18)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(accent))
        ctx.fill(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(accent.opacity(0.18)))
    }

    private func drawBurst(_ ctx: inout GraphicsContext, _ burst: MeteorGameModel.Burst) {
        let palette = Self.meteorPalettes[burst.tint % Self.meteorPalettes.count]
        let scale = 1 + burst.age * 1.4
        let alpha = (1 - burst.age) * 0.8
        let r = burst.radius * scale
        ctx.stroke(Path(ellipseIn: CGRect(x: burst.x - r, y: burst.y - r, width: r * 2, height: r * 2)),
                   with: .color(palette.light.opacity(alpha)), lineWidth: 3)
        let r2 = burst.radius * scale * 0.55
        ctx.fill(Path(ellipseIn: CGRect(x: burst.x - r2, y: burst.y - r2, width: r2 * 2, height: r2 * 2)),
                 with: .color(.white.opacity(alpha * 0.5)))
    }

    private func drawPod(_ ctx: inout GraphicsContext, size: CGSize) {
        let baseY = size.height - game.podBaseInset
        let x = game.podX
        let powered = !game.needsHold
        // Body: rounded capsule. Dims when the pod is powered down.
        let body = CGRect(x: x - 26, y: baseY, width: 52, height: 16)
        let bodyTop = Color(white: powered ? 0.88 : 0.6)
        let bodyBottom = Color(white: powered ? 0.62 : 0.42)
        ctx.fill(Path(roundedRect: body, cornerRadius: 8), with: .linearGradient(
            Gradient(colors: [bodyTop, bodyBottom]),
            startPoint: CGPoint(x: x, y: baseY), endPoint: CGPoint(x: x, y: baseY + 16)))
        // Glass dome with an accent core (the muzzle) — core goes cold when idle.
        let dome = CGRect(x: x - 13, y: baseY - 13, width: 26, height: 15)
        ctx.fill(Path(ellipseIn: dome), with: .color(.white.opacity(powered ? 0.35 : 0.18)))
        let core = CGRect(x: x - 5, y: baseY - 9, width: 10, height: 10)
        ctx.fill(Path(ellipseIn: core), with: .color(powered ? accent : accent.opacity(0.3)))
        // Hover glow.
        let glow = CGRect(x: x - 20, y: baseY + 18, width: 40, height: 8)
        ctx.fill(Path(ellipseIn: glow), with: .color(accent.opacity(powered ? 0.25 : 0.1)))
        // Powered-down beacon: an expanding accent ring pulsing from the pod,
        // pointing the half-awake player back at the thing they need to grab.
        if !powered && !game.completed {
            let phase = game.elapsed.truncatingRemainder(dividingBy: 1.4) / 1.4
            let r = 18 + CGFloat(phase) * 34
            let alpha = (1 - phase) * 0.55
            ctx.stroke(
                Path(ellipseIn: CGRect(x: x - r, y: baseY + 2 - r, width: r * 2, height: r * 2)),
                with: .color(accent.opacity(alpha)), lineWidth: 2.5)
        }
    }
}

// MARK: - Debug harness host

#if DEBUG
/// Renders the meteor mission alone:
///   simctl launch booted <bundle-id> -meteorDebug hard
struct MeteorDebugHost: View {
    let difficulty: MeteorDifficulty

    var body: some View {
        var mission = Mission()
        mission.type = .meteor
        mission.meteorDifficulty = difficulty
        return MeteorMissionView(
            mission: mission,
            onComplete: { print("🧪 [meteorDebug] mission complete") },
            gracePeriodActive: true,
            gracePeriodRemaining: 30,
            graceTotal: 40
        )
        .background(Color(uiColor: .systemBackground))
    }
}
#endif
