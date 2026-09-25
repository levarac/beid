// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// beid#142 — `SensingCoordinator.sessionAggregate` is the full shared
/// `BeidSharedKit.aggregation.SessionAggregate` published alongside
/// `devicesVerified`, so `RecordingView`'s window-buildup line can read
/// `mutualDeviceCount`/`windowCount`/`windowAt(index:)` straight off
/// shared's own type instead of a second native re-projection (beid#222
/// removed the corresponding mutual-confirmations line from `RecordingView`
/// itself, but `mutualDeviceCount`/`mutualObservationCount` stay covered
/// here at the coordinator level). `DeviceCountTests` covers
/// `devicesVerified` itself in depth; this file covers the additional
/// fields this property surfaces.
@MainActor
final class SessionAggregateExposureTests: XCTestCase {
  private func makeCoordinator() -> SensingCoordinator {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-aggregate-test-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      preconditionFailure("Unable to create test directory: \(error)")
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let coordinator = SensingCoordinator(
      windowReportStore: WindowReportStore(
        fileURL: directory.appendingPathComponent("window-reports.json")
      ),
      selfProofStore: SelfProofStore(
        fileURL: directory.appendingPathComponent("self-proofs.json")
      ),
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(
        fileURL: directory.appendingPathComponent("binding-records.json")
      ),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
      ),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false
    return coordinator
  }

  func testSessionAggregateIsNilBeforeAnyObservation() {
    let coordinator = makeCoordinator()

    XCTAssertNil(coordinator.sessionAggregate)
  }

  func testSessionAggregateDeviceCountMatchesDevicesVerified() {
    let coordinator = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-SESSION-AGGREGATE-DEVICE-COUNT")

    for device in 0..<3 {
      coordinator.handleDetection(
        enin: 1,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: 1),
        detectedDisplayId: DetectionFixture.displayId(device: device)
      )
    }

    XCTAssertEqual(Int(coordinator.sessionAggregate?.deviceCount ?? -1), coordinator.devicesVerified)
    XCTAssertEqual(coordinator.devicesVerified, 3)
  }

  /// #109's own documented limitation, restated as a coordinator-level
  /// guarantee: no real caller can set `mutual: true` today, so the mutual
  /// scope stays an honest `0` however many devices are observed. This is
  /// the field `RecordingView`'s mutual-confirmations line reads (DECISIONS
  /// 2026-08-09 "相互観測数は端末上では 0 のまま正直に表示する").
  func testSessionAggregateMutualCountsStayZeroRegardlessOfDeviceCount() {
    let coordinator = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-SESSION-AGGREGATE-MUTUAL-ZERO")

    for device in 0..<5 {
      coordinator.handleDetection(
        enin: 1,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: 1),
        detectedDisplayId: DetectionFixture.displayId(device: device)
      )
    }

    XCTAssertEqual(Int(coordinator.sessionAggregate?.mutualDeviceCount ?? -1), 0)
    XCTAssertEqual(Int(coordinator.sessionAggregate?.mutualObservationCount ?? -1), 0)
  }

  /// The window series backs #142's buildup indicator: one distinct ENIN
  /// window observed produces exactly one `WindowAggregate` row, sparse (no
  /// zero-filling) per shared's own sparse-series contract.
  func testSessionAggregateWindowSeriesReflectsDistinctWindowsObserved() {
    let coordinator = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-SESSION-AGGREGATE-WINDOWS")

    for enin in 1...3 {
      coordinator.handleDetection(
        enin: enin,
        rpid: DetectionFixture.rotatingRpid(device: 0, enin: enin),
        detectedDisplayId: DetectionFixture.displayId(device: 0)
      )
    }

    let aggregate = coordinator.sessionAggregate
    XCTAssertEqual(Int(aggregate?.windowCount ?? -1), 3)
    XCTAssertEqual(aggregate?.windowAt(index: 0)?.windowIndex, 1)
    XCTAssertEqual(aggregate?.windowAt(index: 2)?.windowIndex, 3)
  }

  func testFirstLiveObservationSuppliesWindowAndDisplayOnlySensingData() {
    let coordinator = makeCoordinator()
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    coordinator.startSensing(eventCode: "TEST-LIVE-WINDOW")

    XCTAssertNil(coordinator.firstSightingAt)
    XCTAssertTrue(coordinator.detectedDisplayIDs.isEmpty)
    coordinator.handleDetection(
      enin: 6_000_000,
      rpid: DetectionFixture.rotatingRpid(device: 0, enin: 6_000_000),
      detectedDisplayId: DetectionFixture.displayId(device: 0),
      observedAt: observedAt
    )

    // The first window is still open; shared already exposes its observed row.
    XCTAssertEqual(Int(coordinator.sessionAggregate?.windowCount ?? -1), 1)
    XCTAssertEqual(coordinator.firstSightingAt, observedAt)
    XCTAssertEqual(coordinator.detectedDisplayIDs, Set([DetectionFixture.displayId(device: 0)]))

    coordinator.reset()
    XCTAssertNil(coordinator.firstSightingAt)
    XCTAssertTrue(coordinator.detectedDisplayIDs.isEmpty)
    XCTAssertNil(coordinator.sessionAggregate)
  }

  func testSessionAggregateResetsToNilOnSessionReset() {
    let coordinator = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-SESSION-AGGREGATE-RESET")
    coordinator.handleDetection(
      enin: 1,
      rpid: DetectionFixture.rotatingRpid(device: 0, enin: 1),
      detectedDisplayId: DetectionFixture.displayId(device: 0)
    )
    XCTAssertNotNil(coordinator.sessionAggregate)

    coordinator.reset()

    XCTAssertNil(coordinator.sessionAggregate)
  }

  /// Demo mode (`observeOneDemoDevice`, beid#162) drives the same
  /// `recordDeviceIdentity` path as real detections, so it must publish
  /// `sessionAggregate` too — this is what lets `RecordingView`'s new lines
  /// render real (if fabricated) values on the Simulator, the only place
  /// this UI is reachable without a physical device (no BLE radio).
  func testDemoModeAlsoPublishesSessionAggregate() async {
    let coordinator = makeCoordinator()
    coordinator.useDemoEventMode = true

    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertEqual(Int(coordinator.sessionAggregate?.deviceCount ?? -1), coordinator.devicesVerified)
    XCTAssertGreaterThan(coordinator.devicesVerified, 0)
  }
}
