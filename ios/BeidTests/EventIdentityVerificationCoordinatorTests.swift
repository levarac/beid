// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import Beid

@MainActor
private final class DeferredEventIdentityVerificationRequest: EventIdentityVerificationRequest {
  private(set) var cancelCount = 0

  func cancel() {
    cancelCount += 1
  }
}

@MainActor
private final class DeferredEventIdentityVerificationSource: EventIdentityVerificationSource {
  private(set) var eventIdHexes: [String] = []
  private(set) var requests: [DeferredEventIdentityVerificationRequest] = []
  private var completions: [
    (EventIdentityVerificationResolution) -> Void
  ] = []

  func resolve(
    eventIdHex: String,
    completion: @escaping (EventIdentityVerificationResolution) -> Void
  ) -> any EventIdentityVerificationRequest {
    eventIdHexes.append(eventIdHex)
    completions.append(completion)
    let request = DeferredEventIdentityVerificationRequest()
    requests.append(request)
    return request
  }

  func complete(
    request index: Int,
    with resolution: EventIdentityVerificationResolution
  ) {
    completions[index](resolution)
  }
}

@MainActor
final class EventIdentityVerificationCoordinatorTests: XCTestCase {
  private let canonicalEventIdHex = "0x\(String(repeating: "c", count: 64))"

