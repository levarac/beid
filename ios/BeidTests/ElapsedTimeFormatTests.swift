// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

final class ElapsedTimeFormatTests: XCTestCase {
  func testMinutesSecondsFormatting() {
    XCTAssertEqual(ElapsedTimeFormat.minutesSeconds(0), "0:00")
    XCTAssertEqual(ElapsedTimeFormat.minutesSeconds(59), "0:59")
    XCTAssertEqual(ElapsedTimeFormat.minutesSeconds(60), "1:00")
    XCTAssertEqual(ElapsedTimeFormat.minutesSeconds(3599), "59:59")
    XCTAssertEqual(ElapsedTimeFormat.minutesSeconds(3600), "60:00")
    XCTAssertEqual(ElapsedTimeFormat.minutesSeconds(-5), "0:00")
  }
}
