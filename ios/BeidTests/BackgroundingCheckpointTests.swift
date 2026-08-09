// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// `SensingCoordinator.checkpointOpenWindowForBackgrounding()`
/// (`docs/specs/session-end-finalization.md` §3.4/§3.6, sub-slice 2, §8.2).
/// Drives the real (non-demo) detection path via
/// `handleDetection(enin:rpid:detectedDisplayId:)`, same rationale as
/// `WindowReportFinalizationTests` (sub-slice 1's own test file): demo mode
/// never produces `WindowReport`s, so a demo-driven test could not observe
/// this method's effect on `WindowReportStore`.
@MainActor
final class BackgroundingCheckpointTests: XCTestCase {
  private func makeCoordinator() -> (SensingCoordinator, WindowReportStore) {
    let directory = makeTemporaryDirectory()
    let store = WindowReportStore(
      fileURL: directory.appendingPathComponent("window-reports.json")
    )
    let coordinator = SensingCoordinator(
      windowReportStore: store,
      selfProofStore: SelfProofStore(
        fileURL: directory.appendingPathComponent("self-proofs.json")
      ),
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(
        fileURL: directory.appendingPathComponent("binding-records.json")
      ),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false
    return (coordinator, store)
  }

  /// Same as `makeCoordinator()`, but also isolates `SelfProofStore` behind
  /// its own temp file so a test can assert on the store's contents
  /// directly (rather than only on `stopSensing()`/`reset()`'s return
  /// value) without racing the shared on-device default file other tests
  /// in this process may also touch.
  private func makeCoordinatorWithIsolatedSelfProofStore()
    -> (SensingCoordinator, WindowReportStore, SelfProofStore)
  {
    let directory = makeTemporaryDirectory()
    let windowReportStore = WindowReportStore(
      fileURL: directory.appendingPathComponent("window-reports.json")
    )
    let selfProofStore = SelfProofStore(
      fileURL: directory.appendingPathComponent("self-proofs.json")
    )
    let coordinator = SensingCoordinator(
      windowReportStore: windowReportStore,
      selfProofStore: selfProofStore,
      selfProofCheckpointStore: SelfProofCheckpointStore(
        fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
      ),
      bindingRecordStore: BindingRecordStore(
        fileURL: directory.appendingPathComponent("binding-records.json")
      ),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false
    return (coordinator, windowReportStore, selfProofStore)
  }

  private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("background-checkpoint-test-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      preconditionFailure("Unable to create test directory: \(error)")
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  // MARK: - Basic checkpoint behavior (§3.4)

  func testCheckpointClosesTheOpenWindowButLeavesPhaseAndBindingStateUnchanged() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-CHECKPOINT-BASIC")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }

    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording phase before checkpoint, got \(coordinator.phase)")
      return
    }
    let phaseBeforeCheckpoint = coordinator.phase
    let bindingStateBeforeCheckpoint = coordinator.bindingState

    coordinator.checkpointOpenWindowForBackgrounding()

    XCTAssertEqual(store.reports.count, 1, "the open window must be closed and reported by the checkpoint")
    XCTAssertEqual(store.reports.first?.enin, 1)
    XCTAssertEqual(store.reports.first?.peerCount, threshold)
    XCTAssertEqual(
      coordinator.phase, phaseBeforeCheckpoint,
      "a checkpoint is not a session-end — phase must be untouched (§3.4)"
    )
    XCTAssertEqual(
      coordinator.bindingState, bindingStateBeforeCheckpoint,
      "a checkpoint is not a session-end — bindingState must be untouched (§3.4)"
    )
  }

  /// `aggregationRuntime`/`activeProofId` are private, so this asserts their
  /// preservation indirectly: `aggregationRuntime` still holding already-seen
  /// peers is provable because re-observing one after the checkpoint must NOT
  /// be treated as a new distinct peer (no `onPeersVerifiedChanged` firing, no
  /// phase change); `activeProofId` still being set is provable because the
  /// eventual self-proof at real session end still carries the same
  /// `proofId` the original `Proof` was created with.
  func testCheckpointPreservesTheDeviceCountAccumulatorAndActiveProofIdAcrossTheCheckpoint() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-CHECKPOINT-IDENTITY")

    var collectedProofId: UUID?
    coordinator.onProofCollected = { collectedProofId = $0.id }
    var peersVerifiedChanges: [Int] = []
    coordinator.onPeersVerifiedChanged = { _, count in peersVerifiedChanges.append(count) }

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording phase before checkpoint, got \(coordinator.phase)")
      return
    }
    XCTAssertNotNil(collectedProofId)

