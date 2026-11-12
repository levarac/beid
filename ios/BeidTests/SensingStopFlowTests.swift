// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

@MainActor
final class SensingStopFlowTests: XCTestCase {
  func testSynchronousEarlierNoticeCannotHideCurrentMissingRecordOutcome() async throws {
    let fixture = try makeNoticeBoundaryFixture()
    let proofID = try await prepareNoticeRecording(fixture, withWindowEndpoints: false)
    fixture.app.requestScanClose()
    let sessionID = try XCTUnwrap(fixture.app.stopConfirmSnapshot?.event.sessionID)
    fixture.proofStore.resetForUITesting()
    fixture.runtime.onNextSubmit = { runtime in runtime.onEventSigningKeyFailure?(.unavailable) }
    let submits = fixture.runtime.submits

    fixture.app.confirmStopSensing()

    XCTAssertEqual(fixture.runtime.submits, submits + 1, "The unrelated notice is published inside STOP")
    XCTAssertEqual(fixture.sensing.phase, .idle)
    XCTAssertNil(fixture.proofStore.proof(withId: proofID))
    XCTAssertNil(fixture.selfProofStore.record(forProofId: proofID))
    XCTAssertEqual(fixture.sensing.eventSigningKeyFailure, .unavailable)
    let outcome = try XCTUnwrap(fixture.app.stopOutcome)
    XCTAssertEqual(outcome.sessionID, sessionID)
    XCTAssertTrue(fixture.app.scanPresented, "The actionable outcome must remain behind the unrelated alert")
    XCTAssertNil(fixture.app.sealedSnapshot)
    let stopped = try fixture.effects()
    fixture.app.confirmStopSensing()
    XCTAssertEqual(try fixture.effects(), stopped)
    fixture.sensing.dismissEventSigningKeyFailure()
    XCTAssertNil(fixture.sensing.eventSigningKeyFailure)
    XCTAssertEqual(fixture.app.stopOutcome, outcome, "Acknowledging the root notice must expose this outcome")
    XCTAssertTrue(fixture.app.scanPresented)
    fixture.app.dismissStopOutcome()
    XCTAssertFalse(fixture.app.scanPresented)
    XCTAssertEqual(fixture.app.selectedHomeTab, .now)
    let acknowledged = try fixture.effects()
    fixture.app.confirmStopSensing()
    fixture.app.dismissStopOutcome()
    fixture.sensing.dismissEventSigningKeyFailure()
    XCTAssertNil(fixture.app.stopOutcome)
    XCTAssertNil(fixture.sensing.eventSigningKeyFailure)
    XCTAssertEqual(try fixture.effects(), acknowledged, "Consumed acknowledgements must not retry or write")
  }

  func testSynchronousEarlierNoticeCannotHideCurrentSealedRecord() async throws {
    let fixture = try makeNoticeBoundaryFixture()
    let proofID = try await prepareNoticeRecording(fixture)
    fixture.app.requestScanClose()
    fixture.runtime.onNextSubmit = { runtime in runtime.onSigningKeyChange?("EARLIER-SESSION", .keyChanged) }
    let submits = fixture.runtime.submits

    fixture.app.confirmStopSensing()

    XCTAssertEqual(fixture.runtime.submits, submits + 1)
    XCTAssertEqual(fixture.sensing.eventSigningKeyFailure, .changed)
    XCTAssertEqual(fixture.sensing.eventSigningKeyNoticeEventCode, "EARLIER-SESSION")
    XCTAssertEqual(fixture.app.sealedSnapshot?.recordID, proofID)
    XCTAssertNotNil(fixture.proofStore.proof(withId: proofID))
    XCTAssertNotNil(fixture.selfProofStore.record(forProofId: proofID))
    XCTAssertTrue(fixture.app.scanPresented)
    XCTAssertNil(fixture.app.stopOutcome)
    let sealed = fixture.app.sealedSnapshot
    let stopped = try fixture.effects()
    fixture.app.confirmStopSensing()
    XCTAssertEqual(try fixture.effects(), stopped)
    fixture.sensing.dismissEventSigningKeyFailure()
    XCTAssertNil(fixture.sensing.eventSigningKeyFailure)
    XCTAssertEqual(fixture.runtime.acknowledgedEvents, ["EARLIER-SESSION"])
    XCTAssertEqual(fixture.app.sealedSnapshot?.recordID, sealed?.recordID)
    XCTAssertEqual(fixture.app.sealedSnapshot?.sealedAt, sealed?.sealedAt)
    let acknowledged = try fixture.effects()
    fixture.app.confirmStopSensing()
    fixture.sensing.dismissEventSigningKeyFailure()
    XCTAssertEqual(try fixture.effects(), acknowledged)
    fixture.app.doneWithSealedRecord()
    XCTAssertEqual(fixture.app.proofCollectedSnapshot?.recordID, proofID)
  }

