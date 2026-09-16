// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// beid#464: the iOS adapter over shared's clock preflight, and the notice's
/// state-to-copy mapping. The decision itself is covered by shared's
/// `ClockPreflightTest`; these prove the adapter brackets the request with the
/// injected clocks, reaches the shared runtime, and never publishes silence
/// after a failed fetch.
@MainActor
final class ClockPreflightTests: XCTestCase {
  private let serverDate = "Wed, 16 Sep 2026 11:58:53 GMT"
  private let serverMillis: Int64 = 1_789_559_933_000

  private final class Clocks: @unchecked Sendable {
    var wall: Int64
    var monotonic: Int64
    init(wall: Int64, monotonic: Int64) {
      self.wall = wall
      self.monotonic = monotonic
    }
  }

  private final class FakeSource: TrustedDateSource, @unchecked Sendable {
    var header: String?
    var fetches = 0
    let onFetch: () -> Void
    init(header: String?, onFetch: @escaping () -> Void = {}) {
      self.header = header
      self.onFetch = onFetch
    }
    func fetchDateHeader() async -> String? {
      fetches += 1
      onFetch()
      return header
    }
  }

  private func controller(_ clocks: Clocks, _ source: FakeSource) -> ClockPreflightController {
    ClockPreflightController(
      source: source,
      wallMillis: { clocks.wall },
      monotonicMillis: { clocks.monotonic },
      eninSeconds: 300
    )
  }

  func testStateIsNilBeforeTheFirstCheck() {
    let subject = controller(Clocks(wall: serverMillis, monotonic: 0), FakeSource(header: serverDate))
    XCTAssertNil(subject.stateKey)
  }

  func testAMatchingServerDateIsWithinTolerance() async {
    let clocks = Clocks(wall: serverMillis, monotonic: 1_000)
    let subject = controller(clocks, FakeSource(header: serverDate) { clocks.monotonic += 300 })
    await subject.check()
    XCTAssertEqual(subject.stateKey, "withinTolerance")
  }

  func testADeviceFortySecondsAheadIsOverTolerance() async {
    let subject = controller(
      Clocks(wall: serverMillis + 40_000, monotonic: 1_000),
      FakeSource(header: serverDate)
    )
    await subject.check()
    XCTAssertEqual(subject.stateKey, "overTolerance")
  }

  func testAMissingDateHeaderIsUndeterminable() async {
    let subject = controller(Clocks(wall: serverMillis, monotonic: 1_000), FakeSource(header: nil))
    await subject.check()
    XCTAssertEqual(subject.stateKey, "undeterminable")
  }

  func testAValidCacheIsReusedButStillSeesAManualClockChange() async {
    let clocks = Clocks(wall: serverMillis, monotonic: 1_000)
    let source = FakeSource(header: serverDate)
    let subject = controller(clocks, source)
    await subject.check()
    clocks.wall += 120_000
    await subject.check()
    XCTAssertEqual(source.fetches, 1)
    XCTAssertEqual(subject.stateKey, "overTolerance")
  }

  func testAForcedCheckMeasuresEvenWithAValidCache() async {
    let clocks = Clocks(wall: serverMillis, monotonic: 1_000)
    let source = FakeSource(header: serverDate)
    let subject = controller(clocks, source)
    await subject.check()
    source.header = nil
    await subject.check(force: true)
    XCTAssertEqual(source.fetches, 2)
    XCTAssertEqual(subject.stateKey, "undeterminable")
  }

  func testOperatorOriginIsTakenFromAnHttpsTemplate() {
    XCTAssertEqual(
      OperatorDateHeaderSource.origin(
        fromTemplate: "https://parallax-observation-operator.levarac.workers.dev/v1/events/by-code/{code}"
      )?.absoluteString,
      "https://parallax-observation-operator.levarac.workers.dev/"
    )
    XCTAssertEqual(
      OperatorDateHeaderSource.origin(fromTemplate: "https://example.test:8443/a/{code}")?.absoluteString,
      "https://example.test:8443/"
    )
  }

  func testOperatorOriginIsNilForBlankOrNonHttpsTemplates() {
    XCTAssertNil(OperatorDateHeaderSource.origin(fromTemplate: nil))
    XCTAssertNil(OperatorDateHeaderSource.origin(fromTemplate: ""))
    XCTAssertNil(OperatorDateHeaderSource.origin(fromTemplate: "http://example.test/{code}"))
  }

  func testWithinToleranceAndAnUncheckedClockShowNoNotice() {
    XCTAssertNil(ClockPreflightPresentation.forStateKey(nil))
    XCTAssertNil(ClockPreflightPresentation.forStateKey("withinTolerance"))
  }

  func testOverAndUndeterminableEachHaveTheirOwnNotice() {
    XCTAssertEqual(
      ClockPreflightPresentation.forStateKey("overTolerance")?.statusAccessibilityIdentifier,
      "scan.clock-preflight.over-tolerance"
    )
    XCTAssertEqual(
      ClockPreflightPresentation.forStateKey("undeterminable")?.statusAccessibilityIdentifier,
      "scan.clock-preflight.undeterminable"
    )
  }

  func testAnUnknownKeyIsShownAsUndeterminableRatherThanNothing() {
    XCTAssertEqual(
      ClockPreflightPresentation.forStateKey("someFutureState")?.statusAccessibilityIdentifier,
      "scan.clock-preflight.undeterminable"
    )
  }
}
