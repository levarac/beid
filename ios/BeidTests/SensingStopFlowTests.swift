// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

@MainActor
final class SensingStopFlowTests: XCTestCase {
  func testStopOutcomeFixtureRequiresUITestGateAndKnownMode() {
    XCTAssertNil(StopOutcomeUITestFixture.selectedMode(arguments: ["-beid-stop-outcome-fixture", "save-failure"]))
    XCTAssertNil(StopOutcomeUITestFixture.selectedMode(arguments: ["-beid-ui-test", "-beid-stop-outcome-fixture"]))
    XCTAssertNil(StopOutcomeUITestFixture.selectedMode(arguments: ["-beid-ui-test", "-beid-stop-outcome-fixture", "unknown"]))
    XCTAssertEqual(StopOutcomeUITestFixture.selectedMode(
      arguments: ["-beid-ui-test", "-beid-stop-outcome-fixture", "save-failure"]
    ), .saveFailure)
  }

  func testSaveFailureUIFixtureHasNoDurableRecordAndRetainsFinalizationArtifacts() async throws {
    let fixture = StopOutcomeUITestFixture(mode: .saveFailure)
    let app = makeCoordinator(sensingCoordinator: fixture.sensingCoordinator, proofStore: fixture.proofStore)
    await fixture.prepare()
    app.scanPresented = true
    let proofID = try XCTUnwrap(fixture.proofID)
    XCTAssertNil(fixture.proofStore.proof(withId: proofID))
    XCTAssertNotNil(fixture.proofStore.lastPersistenceError)
    XCTAssertNil(fixture.checkpointStore.checkpoint, "First recording precedes demo ENIN advancement")
    XCTAssertNil(fixture.sensingCoordinator.eventSigningKeyFailure)
    XCTAssertNil(fixture.sensingCoordinator.ownerKeyOperationFailure)

    app.requestScanClose()
    app.confirmStopSensing()

    XCTAssertEqual(fixture.sensingCoordinator.phase, .idle)
    XCTAssertNil(fixture.proofStore.proof(withId: proofID))
    XCTAssertNotNil(fixture.proofStore.lastPersistenceError)
    XCTAssertNil(fixture.selfProofStore.record(forProofId: proofID))
    XCTAssertNotNil(fixture.sensingCoordinator.sessionAggregateSnapshot(forProofId: proofID))
    let aggregateURL = fixture.directory.appendingPathComponent("aggregate.json")
    let aggregateBytes = try Data(contentsOf: aggregateURL)
    XCTAssertNil(app.sealedSnapshot)
    XCTAssertNil(app.proofCollectedSnapshot)
    XCTAssertNil(fixture.sensingCoordinator.eventSigningKeyFailure)
    XCTAssertNil(fixture.sensingCoordinator.ownerKeyOperationFailure)
    app.confirmStopSensing()
    XCTAssertEqual(fixture.signingCallCount, 0, "Missing endpoints must not manufacture signing inputs")
    XCTAssertEqual(try Data(contentsOf: aggregateURL), aggregateBytes)
  }