  func testPreexistingSameEventNoticeDoesNotExplainLaterSessionAndConsumptionDoesNotLeak() async throws {
    let fixture = try makeNoticeBoundaryFixture()
    let proofID = try await prepareNoticeRecording(fixture, withWindowEndpoints: false)
    // The notice belongs to an earlier session using the SAME event code.
    // Event-code equality cannot establish finalization ownership.
    fixture.runtime.onSigningKeyChange?(EventSession.demoSample.id, .keyChanged)
    fixture.app.requestScanClose()
    fixture.proofStore.resetForUITesting()

    fixture.app.confirmStopSensing()

    XCTAssertNil(fixture.proofStore.proof(withId: proofID))
    let first = try XCTUnwrap(fixture.app.stopOutcome)
    XCTAssertEqual(fixture.sensing.eventSigningKeyNoticeEventCode, EventSession.demoSample.id)
    XCTAssertEqual(fixture.sensing.eventSigningKeyFailure, .changed)
    fixture.sensing.dismissEventSigningKeyFailure()
    XCTAssertEqual(fixture.app.stopOutcome, first)
    fixture.app.dismissStopOutcome()
    let nextProofID = try await prepareNoticeRecording(fixture)
    fixture.app.confirmStopSensing() // No new confirmation: the old one is consumed.
    XCTAssertEqual(fixture.sensing.currentProofID, nextProofID)
    XCTAssertNil(fixture.app.stopOutcome)
    fixture.app.requestScanClose()
    XCTAssertNotEqual(fixture.app.stopConfirmSnapshot?.event.sessionID, first.sessionID)
    fixture.app.confirmStopSensing()
    XCTAssertEqual(fixture.app.sealedSnapshot?.recordID, nextProofID)
    XCTAssertNil(fixture.sensing.eventSigningKeyFailure)
    XCTAssertNil(fixture.app.stopOutcome)
  }

  func testCurrentPersistenceFailureRemainsSoleOutcomeBehindSynchronousEarlierNotice() async throws {
    let fixture = try makeNoticeBoundaryFixture()
    _ = try await prepareNoticeRecording(fixture)
    fixture.app.requestScanClose()
    fixture.proofStore.resetForUITesting()
    fixture.runtime.onEventSigningKeyFailure?(.discardFailed)
    fixture.runtime.onNextSubmit = { runtime in runtime.onSigningKeyChange?("EARLIER-SESSION", .keyChanged) }

    fixture.app.confirmStopSensing()

    XCTAssertEqual(fixture.sensing.eventSigningKeyFailure, .changed)
    XCTAssertNil(fixture.app.stopOutcome)
    XCTAssertNil(fixture.app.sealedSnapshot)
    XCTAssertFalse(fixture.app.scanPresented)
    let stopped = try fixture.effects()
    fixture.app.confirmStopSensing()
    XCTAssertEqual(try fixture.effects(), stopped)
    fixture.sensing.dismissEventSigningKeyFailure()
    XCTAssertEqual(fixture.sensing.eventSigningKeyFailure, .discardFailed,
                   "The current finalization's existing explanation survives the earlier notice")
    fixture.sensing.dismissEventSigningKeyFailure()
    let acknowledged = try fixture.effects()
    fixture.app.confirmStopSensing()
    fixture.sensing.dismissEventSigningKeyFailure()
    XCTAssertNil(fixture.sensing.eventSigningKeyFailure)
    XCTAssertNil(fixture.app.stopOutcome)
    XCTAssertEqual(try fixture.effects(), acknowledged)
  }

