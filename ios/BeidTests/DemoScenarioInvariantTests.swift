#if DEBUG
// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import Beid

@MainActor
private final class DemoScenarioLedgerRuntimeSpy: UnsentWindowLedgerRuntimeProtocol {
  private(set) var openWindowCallCount = 0
  private(set) var closeWindowCallCount = 0

  func openWindow(windowId _: String) throws {
    openWindowCallCount += 1
  }

  func closeWindow(windowId _: String, persistedObservationReference _: String) throws {
    closeWindowCallCount += 1
  }

  func reconcileAfterRelaunch(
    persistedObservations _: [(windowId: String, reference: String)]
  ) throws {}
}

@MainActor
private final class DemoScenarioSubmissionRuntimeSpy: WindowReportSubmissionRuntimeProtocol {
  private(set) var captureAndQueueWindowCallCount = 0
  private(set) var submitPendingCallCount = 0

  func captureAndQueueWindow(
    id _: UUID,
    eventCode _: String,
    eventIdHex _: String?,
    enin _: Int,
    peerRpids _: Set<String>,
    reporterRpid _: String?,
    participantCommitment _: Data?
  ) {
    captureAndQueueWindowCallCount += 1
  }

  func submitPending() {
    submitPendingCallCount += 1
  }

  func submissionState(forEventCode _: String) -> ReportSubmissionState? { nil }
  func excludedWindowCount(forEventCode _: String) -> Int { 0 }
}

@MainActor
final class DemoScenarioInvariantTests: XCTestCase {
  func testScenarioLookupAndLaunchArgumentFallbacks() {
    XCTAssertEqual(DemoScenario.named("crowdSurge")?.identifier, "crowdSurge")
    XCTAssertNil(DemoScenario.named("does-not-exist"))
    XCTAssertEqual(BeidConfig.demoScenario(arguments: []).identifier, "appReviewGolden")
    XCTAssertEqual(
      BeidConfig.demoScenario(arguments: ["-beid-demo-scenario"]).identifier,
      "appReviewGolden"
    )
    XCTAssertEqual(
      BeidConfig.demoScenario(arguments: ["-beid-demo-scenario", "does-not-exist"]).identifier,
      "appReviewGolden"
    )
    XCTAssertEqual(
      BeidConfig.demoScenario(arguments: ["-beid-demo-scenario", "longDisplayNames"]).identifier,
      "longDisplayNames"
    )
    XCTAssertEqual(
      BeidConfig.demoScenario(arguments: ["-beid-demo-scenario", "zeroPeersForever"]).identifier,
      "zeroPeersForever"
    )
    XCTAssertEqual(
      BeidConfig.demoScenario(arguments: ["-beid-demo-scenario", "unidentifiedHeavy"]).identifier,
      "unidentifiedHeavy"
    )
  }

