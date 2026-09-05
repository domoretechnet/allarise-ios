//
//  BalanceBallMissionView.swift
//  HaWake Alarm V2
//
//  Balance Ball mission: tilt the phone to roll a 3D glass marble into a
//  dismiss zone and hold it there. Setting the phone down resumes the alarm
//  sound (via onSetDown -> grace period ends early in ActiveAlarmView).
//

import SwiftUI
import SceneKit
import CoreMotion
import Combine

// MARK: - Display Link Driver

/// CADisplayLink wrapper for the balance game loop (ActiveAlarmView's
/// DisplayLinkTimer is private to that file).
private final class BalanceDisplayLink {
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
        onTick?(link.targetTimestamp - link.timestamp)
    }

    deinit {
        stop()
    }
}

// MARK: - Balance Motion Manager

/// Wraps CMMotionManager in a class so it survives SwiftUI struct recreation
/// (same reason as ShakeMotionManager). Uses device motion (gravity +
/// rotation rate + user acceleration) instead of the raw accelerometer, and
/// runs the set-down / pick-up state machine.
@MainActor
final class BalanceMotionManager: ObservableObject {
    private let motionManager = CMMotionManager()
    private var isRunning = false

    /// Latest gravity vector (device frame). Polled by the game loop each
    /// frame — deliberately not @Published to avoid 60 Hz view churn.
    private(set) var gravity: (x: Double, y: Double, z: Double) = (0, 0, -1)

    var isAvailable: Bool { motionManager.isDeviceMotionAvailable }

    /// Fired once when the phone has been flat and still long enough.
    var onSetDown: (() -> Void)?
    /// Fired once when the phone is picked back up after a set-down.
    var onPickUp: (() -> Void)?

    private(set) var isSetDown = false

    // Set-down: the phone must be nearly perfectly flat AND still. The flat
    // threshold is deliberately tight (within ~5.7° of level) because the
    // balancing equilibrium itself is only ~8-13° of tilt — a looser
    // threshold would fire while the user holds the marble steady in the
    // zone. Tables are level to within 2-3°, so set-downs still register.
    private let flatThreshold = 0.995          // |gravity.z|
    private let stillRotationThreshold = 0.10  // rad/s
    private let stillAccelerationThreshold = 0.03  // g
    private let setDownDwell: TimeInterval = 1.5

    // Pick-up hysteresis so the state can't flap on the nightstand.
    private let pickUpFlatExit = 0.985         // |gravity.z| below this counts as lifted
    private let pickUpRotationThreshold = 0.25 // rad/s
    private let pickUpAccelerationThreshold = 0.06 // g
    private let pickUpDwell: TimeInterval = 0.3

    private var setDownCandidateSince: Date?
    private var pickUpCandidateSince: Date?

    func start() {
        guard !isRunning, motionManager.isDeviceMotionAvailable else { return }
        isRunning = true

        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.process(motion)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        isRunning = false
        setDownCandidateSince = nil
        pickUpCandidateSince = nil
        isSetDown = false
    }

    private func process(_ motion: CMDeviceMotion) {
        gravity = (motion.gravity.x, motion.gravity.y, motion.gravity.z)

        let rotationRate = sqrt(
            pow(motion.rotationRate.x, 2) +
            pow(motion.rotationRate.y, 2) +
            pow(motion.rotationRate.z, 2)
        )
        let userAcceleration = sqrt(
            pow(motion.userAcceleration.x, 2) +
            pow(motion.userAcceleration.y, 2) +
            pow(motion.userAcceleration.z, 2)
        )

        if isSetDown {
            let lifted = abs(motion.gravity.z) < pickUpFlatExit
                || rotationRate > pickUpRotationThreshold
                || userAcceleration > pickUpAccelerationThreshold
            if lifted {
                if pickUpCandidateSince == nil { pickUpCandidateSince = Date() }
                if Date().timeIntervalSince(pickUpCandidateSince!) >= pickUpDwell {
                    isSetDown = false
                    pickUpCandidateSince = nil
                    onPickUp?()
                }
            } else {
                pickUpCandidateSince = nil
            }
        } else {
            let flatAndStill = abs(motion.gravity.z) > flatThreshold
                && rotationRate < stillRotationThreshold
                && userAcceleration < stillAccelerationThreshold
            if flatAndStill {
                if setDownCandidateSince == nil { setDownCandidateSince = Date() }
                if Date().timeIntervalSince(setDownCandidateSince!) >= setDownDwell {
                    isSetDown = true
                    setDownCandidateSince = nil
                    onSetDown?()
                }
            } else {
                setDownCandidateSince = nil
            }
        }
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
    }
}

// MARK: - Balance Game Model

