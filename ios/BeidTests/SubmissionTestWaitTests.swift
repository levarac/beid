// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@MainActor
final class SubmissionTestWaitTests: XCTestCase {
  func testSatisfiedConditionReturnsWithoutSleeping() async throws {
    // Even a zero budget must evaluate the observable condition once.
    let completed = try await SubmissionTestWait.until(timeout: 0) { true }
    XCTAssertTrue(completed)
  }

  func testDelayedConditionCompletesBeforeDeadline() async throws {
    let started = ProcessInfo.processInfo.systemUptime
    let completed = try await SubmissionTestWait.until(timeout: 2) {
      ProcessInfo.processInfo.systemUptime - started >= 0.1
    }
    XCTAssertTrue(completed, "a delayed condition must be observed, not sampled only once")
  }

  func testMissingConditionStopsAtDeadline() async throws {
    let started = ProcessInfo.processInfo.systemUptime
    let completed = try await SubmissionTestWait.until(timeout: 0.1) { false }
    XCTAssertFalse(completed, "a missing condition must not be reported as completed")
    XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.1)
  }

  func testCancellationStopsTheWait() async throws {
    let waiting = Task {
      try await SubmissionTestWait.until { false }
    }
    waiting.cancel()
    do {
      _ = try await waiting.value
      XCTFail("a cancelled wait must throw")
    } catch is CancellationError {
      // Expected, without waiting for the hosted-runner budget.
    }
  }

  func testConditionErrorPropagatesWithoutTimingOut() async throws {
    enum ListenerFailure: Error { case failed }
    do {
      _ = try await SubmissionTestWait.until { throw ListenerFailure.failed }
      XCTFail("a failed listener must throw its error, not wait until timeout")
    } catch ListenerFailure.failed {
      // Expected.
    }
  }
}
