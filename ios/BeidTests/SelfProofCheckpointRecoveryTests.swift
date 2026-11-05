// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BarnardCore
import XCTest
@testable import Beid

/// `SensingCoordinator`'s self-proof crash-recovery checkpoint
/// (`docs/specs/session-end-finalization.md` §7.1 Option B, §8.3, sub-slice
/// 3). Golden-vector discipline (`barnard-binding-conformance.md` §5): the
/// signing call itself (`OwnerKeyProvider.signSelfProof`/
/// `BarnardCoreSigning.buildSelfProofMessage`) is already covered by
/// `SelfProofMessageLayoutTests`/`OwnerKeyProviderSelfProofTests` and is not
/// re-tested here. What these tests cover is the reconciliation *path*:
/// given a checkpoint file with known `eninStart`/`eninEnd`, reconciliation
/// (run once, at `SensingCoordinator.init`) produces a `SelfProofRecord`
/// whose signature verifies via Barnard's own `BarnardCoreSigning
/// .verifySelfProof` — same pattern
/// `OwnerKeyProviderSelfProofTests.testSignSelfProofProducesABarnardVerifiableSignature`
/// already establishes, exercised through the new reconciliation call site
/// instead of the direct `stopSensing()` path.
@MainActor
final class SelfProofCheckpointRecoveryTests: XCTestCase {
  func testNextSessionPreservesFailedSelfProofAfterStopWhenWriterRecovers() throws {
    try assertFailedSessionRecoverySurvivesNextSession(writerRecovers: true, endWithReset: false)
  }

  func testNextSessionPreservesFailedSelfProofAfterStopWhileWriterStillFails() throws {
    try assertFailedSessionRecoverySurvivesNextSession(writerRecovers: false, endWithReset: false)
  }

  func testNextSessionPreservesFailedSelfProofAfterResetWhenWriterRecovers() throws {
    try assertFailedSessionRecoverySurvivesNextSession(writerRecovers: true, endWithReset: true)
  }

  func testNextSessionPreservesFailedSelfProofAfterResetWhileWriterStillFails() throws {
    try assertFailedSessionRecoverySurvivesNextSession(writerRecovers: false, endWithReset: true)
  }