  func testIosIdentifiersMatchTheSharedScenarioCatalogAndKeepTheFallbackFirst() throws {
    let fixtureURL = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "demo-scenarios", withExtension: "txt")
    )
    let catalog = try String(contentsOf: fixtureURL, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }

    XCTAssertEqual(
      Set(DemoScenario.allScenarios.map(\.identifier)),
      Set(catalog),
      "DemoScenario must match the shared catalog; update both intentionally"
    )
    XCTAssertEqual(
      DemoScenario.allScenarios.first?.identifier,
      "appReviewGolden",
      "the fallback scenario must stay first; BeidConfig.demoScenario returns it for unknown input"
    )
  }

  func testAppReviewGoldenPreservesExactPrimitiveSequence() {
    let threshold = BeidConfig.eventConfirmThreshold
    var expected: [DemoScenario.Step] = [
      .pause,
      .observeOneDemoDevice(displayId: "demo-device-1", rpid: "demo-device-1", enin: 0),
      .applyPhaseDecision,
      .advanceDemoWindow,
      .pause,
    ]
    if threshold > 1 {
      for device in 2...threshold {
        expected.append(
          .observeOneDemoDevice(
            displayId: "demo-device-\(device)",
            rpid: "demo-device-\(device)",
            enin: 1
          )
        )
        expected.append(.applyPhaseDecision)
      }
    }
    expected.append(.advanceDemoWindow)
    for offset in 0..<2 {
      let device = max(1, threshold) + 1 + offset
      expected.append(.pause)
      expected.append(
        .observeOneDemoDevice(
          displayId: "demo-device-\(device)",
          rpid: "demo-device-\(device)",
          enin: offset + 2
        )
      )
      expected.append(.applyPhaseDecision)
      expected.append(.advanceDemoWindow)
    }

    XCTAssertEqual(DemoScenario.appReviewGolden.steps, expected)
  }

  func testProductionScanFlowContentRouterCoversEveryPhase() {
    let event = EventSession(id: "ROUTER-EVENT", name: "Router Event", venue: nil)

    XCTAssertEqual(ScanFlowContent.route(for: .idle), .sensing)
    XCTAssertEqual(ScanFlowContent.route(for: .sensing), .sensing)
    XCTAssertEqual(ScanFlowContent.route(for: .eventFound(event)), .eventFound)
    XCTAssertEqual(
      ScanFlowContent.route(for: .recording(event: event, peersVerified: 3)),
      .recording
    )
    XCTAssertEqual(
      ScanFlowContent.route(for: .signalLost(event: event, peersVerified: 3)),
      .signalLost
    )
  }

  func testStartSensingUsesSelectedScenarioAndKeepsSubmissionBoundaryEmpty() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("demo-scenario-start-path-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let reportStore = WindowReportStore(fileURL: directory.appendingPathComponent("window-reports.json"))
    let ledger = DemoScenarioLedgerRuntimeSpy()
    let submission = DemoScenarioSubmissionRuntimeSpy()
    let coordinator = SensingCoordinator(
      windowReportStore: reportStore,
      selfProofStore: SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")),
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(fileURL: directory.appendingPathComponent("binding-records.json")),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
      ),
      unsentWindowLedgerRuntime: ledger,
      sensingCryptography: DeterministicSensingCryptography(),
      reportSubmissionRuntime: submission
    )
    coordinator.useDemoEventMode = true

    coordinator.startSensing(demoScenario: .crowdSurge)
    await coordinator.waitForDemoSequenceToFinish()

    guard case .recording(let event, let peersVerified) = coordinator.phase else {
      XCTFail("expected crowdSurge to reach recording, got \(coordinator.phase)")
      return
    }
    XCTAssertEqual(event, DemoScenario.crowdSurge.event)
    XCTAssertEqual(peersVerified, 40)
    XCTAssertEqual(coordinator.devicesVerified, 40)
    XCTAssertEqual(submission.submitPendingCallCount, 1, "startSensing may flush existing real work once")
    XCTAssertEqual(submission.captureAndQueueWindowCallCount, 0)
    XCTAssertTrue(reportStore.reports.isEmpty)
    XCTAssertEqual(ledger.openWindowCallCount, 0)
    XCTAssertEqual(ledger.closeWindowCallCount, 0)
    XCTAssertNil(coordinator.currentWindowIdForTesting)
  }

  func testEveryScenarioKeepsAttestationStateEmptyAtEveryCheckpoint() async {
    for scenario in DemoScenario.allScenarios {
      let fixture = makeFixture()
      var checkpointCount = 0
      fixture.coordinator.onDemoInterpreterCheckpointForTesting = { checkpoint in
        guard case .step = checkpoint else { return }
        checkpointCount += 1
        XCTAssertNil(fixture.coordinator.currentWindowIdForTesting, "\(scenario.identifier): \(checkpoint)")
        XCTAssertTrue(fixture.reportStore.reports.isEmpty, "\(scenario.identifier): \(checkpoint)")
        XCTAssertEqual(fixture.ledger.openWindowCallCount, 0, "\(scenario.identifier): \(checkpoint)")
        XCTAssertEqual(fixture.ledger.closeWindowCallCount, 0, "\(scenario.identifier): \(checkpoint)")
        XCTAssertEqual(
          fixture.submission.captureAndQueueWindowCallCount,
          0,
          "\(scenario.identifier): \(checkpoint)"
        )
      }

      fixture.coordinator.runDemoScenario(scenario, stepDelayNanos: 0)
      await fixture.coordinator.waitForDemoSequenceToFinish()
      while fixture.coordinator.hasParkedDemoScenarioForTesting {
        fixture.coordinator.resumeSensing()
        await fixture.coordinator.waitForDemoSequenceToFinish()
      }

      XCTAssertGreaterThan(checkpointCount, 0, scenario.identifier)
      XCTAssertNil(fixture.coordinator.currentWindowIdForTesting, scenario.identifier)
      XCTAssertTrue(fixture.reportStore.reports.isEmpty, scenario.identifier)
      XCTAssertEqual(fixture.ledger.openWindowCallCount, 0, scenario.identifier)
      XCTAssertEqual(fixture.ledger.closeWindowCallCount, 0, scenario.identifier)
      XCTAssertEqual(fixture.submission.captureAndQueueWindowCallCount, 0, scenario.identifier)
    }
  }

  func testSignalLostResumesFromTheNextCheckpointExactlyOnce() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    let scenario = DemoScenario.signalLostMidway
    var executedSteps: [DemoScenario.Step] = []
    var settledRenderTurns: [Int] = []
    var suspendedCursor: Int?
    var resumedCursor: Int?
    coordinator.onDemoInterpreterCheckpointForTesting = { checkpoint in
      switch checkpoint {
      case .step(_, let step):
        executedSteps.append(step)
      case .renderTurnSettled(let index):
        settledRenderTurns.append(index)
      case .suspended(let nextCursor):
        suspendedCursor = nextCursor
      case .resumed(let cursor):
        resumedCursor = cursor
      case .completed:
        break
      }
    }

    coordinator.runDemoScenario(scenario, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    guard case .signalLost = coordinator.phase else {
      XCTFail("expected signalLost suspension, got \(coordinator.phase)")
      return
    }
    let expectedCursor = try! XCTUnwrap(scenario.steps.firstIndex(of: .simulateSignalLost)) + 1
    XCTAssertEqual(suspendedCursor, expectedCursor)
    XCTAssertEqual(coordinator.parkedDemoScenarioCursorForTesting, expectedCursor)
    XCTAssertEqual(
      settledRenderTurns,
      Array(0...expectedCursor - 1),
      "every pre-suspension step must yield a settled render turn"
    )

    coordinator.resumeSensing()
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertEqual(resumedCursor, expectedCursor)
    XCTAssertEqual(executedSteps, scenario.steps, "no step may be skipped or executed twice")
    XCTAssertEqual(
      settledRenderTurns,
      Array(0..<scenario.steps.count),
      "resume must settle each remaining render turn exactly once"
    )
    XCTAssertFalse(coordinator.hasParkedDemoScenarioForTesting)
  }

  func testPreviewSettlementHasACompletedRenderTurnBeforeCompletion() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    var checkpoints: [DemoInterpreterCheckpoint] = []
    coordinator.onDemoInterpreterCheckpointForTesting = { checkpoints.append($0) }

    coordinator.runDemoScenario(.appReviewGolden, stepDelayNanos: 0)
    await coordinator.waitForDemoScenarioPreviewToSettle()

    let settledIndices = checkpoints.compactMap { checkpoint -> Int? in
      guard case .renderTurnSettled(let index) = checkpoint else { return nil }
      return index
    }
    XCTAssertEqual(
      settledIndices,
      Array(0..<DemoScenario.appReviewGolden.steps.count),
      "the preview must await one settled render turn per interpreter step"
    )
    guard case .completed? = checkpoints.last else {
      XCTFail("preview settlement must leave the interpreter completed after the final render turn")
      return
    }
  }

  func testAppReviewGoldenSelfProofPreservesItsFourWindowRange() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)

    coordinator.runDemoScenario(.appReviewGolden, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let record = coordinator.stopSensing()
    XCTAssertEqual(record?.eninStart, 1)
    XCTAssertEqual(record?.eninEnd, 4)
  }

  // MARK: - beid#399 preview seam: stop where the reducer says

  /// The seam's whole point: the caller names a SCREEN, and the reducer
  /// decides which step reaches it.
  ///
  /// The assertion is deliberately on the phase and not on a cursor value. If
  /// this test pinned "stops after N steps" it would re-encode the reducer's
  /// confirm rule in the test, and it would keep passing while previews went
  /// stale after any change to that rule — the exact failure the step-index
  /// version of this seam was rejected for.
  func testScenarioStopsAtTheRequestedScreenRatherThanAStepIndex() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)

    coordinator.runDemoScenario(.appReviewGolden, stepDelayNanos: 0, stopWhenPhaseReaches: .eventFound)
    await coordinator.waitForDemoScenarioPreviewToSettle()

    XCTAssertTrue(coordinator.demoScenarioReachedRequestedRoute)
    XCTAssertEqual(
      ScanFlowContent.route(for: coordinator.phase),
      .eventFound,
      "the interpreter must stop while the app would still be rendering Event Found"
    )
  }

  /// Stopping early must actually stop early. Without this, a seam that ran to
  /// the end and merely reported the requested screen would satisfy the test
  /// above whenever the terminal screen happened to match.
  func testStoppingAtAnEarlyScreenLeavesTheLaterScreenUnreached() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)

    coordinator.runDemoScenario(.crowdSurge, stepDelayNanos: 0, stopWhenPhaseReaches: .eventFound)
    await coordinator.waitForDemoScenarioPreviewToSettle()

    XCTAssertEqual(ScanFlowContent.route(for: coordinator.phase), .eventFound)
    XCTAssertLessThan(
      coordinator.devicesVerified,
      40,
      "crowdSurge observes 40 devices by its end; stopping at Event Found must leave most unobserved"
    )
  }

  /// What the apparatus CANNOT express, pinned so it cannot be mistaken for
  /// something it can.
  ///
  /// `crowdSurge` never reaches Signal Lost — no step of it ever asks for that
  /// phase. A preview that quietly rendered the terminal Recording screen
  /// under a "Signal Lost" label would be a fixture lying about what it shows,
  /// which is worse than showing nothing. The seam reports the miss instead,
  /// and this test is what stops a later change from making the miss silent.
  func testAnUnreachableScreenIsReportedRatherThanSilentlySubstituted() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)

    coordinator.runDemoScenario(.crowdSurge, stepDelayNanos: 0, stopWhenPhaseReaches: .signalLost)
    await coordinator.waitForDemoScenarioPreviewToSettle()

    XCTAssertFalse(
      coordinator.demoScenarioReachedRequestedRoute,
      "crowdSurge cannot reach Signal Lost, and the seam must say so rather than stop somewhere else"
    )
    XCTAssertNotEqual(ScanFlowContent.route(for: coordinator.phase), .signalLost)
  }

  /// The default overload must be untouched by the seam: no stop route, no
  /// early exit, and the flag stays false so nothing reads a stale true.
  func testRunningWithoutAStopRouteIsUnchanged() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)

    coordinator.runDemoScenario(.appReviewGolden, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertFalse(coordinator.demoScenarioReachedRequestedRoute)
    XCTAssertEqual(ScanFlowContent.route(for: coordinator.phase), .recording)
  }

  /// The screen no other scenario reaches: scanning, and nothing arriving.
  ///
  /// Asserting the phase alone would pass on a scenario that observed devices
  /// and simply had not confirmed yet, which is a different screen with the
  /// same name. The two counters are what separate "nothing is arriving" from
  /// "something is arriving and not identifying" — the whole distinction
  /// `unidentifiedHeavy` below exists to sit opposite.
  func testZeroPeersForeverStaysInSensingWithNothingObservedAtAll() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    let scenario = DemoScenario.zeroPeersForever
    var executedSteps: [DemoScenario.Step] = []
    coordinator.onDemoInterpreterCheckpointForTesting = { checkpoint in
      if case .step(_, let step) = checkpoint {
        executedSteps.append(step)
      }
    }

    coordinator.runDemoScenario(scenario, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    // The end state alone cannot tell "held Sensing across every render turn"
    // from "never ran": an EMPTY step list also finishes in `.sensing` with
    // both counters at zero. This scenario's whole content is its step list,
    // so without pinning execution the assertions below would pass for a
    // scenario that does nothing at all — a fixture unable to express its own
    // failure.
    XCTAssertFalse(scenario.steps.isEmpty, "a scenario with no steps would satisfy every assertion below")
    XCTAssertEqual(executedSteps, scenario.steps, "every step must actually reach the interpreter")

    guard case .sensing = coordinator.phase else {
      XCTFail("expected zeroPeersForever to stay in sensing, got \(coordinator.phase)")
      return
    }
    XCTAssertEqual(coordinator.devicesVerified, 0)
    XCTAssertEqual(coordinator.unidentifiedRpidCount, 0, "nothing was observed, identified or not")
    XCTAssertFalse(coordinator.hasParkedDemoScenarioForTesting)
  }

  /// Radio arriving, none of it identifying — the pair `RecordingView`'s
  /// diagnostic line (beid#218) exists to tell apart from silence.
  ///
  /// `devicesVerified == 0` is the assertion doing the real work. Checking
  /// only that the phase reached `.recording` would pass for the wrong
  /// reason if the scenario ever started resolving display ids, because then
  /// it would confirm through the distinct-device arm and render an ordinary
  /// healthy Recording screen under this scenario's name. That is precisely
  /// the failure Android's `unidentifiedHeavy` snapshot ships today.
  func testUnidentifiedHeavyRecordsWithEveryObservationUnidentified() async {
    await assertUnidentifiedHeavyConfirmsWithoutIdentifyingAnything()
  }

  /// The same scenario at two other thresholds, because its step count is
  /// derived from `BeidConfig.eventConfirmThreshold` rather than written out.
  /// Without this, a step list that happened to be long enough at today's
  /// default of 3 would look correct and stop confirming the moment the
  /// threshold moved — and the launch argument `-beid-threshold-override`
  /// moves it in exactly the demo builds this scenario is for.
  func testUnidentifiedHeavyStaysCorrectWhenTheConfirmThresholdMoves() async {
    for threshold in [1, 7] {
      BeidConfig.eventConfirmThresholdOverrideForTesting = threshold
      await assertUnidentifiedHeavyConfirmsWithoutIdentifyingAnything(
        message: "threshold \(threshold)"
      )
      BeidConfig.eventConfirmThresholdOverrideForTesting = nil
    }
  }

  private func assertUnidentifiedHeavyConfirmsWithoutIdentifyingAnything(
    message: String = "default threshold"
  ) async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    let threshold = BeidConfig.eventConfirmThreshold

    coordinator.runDemoScenario(.unidentifiedHeavy, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    guard case .recording(_, let peersVerified) = coordinator.phase else {
      XCTFail("\(message): expected unidentifiedHeavy to reach recording, got \(coordinator.phase)")
      return
    }
    XCTAssertEqual(peersVerified, 0, "\(message): the recording screen must claim no identified peers")
    XCTAssertEqual(coordinator.devicesVerified, 0, "\(message): nothing resolved a display id")
    XCTAssertGreaterThan(
      coordinator.unidentifiedRpidCount,
      threshold,
      "\(message): the unidentified residue must exceed the threshold, or the screen reads like an ordinary confirm"
    )
  }

  private func makeFixture() -> (
    coordinator: SensingCoordinator,
    reportStore: WindowReportStore,
    ledger: DemoScenarioLedgerRuntimeSpy,
    submission: DemoScenarioSubmissionRuntimeSpy
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("demo-scenario-invariant-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let reportStore = WindowReportStore(fileURL: directory.appendingPathComponent("window-reports.json"))
    let ledger = DemoScenarioLedgerRuntimeSpy()
    let submission = DemoScenarioSubmissionRuntimeSpy()
    let coordinator = SensingCoordinator(
      windowReportStore: reportStore,
      selfProofStore: SelfProofStore(fileURL: directory.appendingPathComponent("self-proofs.json")),
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(fileURL: directory.appendingPathComponent("binding-records.json")),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
      ),
      unsentWindowLedgerRuntime: ledger,
      sensingCryptography: DeterministicSensingCryptography(),
      reportSubmissionRuntime: submission
    )
    return (coordinator, reportStore, ledger, submission)
  }
}
#endif