/// Marble physics + zone/progress state. Marble position is pushed straight
/// to SceneKit via `onMarbleMoved` (not @Published) so 60 fps motion never
/// re-renders SwiftUI; only zone/progress state is published.
@MainActor
final class BalanceGameModel: ObservableObject {
    static let marbleRadius: Double = 18

    @Published private(set) var zoneCenter: CGPoint = .zero
    /// Where the zone will relocate next — the yellow preview ring. Appears
    /// `previewLeadTime` seconds before the hop so the player can start
    /// rolling there immediately; nil while the zone is settled.
    @Published private(set) var nextZoneCenter: CGPoint?
    @Published private(set) var isInZone = false
    @Published private(set) var progress: Double = 0

    /// Called every frame with the marble's playfield position.
    var onMarbleMoved: ((CGPoint) -> Void)?
    /// Fired once when progress reaches the hold duration.
    var onCompleted: (() -> Void)?
    /// Fired with +2s for every full second the marble spends in the zone —
    /// ActiveAlarmView adds it to the grace budget so active balancing keeps
    /// the alarm muted. Batched to whole seconds to avoid 60 Hz state churn.
    var onGraceEarned: ((Double) -> Void)?

    private(set) var difficulty: BalanceDifficulty = .medium
    /// Required in-zone time. Comes from the mission's effective hold (the
    /// per-alarm override when set, else the difficulty default).
    private(set) var holdDuration: Double = 16
    /// Effective target radius — the mission's per-alarm override when set,
    /// else the difficulty preset. All zone geometry (ring size, containment,
    /// placement insets) reads this, NOT `difficulty.zoneRadius`.
    private(set) var zoneRadius: Double = 36
    /// Effective seconds the target sits before relocating (per-alarm override
    /// when set, else the difficulty preset).
    private(set) var zoneDwell: Double = 3
    private(set) var playfieldSize: CGSize = .zero

    private var position: CGPoint = .zero
    private var velocity: CGVector = .zero
    private var completed = false
    private var graceEarnAccumulator: Double = 0

    // Zone relocation cycle: dwell at a spot → preview the next spot →
    // glide there slowly → repeat. Runs at every difficulty. Glide duration
    // is distance / difficulty.zoneGlideSpeed, computed per hop.
    private var zoneTimer: Double = 0
    private var hopFrom: CGPoint?
    private var hopProgress: Double = 0
    private var hopDuration = 1.0

    // Spring pulling the marble toward the playfield center. This is what
    // forces a *held* tilt: without it the equilibrium is a level phone no
    // matter where the zone sits. Tuned against the edge-margin zone
    // distances so the required hold tilt stays ~10-12° at every level
    // (required tilt = asin(springK × zoneDistance / tiltGain)).
    private var springK: Double {
        switch difficulty {
        case .easy: return 2.6
        case .medium: return 4.4
        case .hard: return 7.0
        }
    }

    private let wallRestitution = 0.55

    /// The farthest a zone center may sit from the playfield center and still
    /// be HOLDABLE: the spring pulls back with force springK × distance, so
    /// parking the marble at distance d needs a sustained tilt of
    /// asin(springK × d / tiltGain). Cap d so that tilt never exceeds ~22°
    /// (comfortably above the 10–20° the edge-margin placements need).
    /// Without this cap, hops clamped only to the playfield BOUNDS could park
    /// the zone near the top of a tall playfield — beyond any physically
    /// holdable tilt.
    private var maxZoneDistanceFromCenter: Double {
        let holdableTilt = 22.0 * .pi / 180
        let reachable = difficulty.tiltGain * sin(holdableTilt) / springK
        // Never collapse below the legal placement band on odd configs.
        return max(reachable, zoneRadius + difficulty.zoneEdgeMarginRange.upperBound)
    }

