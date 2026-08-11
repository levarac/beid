// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import XCTest
@testable import Beid

/// beid#166 Phase 2 — `SensingCoordinator`'s session-end hook
/// (`persistSessionAggregateSnapshotIfNeeded()`, called from `endSensing(stopEngine:)`
/// alongside `finalizeSelfProofIfNeeded()`) that calls Phase 1's already-merged
/// `SessionAggregateSnapshotStore.persist(aggregate:proofId:)`. Gated on the
/// same `activeProofId`/`sessionAggregate` shape `finalizeSelfProofIfNeeded()`
/// uses, for the same reason: beid#166's Class-C invariant is that a snapshot
/// is produced once, at session end, only for sessions that produced a
/// `Proof`. `SessionAggregateSnapshotStoreTests` covers the store itself in
/// depth; this file covers only the coordinator's call into it.
@MainActor
final class SessionAggregateSnapshotPersistHookTests: XCTestCase {
  private func makeCoordinator() -> (SensingCoordinator, SessionAggregateSnapshotStore) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-aggregate-persist-hook-test-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      preconditionFailure("Unable to create test directory: \(error)")
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let store = SessionAggregateSnapshotStore(
      fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
    )
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
      sessionAggregateSnapshotStore: store,
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: DeterministicSensingCryptography()
    )
    coordinator.useDemoEventMode = false
    return (coordinator, store)
  }

  func testPersistsSessionAggregateSnapshotOnSessionEndWhenAProofExists() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-PERSIST-HOOK-WITH-PROOF")

    var collectedProofId: UUID?
    coordinator.onProofCollected = { proof in collectedProofId = proof.id }

    let threshold = BeidConfig.eventConfirmThreshold
    for device in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: 1),
        detectedDisplayId: DetectionFixture.displayId(device: device)
      )
    }
    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording, got \(coordinator.phase)")
      return
    }
    guard let proofId = collectedProofId else {
      XCTFail("onProofCollected never fired")
      return
    }
    let expectedDeviceCount = coordinator.sessionAggregate?.deviceCount

    coordinator.stopSensing()

    let snapshot = store.snapshot(proofId: proofId)
    XCTAssertNotNil(snapshot, "a session that produced a Proof must have a persisted snapshot")
    XCTAssertEqual(Int(snapshot?.deviceCount ?? -1), Int(expectedDeviceCount ?? -1))
    XCTAssertEqual(store.records.count, 1)
  }

  func testDoesNotPersistASnapshotWhenNoProofWasEverCreated() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-PERSIST-HOOK-NO-PROOF")

    // One fewer device than `eventConfirmThreshold`, so the session never
    // reaches `.recording` and `activeProofId` stays `nil` — mirrors
    // `finalizeSelfProofIfNeeded()`'s own "no Proof, no self-proof" gate,
    // which this hook deliberately reuses (see this file's own doc comment).
    let threshold = BeidConfig.eventConfirmThreshold
    for device in 0..<(threshold - 1) {
      coordinator.handleDetection(
        enin: 1,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: 1),
        detectedDisplayId: DetectionFixture.displayId(device: device)
      )
    }
    guard case .eventFound = coordinator.phase else {
      XCTFail("expected .eventFound (not yet confirmed), got \(coordinator.phase)")
      return
    }

    coordinator.stopSensing()

    XCTAssertTrue(store.records.isEmpty, "no Proof means nothing to snapshot")
  }

  func testSessionEndSurvivesAPersistFailureWithoutCrashingOrLosingTheExistingRecord() throws {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-PERSIST-HOOK-FAILURE")

    var collectedProofId: UUID?
    coordinator.onProofCollected = { proof in collectedProofId = proof.id }

    let threshold = BeidConfig.eventConfirmThreshold
    for device in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: 1),
        detectedDisplayId: DetectionFixture.displayId(device: device)
      )
    }
    let proofId = try XCTUnwrap(collectedProofId, "onProofCollected never fired")

    // Pre-seed a conflicting record for this exact proofId with a real but
    // distinct aggregate (a different window index changes the encoded
    // window series — see `SessionAggregateSnapshotStoreTests`'s own
    // `testASnapshotIsImmutableOnceWrittenAndRejectsADifferingResubmission`).
    // The store's immutability contract then guarantees
    // `persistSessionAggregateSnapshotIfNeeded()`'s call at session end
    // throws `.conflictingSnapshot`, exercising the hook's failure path
    // deterministically without a mock/fake store.
    let seededInput = BeidSharedKit.aggregation.createAggregationObservationInput()
    _ = BeidSharedKit.aggregation.addAggregationObservation(
      input: seededInput,
      windowIndex: 999,
      peerKey: "seed-peer",
      displayId: "seed-device",
      mutual: false
    )
    let seededAggregate = BeidSharedKit.aggregation.aggregateObservationsForSession(
      input: seededInput,
      windowsPerBand: 4
    )
    try store.persist(aggregate: seededAggregate, proofId: proofId)

    // One more real observation, so this session's own final aggregate at
    // stop time differs from the seeded one above and the persist call at
    // session end genuinely conflicts rather than being an idempotent no-op.
    coordinator.handleDetection(
      enin: 1,
      rpid: DetectionFixture.rotatingRpid(device: threshold, enin: 1),
      detectedDisplayId: DetectionFixture.displayId(device: threshold)
    )

    // Must not crash/throw out of `stopSensing()` despite the persist
    // failure — session-end teardown (self-proof, window close, phase
    // reset) must still complete.
    coordinator.stopSensing()

    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertEqual(store.records.count, 1, "the pre-existing record must survive untouched")
    XCTAssertEqual(store.snapshot(proofId: proofId)?.windowAt(index: 0)?.windowIndex, 999)
  }
}
