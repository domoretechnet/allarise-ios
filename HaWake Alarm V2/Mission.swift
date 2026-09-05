//
//  Mission.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import Foundation

enum MissionType: String, Codable, CaseIterable {
    case none = "None"
    case shake = "Shake"
    case math = "Math"
    case balanceBall = "Balance Ball"
    case blockDrop = "Block Drop"
    case meteor = "Meteor Defense"
    case homeAssistant = "Home Assistant"
    case alert = "Alert"

    /// Mission types shown in the app's mission picker (excludes internal types like .alert)
    static var userVisible: [MissionType] {
        [.none, .shake, .math, .balanceBall, .blockDrop, .meteor, .homeAssistant]
    }

    /// Mission types behind Allarise Pro. The two game missions are the ones
    /// that took real build effort beyond "wake the user up", so they're the
    /// upsell; every mission that can actually get someone out of bed stays
    /// free. Locked types are still SHOWN — a lock the user can see is an
    /// advert, one they can't is just a missing feature.
    var requiresPro: Bool {
        switch self {
        case .blockDrop, .meteor: return true
        default:                  return false
        }
    }

    /// SF Symbol icon for the mission type button
    var iconName: String {
        switch self {
        case .none:          return "hand.tap.fill"
        case .shake:         return "iphone.gen3.radiowaves.left.and.right"
        case .math:          return "function"
        case .balanceBall:   return "gyroscope"
        case .blockDrop:     return "square.grid.3x3.bottomleft.filled"
        case .meteor:        return "sparkles"
        case .homeAssistant: return "house.fill"
        case .alert:         return "bell.badge.fill"
        }
    }

    /// Short label for the glass mission type button
    var shortLabel: String {
        switch self {
        case .none:          return "Tap"
        case .shake:         return "Shake"
        case .math:          return "Math"
        case .balanceBall:   return "Balance"
        case .blockDrop:     return "Bricks"
        case .meteor:        return "Meteor"
        case .homeAssistant: return "HA"
        case .alert:         return "Alert"
        }
    }
}

/// How a missionless ("Tap") alarm is dismissed from the alarm landing screen.
/// `.tap` requires `tapCount` taps (1 = today's single-tap dismiss); `.hold`
/// requires holding the dismiss chip for `tapHoldDuration` seconds. Anything
/// beyond a single tap makes the alarm a REAL mission (opens the app, uses
/// CompleteMissionIntent) so a background lock-screen stop can't bypass it.
enum TapDismissMode: String, Codable, CaseIterable {
    case tap = "Tap"
    case hold = "Hold"
}

enum HASnoozeMode: String, Codable, CaseIterable {
    case normal = "Normal"              // Standard hold-to-snooze
    case math = "Math"                  // Math mission to snooze
    case shake = "Shake"                // Shake mission to snooze
    case homeAssistant = "Home Assistant"  // Only HA can snooze
}

enum ShakeMode: String, Codable, CaseIterable {
    case duration = "Duration"
    case count = "Count"
}

enum ShakeIntensity: String, Codable, CaseIterable {
    case light = "Light"
    case medium = "Medium"
    case vigorous = "Vigorous"
    
    var threshold: Double {
        switch self {
        case .light: return 1.5
        case .medium: return 2.0
        case .vigorous: return 2.8
        }
    }
}

enum BalanceDifficulty: String, Codable, CaseIterable {
    case easy = "Easy"
    case medium = "Medium"
    case hard = "Hard"

    /// Radius of the dismiss zone in points
    var zoneRadius: Double {
        switch self {
        case .easy: return 46
        case .medium: return 36
        case .hard: return 28
        }
    }

    /// Seconds the marble must stay in the zone (progress accrues at 1.0/s inside)
    var holdDuration: Double {
        switch self {
        case .easy: return 8
        case .medium: return 16
        case .hard: return 25
        }
    }

    /// Width of the neutral band outside the zone edge, in points. While the
    /// marble's center sits in this band it neither gains nor drains
    /// progress — grazing the edge is forgiven, but standing clearly off
    /// the zone still costs. The marble radius is 18 pt, so a band ≥ 18
    /// forgives any visual touch; hard's tighter band starts draining while
    /// the marble still slightly overlaps the ring.
    var neutralBandWidth: Double {
        switch self {
        case .easy: return 26
        case .medium: return 20
        case .hard: return 14
        }
    }

    /// Progress-seconds lost per second while the marble is outside the zone
    var drainRate: Double {
        switch self {
        case .easy: return 0.5
        case .medium: return 1.0
        case .hard: return 1.5
        }
    }

    /// Marble acceleration in pt/s² per unit of lateral gravity (tilt sensitivity)
    var tiltGain: Double {
        switch self {
        case .easy: return 900
        case .medium: return 1200
        case .hard: return 1500
        }
    }

    /// Per-second velocity damping
    var friction: Double {
        switch self {
        case .easy: return 2.5
        case .medium: return 2.0
        case .hard: return 1.6
        }
    }

    /// How far past the zone's own radius its center sits from the playfield
    /// center, in points. Measured from the zone EDGE so the resting marble
    /// (which the centering spring parks at the playfield center) can never
    /// start inside the zone — a fraction-based offset allowed exactly that.
    var zoneEdgeMarginRange: ClosedRange<Double> {
        switch self {
        case .easy: return 18...34
        case .medium: return 22...40
        case .hard: return 26...46
        }
    }

    /// How long the zone stays at one spot before relocating
    var zoneDwellDuration: Double {
        switch self {
        case .easy: return 4
        case .medium: return 3
        case .hard: return 3
        }
    }