    /// Pull `p` radially toward `center` until it's within the holdable
    /// distance (see maxZoneDistanceFromCenter).
    private func clampToReachable(_ p: CGPoint, center: CGPoint) -> CGPoint {
        let dx = p.x - center.x, dy = p.y - center.y
        let d = hypot(dx, dy)
        guard d > maxZoneDistanceFromCenter, d > 0 else { return p }
        let scale = maxZoneDistanceFromCenter / d
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    func configure(difficulty: BalanceDifficulty, holdDuration: Double, zoneRadius: Double, zoneDwell: Double, playfieldSize: CGSize) {
        let oldSize = self.playfieldSize
        self.difficulty = difficulty
        self.holdDuration = holdDuration
        self.zoneRadius = zoneRadius
        self.zoneDwell = zoneDwell
        self.playfieldSize = playfieldSize
        guard playfieldSize != oldSize else { return }
        if oldSize.width > 0, oldSize.height > 0 {
            // Mid-game relayout (e.g. the instruction text rewrapping resizes
            // the flexible playfield by a few points): carry the game state
            // into the new bounds instead of restarting — a hard reset here
            // teleports the zone the moment layout shifts.
            rescale(from: oldSize)
        } else {
            reset()
        }
    }

    /// Map marble + zone state proportionally into the current playfield
    /// size, then clamp everything back inside the legal bounds.
    private func rescale(from oldSize: CGSize) {
        let sx = playfieldSize.width / oldSize.width
        let sy = playfieldSize.height / oldSize.height
        func scaled(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }

        let r = Self.marbleRadius
        position = scaled(position)
        position.x = min(max(position.x, r), playfieldSize.width - r)
        position.y = min(max(position.y, r), playfieldSize.height - r)

        let edgeInset = zoneRadius + 12
        func clampedZone(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, edgeInset), playfieldSize.width - edgeInset),
                    y: min(max(p.y, edgeInset), playfieldSize.height - edgeInset))
        }
        zoneCenter = clampedZone(scaled(zoneCenter))
        if let from = hopFrom { hopFrom = clampedZone(scaled(from)) }
        if let next = nextZoneCenter { nextZoneCenter = clampedZone(scaled(next)) }

        onMarbleMoved?(position)
    }

    /// Recenter the marble, clear progress, and pick a fresh zone spot.
    func reset() {
        guard playfieldSize.width > 0, playfieldSize.height > 0 else { return }
        position = CGPoint(x: playfieldSize.width / 2, y: playfieldSize.height / 2)
        velocity = .zero
        progress = 0
        graceEarnAccumulator = 0
        zoneTimer = 0
        nextZoneCenter = nil
        hopFrom = nil
        randomizeZone()
        onMarbleMoved?(position)
    }

    /// Called after a set-down failure: progress is lost and the zone moves
    /// so the same muscle-memory angle won't work twice.
    func handleSetDownFailure() {
        reset()
    }

    private func randomizeZone() {
        guard playfieldSize.width > 0, playfieldSize.height > 0 else { return }
        let center = CGPoint(x: playfieldSize.width / 2, y: playfieldSize.height / 2)

        // Zone must stay fully on the playfield…
        let edgeInset = zoneRadius + 12
        let minX = edgeInset, maxX = playfieldSize.width - edgeInset
        let minY = edgeInset, maxY = playfieldSize.height - edgeInset
        guard maxX > minX, maxY > minY else { return }

        // …and far enough from center that the resting marble (parked at the
        // playfield center by the spring) can never start inside it.
        let minFromCenter = zoneRadius + 16
        let previousAngle = atan2(zoneCenter.y - center.y, zoneCenter.x - center.x)

        var placed: CGPoint?
        for _ in 0..<16 {
            let angle = Double.random(in: 0..<(2 * .pi))
            // Keep the new zone at least 90° around from the old one.
            if zoneCenter != .zero && abs(atan2(sin(angle - previousAngle), cos(angle - previousAngle))) < .pi / 2 {
                continue
            }
            let distance = zoneRadius + Double.random(in: difficulty.zoneEdgeMarginRange)
            var p = CGPoint(x: center.x + cos(angle) * distance,
                            y: center.y + sin(angle) * distance)
            p.x = min(max(p.x, minX), maxX)
            p.y = min(max(p.y, minY), maxY)
            p = clampToReachable(p, center: center)
            if hypot(p.x - center.x, p.y - center.y) >= minFromCenter {
                placed = p
                break
            }
        }

        // Fallback for tiny playfields: farthest spot along the wider axis.
        if placed == nil {
            let direction: Double = Bool.random() ? 1 : -1
            placed = (maxX - center.x) >= (maxY - center.y)
                ? CGPoint(x: center.x + direction * (maxX - center.x), y: center.y)
                : CGPoint(x: center.x, y: center.y + direction * (maxY - center.y))
        }

        zoneCenter = placed!
    }

    /// Pick where the zone relocates to next: within the difficulty's hop
    /// distance from the CURRENT zone, fully on the playfield, and never
    /// close enough to center that the resting marble sits inside it.
    private func pickHopTarget() -> CGPoint? {
        guard playfieldSize.width > 0, playfieldSize.height > 0 else { return nil }
        let center = CGPoint(x: playfieldSize.width / 2, y: playfieldSize.height / 2)

        let edgeInset = zoneRadius + 12
        let minX = edgeInset, maxX = playfieldSize.width - edgeInset
        let minY = edgeInset, maxY = playfieldSize.height - edgeInset
        guard maxX > minX, maxY > minY else { return nil }

        let minFromCenter = zoneRadius + 16
        // Never hop somewhere the player couldn't distinguish from "it didn't
        // move" — at least a zone diameter away from the current spot.
        let minHop = zoneRadius * 2

        var best: CGPoint?
        var bestDistance = 0.0
        for _ in 0..<24 {
            let angle = Double.random(in: 0..<(2 * .pi))
            let distance = Double.random(in: difficulty.hopDistanceRange)
            var p = CGPoint(x: zoneCenter.x + cos(angle) * distance,
                            y: zoneCenter.y + sin(angle) * distance)
            p.x = min(max(p.x, minX), maxX)
            p.y = min(max(p.y, minY), maxY)
            p = clampToReachable(p, center: center)
            guard hypot(p.x - center.x, p.y - center.y) >= minFromCenter else { continue }
            let travelled = hypot(p.x - zoneCenter.x, p.y - zoneCenter.y)
            if travelled >= minHop { return p }
            // Track the farthest clamped candidate as a fallback.
            if travelled > bestDistance {
                bestDistance = travelled
                best = p
            }
        }
        return best
    }

    /// Advance one frame. `gravity` is the device-frame gravity vector.
    func tick(dt rawDt: Double, gravity: (x: Double, y: Double)) {
        guard playfieldSize.width > 0, !completed else { return }
        let dt = min(rawDt, 1.0 / 30.0)

        // Tilt: device +x is screen-right; device +y is screen-up, screen
        // coords have y down, hence the flip.
        var ax = gravity.x * difficulty.tiltGain
        var ay = -gravity.y * difficulty.tiltGain

        // Centering spring (see springK comment).
        let center = CGPoint(x: playfieldSize.width / 2, y: playfieldSize.height / 2)
        ax += -springK * (position.x - center.x)
        ay += -springK * (position.y - center.y)

        velocity.dx += ax * dt
        velocity.dy += ay * dt
        let damping = max(0, 1 - difficulty.friction * dt)
        velocity.dx *= damping
        velocity.dy *= damping
        position.x += velocity.dx * dt
        position.y += velocity.dy * dt

        // Walls
        let r = Self.marbleRadius
        let maxX = Double(playfieldSize.width) - r
        let maxY = Double(playfieldSize.height) - r
        if position.x < r {
            position.x = r
            velocity.dx = abs(velocity.dx) * wallRestitution
        }
        if position.x > maxX {
            position.x = maxX
            velocity.dx = -abs(velocity.dx) * wallRestitution
        }
        if position.y < r {
            position.y = r
            velocity.dy = abs(velocity.dy) * wallRestitution
        }
        if position.y > maxY {
            position.y = maxY
            velocity.dy = -abs(velocity.dy) * wallRestitution
        }

        // Zone relocation cycle (all difficulties): dwell at the current
        // spot, telegraph the next spot with the yellow preview ring
        // `previewLeadTime` seconds early, then glide there SLOWLY at the
        // difficulty's glide speed — slow enough that the marble can ride
        // inside the zone during the move and keep accruing progress.
        if let from = hopFrom, let target = nextZoneCenter {
            // Mid-glide: interpolate the LOGICAL zone position (linear =
            // constant speed, the easiest motion to track) so containment
            // matches exactly what the player sees.
            hopProgress += dt / hopDuration
            if hopProgress >= 1 {
                zoneCenter = target
                hopFrom = nil
                nextZoneCenter = nil
                zoneTimer = 0
            } else {
                zoneCenter = CGPoint(x: from.x + (target.x - from.x) * hopProgress,
                                     y: from.y + (target.y - from.y) * hopProgress)
            }
        } else {
            zoneTimer += dt
            // Cap the preview lead to the (possibly overridden) dwell so a
            // short dwell can't demand a lead longer than the dwell itself —
            // at worst the preview ring appears right at the start of the dwell.
            let previewLead = min(difficulty.previewLeadTime, zoneDwell)
            if nextZoneCenter == nil,
               zoneTimer >= zoneDwell - previewLead {
                nextZoneCenter = pickHopTarget()
            }
            if zoneTimer >= zoneDwell, let target = nextZoneCenter {
                hopFrom = zoneCenter
                hopProgress = 0
                let distance = hypot(target.x - zoneCenter.x, target.y - zoneCenter.y)
                hopDuration = max(distance / difficulty.zoneGlideSpeed, 0.3)
            }
        }

        // Progress: accrues inside the zone, holds steady in the neutral
        // band just outside the edge (grazing the rim is forgiven), and
        // drains only once the marble is clearly away from the zone.
        let wasInZone = isInZone
        let distanceFromZone = hypot(position.x - zoneCenter.x, position.y - zoneCenter.y)
        let inZone = distanceFromZone <= zoneRadius
        let inNeutralBand = !inZone
            && distanceFromZone <= zoneRadius + difficulty.neutralBandWidth
        if inZone != wasInZone {
            isInZone = inZone
            if inZone {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
        if inZone {
            progress = min(progress + dt, holdDuration)
            // Earn +2s of grace for every full second spent in the zone.
            graceEarnAccumulator += dt
            if graceEarnAccumulator >= 1.0 {
                graceEarnAccumulator -= 1.0
                onGraceEarned?(2.0)
            }
        } else if !inNeutralBand {
            progress = max(progress - difficulty.drainRate * dt, 0)
        }

        onMarbleMoved?(position)

        if progress >= holdDuration && !completed {
            completed = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCompleted?()
        }
    }
}

// MARK: - SceneKit Marble View

/// SCNView subclass that reports its own layout — the only source of size
/// truth that is correct in EVERY ordering of SwiftUI callbacks (makeUIView
/// vs onAppear vs window attachment). The camera scale is driven from here.
final class BalanceSCNView: SCNView {
    var onLayout: ((CGSize) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
    }
}

/// Transparent SCNView hosting the 3D glass marble. UIViewRepresentable
/// (not SwiftUI SceneView) because SceneView can't render a transparent
/// background. Marble positions arrive via the game model's onMarbleMoved.
struct BalanceBallSceneView: UIViewRepresentable {
    let model: BalanceGameModel
    let swirlColor: Color

    func makeUIView(context: Context) -> SCNView {
        let scnView = BalanceSCNView()

        let scene = SCNScene()
        scene.lightingEnvironment.contents = Self.makeEnvironmentImage()
        scene.lightingEnvironment.intensity = 1.8

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.zNear = 1
        camera.zFar = 200
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 100)
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 300
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 800
        key.eulerAngles = SCNVector3(-Float.pi / 4, -Float.pi / 6, 0)
        scene.rootNode.addChildNode(key)

        // Authored marble model: glass shell + red/blue ribbon core, built at
        // radius 18 to match BalanceGameModel.marbleRadius exactly — the
        // position mapping and roll math assume that size. Fall back to the
        // procedural marble if the resource is missing so the mission can
        // never come up empty during a live alarm.
        let marbleNode: SCNNode
        if let authored = SCNScene(named: "RealisticMarble.scn")?
            .rootNode.childNode(withName: "marble", recursively: true) {
            marbleNode = authored
        } else {
            marbleNode = Self.makeProceduralMarble(swirlColor: swirlColor)
        }
        scene.rootNode.addChildNode(marbleNode)

        // Assign the scene FIRST, then force the transparent background —
        // setting backgroundColor before the scene is attached gets clobbered
        // and the view renders an opaque white box over the playfield.
        scnView.scene = scene
        scnView.backgroundColor = .clear
        scnView.isOpaque = false
        scnView.antialiasingMode = .multisampling4X
        scnView.isUserInteractionEnabled = false
        scnView.rendersContinuously = true  // tiny scene; guarantees the marble draws every frame

        context.coordinator.scnView = scnView
        context.coordinator.cameraNode = cameraNode
        context.coordinator.marbleNode = marbleNode
        model.onMarbleMoved = { [weak coordinator = context.coordinator] position in
            coordinator?.moveMarble(to: position)
        }
        // Layout is the authoritative size source: it fires whenever the view
        // actually has real bounds, regardless of SwiftUI callback ordering.
        scnView.onLayout = { [weak coordinator = context.coordinator] size in
            coordinator?.updateSize(size)
        }
        // The model may already know its size (configure can run before or
        // after makeUIView depending on SwiftUI's layout order).
        context.coordinator.updateSize(model.playfieldSize)

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Intentionally empty: size and positions flow through the model's
        // closures — SwiftUI does not reliably call this on parent re-renders.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var scnView: SCNView?
        var cameraNode: SCNNode?
        var marbleNode: SCNNode?
        var playfieldSize: CGSize = .zero
        private var lastPosition: CGPoint?

        func updateSize(_ size: CGSize) {
            playfieldSize = size
            // 1 scene unit == 1 point
            cameraNode?.camera?.orthographicScale = max(size.height / 2, 1)
        }

        func moveMarble(to position: CGPoint) {
            guard let marbleNode, playfieldSize.width > 0 else { return }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0

            // Playfield coords (y down) -> scene coords (y up, origin center)
            marbleNode.position = SCNVector3(
                Float(position.x - playfieldSize.width / 2),
                Float(-(position.y - playfieldSize.height / 2)),
                0
            )

            // Roll to match the distance travelled: Δθ = |Δp| / r, axis
            // perpendicular to the motion direction.
            if let last = lastPosition {
                let dx = Float(position.x - last.x)
                let dy = Float(-(position.y - last.y))
                let distance = sqrt(dx * dx + dy * dy)
                if distance > 0.01 {
                    let angle = distance / Float(BalanceGameModel.marbleRadius)
                    let axis = simd_normalize(simd_float3(-dy, dx, 0))
                    marbleNode.simdOrientation = simd_quatf(angle: angle, axis: axis) * marbleNode.simdOrientation
                }
            }
            lastPosition = position

            SCNTransaction.commit()
        }
    }

    /// Fallback marble (pre-4.96 look) used only if RealisticMarble.scn fails
    /// to load: clear glass sphere with a tinted torus swirl inside — the
    /// swirl is what makes the rolling visible on an otherwise uniform ball.
    private static func makeProceduralMarble(swirlColor: Color) -> SCNNode {
        let sphere = SCNSphere(radius: BalanceGameModel.marbleRadius)
        sphere.segmentCount = 48
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        // Mostly-clear glass: low-alpha diffuse so the wallpaper shows
        // through, reflections from the lighting environment sell the surface.
        material.diffuse.contents = UIColor(white: 0.95, alpha: 0.30)
        material.metalness.contents = 0.0
        material.roughness.contents = 0.08
        material.transparency = 0.55
        material.transparencyMode = .dualLayer  // back + front faces = solid glass read
        sphere.materials = [material]
        let marbleNode = SCNNode(geometry: sphere)

        let swirl = SCNTorus(ringRadius: 8, pipeRadius: 3.5)
        let swirlMaterial = SCNMaterial()
        swirlMaterial.lightingModel = .physicallyBased
        let swirlUIColor = UIColor(swirlColor)
        swirlMaterial.diffuse.contents = swirlUIColor
        swirlMaterial.emission.contents = swirlUIColor.withAlphaComponent(0.8)
        swirlMaterial.roughness.contents = 0.3
        swirl.materials = [swirlMaterial]
        let swirlNode = SCNNode(geometry: swirl)
        swirlNode.eulerAngles = SCNVector3(0.6, 0.3, 0)
        marbleNode.addChildNode(swirlNode)

        return marbleNode
    }

    /// Small procedural sky-to-ground gradient used as the PBR lighting
    /// environment — this drives the glass reflections without bundling an
    /// image asset.
    private static func makeEnvironmentImage() -> UIImage {
        let size = CGSize(width: 64, height: 32)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [
                UIColor(white: 1.0, alpha: 1).cgColor,
                UIColor(white: 0.55, alpha: 1).cgColor,
                UIColor(white: 0.2, alpha: 1).cgColor,
            ]
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0, 0.55, 1]
            )!
            ctx.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: 0, y: size.height),
                options: []
            )
        }
    }
}

