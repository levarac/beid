// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import BeidSharedKit
import XCTest
@testable import Beid

@MainActor
func makeIsolatedSensingCoordinator(
  for testCase: XCTestCase,
  sensingCryptography: any SensingCryptography = DeterministicSensingCryptography(),
  reportSubmissionRuntime: (any WindowReportSubmissionRuntimeProtocol)? = nil
) -> SensingCoordinator {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("sensing-coordinator-test-\(UUID().uuidString)", isDirectory: true)
  do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  } catch {
    preconditionFailure("Unable to create isolated sensing test directory: \(error)")
  }
  testCase.addTeardownBlock {
    try? FileManager.default.removeItem(at: directory)
  }
  return SensingCoordinator(
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
    sensingCryptography: sensingCryptography,
    reportSubmissionRuntime: reportSubmissionRuntime
  )
}

@MainActor
final class SensingCoordinatorTests: XCTestCase {
  func testDemoEventModeRemainsOverridableInDebugSimulator() throws {
    #if DEBUG && targetEnvironment(simulator)
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    XCTAssertTrue(coordinator.useDemoEventMode)

    coordinator.useDemoEventMode = false
    XCTAssertFalse(coordinator.useDemoEventMode)

    coordinator.useDemoEventMode = true
    XCTAssertTrue(coordinator.useDemoEventMode)
    #else
    throw XCTSkip("only applicable to Debug Simulator builds")
    #endif
  }

  func testReleaseConfigurationCannotEnableDemoEventMode() throws {
    #if DEBUG
    throw XCTSkip("only applicable to Release-configured builds")
    #else
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.useDemoEventMode = false
    XCTAssertFalse(coordinator.useDemoEventMode)

    coordinator.useDemoEventMode = true
    XCTAssertFalse(coordinator.useDemoEventMode)
    #endif
  }

  func testEngineOnEventIsWired() {
    // Smoke test: constructing the coordinator wires BarnardEngine's
    // onEvent callback without crashing (barnard#56 engine integration).
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    XCTAssertEqual(coordinator.phase, .idle)
  }