  func testCurrentOwnerFailureRemainsSoleOutcomeWithSynchronousEarlierNotice() async throws {
    let fixture = try makeNoticeBoundaryFixture()
    let proofID = try await prepareNoticeRecording(fixture)
    fixture.crypto.selfProofError = OwnerKeyOperationError.storage(.readFailed(-42))
    fixture.app.requestScanClose()
    fixture.runtime.onNextSubmit = { runtime in runtime.onEventSigningKeyFailure?(.unavailable) }

    fixture.app.confirmStopSensing()

    XCTAssertEqual(fixture.sensing.ownerKeyOperationFailure, .unavailable)
    XCTAssertEqual(fixture.sensing.eventSigningKeyFailure, .unavailable)
    XCTAssertNotNil(fixture.proofStore.proof(withId: proofID))
    XCTAssertNil(fixture.selfProofStore.record(forProofId: proofID))
    XCTAssertNil(fixture.app.stopOutcome)
    XCTAssertNil(fixture.app.sealedSnapshot)
    XCTAssertFalse(fixture.app.scanPresented)
    let stopped = try fixture.effects()
    fixture.app.confirmStopSensing()
    fixture.sensing.dismissEventSigningKeyFailure()
    fixture.sensing.dismissEventSigningKeyFailure()
    fixture.app.confirmStopSensing()
    XCTAssertEqual(fixture.sensing.ownerKeyOperationFailure, .unavailable)
    XCTAssertNil(fixture.sensing.eventSigningKeyFailure)
    XCTAssertNil(fixture.app.stopOutcome)
    XCTAssertEqual(try fixture.effects(), stopped)
  }

  func testCurrentFinalizationFailureStillExplainsStopWhenNoticeValueAlreadyMatches() async throws {
    let fixture = try makeNoticeBoundaryFixture()
    _ = try await prepareNoticeRecording(fixture)
    fixture.app.requestScanClose()
    fixture.proofStore.resetForUITesting()
    fixture.runtime.onEventSigningKeyFailure?(.discardFailed)

    fixture.app.confirmStopSensing()

    XCTAssertEqual(fixture.sensing.eventSigningKeyFailure, .discardFailed)
    XCTAssertNil(fixture.app.stopOutcome, "An unchanged enum value does not mean no current failure occurred")
    XCTAssertNil(fixture.app.sealedSnapshot)
    XCTAssertFalse(fixture.app.scanPresented)
    let stopped = try fixture.effects()
    fixture.app.confirmStopSensing()
    XCTAssertEqual(try fixture.effects(), stopped)
  }

  private func makeNoticeBoundaryFixture() throws -> StopNoticeBoundaryFixture {
    let fixture = try StopNoticeBoundaryFixture()
    addTeardownBlock { @MainActor in
      fixture.runtime.onNextSubmit = nil
      _ = fixture.sensing.reset() // Cancels any unfinished demo task, including on timeout.
      fixture.defaults.removePersistentDomain(forName: fixture.defaultsName)
      try FileManager.default.removeItem(at: fixture.directory)
    }
    return fixture
  }

  private func prepareNoticeRecording(
    _ fixture: StopNoticeBoundaryFixture, withWindowEndpoints: Bool = true
  ) async throws -> UUID {
    let sample = EventSession.demoSample
    let event = EventSession(id: sample.id, name: sample.name, venue: sample.venue)
    let scenario = withWindowEndpoints ? DemoScenario.appReviewGolden.replacingEvent(event) : DemoScenario(
      identifier: "stopNoticeBeforeWindow", event: event,
      steps: DemoScenario.appReviewGolden.steps.filter { $0 != .advanceDemoWindow }
    )
    let settled = expectation(description: "Zero-delay STOP boundary setup settles")
    if withWindowEndpoints {
      fixture.sensing.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    } else {
      fixture.sensing.runDemoScenario(scenario, stepDelayNanos: 0, stopWhenPhaseReaches: .recording)
    }
    let waiter = Task { @MainActor in
      await fixture.sensing.waitForDemoScenarioPreviewToSettle()
      if !Task.isCancelled { settled.fulfill() }
    }
    defer { waiter.cancel() }
    await fulfillment(of: [settled], timeout: 2)
    fixture.app.scanPresented = true
    let proofID = try XCTUnwrap(fixture.sensing.currentProofID)
    XCTAssertNotNil(fixture.proofStore.proof(withId: proofID))
    return proofID
  }