    /// How far before a relocation the yellow preview ring appears at the
    /// next spot (so the player can start rolling there early)
    var previewLeadTime: Double {
        switch self {
        case .easy: return 3.0
        case .medium: return 2.5
        case .hard: return 2.0
        }
    }

    /// How far the zone jumps when it relocates, in points
    var hopDistanceRange: ClosedRange<Double> {
        switch self {
        case .easy: return 60...110
        case .medium: return 90...150
        case .hard: return 130...200
        }
    }

    /// How fast the zone glides to its next spot, pt/s. Slow enough that the
    /// marble can ride along inside it and keep accruing hold progress.
    var zoneGlideSpeed: Double {
        switch self {
        case .easy: return 35
        case .medium: return 50
        case .hard: return 70
        }
    }

}

/// Difficulty for the "Meteor Defense" mission: how many meteors to destroy and
/// how hard they press the shield line.
enum MeteorDifficulty: String, Codable, CaseIterable {
    case easy = "Easy"
    case medium = "Medium"
    case hard = "Hard"

    /// Meteors the player must destroy to dismiss
    var targetsToDestroy: Int {
        switch self {
        case .easy: return 8
        case .medium: return 12
        case .hard: return 18
        }
    }

    /// Descent speed in panel points per second
    var descentSpeed: CGFloat {
        switch self {
        case .easy: return 28
        case .medium: return 38
        case .hard: return 50
        }
    }

    /// Seconds between meteor spawns
    var spawnInterval: Double {
        switch self {
        case .easy: return 1.6
        case .medium: return 1.2
        case .hard: return 0.9
        }
    }

    /// Seconds between bolts while the finger is held. SLOWER fire on harder tiers — with
    /// fewer bolts in the air, positioning matters more per shot (a faster
    /// gun would make hard mode EASIER).
    var fireInterval: Double {
        switch self {
        case .easy: return 0.45
        case .medium: return 0.55
        case .hard: return 0.70
        }
    }

    /// Cap on simultaneously visible meteors (readability, not challenge)
    var maxConcurrent: Int {
        switch self {
        case .easy: return 4
        case .medium: return 5
        case .hard: return 7
        }
    }
}

enum BlockDropDifficulty: String, Codable, CaseIterable {
    case easy = "Easy"
    case medium = "Medium"
    case hard = "Hard"

    /// Rows the player must clear (in total, across board resets) to dismiss
    var linesToClear: Int {
        switch self {
        case .easy: return 2
        case .medium: return 3
        case .hard: return 5
        }
    }

    /// Seconds between gravity steps for the falling piece
    var dropInterval: Double {
        switch self {
        case .easy: return 0.9
        case .medium: return 0.65
        case .hard: return 0.4
        }
    }

    /// Pre-filled rows at the bottom of a fresh board. Their gaps give the
    /// player nearly-complete rows to finish — the assist that keeps lower
    /// difficulties tractable half-awake. The assist scales DOWN with
    /// difficulty: easy is mostly slotting, medium mixes slotting with
    /// building, hard starts on an EMPTY board and builds every line from
    /// scratch (pre-filled rows made even hard play too easy).
    var garbageRowCount: Int {
        switch self {
        case .easy: return 3
        case .medium: return 2
        case .hard: return 0
        }
    }

    /// Width of the empty gap in each pre-filled row
    var garbageGapWidth: Int {
        switch self {
        case .easy: return 2
        case .medium: return 2
        case .hard: return 1
        }
    }

    /// Whether the gaps line up vertically (one well, fillable with a single
    /// well-placed piece) or wander between rows (each row needs its own fill).
    /// Hard's gaps are 1-wide AND wander: an aligned 1-wide well turned out to
    /// play too easy (park a vertical I and wait), so hard makes every row an
    /// individual precision drop at speed.
    var garbageGapsAligned: Bool {
        switch self {
        case .easy: return true
        case .medium: return false
        case .hard: return false
        }
    }

    /// Rough seconds a player needs per cleared line (grace-period estimate).
    /// Scales with how much of each line must be built from scratch.
    var estimatedSecondsPerLine: Double {
        switch self {
        case .easy: return 20
        case .medium: return 24
        case .hard: return 30
        }
    }
}

enum MathDifficulty: String, Codable, CaseIterable {
    case superEasy = "Super Easy"
    case easy = "Easy"
    case medium = "Medium"
    case hard = "Hard"
    
    var range: ClosedRange<Int> {
        switch self {
        case .superEasy: return 1...9
        case .easy: return 1...10
        case .medium: return 10...50
        case .hard: return 50...100
        }
    }

    /// UI-facing label. The rawValue ("Super Easy") is storage/MQTT and must
    /// NOT change, but it's too long for the equal-width difficulty chips —
    /// minimumScaleFactor shrinks it next to the shorter siblings, which reads
    /// badly — so every user-visible surface shows the shorter "Easiest".
    var displayLabel: String {
        switch self {
        case .superEasy: return "Easiest"
        default:         return rawValue
        }
    }
}

struct Mission: Equatable, Sendable {
    var type: MissionType = .none

    // Tap ("None"/Tap type) dismiss properties. Only meaningful when type == .none.
    // Defaults reproduce today's single-tap dismiss exactly (mode .tap, count 1).
    var tapDismissMode: TapDismissMode = .tap
    var tapCount: Int = 1            // 1...50 taps to dismiss (tap mode)
    var tapHoldDuration: Double = 3  // seconds to hold the dismiss chip (hold mode)

    /// DISPLAY-ONLY flag: the user explicitly picked the Tap tile in the slot
    /// editor. It distinguishes an intentionally-chosen plain single-tap slot
    /// (which should render as a filled card) from the untouched default slot
    /// (which reads as empty → add-box). It has NO runtime meaning: a solo
    /// single-tap alarm stays missionless whether or not this is set — see
    /// Alarm.missionSequence, which deliberately ignores it.
    var tapExplicitlyChosen: Bool = false

