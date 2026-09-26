// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BarnardCore
import BeidSharedKit
import Combine
import XCTest
@testable import Beid

@MainActor
func makeIsolatedSensingCoordinator(
  for testCase: XCTestCase,
  sensingCryptography: any SensingCryptography = DeterministicSensingCryptography(),
  reportSubmissionRuntime: (any WindowReportSubmissionRuntimeProtocol)? = nil,
  participantRelayControl: (any ParticipantRelayControlling)? = nil,
  eventJoinControl: (any EventJoinControlling)? = nil,
  eventJoinRegistry: (any EventJoinRegistry)? = nil,
  nearbyDiscoveryStore:
    ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventDiscoveryStore? = nil,
  nearbyDiscoveryClock: @escaping () -> Int64 = {
    Int64((Date().timeIntervalSince1970 * 1_000).rounded())
  },
  joinDiagnosticLog: @escaping (String) -> Void = { _ in },
  relayCadenceNanoseconds: UInt64 = SensingCoordinator.relayDecisionBoundaryNanoseconds
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
    reportSubmissionRuntime: reportSubmissionRuntime,
    eventJoinControl: eventJoinControl,
    eventJoinRegistry: eventJoinRegistry,
    nearbyDiscoveryStore: nearbyDiscoveryStore,
    nearbyDiscoveryClock: nearbyDiscoveryClock,
    joinDiagnosticLog: joinDiagnosticLog,
    participantRelayControl: participantRelayControl,
    relayCadenceNanoseconds: relayCadenceNanoseconds
  )
}

@MainActor
final class SensingCoordinatorTests: XCTestCase {
  // MARK: - Demo mode never arms the relay

  /// Demo candidates are fabricated and relay puts bytes on a real radio, so
  /// the two must never meet (beid#367). The guard lives inside
  /// `startParticipantRelay` rather than in `startSensing`'s control flow,
  /// because that method, `runDemoScenario` and `useDemoEventMode` are all
  /// reachable from outside the coordinator. This asserts the structural
  /// property: with demo mode on, no verifier is ever handed to Barnard, for
  /// every scenario the app ships and for a bare call besides.
  func testDemoModeNeverArmsTheRelayForAnyScenario() async {
    for scenario in DemoScenario.allScenarios {
      let control = RecordingParticipantRelayControl()
      let coordinator = makeIsolatedSensingCoordinator(for: self, participantRelayControl: control)
      coordinator.useDemoEventMode = true

      coordinator.runDemoScenario(scenario, stepDelayNanos: 1_000)
      coordinator.startSensing(demoScenario: scenario)
      coordinator.startParticipantRelay()

      XCTAssertNil(
        control.verifier,
        "\(scenario.identifier) armed the relay while demo mode fabricates its candidates"
      )
      XCTAssertEqual(
        control.advanceCalls,
        0,
        "\(scenario.identifier) ran the relay forward in demo mode"
      )
      _ = coordinator.reset()
    }
  }

  /// The same property without a scenario: demo mode alone is enough to keep
  /// the relay unarmed, whatever calls into it.
  func testDemoModeNeverArmsTheRelay() {
    let control = RecordingParticipantRelayControl()
    let coordinator = makeIsolatedSensingCoordinator(for: self, participantRelayControl: control)
    coordinator.useDemoEventMode = true

    coordinator.startParticipantRelay()

    XCTAssertNil(control.verifier)
  }

  /// Stand-in B005 v2 container bytes. Nothing here parses them: barnard has
  /// already verified whatever these tests hand across the seam, and the host
  /// keeps them only so a spec 134 relay can re-send them unchanged.
  static let envelopeContainer = Data([3, 0, 1, 2])
  static let eventIdHex = String(repeating: "ab", count: 32)
  static let keySetDigestHex = String(repeating: "cd", count: 32)
  static let eventCodeHashHex = String(repeating: "ef", count: 8)

  private let nearbyVectorEventIdHex =
    "5d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195"
  private let nearbyVectorHashHex = "9adc61d60dda843e"
  private let nearbyVectorDefinitionHashHex =
    "ab6f2c1d9e4b8a7350c1d2e3f405162738495a6b7c8d9e0f1a2b3c4d5e6f7081"
  private let nearbyVectorBlockHashHex =
    "cd9e8f7a6b5c4d3e2f10112233445566778899aabbccddeeff00112233445566"
  private let nearbyVectorValidFromEpochSeconds: Int64 = 1_799_997_000
  private let nearbyVectorValidUntilEpochSeconds: Int64 = 1_800_003_299

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

  /// The home indicator's stop action must reach the real engine seam. The
  /// Barnard engine owns the asynchronous state callback that later publishes
  /// `isScanning`/`isAdvertising == false`; this test pins the native request
  /// that initiates that transition without pretending a fake is BLE evidence.
  func testStopSensingRequestsAutomaticOperationStop() {
    let engine = RecordingEventJoinControl()
    let coordinator = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)

    coordinator.stopSensing()

    XCTAssertEqual(engine.stopAutomaticOperationCallCount, 1)
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

    // A stated permission outcome instead of the real engine's.
    //
    // This test is about the loading window, not about permissions, and it
    // previously reached that window through the real engine on a BLE-less
    // Simulator — whose answer is a property of the host, not of anything
    // under test. `.neverAnswers` says plainly that no grant arrives.
    //
    // **What keeps the phase at `.sensing` below is neither of those.** The
    // coordinator wraps the permission completion in `Task { @MainActor }`,
    // so its body runs in a later turn; by then `handleDetection` has called
    // `resetSessionState`, which bumps `joinAttemptGeneration`, and the
    // callback discards itself as belonging to an abandoned attempt. Setting
    // this to `.denied` was tried: the assertions still pass. So the phase
    // here is protected by that ordering, not by the outcome — and whether
    // a detection *should* be able to invalidate a pending join is beid#513,
    // a question about the app rather than about this test.
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .neverAnswers
    let coordinator = SensingCoordinator(
      loadingFromDirectory: directory,
      sensingCryptography: DeterministicSensingCryptography(),
      eventJoinControl: engine
    )
    coordinator.useDemoEventMode = false

    // No `await` has happened yet, so the background load task cannot have
    // run any of its body — construction is guaranteed still mid-flight.
    XCTAssertTrue(coordinator.isLedgerLoading, "loading must still be in progress immediately after construction")