  private func assertFailedSessionRecoverySurvivesNextSession(
    writerRecovers: Bool,
    endWithReset: Bool
  ) throws {
    let directory = makeTemporaryDirectory()
    let selfProofURL = directory.appendingPathComponent("self-proofs.json")
    let checkpointURL = directory.appendingPathComponent("checkpoint.json")
    var shouldFail = true
    let store = SelfProofStore(fileURL: selfProofURL, writeData: { data, url in
      if shouldFail { throw CocoaError(.fileWriteNoPermission) }
      try data.write(to: url, options: .atomic)
    })
    let sensing = recoveryCoordinator(directory: directory, store: store, checkpointURL: checkpointURL)
    sensing.useDemoEventMode = false

    func recordSession(eventCode: String, firstWindow: Int) {
      sensing.startSensing(eventCode: eventCode)
      for index in 0..<BeidConfig.eventConfirmThreshold {
        sensing.handleDetection(
          enin: firstWindow, rpid: "example-peer-\(index)",
          detectedDisplayId: DetectionFixture.displayId(device: index))
      }
      sensing.handleDetection(
        enin: firstWindow + 1, rpid: "example-later-peer",
        detectedDisplayId: DetectionFixture.displayId(device: BeidConfig.eventConfirmThreshold))
    }

    func endSession() -> SelfProofRecord? {
      endWithReset ? sensing.reset() : sensing.stopSensing()
    }

    func assertRecoverable(_ proofID: UUID, checkpoint expectedCheckpoint: SelfProofCheckpoint? = nil) {
      let durable = SelfProofStore(fileURL: selfProofURL).durableRecord(forProofId: proofID)
      let checkpoint = SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint
      XCTAssertTrue(durable != nil || checkpoint?.proofId == proofID,
                    "each ended session needs its durable self-proof or its own recovery input")
      if durable == nil, let expectedCheckpoint {
        XCTAssertEqual(checkpoint, expectedCheckpoint, "a pending session's saved range must survive intact")
      }
    }

    recordSession(eventCode: "EXAMPLE-SESSION-A", firstWindow: 10)
    let firstID = try XCTUnwrap(sensing.currentProofID)
    XCTAssertNil(endSession())
    XCTAssertNil(sensing.currentProofID)
    XCTAssertNil(SelfProofStore(fileURL: selfProofURL).durableRecord(forProofId: firstID))
    let firstCheckpoint = try XCTUnwrap(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint)
    XCTAssertEqual(firstCheckpoint.proofId, firstID)
    XCTAssertEqual(firstCheckpoint.eninStart, 10)
    XCTAssertEqual(firstCheckpoint.eninEnd, 11)

    // Attempt the next session on the same live object, without launch recovery.
    shouldFail = !writerRecovers
    recordSession(eventCode: "EXAMPLE-SESSION-B", firstWindow: 20)
    var secondID = sensing.currentProofID
    if writerRecovers {
      XCTAssertNotNil(secondID, "a healthy writer must allow the next session after preserving the first")
    }
    if let secondID { XCTAssertNotEqual(secondID, firstID) }
    assertRecoverable(firstID, checkpoint: firstCheckpoint)
    _ = endSession()
    assertRecoverable(firstID, checkpoint: firstCheckpoint)
    if let secondID {
      assertRecoverable(secondID)
    }

    shouldFail = false
    if secondID == nil {
      // A refused session can be attempted again once persistence recovers.
      recordSession(eventCode: "EXAMPLE-SESSION-B", firstWindow: 20)
      secondID = try XCTUnwrap(sensing.currentProofID)
      XCTAssertNotNil(endSession())
    }
    _ = recoveryCoordinator(directory: directory, store: SelfProofStore(fileURL: selfProofURL),
                            checkpointURL: checkpointURL)
    let reopened = SelfProofStore(fileURL: selfProofURL)
    XCTAssertNotNil(reopened.durableRecord(forProofId: firstID))
    if let secondID { XCTAssertNotNil(reopened.durableRecord(forProofId: secondID)) }
    XCTAssertEqual(Set(reopened.records.map(\.proofId)).count, reopened.records.count)
  }

