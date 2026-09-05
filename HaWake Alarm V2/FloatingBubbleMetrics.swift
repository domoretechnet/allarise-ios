//
//  FloatingBubbleMetrics.swift
//  HaWake Alarm V2
//
//  Geometry for the two floating bubbles on the Alarms list — the gear at the
//  bottom-left and the + at the bottom-right (`AlarmListView.floatingButtons`).
//
//  WHY THIS FILE EXISTS
//  --------------------
//  The bubbles are drawn as circles but laid out in a square frame, and they sit
//  directly over the column the alarm rows put their Skip button in. Any part of
//  the square that reaches outside the visible circle is an invisible view that
//  swallows a tap meant for Skip — the bug reported as "an invisible boundary
//  above the plus button" (bead al-xyq). The corners are the worst of it: they
//  reach ~8pt past the circle diagonally, which is exactly where a Skip pill
//  parked just above the + lands.
//
//  Two invariants keep Skip reachable, and both are pinned by
//  `FloatingBubbleMetricsTests`:
//
//    1. the bubble's *interaction* region is the visible circle, never the
//       square it is laid out in;
//    2. the list's bottom content margin always clears the bubble by enough that
//       the last row can be scrolled out from under it — including when
//       "Bigger Alarm Rows" scales the bubble up.
//
//  The margin used to be hard-coded at 110, which happened to clear the 1.0×
//  bubble and quietly stopped clearing it by the same amount at 1.15×.
//

import CoreGraphics

enum FloatingBubbleMetrics {
    /// Diameter of a floating bubble at 1.0× (no "Bigger Alarm Rows").
    static let baseDiameter: CGFloat = 56

    /// Gap between the bottom of the bubbles and the bottom safe area.
    static let bottomInset: CGFloat = 16

    /// Space kept between the top of a bubble and the bottom of the list's
    /// content, so the last row's Skip button can always be scrolled clear of
    /// the bubbles rather than coming to rest just beneath the +.
    static let rowClearance: CGFloat = 38

    /// Bubble diameter for a given button scale factor.
    static func diameter(scale: CGFloat) -> CGFloat {
        baseDiameter * scale
    }

    /// Bottom content margin the alarms `List` needs at this button scale.
    ///
    /// At 1.0× this is 56 + 16 + 38 = 110, the value that shipped before this
    /// was derived, so the default layout is unchanged.
    static func listBottomMargin(scale: CGFloat) -> CGFloat {
        diameter(scale: scale) + bottomInset + rowClearance
    }

    /// True when a point inside a bubble's square layout frame falls within the
    /// visible circle — i.e. when the bubble should claim the touch.
    ///
    /// `point` is in the bubble's own coordinate space, origin at its top-left.
    /// Anything this returns `false` for must fall through to the alarm row
    /// underneath, which is where the Skip button lives.
    static func bubbleClaimsTouch(at point: CGPoint, scale: CGFloat) -> Bool {
        let radius = diameter(scale: scale) / 2
        let dx = point.x - radius
        let dy = point.y - radius
        return (dx * dx + dy * dy) <= (radius * radius)
    }
}
