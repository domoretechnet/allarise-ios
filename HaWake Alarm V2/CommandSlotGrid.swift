//
//  CommandSlotGrid.swift
//  HaWake Alarm V2
//
//  Drag-to-reorder / tap-to-remove grid for the After-Alarm Notes page's command
//  buttons. Deliberately a sibling of `MissionCardGrid` rather than a second
//  attempt at the problem: same UIKit approach (UICollectionView + the SYSTEM's
//  interactive movement) for the same reason — home-screen physics (lift,
//  tracking, live reflow, drop settle) that a SwiftUI DragGesture can't
//  reproduce, especially inside a scroll view. Card VISUALS stay SwiftUI via
//  UIHostingConfiguration so the glass squares match the Notes page exactly.
//
//  Interaction model, identical to the mission grid:
//    • browse: tap a square → pick/replace its command; tap the add box → assign
//      the next free slot; long-press a square → edit mode begins AND that square
//      lifts for immediate drag.
//    • edit: squares wobble (CoreAnimation, staggered, skipped under Reduce
//      Motion), minus badges clear the slot, long-press-drag reorders with live
//      reflow, taps on empty area / add / placeholders exit.
//
//  Slots are COMPACTED (filled first, then the add box, then placeholders) to
//  match both the mission editor and what actually ships: the runtime Notes page
//  resolves its buttons to a dense `[MQTTCommand]`, so a hole in the middle of
//  the editor never existed on screen.
//
//  The two grids are close enough that a shared generic host is worth extracting
//  if a third one ever appears; two specialisations did not justify making the
//  mission grid's hard-won interaction code generic.
//

import SwiftUI
import UIKit

/// Grid cell identity for the diffable data source. `nonisolated` for the same
/// reason `MissionGridItem` is: the project builds with default-MainActor
/// isolation, which would otherwise give this enum a main-actor-isolated
/// Hashable conformance that can't satisfy the data source's Sendable
/// identifier requirement.
nonisolated enum CommandSlotGridItem: Hashable, Sendable {
    case filled(Int)   // index into `commands`
    case add
    case empty(Int)    // positional placeholder (slot number - 1)
}

struct CommandSlotGrid: UIViewRepresentable {
    /// The assigned commands, compacted into slot order.
    let commands: [MQTTCommand]
    let maxSlots: Int
    let editMode: Bool

    var onTapSlot: (Int) -> Void
    var onTapAdd: () -> Void
    var onEnterEdit: () -> Void
    var onExitEdit: () -> Void
    var onRemove: (Int) -> Void
    /// Reorder commit: the new ordering expressed as original indices.
    var onReorder: ([Int]) -> Void

    /// Grid metrics — one row of `maxSlots` cells, each holding a
    /// `NotesCommandSquare`-sized square plus its name underneath.
    static var gridHeight: CGFloat { NotesCommandSquare.totalHeight }

    func makeUIView(context: Context) -> UICollectionView {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout(slots: maxSlots))
        cv.backgroundColor = .clear
        cv.isScrollEnabled = false
        cv.delegate = context.coordinator
        context.coordinator.install(on: cv, parent: self)
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applySnapshot(animated: true)
        context.coordinator.refreshWobble()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    static func dismantleUIView(_ uiView: UICollectionView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    /// EQUAL-WIDTH columns spanning the full width, one per slot. Previously
    /// absolute-width items hugging the leading edge, which left a ragged gap on
    /// the right; with a fixed four slots, equal columns are symmetric by
    /// construction and match the runtime page's row exactly.
    private static func makeLayout(slots: Int) -> UICollectionViewLayout {
        let count = max(slots, 1)
        return UICollectionViewCompositionalLayout { _, _ in
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0 / CGFloat(count)),
                heightDimension: .fractionalHeight(1.0)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                  heightDimension: .absolute(gridHeight)),
                subitems: Array(repeating: item, count: count))
            return NSCollectionLayoutSection(group: group)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        var parent: CommandSlotGrid
        private var dataSource: UICollectionViewDiffableDataSource<Int, CommandSlotGridItem>!
        private weak var collectionView: UICollectionView?
        private var longPress: UILongPressGestureRecognizer!
        /// Window-level tap recognizer, installed only while editing: a tap
        /// anywhere outside the grid exits jiggle mode.
        private var windowTap: UITapGestureRecognizer? = nil

        init(parent: CommandSlotGrid) {
            self.parent = parent
        }

        func install(on cv: UICollectionView, parent: CommandSlotGrid) {
            self.parent = parent
            self.collectionView = cv

            let registration = UICollectionView.CellRegistration<UICollectionViewCell, CommandSlotGridItem> {
                [weak self] cell, _, item in
                self?.configure(cell: cell, for: item)
            }
            let ds = UICollectionViewDiffableDataSource<Int, CommandSlotGridItem>(collectionView: cv) {
                cv, indexPath, item in
                cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
            }
            ds.reorderingHandlers.canReorderItem = { item in
                if case .filled = item { return true }
                return false
            }
            ds.reorderingHandlers.didReorder = { [weak self] transaction in
                guard let self else { return }
                let order = transaction.finalSnapshot.itemIdentifiers.compactMap { (item: CommandSlotGridItem) -> Int? in
                    if case .filled(let i) = item { return i }
                    return nil
                }
                self.parent.onReorder(order)
            }
            self.dataSource = ds

            let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            lp.minimumPressDuration = 0.35
            lp.delegate = self
            cv.addGestureRecognizer(lp)
            self.longPress = lp

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            cv.addGestureRecognizer(tap)

            applySnapshot(animated: false)
        }

