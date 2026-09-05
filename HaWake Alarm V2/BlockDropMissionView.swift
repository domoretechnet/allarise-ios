//
//  BlockDropMissionView.swift
//  HaWake Alarm V2
//
//  "Block Drop" dismissal mission: a falling-blocks puzzle. The board starts
//  with pre-filled rows whose gaps the player fills to clear lines — clearing
//  N lines (per difficulty) dismisses the alarm. Stack reaching the top resets
//  the board but keeps line progress, so the mission can never dead-end.
//
//  Controls: drag horizontally to move, tap to rotate, swipe down (or the
//  drop button) to hard-drop. Frosted-glass buttons mirror the app's bubble
//  convention for reliable half-awake input.
//

import SwiftUI
import Combine

// MARK: - Cells and pieces

/// A settled or falling cell's color identity. Piece colors are deliberately
/// semantic/constant across themes (like the balance mission's green zone) so
/// the seven shapes stay instantly recognizable; the theme accent is reserved
/// for chrome (progress, buttons, grace ring).
enum BlockCell: Equatable {
    case i, o, t, s, z, j, l, garbage

    /// Base body color (sRGB 0–1)
    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .i:       return (0.25, 0.78, 0.94)   // cyan
        case .o:       return (1.00, 0.76, 0.22)   // amber
        case .t:       return (0.68, 0.45, 0.94)   // purple
        case .s:       return (0.38, 0.82, 0.44)   // green
        case .z:       return (0.93, 0.38, 0.42)   // red
        case .j:       return (0.34, 0.55, 0.95)   // blue
        case .l:       return (0.97, 0.58, 0.24)   // orange
        case .garbage: return (0.52, 0.55, 0.60)   // neutral slate
        }
    }

    /// Top-of-cell gradient color (lit from above)
    var lightColor: Color {
        let c = rgb
        return Color(red: min(1, c.r + 0.20), green: min(1, c.g + 0.20), blue: min(1, c.b + 0.20))
    }

    /// Bottom-of-cell gradient color (shaded base)
    var darkColor: Color {
        let c = rgb
        return Color(red: c.r * 0.66, green: c.g * 0.66, blue: c.b * 0.66)
    }

    var bodyColor: Color {
        let c = rgb
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

/// The seven classic tetromino shapes. Cells are (col, row) offsets inside the
/// piece's bounding box, row 0 at the top; rotation is clockwise within the box.
enum BlockPieceKind: CaseIterable {
    case i, o, t, s, z, j, l

    var boxSize: Int {
        switch self {
        case .i: return 4
        case .o: return 2
        default: return 3
        }
    }

    var cellColor: BlockCell {
        switch self {
        case .i: return .i
        case .o: return .o
        case .t: return .t
        case .s: return .s
        case .z: return .z
        case .j: return .j
        case .l: return .l
        }
    }

    var baseCells: [(col: Int, row: Int)] {
        switch self {
        case .i: return [(0, 1), (1, 1), (2, 1), (3, 1)]
        case .o: return [(0, 0), (1, 0), (0, 1), (1, 1)]
        case .t: return [(1, 0), (0, 1), (1, 1), (2, 1)]
        case .s: return [(1, 0), (2, 0), (0, 1), (1, 1)]
        case .z: return [(0, 0), (1, 0), (1, 1), (2, 1)]
        case .j: return [(0, 0), (0, 1), (1, 1), (2, 1)]
        case .l: return [(2, 0), (0, 1), (1, 1), (2, 1)]
        }
    }

    /// Cells after `rotation` clockwise quarter-turns within the bounding box
    func cells(rotation: Int) -> [(col: Int, row: Int)] {
        var cells = baseCells
        let turns = ((rotation % 4) + 4) % 4
        for _ in 0..<turns {
            cells = cells.map { (col: boxSize - 1 - $0.row, row: $0.col) }
        }
        return cells
    }
}

// MARK: - Game model

/// Resolved tuning for one game: the mission's difficulty values with any
/// per-alarm overrides applied, clamped to sane gameplay bounds.
struct BlockDropConfig {
    var linesToClear = 3
    var dropInterval = 0.65
    var garbageRowCount = 4
    var garbageGapWidth = 2
    var garbageGapsAligned = false

    init() {}

    init(mission: Mission) {
        linesToClear = max(1, mission.effectiveBlockDropLines)
        dropInterval = min(max(mission.effectiveBlockDropInterval, 0.15), 2.0)
        garbageRowCount = min(max(mission.effectiveBlockDropGarbageRows, 0), 10)
        garbageGapWidth = min(max(mission.effectiveBlockDropGapWidth, 1), 4)
        garbageGapsAligned = mission.effectiveBlockDropGapsAligned
    }
}

/// Discrete falling-blocks engine. Gravity runs on a plain repeating Timer
/// (steps are whole cells — no per-frame physics needed), UI state is
/// published so the Canvas re-renders on change.
@MainActor
final class BlockDropGameModel: ObservableObject {
    struct ActivePiece {
        var kind: BlockPieceKind
        var rotation: Int
        var col: Int
        var row: Int

        var cells: [(col: Int, row: Int)] {
            kind.cells(rotation: rotation).map { (col: col + $0.col, row: row + $0.row) }
        }
    }

    let cols = 8
    let rows = 14

    // Sized from day one — the Canvas can render before onAppear/start() runs,
    // so an empty board here is an index-out-of-range crash. Keep the literals
    // in sync with cols/rows above.
    @Published private(set) var board: [[BlockCell?]] = Array(repeating: Array(repeating: nil, count: 8), count: 14)
    @Published private(set) var active: ActivePiece?
    @Published private(set) var nextKind: BlockPieceKind = .i
    /// The one stored (held) piece, if any. Only the kind is kept, so it always
    /// returns at its spawn position/rotation.
    @Published private(set) var heldKind: BlockPieceKind?
    @Published private(set) var linesCleared = 0
    @Published private(set) var clearingRows: Set<Int> = []
    @Published private(set) var completed = false
    @Published private(set) var showResetToast = false

    /// True while the currently falling piece is the replacement that took the
    /// held piece's turn; when it locks, the held piece spawns next (one-shot
    /// skip semantics — not endless Tetris swapping).
    private var holdArmed = false

    /// What the NEXT chip should advertise: the held piece when one is waiting
    /// to return, otherwise the freshly drawn upcoming piece.
    var upcomingKind: BlockPieceKind {
        (holdArmed ? heldKind : nil) ?? nextKind
    }

    /// Whether tapping the hold box would currently do something (drives the
    /// box's available/occupied read; the tap itself is still fully guarded).
    var canHold: Bool {
        !completed && heldKind == nil && clearingRows.isEmpty && !showResetToast && active != nil
    }

    private(set) var config = BlockDropConfig()
    var targetLines: Int { config.linesToClear }

    /// Fires once when the required lines are cleared (after the clear animation).
    var onCompleted: (() -> Void)?
    /// Fires on every line clear with the number of rows cleared (haptics hook).
    var onLinesCleared: ((Int) -> Void)?
    /// Fires on each meaningful engine event that counts as "active play" for the
    /// grace pause window: a piece locking and a line clearing. Player inputs are
    /// reported separately by the view; together they keep the grace countdown
    /// frozen while the player is actually stacking.
    var onActivity: (() -> Void)?

    private var bag: [BlockPieceKind] = []
    private var gravityTimer: Timer?
    private var started = false

    func configure(mission: Mission) {
        guard !started else { return }
        config = BlockDropConfig(mission: mission)
    }

    func start() {
        guard !started else { return }
        started = true
        resetBoard()
        nextKind = drawFromBag()
        spawn()
        startGravity()
    }

    func stop() {
        gravityTimer?.invalidate()
        gravityTimer = nil
    }

    // MARK: Input

    /// Store the falling piece for one turn: it moves into the hold box, the
    /// queued piece spawns immediately, and the stored piece automatically
    /// returns when that replacement locks. No-op when the hold is occupied,
    /// nothing is falling, or a clear/reseed animation is in flight (guards
    /// mirror `canHold`). Returns whether a piece was actually stored so the
    /// caller only fires feedback on a real store.
    @discardableResult
    func storeHold() -> Bool {
        guard canHold, let piece = active else { return false }
        heldKind = piece.kind          // kind only → returns at spawn pos/rotation
        active = nil
        spawn()                        // bring in the queued replacement piece
        holdArmed = true               // when it locks, the held piece returns
        return true
    }

    func moveActive(by dx: Int) {
        guard !completed, var piece = active, dx != 0 else { return }
        piece.col += dx > 0 ? 1 : -1
        guard isValid(piece) else { return }
        active = piece
    }

    /// Drag support: walk the piece one column at a time toward `target`,
    /// stopping at the first collision so pieces never tunnel through walls.
    func setActiveColumn(_ target: Int) {
        guard !completed, let piece = active else { return }
        var current = piece
        while current.col != target {
            var next = current
            next.col += target > current.col ? 1 : -1
            guard isValid(next) else { break }
            current = next
        }
        if current.col != piece.col { active = current }
    }

    /// Rotate clockwise with simple wall kicks (shift left/right up to 2)
    @discardableResult
    func rotateActive() -> Bool {
        guard !completed, let piece = active else { return false }
        var rotated = piece
        rotated.rotation += 1
        for kick in [0, -1, 1, -2, 2] {
            var candidate = rotated
            candidate.col += kick
            if isValid(candidate) {
                active = candidate
                return true
            }
        }
        return false
    }

    func hardDrop() {
        guard !completed, var piece = active else { return }
        piece.row = ghostRow(for: piece)
        active = piece
        lockActive()
    }

    /// Row the active piece would land on if dropped now (ghost preview)
    func ghostRow(for piece: ActivePiece) -> Int {
        var candidate = piece
        while true {
            var next = candidate
            next.row += 1
            guard isValid(next) else { return candidate.row }
            candidate = next
        }
    }

    // MARK: Engine

    private func startGravity() {
        gravityTimer?.invalidate()
        gravityTimer = Timer.scheduledTimer(withTimeInterval: config.dropInterval, repeats: true) { [weak self] _ in
            self?.gravityStep()
        }
    }

    private func gravityStep() {
        guard !completed, var piece = active else { return }
        piece.row += 1
        if isValid(piece) {
            active = piece
        } else {
            lockActive()
        }
    }

    private func isValid(_ piece: ActivePiece) -> Bool {
        for cell in piece.cells {
            guard cell.col >= 0, cell.col < cols, cell.row >= 0, cell.row < rows else { return false }
            if board[cell.row][cell.col] != nil { return false }
        }
        return true
    }

    private func lockActive() {
        guard let piece = active else { return }
        onActivity?()            // a piece settling counts as active play
        for cell in piece.cells {
            board[cell.row][cell.col] = piece.kind.cellColor
        }
        active = nil

        let fullRows = Set((0..<rows).filter { row in board[row].allSatisfy { $0 != nil } })
        if fullRows.isEmpty {
            spawn()
        } else {
            clearingRows = fullRows
            // Brief white flash on the cleared rows before they collapse.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                self?.finishClear()
            }
        }
    }

    private func finishClear() {
        let cleared = clearingRows.count
        guard cleared > 0 else { return }
        board.remove(atOffsets: IndexSet(clearingRows))
        board.insert(contentsOf: Array(repeating: Array(repeating: nil, count: cols), count: cleared), at: 0)
        clearingRows = []
        linesCleared += cleared
        onActivity?()            // a line clearing counts as active play
        onLinesCleared?(cleared)

        if linesCleared >= targetLines {
            completed = true
            stop()
            onCompleted?()
        } else {
            spawn()
        }
    }

    private func spawn() {
        let kind: BlockPieceKind
        if holdArmed, let held = heldKind {
            // The held piece takes this turn; it leaves the box and the queued
            // piece stays queued (don't draw a fresh one).
            kind = held
            heldKind = nil
            holdArmed = false
        } else {
            kind = nextKind
            nextKind = drawFromBag()
        }
        let piece = ActivePiece(kind: kind, rotation: 0, col: (cols - kind.boxSize) / 2, row: 0)
        if isValid(piece) {
            active = piece
        } else {
            // Topped out: reset the board but KEEP line progress — the mission
            // must never dead-end (mirrors the balance mission's set-down reset).
            resetBoard()
            showResetToast = true
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1600))
                self?.showResetToast = false
            }
            active = ActivePiece(kind: kind, rotation: 0, col: (cols - kind.boxSize) / 2, row: 0)
        }
    }

    private func drawFromBag() -> BlockPieceKind {
        if bag.isEmpty { bag = BlockPieceKind.allCases.shuffled() }
        return bag.removeLast()
    }

    /// Fresh board with the difficulty's pre-filled rows. Each pre-filled row
    /// has a gap; aligned difficulties share one column (a single well), the
    /// others let the gap wander so each row needs its own fill.
    private func resetBoard() {
        var fresh: [[BlockCell?]] = Array(repeating: Array(repeating: nil, count: cols), count: rows)
        let gapWidth = config.garbageGapWidth
        var gapStart = Int.random(in: 1..<(cols - gapWidth))
        for i in 0..<config.garbageRowCount {
            let row = rows - 1 - i
            if !config.garbageGapsAligned && i > 0 {
                // Wander by at most 2 columns per row so gaps stay reachable.
                let shift = Int.random(in: -2...2)
                gapStart = min(max(gapStart + shift, 0), cols - gapWidth)
            }
            for col in 0..<cols where col < gapStart || col >= gapStart + gapWidth {
                fresh[row][col] = .garbage
            }
        }
        board = fresh
    }
}

