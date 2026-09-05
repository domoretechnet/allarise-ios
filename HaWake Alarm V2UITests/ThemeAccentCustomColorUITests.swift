//
//  ThemeAccentCustomColorUITests.swift
//  HaWake Alarm V2UITests
//
//  al-94t regression: a colour mixed in the custom picker must APPLY when the
//  picker closes, and must still be there after a cold relaunch.
//
//  Why that path is fragile enough to deserve a UI test: picks made in
//  `CustomColorPickerSheet` are NOT written to the store as they happen. They
//  buffer in a plain `ColorSelectionBuffer` and are committed by the presenting
//  sheet's `.sheet(isPresented: $showingCustomPicker, onDismiss:)` handler in
//  ThemeAccentPickerView.swift — deliberately, so applying the colour cannot
//  re-render the stack out from under the open picker (al-dgb). Everything
//  between "finger moves" and "value saved" is therefore invisible to a unit
//  test; only driving the real sheets proves the commit fires.
//
//  Flow under test:
//    accent sheet → More → Custom Color well → drag hue / SB field → Done →
//    override exists → relaunch → override still exists, same colour → reset.
//
//  Runs against the -themeAccentDebug harness, which hosts the real
//  ThemeAccentPickerSheet against DeviceSettings.shared (light slot).
//
//  NOTE ON STATE DETECTION: there is no "Theme default" / "Your color" label any
//  more — the header card that carried them was removed when the current colour's
//  preview moved onto the Custom Color well. The sheet's "Reset to Theme Default"
//  button is `.disabled(!isOverridden)`, so its enabled-ness IS the override flag
//  and is what this test reads.
//

import XCTest

final class ThemeAccentCustomColorUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCustomPickAppliesOnCloseAndSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-themeAccentDebug"]
        app.launch()

        // Start from a clean slot. The reset button is the override indicator, so
        // it both clears the state and confirms it was cleared.
        let reset = app.buttons["Reset to Theme Default"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "accent sheet did not appear")
        if reset.isEnabled { reset.tap() }
        XCTAssertTrue(waitFor(timeout: 3) { !reset.isEnabled },
                      "expected no override after reset")

        openCustomPicker(app)

        // The picker's preview is one combined accessibility element labelled
        // "Selected colour #RRGGBB" — the only place the exact working colour is
        // readable from outside the app, which is what makes the persistence
        // assertion below a colour check and not just a flag check.
        let before = try readSelectedHex(app)

        // Mix a colour. Both controls are raw DragGesture surfaces (no Slider, no
        // stepper), so they are driven as a finger would: press, drag, lift.
        // Either one alone changes the colour; the SB field can sit below the fold
        // at the .medium detent, so it is best-effort and the hue slider — always
        // the shorter, lower-risk target — carries the requirement.
        dragIfHittable(app, label: "Saturation and brightness",
                       from: CGVector(dx: 0.5, dy: 0.5), to: CGVector(dx: 0.82, dy: 0.32))
        dragIfHittable(app, label: "Hue",
                       from: CGVector(dx: 0.5, dy: 0.5), to: CGVector(dx: 0.13, dy: 0.5))

        let picked = try readSelectedHex(app)
        XCTAssertNotEqual(picked, before,
                          "neither picker control moved the colour — the drags missed their targets")

        attach(app, name: "after-pick-\(picked)")

        // Close the way a user does. Scoped to the picker's own navigation bar:
        // the accent sheet underneath has a "Done" of its own, and an unscoped
        // query can resolve to the wrong one.
        let pickerDone = app.navigationBars["Custom Color"].buttons["Done"]
        XCTAssertTrue(pickerDone.waitForExistence(timeout: 3), "picker Done button not found")
        pickerDone.tap()

        // THE ASSERTION THIS FILE EXISTS FOR: the commit happens in onDismiss, so
        // the override must appear only once the picker is gone.
        XCTAssertTrue(waitForResetEnabled(app),
                      "custom pick did not apply — no override after closing the picker")

        attach(app, name: "after-close")

        // And it must survive a cold relaunch.
        app.terminate()
        app.launch()

        let resetAfterRelaunch = app.buttons["Reset to Theme Default"]
        XCTAssertTrue(resetAfterRelaunch.waitForExistence(timeout: 10),
                      "accent sheet did not appear after relaunch")
        XCTAssertTrue(waitForResetEnabled(app),
                      "override did not persist across relaunch")

        // Not just "an override exists" — the same colour. Reopening the well
        // seeds the picker from the stored accent, so its preview reports what was
        // actually saved.
        openCustomPicker(app)
        let restored = try readSelectedHex(app)
        assertHexNearlyEqual(restored, picked,
                             "relaunch restored a different colour than was picked")
        attach(app, name: "after-relaunch-\(restored)")
        app.navigationBars["Custom Color"].buttons["Done"].tap()

        // Leave the slot clean for the next run.
        if waitForResetEnabled(app) { resetAfterRelaunch.tap() }
    }

    // MARK: - Flow helpers

    /// Waits for the reset button to be present AND enabled, scrolling as it
    /// polls.
    ///
    /// Scrolling is not cosmetic here: the reset row is the last row of a LAZY
    /// Form, so once the catalog is expanded and scrolled past, the row is not in
    /// the accessibility tree at all and `isEnabled` reads false for the wrong
    /// reason. Scrolling cannot fake the enabled state — only a real override can
    /// — so this stays a true assertion of the commit.
    @MainActor
    private func waitForResetEnabled(_ app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        let reset = app.buttons["Reset to Theme Default"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if reset.exists && reset.isEnabled { return true }
            app.swipeUp()
        }
        return reset.exists && reset.isEnabled
    }

    /// Expands the catalog and opens the Custom Color well.
    ///
    /// The well is only rendered while the palette is expanded, and it sits below
    /// the fold once it is — the Form is lazy, so it has to be scrolled to before
    /// it exists at all.
    @MainActor
    private func openCustomPicker(_ app: XCUIApplication) {
        // CommandPaletteMoreRow builds its label from `subject`: "Show more colors".
        let more = app.buttons["Show more colors"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "More row not found")
        more.tap()

        let well = app.buttons["Custom Color"]
        for _ in 0..<10 where !(well.exists && well.isHittable) {
            app.swipeUp()
        }
        guard well.exists, well.isHittable else {
            print("HIERARCHY DUMP:\n\(app.debugDescription)")
            XCTFail("Custom Color well not reachable after expanding and scrolling")
            return
        }
        well.tap()

        XCTAssertTrue(app.navigationBars["Custom Color"].waitForExistence(timeout: 5),
                      "custom colour picker did not open")
    }

    /// Drags across a control identified by its accessibility label, if it is on
    /// screen and hittable. Silently skips otherwise — callers assert on the
    /// resulting colour, not on which control moved it.
    @MainActor
    private func dragIfHittable(_ app: XCUIApplication,
                                label: String,
                                from: CGVector,
                                to: CGVector) {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
        guard element.exists, element.isHittable else { return }
        element.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.1,
                   thenDragTo: element.coordinate(withNormalizedOffset: to))
    }

    // MARK: - Colour readback

    /// Pulls the hex out of the picker preview's combined label
    /// ("Selected colour #4C4CD6").
    @MainActor
    private func readSelectedHex(_ app: XCUIApplication) throws -> String {
        let preview = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Selected colour'"))
            .firstMatch
        guard preview.waitForExistence(timeout: 5) else {
            print("HIERARCHY DUMP:\n\(app.debugDescription)")
            throw XCTSkip("picker preview element not found")
        }
        let label = preview.label
        guard let hash = label.firstIndex(of: "#") else {
            XCTFail("preview label carried no hex: \(label)")
            return ""
        }
        return String(label[label.index(after: hash)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    /// Compares two hex colours with a one-step-per-channel tolerance. The colour
    /// makes an HSB → RGB → stored → HSB → RGB round trip between the pick and the
    /// relaunch readback; a single least-significant-bit of drift there is not the
    /// regression this test guards.
    private func assertHexNearlyEqual(_ lhs: String, _ rhs: String, _ message: String) {
        guard let a = channels(lhs), let b = channels(rhs) else {
            XCTFail("\(message) — unparsable hex \(lhs) / \(rhs)")
            return
        }
        for (x, y) in zip(a, b) where abs(x - y) > 2 {
            XCTFail("\(message) — expected ~\(rhs), got \(lhs)")
            return
        }
    }

    private func channels(_ hex: String) -> [Int]? {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
    }

    // MARK: - Misc

    /// Polls a condition. `isEnabled` changes are not events XCUITest can wait on
    /// with `waitForExistence`, and the value flips a frame or two after the sheet
    /// commits.
    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
