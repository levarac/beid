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
  private let ownerKeyProvider = OwnerKeyProvider(
    keyStorage: FixedSeedKeyStorage(seed: Data((0..<32).map(UInt8.init))),
    randomSource: NeverCalledRandomSource()
  )
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