  func testInjectedSaveFailuresKeepRecoveryInputUntilDurableRetry() throws {
    for failEncoding in [true, false] {
      for hasExisting in [true, false] {
        let directory = makeTemporaryDirectory()
        let selfProofURL = directory.appendingPathComponent("self-proofs.json")
        let checkpointURL = directory.appendingPathComponent("checkpoint.json")
        if hasExisting {
          SelfProofCheckpointStore(fileURL: checkpointURL).save(
            SelfProofCheckpoint(proofId: UUID(), eventCode: "EXAMPLE-OLD", eninStart: 1, eninEnd: 2))
          _ = recoveryCoordinator(directory: directory, store: SelfProofStore(fileURL: selfProofURL),
                                  checkpointURL: checkpointURL)
        }
        let existing = SelfProofStore(fileURL: selfProofURL).records
        let checkpoint = SelfProofCheckpoint(proofId: UUID(), eventCode: "EXAMPLE-RETRY",
                                             eninStart: 3, eninEnd: 4)
        SelfProofCheckpointStore(fileURL: checkpointURL).save(checkpoint)
        var shouldFail = true
        let store = SelfProofStore(
          fileURL: selfProofURL,
          encodeRecords: { records in
            if shouldFail && failEncoding { throw CocoaError(.coderInvalidValue) }
            return try RecordSchemaEnvelope.encodeRecords(records)
          },
          writeData: { data, url in
            if shouldFail && !failEncoding { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
          }
        )
        for _ in 0..<2 {
          _ = recoveryCoordinator(directory: directory, store: store, checkpointURL: checkpointURL)
          XCTAssertNotNil(store.lastPersistenceError)
          XCTAssertEqual(store.records, existing)
          XCTAssertEqual(SelfProofStore(fileURL: selfProofURL).records, existing)
          XCTAssertEqual(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint?.proofId,
                         checkpoint.proofId)
        }
        shouldFail = false
        _ = recoveryCoordinator(directory: directory, store: store, checkpointURL: checkpointURL)
        XCTAssertNil(store.lastPersistenceError)
        let saved = try XCTUnwrap(store.record(forProofId: checkpoint.proofId))
        XCTAssertTrue(store.add(saved))
        XCTAssertTrue(store.add(saved))
        XCTAssertEqual(SelfProofStore(fileURL: selfProofURL).records.count, existing.count + 1)
        XCTAssertNil(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint)
      }
    }
  }

  func testSuspendedStoreCannotClearCheckpointUsingItsInMemoryFallback() throws {
    let directory = makeTemporaryDirectory()
    let selfProofURL = directory.appendingPathComponent("self-proofs.json")
    let checkpointURL = directory.appendingPathComponent("checkpoint.json")
    try FileManager.default.createDirectory(at: selfProofURL, withIntermediateDirectories: false)
    let checkpoint = SelfProofCheckpoint(proofId: UUID(), eventCode: "EXAMPLE-SUSPENDED",
                                         eninStart: 1, eninEnd: 2)
    SelfProofCheckpointStore(fileURL: checkpointURL).save(checkpoint)
    let store = SelfProofStore(fileURL: selfProofURL)
    for _ in 0..<2 {
      _ = recoveryCoordinator(directory: directory, store: store, checkpointURL: checkpointURL)
      XCTAssertTrue(store.isPersistenceSuspended)
      XCTAssertNotNil(store.lastPersistenceError)
      XCTAssertEqual(store.records.count, 1)
      XCTAssertNil(store.durableRecord(forProofId: checkpoint.proofId))
      XCTAssertNotNil(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint)
    }
    try FileManager.default.removeItem(at: selfProofURL)
    _ = recoveryCoordinator(directory: directory, store: SelfProofStore(fileURL: selfProofURL),
                            checkpointURL: checkpointURL)
    XCTAssertEqual(SelfProofStore(fileURL: selfProofURL).records.count, 1)
    XCTAssertNil(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint)
  }

  func testFinalizationFailureKeepsCheckpointAndDoesNotReturnASavedRecord() throws {
    let directory = makeTemporaryDirectory()
    let selfProofURL = directory.appendingPathComponent("self-proofs.json")
    let checkpointURL = directory.appendingPathComponent("checkpoint.json")
    let store = SelfProofStore(fileURL: selfProofURL,
                              writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    let sensing = recoveryCoordinator(directory: directory, store: store, checkpointURL: checkpointURL)
    sensing.useDemoEventMode = false
    sensing.startSensing(eventCode: "EXAMPLE-STOP")
    for index in 0..<BeidConfig.eventConfirmThreshold {
      sensing.handleDetection(enin: 1, rpid: "peer-\(index)",
                              detectedDisplayId: DetectionFixture.displayId(device: index))
    }
    XCTAssertNil(sensing.stopSensing())
    XCTAssertNotNil(store.lastPersistenceError)
    XCTAssertNotNil(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint)
    _ = recoveryCoordinator(directory: directory, store: SelfProofStore(fileURL: selfProofURL),
                            checkpointURL: checkpointURL)
    XCTAssertEqual(SelfProofStore(fileURL: selfProofURL).records.count, 1)
    XCTAssertNil(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint)
  }
  func testMissingUnsavedRecordDismissesWithoutSealedClaimAndKeepsSelfRecovery() throws {
    for suspended in [false, true] {
    let directory = makeTemporaryDirectory()
    let selfProofURL = directory.appendingPathComponent("self-proofs.json")
    let checkpointURL = directory.appendingPathComponent("checkpoint.json")
    let proofURL = directory.appendingPathComponent("proofs.json")
    if suspended {
      try FileManager.default.createDirectory(at: proofURL, withIntermediateDirectories: false)
    }
    let proofStore = ProofStore(fileURL: proofURL,
                                writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    let selfStore = SelfProofStore(fileURL: selfProofURL,
                                   writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    let sensing = recoveryCoordinator(directory: directory, store: selfStore, checkpointURL: checkpointURL)
    let suiteName = "beid.persistence-test.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let app = AppCoordinator(proofStore: proofStore, sensingCoordinator: sensing,
                             registryClient: nil, userDefaults: defaults)
    app.scanPresented = true
    sensing.useDemoEventMode = false
    sensing.startSensing(eventCode: "EXAMPLE-UNSAVED")
    for index in 0..<BeidConfig.eventConfirmThreshold {
      sensing.handleDetection(enin: 1, rpid: "peer-\(index)",
                              detectedDisplayId: DetectionFixture.displayId(device: index))
    }
    let proofID = try XCTUnwrap(sensing.currentProofID)
    XCTAssertNil(proofStore.proof(withId: proofID))
    XCTAssertNotNil(proofStore.lastPersistenceError)
    app.requestScanClose()
    XCTAssertFalse(app.scanPresented)
    XCTAssertNil(app.sealedSnapshot)
    XCTAssertNil(app.proofCollectedSnapshot)
    XCTAssertNotNil(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint)
    _ = recoveryCoordinator(directory: directory, store: SelfProofStore(fileURL: selfProofURL),
                            checkpointURL: checkpointURL)
    XCTAssertEqual(SelfProofStore(fileURL: selfProofURL).records.first?.proofId, proofID)
    }
  }

  func testOwnerIdentityAndLegacyRecordLinkageSurviveReconstruction() throws {
    let directory = makeTemporaryDirectory()
    let seedURL = directory.appendingPathComponent("example-seed")
    try Data((0..<32).map(UInt8.init)).write(to: seedURL, options: .atomic)
    let selfProofURL = directory.appendingPathComponent("self-proofs.json")
    let proofURL = directory.appendingPathComponent("proofs.json")
    let bindingURL = directory.appendingPathComponent("bindings.json")
    let checkpointURL = directory.appendingPathComponent("checkpoint.json")
    let proof = Proof(eventName: "Example event", date: Date(timeIntervalSince1970: 123),
                      peersVerified: 2, eventCode: "EXAMPLE-RESTART")
    XCTAssertTrue(ProofStore(fileURL: proofURL).add(proof))
    let before = BarnardBackedSelfProofCryptography(keyStorage: FileSeedKeyStorage(fileURL: seedURL))
    let ownerKey = try before.ownerPublicKey()
    let eventKey = before.eventSigningPublicKey(eventCode: "EXAMPLE-RESTART")
    let binding = BindingRecord(
      proofId: proof.id, eventCode: "EXAMPLE-RESTART",
      walletAddress: "0x" + String(repeating: "00", count: 20),
      eventSigningPublicKey: eventKey, ownerPublicKey: ownerKey, chainId: 1,
      nonce: Data(repeating: 0, count: 16), issuedAt: "2000-01-01T00:00:00Z",
      walletSignatureHex: String(repeating: "00", count: 65),
      deviceSignature: BarnardCoreRecoverableSignature(
        r: [UInt8](repeating: 1, count: 32), s: [UInt8](repeating: 2, count: 32), v: 0))
    BindingRecordStore(fileURL: bindingURL).add(binding)
    SelfProofCheckpointStore(fileURL: checkpointURL).save(
      SelfProofCheckpoint(proofId: proof.id, eventCode: "EXAMPLE-RESTART", eninStart: 1, eninEnd: 2))
    let after = BarnardBackedSelfProofCryptography(keyStorage: FileSeedKeyStorage(fileURL: seedURL))
    XCTAssertEqual(try after.ownerPublicKey(), ownerKey)
    _ = recoveryCoordinator(directory: directory, store: SelfProofStore(fileURL: selfProofURL),
                            checkpointURL: checkpointURL, cryptography: after)
    let restored = try XCTUnwrap(SelfProofStore(fileURL: selfProofURL).durableRecord(forProofId: proof.id))
    XCTAssertEqual(ProofStore(fileURL: proofURL).proofs, [proof])
    XCTAssertEqual(BindingRecordStore(fileURL: bindingURL).record(forProofId: proof.id), binding)
    XCTAssertEqual(restored.ownerPublicKeyHex, binding.ownerPublicKeyHex)
    XCTAssertEqual(restored.eventSigningPublicKeyHex, binding.eventSigningPublicKeyHex)
    XCTAssertTrue(BarnardCoreSigning.verifySelfProof(
      eventIdHash: Array(bytesFromHex(restored.eventIdHashHex)),
      eventSigningPublicKey: bytesFromHex(restored.eventSigningPublicKeyHex),
      eninStart: restored.eninStart, eninEnd: restored.eninEnd,
      ownerPublicKey: bytesFromHex(restored.ownerPublicKeyHex),
      signature: BarnardCoreRecoverableSignature(r: bytesFromHex(restored.signatureRHex),
                                               s: bytesFromHex(restored.signatureSHex),
                                               v: restored.signatureV)))
  }
  func testFailedReconciliationKeepsCheckpointAcrossReopenAndRepeatedRetries() throws {
    let directory = makeTemporaryDirectory()
    let selfProofURL = directory.appendingPathComponent("self-proofs.json")
    let checkpointURL = directory.appendingPathComponent("checkpoint.json")
    let checkpoint = SelfProofCheckpoint(proofId: UUID(), eventCode: "RECOVERY", eninStart: 1, eninEnd: 2)
    SelfProofCheckpointStore(fileURL: checkpointURL).save(checkpoint)
    let store = SelfProofStore(fileURL: selfProofURL)
    try FileManager.default.createDirectory(at: selfProofURL, withIntermediateDirectories: false)
    for _ in 0..<2 {
      _ = recoveryCoordinator(directory: directory, store: store, checkpointURL: checkpointURL)
      XCTAssertNotNil(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint,
                      "a failed save must keep the sole durable recovery input, even after retry")
    }
    try FileManager.default.removeItem(at: selfProofURL)
    _ = recoveryCoordinator(directory: directory, store: SelfProofStore(fileURL: selfProofURL),
                            checkpointURL: checkpointURL)
    let reloaded = SelfProofStore(fileURL: selfProofURL)
    XCTAssertEqual(reloaded.records.count, 1)
    XCTAssertEqual(reloaded.records.first?.proofId, checkpoint.proofId)
    XCTAssertNil(SelfProofCheckpointStore(fileURL: checkpointURL).checkpoint)
  }

  private func recoveryCoordinator(directory: URL, store: SelfProofStore,
                                   checkpointURL: URL,
                                   cryptography: any SensingCryptography = DeterministicSensingCryptography())
    -> SensingCoordinator {
    SensingCoordinator(
      windowReportStore: WindowReportStore(fileURL: directory.appendingPathComponent("windows.json")),
      selfProofStore: store,
      selfProofCheckpointStore: SelfProofCheckpointStore(fileURL: checkpointURL),
      bindingRecordStore: BindingRecordStore(fileURL: directory.appendingPathComponent("bindings.json")),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: directory.appendingPathComponent("aggregates.json")),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: cryptography
    )
  }

  func testReconciliationRecoversASelfProofAfterASimulatedCrashMidSession() throws {
    let directory = makeTemporaryDirectory()
    let windowReportFileURL = directory.appendingPathComponent("window-reports.json")
    let selfProofFileURL = directory.appendingPathComponent("self-proofs.json")
    let checkpointFileURL = directory.appendingPathComponent("self-proof-checkpoint.json")
    let ledgerFileURL = directory.appendingPathComponent("ledger.snapshot")
    let cryptography = BarnardBackedSelfProofCryptography()
    // Not asserted against a literal: on the real (non-demo) detection path,
    // `handleDetection`'s `.sensing` branch resolves the session's event
    // code from `engine.getCurrentEventCode()` (falling back to
    // "Unknown Event"), not from whatever string was passed to
    // `startSensing(eventCode:)` — `engine.configure(eventCode:)` only runs
    // once `requestPermissions`'s async completion lands, which this test's
    // synchronous `handleDetection` calls run ahead of. Reading the actual
    // value back from `coordinator.phase` keeps this test correct regardless
    // of that timing, since reconciliation's job is to reproduce whatever
    // event code the checkpoint actually captured, not one implied by the
    // call the app happened to make.
    var eventCode = ""

    // Before the crash: a real session reaches .recording (a wallet binding
    // would ordinarily follow, but nothing about reconciliation depends on
    // that — only on activeProofId/currentBindingEvent, which .recording
    // alone already sets) and crosses one window boundary, then is
    // abandoned without ever calling stopSensing()/reset() — simulating a
    // device kill after the point self-proof state becomes checkpointable.
    do {
      let coordinator = SensingCoordinator(
        windowReportStore: WindowReportStore(fileURL: windowReportFileURL),
        selfProofStore: SelfProofStore(fileURL: selfProofFileURL),
        selfProofCheckpointStore: SelfProofCheckpointStore(fileURL: checkpointFileURL),
        bindingRecordStore: BindingRecordStore(
          fileURL: directory.appendingPathComponent("binding-records.json")
        ),
        sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
          fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
        ),
        unsentWindowLedgerFileURL: ledgerFileURL,
        sensingCryptography: cryptography
      )
      coordinator.useDemoEventMode = false
      coordinator.startSensing(eventCode: "TEST-CHECKPOINT-RECOVERY")

      let threshold = BeidConfig.eventConfirmThreshold
      for index in 0..<threshold {
        coordinator.handleDetection(
          enin: 1,
          rpid: "peer-\(index)",
          detectedDisplayId: DetectionFixture.displayId(device: index)
        )
      }
      guard case .recording(let session, _) = coordinator.phase else {
        XCTFail("expected .recording phase before the simulated crash, got \(coordinator.phase)")
        return
      }
      eventCode = session.id

      // Rotate into a second window so eninEnd advances past eninStart —
      // this is the write this test is really about: it happens from
      // inside advanceWindowBookkeepingIfNeeded/openNewWindowState, on the
      // real detection path, with no new lifecycle hook.
      coordinator.handleDetection(
        enin: 2,
        rpid: "peer-late",
        detectedDisplayId: DetectionFixture.displayId(device: threshold)
      )
      // Deliberately no stopSensing()/reset() call here.
    }

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: checkpointFileURL.path),
      "a checkpoint must have been written mid-session, before the simulated crash"
    )
    XCTAssertTrue(
      SelfProofStore(fileURL: selfProofFileURL).records.isEmpty,
      "no self-proof exists yet — the simulated crash happened before session end"
    )

