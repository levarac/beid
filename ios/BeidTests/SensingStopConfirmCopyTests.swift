// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

final class SensingStopConfirmCopyTests: XCTestCase {
  func testCopyWithARecordPromisesItIsKept() {
    let copy = SensingStopConfirmCopy(hasRecord: true)
    XCTAssertEqual(copy.stopTitle, "Stop and keep record")
    XCTAssertEqual(copy.body, "Your record will be saved on this phone. You can join this event again later.")
  }

  func testCopyBeforeAnyRecordSaysNothingIsRecorded() {
    let copy = SensingStopConfirmCopy(hasRecord: false)
    XCTAssertEqual(copy.stopTitle, "Stop sensing")
    XCTAssertEqual(copy.body, "Nothing has been recorded yet. You can join this event again later.")
  }
}