    // No `eventCode:` argument: nothing downstream of the permission
    // completion runs while the grant is outstanding, so
    // `currentJoinedEventCode()` stays `nil` and `handleDetection`'s
    // `.sensing` case falls back to "Unknown Event" regardless of load
    // timing. Sibling tests in `WindowReportFinalizationTests.swift` use the
    // same pattern and likewise assert no exact `eventCode`/session id.
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
    // Stated rather than inherited from the Simulator's answer about a radio
    // it does not have — see the sibling test above, including what does and
    // does not actually protect the phase.
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .neverAnswers
    let coordinator = SensingCoordinator(
      loadingFromDirectory: directory,
      sensingCryptography: crypto,
      eventJoinControl: engine
    )
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

  func testDiscoveryOnlyScanStartsAndStopsOnlyTheScanItOwns() {
    let engine = RecordingEventJoinControl()
    let coordinator = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    coordinator.useDemoEventMode = false

    coordinator.startNearbyEventDiscovery()
    coordinator.startNearbyEventDiscovery()

    XCTAssertEqual(engine.startDiscoveryScanCallCount, 1)
    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 0)
    XCTAssertEqual(coordinator.phase, .idle)

    coordinator.stopNearbyEventDiscovery()
    coordinator.stopNearbyEventDiscovery()