  func testNilSignatureUIFixtureRetainsUnsignedRecordAndCheckpointWithoutAnAlert() async throws {
    let fixture = StopOutcomeUITestFixture(mode: .nilSignature)
    let app = makeCoordinator(sensingCoordinator: fixture.sensingCoordinator, proofStore: fixture.proofStore)
    await fixture.prepare()
    app.scanPresented = true
    let proofID = try XCTUnwrap(fixture.proofID)
    XCTAssertNotNil(fixture.proofStore.proof(withId: proofID))
    let recordURL = fixture.directory.appendingPathComponent("proofs.json")
    let recordBytes = try Data(contentsOf: recordURL)
    XCTAssertNil(fixture.checkpointStore.checkpoint, "Demo checkpoints only at finalization")

    app.requestScanClose()
    app.confirmStopSensing()
    app.confirmStopSensing()

    XCTAssertEqual(fixture.sensingCoordinator.phase, .idle)
    XCTAssertNotNil(fixture.proofStore.proof(withId: proofID))
    XCTAssertEqual(try Data(contentsOf: recordURL), recordBytes)
    XCTAssertNotNil(ProofStore(fileURL: recordURL).proof(withId: proofID), "Reload must find the durable Record")
    XCTAssertNil(fixture.selfProofStore.record(forProofId: proofID))
    XCTAssertEqual(fixture.checkpointStore.checkpoint?.proofId, proofID)
    XCTAssertEqual(SelfProofCheckpointStore(
      fileURL: fixture.directory.appendingPathComponent("checkpoint.json")
    ).checkpoint?.proofId, proofID)
    XCTAssertNotNil(fixture.sensingCoordinator.sessionAggregateSnapshot(forProofId: proofID))
    XCTAssertNil(fixture.sensingCoordinator.eventSigningKeyFailure)
    XCTAssertNil(fixture.sensingCoordinator.ownerKeyOperationFailure)
    XCTAssertNil(app.sealedSnapshot)
    XCTAssertNil(app.proofCollectedSnapshot)
    XCTAssertEqual(fixture.signingCallCount, 1)
  }

  func testSaveFailureWithEndpointsAlreadyRaisesPersistenceAlert() async throws {
    let fixture = StopOutcomeUITestFixture(mode: .saveFailureWithEndpoints)
    let app = makeCoordinator(sensingCoordinator: fixture.sensingCoordinator, proofStore: fixture.proofStore)
    await fixture.prepare()
    app.scanPresented = true
    let proofID = try XCTUnwrap(fixture.proofID)
    XCTAssertNil(fixture.sensingCoordinator.eventSigningKeyFailure)

    app.requestScanClose()
    app.confirmStopSensing()

    XCTAssertEqual(fixture.sensingCoordinator.eventSigningKeyFailure, .discardFailed)
    XCTAssertNil(fixture.proofStore.proof(withId: proofID))
    XCTAssertNotNil(fixture.selfProofStore.record(forProofId: proofID), "Preserve independently saved signature bytes")
    XCTAssertNotNil(fixture.sensingCoordinator.sessionAggregateSnapshot(forProofId: proofID))
    XCTAssertNil(app.sealedSnapshot)
    XCTAssertNil(app.proofCollectedSnapshot)
  }

  func testSigningErrorUIFixtureUsesExistingAlertAndRetainsUnsignedArtifacts() async throws {
    let fixture = StopOutcomeUITestFixture(mode: .signingError)
    let app = makeCoordinator(sensingCoordinator: fixture.sensingCoordinator, proofStore: fixture.proofStore)
    await fixture.prepare()
    app.scanPresented = true
    let proofID = try XCTUnwrap(fixture.proofID)
    XCTAssertNil(fixture.sensingCoordinator.eventSigningKeyFailure, "Fault is armed after setup")

    app.requestScanClose()
    app.confirmStopSensing()
    app.confirmStopSensing()

    XCTAssertEqual(fixture.sensingCoordinator.eventSigningKeyFailure, .unavailable)
    XCTAssertNil(fixture.sensingCoordinator.ownerKeyOperationFailure)
    XCTAssertNotNil(fixture.proofStore.proof(withId: proofID))
    XCTAssertNil(fixture.selfProofStore.record(forProofId: proofID))
    XCTAssertEqual(fixture.checkpointStore.checkpoint?.proofId, proofID)
    XCTAssertNil(app.sealedSnapshot)
    XCTAssertNil(app.proofCollectedSnapshot)
    fixture.sensingCoordinator.dismissEventSigningKeyFailure()
    XCTAssertNil(fixture.sensingCoordinator.eventSigningKeyFailure)
    app.confirmStopSensing()
    XCTAssertNil(fixture.sensingCoordinator.eventSigningKeyFailure)
  }