        // MARK: Snapshot

        private var items: [CommandSlotGridItem] {
            var out: [CommandSlotGridItem] = parent.commands.indices.map { .filled($0) }
            if parent.commands.count < parent.maxSlots {
                out.append(.add)
                var slot = parent.commands.count + 1
                while out.count < parent.maxSlots {
                    out.append(.empty(slot))
                    slot += 1
                }
            }
            return out
        }

        func applySnapshot(animated: Bool) {
            var snapshot = NSDiffableDataSourceSnapshot<Int, CommandSlotGridItem>()
            snapshot.appendSections([0])
            snapshot.appendItems(items, toSection: 0)
            // Reconfigure everything so hosted SwiftUI content picks up edit-mode
            // and reassignment changes.
            snapshot.reconfigureItems(items)
            dataSource.apply(snapshot, animatingDifferences: animated)
            // Faster pickup while already jiggling, like the home screen.
            longPress?.minimumPressDuration = parent.editMode ? 0.15 : 0.35
            syncWindowTap()
        }

        /// Install/remove the outside-tap exit recognizer to match edit mode. It
        /// lives on the WINDOW so any tap outside the grid — the notes text, the
        /// nav bar — leaves jiggle mode, and it never cancels the touches it
        /// observes, so those taps still do their real work.
        private func syncWindowTap() {
            if parent.editMode {
                guard windowTap == nil else { return }
                // The window can be nil during the first update tick — defer a beat.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.parent.editMode, self.windowTap == nil,
                          let window = self.collectionView?.window else { return }
                    let tap = UITapGestureRecognizer(target: self, action: #selector(self.handleWindowTap(_:)))
                    tap.cancelsTouchesInView = false
                    tap.delegate = self
                    window.addGestureRecognizer(tap)
                    self.windowTap = tap
                }
            } else if let tap = windowTap {
                tap.view?.removeGestureRecognizer(tap)
                windowTap = nil
            }
        }

        /// Called when SwiftUI tears the grid down — the window-level recognizer
        /// must not outlive it.
        func teardown() {
            if let tap = windowTap {
                tap.view?.removeGestureRecognizer(tap)
                windowTap = nil
            }
        }

        @objc private func handleWindowTap(_ gesture: UITapGestureRecognizer) {
            guard parent.editMode, let cv = collectionView, let window = gesture.view else { return }
            let loc = gesture.location(in: window)
            let inGrid = cv.bounds.contains(cv.convert(loc, from: window))
            if !inGrid {
                parent.onExitEdit()
            }
        }

        private func configure(cell: UICollectionViewCell, for item: CommandSlotGridItem) {
            let parent = self.parent
            // The Notes page draws on a wallpaper — cells must never paint a
            // background of their own behind the glass squares.
            cell.backgroundConfiguration = .clear()
            switch item {
            case .filled(let index):
                guard index < parent.commands.count else { return }
                let command = parent.commands[index]
                cell.contentConfiguration = UIHostingConfiguration {
                    CommandSlotContent(
                        systemImage: command.icon,
                        tint: command.iconColor,
                        sourceGlyph: command.sourceKind.glyph,
                        label: command.displayName,
                        editMode: parent.editMode,
                        onRemove: { parent.onRemove(index) }
                    )
                }
                .margins(.all, 0)
            case .add:
                cell.contentConfiguration = UIHostingConfiguration {
                    CommandSlotContent(
                        systemImage: "plus",
                        tint: Color.white.opacity(0.75),
                        sourceGlyph: nil,
                        // "Add / Edit" because this tile is both routes: it fills
                        // the next free slot, and the picker it opens is where
                        // commands are edited and managed.
                        label: "Add / Edit",
                        editMode: false,
                        onRemove: {}
                    )
                }
                .margins(.all, 0)
            case .empty:
                cell.contentConfiguration = UIHostingConfiguration {
                    CommandSlotPlaceholder()
                }
                .margins(.all, 0)
            }
        }

        // MARK: Reorder rules

        func collectionView(_ collectionView: UICollectionView,
                            targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath,
                            toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
            // Never drop onto the add box / placeholders.
            let filled = parent.commands.count
            let target = min(proposedIndexPath.item, max(filled - 1, 0))
            return IndexPath(item: target, section: proposedIndexPath.section)
        }