// MARK: - Balance Ball Mission View

struct BalanceBallMissionView: View {
    let mission: Mission
    let onComplete: () -> Void
    var onEngaged: (() -> Void)? = nil
    var onSetDown: (() -> Void)? = nil
    var onGraceEarned: ((Double) -> Void)? = nil
    var gracePeriodActive: Bool = false
    var gracePeriodRemaining: TimeInterval = 0
    var graceTotal: TimeInterval = 0
    var alarmColors: AlarmColorCustomization = .default
    /// Accent from the main app theme (progress bar while in-zone).
    var accent: Color = .accentColor
    var compact: Bool = false
    /// Retained for source compatibility; the redesigned screen is full-screen
    /// with no glass card.
    var showsGlassCard: Bool = true

    @StateObject private var motionManager = BalanceMotionManager()
    @StateObject private var gameModel = BalanceGameModel()
    @State private var displayLink: BalanceDisplayLink?
    @State private var hasEngaged = false
    @State private var completed = false
    @State private var simulatedGravity: CGVector = .zero
    @State private var zonePulse = false

    private var difficulty: BalanceDifficulty { mission.balanceDifficulty }
    /// Effective target radius (per-alarm override, else the difficulty preset)
    /// — every ring the view draws sizes off this, matching the game model.
    private var zoneRadius: Double { mission.effectiveBalanceZoneRadius }