    // After relaunch: a fresh SensingCoordinator over the same on-device
    // files reconciles the surviving checkpoint at init.
    _ = SensingCoordinator(
      windowReportStore: WindowReportStore(fileURL: windowReportFileURL),
      selfProofStore: SelfProofStore(fileURL: selfProofFileURL),
      selfProofCheckpointStore: SelfProofCheckpointStore(fileURL: checkpointFileURL),
      bindingRecordStore: BindingRecordStore(
        fileURL: directory.appendingPathComponent("binding-records.json")
      ),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
      ),
      unsentWindowLedgerFileURL: ledgerFileURL,
      sensingCryptography: cryptography
    )

    let recoveredStore = SelfProofStore(fileURL: selfProofFileURL)
    guard let record = recoveredStore.records.first else {
      XCTFail("expected reconciliation to recover a self-proof from the surviving checkpoint")
      return
    }
    XCTAssertEqual(recoveredStore.records.count, 1)
    XCTAssertEqual(record.eventCode, eventCode)
    XCTAssertEqual(record.eninStart, 1)
    XCTAssertEqual(record.eninEnd, 2)

    XCTAssertTrue(
      BarnardCoreSigning.verifySelfProof(
        eventIdHash: Array(bytesFromHex(record.eventIdHashHex)),
        eventSigningPublicKey: bytesFromHex(record.eventSigningPublicKeyHex),
        eninStart: record.eninStart,
        eninEnd: record.eninEnd,
        ownerPublicKey: bytesFromHex(record.ownerPublicKeyHex),
        signature: BarnardCoreRecoverableSignature(
          r: bytesFromHex(record.signatureRHex),
          s: bytesFromHex(record.signatureSHex),
          v: record.signatureV
        )
      ),
      "the reconciled self-proof must verify via Barnard's own verifier, not beid's re-derivation"
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: checkpointFileURL.path),
      "the checkpoint must be cleared once reconciliation produces the real record"
    )
  }

  func testReconciliationIsANoOpWhenNoCheckpointExists() {
    let directory = makeTemporaryDirectory()
    let selfProofFileURL = directory.appendingPathComponent("self-proofs.json")
    let checkpointFileURL = directory.appendingPathComponent("self-proof-checkpoint.json")

    XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointFileURL.path))

    _ = SensingCoordinator(
      windowReportStore: WindowReportStore(
        fileURL: directory.appendingPathComponent("window-reports.json")
      ),
      selfProofStore: SelfProofStore(fileURL: selfProofFileURL),
      selfProofCheckpointStore: SelfProofCheckpointStore(fileURL: checkpointFileURL),
      bindingRecordStore: BindingRecordStore(
        fileURL: directory.appendingPathComponent("binding-records.json")
      ),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
      ),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: DeterministicSensingCryptography()
    )

    XCTAssertTrue(
      SelfProofStore(fileURL: selfProofFileURL).records.isEmpty,
      "no checkpoint ever existed — reconciliation must not fabricate a record"
    )
  }

  func testReconciliationIsANoOpWhenAMatchingSelfProofRecordAlreadyExists() {
    let directory = makeTemporaryDirectory()
    let selfProofFileURL = directory.appendingPathComponent("self-proofs.json")
    let checkpointFileURL = directory.appendingPathComponent("self-proof-checkpoint.json")
    let proofId = UUID()
    let eventCode = "TEST-ALREADY-RECONCILED"

    // Simulates a graceful session end that already produced the real
    // record, immediately followed by a crash before the checkpoint's own
    // clear() write could land — the exact race finalizeSelfProofIfNeeded()
    // clearing the checkpoint is meant to make vanishingly rare, not
    // impossible.
    let existingRecord = SelfProofRecord(
      proofId: proofId,
      eventCode: eventCode,
      eventIdHash: Data(repeating: 0xAB, count: 32),
      eventSigningPublicKey: Data(bytesFromHex(
        "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
      )),
      eninStart: 1,
      eninEnd: 2,
      ownerPublicKey: Data(bytesFromHex(
        "03879beac8b548009124867a99a358aeb34ff42f957f868bbc83339568b16d9c67"
      )),
      signature: BarnardCoreRecoverableSignature(
        r: [UInt8](repeating: 1, count: 32),
        s: [UInt8](repeating: 2, count: 32),
        v: 0
      )
    )
    SelfProofStore(fileURL: selfProofFileURL).add(existingRecord)
    SelfProofCheckpointStore(fileURL: checkpointFileURL).save(
      SelfProofCheckpoint(proofId: proofId, eventCode: eventCode, eninStart: 1, eninEnd: 2)
    )

    _ = SensingCoordinator(
      windowReportStore: WindowReportStore(
        fileURL: directory.appendingPathComponent("window-reports.json")
      ),
      selfProofStore: SelfProofStore(fileURL: selfProofFileURL),
      selfProofCheckpointStore: SelfProofCheckpointStore(fileURL: checkpointFileURL),
      bindingRecordStore: BindingRecordStore(
        fileURL: directory.appendingPathComponent("binding-records.json")
      ),
      sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
        fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
      ),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: DeterministicSensingCryptography()
    )

    let store = SelfProofStore(fileURL: selfProofFileURL)
    XCTAssertEqual(
      store.records.count, 1,
      "a matching record already existed — reconciliation must not add a duplicate"
    )
    XCTAssertEqual(store.records.first?.id, existingRecord.id)
  }

  func testStopSensingClearsTheCheckpointAfterProducingTheRealSelfProof() {
    let directory = makeTemporaryDirectory()
    let checkpointFileURL = directory.appendingPathComponent("self-proof-checkpoint.json")
    let coordinator = SensingCoordinator(
      windowReportStore: WindowReportStore(
        fileURL: directory.appendingPathComponent("window-reports.json")
      ),
      selfProofStore: SelfProofStore(
        fileURL: directory.appendingPathComponent("self-proofs.json")
      ),
      selfProofCheckpointStore: SelfProofCheckpointStore(fileURL: checkpointFileURL),
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
    coordinator.startSensing(eventCode: "TEST-CHECKPOINT-CLEAR")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(
        enin: 1,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    coordinator.handleDetection(
      enin: 2,
      rpid: "peer-late",
      detectedDisplayId: DetectionFixture.displayId(device: threshold)
    )
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: checkpointFileURL.path),
      "a checkpoint must exist mid-session, after a window rotation past .recording"
    )

    XCTAssertNotNil(coordinator.stopSensing())
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: checkpointFileURL.path),
      "a graceful session end must clear the checkpoint so it is never reconciled"
    )
  }

  private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("self-proof-checkpoint-test-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      preconditionFailure("Unable to create test directory: \(error)")
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }
}