        // MARK: Taps

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
            switch item {
            case .filled(let i):
                if parent.editMode {
                    // Home-screen behaviour: taps don't open cards while jiggling.
                } else {
                    parent.onTapSlot(i)
                }
            case .add:
                parent.editMode ? parent.onExitEdit() : parent.onTapAdd()
            case .empty:
                if parent.editMode { parent.onExitEdit() }
            }
        }

        @objc private func handleBackgroundTap(_ gesture: UITapGestureRecognizer) {
            guard parent.editMode, let cv = collectionView else { return }
            let loc = gesture.location(in: cv)
            if cv.indexPathForItem(at: loc) == nil {
                parent.onExitEdit()
            }
        }

        // MARK: Long-press → system interactive movement

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let cv = collectionView else { return }
            switch gesture.state {
            case .began:
                let loc = gesture.location(in: cv)
                guard let ip = cv.indexPathForItem(at: loc),
                      let item = dataSource.itemIdentifier(for: ip),
                      case .filled = item else { return }
                if !parent.editMode {
                    parent.onEnterEdit()
                }
                if cv.beginInteractiveMovementForItem(at: ip) {
                    lift(cellAt: ip, in: cv)
                }
            case .changed:
                cv.updateInteractiveMovementTargetPosition(gesture.location(in: cv))
            case .ended:
                cv.endInteractiveMovement()
                settleAllCells(in: cv)
            default:
                cv.cancelInteractiveMovement()
                settleAllCells(in: cv)
            }
        }

        private func lift(cellAt indexPath: IndexPath, in cv: UICollectionView) {
            guard let cell = cv.cellForItem(at: indexPath) else { return }
            UIView.animate(withDuration: 0.18) {
                cell.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
                cell.layer.shadowColor = UIColor.black.cgColor
                cell.layer.shadowOpacity = 0.25
                cell.layer.shadowRadius = 8
                cell.layer.shadowOffset = CGSize(width: 0, height: 4)
            }
        }

        private func settleAllCells(in cv: UICollectionView) {
            for cell in cv.visibleCells {
                UIView.animate(withDuration: 0.2) {
                    cell.transform = .identity
                    cell.layer.shadowOpacity = 0
                }
            }
        }

        // MARK: Wobble (CoreAnimation — nothing to leak into layout)

        func refreshWobble() {
            guard let cv = collectionView else { return }
            for ip in cv.indexPathsForVisibleItems {
                guard let cell = cv.cellForItem(at: ip),
                      let item = dataSource.itemIdentifier(for: ip) else { continue }
                setWobble(cell: cell, item: item)
            }
        }

        func collectionView(_ collectionView: UICollectionView,
                            willDisplay cell: UICollectionViewCell,
                            forItemAt indexPath: IndexPath) {
            if let item = dataSource.itemIdentifier(for: indexPath) {
                setWobble(cell: cell, item: item)
            }
        }

        private func setWobble(cell: UICollectionViewCell, item: CommandSlotGridItem) {
            let shouldWobble: Bool
            if case .filled = item,
               parent.editMode,
               !UIAccessibility.isReduceMotionEnabled {
                shouldWobble = true
            } else {
                shouldWobble = false
            }
            let key = "commandSlotWobble"
            if shouldWobble {
                guard cell.layer.animation(forKey: key) == nil else { return }
                let wobble = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                let angle = 1.8 * Double.pi / 180
                wobble.values = [-angle, angle, -angle]
                wobble.keyTimes = [0, 0.5, 1]
                wobble.duration = 0.28
                wobble.repeatCount = .infinity
                // Stagger per cell so neighbours never wobble in lockstep.
                wobble.timeOffset = Double.random(in: 0...0.28)
                cell.layer.add(wobble, forKey: key)
            } else {
                cell.layer.removeAnimation(forKey: key)
            }
        }

        // MARK: Gesture coexistence

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Let the background tap coexist with cell selection.
            gestureRecognizer !== longPress
        }
    }
}

// MARK: - Hosted content (pure SwiftUI, no gestures — UIKit owns those)

/// The Notes square, minus its Button — it reuses `NotesCommandSquareContent`
/// verbatim so the grid and the runtime page can't drift, and adds only the
/// edit-mode minus badge that exists here and nowhere else.
private struct CommandSlotContent: View {
    let systemImage: String
    let tint: Color
    let sourceGlyph: String?
    let label: String?
    let editMode: Bool
    let onRemove: () -> Void

    var body: some View {
        NotesCommandSquareContent(
            systemImage: systemImage,
            tint: tint,
            glassTint: tint,
            sourceGlyph: sourceGlyph,
            label: label,
            hidesSourceGlyph: editMode
        )
        .overlay(alignment: .topLeading) {
            if editMode {
                Button(action: onRemove) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.red))
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                // Kept INSIDE the square: a negative offset pushed the badge past
                // the cell bounds and it clipped.
                .padding(1)
            }
        }
    }
}

/// A trailing slot that holds space without inviting a tap. Matches the square's
/// footprint including the reserved name line, so the row stays aligned.
private struct CommandSlotPlaceholder: View {
    var body: some View {
        VStack(spacing: NotesCommandSquare.labelSpacing) {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .foregroundStyle(Color.white)
                .opacity(0.28)
                .frame(width: NotesCommandSquare.side, height: NotesCommandSquare.side)
            Text(" ")
                .font(.caption2)
                .frame(height: NotesCommandSquare.labelHeight)
        }
    }
}