    coordinator.checkpointOpenWindowForBackgrounding()
    let phaseAfterCheckpoint = coordinator.phase

    // Re-observing an already-seen peer, in a new window (enin=2, since the
    // checkpoint nil'd currentWindowEnin) — if aggregationRuntime had been
    // reset by the checkpoint, this would be (incorrectly) treated as a
    // brand-new distinct peer, bumping peersVerified and firing
    // onPeersVerifiedChanged.
    coordinator.handleDetection(
      enin: 2,
      rpid: "peer-0",
      detectedDisplayId: DetectionFixture.displayId(device: 0)
    )

    XCTAssertTrue(
      peersVerifiedChanges.isEmpty,
      "re-observing an already-seen device after a checkpoint must not look like a new distinct device — aggregationRuntime must survive the checkpoint"
    )
    XCTAssertEqual(
      coordinator.phase, phaseAfterCheckpoint,
      "peersVerified must not change from re-observing an already-seen peer"
    )

    let selfProof = coordinator.reset()
    XCTAssertEqual(store.reports.count, 2, "the checkpoint's window (1) plus the final window (2) opened by the new peer")
    XCTAssertEqual(
      selfProof?.proofId, collectedProofId,
      "the self-proof produced at real session end must still carry the original Proof's id — activeProofId must survive the checkpoint"
    )
  }

  func testCheckpointAloneProducesNoSelfProof() {
    let (coordinator, _, selfProofStore) = makeCoordinatorWithIsolatedSelfProofStore()
    coordinator.startSensing(eventCode: "TEST-CHECKPOINT-NO-SELF-PROOF")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording phase before checkpoint, got \(coordinator.phase)")
      return
    }

    coordinator.checkpointOpenWindowForBackgrounding()

    XCTAssertTrue(
      selfProofStore.records.isEmpty,
      "a backgrounding checkpoint must never produce a self-proof (§7.1 Option A was rejected; this is checkpoint-the-window only)"
    )
  }

  // MARK: - Double-finalization scenario (a): checkpoint then explicit stop

  func testCheckpointThenStopDoesNotDoubleCloseWhenNoNewWindowOpenedAfterTheCheckpoint() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-CHECKPOINT-THEN-STOP-NO-NEW-WINDOW")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }

    coordinator.checkpointOpenWindowForBackgrounding()
    XCTAssertEqual(store.reports.count, 1, "checkpoint closes the one open window")

    // No further detections — sensing is still "running" in the background
    // per the app's declared BLE background modes, but nothing new was
    // observed before the user explicitly stops.
    coordinator.stopSensing()

    XCTAssertEqual(
      store.reports.count, 1,
      "stopSensing() after a checkpoint with nothing new observed must not re-close the same window a second time (§3.6)"
    )
  }

  /// Regression for a bug found while tracing this exact scenario: before
  /// the `lastWindowEnin` fix, `finalizeSelfProofIfNeeded()` read
  /// `currentWindowEnin` for `eninEnd` — which the checkpoint nils — so a
  /// stop with nothing new observed after a checkpoint would silently
  /// return `nil` (no self-proof at all) for what is otherwise a complete,
  /// valid session. Would fail without that fix.
  func testCheckpointThenStopWithNoNewWindowStillProducesASelfProof() {
    let (coordinator, _, selfProofStore) = makeCoordinatorWithIsolatedSelfProofStore()
    coordinator.startSensing(eventCode: "TEST-CHECKPOINT-THEN-STOP-SELF-PROOF")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }

    coordinator.checkpointOpenWindowForBackgrounding()

    let record = coordinator.stopSensing()

    guard let record else {
      XCTFail("expected a SelfProofRecord — the session was complete (a Proof existed, a window was observed), only the exact enin bookkeeping changed via the checkpoint")
      return
    }
    XCTAssertEqual(selfProofStore.records.count, 1)
    XCTAssertEqual(record.eninStart, 1)
    XCTAssertEqual(record.eninEnd, 1, "eninEnd must reflect the checkpointed window (1), the last one this session actually observed")
  }

  func testCheckpointThenStopClosesANewWindowThatOpenedAfterTheCheckpoint() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-CHECKPOINT-THEN-STOP-NEW-WINDOW")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }

    coordinator.checkpointOpenWindowForBackgrounding()
    XCTAssertEqual(store.reports.count, 1, "checkpoint closes the first open window (enin=1)")

    // Background sensing observes a new peer in a new window (enin=2) —
    // e.g. the app resumed background BLE activity before the user
    // eventually stopped.
    coordinator.handleDetection(
      enin: 2,
      rpid: "peer-after-checkpoint",
      detectedDisplayId: DetectionFixture.displayId(device: 99)
    )

    coordinator.stopSensing()

    XCTAssertEqual(
      store.reports.count, 2,
      "stopSensing() must still close a genuinely new window that opened after the checkpoint (enin=2), distinct from the checkpointed one (enin=1)"
    )
    XCTAssertEqual(store.reports.last?.enin, 2)
    XCTAssertEqual(store.reports.last?.peerCount, 1)
  }

  // MARK: - Double-finalization scenario (b): two checkpoints, nothing observed between

  func testTwoConsecutiveCheckpointsWithNoActivityBetweenDoNotDoubleCloseOrProduceASpuriousReport() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-CHECKPOINT-TWICE")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }

    coordinator.checkpointOpenWindowForBackgrounding()
    XCTAssertEqual(store.reports.count, 1, "first checkpoint closes the open window")

    // App briefly foregrounds without any BLE activity, then backgrounds
    // again — a second, genuine backgrounding event, but with nothing new
    // observed since the first checkpoint.
    coordinator.checkpointOpenWindowForBackgrounding()

    XCTAssertEqual(
      store.reports.count, 1,
      "a second checkpoint with nothing new observed must no-op, not double-close or produce a spurious empty report (§3.6)"
    )
  }

  // MARK: - Regression: firstWindowEnin guard (sub-slice 1, §3.5)

  /// Would fail if `advanceWindowBookkeepingIfNeeded`'s nil-branch guard
  /// were reverted to the old unconditional `firstWindowEnin = enin` — a
  /// backgrounding
  /// checkpoint nils `currentWindowEnin` mid-session without ending the
  /// session, so the next detection re-enters that nil-branch a second time
  /// per session, which is exactly the case sub-slice 1's guard fix exists
  /// for.
  func testFirstWindowEninSurvivesABackgroundingCheckpointMidSession() {
    let (coordinator, _, selfProofStore) = makeCoordinatorWithIsolatedSelfProofStore()
    coordinator.startSensing(eventCode: "TEST-FIRST-WINDOW-ENIN-REGRESSION")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording phase before checkpoint, got \(coordinator.phase)")
      return
    }

    coordinator.checkpointOpenWindowForBackgrounding()

    // Re-enters advanceWindowBookkeepingIfNeeded's nil-branch
    // (currentWindowEnin was nil'd by the checkpoint) — with the old
    // unconditional assignment this
    // would overwrite firstWindowEnin from 1 to 2.
    coordinator.handleDetection(
      enin: 2,
      rpid: "peer-after-checkpoint",
      detectedDisplayId: DetectionFixture.displayId(device: 99)
    )

    let record = coordinator.stopSensing()
    guard let record else {
      XCTFail("expected a SelfProofRecord")
      return
    }
    XCTAssertEqual(selfProofStore.records.count, 1)
    XCTAssertEqual(
      record.eninStart, 1,
      "firstWindowEnin must stay pinned to the session's true first window (1), not be overwritten by the post-checkpoint window (2)"
    )
    XCTAssertEqual(record.eninEnd, 2, "eninEnd correctly reflects the final open window at real session end")
  }
}
