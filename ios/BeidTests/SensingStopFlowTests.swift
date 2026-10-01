// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

@MainActor
final class SensingStopFlowTests: XCTestCase {
  func testPrejoinCloseBypassesConfirmationAndKeepsAutomaticTransport() {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    let coordinator = makeCoordinator(sensingCoordinator: sensing)
    coordinator.scanPresented = true

    coordinator.requestScanClose()

    XCTAssertFalse(coordinator.scanPresented)
    XCTAssertNil(coordinator.stopConfirmSnapshot)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertEqual(coordinator.sensingCoordinator.phase, .idle)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 0)
  }

  func testHomePrejoinStopStopsAutomaticTransportWithoutConfirmation() {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    let coordinator = makeCoordinator(sensingCoordinator: sensing)

    coordinator.requestHomeStopSensing()

    XCTAssertFalse(coordinator.scanPresented)
    XCTAssertNil(coordinator.stopConfirmSnapshot)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
    XCTAssertEqual(coordinator.sensingCoordinator.phase, .idle)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 1)
  }

  func testKeepSensingPreservesTheLiveProofAndDoesNotFinalize() async {
    let coordinator = makeCoordinator()
    await reachRecording(coordinator)
    let proofID = coordinator.sensingCoordinator.currentProofID

    coordinator.requestScanClose()
    XCTAssertEqual(coordinator.stopConfirmSnapshot?.proofID, proofID)
    coordinator.keepSensing()

    XCTAssertNil(coordinator.stopConfirmSnapshot)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertEqual(coordinator.sensingCoordinator.currentProofID, proofID)
    XCTAssertTrue(coordinator.scanPresented)
    guard case .recording = coordinator.sensingCoordinator.phase else {
      return XCTFail("KEEP SENSING must leave recording live")
    }
    _ = coordinator.sensingCoordinator.reset()
  }

  func testStopFinalizesOnceThenDoneShowsPersistentProofCollected() async throws {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    let coordinator = makeCoordinator(sensingCoordinator: sensing)
    await reachRecording(coordinator)
    let proofID = coordinator.sensingCoordinator.currentProofID

    // A future Stream B/D caller may request CLOSE outside the scan cover.
    coordinator.scanPresented = false
    coordinator.requestScanClose()
    XCTAssertTrue(coordinator.scanPresented)
    coordinator.confirmStopSensing()

    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 0)
    XCTAssertEqual(coordinator.sealedSnapshot?.recordID, proofID)
    XCTAssertTrue(coordinator.scanPresented)
    XCTAssertEqual(coordinator.sensingCoordinator.phase, .idle)
    let sealedAt = coordinator.sealedSnapshot?.sealedAt
    let sealedDetectedCount = coordinator.sealedSnapshot?.detectedDeviceCount
    let sealedWindowCount = coordinator.sealedSnapshot?.aggregate.map { Int($0.windowCount) }
    let storedProof = try XCTUnwrap(proofID.flatMap { coordinator.proofStore.proof(withId: $0) })
    coordinator.confirmStopSensing()
    XCTAssertEqual(coordinator.sealedSnapshot?.sealedAt, sealedAt)
    coordinator.doneWithSealedRecord()
    XCTAssertTrue(coordinator.scanPresented)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertEqual(coordinator.proofCollectedSnapshot?.recordID, storedProof.id)
    XCTAssertEqual(coordinator.proofCollectedSnapshot?.eventName, storedProof.eventName)
    XCTAssertEqual(coordinator.proofCollectedSnapshot?.date, storedProof.date)
    XCTAssertEqual(coordinator.proofCollectedSnapshot?.detectedPeerCount, sealedDetectedCount)
    XCTAssertEqual(coordinator.proofCollectedSnapshot?.observedWindowCount, sealedWindowCount)
    coordinator.doneWithSealedRecord()
    XCTAssertNotNil(coordinator.proofCollectedSnapshot)
    XCTAssertTrue(coordinator.scanPresented, "07 must persist until View collection")

    coordinator.viewCollectionAfterProofCollected()
    XCTAssertFalse(coordinator.scanPresented)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
  }

  func testHomeStopWithStoredProofCannotBypass05eAndStopsTransportAfterConfirmation() async {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    let coordinator = makeCoordinator(sensingCoordinator: sensing)
    await reachRecording(coordinator)
    guard let proofID = coordinator.sensingCoordinator.currentProofID else {
      return XCTFail("recording must create a Proof")
    }
    XCTAssertNotNil(coordinator.proofStore.proof(withId: proofID))
    coordinator.scanPresented = false

    coordinator.requestHomeStopSensing()
    coordinator.requestHomeStopSensing()

    XCTAssertTrue(coordinator.scanPresented)
    XCTAssertEqual(coordinator.stopConfirmSnapshot?.proofID, proofID)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
    XCTAssertEqual(coordinator.sensingCoordinator.currentProofID, proofID)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 0)

    coordinator.confirmStopSensing()
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 1)
    XCTAssertEqual(coordinator.sealedSnapshot?.recordID, proofID)
    XCTAssertNil(coordinator.stopConfirmSnapshot)
    coordinator.doneWithSealedRecord()
    XCTAssertEqual(coordinator.proofCollectedSnapshot?.recordID, proofID)
    XCTAssertTrue(coordinator.scanPresented)
    coordinator.viewCollectionAfterProofCollected()
    XCTAssertFalse(coordinator.scanPresented)
  }

  func testKeepSensingAfterHomeStopClearsTransportIntentForLaterScanClose() async {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    let coordinator = makeCoordinator(sensingCoordinator: sensing)
    await reachRecording(coordinator)
    guard let proofID = coordinator.sensingCoordinator.currentProofID else {
      return XCTFail("recording must create a Proof")
    }
    coordinator.scanPresented = false

    coordinator.requestHomeStopSensing()
    XCTAssertEqual(coordinator.stopConfirmSnapshot?.proofID, proofID)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 0)
    coordinator.keepSensing()

    XCTAssertNil(coordinator.stopConfirmSnapshot)
    XCTAssertEqual(coordinator.sensingCoordinator.currentProofID, proofID)
    coordinator.requestScanClose()
    XCTAssertEqual(coordinator.stopConfirmSnapshot?.proofID, proofID)
    coordinator.confirmStopSensing()

    XCTAssertEqual(coordinator.sealedSnapshot?.recordID, proofID)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 0)
  }

  func testStaleProofIDCannotFinalizeOrShowSealed() async {
    let coordinator = makeCoordinator()
    await reachRecording(coordinator)
    coordinator.requestScanClose()

    _ = coordinator.sensingCoordinator.reset()
    coordinator.confirmStopSensing()

    XCTAssertFalse(coordinator.scanPresented)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
    XCTAssertNil(coordinator.stopConfirmSnapshot)
  }

  func testNewProofWhileConfirmationIsOpenReturnsToItsLiveScan() async {
    let coordinator = makeCoordinator()
    await reachRecording(coordinator)
    let oldProofID = coordinator.sensingCoordinator.currentProofID
    coordinator.requestScanClose()

    coordinator.sensingCoordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.sensingCoordinator.waitForDemoSequenceToFinish()
    XCTAssertNotEqual(coordinator.sensingCoordinator.currentProofID, oldProofID)
    coordinator.confirmStopSensing()

    XCTAssertTrue(coordinator.scanPresented)
    XCTAssertNil(coordinator.stopConfirmSnapshot)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
    guard case .recording = coordinator.sensingCoordinator.phase else {
      return XCTFail("a newer Proof must remain live")
    }
    _ = coordinator.sensingCoordinator.reset()
  }

  func testMissingStoredProofReturnsToTheLiveScan() async {
    let coordinator = makeCoordinator()
    await reachRecording(coordinator)
    coordinator.requestScanClose()
    coordinator.proofStore.resetForUITesting()

    coordinator.confirmStopSensing()

    XCTAssertTrue(coordinator.scanPresented)
    XCTAssertNil(coordinator.stopConfirmSnapshot)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
    XCTAssertNotNil(coordinator.sensingCoordinator.currentProofID)
    _ = coordinator.sensingCoordinator.reset()
  }

  func testSealedSnapshotUsesObservationsReceivedWhileConfirmationWasOpen() async {
    let coordinator = makeCoordinator()
    coordinator.scanPresented = true
    coordinator.sensingCoordinator.runDemoSequence(
      demoEvent: .demoSample,
      stepDelayNanos: 100_000_000
    )
    for _ in 0..<100 where coordinator.sensingCoordinator.currentProofID == nil {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    guard coordinator.sensingCoordinator.currentProofID != nil else {
      return XCTFail("Demo did not create a Proof")
    }

    coordinator.requestScanClose()
    XCTAssertNotNil(coordinator.stopConfirmSnapshot)
    let earlierCount = coordinator.sensingCoordinator.devicesVerified
    await coordinator.sensingCoordinator.waitForDemoSequenceToFinish()
    let laterCount = coordinator.sensingCoordinator.devicesVerified
    XCTAssertGreaterThan(laterCount, earlierCount)

    coordinator.confirmStopSensing()
    XCTAssertEqual(coordinator.sealedSnapshot?.detectedDeviceCount, laterCount)
    XCTAssertEqual(
      coordinator.sealedSnapshot?.aggregate?.deviceCount,
      Int32(laterCount)
    )
  }

  func testProofCollectedDoesNotTurnMissingAggregateIntoZeroWindows() {
    let proof = Proof(eventName: "Real event", date: Date(), peersVerified: 2)
    let snapshot = ProofCollectedSnapshot(
      proof: proof, detectedPeerCount: 2, observedWindowCount: nil
    )

    XCTAssertEqual(snapshot.withValue, "2 peers")
    XCTAssertFalse(snapshot.withValue.contains("window"))
    XCTAssertEqual(snapshot.shortRecordID, RecordIDDisplay.abbreviated(proof.id))
  }

  private func makeCoordinator(sensingCoordinator: SensingCoordinator? = nil) -> AppCoordinator {
    let identifier = UUID().uuidString
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("sensing-stop-\(identifier).json")
    let defaults = UserDefaults(suiteName: "sensing-stop-\(identifier)")!
    return AppCoordinator(
      proofStore: ProofStore(fileURL: fileURL),
      sensingCoordinator: sensingCoordinator,
      registryClient: nil,
      userDefaults: defaults
    )
  }

  private func reachRecording(_ coordinator: AppCoordinator) async {
    coordinator.scanPresented = true
    coordinator.sensingCoordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.sensingCoordinator.waitForDemoSequenceToFinish()
    XCTAssertNotNil(coordinator.sensingCoordinator.currentProofID)
  }
}
