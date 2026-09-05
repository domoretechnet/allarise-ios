//
//  MissionCardGrid.swift
//  HaWake Alarm V2
//
//  UIKit-backed mission card grid for the alarm editor. The grid itself is a
//  UICollectionView so drag-to-reorder uses the SYSTEM's interactive-movement
//  support — the exact home-screen physics (lift, tracking, live reflow, drop
//  settle) that a hand-rolled SwiftUI DragGesture can't fully reproduce inside
//  a Form's scroll view. Card VISUALS stay SwiftUI via UIHostingConfiguration,
//  so the pastel tiles, glyphs, and badges are identical to the rest of the app.
//
//  Interaction model (home-screen style):
//    • browse: tap a card → edit its slot; tap the add box → add; long-press a
//      card → edit mode begins AND the pressed card lifts for immediate drag.
//    • edit: cards wobble (CoreAnimation, staggered; skipped under Reduce
//      Motion), minus badges remove, long-press-drag reorders with live reflow,
//      taps on empty area / add / placeholders exit.
//  Home Assistant stays slot 1: its card can't be picked up, and the move
//  delegate clamps any proposed drop so nothing lands in front of it. The
//  SwiftUI side's writeMissions HA-first normalization remains the backstop.
//

import SwiftUI
import UIKit

/// Grid cell identity for the diffable data source. Explicitly `nonisolated`:
/// the project builds with default-MainActor isolation, which would otherwise
/// give even this enum a main-actor-isolated Hashable conformance that can't
/// satisfy the data source's Sendable identifier requirement.
nonisolated enum MissionGridItem: Hashable, Sendable {
    case filled(Int)   // index into `missions`
    case add
    case empty(Int)    // positional placeholder (slot number - 1)
}

struct MissionCardGrid: UIViewRepresentable {
    /// The filled mission cards, in slot order.
    let missions: [Mission]
    let maxSlots: Int
    let editMode: Bool
    let accent: Color
    /// True when the alarm is truly empty (the add box targets slot 1 itself).
    let addTargetsSlotOne: Bool

    var onTapCard: (Int) -> Void
    var onTapAdd: () -> Void
    var onEnterEdit: () -> Void
    var onExitEdit: () -> Void
    var onRemove: (Int) -> Void
    /// Reorder commit: the new ordering expressed as original indices.
    var onReorder: ([Int]) -> Void

    /// Grid metrics — 3 columns × 2 rows of 70pt cards with 12pt gutters.
    static let tileHeight: CGFloat = 70
    static let spacing: CGFloat = 12
    static var gridHeight: CGFloat { tileHeight * 2 + spacing }