  func testStopPresentationRequiresADurableMatchingRecordAndGivesAlertsPriority() {
    let attemptedID = UUID()
    let otherID = UUID()
    for signatureID in [nil, attemptedID, otherID] {
      XCTAssertEqual(AppCoordinator.stopPresentation(
        attemptedRecordID: attemptedID, signedRecordID: signatureID,
        storedRecordID: nil, hasExplainingAlert: false
      ), .noRecordSaved, "Nil or mismatched signing output cannot hide a missing durable Record")
      XCTAssertEqual(AppCoordinator.stopPresentation(
        attemptedRecordID: attemptedID, signedRecordID: signatureID,
        storedRecordID: otherID, hasExplainingAlert: false
      ), .noRecordSaved)
      XCTAssertEqual(AppCoordinator.stopPresentation(
        attemptedRecordID: attemptedID, signedRecordID: signatureID,
        storedRecordID: attemptedID, hasExplainingAlert: false
      ), signatureID == attemptedID ? .sealed : .dismiss)
      for storedID in [nil, attemptedID, otherID] {
        XCTAssertEqual(AppCoordinator.stopPresentation(
          attemptedRecordID: attemptedID, signedRecordID: signatureID,
          storedRecordID: storedID, hasExplainingAlert: true
        ), .dismiss, "An existing STOP failure alert is the only explanation")
      }
    }
    XCTAssertEqual(AppCoordinator.stopPresentation(
      attemptedRecordID: nil, signedRecordID: nil, storedRecordID: nil, hasExplainingAlert: false
    ), .dismiss, "Detecting without observations is normal cancellation")
  }

  func testLaterIndependentSessionGetsItsOwnOutcomeWithoutReusingConsumedConfirmation() async throws {
    let fixture = StopOutcomeUITestFixture(mode: .saveFailure)
    let app = makeCoordinator(sensingCoordinator: fixture.sensingCoordinator, proofStore: fixture.proofStore)
    await fixture.prepare()
    app.scanPresented = true
    app.requestScanClose()
    app.confirmStopSensing()
    let first = try XCTUnwrap(app.stopOutcome)
    app.dismissStopOutcome()
    await fixture.prepare()
    app.scanPresented = true
    let newProofID = try XCTUnwrap(fixture.proofID)
    app.confirmStopSensing()
    XCTAssertEqual(fixture.sensingCoordinator.currentProofID, newProofID)
    XCTAssertNil(app.stopOutcome, "An old confirmation cannot stop the next live session")
    app.requestScanClose()
    let nextSessionID = try XCTUnwrap(app.stopConfirmSnapshot?.event.sessionID)
    app.confirmStopSensing()
    let second = try XCTUnwrap(app.stopOutcome)
    XCTAssertNotEqual(second, first)
    XCTAssertEqual(second.sessionID, nextSessionID)
    XCTAssertNotEqual(second.sessionID, first.sessionID)
    let artifacts = try fixtureArtifacts(fixture)
    let writes = fixture.recordWriteCount
    app.confirmStopSensing()
    XCTAssertEqual(app.stopOutcome, second)
    XCTAssertEqual(fixture.recordWriteCount, writes)
    XCTAssertEqual(try fixtureArtifacts(fixture), artifacts)
  }

  func testDetectingConfirmationCannotStopDifferentSessionUsingTheSameEventCode() async throws {
    let fixture = StopOutcomeUITestFixture(mode: .detecting)
    let app = makeCoordinator(sensingCoordinator: fixture.sensingCoordinator, proofStore: fixture.proofStore)
    await fixture.prepare()
    app.scanPresented = true
    app.requestScanClose()
    let oldSessionID = try XCTUnwrap(app.stopConfirmSnapshot?.event.sessionID)
    await fixture.prepare()
    let livePhase = fixture.sensingCoordinator.phase
    let artifacts = try fixtureArtifacts(fixture)
    app.confirmStopSensing()
    XCTAssertEqual(fixture.sensingCoordinator.phase, livePhase)
    XCTAssertTrue(app.scanPresented)
    XCTAssertNil(app.stopConfirmSnapshot)
    XCTAssertNil(app.stopOutcome)
    XCTAssertEqual(try fixtureArtifacts(fixture), artifacts)
    app.requestScanClose()
    XCTAssertNotEqual(app.stopConfirmSnapshot?.event.sessionID, oldSessionID)
    app.confirmStopSensing()
    XCTAssertEqual(fixture.sensingCoordinator.phase, .idle)
    XCTAssertNil(app.stopOutcome)
  }