    /// True when this Tap mission demands more than a single tap — a hold, or a
    /// multi-tap count. Such an alarm is a REAL mission: it must open the app and
    /// use CompleteMissionIntent (never a background stop that would bypass the
    /// taps). A plain single-tap Tap mission (mode .tap, count 1) is NOT a mission
    /// and behaves byte-for-byte like today's missionless alarm.
    var tapDismissIsMission: Bool {
        guard type == .none else { return false }
        switch tapDismissMode {
        case .tap:  return tapCount > 1
        case .hold: return true
        }
    }

    // Shake properties
    var shakeMode: ShakeMode = .duration
    var shakeDuration: Int = 10 // seconds
    var shakeCount: Int = 20
    var shakeIntensity: ShakeIntensity = .medium
    
    // Math properties
    var mathProblemCount: Int = 3
    var mathDifficulty: MathDifficulty = .easy

    // Balance Ball properties
    var balanceDifficulty: BalanceDifficulty = .medium
    /// Per-alarm hold-time override in seconds. nil = use the difficulty's
    /// default hold duration.
    var balanceHoldOverride: Double? = nil
    /// Per-alarm target (dismiss-zone) radius override in points. nil = use the
    /// difficulty's preset radius. ~24...60.
    var balanceZoneRadiusOverride: Double? = nil
    /// Per-alarm override for how many seconds the target sits before it
    /// relocates. nil = use the difficulty's preset dwell. ~2...10.
    var balanceZoneDwellOverride: Double? = nil

    /// The hold time this alarm actually requires (override wins).
    var effectiveBalanceHoldDuration: Double {
        balanceHoldOverride ?? balanceDifficulty.holdDuration
    }
    /// The target radius this alarm actually uses (override wins).
    var effectiveBalanceZoneRadius: Double {
        balanceZoneRadiusOverride ?? balanceDifficulty.zoneRadius
    }
    /// The seconds-between-relocations this alarm actually uses (override wins).
    var effectiveBalanceZoneDwell: Double {
        balanceZoneDwellOverride ?? balanceDifficulty.zoneDwellDuration
    }

    /// Friendly Small/Medium/Large name for a target radius, bucketing the
    /// 24...60 pt range around the difficulty presets (28 / 36 / 46). Used by
    /// the customize control and the summary so an overridden size still reads
    /// in words.
    static func balanceTargetSizeLabel(forRadius r: Double) -> String {
        switch r {
        case ..<32: return "Small"
        case ..<44: return "Medium"
        default:    return "Large"
        }
    }
    var balanceTargetSizeLabel: String {
        Mission.balanceTargetSizeLabel(forRadius: effectiveBalanceZoneRadius)
    }

    // Block Drop properties. The difficulty supplies every tuning value;
    // each nil override falls back to it. Picking a difficulty in the UI
    // clears all overrides (see MissionSelectorView.blockDropSettings), so
    // Easy/Medium/Hard always mean their stock tuning.
    var blockDropDifficulty: BlockDropDifficulty = .medium
    var meteorDifficulty: MeteorDifficulty = .medium
    /// Fine-tune overrides layered on the Meteor difficulty preset (nil = preset).
    /// Every game mission exposes manual tuning — difficulty chips are presets,
    /// not the ceiling (see 05-MISSIONS.md "Manual adjustability rule").
    var meteorTargetsOverride: Int?
    var meteorFireIntervalOverride: Double?

    /// Effective Meteor values: override when set, else the difficulty preset.
    var effectiveMeteorTargets: Int {
        meteorTargetsOverride ?? meteorDifficulty.targetsToDestroy
    }
    var effectiveMeteorFireInterval: Double {
        meteorFireIntervalOverride ?? meteorDifficulty.fireInterval
    }
    var blockDropLinesOverride: Int? = nil
    var blockDropIntervalOverride: Double? = nil
    var blockDropGarbageRowsOverride: Int? = nil
    var blockDropGapWidthOverride: Int? = nil
    var blockDropGapsAlignedOverride: Bool? = nil

    var effectiveBlockDropLines: Int {
        blockDropLinesOverride ?? blockDropDifficulty.linesToClear
    }
    var effectiveBlockDropInterval: Double {
        blockDropIntervalOverride ?? blockDropDifficulty.dropInterval
    }
    var effectiveBlockDropGarbageRows: Int {
        blockDropGarbageRowsOverride ?? blockDropDifficulty.garbageRowCount
    }
    var effectiveBlockDropGapWidth: Int {
        blockDropGapWidthOverride ?? blockDropDifficulty.garbageGapWidth
    }
    var effectiveBlockDropGapsAligned: Bool {
        blockDropGapsAlignedOverride ?? blockDropDifficulty.garbageGapsAligned
    }

    // Home Assistant mission properties
    var haSnoozeMode: HASnoozeMode = .normal    // How snooze works for HA missions
    var haFallbackMission: MissionType = .none  // Fallback when MQTT disconnected
    