  func testStopAfterFailedProofSaveEndsSensingWithoutClaimingASavedRecord() async throws {
    let proofURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("sensing-stop-unsaved-\(UUID().uuidString).json")
    let proofStore = ProofStore(fileURL: proofURL,
                                writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    let coordinator = makeCoordinator(sensingCoordinator: sensing, proofStore: proofStore)
    await reachRecording(coordinator)
    let proofID = try XCTUnwrap(sensing.currentProofID)
    XCTAssertNil(proofStore.proof(withId: proofID))
    XCTAssertNotNil(proofStore.lastPersistenceError)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 0)

    coordinator.requestScanClose()
    coordinator.confirmStopSensing()

    XCTAssertEqual(sensing.phase, .idle)
    XCTAssertNil(sensing.currentProofID)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 1)
    XCTAssertFalse(coordinator.scanPresented)
    XCTAssertNil(coordinator.stopConfirmSnapshot)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
    XCTAssertNotNil(proofStore.lastPersistenceError, "stopping must preserve the save failure")
  }

  func testPrejoinStopBypassesConfirmationAndEndsParticipantTransport() {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    let coordinator = makeCoordinator(sensingCoordinator: sensing)
    coordinator.scanPresented = true

    coordinator.requestScanClose()

    XCTAssertFalse(coordinator.scanPresented)
    XCTAssertNil(coordinator.stopConfirmSnapshot)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertEqual(coordinator.sensingCoordinator.phase, .idle)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 1)
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

  func testStopFinalizesOnceThenDoneShowsPersistentRecordCollected() async throws {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    let coordinator = makeCoordinator(sensingCoordinator: sensing)
    await reachRecording(coordinator)
    let proofID = coordinator.sensingCoordinator.currentProofID

    // A stop requested from Now must use the same confirmation.
    coordinator.scanPresented = false
    coordinator.requestScanClose()
    XCTAssertTrue(coordinator.scanPresented)
    coordinator.confirmStopSensing()

    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 1)
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
    XCTAssertEqual(coordinator.sealedSnapshot?.recordID, proofID)
    XCTAssertEqual(coordinator.proofCollectedSnapshot?.recordID, storedProof.id)
    XCTAssertEqual(coordinator.proofCollectedSnapshot?.eventName, storedProof.eventName)
    XCTAssertEqual(coordinator.proofCollectedSnapshot?.date, storedProof.date)
    XCTAssertEqual(coordinator.proofCollectedSnapshot?.detectedPeerCount, sealedDetectedCount)
    XCTAssertEqual(coordinator.proofCollectedSnapshot?.observedWindowCount, sealedWindowCount)
    coordinator.doneWithSealedRecord()
    XCTAssertNotNil(coordinator.proofCollectedSnapshot)
    XCTAssertTrue(coordinator.scanPresented, "07 must persist until View records")

    coordinator.viewCollectionAfterProofCollected()
    XCTAssertFalse(coordinator.scanPresented)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
    XCTAssertEqual(coordinator.selectedHomeTab, .records)
    XCTAssertEqual(coordinator.sealedSnapshot?.recordID, proofID)
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

  func testKeepSensingAfterHomeStopStillRequiresExplicitStopLater() async {
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
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 1)
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

  func testConfirmedStopEndsSensingWhenTheStoredProofDisappears() async {
    let coordinator = makeCoordinator()
    await reachRecording(coordinator)
    coordinator.requestScanClose()
    coordinator.proofStore.resetForUITesting()

    coordinator.confirmStopSensing()

    XCTAssertFalse(coordinator.scanPresented)
    XCTAssertNil(coordinator.stopConfirmSnapshot)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
    XCTAssertNil(coordinator.sensingCoordinator.currentProofID)
    XCTAssertEqual(coordinator.sensingCoordinator.phase, .idle)
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

    XCTAssertEqual(snapshot.withValue, "2 devices")
    XCTAssertFalse(snapshot.withValue.contains("window"))
    XCTAssertEqual(snapshot.shortRecordID, RecordIDDisplay.abbreviated(proof.id))
  }

  func testBackPreservesRecordingWithoutFinalizationOrStoppingTransport() async {
    let engine = RecordingEventJoinControl()
    let crypto = DeterministicSensingCryptography()
    let sensing = makeIsolatedSensingCoordinator(for: self, sensingCryptography: crypto, eventJoinControl: engine)
    let coordinator = makeCoordinator(sensingCoordinator: sensing)
    await reachRecording(coordinator)
    let proofID = sensing.currentProofID

    coordinator.scanPresented = false
    coordinator.updateHomeStandby(isVisible: true, isSceneActive: true)

    XCTAssertEqual(sensing.currentProofID, proofID)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 0)
    XCTAssertNil(coordinator.stopConfirmSnapshot)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertFalse(crypto.calls.contains { if case .signSelfProof = $0 { return true }; return false })
    _ = sensing.reset()
  }

  func testNilSelfProofDoesNotClaimRecordWasSaved() async {
    let crypto = DeterministicSensingCryptography(selfProofSignature: nil)
    let sensing = makeIsolatedSensingCoordinator(for: self, sensingCryptography: crypto)
    let coordinator = makeCoordinator(sensingCoordinator: sensing)
    await reachRecording(coordinator)

    coordinator.requestScanClose()
    coordinator.confirmStopSensing()

    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
    XCTAssertFalse(coordinator.scanPresented)
  }

  func testFailedSelfProofDoesNotClaimRecordWasSaved() async {
    let crypto = DeterministicSensingCryptography()
    let sensing = makeIsolatedSensingCoordinator(for: self, sensingCryptography: crypto)
    let coordinator = makeCoordinator(sensingCoordinator: sensing)
    await reachRecording(coordinator)
    crypto.selfProofError = OwnerKeyOperationError.storage(.readFailed(-42))

    coordinator.requestScanClose()
    coordinator.confirmStopSensing()

    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
    XCTAssertEqual(sensing.ownerKeyOperationFailure, .unavailable, "The real signing throw already has a root alert")
    XCTAssertNil(sensing.eventSigningKeyFailure, "Do not manufacture a second signing alert")
  }

  func testStopDuringDetectingRequiresConfirmationAndKeepPreservesSession() async {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    let app = makeCoordinator(sensingCoordinator: sensing)
    app.scanPresented = true
    sensing.runDemoScenario(.appReviewGolden, stepDelayNanos: 0, stopWhenPhaseReaches: .eventFound)
    await sensing.waitForDemoScenarioPreviewToSettle()
    let phase = sensing.phase
    let count = sensing.devicesVerified
    XCTAssertNil(sensing.currentProofID)

    app.requestScanClose()
    XCTAssertNotNil(app.stopConfirmSnapshot)
    app.keepSensing()

    XCTAssertNil(app.stopConfirmSnapshot)
    XCTAssertEqual(sensing.phase, phase)
    XCTAssertEqual(sensing.devicesVerified, count)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 0)
    XCTAssertTrue(app.scanPresented)
    _ = sensing.reset()
  }

  func testConfirmedStopDuringDetectingEndsParticipationWithoutSavedClaim() async {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    let app = makeCoordinator(sensingCoordinator: sensing)
    app.scanPresented = true
    sensing.runDemoScenario(.appReviewGolden, stepDelayNanos: 0, stopWhenPhaseReaches: .eventFound)
    await sensing.waitForDemoScenarioPreviewToSettle()

    app.requestScanClose()
    XCTAssertNotNil(app.stopConfirmSnapshot)
    app.confirmStopSensing()

    XCTAssertNil(app.stopConfirmSnapshot)
    XCTAssertNil(app.sealedSnapshot)
    XCTAssertNil(app.proofCollectedSnapshot)
    XCTAssertEqual(sensing.phase, .idle)
    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 1)
    XCTAssertFalse(app.scanPresented)
  }

  private func makeCoordinator(sensingCoordinator: SensingCoordinator? = nil,
                               proofStore: ProofStore? = nil) -> AppCoordinator {
    let identifier = UUID().uuidString
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("sensing-stop-\(identifier).json")
    let defaults = UserDefaults(suiteName: "sensing-stop-\(identifier)")!
    return AppCoordinator(
      proofStore: proofStore ?? ProofStore(fileURL: fileURL),
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