  func testDemoSequenceReachesRecordingPhaseAtThreshold() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    let event = EventSession(id: "TEST-EVENT", name: "Test Event", venue: nil)
    var collectedProof: Proof?
    coordinator.onProofCollected = { collectedProof = $0 }

    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    let threshold = BeidConfig.eventConfirmThreshold
    guard case .recording(let recordingEvent, let peersVerified) = coordinator.phase else {
      XCTFail("expected .recording phase, got \(coordinator.phase)")
      return
    }
    XCTAssertEqual(recordingEvent, event)
    XCTAssertEqual(peersVerified, threshold + 2, "demo sequence keeps growing for 2 steps past threshold")
    XCTAssertEqual(collectedProof?.eventName, "Test Event")
    XCTAssertEqual(collectedProof?.peersVerified, threshold, "Proof is created the instant .recording begins, at the threshold count")
  }

  func testDemoSequenceKeepsSensingDuringItsInitialDelay() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.startSensing(demoEvent: .demoSample)

    try? await Task.sleep(nanoseconds: 10_000_000)

    XCTAssertEqual(coordinator.phase, .sensing)
    coordinator.reset()
  }

  func testDemoSequenceStepsThroughRecordingCounts() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    let event = EventSession(id: "TEST-EVENT", name: "Test Event", venue: nil)
    var observedPeerCounts: [Int] = []
    let threshold = BeidConfig.eventConfirmThreshold
    let finalCount = threshold + 2

    // Drive the sequence with a real delay short enough for a test, and
    // sample intermediate phases via a manual polling loop instead of
    // reaching into private state. Breaking on the known final count (not
    // an observation tally) guarantees termination: once the sequence
    // finishes, phase stays at `.recording(finalCount)` forever.
    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 10_000_000)
    while true {
      try? await Task.sleep(nanoseconds: 5_000_000)
      if case .recording(_, let peersVerified) = coordinator.phase {
        if observedPeerCounts.last != peersVerified {
          observedPeerCounts.append(peersVerified)
        }
        if peersVerified == finalCount { break }
      }
    }

    XCTAssertEqual(observedPeerCounts, [threshold, threshold + 1, finalCount])
  }

  func testSimulateSignalLostOnlyAppliesDuringRecording() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.simulateSignalLost()
    XCTAssertEqual(coordinator.phase, .idle, "no-op outside .recording")
  }

  func testResumeSensingPreservesPeersVerifiedAcrossSignalLostCycle() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    let event = EventSession(id: "TEST-EVENT", name: "Test Event", venue: nil)

    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    guard case .recording(_, let peersVerifiedBeforeLoss) = coordinator.phase else {
      XCTFail("expected .recording phase before signal loss")
      return
    }

    coordinator.simulateSignalLost()
    guard case .signalLost(let frozenEvent, let frozenPeersVerified) = coordinator.phase else {
      XCTFail("expected .signalLost phase")
      return
    }
    XCTAssertEqual(frozenEvent, event)
    XCTAssertEqual(frozenPeersVerified, peersVerifiedBeforeLoss, "signal loss freezes the count, never resets it")

    coordinator.resumeSensing()
    guard case .recording(let resumedEvent, let resumedPeersVerified) = coordinator.phase else {
      XCTFail("expected .recording phase after resume")
      return
    }
    XCTAssertEqual(resumedEvent, event)
    XCTAssertEqual(resumedPeersVerified, frozenPeersVerified, "resume continues in place, not a restart")
  }

  func testResetReturnsToIdle() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    coordinator.reset()
    XCTAssertEqual(coordinator.phase, .idle)
  }

  func testCancelingDemoWhileItsContinuationWaitsForMainActorDoesNotResurrectSession() async {
    for usesReset in [false, true] {
      let coordinator = makeIsolatedSensingCoordinator(for: self)
      let stepDelayNanos: UInt64 = 100_000_000
      coordinator.runDemoSequence(
        demoEvent: .demoSample,
        stepDelayNanos: stepDelayNanos
      )

      // Let the demo task enter its nonisolated delay, then hold MainActor
      // past that delay. Its successful continuation is now queued behind
      // this test when the session-ending action cancels the task.
      try? await Task.sleep(nanoseconds: 10_000_000)
      Thread.sleep(forTimeInterval: 0.15)
      if usesReset {
        coordinator.reset()
      } else {
        coordinator.stopSensing()
      }

      // Give the queued, now-cancelled continuation a chance to run. It
      // must exit instead of restoring eventFound/recording state.
      try? await Task.sleep(nanoseconds: 10_000_000)
      XCTAssertEqual(
        coordinator.phase,
        .idle,
        usesReset ? "reset" : "stopSensing"
      )
    }
  }

  /// beid#134 Decision 1 (`docs/specs/ledger-async-io.md` §4, §7 AC3): a
  /// detection arriving while `isLedgerLoading` is still `true` must be
  /// queued, not lost, and must be processed in original arrival order once
  /// loading completes — producing the same `phase`/window state as if
  /// `handleDetection` had been called directly after construction, once
  /// `isLedgerLoading` becomes `false`.
  func testDetectionsArrivingDuringLoadingWindowAreQueuedAndReplayedInOrder() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sensing-coordinator-loading-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let coordinator = SensingCoordinator(
      loadingFromDirectory: directory,
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false

    // No `await` has happened yet, so the background load task cannot have
    // run any of its body — construction is guaranteed still mid-flight.
    XCTAssertTrue(coordinator.isLedgerLoading, "loading must still be in progress immediately after construction")

    // No `eventCode:` argument: `startSensing`'s real (non-demo) path only
    // calls `engine.configure(eventCode:)` inside `engine.requestPermissions`'s
    // completion, gated on `canScan`/`canAdvertise` — never satisfied on a
    // BLE-less Simulator (AGENTS.md), so `engine.getCurrentEventCode()`
    // stays `nil` and `handleDetection`'s `.sensing` case falls back to
    // "Unknown Event" regardless of load timing. Matches every sibling test
    // in `WindowReportFinalizationTests.swift` using this same real-path
    // pattern, none of which assert an exact `eventCode`/session id either.
    coordinator.startSensing()
    // Two detections, queued in arrival order — the second alone would
    // reach .recording at the configured threshold if replayed out of
    // order or deduped incorrectly against the first.
    coordinator.handleDetection(
      enin: 1,
      rpid: "peer-0",
      detectedDisplayId: DetectionFixture.displayId(device: 0)
    )
    coordinator.handleDetection(
      enin: 1,
      rpid: "peer-1",
      detectedDisplayId: DetectionFixture.displayId(device: 1)
    )

    // Still queued: no detection has been processed, so phase has not yet
    // advanced past .sensing (set by startSensing above).
    XCTAssertTrue(coordinator.isLedgerLoading, "still mid-load: queued detections must not be processed yet")
    XCTAssertEqual(coordinator.phase, .sensing, "a queued detection must not advance phase before loading completes")

    await coordinator.waitForLedgerLoadToFinish()

    XCTAssertFalse(coordinator.isLedgerLoading, "loading must have completed")
    guard case .eventFound = coordinator.phase else {
      XCTFail("expected .eventFound after the queued detections drained, got \(coordinator.phase)")
      return
    }
    XCTAssertEqual(coordinator.devicesVerified, 2, "both queued detections must have been replayed, in order, not lost or deduped")
  }

  /// beid#134/#156: gh#156's owner-key regeneration check (`quarantinedOwnerKeySeedKey`
  /// / `ownerPublicKeyMismatchDetected`) was relocated from a synchronous
  /// `AppCoordinator.init()` call into `beginLedgerLoad(...)`'s background
  /// Task, at the same point that already calls
  /// `reconcileSelfProofCheckpointIfNeeded()` — after the real stores are
  /// assigned, before `isLedgerLoading` flips `false` and before the
  /// detection queue drains. This proves both halves of that move: (1) the
  /// owner-key resolution the check forces does not happen synchronously at
  /// construction — `crypto.calls` is still empty immediately after
  /// `init`, mid-load — and (2) it still completes strictly before any
  /// queued detection is replayed, using `DeterministicSensingCryptography`
  /// as a call-order spy: `ownerPublicKeyMismatchDetected` unconditionally
  /// calls `sensingCryptography.ownerPublicKey()`, and replaying the queued
  /// detection's `.sensing -> .eventFound` transition
  /// (`handleDetection`'s `.sensing` case, via `beginEventFoundSessionState(_:)`)
  /// independently calls `eventSigningPublicKey(eventCode:)` then
  /// `ownerPublicKey()` again to fix the session commit — so if the
  /// relocation ever reordered the check after the drain, the first
  /// `.ownerPublicKey` call recorded would no longer be the check's. This
  /// test never uses demo mode (`useDemoEventMode = false` below), so it
  /// only ever exercises the real detection path — this comment previously
  /// misnamed the mechanism after `beginEventFound(_:)`, the demo-only
  /// function beid#189 removed; fixed to name the function this test
  /// actually exercises.
  func testOwnerKeyMismatchCheckCompletesDuringBackgroundLoadBeforeQueuedDetectionDrains() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sensing-coordinator-owner-key-loading-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let crypto = DeterministicSensingCryptography()
    let coordinator = SensingCoordinator(loadingFromDirectory: directory, sensingCryptography: crypto)
    coordinator.useDemoEventMode = false

    // No `await` has happened yet, so the background load task cannot have
    // run any of its body — the owner-key check has not resolved anything.
    XCTAssertTrue(coordinator.isLedgerLoading, "loading must still be in progress immediately after construction")
    XCTAssertTrue(crypto.calls.isEmpty, "owner key must not be resolved synchronously at/around construction")

    coordinator.startSensing()
    coordinator.handleDetection(
      enin: 1,
      rpid: "peer-0",
      detectedDisplayId: DetectionFixture.displayId(device: 0)
    )

    // Still queued: the detection must not have been replayed yet, so the
    // commit-computation calls it would trigger have not happened either.
    XCTAssertTrue(coordinator.isLedgerLoading, "still mid-load: the queued detection must not be processed yet")
    XCTAssertTrue(crypto.calls.isEmpty, "the queued detection must not be replayed before loading completes")

    await coordinator.waitForLedgerLoadToFinish()

    XCTAssertFalse(coordinator.isLedgerLoading, "loading must have completed")
    guard case .eventFound = coordinator.phase else {
      XCTFail("expected .eventFound after the queued detection drained, got \(coordinator.phase)")
      return
    }
    XCTAssertEqual(
      crypto.calls,
      [.ownerPublicKey, .eventSigningPublicKey(eventCode: "Unknown Event"), .ownerPublicKey],
      "the mismatch check's ownerPublicKey() call must be the first recorded call — strictly before the queued detection's beginEventFoundSessionState(_:) commit computation calls eventSigningPublicKey/ownerPublicKey again"
    )
  }

  /// beid#186 — `bindingRecordStore` was the one store on `SensingCoordinator`
  /// never threaded through `loadingFromDirectory:`/the explicit-storage
  /// seam: every other store (`windowReportStore`/`selfProofStore`/
  /// `selfProofCheckpointStore`/the ledger file) was already injectable, but
  /// this one silently kept resolving `BindingRecordStore`'s own default
  /// on-device path regardless of what directory a test passed in. Because
  /// `ownerPublicKeyMismatchDetected` (gh#156 Signal B) reads
  /// `bindingRecordStore.records`, a coordinator built for an "isolated"
  /// test could still see whatever real binding records happened to already
  /// exist on the machine running the test — a harness bug that would read
  /// as a product bug, discovered empirically during beid#134's own test
  /// development. This seeds the real on-device default store with a
  /// deliberately owner-key-mismatching record, then proves an isolated
  /// coordinator constructed via `loadingFromDirectory:` — pointed at an
  /// empty temp directory, never at that default path — does not see it.
  func testIsolatedCoordinatorDoesNotSeeOnDeviceBindingRecords() async throws {
    // `BindingRecordStore`'s own default filename
    // (`ios/Beid/Persistence/BindingRecordStore.swift`'s `defaultFileURL()`)
    // — deliberately stable per that file's own doc comment, so hardcoding
    // it here is safe. Snapshot-and-restore rather than "delete on
    // teardown": this file may legitimately already hold real records from
    // other activity on this machine, and this test must not destroy them.
    let onDeviceFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("binding-records-v2.json")
    let originalOnDeviceBytes = try? Data(contentsOf: onDeviceFileURL)
    addTeardownBlock {
      if let originalOnDeviceBytes {
        try? originalOnDeviceBytes.write(to: onDeviceFileURL, options: .atomic)
      } else {
        try? FileManager.default.removeItem(at: onDeviceFileURL)
      }
    }

    let mismatchingRecord = BindingRecord(
      proofId: UUID(),
      eventCode: "TEST-ON-DEVICE-POLLUTION",
      walletAddress: "0x0000000000000000000000000000000000000001",
      eventSigningPublicKey: Data(repeating: 0x02, count: 33),
      ownerPublicKey: Data(repeating: 0xAA, count: 33),
      chainId: 1,
      nonce: Data(repeating: 0x04, count: 16),
      issuedAt: "2026-01-01T00:00:00Z",
      walletSignatureHex: String(repeating: "0a", count: 65),
      deviceSignature: BarnardCoreRecoverableSignature(
        r: [UInt8](repeating: 1, count: 32),
        s: [UInt8](repeating: 2, count: 32),
        v: 0
      )
    )
    // `BindingRecordStore()` with no `fileURL` resolves to the same
    // real on-device default path `SensingCoordinator`'s own production
    // `convenience init()` would use — the exact path an isolated test
    // coordinator must never read from.
    BindingRecordStore().add(mismatchingRecord)

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sensing-coordinator-binding-isolation-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let coordinator = SensingCoordinator(
      loadingFromDirectory: directory,
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false
    await coordinator.waitForLedgerLoadToFinish()

    XCTAssertFalse(
      coordinator.ownerPublicKeyMismatchDetected,
      "an isolated coordinator must not see a mismatching record seeded directly into the real on-device binding-record store"
    )
  }

  func testStartSensingTwiceInARowOnTheSameCoordinatorBothReachRecording() async {
    // Regression check for re-entering the scan flow within one app
    // session (AppCoordinator reuses one long-lived SensingCoordinator
    // across `startScan()`/`finishScan()` calls) — per-session state
    // (`aggregationRuntime`, `activeCommit`, `activeProofId`, ...) must not
    // leak from the first session into the second.
    let coordinator = makeIsolatedSensingCoordinator(for: self)

    coordinator.startSensing(demoEvent: .demoSample)
    await coordinator.waitForDemoSequenceToFinish()
    guard case .recording = coordinator.phase else {
      XCTFail("first session: expected .recording, got \(coordinator.phase)")
      return
    }

    coordinator.reset()
    XCTAssertEqual(coordinator.phase, .idle)

    coordinator.startSensing(demoEvent: .demoSample)
    await coordinator.waitForDemoSequenceToFinish()
    guard case .recording = coordinator.phase else {
      XCTFail("second session: expected .recording, got \(coordinator.phase)")
      return
    }
  }

  // MARK: - beid#116: BeidSharedKit.sensing ownership gates
  //
  // The phase machine and its threshold decision live in
  // `BeidSharedKit.sensing` (`shared/.../sensing/ScanPhase.kt`); this
  // coordinator only converts, calls, and projects. These tests are the
  // "reverting to a native decision turns a test RED" mutation-gate: if a
  // future edit reintroduces a native re-implementation of the confirm
  // comparison, or a native-driven `.signalLost` recovery on the next
  // detection, one of these goes RED without any change to shared itself.

  /// A real (non-demo) detection arriving while `.signalLost` must be a
  /// full no-op — not just the displayed phase, but the underlying device
  /// count too. Recovery is only ever the explicit `resumeSensing()`
  /// action; mirrors `applyScanDetection`'s `SIGNAL_LOST` branch in shared.
  func testHandleDetectionIsANoOpWhileSignalLost() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: "TEST-SIGNAL-LOST-DETECTION-NO-OP")

    let threshold = BeidConfig.eventConfirmThreshold
    for device in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: 1),
        detectedDisplayId: DetectionFixture.displayId(device: device)
      )
    }
    guard case .recording(_, let peersVerifiedBeforeLoss) = coordinator.phase else {
      XCTFail("expected .recording before signal loss, got \(coordinator.phase)")
      return
    }

    coordinator.simulateSignalLost()
    guard case .signalLost(_, let frozenPeersVerified) = coordinator.phase else {
      XCTFail("expected .signalLost, got \(coordinator.phase)")
      return
    }
    XCTAssertEqual(frozenPeersVerified, peersVerifiedBeforeLoss)

    // A brand-new device — which would move both arms if processed — must
    // be dropped entirely while `.signalLost`.
    coordinator.handleDetection(
      enin: 2,
      rpid: DetectionFixture.rotatingRpid(device: threshold + 1, enin: 2),
      detectedDisplayId: DetectionFixture.displayId(device: threshold + 1)
    )

    guard case .signalLost(_, let peersVerifiedAfterDetection) = coordinator.phase else {
      XCTFail("a detection while .signalLost must not leave .signalLost, got \(coordinator.phase)")
      return
    }
    XCTAssertEqual(
      peersVerifiedAfterDetection, frozenPeersVerified,
      "a detection while .signalLost must not move the frozen count — resumeSensing() is the only way out"
    )
    XCTAssertEqual(
      coordinator.devicesVerified, peersVerifiedBeforeLoss,
      "the underlying device count must not move either — this is a full no-op, not just a display freeze"
    )
  }

  /// A real detection before `startSensing()` (`.idle`) must also be a
  /// no-op — mirrors `applyScanDetection`'s `IDLE` branch in shared.
  func testHandleDetectionIsANoOpWhileIdle() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.useDemoEventMode = false

    coordinator.handleDetection(
      enin: 1,
      rpid: DetectionFixture.rotatingRpid(device: 0, enin: 1),
      detectedDisplayId: DetectionFixture.displayId(device: 0)
    )

    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertEqual(coordinator.devicesVerified, 0)
  }

  /// Runtime-authority gate: the coordinator's confirm decision, for the
  /// counts it actually accumulated, must equal what
  /// `BeidSharedKit.sensing.shouldConfirmScanEvent` computes for those same
  /// counts — proving the phase the coordinator lands on isn't a native
  /// value that merely happens to agree with shared today.
  func testConfirmationDecisionMatchesBeidSharedKitForTheSameCounts() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: "TEST-RUNTIME-AUTHORITY")

    let threshold = BeidConfig.eventConfirmThreshold
    for device in 0..<(threshold - 1) {
      coordinator.handleDetection(
        enin: 1,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: 1),
        detectedDisplayId: DetectionFixture.displayId(device: device)
      )
    }
    XCTAssertFalse(
      BeidSharedKit.sensing.shouldConfirmScanEvent(
        coPresentDeviceCount: Int32(threshold - 1),
        distinctDeviceCount: Int32(threshold - 1),
        eventConfirmThreshold: Int32(threshold)
      )
    )
    guard case .eventFound = coordinator.phase else {
      XCTFail("expected .eventFound below threshold, got \(coordinator.phase)")
      return
    }

    coordinator.handleDetection(
      enin: 1,
      rpid: DetectionFixture.rotatingRpid(device: threshold - 1, enin: 1),
      detectedDisplayId: DetectionFixture.displayId(device: threshold - 1)
    )
    XCTAssertTrue(
      BeidSharedKit.sensing.shouldConfirmScanEvent(
        coPresentDeviceCount: Int32(threshold),
        distinctDeviceCount: Int32(threshold),
        eventConfirmThreshold: Int32(threshold)
      )
    )
    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording at threshold, got \(coordinator.phase)")
      return
    }
  }

  /// B005 discovery is an unauthenticated pre-join hint only. The native
  /// adapter must forward its fields to shared without entering sensing,
  /// binding, proof, ledger, or report-submission paths.
  func testEventInfoHintAppearsAsNearbyCandidateWithoutMutatingJoinedSessionState() throws {
    let reportRuntime = DiscoveryIsolationReportRuntimeSpy()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      reportSubmissionRuntime: reportRuntime
    )
    var collectedProof = false
    coordinator.onProofCollected = { _ in collectedProof = true }
    let hash = Data([0, 1, 2, 3, 4, 5, 6, 7])
    let census = Data([9, 8])

    coordinator.handleEventInfoHint(
      peripheralId: "peripheral-a",
      eventDisplayName: "Community night",
      eventCodeHash: hash,
      census: census,
      additionalNamesOmitted: false,
      additionalEventsOmitted: false,
      observedAtEpochMillis: 1_000
    )

    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertEqual(coordinator.bindingState, .none)
    XCTAssertNil(coordinator.joinedEventCode)
    XCTAssertNil(coordinator.joinedCanonicalEventIdHex)
    XCTAssertEqual(coordinator.devicesVerified, 0)
    XCTAssertNil(coordinator.sessionAggregate)
    XCTAssertEqual(coordinator.unidentifiedRpidCount, 0)
    XCTAssertFalse(collectedProof)
    XCTAssertEqual(reportRuntime.captureCalls, 0)
    XCTAssertEqual(reportRuntime.submitCalls, 0)

    let snapshot = coordinator.nearbyEventCandidates
    XCTAssertEqual(snapshot.candidateCount, 1)
    let candidate = try XCTUnwrap(snapshot.candidateAt(index: 0))
    XCTAssertEqual(Data(bytesFromKotlinByteArray: candidate.eventCodeHash), hash)
    XCTAssertEqual(candidate.displayNameAt(index: 0), "Community night")
    let source = try XCTUnwrap(candidate.sourceAt(index: 0))
    XCTAssertEqual(source.peripheralId, "peripheral-a")
    XCTAssertEqual(source.eventDisplayName, "Community night")
    XCTAssertEqual(
      Data(bytesFromKotlinByteArray: try XCTUnwrap(source.census)),
      census
    )
  }

  /// Barnard's overflow marker carries no candidate identity. Its global
  /// omission facts still cross the adapter, then reset with the discovery
  /// session; the marker itself must never be shown as an event.
  func testEventInfoOverflowMarkerPublishesOnlyOmissionFactsAndResetClearsThem() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)

    coordinator.handleEventInfoHint(
      peripheralId: "",
      eventDisplayName: "",
      eventCodeHash: Data(),
      census: nil,
      additionalNamesOmitted: true,
      additionalEventsOmitted: true,
      observedAtEpochMillis: 2_000
    )

    XCTAssertEqual(coordinator.nearbyEventCandidates.candidateCount, 0)
    XCTAssertTrue(coordinator.nearbyEventCandidates.additionalNamesOmitted)
    XCTAssertTrue(coordinator.nearbyEventCandidates.additionalEventsOmitted)
    XCTAssertEqual(coordinator.phase, .idle)

    coordinator.reset()

    XCTAssertEqual(coordinator.nearbyEventCandidates.candidateCount, 0)
    XCTAssertFalse(coordinator.nearbyEventCandidates.additionalNamesOmitted)
    XCTAssertFalse(coordinator.nearbyEventCandidates.additionalEventsOmitted)
    XCTAssertEqual(coordinator.phase, .idle)
  }
}

@MainActor
private final class DiscoveryIsolationReportRuntimeSpy: WindowReportSubmissionRuntimeProtocol {
  private(set) var captureCalls = 0
  private(set) var submitCalls = 0

  func captureAndQueueWindow(
    id: UUID,
    eventCode: String,
    eventIdHex: String?,
    enin: Int,
    peerRpids: Set<String>,
    reporterRpid: String?,
    participantCommitment: Data?
  ) {
    captureCalls += 1
  }

  func submitPending() {
    submitCalls += 1
  }

  func submissionState(forEventCode eventCode: String) -> ReportSubmissionState? {
    nil
  }
}