// MARK: - Mission view

struct BlockDropMissionView: View {
    let mission: Mission
    let onComplete: () -> Void
    var onEngaged: (() -> Void)? = nil
    /// Fired on every player input and on piece-lock / line-clear events so the
    /// host can refresh its grace pause window (the countdown stays frozen while
    /// the player is actively stacking).
    var onActivity: (() -> Void)? = nil
    var gracePeriodActive: Bool = false
    var gracePeriodRemaining: TimeInterval = 0
    var graceTotal: TimeInterval = 0
    var alarmColors: AlarmColorCustomization = .default
    /// Accent from the main app theme (progress, controls, grace ring).
    var accent: Color = .accentColor
    var compact: Bool = false

    @StateObject private var game = BlockDropGameModel()
    @State private var hasEngaged = false
    /// Column of the active piece when the current drag began
    @State private var dragStartCol: Int?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 14) {
                if !compact { header }
                progressBar
                boardView
                controls
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            // Reserve the bottom-right corner for the grace ring (like math
            // reserves space under its keypad).
            .padding(.bottom, 72)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Grace countdown ring — bottom-right, consistent across missions.
            if gracePeriodActive && gracePeriodRemaining > 0 {
                MissionGracePill(remaining: gracePeriodRemaining, total: graceTotal, accent: accent)
                    .padding(.trailing, 22)
                    .padding(.bottom, 26)
            }
        }
        .onAppear { startGame() }
        .onDisappear { game.stop() }
    }

    // MARK: Header (lines left + hold/next pieces)

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // No instruction line. It was a single truncating line competing
                // with the lines-left counter for the same row, so on narrower
                // layouts it shrank and then ellipsised — and the game teaches
                // itself: blocks fall, you move them, rows clear.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(max(0, game.targetLines - game.linesCleared))")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.25), value: game.linesCleared)
                    Text(game.targetLines - game.linesCleared == 1 ? "line left" : "lines left")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Hold box: tap to stash the falling piece for one turn.
            holdChip

            // Next-piece chip: frosted glass, the app's bubble material. Shows
            // the held piece when one is waiting to return — i.e. what will
            // ACTUALLY spawn next.
            VStack(spacing: 5) {
                Text("NEXT")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                miniPiece(game.upcomingKind)
            }
            .frame(minWidth: 68)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        }
    }

    /// Hold box: same frosted-glass bubble as the NEXT chip, but tappable.
    /// Empty state shows a dashed dimmed outline; occupied shows the stored
    /// piece in its real color. Tapping with the hold empty stashes the falling
    /// piece for one turn; while occupied, tapping is a no-op (one-shot skip).
    private var holdChip: some View {
        Button {
            engageIfNeeded()
            registerActivity()       // holding a piece counts as active play
            if game.storeHold() { holdHaptic() }
        } label: {
            VStack(spacing: 5) {
                Text("HOLD")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                holdSlot
            }
            // ≥44pt tap target; matches the NEXT chip's footprint.
            .frame(minWidth: 68, minHeight: 44)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(accent.opacity(game.canHold ? 0.5 : 0), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: game.canHold)
    }

    /// The piece (or empty placeholder) drawn inside the hold box, animated as
    /// pieces enter and leave.
    @ViewBuilder private var holdSlot: some View {
        ZStack {
            if let held = game.heldKind {
                miniPiece(held)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .id(held)
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .frame(width: 34, height: 22)
                    .transition(.opacity)
            }
        }
        .frame(height: 33)
        .animation(.snappy(duration: 0.28), value: game.heldKind)
    }

    /// Tiny glossy render of a piece for the NEXT chip
    private func miniPiece(_ kind: BlockPieceKind) -> some View {
        let cells = kind.cells(rotation: 0)
        let minCol = cells.map(\.col).min() ?? 0
        let minRow = cells.map(\.row).min() ?? 0
        let w = (cells.map(\.col).max() ?? 0) - minCol + 1
        let h = (cells.map(\.row).max() ?? 0) - minRow + 1
        let unit: CGFloat = 11
        return Canvas { ctx, _ in
            for cell in cells {
                let rect = CGRect(x: CGFloat(cell.col - minCol) * unit,
                                  y: CGFloat(cell.row - minRow) * unit,
                                  width: unit, height: unit)
                BlockDropMissionView.drawBlock(&ctx, rect: rect, cell: kind.cellColor)
            }
        }
        .frame(width: CGFloat(w) * unit, height: CGFloat(h) * unit)
    }

    // MARK: Progress toward the line target

    private var progressBar: some View {
        let progress = min(1, Double(game.linesCleared) / Double(max(1, game.targetLines)))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(uiColor: .tertiarySystemFill))
                Capsule()
                    .fill(accent)
                    .frame(width: max(8, geo.size.width * progress))
                    .opacity(progress > 0 ? 1 : 0)
            }
        }
        .frame(height: 6)
        .animation(.easeInOut(duration: 0.35), value: game.linesCleared)
    }

    // MARK: Board

    private var boardView: some View {
        GeometryReader { geo in
            // Whole cells only, so the grid renders crisp.
            let cell = floor(min((geo.size.width - 24) / CGFloat(game.cols),
                                 (geo.size.height - 24) / CGFloat(game.rows)))
            let boardW = cell * CGFloat(game.cols)
            let boardH = cell * CGFloat(game.rows)

            ZStack {
                // Same surface treatment as the balance playfield: continuous
                // rounded rect + radial vignette for depth, no hard border.
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .overlay(
                        RadialGradient(colors: [.clear, .black.opacity(0.22)],
                                       center: .center, startRadius: 70, endRadius: 460)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    )

                boardCanvas(cellSize: cell)
                    .frame(width: boardW, height: boardH)

                if game.showResetToast {
                    Text("Stacked out — board reset")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: boardW + 24, height: boardH + 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: game.showResetToast)
            .contentShape(Rectangle())
            .onTapGesture {
                engageIfNeeded()
                registerActivity()
                if game.rotateActive() { tapHaptic() }
            }
            .gesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { value in
                        engageIfNeeded()
                        registerActivity()
                        if dragStartCol == nil { dragStartCol = game.active?.col }
                        guard let start = dragStartCol, cell > 0 else { return }
                        let offset = Int((value.translation.width / cell).rounded())
                        game.setActiveColumn(start + offset)
                    }
                    .onEnded { value in
                        dragStartCol = nil
                        // A predominantly-downward swipe hard-drops.
                        if value.translation.height > 60,
                           value.translation.height > abs(value.translation.width) {
                            registerActivity()
                            dropHaptic()
                            game.hardDrop()
                        }
                    }
            )
        }
    }

    private func boardCanvas(cellSize: CGFloat) -> some View {
        Canvas { ctx, _ in
            // Defensive: never index a board that isn't fully sized.
            guard game.board.count == game.rows,
                  game.board.allSatisfy({ $0.count == game.cols }) else { return }
            // Empty-grid texture: a faint pit behind the action.
            for row in 0..<game.rows {
                for col in 0..<game.cols {
                    let rect = cellRect(col: col, row: row, size: cellSize)
                    let pit = Path(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5),
                                   cornerRadius: cellSize * 0.16, style: .continuous)
                    ctx.fill(pit, with: .color(Color.primary.opacity(0.045)))
                }
            }

            // Settled cells (white-hot flash on rows mid-clear).
            for row in 0..<game.rows {
                for col in 0..<game.cols {
                    guard let cell = game.board[row][col] else { continue }
                    let rect = cellRect(col: col, row: row, size: cellSize)
                    Self.drawBlock(&ctx, rect: rect, cell: cell)
                    if game.clearingRows.contains(row) {
                        let flash = Path(roundedRect: rect.insetBy(dx: 1, dy: 1),
                                         cornerRadius: cellSize * 0.2, style: .continuous)
                        ctx.fill(flash, with: .color(.white.opacity(0.75)))
                    }
                }
            }

            if let piece = game.active {
                // Ghost landing preview
                let ghostRow = game.ghostRow(for: piece)
                if ghostRow != piece.row {
                    for cell in piece.kind.cells(rotation: piece.rotation) {
                        let rect = cellRect(col: piece.col + cell.col, row: ghostRow + cell.row, size: cellSize)
                        let path = Path(roundedRect: rect.insetBy(dx: 2, dy: 2),
                                        cornerRadius: cellSize * 0.18, style: .continuous)
                        ctx.fill(path, with: .color(.primary.opacity(0.07)))
                        ctx.stroke(path, with: .color(.primary.opacity(0.32)), lineWidth: 1)
                    }
                }
                // The falling piece itself
                for cell in piece.cells {
                    let rect = cellRect(col: cell.col, row: cell.row, size: cellSize)
                    Self.drawBlock(&ctx, rect: rect, cell: piece.kind.cellColor)
                }
            }
        }
    }

    private func cellRect(col: Int, row: Int, size: CGFloat) -> CGRect {
        CGRect(x: CGFloat(col) * size, y: CGFloat(row) * size, width: size, height: size)
    }

    /// Glossy beveled block: vertical body gradient (lit from above), specular
    /// top highlight, crisp dark edge, soft drop shadow — the marble's
    /// "realistic glass/plastic" read translated to 2D, same recipe as
    /// HoldPressStyle's physical surfaces.
    static func drawBlock(_ ctx: inout GraphicsContext, rect: CGRect, cell: BlockCell) {
        let inset = rect.insetBy(dx: max(0.8, rect.width * 0.045), dy: max(0.8, rect.width * 0.045))
        let corner = rect.width * 0.2
        let shape = Path(roundedRect: inset, cornerRadius: corner, style: .continuous)

        // Soft shadow for lift off the board
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.32), radius: rect.width * 0.07,
                                    x: 0, y: rect.width * 0.06))
            layer.fill(shape, with: .linearGradient(
                Gradient(colors: [cell.lightColor, cell.darkColor]),
                startPoint: CGPoint(x: inset.midX, y: inset.minY),
                endPoint: CGPoint(x: inset.midX, y: inset.maxY)
            ))
        }

        // Specular top gloss (upper ~40%)
        let glossRect = CGRect(x: inset.minX + inset.width * 0.12,
                               y: inset.minY + inset.height * 0.08,
                               width: inset.width * 0.76,
                               height: inset.height * 0.34)
        let gloss = Path(roundedRect: glossRect, cornerRadius: corner * 0.8, style: .continuous)
        ctx.fill(gloss, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.42), .white.opacity(0.03)]),
            startPoint: CGPoint(x: glossRect.midX, y: glossRect.minY),
            endPoint: CGPoint(x: glossRect.midX, y: glossRect.maxY)
        ))

        // Crisp beveled edge
        ctx.stroke(shape, with: .color(.black.opacity(0.22)), lineWidth: max(0.8, rect.width * 0.03))
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 16) {
            controlButton("arrow.left") {
                engageIfNeeded()
                registerActivity()
                game.moveActive(by: -1)
                tapHaptic()
            }
            controlButton("rotate.right") {
                engageIfNeeded()
                registerActivity()
                if game.rotateActive() { tapHaptic() }
            }
            controlButton("arrow.right") {
                engageIfNeeded()
                registerActivity()
                game.moveActive(by: 1)
                tapHaptic()
            }
            controlButton("arrow.down.to.line") {
                engageIfNeeded()
                registerActivity()
                dropHaptic()
                game.hardDrop()
            }
        }
    }

    /// Frosted-glass circular bubble with an accent glyph — the app's
    /// RadioPlayCircle `.material` convention.
    private func controlButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 58, height: 58)
        }
        .buttonStyle(.plain)
    }

    // MARK: Lifecycle / wiring

    private func startGame() {
        game.configure(mission: mission)
        // Route the engine's activity events (piece-lock / line-clear) to the host.
        game.onActivity = { onActivity?() }
        game.onLinesCleared = { cleared in
            UIImpactFeedbackGenerator(style: cleared > 1 ? .heavy : .rigid).impactOccurred()
        }
        game.onCompleted = {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // Let the final clear's flash land before the alarm dismisses.
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                onComplete()
            }
        }
        game.start()
    }

    /// First real input starts the grace period (mutes the alarm) — only while
    /// the app is frontmost, mirroring the shake mission's guard.
    private func engageIfNeeded() {
        guard !hasEngaged, UIApplication.shared.applicationState == .active else { return }
        hasEngaged = true
        onEngaged?()
    }

    /// Every player input refreshes the host's grace pause window (piece-lock /
    /// line-clear events are reported by the game model). Pure signal — no audio
    /// or global side effect — so a preview freezes the ring identically, silent.
    private func registerActivity() {
        onActivity?()
    }

    // MARK: Haptics

    private func tapHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    private func dropHaptic() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    private func holdHaptic() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
}

// MARK: - Debug host (-blockDropDebug launch argument)

#if DEBUG
/// Renders the mission alone over a neutral gradient:
///   simctl launch booted <bundle-id> -blockDropDebug easy|medium|hard
struct BlockDropDebugHost: View {
    let difficulty: BlockDropDifficulty

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(uiColor: .systemBackground), Color(uiColor: .secondarySystemBackground)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            BlockDropMissionView(
                mission: {
                    var m = Mission()
                    m.type = .blockDrop
                    m.blockDropDifficulty = difficulty
                    return m
                }(),
                onComplete: { print("🧪 [blockDropDebug] mission complete") }
            )
        }
    }
}
#endif

#Preview {
    BlockDropMissionView(
        mission: {
            var m = Mission()
            m.type = .blockDrop
            m.blockDropDifficulty = .easy
            return m
        }(),
        onComplete: {},
        gracePeriodActive: true,
        gracePeriodRemaining: 42,
        graceTotal: 55
    )
}
