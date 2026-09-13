// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

@MainActor
final class VenueLifecycleTaskOwnerTests: XCTestCase {
  func testOverlappingLifecycleCallbacksRemainIndividuallyOwned() async {
    let owner = VenueLifecycleTaskOwner()
    let firstRelease = XCTestExpectation(description: "first callback release")
    let secondRelease = XCTestExpectation(description: "second callback release")

    owner.start {
      try? await Task.sleep(nanoseconds: .max)
      firstRelease.fulfill()
    }
    owner.start {
      try? await Task.sleep(nanoseconds: .max)
      secondRelease.fulfill()
    }

    XCTAssertEqual(owner.taskCount, 2)
    owner.cancelAll()
    await fulfillment(of: [firstRelease, secondRelease], timeout: 1)
    XCTAssertEqual(owner.taskCount, 0)
  }

  func testDisappearanceCancellationClearsEveryLifecycleHandle() async {
    let owner = VenueLifecycleTaskOwner()
    let firstRelease = XCTestExpectation(description: "first callback release")
    let secondRelease = XCTestExpectation(description: "second callback release")

    owner.start {
      try? await Task.sleep(nanoseconds: .max)
      firstRelease.fulfill()
    }
    owner.start {
      try? await Task.sleep(nanoseconds: .max)
      secondRelease.fulfill()
    }

    owner.cancelAll()
    await fulfillment(of: [firstRelease, secondRelease], timeout: 1)
    XCTAssertEqual(owner.taskCount, 0)
  }
}