    XCTAssertEqual(engine.stopDiscoveryScanCallCount, 1)
  }

  func testSuccessfulNearbyJoinTransfersDiscoveryScanOwnershipToAutomaticOperation() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let store = makeNearbyDiscoveryStore()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      nearbyDiscoveryStore: store,
      nearbyDiscoveryClock: { 1_800_000_000_000 }
    )
    coordinator.useDemoEventMode = false

    coordinator.startNearbyEventDiscovery()
    coordinator.joinNearbyEvent(eventCodeHashHex: nearbyVectorHashHex)
    try? await Task.sleep(nanoseconds: 20_000_000)
    coordinator.stopNearbyEventDiscovery()

    XCTAssertEqual(engine.startDiscoveryScanCallCount, 1)
    XCTAssertEqual(engine.joinAndStartContexts.count, 1)
    XCTAssertEqual(
      engine.stopDiscoveryScanCallCount,
      0,
      "a joined automatic-operation scan is no longer owned by the pre-join flow"
    )
  }

  /// beid#450 — Barnard kept 32 hashes and dropped the rest, and the list
  /// must not read as "this is what is nearby".
  func testNearbyCardProjectionCarriesTheOmittedEventsFlag() throws {
    let store = makeNearbyDiscoveryStore(additionalEventsOmitted: true)

    let presentation = NearbyEventCardListPresentation(
      candidates: store.snapshot,
      nowEpochSeconds: 1_800_000_000
    )

    XCTAssertTrue(
      presentation.hasOmittedEvents,
      "the SDK said it dropped events; the surface has to be able to say so"
    )
  }

  /// And stays false when nothing was dropped, so the row means something.
  func testNearbyCardProjectionReportsNoOmissionWhenNothingWasDropped() throws {
    let store = makeNearbyDiscoveryStore()

    let presentation = NearbyEventCardListPresentation(
      candidates: store.snapshot,
      nowEpochSeconds: 1_800_000_000
    )

    XCTAssertFalse(presentation.hasOmittedEvents)
  }

  func testNearbyCardProjectionKeepsUnresolvedCandidatesVisibleButNonInteractive() throws {
    let store = makeNearbyDiscoveryStore(includeUnresolvedCandidate: true)
    let snapshot = store.snapshot

    let presentation = NearbyEventCardListPresentation(
      candidates: snapshot,
      nowEpochSeconds: 1_800_000_000
    )

    let sourceHashes = (0..<snapshot.candidateCount).compactMap {
      snapshot.candidateAt(index: $0)?.eventCodeHashHex
    }
    XCTAssertEqual(
      presentation.cards.map(\.eventCodeHashHex),
      sourceHashes,
      "the native display projection must preserve every shared candidate in shared order"
    )
    let joinable = try XCTUnwrap(
      presentation.cards.first { $0.eventCodeHashHex == nearbyVectorHashHex }
    )
    XCTAssertEqual(joinable.eventIdHex, nearbyVectorEventIdHex)
    XCTAssertEqual(joinable.displayValidFromEpochSeconds, nearbyVectorValidFromEpochSeconds)
    XCTAssertEqual(joinable.displayValidUntilEpochSeconds, nearbyVectorValidUntilEpochSeconds)
    XCTAssertEqual(joinable.joinActionEventCodeHashHex, nearbyVectorHashHex)
    XCTAssertEqual(presentation.selectedEventCodeHashHex, nearbyVectorHashHex)

    let unresolved = try XCTUnwrap(
      presentation.cards.first { $0.eventCodeHashHex == "0102030405060708" }
    )
    XCTAssertNil(unresolved.eventIdHex)
    XCTAssertNil(unresolved.joinActionEventCodeHashHex)
  }

  func testOneEligibleCandidateIsPreselectedWithoutAutoJoining() {
    let engine = RecordingEventJoinControl()
    let store = makeNearbyDiscoveryStore()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      nearbyDiscoveryStore: store,
      nearbyDiscoveryClock: { 1_800_000_000_000 }
    )
    coordinator.useDemoEventMode = false

    let presentation = NearbyEventCardListPresentation(
      candidates: coordinator.nearbyEventCandidates,
      nowEpochSeconds: 1_800_000_000
    )

    XCTAssertEqual(presentation.selectedEventCodeHashHex, nearbyVectorHashHex)
    XCTAssertFalse(engine.didJoin, "preselection is visual state and must never auto-join")
  }

  func testMultipleEligibleCandidatesAreNotPreselectedOrAutoJoined() {
    let engine = RecordingEventJoinControl()
    let first = NearbyEventCard(
      beaconDisplayName: "First",
      eventIdHex: "01",
      displayValidFromEpochSeconds: nil,
      displayValidUntilEpochSeconds: nil,
      eventCodeHashHex: "0101010101010101"
    )
    let second = NearbyEventCard(
      beaconDisplayName: "Second",
      eventIdHex: "02",
      displayValidFromEpochSeconds: nil,
      displayValidUntilEpochSeconds: nil,
      eventCodeHashHex: "0202020202020202"
    )

    let presentation = NearbyEventCardListPresentation(cards: [first, second])

    XCTAssertNil(presentation.selectedEventCodeHashHex)
    XCTAssertFalse(engine.didJoin)
  }

  func testZeroCandidatesShowsSearchingStateAndManualEntryRescue() {
    let presentation = NearbyEventCardListPresentation(cards: [])

    XCTAssertTrue(presentation.isSearching)
    XCTAssertTrue(presentation.showsManualEntryRescue)
    XCTAssertTrue(presentation.cards.isEmpty)
  }

  func testEligibleNearbyCandidateJoinsExactlyOnceThroughCapabilitySeam() async throws {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let store = makeNearbyDiscoveryStore()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      nearbyDiscoveryStore: store,
      nearbyDiscoveryClock: { 1_800_000_000_000 }
    )
    coordinator.useDemoEventMode = false

    coordinator.joinNearbyEvent(eventCodeHashHex: nearbyVectorHashHex)
    try await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertEqual(engine.joinAndStartContexts.count, 1)
    XCTAssertEqual(engine.joinedCodes, [nearbyVectorEventIdHex])
    XCTAssertEqual(coordinator.phase, .sensing)
  }

  func testRenderedNearbyActionFailsClosedWhenCandidateExpiresDuringPermissionWait() async {
    var nowEpochMillis: Int64 = 1_800_000_000_000
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .answersLate
    let store = makeNearbyDiscoveryStore(observedAtEpochMillis: nowEpochMillis)
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      nearbyDiscoveryStore: store,
      nearbyDiscoveryClock: { nowEpochMillis }
    )
    coordinator.useDemoEventMode = false
    let renderedActionHash = NearbyEventCardListPresentation(
      candidates: coordinator.nearbyEventCandidates,
      nowEpochSeconds: nowEpochMillis / 1_000
    ).cards.first?.joinActionEventCodeHashHex

    coordinator.joinNearbyEvent(eventCodeHashHex: renderedActionHash ?? "")
    XCTAssertTrue(engine.isHoldingPermissionRequest)

    nowEpochMillis += 300_001
    coordinator.refreshNearbyEventDiscovery()
    XCTAssertEqual(coordinator.nearbyEventCandidates.candidateCount, 0)
    engine.grantHeldPermissionRequest()
    try? await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertFalse(engine.didJoin)
    XCTAssertEqual(coordinator.joinRefusal, .definitionNotEligible)
  }

  func testRenderedNearbyActionFailsClosedWhenCandidateExpiresBeforeTap() async throws {
    var nowEpochMillis: Int64 = 1_800_000_000_000
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .answersLate
    let store = makeNearbyDiscoveryStore(observedAtEpochMillis: nowEpochMillis)
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      nearbyDiscoveryStore: store,
      nearbyDiscoveryClock: { nowEpochMillis }
    )
    coordinator.useDemoEventMode = false
    let renderedActionHash = try XCTUnwrap(
      NearbyEventCardListPresentation(
        candidates: coordinator.nearbyEventCandidates,
        nowEpochSeconds: nowEpochMillis / 1_000
      ).cards.first?.joinActionEventCodeHashHex
    )

    nowEpochMillis += 300_001
    coordinator.refreshNearbyEventDiscovery()
    XCTAssertEqual(coordinator.nearbyEventCandidates.candidateCount, 0)

    coordinator.joinNearbyEvent(eventCodeHashHex: renderedActionHash)
    XCTAssertTrue(engine.isHoldingPermissionRequest)
    engine.grantHeldPermissionRequest()
    try? await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertFalse(engine.didJoin)
    XCTAssertEqual(engine.joinAndStartContexts.count, 0)
    XCTAssertEqual(coordinator.joinRefusal, .definitionNotEligible)
  }

  func testMissingDisplayWindowDoesNotOverrideAuthoritativeCandidateWindow() async throws {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let store = makeNearbyDiscoveryStore()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      nearbyDiscoveryStore: store,
      nearbyDiscoveryClock: { 1_800_000_000_000 }
    )
    coordinator.useDemoEventMode = false
    let card = NearbyEventCard(
      beaconDisplayName: "Community night",
      eventIdHex: nearbyVectorEventIdHex,
      displayValidFromEpochSeconds: nil,
      displayValidUntilEpochSeconds: nil,
      eventCodeHashHex: nearbyVectorHashHex
    )

    coordinator.joinNearbyEvent(eventCodeHashHex: try XCTUnwrap(card.joinActionEventCodeHashHex))
    try await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertEqual(engine.joinAndStartContexts.count, 1)
    XCTAssertEqual(engine.joinedCodes, [nearbyVectorEventIdHex])
  }

  func testDefinitionExpiryPublishesADisabledProjectionBeforeSourceTTL() async throws {
    let validUntilEpochSeconds: Int64 = 1_800_000_000
    var nowEpochMillis = validUntilEpochSeconds * 1_000 + 900
    let store = makeNearbyDiscoveryStore(
      observedAtEpochMillis: nowEpochMillis,
      validFromEpochSeconds: validUntilEpochSeconds - 60,
      validUntilEpochSeconds: validUntilEpochSeconds
    )
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      nearbyDiscoveryStore: store,
      nearbyDiscoveryClock: { nowEpochMillis }
    )
    let initial = try XCTUnwrap(
      NearbyEventCardListPresentation(
        candidates: coordinator.nearbyEventCandidates,
        nowEpochSeconds: nowEpochMillis / 1_000
      ).cards.first
    )
    XCTAssertEqual(initial.joinActionEventCodeHashHex, nearbyVectorHashHex)

    coordinator.refreshNearbyEventDiscovery()
    let expiryPublished = expectation(description: "definition expiry republishes nearby projection")
    let publication = coordinator.$nearbyEventCandidates.dropFirst().sink { _ in
      expiryPublished.fulfill()
    }
    nowEpochMillis += 100
    await fulfillment(of: [expiryPublished], timeout: 1)
    publication.cancel()

    let expired = try XCTUnwrap(
      NearbyEventCardListPresentation(
        candidates: coordinator.nearbyEventCandidates,
        nowEpochSeconds: nowEpochMillis / 1_000
      ).cards.first
    )
    XCTAssertEqual(coordinator.nearbyEventCandidates.candidateCount, 1)
    XCTAssertNil(expired.eventIdHex)
    XCTAssertNil(expired.joinActionEventCodeHashHex)
    XCTAssertNil(expired.displayValidFromEpochSeconds)
    XCTAssertNil(expired.displayValidUntilEpochSeconds)
  }

  private func makeNearbyDiscoveryStore(
    includeUnresolvedCandidate: Bool = false,
    observedAtEpochMillis: Int64 = 1_800_000_000_000,
    validFromEpochSeconds: Int64? = nil,
    validUntilEpochSeconds: Int64? = nil,
    additionalEventsOmitted: Bool = false
  ) -> ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventDiscoveryStore {
    let store = ExportedKotlinPackages.org.levarac.parallax.discovery
      .createNearbyEventDiscoveryStore()
    _ = ExportedKotlinPackages.org.levarac.parallax.discovery
      .recordNearbyEventRadioSelfVerifiedEnvelopeFromHex(
        store: store,
        peripheralId: "peripheral-verified",
        eventDisplayName: "Community night",
        eventCodeHashHex: nearbyVectorHashHex,
        rawContainerHex: "03000004",
        agreesWithRegistry: false,
        additionalNamesOmitted: false,
        additionalEventsOmitted: additionalEventsOmitted,
        observedAtEpochMillis: observedAtEpochMillis
      )
    guard let attempt = ExportedKotlinPackages.org.levarac.parallax.discovery
      .beginNearbyEventRegistryResolutionFromHex(
        store: store,
        eventCodeHashHex: nearbyVectorHashHex
      )
    else {
      preconditionFailure("expected a registry-resolution attempt")
    }
    _ = ExportedKotlinPackages.org.levarac.parallax.discovery
      .completeNearbyEventRegistryResolutionFromHex(
        store: store,
        attempt: attempt,
        result: .VERIFIED,
        resolvedEventIdHex: nearbyVectorEventIdHex,
        verifiedDefinitionJoinMode: .OPEN,
        verifiedDefinitionEventIdHex: nearbyVectorEventIdHex,
        verifiedDefinitionEventCodeHashHex: nearbyVectorHashHex,
        envelopeAgreesWithRegistry: true,
        verifiedDefinitionHashHex: nearbyVectorDefinitionHashHex,
        registryBlockHashHex: nearbyVectorBlockHashHex,
        verifiedDefinitionValidFromEpochSeconds: validFromEpochSeconds
          ?? nearbyVectorValidFromEpochSeconds,
        verifiedDefinitionValidUntilEpochSeconds: validUntilEpochSeconds
          ?? nearbyVectorValidUntilEpochSeconds
      )
    if includeUnresolvedCandidate {
      _ = ExportedKotlinPackages.org.levarac.parallax.discovery.recordNearbyEventHintFromHex(
        store: store,
        peripheralId: "peripheral-unresolved",
        eventDisplayName: "Unverified beacon",
        eventCodeHashHex: "0102030405060708",
        censusHex: nil,
        additionalNamesOmitted: false,
        additionalEventsOmitted: false,
        observedAtEpochMillis: observedAtEpochMillis
      )
    }
    return store
  }

  /// A B005 v2 envelope barnard reported as radio-self-verified becomes a
  /// candidate at exactly that tier, and at no higher one: only this host's
  /// own registry read can promote it, and none has happened here.
  ///
  /// The agreement closure is stubbed rather than driven through barnard's
  /// real `registryAgreement`, because `BarnardB005VerifiedEnvelope` has no
  /// public initializer on either platform and no test can fabricate one. The
  /// promotion matrix itself is asserted in the shared reducer's tests, which
  /// run on the iOS targets as well.
  func testRadioSelfVerifiedEnvelopeAppearsAtItsOwnTierWithoutMutatingJoinedSessionState() throws {
    let reportRuntime = DiscoveryIsolationReportRuntimeSpy()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      reportSubmissionRuntime: reportRuntime
    )
    var collectedProof = false
    coordinator.onProofCollected = { _ in collectedProof = true }
    let hash = Data([0, 1, 2, 3, 4, 5, 6, 7])

    coordinator.handleEventInfoEnvelopeV2(
      peripheralId: "peripheral-a",
      eventDisplayName: "Community night",
      eventCodeHash: hash,
      rawContainer: Self.envelopeContainer,
      registryAgreement: { _ in true },
      observedAtEpochMillis: 1_000
    )

    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertNil(coordinator.joinedEventCode)
    XCTAssertEqual(coordinator.devicesVerified, 0)
    XCTAssertFalse(collectedProof)
    XCTAssertEqual(reportRuntime.captureCalls, 0)
    XCTAssertEqual(reportRuntime.submitCalls, 0)

    let candidate = try XCTUnwrap(coordinator.nearbyEventCandidates.candidateAt(index: 0))
    XCTAssertEqual(candidate.receiverState, .RADIO_SELF_VERIFIED)
    XCTAssertEqual(candidate.registryStatus, .UNRESOLVED)
    XCTAssertEqual(Data(bytesFromKotlinByteArray: candidate.eventCodeHash), hash)
    XCTAssertEqual(candidate.displayNameAt(index: 0), "Community night")
    XCTAssertEqual(try XCTUnwrap(candidate.sourceAt(index: 0)).peripheralId, "peripheral-a")
  }

  /// A verified B005 v2 envelope carries the canonical Event ID that must be
  /// used for the registry read. The human-code hash is intentionally a
  /// different value in this regression: the v2 path must retain Barnard's
  /// verified identity instead of routing through the legacy hash lookup.
  func testRadioSelfVerifiedEnvelopeResolvesItsVerifiedEventIdWithoutLegacyHashLookup() async throws {
    let eventIdHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    let canonicalHash = "6c86c6aac5fb24bc"
    let legacyHumanCodeHash = "0001020304050607"
    let canonicalHashBytes = Data([0x6c, 0x86, 0xc6, 0xaa, 0xc5, 0xfb, 0x24, 0xbc])
    XCTAssertNotEqual(canonicalHash, legacyHumanCodeHash)
    let registry = FakeEventJoinRegistry()
    registry.answer = .resolves(
      FakeEventJoinRegistry.admittingResolution(
        eventIdHex: eventIdHex,
        nowEpochSeconds: 1_800_000_000,
        eventCodeHashHex: canonicalHash
      )
    )
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinRegistry: registry,
      nearbyDiscoveryClock: { 1_800_000_000_000 }
    )

    coordinator.handleEventInfoEnvelopeV2(
      peripheralId: "peripheral-a",
      eventDisplayName: "Community night",
      eventCodeHash: canonicalHashBytes,
      rawContainer: Self.envelopeContainer,
      verifiedEventIdHex: "0x\(eventIdHex)",
      registryAgreement: { _ in true },
      observedAtEpochMillis: 1_800_000_000_000
    )
    await Task.yield()

    let candidate = try XCTUnwrap(coordinator.nearbyEventCandidates.candidateAt(index: 0))
    XCTAssertEqual(registry.requestedEventIdHexes, ["0x\(eventIdHex)"])
    XCTAssertEqual(candidate.registryStatus, .REGISTERED_VIA_OPERATOR_LOOKUP)
    XCTAssertEqual(candidate.resolvedEventIdHex, "0x\(eventIdHex)")
    XCTAssertEqual(Data(bytesFromKotlinByteArray: candidate.eventCodeHash), canonicalHashBytes)
  }

  /// A v2 envelope carries no census, so recording one must not erase the
  /// census a v1 hint already published for the same source.
  func testRadioSelfVerifiedEnvelopeKeepsTheCensusAV1HintRecorded() throws {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
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

    coordinator.handleEventInfoEnvelopeV2(
      peripheralId: "peripheral-a",
      eventDisplayName: "Community night",
      eventCodeHash: hash,
      rawContainer: Self.envelopeContainer,
      registryAgreement: { _ in true },
      observedAtEpochMillis: 1_001
    )

    let candidate = try XCTUnwrap(coordinator.nearbyEventCandidates.candidateAt(index: 0))
    XCTAssertEqual(candidate.receiverState, .RADIO_SELF_VERIFIED)
    let source = try XCTUnwrap(candidate.sourceAt(index: 0))
    XCTAssertEqual(
      Data(bytesFromKotlinByteArray: try XCTUnwrap(source.census)),
      census
    )
  }

  /// A candidate assembled from v1 hints alone can never leave UNVERIFIED, and
  /// ending the session clears the tier along with everything else.
  func testHintOnlyCandidateStaysUnverifiedAndResetClearsAnEstablishedTier() throws {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    let hash = Data([0, 1, 2, 3, 4, 5, 6, 7])
    coordinator.handleEventInfoHint(
      peripheralId: "peripheral-a",
      eventDisplayName: "Community night",
      eventCodeHash: hash,
      census: nil,
      additionalNamesOmitted: false,
      additionalEventsOmitted: false,
      observedAtEpochMillis: 1_000
    )
    XCTAssertEqual(
      try XCTUnwrap(coordinator.nearbyEventCandidates.candidateAt(index: 0)).receiverState,
      .UNVERIFIED
    )

    coordinator.handleEventInfoEnvelopeV2(
      peripheralId: "peripheral-a",
      eventDisplayName: "Community night",
      eventCodeHash: hash,
      rawContainer: Self.envelopeContainer,
      registryAgreement: { _ in true },
      observedAtEpochMillis: 1_001
    )
    coordinator.reset()
    coordinator.handleEventInfoHint(
      peripheralId: "peripheral-a",
      eventDisplayName: "Community night",
      eventCodeHash: hash,
      census: nil,
      additionalNamesOmitted: false,
      additionalEventsOmitted: false,
      observedAtEpochMillis: 1_002
    )

    XCTAssertEqual(
      try XCTUnwrap(coordinator.nearbyEventCandidates.candidateAt(index: 0)).receiverState,
      .UNVERIFIED
    )
  }

  /// Spec 134 re-broadcast is signature-preserving, so the exact container
  /// bytes have to survive on the candidate for a later relay decision.
  func testRadioSelfVerifiedEnvelopeRetainsItsRawContainerBytes() throws {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.handleEventInfoEnvelopeV2(
      peripheralId: "peripheral-a",
      eventDisplayName: "Community night",
      eventCodeHash: Data([0, 1, 2, 3, 4, 5, 6, 7]),
      rawContainer: Self.envelopeContainer,
      registryAgreement: { _ in true },
      observedAtEpochMillis: 1_000
    )

    let candidate = try XCTUnwrap(coordinator.nearbyEventCandidates.candidateAt(index: 0))
    XCTAssertEqual(
      Data(bytesFromKotlinByteArray: try XCTUnwrap(candidate.rawEnvelopeContainer)),
      Self.envelopeContainer
    )
  }

  /// An unverified container becomes no candidate, but must not vanish
  /// without trace: the session tally is what makes the drop observable.
  func testUnverifiedEnvelopeIsCountedRatherThanVanishing() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)

    coordinator.handleUnverifiedEventInfoEnvelopeV2()

    XCTAssertEqual(coordinator.nearbyEventCandidates.candidateCount, 0)
    XCTAssertEqual(coordinator.nearbyEventCandidates.unverifiedEnvelopeCount, 1)
    XCTAssertEqual(coordinator.phase, .idle)

    coordinator.reset()

    XCTAssertEqual(coordinator.nearbyEventCandidates.unverifiedEnvelopeCount, 0)
  }

  func testJoinDiagnosticsUseOnlyAnEventIdPrefixOrUnknown() {
    var lines: [String] = []
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      joinDiagnosticLog: { lines.append($0) }
    )

    coordinator.handleEventInfoHint(
      peripheralId: "peripheral-a",
      eventDisplayName: "Community night",
      eventCodeHash: Data([0, 1, 2, 3, 4, 5, 6, 7]),
      census: nil,
      additionalNamesOmitted: false,
      additionalEventsOmitted: false,
      observedAtEpochMillis: 1_000
    )
    coordinator.handleUnverifiedEventInfoEnvelopeV2()
    coordinator.handleEventInfoEnvelopeV2(
      peripheralId: "peripheral-a",
      eventDisplayName: "Community night",
      eventCodeHash: Data([0, 1, 2, 3, 4, 5, 6, 7]),
      rawContainer: Self.envelopeContainer,
      verifiedEventIdHex: "0x\(Self.eventIdHex)",
      registryAgreement: { _ in true },
      observedAtEpochMillis: 1_001
    )

    XCTAssertEqual(
      lines,
      [
        "join_stage event_id=unknown stage=detection outcome=detected attempt=none retry_at_epoch_ms=none",
        "join_stage event_id=unknown stage=registry_resolution outcome=rejected_no_registry " +
          "attempt=none retry_at_epoch_ms=none",
        "join_stage event_id=unknown stage=detection outcome=detected attempt=none retry_at_epoch_ms=none",
        "join_stage event_id=unknown stage=envelope_verification outcome=rejected_unverified attempt=none retry_at_epoch_ms=none",
        "join_stage event_id=abababab stage=detection outcome=detected attempt=none retry_at_epoch_ms=none",
        "join_stage event_id=abababab stage=envelope_verification outcome=success attempt=none retry_at_epoch_ms=none",
        "join_stage event_id=abababab stage=registry_resolution outcome=rejected_no_registry " +
          "attempt=none retry_at_epoch_ms=none",
      ]
    )
  }

  func testJoinDiagnosticsRecordNearbyAdmission() async throws {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let store = makeNearbyDiscoveryStore()
    var lines: [String] = []
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      nearbyDiscoveryStore: store,
      nearbyDiscoveryClock: { 1_800_000_000_000 },
      joinDiagnosticLog: { lines.append($0) }
    )
    coordinator.useDemoEventMode = false

    coordinator.startNearbyEventDiscovery()
    coordinator.joinNearbyEvent(eventCodeHashHex: nearbyVectorHashHex)
    try await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertTrue(
      lines.contains(
        "join_stage event_id=5d5891b9 stage=admission outcome=admitted " +
          "attempt=none retry_at_epoch_ms=none"
      ),
      "diagnostic lines: \(lines)"
    )
  }

  func testJoinDiagnosticsRejectMalformedIdentifiersAndKeepReceiptFieldsPrivate() {
    var lines: [String] = []
    let coordinator = makeIsolatedSensingCoordinator(
      for: self, joinDiagnosticLog: { lines.append($0) }
    )
    coordinator.handleEventInfoEnvelopeV2(
      peripheralId: "private-peripheral-rpid", eventDisplayName: "private-name",
      eventCodeHash: Data([0, 1, 2, 3, 4, 5, 6, 7]),
      rawContainer: Data("private-container".utf8),
      verifiedEventIdHex: String(repeating: "ab", count: 32) + "\nforged_log_line",
      registryAgreement: { _ in true }, observedAtEpochMillis: 1_000
    )
    XCTAssertEqual(lines, [
      "join_stage event_id=unknown stage=detection outcome=detected attempt=none retry_at_epoch_ms=none",
      "join_stage event_id=unknown stage=envelope_verification outcome=success attempt=none retry_at_epoch_ms=none",
      "join_stage event_id=unknown stage=registry_resolution outcome=rejected_no_registry " +
        "attempt=none retry_at_epoch_ms=none"
    ])
  }

  func testRegistryFailureLogsRetryDeadlineAndRetriesWhenTheClockReachesIt() async throws {
    let eventIdHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    let eventCodeHash = Data([0x6c, 0x86, 0xc6, 0xaa, 0xc5, 0xfb, 0x24, 0xbc])
    var nowEpochMillis: Int64 = 1_800_000_000_000
    let registry = FakeEventJoinRegistry()
    registry.answer = .readFails(errorCode: nil)
    var lines: [String] = []
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinRegistry: registry,
      nearbyDiscoveryClock: { nowEpochMillis },
      joinDiagnosticLog: { lines.append($0) }
    )

    coordinator.handleEventInfoEnvelopeV2(
      peripheralId: "peripheral-a",
      eventDisplayName: "Community night",
      eventCodeHash: eventCodeHash,
      rawContainer: Self.envelopeContainer,
      verifiedEventIdHex: "0x\(eventIdHex)",
      registryAgreement: { _ in true },
      observedAtEpochMillis: nowEpochMillis
    )
    try await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertEqual(registry.requestedEventIdHexes, ["0x\(eventIdHex)"])
    XCTAssertTrue(
      lines.contains(
        "join_stage event_id=00010203 stage=registry_resolution " +
          "outcome=rejected_verification_unavailable attempt=1 " +
          "retry_at_epoch_ms=1800000005000"
      ),
      "diagnostic lines: \(lines)"
    )

    nowEpochMillis += 5_000
    coordinator.refreshNearbyEventDiscovery()
    try await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertEqual(
      registry.requestedEventIdHexes,
      ["0x\(eventIdHex)", "0x\(eventIdHex)"]
    )
    XCTAssertTrue(
      lines.contains(
        "join_stage event_id=00010203 stage=registry_resolution " +
          "outcome=rejected_verification_unavailable attempt=2 " +
          "retry_at_epoch_ms=1800000035000"
      ),
      "diagnostic lines: \(lines)"
    )
    XCTAssertEqual(lines, [
      "join_stage event_id=00010203 stage=detection outcome=detected attempt=none retry_at_epoch_ms=none",
      "join_stage event_id=00010203 stage=envelope_verification outcome=success attempt=none retry_at_epoch_ms=none",
      "join_stage event_id=00010203 stage=registry_resolution outcome=started attempt=1 retry_at_epoch_ms=none",
      "join_stage event_id=00010203 stage=registry_resolution " +
        "outcome=rejected_verification_unavailable attempt=1 retry_at_epoch_ms=1800000005000",
      "join_stage event_id=00010203 stage=registry_resolution outcome=started attempt=2 retry_at_epoch_ms=none",
      "join_stage event_id=00010203 stage=registry_resolution " +
        "outcome=rejected_verification_unavailable attempt=2 retry_at_epoch_ms=1800000035000"
    ])
  }

  // MARK: - Registry definition mapping
  //
  // The values handed to barnard's `registryAgreement` decide whether a
  // candidate is promoted at all, so every rule that builds them is asserted
  // here. Mirrors Android's `barnardIsAskedWithTheDefinitionThisHostRead`.

  func testOpenDefinitionMapsToJoinModeZeroAndCarriesEveryFieldThrough() throws {
    let definition = try XCTUnwrap(
      SensingCoordinator.barnardDefinition(
        eventIdHex: Self.eventIdHex,
        keySetDigestHex: Self.keySetDigestHex,
        eventCodeHashHex: Self.eventCodeHashHex,
        joinMode: .OPEN,
        validFromUnixSeconds: 100,
        validUntilUnixSeconds: 200
      )
    )

    XCTAssertEqual(definition.joinMode, 0)
    XCTAssertEqual(Data(definition.eventId), Data(repeating: 0xab, count: 32))
    XCTAssertEqual(Data(definition.keySetDigest), Data(repeating: 0xcd, count: 32))
    XCTAssertEqual(Data(definition.eventCodeHash), Data(repeating: 0xef, count: 8))
    XCTAssertEqual(definition.validFromUnixSeconds, 100)
    XCTAssertEqual(definition.validUntilUnixSeconds, 200)
  }

  /// The wire value, not an enum ordinal. Barnard derives an open event's
  /// code hash from its event ID and only for `joinMode == 0`, so inverting
  /// this mapping would make agreement answer about the wrong event shape.
  func testGatedDefinitionMapsToJoinModeOne() throws {
    let definition = try XCTUnwrap(
      SensingCoordinator.barnardDefinition(
        eventIdHex: Self.eventIdHex,
        keySetDigestHex: Self.keySetDigestHex,
        eventCodeHashHex: Self.eventCodeHashHex,
        joinMode: .GATED,
        validFromUnixSeconds: 100,
        validUntilUnixSeconds: 200
      )
    )

    XCTAssertEqual(definition.joinMode, 1)
  }

  func testDefinitionWithNoJoinModeYieldsNothing() {
    XCTAssertNil(
      SensingCoordinator.barnardDefinition(
        eventIdHex: Self.eventIdHex,
        keySetDigestHex: Self.keySetDigestHex,
        eventCodeHashHex: Self.eventCodeHashHex,
        joinMode: nil,
        validFromUnixSeconds: 100,
        validUntilUnixSeconds: 200
      )
    )
  }

  /// Every hex field is length-checked, because a short or long value would
  /// otherwise reach barnard as a differently shaped array and make agreement
  /// answer a question nobody asked.
  func testMisSizedOrMalformedHexFieldsYieldNothing() {
    let cases: [(String, String, String?)] = [
      (String(repeating: "ab", count: 31), Self.keySetDigestHex, Self.eventCodeHashHex),
      (String(repeating: "ab", count: 33), Self.keySetDigestHex, Self.eventCodeHashHex),
      (Self.eventIdHex, String(repeating: "cd", count: 31), Self.eventCodeHashHex),
      (Self.eventIdHex, Self.keySetDigestHex, String(repeating: "ef", count: 7)),
      (Self.eventIdHex, Self.keySetDigestHex, String(repeating: "ef", count: 9)),
      (Self.eventIdHex, Self.keySetDigestHex, nil),
      (String(repeating: "zz", count: 32), Self.keySetDigestHex, Self.eventCodeHashHex),
    ]

    for (eventId, keySetDigest, eventCodeHash) in cases {
      XCTAssertNil(
        SensingCoordinator.barnardDefinition(
          eventIdHex: eventId,
          keySetDigestHex: keySetDigest,
          eventCodeHashHex: eventCodeHash,
          joinMode: .OPEN,
          validFromUnixSeconds: 100,
          validUntilUnixSeconds: 200
        ),
        "expected nil for eventId \(eventId.prefix(8)), digest \(keySetDigest.prefix(8)), hash \(eventCodeHash ?? "nil")"
      )
    }
  }

  /// The registry hands these fields back `0x`-prefixed.
  func testPrefixedHexIsAccepted() throws {
    let definition = try XCTUnwrap(
      SensingCoordinator.barnardDefinition(
        eventIdHex: "0x" + Self.eventIdHex,
        keySetDigestHex: "0x" + Self.keySetDigestHex,
        eventCodeHashHex: "0x" + Self.eventCodeHashHex,
        joinMode: .OPEN,
        validFromUnixSeconds: 100,
        validUntilUnixSeconds: 200
      )
    )

    XCTAssertEqual(Data(definition.eventId), Data(repeating: 0xab, count: 32))
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

  /// iOS mirror of Android's
  /// `leaveEventAloneClearsCandidatesWithoutRelyingOnAnExplicitDiscoveryStop`.
  /// Candidates seen before a join are stale once that join is given up, and
  /// clearing them must not depend on a separate discovery-stop call.
  func testLeaveEventAloneClearsNearbyEventCandidates() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.handleEventInfoHint(
      peripheralId: "peripheral-a",
      eventDisplayName: "Community night",
      eventCodeHash: Data([0, 1, 2, 3, 4, 5, 6, 7]),
      census: nil,
      additionalNamesOmitted: false,
      additionalEventsOmitted: false,
      observedAtEpochMillis: 1_000
    )
    XCTAssertEqual(coordinator.nearbyEventCandidates.candidateCount, 1)

    coordinator.leaveEvent()

    XCTAssertEqual(coordinator.nearbyEventCandidates.candidateCount, 0)
  }

  /// Regression guard for the record/schedule clock split: the recorded
  /// observation time and the time the expiry delay is computed against must
  /// be the same value. When they diverge, every delay collapses to zero and
  /// the rearmed refresh expires the hint that was just recorded. The other
  /// discovery tests never suspend, so only an `async` test can observe it.
  func testNearbyCandidateSurvivesTheScheduledExpiryRearm() async throws {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.handleEventInfoHint(
      peripheralId: "peripheral-a",
      eventDisplayName: "Community night",
      eventCodeHash: Data([0, 1, 2, 3, 4, 5, 6, 7]),
      census: nil,
      additionalNamesOmitted: false,
      additionalEventsOmitted: false,
      observedAtEpochMillis: 1_000
    )

    // Long enough for a zero-delay rearm to run to completion, far short of
    // the 300 s TTL a correctly scheduled rearm waits for.
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(coordinator.nearbyEventCandidates.candidateCount, 1)
  }
}

