// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Combine
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

  // MARK: - beid#464: the two production wirings, not just the adapter

  private var joinableCard: NearbyEventCard {
    NearbyEventCard(
      beaconDisplayName: "Community night",
      eventIdHex: "0102030405060708090a0b0c0d0e0f10",
      displayValidFromEpochSeconds: nil,
      displayValidUntilEpochSeconds: nil,
      eventCodeHashHex: "9adc61d60dda843e"
    )
  }

  /// Waits until the controller publishes `expected`. The wirings below fire
  /// `check()` from an unstructured `Task`, exactly as production does, so the
  /// verdict lands after this test resumes; reading `stateKey` straight after
  /// the call would race it. `@Published` republishes the current value on
  /// subscription, so a value already reached fulfils immediately.
  private func awaitStateKey(
    _ expected: String?,
    on subject: ClockPreflightController,
    timeout: TimeInterval = 5
  ) async {
    let reached = expectation(description: "clock preflight publishes \(expected ?? "nil")")
    reached.assertForOverFulfill = false
    let subscription = subject.$stateKey.sink { published in
      if published == expected { reached.fulfill() }
    }
    await fulfillment(of: [reached], timeout: timeout)
    subscription.cancel()
  }

  /// The retry closure the production notice view installs. `body` is a single
  /// `ClockPreflightNotice`, and the cast goes through `Any` because `body` is
  /// declared with an opaque type.
  private func retryAction(of view: ClockPreflightNoticeView) throws -> () -> Void {
    let body: Any = view.body
    let notice = try XCTUnwrap(
      body as? ClockPreflightNotice,
      "ClockPreflightNoticeView.body is no longer a single ClockPreflightNotice"
    )
    return notice.onRetry
  }

  /// "Check again" is the one control a participant has after being told the
  /// clock is wrong, so it has to measure even while the cached sample is
  /// still valid — a button that reprints the cached verdict would look like
  /// it worked and tell them nothing new.
  func testCheckAgainOnTheNoticeMeasuresEvenWhileTheCacheIsValid() async throws {
    let clocks = Clocks(wall: serverMillis, monotonic: 1_000)
    let source = FakeSource(header: serverDate)
    let subject = controller(clocks, source)
    await subject.check()
    XCTAssertEqual(subject.stateKey, "withinTolerance")
    XCTAssertEqual(source.fetches, 1)

    source.header = nil
    let retry = try retryAction(of: ClockPreflightNoticeView(preflight: subject))
    retry()

    await awaitStateKey("undeterminable", on: subject)
    XCTAssertEqual(
      source.fetches,
      2,
      "Check again answered from the valid cache instead of re-measuring"
    )
  }

  /// Opening the scan screen is not the moment that matters: a participant can
  /// stand in front of the beacon for an hour before tapping. The tap re-reads
  /// the clock, as Android's `joinNearbyEvent` does.
  func testJoiningANearbyEventChecksTheDeviceClock() async {
    let clocks = Clocks(wall: serverMillis, monotonic: 1_000)
    let source = FakeSource(header: serverDate)
    let preflight = controller(clocks, source)
    let engine = RecordingEventJoinControl()
    let coordinator = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    coordinator.useDemoEventMode = false

    SensingView(sensing: coordinator, clockPreflight: preflight)
      .joinNearbyEventTapped(joinableCard)

    await awaitStateKey("withinTolerance", on: preflight)
    XCTAssertEqual(source.fetches, 1, "joining did not read the device clock")
    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 1, "the join itself did not happen")
  }

  /// The case the join-time check exists for: the clock moved after the screen
  /// opened, the cached sample is still valid, and shared catches the jump
  /// without a second request. Android's twin is
  /// `joiningANearbyEventSeesAClockChangedSinceTheScreenOpened`.
  func testJoiningANearbyEventSeesAClockChangedSinceTheScanOpened() async {
    let clocks = Clocks(wall: serverMillis, monotonic: 1_000)
    let source = FakeSource(header: serverDate)
    let preflight = controller(clocks, source)
    await preflight.check()
    XCTAssertEqual(preflight.stateKey, "withinTolerance")

    clocks.wall += 120_000
    let engine = RecordingEventJoinControl()
    let coordinator = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    coordinator.useDemoEventMode = false

    SensingView(sensing: coordinator, clockPreflight: preflight)
      .joinNearbyEventTapped(joinableCard)

    await awaitStateKey("overTolerance", on: preflight)
    XCTAssertEqual(source.fetches, 1, "a valid cached sample was re-measured")
    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 1, "the join itself did not happen")
  }

  /// The eligibility guard stays in front of both effects: a card shared did
  /// not make joinable neither joins nor spends a request on the clock.
  ///
  /// The clock half is an inverted expectation rather than a count read after
  /// one yield, because `fetchDateHeader` runs off the main actor: a single
  /// yield does not guarantee a fetch would have been observed, so the count
  /// alone would read as zero even if the guard had moved.
  func testTappingACardSharedDidNotMakeJoinableNeitherChecksNorJoins() async {
    let clocks = Clocks(wall: serverMillis, monotonic: 1_000)
    let neverFetched = expectation(description: "a card that cannot be joined never reads the clock")
    neverFetched.isInverted = true
    let source = FakeSource(header: serverDate) { neverFetched.fulfill() }
    let preflight = controller(clocks, source)
    let engine = RecordingEventJoinControl()
    let coordinator = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    coordinator.useDemoEventMode = false
    let notJoinable = NearbyEventCard(
      beaconDisplayName: "Community night",
      eventIdHex: nil,
      displayValidFromEpochSeconds: nil,
      displayValidUntilEpochSeconds: nil,
      eventCodeHashHex: "9adc61d60dda843e"
    )

    SensingView(sensing: coordinator, clockPreflight: preflight)
      .joinNearbyEventTapped(notJoinable)

    await fulfillment(of: [neverFetched], timeout: 0.5)
    XCTAssertEqual(source.fetches, 0)
    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 0)
    XCTAssertNil(preflight.stateKey)
  }
}