    // Dismiss fallback config (independent from primary shake/math settings)
    var haFallbackShakeMode: ShakeMode = .duration
    var haFallbackShakeDuration: Int = 10
    var haFallbackShakeCount: Int = 20
    var haFallbackShakeIntensity: ShakeIntensity = .medium
    var haFallbackMathProblemCount: Int = 3
    var haFallbackMathDifficulty: MathDifficulty = .easy
    var haFallbackBalanceDifficulty: BalanceDifficulty = .medium
    /// Bricks / Meteor as HA fallbacks. They were previously excluded from the
    /// fallback grid, so there was nowhere to store their difficulty; without
    /// these the fallback would always run at the type's default.
    var haFallbackBlockDropDifficulty: BlockDropDifficulty = .medium
    var haFallbackMeteorDifficulty: MeteorDifficulty = .medium
    /// Tap-as-fallback carries the same three knobs the primary Tap mission has.
    /// Without them a Tap fallback was always a single tap, so "tap 10 times"
    /// could be configured as a mission but not as a backup.
    var haFallbackTapDismissMode: TapDismissMode = .tap
    var haFallbackTapCount: Int = 1
    var haFallbackTapHoldDuration: Double = 3
    /// Per-type overrides, mirroring the primary mission's nil-able overrides so
    /// a fallback can be tuned past its difficulty preset.
    var haFallbackBlockDropLinesOverride: Int? = nil
    var haFallbackBlockDropIntervalOverride: Double? = nil
    var haFallbackBlockDropGarbageRowsOverride: Int? = nil
    var haFallbackBlockDropGapWidthOverride: Int? = nil
    var haFallbackBlockDropGapsAlignedOverride: Bool? = nil
    var haFallbackMeteorTargetsOverride: Int? = nil
    var haFallbackMeteorFireIntervalOverride: Double? = nil
    var haFallbackBalanceHoldOverride: Double? = nil
    var haFallbackGracePeriod: Double = 0  // 0 = auto
    
    // Snooze fallback (how snooze works when MQTT offline and haSnoozeMode == .homeAssistant)
    var haSnoozeFallback: SnoozeMode = .hold  // hold, tap, or disabled
    var haSnoozeFallbackDuration: Int = 5
    var haSnoozeFallbackMaxCount: Int = 3
    var haSnoozeFallbackHoldDuration: Double = 1.5
    
    // Alert properties (only used when type == .alert, set via MQTT)
    var alertTitle: String?
    var alertMessage: String?
    
    static let defaultMission = Mission()
    
    /// Human-readable summary of the current mission settings
    var summaryText: String {
        switch type {
        case .none:
            switch tapDismissMode {
            case .tap:  return tapCount <= 1 ? "Single tap" : "\(tapCount) taps"
            case .hold: return "Hold · \(Int(tapHoldDuration))s"
            }
        case .shake:
            switch shakeMode {
            case .duration:
                return "Shake · \(shakeDuration)s · \(shakeIntensity.rawValue)"
            case .count:
                return "Shake · \(shakeCount) shakes · \(shakeIntensity.rawValue)"
            }
        case .math:
            return "\(mathProblemCount) Problem\(mathProblemCount == 1 ? "" : "s") · \(mathDifficulty.displayLabel)"
        case .balanceBall:
            var s = "Balance · \(balanceDifficulty.rawValue) · \(Int(effectiveBalanceHoldDuration))s hold"
            if balanceZoneRadiusOverride != nil {
                s += " · \(balanceTargetSizeLabel) target"
            }
            if balanceZoneDwellOverride != nil {
                s += " · moves \(Int(effectiveBalanceZoneDwell))s"
            }
            return s
        case .blockDrop:
            let lines = effectiveBlockDropLines
            return "Bricks · \(blockDropDifficulty.rawValue) · \(lines) line\(lines == 1 ? "" : "s")"
        case .meteor:
            return "Meteor · \(meteorDifficulty.rawValue) · \(effectiveMeteorTargets) meteors"
        case .homeAssistant:
            return "Controlled via MQTT"
        case .alert:
            return "MQTT Alert"
        }
    }
    