  func testMissingStoredRecordWithoutWindowEndpointsExplainsNoRecordAfterAttempt() async throws {
    let fixture = StopOutcomeUITestFixture(mode: .nilSignature)
    let app = makeCoordinator(sensingCoordinator: fixture.sensingCoordinator, proofStore: fixture.proofStore)
    let scenario = DemoScenario(
      identifier: "stopMissingRecordBeforeWindow", event: .demoSample,
      steps: DemoScenario.appReviewGolden.steps.filter { $0 != .advanceDemoWindow }
    )
    fixture.sensingCoordinator.runDemoScenario(scenario, stepDelayNanos: 0, stopWhenPhaseReaches: .recording)
    await fixture.sensingCoordinator.waitForDemoScenarioPreviewToSettle()
    let proofID = try XCTUnwrap(fixture.sensingCoordinator.currentProofID)
    XCTAssertNotNil(fixture.proofStore.proof(withId: proofID))
    app.scanPresented = true
    app.requestScanClose()
    fixture.proofStore.resetForUITesting() // Isolated test input: the durable parent disappears.
    app.confirmStopSensing()
    XCTAssertEqual(fixture.sensingCoordinator.phase, .idle)
    XCTAssertNil(fixture.sensingCoordinator.eventSigningKeyFailure)
    XCTAssertNil(fixture.sensingCoordinator.ownerKeyOperationFailure)
    XCTAssertNotNil(app.stopOutcome)
    XCTAssertNil(app.sealedSnapshot)
    XCTAssertNil(app.proofCollectedSnapshot)
    let artifacts = try fixtureArtifacts(fixture)
    let writes = fixture.recordWriteCount
    app.confirmStopSensing()
    XCTAssertEqual(fixture.recordWriteCount, writes)
    XCTAssertEqual(try fixtureArtifacts(fixture), artifacts)
  }

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
    XCTAssertNotNil(app.stopConfirmSnapshot, "A failed save must still offer STOP confirmation")
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
    let outcome = try XCTUnwrap(app.stopOutcome)
    let writes = fixture.recordWriteCount
    let artifacts = try fixtureArtifacts(fixture)
    app.confirmStopSensing()
    XCTAssertEqual(app.stopOutcome, outcome, "Repeated confirmation cannot replace the existing outcome")
    XCTAssertEqual(fixture.recordWriteCount, writes)
    XCTAssertEqual(try fixtureArtifacts(fixture), artifacts)
    XCTAssertEqual(fixture.signingCallCount, 0, "Missing endpoints must not manufacture signing inputs")
    XCTAssertEqual(try Data(contentsOf: aggregateURL), aggregateBytes)
    app.dismissStopOutcome()
    app.confirmStopSensing()
    XCTAssertNil(app.stopOutcome, "Acknowledgement cannot trigger a second outcome")
    XCTAssertEqual(try fixtureArtifacts(fixture), artifacts)
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
    let artifacts = try fixtureArtifacts(fixture)
    let writes = fixture.recordWriteCount
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
    XCTAssertNil(app.stopOutcome, "A durable unsigned Record needs no new outcome")
    XCTAssertEqual(fixture.recordWriteCount, writes)
    XCTAssertEqual(try fixtureArtifacts(fixture), artifacts)
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
    XCTAssertNil(app.stopOutcome)
    let artifacts = try fixtureArtifacts(fixture)
    let writes = fixture.recordWriteCount
    let signatures = fixture.signingCallCount
    app.confirmStopSensing()
    XCTAssertEqual(fixture.sensingCoordinator.eventSigningKeyFailure, .discardFailed)
    XCTAssertEqual(fixture.signingCallCount, signatures)
    XCTAssertEqual(fixture.recordWriteCount, writes)
    XCTAssertEqual(try fixtureArtifacts(fixture), artifacts, "Preserve signed and unsigned files byte for byte")
    fixture.sensingCoordinator.dismissEventSigningKeyFailure()
    app.confirmStopSensing()
    XCTAssertNil(fixture.sensingCoordinator.eventSigningKeyFailure)
    XCTAssertNil(app.stopOutcome)
    XCTAssertEqual(try fixtureArtifacts(fixture), artifacts)
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
    let artifacts = try fixtureArtifacts(fixture)
    let writes = fixture.recordWriteCount
    app.confirmStopSensing()

