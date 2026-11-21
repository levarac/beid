// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

final class SensingStopConfirmCopyTests: XCTestCase {
  func testCopyWithARecordPromisesItIsKept() {
    let copy = SensingStopConfirmCopy(hasRecord: true)
    XCTAssertEqual(copy.stopTitle, "Stop and keep record")
    XCTAssertEqual(copy.body, "Your record will be saved on this device.")
  }

  func testCopyBeforeAnyRecordAllowsARecordToBeCreatedDuringConfirmation() {
    let copy = SensingStopConfirmCopy(hasRecord: false)
    XCTAssertEqual(copy.stopTitle, "Stop sensing")
    XCTAssertEqual(copy.body, "Any record created will be saved on this device.")
  }
}
