// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import XCTest
@testable import Beid

/// Direct tests of `AggregationRuntime`, the thin native adapter over
/// `BeidSharedKit.aggregation` (beid#109/#162/#142). `DeviceCountTests`
/// exercises the same shared decision through the full `SensingCoordinator`
/// production path; this file is the degenerate companion that targets the
/// adapter boundary directly — the same relationship
/// `UnsentWindowLedgerRuntimeTests.testSharedReducerOwnsDuplicateCloseForRepeatedNativeInputs`
/// has to the ledger family's native lifecycle tests — and it is the target
/// of `compile-fixtures/removed-swift-aggregation-call.patch`'s
/// runtime-authority mutation gate.
@MainActor
final class AggregationRuntimeTests: XCTestCase {
  func testSameDisplayIdAcrossWindowsCountsAsOneDevice() {
    let runtime = AggregationRuntime()

    for enin in 1...5 {
      runtime.recordObservation(windowIndex: enin, peerKey: "rpid-\(enin)", displayId: "device-a")
    }

    XCTAssertEqual(Int(runtime.sessionAggregate.deviceCount), 1)
  }

  func testDistinctDisplayIdsCountSeparately() {
    let runtime = AggregationRuntime()

    runtime.recordObservation(windowIndex: 1, peerKey: "rpid-1", displayId: "device-a")
    runtime.recordObservation(windowIndex: 1, peerKey: "rpid-2", displayId: "device-b")

    XCTAssertEqual(Int(runtime.sessionAggregate.deviceCount), 2)
  }

  func testObservationsWithoutADisplayIdNeverCount() {
    let runtime = AggregationRuntime()

    for enin in 1...3 {
      runtime.recordObservation(windowIndex: enin, peerKey: "rpid-\(enin)", displayId: nil)
    }

    XCTAssertEqual(Int(runtime.sessionAggregate.deviceCount), 0)
  }

  /// The adapter's output must actually be a `BeidSharedKit.aggregation`
  /// value, not a native re-derivation: an independent accumulator built
  /// directly from shared's own API, fed the identical inputs the adapter
  /// forwarded, must agree with what the adapter reports.
  func testSessionAggregateMatchesADirectSharedCallWithTheSameInputs() {
    let runtime = AggregationRuntime()
    runtime.recordObservation(windowIndex: 1, peerKey: "rpid-1", displayId: "device-a")
    runtime.recordObservation(windowIndex: 2, peerKey: "rpid-2", displayId: "device-a")
    runtime.recordObservation(windowIndex: 2, peerKey: "rpid-3", displayId: "device-b")
    runtime.recordObservation(windowIndex: 3, peerKey: "rpid-4", displayId: nil)

    let expected = BeidSharedKit.aggregation.createAggregationObservationInput()
    _ = BeidSharedKit.aggregation.addAggregationObservation(
      input: expected, windowIndex: 1, peerKey: "rpid-1", displayId: "device-a", mutual: false
    )
    _ = BeidSharedKit.aggregation.addAggregationObservation(
      input: expected, windowIndex: 2, peerKey: "rpid-2", displayId: "device-a", mutual: false
    )
    _ = BeidSharedKit.aggregation.addAggregationObservation(
      input: expected, windowIndex: 2, peerKey: "rpid-3", displayId: "device-b", mutual: false
    )
    _ = BeidSharedKit.aggregation.addAggregationObservation(
      input: expected, windowIndex: 3, peerKey: "rpid-4", displayId: nil, mutual: false
    )
    let expectedAggregate = BeidSharedKit.aggregation.aggregateObservationsForSession(
      input: expected, windowsPerBand: 1
    )
    let actualAggregate = runtime.sessionAggregate

    // `Int(...)` normalizes shared's Kotlin `Int` results to Swift's native
    // `Int` width regardless of the exact Swift Export integer mapping.
    XCTAssertEqual(Int(actualAggregate.deviceCount), Int(expectedAggregate.deviceCount))
    XCTAssertEqual(Int(actualAggregate.deviceCount), 2)
    XCTAssertEqual(Int(actualAggregate.observationCount), Int(expectedAggregate.observationCount))
    XCTAssertEqual(Int(actualAggregate.windowCount), Int(expectedAggregate.windowCount))
  }

  /// `mutual` is always passed `false` (beid#109's own documented
  /// limitation — no reciprocity signal exists on-device yet). This is not a
  /// value assertion on `deviceCount` (already covered above); it proves the
  /// adapter never fabricates a mutual signal shared did not receive.
  func testRecordedObservationsNeverReportAsMutual() {
    let runtime = AggregationRuntime()
    runtime.recordObservation(windowIndex: 1, peerKey: "rpid-1", displayId: "device-a")

    let aggregate = runtime.sessionAggregate

    XCTAssertEqual(Int(aggregate.mutualDeviceCount), 0)
    XCTAssertEqual(Int(aggregate.mutualObservationCount), 0)
    XCTAssertEqual(Int(aggregate.deviceCount), 1, "all-observation scope still counts the device")
  }

  /// The window series (#142's buildup indicator) is a live view of the same
  /// accumulated input, not a separate native tally: one distinct ENIN
  /// window index recorded produces exactly one `WindowAggregate` row.
  func testWindowSeriesReflectsDistinctWindowIndexesRecorded() {
    let runtime = AggregationRuntime()
    runtime.recordObservation(windowIndex: 1, peerKey: "rpid-1", displayId: "device-a")
    runtime.recordObservation(windowIndex: 1, peerKey: "rpid-2", displayId: "device-b")
    runtime.recordObservation(windowIndex: 2, peerKey: "rpid-3", displayId: "device-c")

    let aggregate = runtime.sessionAggregate

    XCTAssertEqual(Int(aggregate.windowCount), 2)
    XCTAssertEqual(aggregate.windowAt(index: 0)?.windowIndex, 1)
    XCTAssertEqual(Int(aggregate.windowAt(index: 0)?.peerCount ?? -1), 2)
    XCTAssertEqual(aggregate.windowAt(index: 1)?.windowIndex, 2)
    XCTAssertEqual(Int(aggregate.windowAt(index: 1)?.peerCount ?? -1), 1)
  }

  /// A session with no recorded observations yet still returns a valid,
  /// empty aggregate rather than failing — the adapter always has an input
  /// to aggregate over, even before the first `recordObservation` call.
  func testEmptySessionAggregateHasZeroCountsAndNoWindows() {
    let runtime = AggregationRuntime()

    let aggregate = runtime.sessionAggregate

    XCTAssertTrue(aggregate.isSuccess)
    XCTAssertEqual(Int(aggregate.deviceCount), 0)
    XCTAssertEqual(Int(aggregate.windowCount), 0)
  }
}