    /// Build a Mission struct from the dismiss fallback config
    var dismissFallbackMission: Mission {
        var m = Mission()
        m.type = haFallbackMission
        m.shakeMode = haFallbackShakeMode
        m.shakeDuration = haFallbackShakeDuration
        m.shakeCount = haFallbackShakeCount
        m.shakeIntensity = haFallbackShakeIntensity
        m.mathProblemCount = haFallbackMathProblemCount
        m.mathDifficulty = haFallbackMathDifficulty
        m.balanceDifficulty = haFallbackBalanceDifficulty
        m.blockDropDifficulty = haFallbackBlockDropDifficulty
        m.meteorDifficulty = haFallbackMeteorDifficulty
        m.tapDismissMode = haFallbackTapDismissMode
        m.tapCount = haFallbackTapCount
        m.tapHoldDuration = haFallbackTapHoldDuration
        m.blockDropLinesOverride = haFallbackBlockDropLinesOverride
        m.blockDropIntervalOverride = haFallbackBlockDropIntervalOverride
        m.blockDropGarbageRowsOverride = haFallbackBlockDropGarbageRowsOverride
        m.blockDropGapWidthOverride = haFallbackBlockDropGapWidthOverride
        m.blockDropGapsAlignedOverride = haFallbackBlockDropGapsAlignedOverride
        m.meteorTargetsOverride = haFallbackMeteorTargetsOverride
        m.meteorFireIntervalOverride = haFallbackMeteorFireIntervalOverride
        m.balanceHoldOverride = haFallbackBalanceHoldOverride
        return m
    }
    
    
    /// Dynamically calculated grace period in seconds based on mission difficulty.
    /// This is how long the alarm sound is muted while the user works on the mission.
    var calculatedGracePeriod: Double {
        switch type {
        case .homeAssistant, .alert:
            return 0

        case .none:
            // A plain single tap has NO grace — byte-for-byte the old missionless
            // dismiss. Multi-tap and hold ARE real missions and earn a grace
            // period plus a 12s buffer (per the 10–15s guidance). The countdown is
            // paused while the user is actively tapping / holding (see
            // ActiveAlarmView's grace activity-pause), so the buffer only has to
            // cover getting oriented, not the whole interaction.
            guard tapDismissIsMission else { return 0 }
            switch tapDismissMode {
            case .tap:  return Double(tapCount) * 0.5 + 12.0
            case .hold: return tapHoldDuration + 12.0
            }

        case .shake:
            switch shakeMode {
            case .duration:
                // Shake duration + 15s buffer
                return Double(shakeDuration) + 15.0
                
            case .count:
                // Estimate time: shakes per second depends on intensity
                let shakesPerSecond: Double
                switch shakeIntensity {
                case .light:    shakesPerSecond = 3.0
                case .medium:   shakesPerSecond = 2.0
                case .vigorous: shakesPerSecond = 1.5
                }
                let estimatedTime = Double(shakeCount) / shakesPerSecond
                return estimatedTime + 15.0
            }

        case .balanceBall:
            // Deliberately tight: the effective hold time plus 10s. The player
            // EARNS additional grace (+2s per full second in-zone, see
            // BalanceGameModel.onGraceEarned) by actually balancing, so active
            // play stays quiet while dawdling runs the budget out.
            return effectiveBalanceHoldDuration + 10

        case .blockDrop:
            // Flat base. The countdown pauses while the player is actively
            // stacking (any input, piece-lock, or line-clear refreshes the pause
            // window — see ActiveAlarmView's grace activity-pause), so a
            // lines-scaled budget is unnecessary; the old lines×perLine+buffer was
            // far too long. A per-alarm custom grace still overrides this.
            return 20

        case .meteor:
            // Per-meteor time scales with the fire interval (a slow gun can't
            // clear faster than it shoots), plus an orientation buffer. Like
            // Bricks, the countdown pauses while the player is actively
            // blasting (every destroyed meteor / drag refreshes the pause
            // window), so this only covers orientation and wave lulls.
            let perMeteor = max(2.0, effectiveMeteorFireInterval * 3.0)
            return Double(effectiveMeteorTargets) * perMeteor + 15.0

        case .math:
            // Time per problem depends on difficulty
            let secondsPerProblem: Double
            switch mathDifficulty {
            case .superEasy: secondsPerProblem = 5.0
            case .easy:      secondsPerProblem = 8.0
            case .medium:    secondsPerProblem = 15.0
            case .hard:      secondsPerProblem = 25.0
            }
            // Extra buffer for the time spent reading/orienting on the math screen
            // before typing the first digit (grace period now starts on screen appear).
            let viewingBuffer: Double
            switch mathDifficulty {
            case .superEasy: viewingBuffer = 5.0
            case .easy:      viewingBuffer = 8.0
            case .medium:    viewingBuffer = 12.0
            case .hard:      viewingBuffer = 15.0
            }
            return Double(mathProblemCount) * secondsPerProblem + 10.0 + viewingBuffer
        }
    }
}
// Explicit Codable conformance to avoid MainActor isolation
extension Mission: Codable {
    enum CodingKeys: String, CodingKey {
        case type
        case tapDismissMode, tapCount, tapHoldDuration, tapExplicitlyChosen
        case shakeMode, shakeDuration, shakeCount, shakeIntensity
        case mathProblemCount, mathDifficulty
        case balanceDifficulty, balanceHoldOverride, balanceZoneRadiusOverride, balanceZoneDwellOverride
        case blockDropDifficulty
        case meteorDifficulty, meteorTargetsOverride, meteorFireIntervalOverride
        case blockDropLinesOverride, blockDropIntervalOverride
        case blockDropGarbageRowsOverride, blockDropGapWidthOverride, blockDropGapsAlignedOverride
        case haSnoozeMode, haFallbackMission
        case haFallbackShakeMode, haFallbackShakeDuration, haFallbackShakeCount, haFallbackShakeIntensity
        case haFallbackMathProblemCount, haFallbackMathDifficulty, haFallbackBalanceDifficulty, haFallbackGracePeriod
        case haFallbackBlockDropDifficulty, haFallbackMeteorDifficulty
        case haFallbackTapDismissMode, haFallbackTapCount, haFallbackTapHoldDuration
        case haFallbackBlockDropLinesOverride, haFallbackBlockDropIntervalOverride
        case haFallbackBlockDropGarbageRowsOverride, haFallbackBlockDropGapWidthOverride
        case haFallbackBlockDropGapsAlignedOverride
        case haFallbackMeteorTargetsOverride, haFallbackMeteorFireIntervalOverride
        case haFallbackBalanceHoldOverride
        case haSnoozeFallback, haSnoozeFallbackDuration, haSnoozeFallbackMaxCount, haSnoozeFallbackHoldDuration
        case alertTitle, alertMessage
    }
    
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(MissionType.self, forKey: .type)
        tapDismissMode = try container.decodeIfPresent(TapDismissMode.self, forKey: .tapDismissMode) ?? .tap
        tapCount = try container.decodeIfPresent(Int.self, forKey: .tapCount) ?? 1
        tapHoldDuration = try container.decodeIfPresent(Double.self, forKey: .tapHoldDuration) ?? 3
        tapExplicitlyChosen = try container.decodeIfPresent(Bool.self, forKey: .tapExplicitlyChosen) ?? false
        shakeMode = try container.decode(ShakeMode.self, forKey: .shakeMode)
        shakeDuration = try container.decode(Int.self, forKey: .shakeDuration)
        shakeCount = try container.decode(Int.self, forKey: .shakeCount)
        shakeIntensity = try container.decode(ShakeIntensity.self, forKey: .shakeIntensity)
        mathProblemCount = try container.decode(Int.self, forKey: .mathProblemCount)
        mathDifficulty = try container.decode(MathDifficulty.self, forKey: .mathDifficulty)
        balanceDifficulty = try container.decodeIfPresent(BalanceDifficulty.self, forKey: .balanceDifficulty) ?? .medium
        balanceHoldOverride = try container.decodeIfPresent(Double.self, forKey: .balanceHoldOverride)
        balanceZoneRadiusOverride = try container.decodeIfPresent(Double.self, forKey: .balanceZoneRadiusOverride)
        balanceZoneDwellOverride = try container.decodeIfPresent(Double.self, forKey: .balanceZoneDwellOverride)
        blockDropDifficulty = try container.decodeIfPresent(BlockDropDifficulty.self, forKey: .blockDropDifficulty) ?? .medium
        meteorDifficulty = try container.decodeIfPresent(MeteorDifficulty.self, forKey: .meteorDifficulty) ?? .medium
        meteorTargetsOverride = try container.decodeIfPresent(Int.self, forKey: .meteorTargetsOverride)
        meteorFireIntervalOverride = try container.decodeIfPresent(Double.self, forKey: .meteorFireIntervalOverride)
        blockDropLinesOverride = try container.decodeIfPresent(Int.self, forKey: .blockDropLinesOverride)
        blockDropIntervalOverride = try container.decodeIfPresent(Double.self, forKey: .blockDropIntervalOverride)
        blockDropGarbageRowsOverride = try container.decodeIfPresent(Int.self, forKey: .blockDropGarbageRowsOverride)
        blockDropGapWidthOverride = try container.decodeIfPresent(Int.self, forKey: .blockDropGapWidthOverride)
        blockDropGapsAlignedOverride = try container.decodeIfPresent(Bool.self, forKey: .blockDropGapsAlignedOverride)
        haSnoozeMode = try container.decodeIfPresent(HASnoozeMode.self, forKey: .haSnoozeMode) ?? .normal
        haFallbackMission = try container.decodeIfPresent(MissionType.self, forKey: .haFallbackMission) ?? .none
        haFallbackShakeMode = try container.decodeIfPresent(ShakeMode.self, forKey: .haFallbackShakeMode) ?? .duration
        haFallbackShakeDuration = try container.decodeIfPresent(Int.self, forKey: .haFallbackShakeDuration) ?? 10
        haFallbackShakeCount = try container.decodeIfPresent(Int.self, forKey: .haFallbackShakeCount) ?? 20
        haFallbackShakeIntensity = try container.decodeIfPresent(ShakeIntensity.self, forKey: .haFallbackShakeIntensity) ?? .medium
        haFallbackMathProblemCount = try container.decodeIfPresent(Int.self, forKey: .haFallbackMathProblemCount) ?? 3
        haFallbackMathDifficulty = try container.decodeIfPresent(MathDifficulty.self, forKey: .haFallbackMathDifficulty) ?? .easy
        haFallbackBalanceDifficulty = try container.decodeIfPresent(BalanceDifficulty.self, forKey: .haFallbackBalanceDifficulty) ?? .medium
        haFallbackBlockDropDifficulty = try container.decodeIfPresent(BlockDropDifficulty.self, forKey: .haFallbackBlockDropDifficulty) ?? .medium
        haFallbackMeteorDifficulty = try container.decodeIfPresent(MeteorDifficulty.self, forKey: .haFallbackMeteorDifficulty) ?? .medium
        haFallbackTapDismissMode = try container.decodeIfPresent(TapDismissMode.self, forKey: .haFallbackTapDismissMode) ?? .tap
        haFallbackTapCount = try container.decodeIfPresent(Int.self, forKey: .haFallbackTapCount) ?? 1
        haFallbackTapHoldDuration = try container.decodeIfPresent(Double.self, forKey: .haFallbackTapHoldDuration) ?? 3
        haFallbackBlockDropLinesOverride = try container.decodeIfPresent(Int.self, forKey: .haFallbackBlockDropLinesOverride)
        haFallbackBlockDropIntervalOverride = try container.decodeIfPresent(Double.self, forKey: .haFallbackBlockDropIntervalOverride)
        haFallbackBlockDropGarbageRowsOverride = try container.decodeIfPresent(Int.self, forKey: .haFallbackBlockDropGarbageRowsOverride)
        haFallbackBlockDropGapWidthOverride = try container.decodeIfPresent(Int.self, forKey: .haFallbackBlockDropGapWidthOverride)
        haFallbackBlockDropGapsAlignedOverride = try container.decodeIfPresent(Bool.self, forKey: .haFallbackBlockDropGapsAlignedOverride)
        haFallbackMeteorTargetsOverride = try container.decodeIfPresent(Int.self, forKey: .haFallbackMeteorTargetsOverride)
        haFallbackMeteorFireIntervalOverride = try container.decodeIfPresent(Double.self, forKey: .haFallbackMeteorFireIntervalOverride)
        haFallbackBalanceHoldOverride = try container.decodeIfPresent(Double.self, forKey: .haFallbackBalanceHoldOverride)
        haFallbackGracePeriod = try container.decodeIfPresent(Double.self, forKey: .haFallbackGracePeriod) ?? 0
        haSnoozeFallback = try container.decodeIfPresent(SnoozeMode.self, forKey: .haSnoozeFallback) ?? .hold
        haSnoozeFallbackDuration = try container.decodeIfPresent(Int.self, forKey: .haSnoozeFallbackDuration) ?? 5
        haSnoozeFallbackMaxCount = try container.decodeIfPresent(Int.self, forKey: .haSnoozeFallbackMaxCount) ?? 3
        haSnoozeFallbackHoldDuration = try container.decodeIfPresent(Double.self, forKey: .haSnoozeFallbackHoldDuration) ?? 1.5
        alertTitle = try container.decodeIfPresent(String.self, forKey: .alertTitle)
        alertMessage = try container.decodeIfPresent(String.self, forKey: .alertMessage)
    }
    
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(tapDismissMode, forKey: .tapDismissMode)
        try container.encode(tapCount, forKey: .tapCount)
        try container.encode(tapHoldDuration, forKey: .tapHoldDuration)
        try container.encode(tapExplicitlyChosen, forKey: .tapExplicitlyChosen)
        try container.encode(shakeMode, forKey: .shakeMode)
        try container.encode(shakeDuration, forKey: .shakeDuration)
        try container.encode(shakeCount, forKey: .shakeCount)
        try container.encode(shakeIntensity, forKey: .shakeIntensity)
        try container.encode(mathProblemCount, forKey: .mathProblemCount)
        try container.encode(mathDifficulty, forKey: .mathDifficulty)
        try container.encode(balanceDifficulty, forKey: .balanceDifficulty)
        try container.encodeIfPresent(balanceHoldOverride, forKey: .balanceHoldOverride)
        try container.encodeIfPresent(balanceZoneRadiusOverride, forKey: .balanceZoneRadiusOverride)
        try container.encodeIfPresent(balanceZoneDwellOverride, forKey: .balanceZoneDwellOverride)
        try container.encode(blockDropDifficulty, forKey: .blockDropDifficulty)
        try container.encode(meteorDifficulty, forKey: .meteorDifficulty)
        try container.encodeIfPresent(meteorTargetsOverride, forKey: .meteorTargetsOverride)
        try container.encodeIfPresent(meteorFireIntervalOverride, forKey: .meteorFireIntervalOverride)
        try container.encodeIfPresent(blockDropLinesOverride, forKey: .blockDropLinesOverride)
        try container.encodeIfPresent(blockDropIntervalOverride, forKey: .blockDropIntervalOverride)
        try container.encodeIfPresent(blockDropGarbageRowsOverride, forKey: .blockDropGarbageRowsOverride)
        try container.encodeIfPresent(blockDropGapWidthOverride, forKey: .blockDropGapWidthOverride)
        try container.encodeIfPresent(blockDropGapsAlignedOverride, forKey: .blockDropGapsAlignedOverride)
        try container.encode(haSnoozeMode, forKey: .haSnoozeMode)
        try container.encode(haFallbackMission, forKey: .haFallbackMission)
        try container.encode(haFallbackShakeMode, forKey: .haFallbackShakeMode)
        try container.encode(haFallbackShakeDuration, forKey: .haFallbackShakeDuration)
        try container.encode(haFallbackShakeCount, forKey: .haFallbackShakeCount)
        try container.encode(haFallbackShakeIntensity, forKey: .haFallbackShakeIntensity)
        try container.encode(haFallbackMathProblemCount, forKey: .haFallbackMathProblemCount)
        try container.encode(haFallbackMathDifficulty, forKey: .haFallbackMathDifficulty)
        try container.encode(haFallbackBalanceDifficulty, forKey: .haFallbackBalanceDifficulty)
        try container.encode(haFallbackBlockDropDifficulty, forKey: .haFallbackBlockDropDifficulty)
        try container.encode(haFallbackMeteorDifficulty, forKey: .haFallbackMeteorDifficulty)
        try container.encode(haFallbackTapDismissMode, forKey: .haFallbackTapDismissMode)
        try container.encode(haFallbackTapCount, forKey: .haFallbackTapCount)
        try container.encode(haFallbackTapHoldDuration, forKey: .haFallbackTapHoldDuration)
        try container.encodeIfPresent(haFallbackBlockDropLinesOverride, forKey: .haFallbackBlockDropLinesOverride)
        try container.encodeIfPresent(haFallbackBlockDropIntervalOverride, forKey: .haFallbackBlockDropIntervalOverride)
        try container.encodeIfPresent(haFallbackBlockDropGarbageRowsOverride, forKey: .haFallbackBlockDropGarbageRowsOverride)
        try container.encodeIfPresent(haFallbackBlockDropGapWidthOverride, forKey: .haFallbackBlockDropGapWidthOverride)
        try container.encodeIfPresent(haFallbackBlockDropGapsAlignedOverride, forKey: .haFallbackBlockDropGapsAlignedOverride)
        try container.encodeIfPresent(haFallbackMeteorTargetsOverride, forKey: .haFallbackMeteorTargetsOverride)
        try container.encodeIfPresent(haFallbackMeteorFireIntervalOverride, forKey: .haFallbackMeteorFireIntervalOverride)
        try container.encodeIfPresent(haFallbackBalanceHoldOverride, forKey: .haFallbackBalanceHoldOverride)
        try container.encode(haFallbackGracePeriod, forKey: .haFallbackGracePeriod)
        try container.encode(haSnoozeFallback, forKey: .haSnoozeFallback)
        try container.encode(haSnoozeFallbackDuration, forKey: .haSnoozeFallbackDuration)
        try container.encode(haSnoozeFallbackMaxCount, forKey: .haSnoozeFallbackMaxCount)
        try container.encode(haSnoozeFallbackHoldDuration, forKey: .haSnoozeFallbackHoldDuration)
        try container.encodeIfPresent(alertTitle, forKey: .alertTitle)
        try container.encodeIfPresent(alertMessage, forKey: .alertMessage)
    }
}

