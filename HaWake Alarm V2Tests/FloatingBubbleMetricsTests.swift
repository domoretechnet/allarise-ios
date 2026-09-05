//
//  FloatingBubbleMetricsTests.swift
//  HaWake Alarm V2Tests
//
//  Pins the two geometry invariants that keep a row's Skip button tappable when
//  it sits near the floating gear / + bubbles on the Alarms list.
//
//  The reported bug (al-xyq) was "an invisible boundary above the plus button":
//  the bubbles are drawn as circles but laid out in a square, and the square's
//  corners reach past the visible circle into exactly the strip the Skip pill
//  occupies. A tap there hit nothing and did nothing.
//
//  Nothing here can prove SwiftUI honours the content shape — that needs the
//  device. What it does prove is that the shape we ask for is the visible circle
//  and not the square, and that the list keeps enough bottom margin for the last
//  row to be scrolled clear of the bubbles at BOTH button scales. The second one
//  is the regression that hid for a while: the margin was hard-coded at 110,
//  correct at 1.0× and quietly short at 1.15× ("Bigger Alarm Rows").
//

import CoreGraphics
import Foundation
import Testing
@testable import HaWake_Alarm_V2

struct FloatingBubbleMetricsTests {

    /// Button scales AlarmListView actually uses.
    private static let scales: [CGFloat] = [1.0, 1.15]

    // MARK: - Interaction shape

    @Test("A bubble claims its centre at every scale")
    func centreIsTappable() {
        for scale in Self.scales {
            let d = FloatingBubbleMetrics.diameter(scale: scale)
            #expect(FloatingBubbleMetrics.bubbleClaimsTouch(
                at: CGPoint(x: d / 2, y: d / 2), scale: scale
            ))
        }
    }

    @Test("A bubble never claims the corners of its layout square")
    func cornersFallThrough() {
        for scale in Self.scales {
            let d = FloatingBubbleMetrics.diameter(scale: scale)
            let corners = [
                CGPoint(x: 0, y: 0),
                CGPoint(x: d, y: 0),
                CGPoint(x: 0, y: d),
                CGPoint(x: d, y: d)
            ]
            for corner in corners {
                #expect(
                    !FloatingBubbleMetrics.bubbleClaimsTouch(at: corner, scale: scale),
                    "Corner \(corner) at scale \(scale) must fall through to the alarm row"
                )
            }
        }
    }

    @Test("The strip just above the + — where a Skip pill parks — falls through")
    func skipStripFallsThrough() {
        // 6pt in from the top-left corner of the + bubble's square: visually
        // empty, but inside the bounding rectangle. This is the point the user
        // was tapping when Skip did nothing.
        for scale in Self.scales {
            #expect(!FloatingBubbleMetrics.bubbleClaimsTouch(
                at: CGPoint(x: 6, y: 6), scale: scale
            ))
        }
    }

    @Test("The top of the visible circle is still tappable")
    func circleEdgeIsTappable() {
        for scale in Self.scales {
            let d = FloatingBubbleMetrics.diameter(scale: scale)
            #expect(FloatingBubbleMetrics.bubbleClaimsTouch(
                at: CGPoint(x: d / 2, y: 0), scale: scale
            ))
        }
    }

    @Test("The bubble keeps a comfortable tap target")
    func tapTargetMeetsGuidance() {
        for scale in Self.scales {
            // Apple's 44pt minimum. Clamping to the circle must not shrink the
            // bubble below it.
            #expect(FloatingBubbleMetrics.diameter(scale: scale) >= 44)
        }
    }

    // MARK: - List bottom margin

    @Test("The default layout keeps the 110pt margin that shipped")
    func defaultMarginUnchanged() {
        #expect(FloatingBubbleMetrics.listBottomMargin(scale: 1.0) == 110)
    }

    @Test("Every scale clears the bubble with room for the last row's Skip")
    func marginClearsBubbleAtEveryScale() {
        for scale in Self.scales {
            let margin = FloatingBubbleMetrics.listBottomMargin(scale: scale)
            let bubbleTop = FloatingBubbleMetrics.diameter(scale: scale)
                + FloatingBubbleMetrics.bottomInset
            #expect(
                margin - bubbleTop >= FloatingBubbleMetrics.rowClearance,
                "At scale \(scale) the list stops \(margin - bubbleTop)pt above the bubble"
            )
        }
    }

    @Test("A larger bubble takes a larger margin")
    func marginGrowsWithScale() {
        #expect(
            FloatingBubbleMetrics.listBottomMargin(scale: 1.15)
                > FloatingBubbleMetrics.listBottomMargin(scale: 1.0)
        )
    }
}
