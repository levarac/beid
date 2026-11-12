// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest

/// Coverage for Account's Join event row (gh#101). Joining from the Account
/// sheet starts sensing and presents the sensing screen (v1.1).
final class EventMembershipUITests: XCTestCase {
  private let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testAccountSheetJoinDismissesCodeEntryAndShowsSensing() {
    app.launchArguments = ["-beid-ui-test"]
    app.launch()

    app.buttons["Continue"].tap()
    XCTAssertTrue(app.buttons["Allow Bluetooth"].waitForExistence(timeout: 5))
    app.buttons["Allow Bluetooth"].tap()
    XCTAssertTrue(app.buttons["home.demo.join"].waitForExistence(timeout: 5))

    app.buttons["home.account"].tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))

    // Lower rows can exist in the accessibility tree while sitting behind
    // the footer. Scroll until the whole tappable row is unobstructed.
    let list = app.collectionViews.firstMatch
    scrollUntilTappable(app.buttons["Join event"], in: list)

    // Only one "Join event" element exists in the tree here — the nested
    // event-code sheet is not presented yet, so there's no collision with
    // EventCodeEntryView's own "Join event" submit button.
    let joinEventRow = app.buttons["Join event"]
    XCTAssertTrue(isUnobstructed(joinEventRow, in: list))
    XCTAssertTrue(joinEventRow.isEnabled)
    joinEventRow.tap()

    let codeField = app.textFields["Event code"]
    XCTAssertTrue(codeField.waitForExistence(timeout: 5))
    codeField.tap()
    // Submit via the keyboard's Join return-key action (onSubmit) rather
    // than tapping a button labeled "Join event" — this avoids the label
    // collision with the Account-sheet row while both could be in the tree.
    codeField.typeText("ETHTOKYO2026\n")

    // A successful join from the Account sheet closes the code sheet and the
    // Account sheet, selects the Now tab and presents the sensing screen,
    // which carries STOP SENSING once an event is joined.
    let codeSheetGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: codeField)
    wait(for: [codeSheetGone], timeout: 15)
    XCTAssertTrue(
      app.buttons["scan.stop-sensing"].waitForExistence(timeout: 10),
      "joining from the Account sheet must start sensing and show the sensing screen"
    )
  }

  func testCodeLookupPendingLocksInputAndDuplicateButtonSubmits() {
    launchCodeProgressFixture()
    openAccountCodeEntry()
    let field = app.textFields["Event code"]
    field.typeText("ETHTOKYO2026")
    let join = app.buttons["eventCode.join"]
    join.doubleTap()

    assertCodeLookupPending()
    // A coordinate tap still reaches the disabled control's location.
    join.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    app.buttons["eventCode.paste"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    app.buttons["fixture.code.resubmit"].tap()
    XCTAssertEqual(field.value as? String, "ETHTOKYO2026")
    assertCodeReceipt("submissions=1 resumed=0")
    app.buttons["fixture.code.fail"].tap()
    assertCodeReceipt("submissions=1 resumed=1")
  }

  func testCodeLookupKeyboardSubmitFailureRestoresEditingAndRetry() {
    launchCodeProgressFixture()
    openAccountCodeEntry()
    let field = app.textFields["Event code"]
    field.typeText("FIRST-CODE\n")
    assertCodeLookupPending()
    app.buttons["eventCode.join"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    // Exercise the same handler as a queued second keyboard action. A
    // disabled field cannot receive another physical Return key event.
    app.buttons["fixture.code.resubmit"].tap()
    assertCodeReceipt("submissions=1 resumed=0")

    app.buttons["fixture.code.fail"].tap()
    app.staticTexts["eventCode.pending"].assertDisappears()
    XCTAssertTrue(field.isEnabled)
    XCTAssertTrue(app.buttons["eventCode.paste"].isEnabled)
    XCTAssertTrue(app.buttons["eventCode.join"].isEnabled)
    app.staticTexts["beid couldn't join that event. Check the code and try again."].assertExists()

    field.tap()
    field.typeText("-RETRY\n")
    assertCodeLookupPending()
    XCTAssertEqual(field.value as? String, "FIRST-CODE-RETRY")
    XCTAssertFalse(app.staticTexts["beid couldn't join that event. Check the code and try again."].exists)
    assertCodeReceipt("submissions=2 resumed=1")
    app.buttons["fixture.code.fail"].tap()
    assertCodeReceipt("submissions=2 resumed=2")
  }

  func testCodeLookupSuccessUsesTheExistingAccountRouteOnce() {
    launchCodeProgressFixture()
    openAccountCodeEntry()
    app.textFields["Event code"].typeText("ETHTOKYO2026\n")
    assertCodeLookupPending()
    assertCodeReceipt("submissions=1 resumed=0")
    app.buttons["fixture.code.succeed"].tap()

    app.textFields["Event code"].assertDisappears()
    app.buttons["scan.stop-sensing"].assertHittable()
    // One lookup fed the existing success method; one native Back returns
    // to the root, rather than exposing a second pushed sensing screen.
    app.navigationBars.buttons.firstMatch.tap()
    app.tabButton("Records").assertHittable()
    app.tabButton("Records").tap()
    app.tabButton("Now").tap()
    XCTAssertFalse(app.staticTexts["eventCode.pending"].exists)
    XCTAssertFalse(app.buttons["scan.stop-sensing"].exists)
  }

  func testClosingPendingCodeEntryIgnoresLateSuccessAndFailure() {
    launchCodeProgressFixture()
    for completion in ["fixture.code.succeed", "fixture.code.fail"] {
      openAccountCodeEntry()
      app.textFields["Event code"].typeText("ABANDONED\n")
      assertCodeLookupPending()
      app.buttons["Cancel"].tap()
      app.textFields["Event code"].assertDisappears()

      openAccountCodeEntryFromAccount()
      app.buttons[completion].tap()
      assertCodeReceipt(completion == "fixture.code.succeed"
        ? "submissions=1 resumed=1" : "submissions=2 resumed=2")
      assertFreshCodeEntry()
      app.buttons["Cancel"].tap()
      app.buttons["Done"].tap()
    }
  }

  func testAbandonedCodeLookupCannotUnlockOrWriteErrorsIntoANewAttempt() {
    launchCodeProgressFixture()
    openAccountCodeEntry()
    app.textFields["Event code"].typeText("ABANDONED\n")
    assertCodeReceipt("submissions=1 resumed=0")
    app.buttons["Cancel"].tap()
    app.textFields["Event code"].assertDisappears()
    openAccountCodeEntryFromAccount()
    app.textFields["Event code"].typeText("CURRENT\n")
    assertCodeReceipt("submissions=2 resumed=0")

    app.buttons["fixture.code.fail"].tap()
    assertCodeReceipt("submissions=2 resumed=1")
    assertCodeLookupPending()
    XCTAssertEqual(app.textFields["Event code"].value as? String, "CURRENT")
    XCTAssertFalse(app.staticTexts["beid couldn't join that event. Check the code and try again."].exists)

    app.buttons["fixture.code.fail"].tap()
    assertCodeReceipt("submissions=2 resumed=2")
    app.staticTexts["eventCode.pending"].assertDisappears()
    XCTAssertTrue(app.textFields["Event code"].isEnabled)
    app.staticTexts["beid couldn't join that event. Check the code and try again."].assertExists()
  }

  func testNativeBackDuringPendingCodeEntryIgnoresLateCompletion() {
    launchCodeProgressFixture(extraArguments: ["-beid-clock-preflight-fixture"])
    for (index, completion) in ["fixture.code.succeed", "fixture.code.fail"].enumerated() {
      app.buttons["home.demo.join"].assertHittable()
      app.buttons["home.demo.join"].tap()
      app.buttons["scan.manual-entry"].assertHittable()
      app.buttons["scan.manual-entry"].tap()
      app.textFields["Event code"].assertHittable()
      app.textFields["Event code"].tap()
      app.textFields["Event code"].typeText("ABANDONED\n")
      assertCodeLookupPending()
      app.navigationBars.buttons.firstMatch.tap()
      app.textFields["Event code"].assertDisappears()

      app.buttons["scan.manual-entry"].tap()
      app.buttons[completion].tap()
      assertCodeReceipt("submissions=\(index + 1) resumed=\(index + 1)")
      assertFreshCodeEntry()
      app.navigationBars.buttons.firstMatch.tap()
      app.navigationBars.buttons.firstMatch.tap()
      app.tabButton("Now").assertHittable()
    }
  }

  func testEmptyCodeValidationDoesNotStartPendingLookup() {
    launchCodeProgressFixture()
    openAccountCodeEntry()
    app.textFields["Event code"].typeText("   \n")

    app.staticTexts["Enter an event code to continue. Ask the event organizer for it."].assertExists()
    XCTAssertFalse(app.staticTexts["eventCode.pending"].exists)
    XCTAssertTrue(app.textFields["Event code"].isEnabled)
    XCTAssertTrue(app.buttons["eventCode.paste"].isEnabled)
    XCTAssertTrue(app.buttons["eventCode.join"].isEnabled)
    assertCodeReceipt("submissions=0 resumed=0")
  }

  private func launchCodeProgressFixture(extraArguments: [String] = []) {
    app.launchArguments = ["-beid-ui-test", "-beid-code-entry-progress-fixture"] + extraArguments
    app.launch()
    app.buttons["Continue"].assertHittable()
    app.buttons["Continue"].tap()
    app.buttons["Allow Bluetooth"].assertHittable()
    app.buttons["Allow Bluetooth"].tap()
    app.tabButton("Records").assertHittable()
    app.tabButton("Records").tap()
    app.tabButton("Now").tap()
  }

  private func openAccountCodeEntry() {
    app.buttons["home.account"].assertHittable()
    app.buttons["home.account"].tap()
    openAccountCodeEntryFromAccount()
  }

  private func openAccountCodeEntryFromAccount() {
    let row = app.buttons["Join event"]
    scrollUntilTappable(row, in: app.collectionViews.firstMatch)
    row.assertHittable()
    row.tap()
    app.textFields["Event code"].assertHittable()
    app.textFields["Event code"].tap()
  }

  private func assertCodeLookupPending() {
    let pending = app.staticTexts["eventCode.pending"]
    pending.assertHittable()
    XCTAssertEqual(pending.label, "Looking up event code…")
    XCTAssertFalse(app.textFields["Event code"].isEnabled)
    XCTAssertFalse(app.buttons["eventCode.paste"].isEnabled)
    XCTAssertFalse(app.buttons["eventCode.join"].isEnabled)
  }

  private func assertCodeReceipt(_ value: String) {
    let receipt = app.staticTexts["fixture.code.receipt"]
    let updated = expectation(for: NSPredicate(format: "label == %@", value), evaluatedWith: receipt)
    wait(for: [updated], timeout: UITestWait.timeout)
  }

  private func assertFreshCodeEntry() {
    app.textFields["Event code"].assertHittable()
    XCTAssertTrue(app.textFields["Event code"].isEnabled)
    XCTAssertEqual(app.textFields["Event code"].value as? String, "Paste event code")
    XCTAssertFalse(app.staticTexts["eventCode.pending"].exists)
    XCTAssertFalse(app.staticTexts["beid couldn't join that event. Check the code and try again."].exists)
    XCTAssertFalse(app.buttons["scan.stop-sensing"].exists)
  }

  /// An offscreen List row may already `exist`, so require its full frame to
  /// sit between the root Done control and the fixed Account footer.
  private func scrollUntilTappable(_ element: XCUIElement, in container: XCUIElement, maxAttempts: Int = 6) {
    var attempts = 0
    while !isUnobstructed(element, in: container), attempts < maxAttempts {
      if element.exists, element.frame.minY < container.frame.minY + 56 {
        container.swipeDown()
      } else {
        container.swipeUp()
      }
      attempts += 1
    }
  }

  private func isUnobstructed(_ element: XCUIElement, in container: XCUIElement) -> Bool {
    guard element.exists, container.exists else { return false }
    let visibleTop = container.frame.minY + 56
    let footer = app.staticTexts["account.version.value"]
    let visibleBottom = min(
      container.frame.maxY - 60,
      footer.exists ? footer.frame.minY - 8 : container.frame.maxY
    )
    let frame = element.frame
    return element.isHittable && frame.minY >= visibleTop && frame.maxY <= visibleBottom
  }
}