    XCTAssertEqual(fixture.sensingCoordinator.eventSigningKeyFailure, .unavailable)
    XCTAssertNil(fixture.sensingCoordinator.ownerKeyOperationFailure)
    XCTAssertNotNil(fixture.proofStore.proof(withId: proofID))
    XCTAssertNil(fixture.selfProofStore.record(forProofId: proofID))
    XCTAssertEqual(fixture.checkpointStore.checkpoint?.proofId, proofID)
    XCTAssertNil(app.sealedSnapshot)
    XCTAssertNil(app.proofCollectedSnapshot)
    XCTAssertNil(app.stopOutcome)
    fixture.sensingCoordinator.dismissEventSigningKeyFailure()
    XCTAssertNil(fixture.sensingCoordinator.eventSigningKeyFailure)
    app.confirmStopSensing()
    XCTAssertNil(fixture.sensingCoordinator.eventSigningKeyFailure)
    XCTAssertNil(app.stopOutcome)
    XCTAssertEqual(fixture.recordWriteCount, writes)
    XCTAssertEqual(try fixtureArtifacts(fixture), artifacts)
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
    XCTAssertTrue(coordinator.scanPresented, "Keep the no-Record outcome reachable until acknowledged")
    XCTAssertNil(coordinator.stopConfirmSnapshot)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
    XCTAssertNotNil(proofStore.lastPersistenceError, "stopping must preserve the save failure")
    XCTAssertNotNil(coordinator.stopOutcome)
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
    XCTAssertNil(coordinator.stopOutcome)
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
    XCTAssertNil(coordinator.stopOutcome, "Stale confirmation is not a failed attempt in the new session")
    _ = coordinator.sensingCoordinator.reset()
  }

  func testConfirmedStopEndsSensingWhenTheStoredProofDisappears() async {
    let coordinator = makeCoordinator()
    await reachRecording(coordinator)
    coordinator.requestScanClose()
    coordinator.proofStore.resetForUITesting()

    coordinator.confirmStopSensing()

    XCTAssertFalse(coordinator.scanPresented, "The existing persistence alert explains this missing Record")
    XCTAssertNil(coordinator.stopConfirmSnapshot)
    XCTAssertNil(coordinator.sealedSnapshot)
    XCTAssertNil(coordinator.proofCollectedSnapshot)
    XCTAssertNil(coordinator.sensingCoordinator.currentProofID)
    XCTAssertEqual(coordinator.sensingCoordinator.phase, .idle)
    XCTAssertEqual(coordinator.sensingCoordinator.eventSigningKeyFailure, .discardFailed)
    XCTAssertNil(coordinator.stopOutcome)
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
    XCTAssertNil(coordinator.stopOutcome, "The existing owner-key alert is the sole explanation")
    let signingCalls = crypto.calls
    coordinator.confirmStopSensing()
    XCTAssertEqual(crypto.calls, signingCalls, "Repeated confirmation cannot retry an owner-key operation")
    XCTAssertEqual(sensing.ownerKeyOperationFailure, .unavailable)
    XCTAssertNil(coordinator.stopOutcome)
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
    XCTAssertNil(app.stopOutcome)
  }

  private func fixtureArtifacts(_ fixture: StopOutcomeUITestFixture) throws -> [String: Data] {
    let urls = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
    return try Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
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

/// Existing native protocol only: the tests run the real STOP boundary and
/// publish an earlier notice synchronously from its existing submitPending call.
@MainActor
private final class StopNoticeRuntime: WindowReportSubmissionRuntimeProtocol {
  var onEventSigningKeyFailure: ((EventSigningKeyFailure) -> Void)?
  var onSigningKeyChange: ((String, EventSigningDiscardReason) -> Void)?
  var onNextSubmit: ((StopNoticeRuntime) -> Void)?
  private(set) var submits = 0
  private(set) var captures = 0
  private(set) var acknowledgedEvents: [String] = []

  func captureAndQueueWindow(
    id: UUID, eventCode: String, eventIdHex: String?, enin: Int, peerRpids: Set<String>,
    reporterRpid: String?, participantCommitment: Data?, eventSigningPublicKey: Data?
  ) { captures += 1 }

  func submitPending() {
    submits += 1
    let callback = onNextSubmit
    onNextSubmit = nil
    callback?(self)
  }

  func acknowledgeSigningKeyChanges(forEventCode eventCode: String) throws { acknowledgedEvents.append(eventCode) }
  func submissionState(forEventCode eventCode: String) -> ReportSubmissionState? { nil }
  func excludedWindowCount(forEventCode eventCode: String) -> Int { 0 }
}

@MainActor
private final class StopNoticeBoundaryFixture {
  struct Effects: Equatable {
    let files: [String: Data]
    let cryptoCalls: [DeterministicSensingCryptography.Call]
    let recordWrites: Int
    let submits: Int
    let captures: Int
    let acknowledgements: [String]
    let engineStops: Int
  }
  private final class WriteCounter { var count = 0 }
  let directory: URL
  let defaultsName: String
  let defaults: UserDefaults
  let runtime: StopNoticeRuntime
  let crypto: DeterministicSensingCryptography
  let engine: RecordingEventJoinControl
  let proofStore: ProofStore
  let selfProofStore: SelfProofStore
  let sensing: SensingCoordinator
  let app: AppCoordinator
  private let writes: WriteCounter

  init() throws {
    let defaultsName = "stop-notice-\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(defaultsName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
    let counter = WriteCounter()
    let runtime = StopNoticeRuntime()
    let crypto = DeterministicSensingCryptography()
    let engine = RecordingEventJoinControl()
    let proofStore = ProofStore(fileURL: directory.appendingPathComponent("proofs.json"), writeData: { data, url in
      counter.count += 1
      try data.write(to: url, options: .atomic)
    })
    let selfProofStore = SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json"))
    let sensing = SensingCoordinator(
      windowReportStore: WindowReportStore(fileURL: directory.appendingPathComponent("windows.json")),
      selfProofStore: selfProofStore,
      selfProofCheckpointStore: SelfProofCheckpointStore(fileURL: directory.appendingPathComponent("checkpoint.json")),
      bindingRecordStore: BindingRecordStore(fileURL: directory.appendingPathComponent("bindings.json")),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(fileURL: directory.appendingPathComponent("aggregate.json")),
      unsentWindowLedgerRuntime: nil, sensingCryptography: crypto, reportSubmissionRuntime: runtime,
      eventJoinControl: engine, participantRelayControl: RecordingParticipantRelayControl(), proofStore: proofStore
    )
    app = AppCoordinator(
      proofStore: proofStore, sensingCoordinator: sensing,
      reportSubmissionStore: ReportSubmissionStore(fileURL: directory.appendingPathComponent("reports.json")),
      reportProofLinkStore: ReportProofLinkStore(fileURL: directory.appendingPathComponent("links.json")),
      registryClient: nil, userDefaults: defaults
    )
    self.directory = directory
    self.defaultsName = defaultsName
    self.defaults = defaults
    self.runtime = runtime
    self.crypto = crypto
    self.engine = engine
    self.proofStore = proofStore
    self.selfProofStore = selfProofStore
    self.sensing = sensing
    self.writes = counter
  }

  func effects() throws -> Effects {
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    return Effects(
      files: try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) }),
      cryptoCalls: crypto.calls, recordWrites: writes.count, submits: runtime.submits, captures: runtime.captures,
      acknowledgements: runtime.acknowledgedEvents, engineStops: engine.stopAutomaticOperationCallCount
    )
  }
}