/// A `SensingCryptography` facade whose owner-key half is backed by a real
/// `OwnerKeyProvider` over a fixed seed, so `signSelfProof` produces
/// signatures Barnard's own `BarnardCoreSigning.verifySelfProof` accepts —
/// unlike `DeterministicSensingCryptography`, which returns fabricated,
/// non-cryptographic signature bytes. `eventSigningPublicKey(eventCode:)`
/// returns a fixed, arbitrary compressed-key-shaped byte string: the
/// self-proof message embeds it as opaque data (`SelfProofMessageLayoutTests`)
/// rather than verifying it against any real signing key, so a real
/// `BarnardIdentity` is unnecessary here.
private final class BarnardBackedSelfProofCryptography: SensingCryptography {
  private let ownerKeyProvider: OwnerKeyProvider

  init(keyStorage: any OwnerKeySeedResolving = FixedSeedKeyStorage(seed: Data((0..<32).map(UInt8.init)))) {
    ownerKeyProvider = OwnerKeyProvider(keyStorage: keyStorage, randomSource: NeverCalledRandomSource())
  }
  private let fixedEventSigningPublicKey = Data(bytesFromHex(
    "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
  ))

  func eventSigningPublicKey(eventCode: String) -> Data {
    fixedEventSigningPublicKey
  }

