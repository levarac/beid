// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

final class SensingStopConfirmCopyTests: XCTestCase {
  func testCopyWithARecordExplainsWhereItStays() {
    let copy = SensingStopConfirmCopy(hasRecord: true)
    XCTAssertEqual(copy.stopTitle, "Stop sensing")
    XCTAssertEqual(copy.body, "This ends your sensing session at this event. Any saved Record stays in Records on this device.")
  }

  func testCopyBeforeAnyRecordDoesNotPromiseOne() {
    let copy = SensingStopConfirmCopy(hasRecord: false)
    XCTAssertEqual(copy.stopTitle, "Stop sensing")
    XCTAssertEqual(copy.body, "This ends your sensing session at this event. No Record has been created yet.")
  }
}