    func makeUIView(context: Context) -> UICollectionView {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
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

    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            // Exact thirds minus the two 12pt gutters, computed from the real
            // container width — the count-based group sizing rendered cells at
            // full row width here, so the widths are made explicit instead.
            let width = environment.container.effectiveContentSize.width
            let itemWidth = max((width - 2 * spacing) / 3, 10)
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .absolute(itemWidth),
                heightDimension: .absolute(tileHeight)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                   heightDimension: .absolute(tileHeight)),
                subitems: [item, item, item])
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            return section
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        var parent: MissionCardGrid
        private var dataSource: UICollectionViewDiffableDataSource<Int, MissionGridItem>!
        private weak var collectionView: UICollectionView?
        private var longPress: UILongPressGestureRecognizer!
        /// Index (into missions) of the card currently lifted by the system drag.
        private var draggingIndex: Int? = nil
        /// Window-level tap recognizer, installed only while editing: a tap ANYWHERE
        /// outside the grid (other editor sections, nav bar, …) exits jiggle mode.
        private var windowTap: UITapGestureRecognizer? = nil

        init(parent: MissionCardGrid) {
            self.parent = parent
        }

        func install(on cv: UICollectionView, parent: MissionCardGrid) {
            self.parent = parent
            self.collectionView = cv

            let registration = UICollectionView.CellRegistration<UICollectionViewCell, MissionGridItem> {
                [weak self] cell, _, item in
                self?.configure(cell: cell, for: item)
            }
            let ds = UICollectionViewDiffableDataSource<Int, MissionGridItem>(collectionView: cv) {
                cv, indexPath, item in
                cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
            }
            ds.reorderingHandlers.canReorderItem = { [weak self] item in
                self?.canMove(item) ?? false
            }
            ds.reorderingHandlers.didReorder = { [weak self] transaction in
                guard let self else { return }
                let order = transaction.finalSnapshot.itemIdentifiers.compactMap { (item: MissionGridItem) -> Int? in
                    if case .filled(let i) = item { return i }
                    return nil
                }
                self.draggingIndex = nil
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

        private var items: [MissionGridItem] {
            var out: [MissionGridItem] = parent.missions.indices.map { .filled($0) }
            if parent.missions.count < parent.maxSlots {
                out.append(.add)
                var slot = parent.missions.count + 1
                while out.count < parent.maxSlots {
                    out.append(.empty(slot))
                    slot += 1
                }
            }
            return out
        }

        func applySnapshot(animated: Bool) {
            var snapshot = NSDiffableDataSourceSnapshot<Int, MissionGridItem>()
            snapshot.appendSections([0])
            snapshot.appendItems(items, toSection: 0)
            // Reconfigure everything so hosted SwiftUI content picks up edit-mode,
            // accent, and renumbering changes.
            snapshot.reconfigureItems(items)
            dataSource.apply(snapshot, animatingDifferences: animated)
            // Faster pickup while already jiggling, like the home screen.
            longPress?.minimumPressDuration = parent.editMode ? 0.15 : 0.35
            syncWindowTap()
        }

        /// Install/remove the outside-tap exit recognizer to match edit mode. It
        /// lives on the WINDOW (not the collection view) so any tap outside the
        /// grid — other sections, the nav bar — leaves jiggle mode, and it never
        /// cancels the touches it observes, so those taps still do their real work.
        private func syncWindowTap() {
            guard let cv = collectionView else { return }
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
                _ = cv
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

        private func configure(cell: UICollectionViewCell, for item: MissionGridItem) {
            let parent = self.parent
            switch item {
            case .filled(let index):
                guard index < parent.missions.count else { return }
                let mission = parent.missions[index]
                cell.contentConfiguration = UIHostingConfiguration {
                    MissionCardContent(
                        mission: mission,
                        number: index + 1,
                        accent: parent.accent,
                        editMode: parent.editMode,
                        onRemove: { parent.onRemove(index) }
                    )
                }
                .margins(.all, 0)
            case .add:
                cell.contentConfiguration = UIHostingConfiguration {
                    MissionAddBoxContent(accent: parent.accent,
                                         number: parent.missions.count + 1)
                }
                .margins(.all, 0)
            case .empty(let slot):
                cell.contentConfiguration = UIHostingConfiguration {
                    MissionEmptyBoxContent(number: slot + 1)
                }
                .margins(.all, 0)
            }
        }

        // MARK: Reorder rules

        private func canMove(_ item: MissionGridItem) -> Bool {
            guard case .filled(let i) = item, i < parent.missions.count else { return false }
            // HA is slot-1-only and can never be picked up.
            return parent.missions[i].type != .homeAssistant
        }

        func collectionView(_ collectionView: UICollectionView,
                            targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath,
                            toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
            var target = proposedIndexPath.item
            let filled = parent.missions.count
            // Never drop onto the add box / placeholders.
            target = min(target, max(filled - 1, 0))
            // Nothing may land in front of a slot-1 Home Assistant mission.
            if parent.missions.first?.type == .homeAssistant {
                target = max(target, 1)
            }
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
                    parent.onTapCard(i)
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
                      case .filled(let i) = item else { return }
                if !parent.editMode {
                    parent.onEnterEdit()
                }
                guard canMove(item) else { return }
                draggingIndex = i
                if cv.beginInteractiveMovementForItem(at: ip) {
                    lift(cellAt: ip, in: cv)
                } else {
                    draggingIndex = nil
                }
            case .changed:
                cv.updateInteractiveMovementTargetPosition(gesture.location(in: cv))
            case .ended:
                cv.endInteractiveMovement()
                settleAllCells(in: cv)
                draggingIndex = nil
            default:
                cv.cancelInteractiveMovement()
                settleAllCells(in: cv)
                draggingIndex = nil
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
            for case let ip in cv.indexPathsForVisibleItems {
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

        private func setWobble(cell: UICollectionViewCell, item: MissionGridItem) {
            let shouldWobble: Bool
            if case .filled = item,
               parent.editMode,
               !UIAccessibility.isReduceMotionEnabled {
                shouldWobble = true
            } else {
                shouldWobble = false
            }
            let key = "missionWobble"
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

// MARK: - Hosted card content (pure SwiftUI, no gestures — UIKit owns those)

private struct MissionCardContent: View {
    let mission: Mission
    let number: Int
    let accent: Color
    let editMode: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            MissionTypeGlyph(type: mission.type, accent: accent, animated: false)
            Text(mission.type.shortLabel)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(accent)
        .frame(maxWidth: .infinity)
        .frame(height: MissionCardGrid.tileHeight)
        .selectableTile(isSelected: true, accent: accent, cornerRadius: 16)
        .overlay(alignment: editMode ? .topTrailing : .topLeading) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(accent))
                .padding(5)
        }
        .overlay(alignment: .topLeading) {
            if editMode {
                Button(action: onRemove) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.red))
                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .padding(4)
            }
        }
    }
}

private struct MissionAddBoxContent: View {
    let accent: Color
    let number: Int

    var body: some View {
        Image(systemName: "plus")
            .font(.title2.weight(.semibold))
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity)
            .frame(height: MissionCardGrid.tileHeight)
            .background(dashed(accent, opacity: 0.9))
            .overlay(alignment: .topLeading) { numberBadge }
    }

    private var numberBadge: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.secondary)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
            .padding(5)
    }

    private func dashed(_ tint: Color, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .foregroundStyle(tint)
            .opacity(opacity)
    }
}

private struct MissionEmptyBoxContent: View {
    let number: Int

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: MissionCardGrid.tileHeight)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(Color.secondary)
                    .opacity(0.4)
            )
            .overlay(alignment: .topLeading) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
                    .padding(5)
            }
            .opacity(0.5)
    }
}