// MARK: - Math Problem Generation

struct MathProblem {
    let question: String
    let answer: Int
    
    /// Generate a sample problem for the given difficulty
    static func generate(for difficulty: MathDifficulty) -> MathProblem {
        switch difficulty {
        case .superEasy: generateSuperEasy()
        case .easy: generateEasy()
        case .medium: generateMedium()
        case .hard: generateHard()
        }
    }
    
    // Super Easy: single-digit (1–9) two-number addition or subtraction, always positive result
    static func generateSuperEasy() -> MathProblem {
        if Bool.random() {
            // Addition: a + b
            let a = Int.random(in: 1...9), b = Int.random(in: 1...9)
            return MathProblem(question: "\(a) + \(b)", answer: a + b)
        } else {
            // Subtraction: a - b (always positive, a > b)
            let a = Int.random(in: 2...9)
            let b = Int.random(in: 1...(a - 1))
            return MathProblem(question: "\(a) - \(b)", answer: a - b)
        }
    }

    // Easy: three-number addition/subtraction only, always positive result
    static func generateEasy() -> MathProblem {
        switch Int.random(in: 0...3) {
        case 0:
            // a + b + c
            let a = Int.random(in: 1...25), b = Int.random(in: 1...25), c = Int.random(in: 1...25)
            return MathProblem(question: "\(a) + \(b) + \(c)", answer: a + b + c)
        case 1:
            // a + b - c (result always positive)
            let a = Int.random(in: 5...30), b = Int.random(in: 5...30)
            let c = Int.random(in: 1...(a + b - 1))
            return MathProblem(question: "\(a) + \(b) - \(c)", answer: a + b - c)
        case 2:
            // a - b + c (intermediate always positive)
            let a = Int.random(in: 10...35)
            let b = Int.random(in: 1...(a - 1))
            let c = Int.random(in: 1...25)
            return MathProblem(question: "\(a) - \(b) + \(c)", answer: a - b + c)
        default:
            // a - b - c (result always positive)
            let a = Int.random(in: 15...40)
            let b = Int.random(in: 1...(a / 2))
            let c = Int.random(in: 1...(a - b - 1))
            return MathProblem(question: "\(a) - \(b) - \(c)", answer: a - b - c)
        }
    }

