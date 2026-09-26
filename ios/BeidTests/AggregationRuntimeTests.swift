// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation
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

  /// beid#327's last acceptance condition: **iOS and Android must produce the
  /// same numbers from the same observations.**
  ///
  /// The fixture and its expected values live in `shared/`
  /// (`aggregationParityFixtureJson`), and Android's `AggregationRuntimeTest`
  /// already asserts against them. Until this test existed, that proved
  /// Android agreed with the fixture and nothing more — **the two hosts could
  /// still disagree with each other, and no test would notice.**
  ///
  /// What this actually guards is the *adapter*, not the arithmetic: both
  /// hosts call the same shared aggregation functions, so the sums cannot
  /// differ unless a host transforms what it feeds in — deduplicating
  /// repeated detections, offsetting a window index, dropping the
  /// no-display-id rows. Those are the changes this goes red for.
  ///
  /// **The display ids go through `normalizedDisplayIdOrNull` here because
  /// that is what production does, and the two hosts do it in different
  /// places.** Android's `AggregationRuntime` normalises inside
  /// `recordObservation`; iOS normalises one level up, in
  /// `SensingCoordinator.handleDetection`, and its runtime trusts its caller.
  /// The first version of this test fed the fixture raw and reported
  /// `deviceCount` 3 against Android's 2 — which looked like a product
  /// divergence and was not one. Both apps count a peer whose display id
  /// arrives in different hex casing as one device; `DeviceCountTests
  /// .testDisplayIdMatchingIsCaseInsensitive` pins that through iOS's real
  /// detection path.
  func testSharedParityFixtureProducesTheSameNumbersAsAndroid() throws {
    let json = BeidSharedKit.jointestsupport.aggregationParityFixtureJson()
    let rows = try XCTUnwrap(
      try JSONSerialization.jsonObject(
        with: Data(json.utf8)
      ) as? [[String: Any]],
      "the shared fixture must parse as an array of observation objects"
    )
    XCTAssertFalse(rows.isEmpty, "an empty fixture would make every assertion below vacuous")

    let runtime = AggregationRuntime()
    for row in rows {
      let windowIndex = try XCTUnwrap(row["windowIndex"] as? Int)
      let peerKey = try XCTUnwrap(row["peerKey"] as? String)
      // `NSNull` for a detection with no B003 display id, which the fixture
      // includes on purpose — those observations must not count as devices.
      let displayId = BeidSharedKit.sensing.normalizedDisplayIdOrNull(
        detectedDisplayId: row["displayId"] as? String
      )
      XCTAssertTrue(
        runtime.recordObservation(
          windowIndex: windowIndex,
          peerKey: peerKey,
          displayId: displayId
        ),
        "shared rejected a fixture row at its boundary check; the fixture and the adapter disagree"
      )
    }

    let aggregate = runtime.sessionAggregate
    XCTAssertEqual(
      Int(aggregate.observationCount),
      Int(BeidSharedKit.jointestsupport.aggregationParityExpectedObservations())
    )
    XCTAssertEqual(
      Int(aggregate.windowCount),
      Int(BeidSharedKit.jointestsupport.aggregationParityExpectedWindows())
    )
    XCTAssertEqual(
      Int(aggregate.deviceCount),
      Int(BeidSharedKit.jointestsupport.aggregationParityExpectedDevices())
    )
    XCTAssertEqual(
      Int(aggregate.mutualObservationCount),
      Int(BeidSharedKit.jointestsupport.aggregationParityExpectedMutualObservations())
    )
  }
}