@MainActor
final class OwnerKeyRestorationNoticeTests: XCTestCase {
  func testOwnerKeyFailurePresentationIsRetryableAndDistinctFromResetNotice() {
    let failure = OwnerKeyOperationFailure.unavailable

    XCTAssertEqual(failure.id, "owner-key-unavailable")
    XCTAssertEqual(failure.title, "Proof key is unavailable")
    XCTAssertTrue(failure.message.contains("operations are paused"))
    XCTAssertNotEqual(failure.title, OwnerKeyRestorationNotice.identityWasReset.title)
  }

  func testOwnerKeyFailureAtStartupIsPublishedWithoutRestorationNotice() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("owner-key-operation-failure-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let crypto = StagedOwnerKeyFailureCryptography()
    let coordinator = SensingCoordinator(
      loadingFromDirectory: directory,
      sensingCryptography: crypto,
      ownerKeyRestorationAcknowledgementDefaults: UserDefaults(suiteName: UUID().uuidString)!
    )

    await coordinator.waitForLedgerLoadToFinish()

    XCTAssertEqual(coordinator.ownerKeyOperationFailure, .unavailable)
    XCTAssertNil(coordinator.ownerKeyRestorationNotice)
    XCTAssertEqual(crypto.ownerPublicKeyCallCount, 1)
  }

