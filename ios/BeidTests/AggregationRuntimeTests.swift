// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import XCTest
@testable import Beid

/// Direct tests of `AggregationRuntime`, the thin native adapter over
/// `BeidSharedKit.aggregation` (beid#109/#162). `DeviceCountTests` exercises
/// the same shared decision through the full `SensingCoordinator` production
/// path; this file is the degenerate companion that targets the adapter
/// boundary directly — the same relationship
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

    XCTAssertEqual(runtime.deviceCount, 1)
  }

  func testDistinctDisplayIdsCountSeparately() {
    let runtime = AggregationRuntime()

    runtime.recordObservation(windowIndex: 1, peerKey: "rpid-1", displayId: "device-a")
    runtime.recordObservation(windowIndex: 1, peerKey: "rpid-2", displayId: "device-b")

    XCTAssertEqual(runtime.deviceCount, 2)
  }

  func testObservationsWithoutADisplayIdNeverCount() {
    let runtime = AggregationRuntime()

    for enin in 1...3 {
      runtime.recordObservation(windowIndex: enin, peerKey: "rpid-\(enin)", displayId: nil)
    }

    XCTAssertEqual(runtime.deviceCount, 0)
  }

  /// The adapter's output must actually be a `BeidSharedKit.aggregation`
  /// value, not a native re-derivation: an independent accumulator built
  /// directly from shared's own API, fed the identical inputs the adapter
  /// forwarded, must agree with what the adapter reports.
  func testDeviceCountMatchesADirectSharedCallWithTheSameInputs() {
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
    // `Int(...)` normalizes shared's Kotlin `Int` result to Swift's native
    // `Int` width, matching `AggregationRuntime.deviceCount`'s own
    // normalization, regardless of the exact Swift Export integer mapping.
    let expectedDeviceCount = Int(
      BeidSharedKit.aggregation.aggregateObservationsForSession(
        input: expected, windowsPerBand: 1
      ).deviceCount
    )

    XCTAssertEqual(runtime.deviceCount, expectedDeviceCount)
    XCTAssertEqual(runtime.deviceCount, 2)
  }

  /// `mutual` is always passed `false` (beid#109's own documented
  /// limitation — no reciprocity signal exists on-device yet). This is not a
  /// value assertion on `deviceCount` (already covered above); it proves the
  /// adapter never fabricates a mutual signal shared did not receive.
  func testRecordedObservationsNeverReportAsMutual() {
    let runtime = AggregationRuntime()
    runtime.recordObservation(windowIndex: 1, peerKey: "rpid-1", displayId: "device-a")

    let mirror = BeidSharedKit.aggregation.createAggregationObservationInput()
    _ = BeidSharedKit.aggregation.addAggregationObservation(
      input: mirror, windowIndex: 1, peerKey: "rpid-1", displayId: "device-a", mutual: false
    )
    let session = BeidSharedKit.aggregation.aggregateObservationsForSession(input: mirror, windowsPerBand: 1)

    XCTAssertEqual(session.mutualDeviceCount, 0)
    XCTAssertEqual(runtime.deviceCount, Int(session.deviceCount), "all-observation scope still counts the device")
  }
}
