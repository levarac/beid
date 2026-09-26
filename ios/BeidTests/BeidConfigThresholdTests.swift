// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

/// Mutation evidence for beid#231 item 3: compares the read value against a
/// hardcoded literal, not against a live read of the shared constant. A test
/// that compared `BeidConfig.eventConfirmThreshold` against
/// `BeidSharedKit.sensing.defaultEventConfirmThreshold` directly would stay
/// green under any mutation of the shared constant's value, since both sides
/// would move together — this literal comparison is what actually kills a
/// broken or reverted delegation.
///
/// Every existing reference to `BeidConfig.eventConfirmThreshold` elsewhere
/// in this test target reads it dynamically (`let threshold = ...`), which is
/// correct for those tests' purposes but does not serve as mutation evidence
/// for this wiring.
final class BeidConfigThresholdTests: XCTestCase {
  func testEventConfirmThresholdIsThree() {
    XCTAssertEqual(BeidConfig.eventConfirmThreshold, 3)
  }
}