    // Medium: mixed operations with order-of-operations (e.g. 35 + 7 × 4, 8 × 9 - 15)
    static func generateMedium() -> MathProblem {
        switch Int.random(in: 0...3) {
        case 0:
            // a + b × c
            let a = Int.random(in: 10...80)
            let b = Int.random(in: 2...12), c = Int.random(in: 2...12)
            let answer = a + b * c
            return MathProblem(question: "\(a) + \(b) × \(c)", answer: answer)
        case 1:
            // a × b + c
            let a = Int.random(in: 2...15), b = Int.random(in: 2...15)
            let c = Int.random(in: 10...80)
            let answer = a * b + c
            return MathProblem(question: "\(a) × \(b) + \(c)", answer: answer)
        case 2:
            // a × b - c (result always positive)
            let a = Int.random(in: 3...15), b = Int.random(in: 3...12)
            let product = a * b
            let c = Int.random(in: 1...(product - 1))
            let answer = product - c
            return MathProblem(question: "\(a) × \(b) - \(c)", answer: answer)
        default:
            // a + b + c + d (four-number addition)
            let a = Int.random(in: 10...50), b = Int.random(in: 10...50)
            let c = Int.random(in: 10...50), d = Int.random(in: 10...50)
            return MathProblem(question: "\(a) + \(b) + \(c) + \(d)", answer: a + b + c + d)
        }
    }