  func testRetryOwnerKeyOperationClearsFailureWithoutResettingIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("owner-key-operation-retry-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let crypto = StagedOwnerKeyFailureCryptography()
    let coordinator = SensingCoordinator(
      loadingFromDirectory: directory,
      sensingCryptography: crypto,
      ownerKeyRestorationAcknowledgementDefaults: UserDefaults(suiteName: UUID().uuidString)!
    )

    await coordinator.waitForLedgerLoadToFinish()
    crypto.failure = nil
    coordinator.retryOwnerKeyOperation()

    XCTAssertNil(coordinator.ownerKeyOperationFailure)
    XCTAssertGreaterThanOrEqual(crypto.ownerPublicKeyCallCount, 2)
  }

  func testSignalAExplainsThatThePreviousProofIdentityWasLost() {
    let notice = OwnerKeyRestorationNotice.classify(
      quarantinedSeedKey: "beid.ownerKeySeed.quarantine.test",
      ownerPublicKeyMismatchDetected: false
    )

    XCTAssertEqual(notice, .identityWasReset)
    XCTAssertEqual(notice?.title, "Proof identity was reset")
    XCTAssertEqual(
      notice?.message,
      "beid could not restore the identity this device used to sign proofs, so it created a new one. This device can no longer use the previous identity."
    )
  }