  func ownerPublicKey() throws -> Data {
    try ownerKeyProvider.publicKeyCompressed()
  }

  func signWindowReport(eventCode: String, bytes: Data) -> SensingRecoverableSignature {
    SensingRecoverableSignature(r: Data(repeating: 0, count: 32), s: Data(repeating: 0, count: 32), v: 0)
  }

  func signSelfProof(
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64
  ) throws -> SensingRecoverableSignature? {
    try ownerKeyProvider.signSelfProof(
      eventIdHash: eventIdHash,
      eventSigningPublicKey: eventSigningPublicKey,
      eninStart: eninStart,
      eninEnd: eninEnd
    ).map { SensingRecoverableSignature(barnardCore: $0) }
  }

  func signWalletAcknowledgement(
    walletAddress: Data,
    walletSignature: Data
  ) throws -> SensingRecoverableSignature? {
    nil
  }
}

private struct FileSeedKeyStorage: OwnerKeySeedResolving {
  let fileURL: URL

  func bytes(forKey key: String) -> [UInt8]? {
    (try? Data(contentsOf: fileURL)).map(Array.init)
  }

  func setBytes(_ bytes: [UInt8], forKey key: String) {
    XCTFail("the example seed is already stored")
  }

  func resolveSeed(forKey key: String, randomSource: any OwnerKeyRandomBytesGenerating) throws -> [UInt8] {
    Array(try Data(contentsOf: fileURL))
  }
}

private struct FixedSeedKeyStorage: OwnerKeySeedResolving {
  let seed: Data

  func bytes(forKey key: String) -> [UInt8]? {
    Array(seed)
  }

  func setBytes(_ bytes: [UInt8], forKey key: String) {}
  func resolveSeed(forKey key: String, randomSource: any OwnerKeyRandomBytesGenerating) throws -> [UInt8] { Array(seed) }
}

private struct NeverCalledRandomSource: BarnardCoreRandomSource, OwnerKeyRandomBytesGenerating {
  func randomBytes(count: Int) -> [UInt8] {
    XCTFail("randomSource must not be used when a seed is already stored")
    return [UInt8](repeating: 0, count: count)
  }
}

private func bytesFromHex(_ hex: String) -> [UInt8] {
  stride(from: 0, to: hex.count, by: 2).map { offset in
    let start = hex.index(hex.startIndex, offsetBy: offset)
    let end = hex.index(start, offsetBy: 2)
    return UInt8(hex[start..<end], radix: 16)!
  }
}