    // Hard: large multi-digit operations (e.g. 47 × 8 + 135, 23 × 7 - 89, 6 × 14 + 9 × 5)
    static func generateHard() -> MathProblem {
        switch Int.random(in: 0...3) {
        case 0:
            // a × b + c (large numbers)
            let a = Int.random(in: 12...99), b = Int.random(in: 3...25)
            let c = Int.random(in: 50...300)
            let answer = a * b + c
            return MathProblem(question: "\(a) × \(b) + \(c)", answer: answer)
        case 1:
            // a × b - c (result always positive)
            let a = Int.random(in: 15...80), b = Int.random(in: 3...15)
            let product = a * b
            let c = Int.random(in: 10...min(product - 1, 500))
            let answer = product - c
            return MathProblem(question: "\(a) × \(b) - \(c)", answer: answer)
        case 2:
            // a + b × c (large numbers)
            let a = Int.random(in: 50...300)
            let b = Int.random(in: 10...50), c = Int.random(in: 3...15)
            let answer = a + b * c
            return MathProblem(question: "\(a) + \(b) × \(c)", answer: answer)
        default:
            // a × b + c × d (two multiplications)
            let a = Int.random(in: 3...15), b = Int.random(in: 3...12)
            let c = Int.random(in: 3...15), d = Int.random(in: 3...12)
            let answer = a * b + c * d
            return MathProblem(question: "\(a) × \(b) + \(c) × \(d)", answer: answer)
        }
    }
}

// MARK: - Math Problem Preview Row

import SwiftUI

/// Reusable row that shows an example math problem for a given difficulty, with a refresh button.
struct MathProblemPreviewRow: View {
    let difficulty: MathDifficulty
    @State private var problem: MathProblem
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }

    init(difficulty: MathDifficulty) {
        self.difficulty = difficulty
        self._problem = State(initialValue: MathProblem.generate(for: difficulty))
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Example")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(problem.question) = \(problem.answer)")
                    .font(.body.monospaced())
                    .foregroundStyle(.primary)
            }
            
            Spacer()
            
            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    problem = MathProblem.generate(for: difficulty)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
                    .foregroundStyle(accent)
            }
            .buttonStyle(.borderless)
        }
        .onChange(of: difficulty) { _, newDifficulty in
            problem = MathProblem.generate(for: newDifficulty)
        }
    }
}