  func testSignalBExplainsThatSavedRecordsUseThePreviousIdentity() {
    let notice = OwnerKeyRestorationNotice.classify(
      quarantinedSeedKey: nil,
      ownerPublicKeyMismatchDetected: true
    )

    XCTAssertEqual(notice, .savedRecordsUsePreviousIdentity)
    XCTAssertEqual(notice?.title, "Some proof records use a previous identity")
    XCTAssertEqual(
      notice?.message,
      "Some saved proof records were created with a different identity. They still exist, but this device can no longer sign as that identity."
    )
  }

  func testBothSignalsExplainTheResetAndAffectedRecordsTogether() {
    let notice = OwnerKeyRestorationNotice.classify(
      quarantinedSeedKey: "beid.ownerKeySeed.quarantine.test",
      ownerPublicKeyMismatchDetected: true
    )

    XCTAssertEqual(notice, .identityWasResetWithSavedRecords)
    XCTAssertEqual(notice?.title, "Proof identity could not be restored")
    XCTAssertEqual(
      notice?.message,
      "beid created a new identity because the saved one could not be restored. Some saved proof records still refer to the previous identity; they still exist, but this device can no longer sign as that identity."
    )
  }

  func testNoSignalProducesNoNotice() {
    XCTAssertNil(
      OwnerKeyRestorationNotice.classify(
        quarantinedSeedKey: nil,
        ownerPublicKeyMismatchDetected: false
      )
    )
  }