  func testRealHintedSessionChecksThenUpdatesPhaseAndPendingBindingWithoutRenamingEvent() async {
    let source = DeferredEventIdentityVerificationSource()
    let coordinator = makeCoordinator(source: source)
    let code = "REAL-RAW-CODE"
    startRealSession(coordinator, code: code, canonicalEventIdHex: canonicalEventIdHex)

    detectDevices(coordinator, count: max(1, BeidConfig.eventConfirmThreshold))

    XCTAssertEqual(source.eventIdHexes, [canonicalEventIdHex])
    guard let checkingEvent = event(in: coordinator.phase) else {
      return XCTFail("expected a real event phase")
    }
    XCTAssertEqual(checkingEvent.identityVerification, .checking)
    XCTAssertEqual(checkingEvent.id, code)
    XCTAssertEqual(checkingEvent.name, code)

    guard case .recording(let recordingEvent, _) = coordinator.phase else {
      return XCTFail("expected recording after the confirmation threshold")
    }
    guard case .pendingConnect(let pendingBindingEvent) = coordinator.bindingState else {
      return XCTFail("expected pending binding state")
    }
    XCTAssertEqual(recordingEvent.identityVerification, .checking)
    XCTAssertEqual(pendingBindingEvent.identityVerification, .checking)

    source.complete(
      request: 0,
      with: EventIdentityVerificationResolution(
        isSuccess: true,
        context: NSObject(),
        errorCode: nil,
        errorMessage: nil
      )
    )
    await settleMainActor()

    guard let verifiedEvent = event(in: coordinator.phase) else {
      return XCTFail("expected the event phase to remain live")
    }
    XCTAssertEqual(verifiedEvent.identityVerification, .verified)
    XCTAssertEqual(verifiedEvent.name, code, "verification must never replace the raw event code")
    guard case .pendingConnect(let verifiedPendingEvent) = coordinator.bindingState else {
      return XCTFail("expected pending binding state after verification")
    }
    XCTAssertEqual(verifiedPendingEvent.identityVerification, .verified)
    XCTAssertEqual(verifiedPendingEvent.name, code)

    coordinator.simulateSignalLost()
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .verified)
    coordinator.resumeSensing()
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .verified)
    XCTAssertEqual(pendingEvent(in: coordinator.bindingState)?.identityVerification, .verified)
  }

  func testMissingCanonicalHintStaysNotCheckedAndDoesNotCallSource() {
    let source = DeferredEventIdentityVerificationSource()
    let coordinator = makeCoordinator(source: source)
    let code = "REAL-WITHOUT-HINT"
    XCTAssertTrue(coordinator.joinEvent(code))
    coordinator.startSensing(eventCode: code)

    detectDevices(coordinator, count: 1)

    XCTAssertEqual(source.eventIdHexes, [])
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .notChecked)
  }

  func testMissingSourceFailsUnavailableAfterARealHintIsPublished() {
    let coordinator = makeCoordinator(source: nil)
    let code = "REAL-WITHOUT-SOURCE"
    startRealSession(coordinator, code: code, canonicalEventIdHex: canonicalEventIdHex)

    detectDevices(coordinator, count: 1)

    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .unavailable)
  }

  func testRetryIsManualOnlyForUnavailableAndNotFound() async {
    let source = DeferredEventIdentityVerificationSource()
    let coordinator = makeCoordinator(source: source)
    startRealSession(coordinator, code: "RETRY-CODE", canonicalEventIdHex: canonicalEventIdHex)
    detectDevices(coordinator, count: 1)

    source.complete(
      request: 0,
      with: EventIdentityVerificationResolution(
        isSuccess: false,
        context: nil,
        errorCode: "definition_not_found",
        errorMessage: "no definition"
      )
    )
    await settleMainActor()
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .notFound)

    coordinator.retryEventIdentityVerification()
    XCTAssertEqual(source.eventIdHexes.count, 2)
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .checking)
    XCTAssertEqual(
      source.requests[0].cancelCount,
      0,
      "a completed request is already released; retry must not cancel it again"
    )

    source.complete(
      request: 1,
      with: EventIdentityVerificationResolution(
        isSuccess: false,
        context: nil,
        errorCode: "definition_http_error",
        errorMessage: "network failure"
      )
    )
    await settleMainActor()
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .unavailable)

    coordinator.retryEventIdentityVerification()
    XCTAssertEqual(source.eventIdHexes.count, 3)
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .checking)

    source.complete(
      request: 2,
      with: EventIdentityVerificationResolution(
        isSuccess: true,
        context: NSObject(),
        errorCode: nil,
        errorMessage: nil
      )
    )
    await settleMainActor()
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .verified)

    coordinator.retryEventIdentityVerification()
    XCTAssertEqual(source.eventIdHexes.count, 3, "verified has no retry action")
  }

  func testStaleCompletionAfterResetCannotTouchLaterSameCodeSession() async {
    let source = DeferredEventIdentityVerificationSource()
    let coordinator = makeCoordinator(source: source)
    let code = "SAME-RAW-CODE"
    startRealSession(coordinator, code: code, canonicalEventIdHex: canonicalEventIdHex)
    detectDevices(coordinator, count: 1)

    coordinator.reset()
    startRealSession(coordinator, code: code, canonicalEventIdHex: canonicalEventIdHex)
    detectDevices(coordinator, count: 1)
    XCTAssertEqual(source.eventIdHexes.count, 2)
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .checking)

    source.complete(
      request: 0,
      with: EventIdentityVerificationResolution(
        isSuccess: true,
        context: NSObject(),
        errorCode: nil,
        errorMessage: nil
      )
    )
    await settleMainActor()
    XCTAssertEqual(
      event(in: coordinator.phase)?.identityVerification,
      .checking,
      "the old same-code session must be rejected"
    )

    source.complete(
      request: 1,
      with: EventIdentityVerificationResolution(
        isSuccess: true,
        context: NSObject(),
        errorCode: nil,
        errorMessage: nil
      )
    )
    await settleMainActor()
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .verified)
  }

  func testStaleCompletionAfterLeaveCannotTouchNewSession() async {
    let source = DeferredEventIdentityVerificationSource()
    let coordinator = makeCoordinator(source: source)
    let code = "LEAVE-AND-REJOIN"
    startRealSession(coordinator, code: code, canonicalEventIdHex: canonicalEventIdHex)
    detectDevices(coordinator, count: 1)

    coordinator.leaveEvent()
    startRealSession(coordinator, code: code, canonicalEventIdHex: canonicalEventIdHex)
    detectDevices(coordinator, count: 1)

    source.complete(
      request: 0,
      with: EventIdentityVerificationResolution(
        isSuccess: true,
        context: NSObject(),
        errorCode: nil,
        errorMessage: nil
      )
    )
    await settleMainActor()
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .checking)
    XCTAssertEqual(source.requests[0].cancelCount, 1)
  }

  func testBackgroundCheckpointPreservesRequestAndAllowsCompletion() async {
    let source = DeferredEventIdentityVerificationSource()
    let coordinator = makeCoordinator(source: source)
    startRealSession(coordinator, code: "BACKGROUND-CODE", canonicalEventIdHex: canonicalEventIdHex)
    detectDevices(coordinator, count: max(1, BeidConfig.eventConfirmThreshold))

    coordinator.checkpointOpenWindowForBackgrounding()

    XCTAssertEqual(source.requests[0].cancelCount, 0)
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .checking)
    source.complete(
      request: 0,
      with: EventIdentityVerificationResolution(
        isSuccess: true,
        context: NSObject(),
        errorCode: nil,
        errorMessage: nil
      )
    )
    await settleMainActor()
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .verified)
  }

  func testDemoAlwaysSuppressesVerificationAndNeverCallsInjectedSource() async {
    let source = DeferredEventIdentityVerificationSource()
    let coordinator = makeCoordinator(source: source)
    let demoEvent = EventSession(
      id: "DEMO-CODE",
      name: "Existing Demo Display Name",
      venue: "Demo venue",
      canonicalEventIdHex: canonicalEventIdHex,
      identityVerification: .verified
    )
    coordinator.useDemoEventMode = true

    coordinator.runDemoSequence(demoEvent: demoEvent, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertEqual(source.eventIdHexes, [])
    XCTAssertEqual(event(in: coordinator.phase)?.identityVerification, .notChecked)
    XCTAssertEqual(pendingEvent(in: coordinator.bindingState)?.identityVerification, .notChecked)
  }

  private func makeCoordinator(
    source: (any EventIdentityVerificationSource)?
  ) -> SensingCoordinator {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("event-identity-verification-test-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      preconditionFailure("Unable to create event identity verification test directory: \(error)")
    }
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }
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
      sensingCryptography: DeterministicSensingCryptography(),
      eventIdentityVerificationSource: source
    )
    coordinator.useDemoEventMode = false
    return coordinator
  }

  private func startRealSession(
    _ coordinator: SensingCoordinator,
    code: String,
    canonicalEventIdHex: String
  ) {
    XCTAssertTrue(coordinator.joinEvent(code, canonicalEventIdHex: canonicalEventIdHex))
    coordinator.startSensing(eventCode: code, eventIdHex: canonicalEventIdHex)
  }

  private func detectDevices(_ coordinator: SensingCoordinator, count: Int) {
    for index in 0..<count {
      coordinator.handleDetection(
        enin: 1,
        rpid: "identity-rpid-\(index)",
        detectedDisplayId: "identity-display-\(index)",
        reporterRpid: "identity-reporter"
      )
    }
  }

  private func event(in phase: ScanPhase) -> EventSession? {
    switch phase {
    case .eventFound(let event), .recording(let event, _), .signalLost(let event, _):
      return event
    case .idle, .sensing:
      return nil
    }
  }

  private func pendingEvent(in bindingState: EventBindingState) -> EventSession? {
    guard case .pendingConnect(let event) = bindingState else { return nil }
    return event
  }

  private func settleMainActor() async {
    await Task.yield()
    await Task.yield()
  }
}
