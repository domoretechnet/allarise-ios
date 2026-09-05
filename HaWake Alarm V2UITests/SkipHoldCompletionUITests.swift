//
//  SkipHoldCompletionUITests.swift
//  HaWake Alarm V2UITests
//
//  Regression cover for al-lwz: the alarm list's hold-to-skip chip would not
//  complete.
//
//  Why this has to be a UI test. The bug was not in any value the app computes
//  — it was WHICH RUN LOOP MODE the hold timer was registered in. The chip
//  lives inside a `List`, i.e. a UIScrollView, and while a finger is down the
//  main run loop runs in `UITrackingRunLoopMode`. `Timer.scheduledTimer`
//  registers in `.default` only, so the tick simply stopped firing for the
//  whole gesture and progress never reached 1.0. Nothing short of a real
//  synthetic touch, held down, reproduces that: a unit test calling the same
//  functions runs on a run loop that is never in tracking mode and passes
//  against the broken code.
//
//  The test presses the chip for comfortably longer than the configured hold
//  and asserts the skip actually committed — the row offers "Undo", which only
//  appears once an alarm is skipped.
//
//  Requires the simulator to already have at least one recurring, skippable
//  alarm and Skip mode set to hold (the app's default).
//

import XCTest

final class SkipHoldCompletionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHoldToSkipCompletesWhileFingerIsDown() throws {
        let app = XCUIApplication()
        app.launch()

        let skip = app.buttons["Skip"].firstMatch
        guard skip.waitForExistence(timeout: 10) else {
            throw XCTSkip("No skippable alarm on this device — seed one before running.")
        }

        // Capture the chip mid-hold. `press(forDuration:)` blocks, so the shot
        // has to be taken from another queue while the finger is still down —
        // this is the only way to photograph the rising fill and the countdown.
        var midHold: XCUIScreenshot?
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            midHold = XCUIScreen.main.screenshot()
        }

        // Longer than the hold with plenty of headroom, so a pass means the
        // timer really ran, not that the press happened to be lucky.
        skip.press(forDuration: 10.0)

        if let midHold {
            let during = XCTAttachment(screenshot: midHold)
            during.name = "during-hold"
            during.lifetime = .keepAlways
            add(during)
        }

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "after-hold"
        shot.lifetime = .keepAlways
        add(shot)

        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5),
                      "Holding Skip past its hold duration did not commit the skip — "
                      + "the hold timer stalled instead of reaching completion.")
    }
}