  func testMismatchNoticeSurvivesBackgroundLoadUntilAcknowledged() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("owner-key-restoration-notice-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let crypto = DeterministicSensingCryptography()
    let defaultsSuiteName = "org.levarac.beid.tests.ownerKeyRestorationNotice.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsSuiteName)!
    addTeardownBlock { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let bindingStore = BindingRecordStore(
      fileURL: directory.appendingPathComponent("binding-records.json")
    )
    bindingStore.add(makeBindingRecord(ownerPublicKey: Data(repeating: 0x09, count: 33)))

    let coordinator = SensingCoordinator(
      loadingFromDirectory: directory,
      sensingCryptography: crypto,
      ownerKeyRestorationAcknowledgementDefaults: defaults
    )

    XCTAssertNil(coordinator.ownerKeyRestorationNotice)

    await coordinator.waitForLedgerLoadToFinish()

    XCTAssertEqual(
      coordinator.ownerKeyRestorationNotice,
      .savedRecordsUsePreviousIdentity,
      "the startup warning must remain available after the asynchronous load reaches the UI"
    )

    coordinator.acknowledgeOwnerKeyRestorationNotice()

    XCTAssertNil(
      coordinator.ownerKeyRestorationNotice,
      "the explicit acknowledgement must deterministically clear the warning"
    )

    let relaunchedCoordinator = SensingCoordinator(
      loadingFromDirectory: directory,
      sensingCryptography: DeterministicSensingCryptography(),
      ownerKeyRestorationAcknowledgementDefaults: defaults
    )
    await relaunchedCoordinator.waitForLedgerLoadToFinish()

    XCTAssertNil(
      relaunchedCoordinator.ownerKeyRestorationNotice,
      "an acknowledged warning must not interrupt the user again on every launch while the same current identity remains active"
    )
  }

  func testSignalAIsCapturedAfterOwnerKeyResolutionQuarantinesTheSeed() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("owner-key-restoration-signal-a-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let defaultsSuiteName = "org.levarac.beid.tests.ownerKeyRestorationSignalA.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsSuiteName)!
    addTeardownBlock { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    defaults.set("unreadable-owner-key-seed", forKey: "beid.ownerKeySeed")

    let ownerKeyProvider = OwnerKeyProvider(
      keyStorage: BeidUserDefaultsKeyStorage(defaults: defaults),
      randomSource: FixedOwnerKeyRandomSource()
    )
    let coordinator = SensingCoordinator(
      loadingFromDirectory: directory,
      sensingCryptography: BarnardSensingCryptography(ownerKeyProvider: ownerKeyProvider),
      ownerKeyRestorationAcknowledgementDefaults: defaults
    )

    await coordinator.waitForLedgerLoadToFinish()

    XCTAssertEqual(
      coordinator.ownerKeyRestorationNotice,
      .identityWasReset,
      "Signal A must be read after owner-key resolution has had the chance to quarantine and replace an unreadable seed"
    )
  }

  private func makeBindingRecord(ownerPublicKey: Data) -> BindingRecord {
    BindingRecord(
      proofId: UUID(),
      eventCode: "TEST-EVENT",
      walletAddress: "0x0000000000000000000000000000000000000001",
      eventSigningPublicKey: Data(repeating: 0x02, count: 33),
      ownerPublicKey: ownerPublicKey,
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
  }
}

private final class StagedOwnerKeyFailureCryptography: SensingCryptography {
  var failure: OwnerKeyOperationError? = .storage(.readFailed(errSecInteractionNotAllowed))
  private(set) var ownerPublicKeyCallCount = 0

  func eventSigningPublicKey(eventCode: String) -> Data { Data([0x02] + [UInt8](repeating: 0x01, count: 32)) }
  func ownerPublicKey() throws -> Data {
    ownerPublicKeyCallCount += 1
    if let failure { throw failure }
    return Data([0x03] + [UInt8](repeating: 0x02, count: 32))
  }
  func signWindowReport(eventCode: String, bytes: Data) -> SensingRecoverableSignature {
    SensingRecoverableSignature(r: Data(repeating: 0, count: 32), s: Data(repeating: 0, count: 32), v: 0)
  }
  func signSelfProof(eventIdHash: Data, eventSigningPublicKey: Data, eninStart: UInt64, eninEnd: UInt64) throws -> SensingRecoverableSignature? { nil }
  func signWalletAcknowledgement(walletAddress: Data, walletSignature: Data) throws -> SensingRecoverableSignature? { nil }
}

private struct FixedOwnerKeyRandomSource: BarnardCoreRandomSource, OwnerKeyRandomBytesGenerating {
  func randomBytes(count: Int) -> [UInt8] {
    [UInt8](repeating: 0x42, count: count)
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

  func excludedWindowCount(forEventCode _: String) -> Int { 0 }
}

private extension Data {
  /// Mirrors the file-private helper of the same name in
  /// `ReportSubmissionRuntime.swift` and
  /// `ReportSubmissionOperatorIntegrationTests.swift`. Each copy is
  /// file-private, so this file needs its own to read a Kotlin `ByteArray`
  /// out of a published discovery snapshot.
  init(bytesFromKotlinByteArray bytes: ExportedKotlinPackages.kotlin.ByteArray) {
    self.init((0..<Int(bytes.size)).map { index in
      UInt8(bitPattern: bytes[Int32(index)])
    })
  }
}