    // Engagement = the user is actually tilting the phone (~6°+). Same idea
    // as shake's first-shake trigger: don't mute the alarm until they're
    // clearly working on the mission.
    private let engagementTilt = 0.105  // sin(6°)

    /// Every line names the MARBLE. Half of these used to say "it" or nothing at
    /// all ("Hold it there…", "head there"), which reads fine once you already
    /// know what you're steering — and this is the one screen where the user is
    /// half asleep and seeing it for the first time.
    private var instructionText: String {
        if gameModel.isInZone {
            return gameModel.nextZoneCenter != nil
                ? "Hold the marble — it's about to move to the yellow ring"
                : "Hold the marble there…"
        }
        return gameModel.nextZoneCenter != nil
            ? "Move the marble to the yellow ring"
            : "Tilt the phone to move the marble"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
            Text(instructionText)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 24)

            // Full-screen playfield — claims the whole middle of the screen.
            playfield
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            // No bottom readout — the goal-zone ring IS the progress/complete
            // indicator, so the playfield gets the full screen.
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Lift the content when grace is active so the bottom progress bar
            // doesn't collide with the grace ring in the corner.
            .padding(.bottom, gracePeriodActive ? 58 : 0)

            // Grace countdown ring — bottom-right, consistent across missions.
            if gracePeriodActive && gracePeriodRemaining > 0 {
                MissionGracePill(remaining: gracePeriodRemaining, total: graceTotal, accent: accent)
                    .padding(.trailing, 22)
                    .padding(.bottom, 26)
            }
        }
        .onAppear {
            startGame()
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                zonePulse = true
            }
        }
        .onDisappear { stopGame() }
    }

    @ViewBuilder
    private var playfield: some View {
        GeometryReader { geometry in
            let holdProgress = min(1.0, gameModel.progress / max(0.1, mission.effectiveBalanceHoldDuration))
            ZStack {
                // Soft playfield surface — no hard border; a gentle radial
                // vignette gives the marble a sense of depth.
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .overlay(
                        RadialGradient(
                            colors: [.clear, .black.opacity(0.22)],
                            center: .center, startRadius: 70, endRadius: 460
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    )

                // Yellow preview ring: where the zone relocates next. Seeing
                // it means "start rolling there now".
                if let next = gameModel.nextZoneCenter {
                    Circle()
                        .strokeBorder(
                            Color.yellow.opacity(0.85),
                            style: StrokeStyle(lineWidth: 2.5, dash: [5, 6])
                        )
                        .frame(width: zoneRadius * 2, height: zoneRadius * 2)
                        .position(next)
                        .transition(.opacity)
                }

                // Dismiss zone: real green (deliberately NOT theme-based, so
                // green = safe reads the same across every theme) with a
                // subtle breathing pulse; fill deepens, the stroke goes solid,
                // and it glows while the marble is inside.
                Circle()
                    .fill(Color.green.opacity(gameModel.isInZone ? 0.40 : 0.18))
                    .overlay(
                        Circle().strokeBorder(
                            Color.green.opacity(gameModel.isInZone ? 1.0 : 0.75),
                            style: StrokeStyle(lineWidth: 3, dash: gameModel.isInZone ? [] : [6, 5])
                        )
                    )
                    .frame(width: zoneRadius * 2, height: zoneRadius * 2)
                    .scaleEffect(zonePulse ? 1.05 : 0.96)
                    .shadow(color: .green.opacity(gameModel.isInZone ? 0.7 : 0), radius: 16)
                    .animation(.easeOut(duration: 0.25), value: gameModel.isInZone)
                    .position(gameModel.zoneCenter)

                // Hold-progress ring hugging the goal zone — fills as the marble
                // is held inside, so the target visibly "completes".
                Circle()
                    .trim(from: 0, to: holdProgress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: zoneRadius * 2 + 18, height: zoneRadius * 2 + 18)
                    .shadow(color: .green.opacity(0.5), radius: 4)
                    .position(gameModel.zoneCenter)
                    .animation(.linear(duration: 0.12), value: holdProgress)

                BalanceBallSceneView(model: gameModel, swirlColor: alarmColors.resolvedShakeProgressColor)
                    .allowsHitTesting(false)

                #if targetEnvironment(simulator)
                simulatorOverlay
                #endif
            }
            .onAppear {
                gameModel.configure(difficulty: difficulty, holdDuration: mission.effectiveBalanceHoldDuration, zoneRadius: zoneRadius, zoneDwell: mission.effectiveBalanceZoneDwell, playfieldSize: geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                gameModel.configure(difficulty: difficulty, holdDuration: mission.effectiveBalanceHoldDuration, zoneRadius: zoneRadius, zoneDwell: mission.effectiveBalanceZoneDwell, playfieldSize: newSize)
            }
            .onChange(of: gameModel.isInZone) { _, inZone in
                // Light haptic tick the moment the marble enters the goal zone.
                if inZone { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
            }
            #if targetEnvironment(simulator)
            .contentShape(Rectangle())
            .gesture(simulatorDragGesture(playfieldSize: geometry.size))
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
    }

    // MARK: Game lifecycle

    private func startGame() {
        gameModel.onCompleted = {
            guard !completed else { return }
            completed = true
            onComplete()
        }

        gameModel.onGraceEarned = { amount in
            onGraceEarned?(amount)
        }

        motionManager.onSetDown = {
            guard !completed else { return }
            // Only a set-down AFTER engaging is a real failure. On a multi-mission
            // handoff the grace period is already running when this view mounts, so
            // a phone that is simply still flat while the user reads the new
            // instructions would otherwise trip this within setDownDwell and resume
            // the alarm sound a second into the slot.
            guard hasEngaged else { return }
            // Losing progress + a fresh zone spot is the cost of putting
            // the phone down; ActiveAlarmView resumes the sound.
            gameModel.handleSetDownFailure()
            hasEngaged = false
            onSetDown?()
        }
        motionManager.start()

        displayLink = BalanceDisplayLink { dt in
            let gravity: (x: Double, y: Double)
            if motionManager.isAvailable {
                gravity = (motionManager.gravity.x, motionManager.gravity.y)
            } else {
                gravity = (Double(simulatedGravity.dx), Double(simulatedGravity.dy))
            }

            guard !motionManager.isSetDown else { return }
            gameModel.tick(dt: dt, gravity: gravity)
            engageIfNeeded(gravity: gravity)
        }
        displayLink?.start()
    }

    private func stopGame() {
        displayLink?.stop()
        displayLink = nil
        motionManager.stop()
    }

    /// Mute the alarm only once the user is visibly working the mission and
    /// the app is frontmost (same gating as shake). After a set-down,
    /// hasEngaged resets so picking the phone back up re-arms the grace
    /// period in ActiveAlarmView.
    private func engageIfNeeded(gravity: (x: Double, y: Double)) {
        // NOT gated on gracePeriodActive: on a multi-mission handoff grace is
        // already running when this slot opens, and this is still the signal that
        // seeds hasEngaged / the set-down budget. ActiveAlarmView's onEngaged is
        // idempotent (startGracePeriod no-ops while a period is active).
        guard !hasEngaged else { return }
        let tilting = abs(gravity.x) > engagementTilt || abs(gravity.y) > engagementTilt
        guard tilting, UIApplication.shared.applicationState == .active else { return }
        hasEngaged = true
        onEngaged?()
    }

    // MARK: Simulator support (no device motion in the simulator)

    #if targetEnvironment(simulator)
    @ViewBuilder
    private var simulatorOverlay: some View {
        VStack {
            Text("Drag to tilt (simulator)")
                .font(.caption2)
                .foregroundStyle(alarmColors.resolvedMissionTitleColor.opacity(0.5))
            Spacer()
            Button("Simulate Set Down") {
                motionManager.onSetDown?()
            }
            .font(.caption2)
            .buttonStyle(.bordered)
        }
        .padding(8)
    }

    private func simulatorDragGesture(playfieldSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Map drag offset to a virtual tilt, through the exact same
                // physics path as real gravity. Note the y flip: dragging
                // down should roll the ball down (device -y gravity).
                let scale = 150.0
                simulatedGravity = CGVector(
                    dx: max(-0.5, min(0.5, value.translation.width / scale)),
                    dy: max(-0.5, min(0.5, -value.translation.height / scale))
                )
            }
            .onEnded { _ in
                simulatedGravity = .zero
            }
    }
    #endif
}

#if DEBUG
/// Fires a REAL alarm window over the running app (the exact "alarm rings
/// while the app is open" path) for the balance mission. Launch with
/// `-balanceBallDebug alarm-hard`. Not reachable in any normal app flow.
enum BalanceBallDebugAlarm {
    @MainActor
    static func fire(difficulty: BalanceDifficulty, after seconds: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            var mission = Mission()
            mission.type = .balanceBall
            mission.balanceDifficulty = difficulty
            let alarm = Alarm(label: "Balance Debug", mission: mission)
            PendingAlarmStore.shared.storeFullAlarmInfo(alarmID: 424242, alarm: alarm)
            AlarmWindowManager.shared.showAlarm(
                alarmID: 424242,
                label: "Balance Debug",
                missionType: .balanceBall,
                soundID: alarm.soundName
            )
        }
    }
}

/// Standalone host for exercising the balance mission in the simulator
/// without navigating the app: launch with `-balanceBallDebug hard`.
/// Not reachable in any normal app flow.
struct BalanceBallDebugHost: View {
    let difficulty: BalanceDifficulty

    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            BalanceBallMissionView(
                mission: {
                    var m = Mission()
                    m.type = .balanceBall
                    m.balanceDifficulty = difficulty
                    return m
                }(),
                onComplete: { print("BALANCE DEBUG: completed") },
                onSetDown: { print("BALANCE DEBUG: set down") }
            )
        }
    }
}
#endif

#Preview {
    ZStack {
        LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        BalanceBallMissionView(
            mission: {
                var m = Mission()
                m.type = .balanceBall
                m.balanceDifficulty = .medium
                return m
            }(),
            onComplete: {}
        )
    }
}
