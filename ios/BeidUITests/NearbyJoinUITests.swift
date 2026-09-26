import XCTest

/// Witnesses the production Button action, not a direct call to its helper.
final class NearbyJoinUITests: XCTestCase {
  func testNearbyCardTapJoinsItsVerifiedEventExactlyOnce() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-beid-ui-test", "-beid-nearby-join-fixture"]
    app.launch()

    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()
    XCTAssertTrue(app.buttons["home.scan"].waitForExistence(timeout: 5))
    app.buttons["home.scan"].tap()

    let receipt = app.staticTexts["fixture.nearby-join.receipt"]
    XCTAssertTrue(receipt.waitForExistence(timeout: 5))
    XCTAssertEqual(receipt.label, "joins=0 event=none")
    // SwiftUI exposes the enclosing section identifier on this Button.
    // Match the fixture's actual card label as well, rather than the section title.
    let card = app.buttons.matching(NSPredicate(
      format: "identifier == %@ AND label CONTAINS %@", "scan.nearby-events", "Community night"
    )).firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    XCTAssertTrue(card.isEnabled)
    // XCTest can report this offscreen card as hittable behind the fixed footer.
    // Bring it into the visible part of the actual Scan scroll view first.
    app.scrollViews["scan.sensing"].swipeUp()
    XCTAssertTrue(card.isHittable)
    card.tap()

    // This value changes only when the native engine seam receives a capability.
    // Entering .sensing before permissions complete is not a successful join.
    let expected = "joins=1 event=5d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195"
    let joined = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", expected), object: receipt
    )
    XCTAssertEqual(XCTWaiter.wait(for: [joined], timeout: 5), .completed)
    XCTAssertFalse(card.exists, "the production pre-join cards disappear after admission")
  }
}
