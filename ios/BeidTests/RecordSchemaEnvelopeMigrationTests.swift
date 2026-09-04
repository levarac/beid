// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import BeidSharedKit
import Foundation
import XCTest
@testable import Beid

/// gh#155's actual regression coverage: a file saved by a build that
/// predates `RecordSchemaEnvelope` (today's real, unversioned on-device
/// shape for each of the four proof-bearing stores) must still load, must
/// not be quarantined, and — once the store next writes — the file on disk
/// must have become the versioned envelope, readable again by a fresh store
/// instance.
///
/// Each v0 fixture below is a hand-authored, complete production shape (no
/// field missing) for that type, not encoder-generated — the point is to
/// pin down exactly what a real device has on disk right now, independent
/// of whatever `RecordSchemaEnvelope`/model code this PR introduces.
@MainActor
final class RecordSchemaEnvelopeMigrationTests: XCTestCase {
  /// Only the field this envelope's dispatch mechanism actually reads —
  /// decodable from both the plural (`records`) and singular (`record`)
  /// envelope shapes, since both carry nothing else in common.
  private struct SchemaVersionProbe: Decodable {
    let schemaVersion: Int
  }

  private func makeIsolatedDirectory(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  /// Asserts the raw bytes on disk are now the versioned envelope: a
  /// top-level JSON *object* (not the old bare array/object) carrying
  /// `"schemaVersion":1`.
  private func assertFileIsNowVersionedEnvelope(at fileURL: URL) throws {
    let data = try Data(contentsOf: fileURL)
    let probe = try JSONDecoder().decode(SchemaVersionProbe.self, from: data)
    XCTAssertEqual(probe.schemaVersion, RecordSchemaEnvelope.currentSchemaVersion)

    let topLevel = try JSONSerialization.jsonObject(with: data)
    XCTAssertTrue(
      topLevel is [String: Any],
      "the rewritten file must be a top-level object, not the old bare array/object"
    )
  }

  // MARK: - Proof (array-of-records store)

  func testProofStoreV0FixtureMigratesToVersionedEnvelopeOnNextSave() throws {
    let directory = try makeIsolatedDirectory(named: "beid-migration-proof")
    let fileURL = directory.appendingPathComponent("proofs.json")
    let proofID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let v0Fixture = Data("""
    [{"date":721692800,"eventName":"ETHGlobal Tokyo","id":"11111111-1111-1111-1111-111111111111","method":"Bluetooth Sensing","signatureState":{"notRequested":{}},"peersVerified":3,"gradientSeed":42,"eventCode":"ABC123"}]
    """.utf8)
    try v0Fixture.write(to: fileURL, options: .atomic)

    // (a) the v0 fixture loads, unquarantined.
    let store = ProofStore(fileURL: fileURL)
    XCTAssertEqual(store.proofs.count, 1)
    XCTAssertEqual(store.proofs.first?.id, proofID)
    XCTAssertEqual(store.proofs.first?.eventName, "ETHGlobal Tokyo")
    XCTAssertEqual(store.proofs.first?.eventCode, "ABC123")
    XCTAssertNil(store.quarantinedFileURL)

    // (b) triggering a save rewrites the file as the versioned envelope.
    store.updatePeersVerified(for: proofID, to: 3)
    try assertFileIsNowVersionedEnvelope(at: fileURL)

    // (c) a fresh store against the now-rewritten file reloads correctly.
    let reloaded = ProofStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.proofs.count, 1)
    XCTAssertEqual(reloaded.proofs.first?.id, proofID)
    XCTAssertEqual(reloaded.proofs.first?.eventName, "ETHGlobal Tokyo")
    XCTAssertEqual(reloaded.proofs.first?.eventCode, "ABC123")
    XCTAssertNil(reloaded.quarantinedFileURL)
  }

  // MARK: - BindingRecord (array-of-records store)

  func testBindingRecordStoreV0FixtureMigratesToVersionedEnvelopeOnNextSave() throws {
    let directory = try makeIsolatedDirectory(named: "beid-migration-binding")
    let fileURL = directory.appendingPathComponent("binding-records-v2.json")
    let recordID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    // nonceHex corrected to 16 bytes (32 hex chars) per `BindingRecord`'s
    // real construction (`Data(repeating: 0x04, count: 16)` in
    // `CorruptStoreQuarantineTests.makeBindingRecord()`) — the task's
    // starting-point literal was 31 bytes (62 hex chars).
    let v0Fixture = Data("""
    [{"id":"44444444-4444-4444-4444-444444444444","proofId":"55555555-5555-5555-5555-555555555555","eventCode":"TEST-EVENT","walletAddress":"0x0000000000000000000000000000000000000001","eventSigningPublicKeyHex":"0202020202020202020202020202020202020202020202020202020202020202","ownerPublicKeyHex":"0303030303030303030303030303030303030303030303030303030303030303","chainId":1,"nonceHex":"04040404040404040404040404040404","issuedAt":"2026-01-01T00:00:00Z","walletSignatureHex":"0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a","deviceSignatureRHex":"0101010101010101010101010101010101010101010101010101010101010101","deviceSignatureSHex":"0202020202020202020202020202020202020202020202020202020202020202","deviceSignatureV":0}]
    """.utf8)
    try v0Fixture.write(to: fileURL, options: .atomic)

    // (a) the v0 fixture loads, unquarantined.
    let store = BindingRecordStore(fileURL: fileURL)
    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(store.records.first?.id, recordID)
    XCTAssertEqual(store.records.first?.chainId, 1)
    XCTAssertNil(store.quarantinedFileURL)

    // (b) triggering a save rewrites the file as the versioned envelope.
    let secondProofID = UUID()
    store.add(
      BindingRecord(
        proofId: secondProofID,
        eventCode: "TEST-EVENT-2",
        walletAddress: "0x0000000000000000000000000000000000000002",
        eventSigningPublicKey: Data(repeating: 0x02, count: 33),
        ownerPublicKey: Data(repeating: 0x03, count: 33),
        chainId: 1,
        nonce: Data(repeating: 0x04, count: 16),
        issuedAt: "2026-01-02T00:00:00Z",
        walletSignatureHex: String(repeating: "0a", count: 65),
        deviceSignature: BarnardCoreRecoverableSignature(
          r: [UInt8](repeating: 1, count: 32),
          s: [UInt8](repeating: 2, count: 32),
          v: 0
        )
      )
    )
    try assertFileIsNowVersionedEnvelope(at: fileURL)

    // (c) a fresh store against the now-rewritten file reloads correctly.
    let reloaded = BindingRecordStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.records.count, 2)
    XCTAssertTrue(reloaded.records.contains { $0.id == recordID && $0.chainId == 1 })
    XCTAssertTrue(reloaded.records.contains { $0.proofId == secondProofID })
    XCTAssertNil(reloaded.quarantinedFileURL)
  }

  // MARK: - SelfProofRecord (array-of-records store)

  func testSelfProofStoreV0FixtureMigratesToVersionedEnvelopeOnNextSave() throws {
    let directory = try makeIsolatedDirectory(named: "beid-migration-selfproof")
    let fileURL = directory.appendingPathComponent("self-proofs.json")
    let recordID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    let v0Fixture = Data("""
    [{"id":"66666666-6666-6666-6666-666666666666","proofId":"77777777-7777-7777-7777-777777777777","eventCode":"TEST-EVENT","eventIdHashHex":"abababababababababababababababababababababababababababababababab","eventSigningPublicKeyHex":"0202020202020202020202020202020202020202020202020202020202020202","eninStart":100,"eninEnd":200,"ownerPublicKeyHex":"0303030303030303030303030303030303030303030303030303030303030303","signatureRHex":"0101010101010101010101010101010101010101010101010101010101010101","signatureSHex":"0202020202020202020202020202020202020202020202020202020202020202","signatureV":0,"signedAt":721692800}]
    """.utf8)
    try v0Fixture.write(to: fileURL, options: .atomic)

    // (a) the v0 fixture loads, unquarantined.
    let store = SelfProofStore(fileURL: fileURL)
    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(store.records.first?.id, recordID)
    XCTAssertEqual(store.records.first?.eninStart, 100)
    XCTAssertEqual(store.records.first?.eninEnd, 200)
    XCTAssertNil(store.quarantinedFileURL)

    // (b) triggering a save rewrites the file as the versioned envelope.
    let secondProofID = UUID()
    store.add(
      SelfProofRecord(
        proofId: secondProofID,
        eventCode: "TEST-EVENT-2",
        eventIdHash: Data(repeating: 0xAB, count: 32),
        eventSigningPublicKey: Data(repeating: 0x02, count: 33),
        eninStart: 300,
        eninEnd: 400,
        ownerPublicKey: Data(repeating: 0x03, count: 33),
        signature: BarnardCoreRecoverableSignature(
          r: [UInt8](repeating: 1, count: 32),
          s: [UInt8](repeating: 2, count: 32),
          v: 0
        )
      )
    )
    try assertFileIsNowVersionedEnvelope(at: fileURL)

    // (c) a fresh store against the now-rewritten file reloads correctly.
    let reloaded = SelfProofStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.records.count, 2)
    XCTAssertTrue(reloaded.records.contains { $0.id == recordID && $0.eninStart == 100 && $0.eninEnd == 200 })
    XCTAssertTrue(reloaded.records.contains { $0.proofId == secondProofID })
    XCTAssertNil(reloaded.quarantinedFileURL)
  }

  // MARK: - SelfProofCheckpoint (single-optional-record store)

  func testSelfProofCheckpointStoreV0FixtureMigratesToVersionedEnvelopeOnNextSave() throws {
    let directory = try makeIsolatedDirectory(named: "beid-migration-checkpoint")
    let fileURL = directory.appendingPathComponent("self-proof-checkpoint.json")
    let proofID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    let v0Fixture = Data("""
    {"proofId":"88888888-8888-8888-8888-888888888888","eventCode":"TEST-EVENT","eninStart":100,"eninEnd":200}
    """.utf8)
    try v0Fixture.write(to: fileURL, options: .atomic)

    // (a) the v0 fixture loads, unquarantined.
    let store = SelfProofCheckpointStore(fileURL: fileURL)
    XCTAssertEqual(store.checkpoint?.proofId, proofID)
    XCTAssertEqual(store.checkpoint?.eninStart, 100)
    XCTAssertEqual(store.checkpoint?.eninEnd, 200)
    XCTAssertNil(store.quarantinedFileURL)

    // (b) triggering a save (an upsert with identical content) rewrites the
    // file as the versioned envelope.
    store.save(SelfProofCheckpoint(proofId: proofID, eventCode: "TEST-EVENT", eninStart: 100, eninEnd: 200))
    try assertFileIsNowVersionedEnvelope(at: fileURL)

    // (c) a fresh store against the now-rewritten file reloads correctly.
    let reloaded = SelfProofCheckpointStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.checkpoint?.proofId, proofID)
    XCTAssertEqual(reloaded.checkpoint?.eninStart, 100)
    XCTAssertEqual(reloaded.checkpoint?.eninEnd, 200)
    XCTAssertNil(reloaded.quarantinedFileURL)
  }

  // MARK: - Unknown schemaVersion fails closed via the "unpreserved" branch

  /// Proves the design choice documented on `RecordSchemaEnvelope
  /// .UnsupportedSchemaVersion`: a file whose `schemaVersion` this build
  /// does not recognize must NOT be quarantined (that would permanently
  /// orphan a file a newer build might understand) but must suspend writes
  /// (so this build never overwrites it).
  func testUnknownSchemaVersionIsNotQuarantinedButSuspendsWrites() throws {
    let directory = try makeIsolatedDirectory(named: "beid-migration-unsupported-version")
    let fileURL = directory.appendingPathComponent("proofs.json")
    let futureVersionFixture = Data("""
    {"schemaVersion":999,"records":[{"date":721692800,"eventName":"Future Event","id":"99999999-9999-9999-9999-999999999999","method":"Bluetooth Sensing","signatureState":{"notRequested":{}},"peersVerified":1,"gradientSeed":1,"eventCode":"FUTURE"}]}
    """.utf8)
    try futureVersionFixture.write(to: fileURL, options: .atomic)

    let store = ProofStore(fileURL: fileURL)

    XCTAssertNil(
      store.quarantinedFileURL,
      "an unrecognized schemaVersion must not be quarantined -- a future build might understand it"
    )
    XCTAssertTrue(
      store.isPersistenceSuspended,
      "this build must not overwrite a file it cannot interpret"
    )
    XCTAssertTrue(store.proofs.isEmpty)

    // The file on disk must be untouched -- still the schemaVersion:999
    // envelope, not rewritten or removed.
    XCTAssertEqual(try Data(contentsOf: fileURL), futureVersionFixture)
  }

  // MARK: - VenueDeviceAssignment (array-of-records store)

  func testVenueDeviceAssignmentStoreV0FixtureMigratesToVersionedEnvelopeOnNextSave() throws {
    let directory = try makeIsolatedDirectory(named: "beid-migration-venue-device-assignment")
    let fileURL = directory.appendingPathComponent("venue-device-assignments.json")
    let recordID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let v0Fixture = Data("""
    [{"id":"11111111-1111-1111-1111-111111111111","label":"Entrance A","validityStart":730000000,"validityEnd":730003600,"assignedAt":730000000}]
    """.utf8)
    try v0Fixture.write(to: fileURL, options: .atomic)

    // (a) the v0 fixture loads, unquarantined.
    let store = VenueDeviceAssignmentStore(fileURL: fileURL)
    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(store.records.first?.id, recordID)
    XCTAssertEqual(store.records.first?.label, "Entrance A")
    XCTAssertNil(store.quarantinedFileURL)

    // (b) triggering a save rewrites the file as the versioned envelope.
    let now = Date()
    store.add(
      VenueDeviceAssignmentRecord(
        label: "Side Door",
        validityStart: now,
        validityEnd: now.addingTimeInterval(3600),
        assignedAt: now
      )
    )
    try assertFileIsNowVersionedEnvelope(at: fileURL)

    // (c) a fresh store against the now-rewritten file reloads correctly.
    let reloaded = VenueDeviceAssignmentStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.records.count, 2)
    XCTAssertTrue(reloaded.records.contains { $0.id == recordID && $0.label == "Entrance A" })
    XCTAssertTrue(reloaded.records.contains { $0.label == "Side Door" })
    XCTAssertNil(reloaded.quarantinedFileURL)
  }

  func testVenueDeviceAssignmentStoreMalformedV0FileIsQuarantinedNotSilentlyEmptied() throws {
    let directory = try makeIsolatedDirectory(named: "beid-migration-venue-device-assignment-malformed")
    let fileURL = directory.appendingPathComponent("venue-device-assignments.json")
    // Valid JSON array syntax, but missing the required `label` field -- must
    // still be treated as corrupt (a `DecodingError`), not as an empty v0 file.
    let malformedFixture = Data("""
    [{"id":"33333333-3333-3333-3333-333333333333","validityStart":730000000,"validityEnd":730003600,"assignedAt":730000000}]
    """.utf8)
    try malformedFixture.write(to: fileURL, options: .atomic)

    let store = VenueDeviceAssignmentStore(fileURL: fileURL)

    XCTAssertTrue(store.records.isEmpty)
    let quarantinedURL = try XCTUnwrap(store.quarantinedFileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path))
    XCTAssertEqual(try Data(contentsOf: quarantinedURL), malformedFixture)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  // MARK: - SessionAggregateSnapshot (array-of-records store)

  func testSessionAggregateSnapshotStoreV0FixtureMigratesToVersionedEnvelopeOnNextSave() throws {
    let directory = try makeIsolatedDirectory(named: "beid-migration-session-aggregate-snapshot")
    let fileURL = directory.appendingPathComponent("session-aggregate-snapshots.json")
    let proofID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let v0Fixture = Data("""
    [{"proofId":"22222222-2222-2222-2222-222222222222","snapshotText":"opaque-shared-encoded-text","createdAt":730000000}]
    """.utf8)
    try v0Fixture.write(to: fileURL, options: .atomic)

    // (a) the v0 fixture loads, unquarantined.
    let store = SessionAggregateSnapshotStore(fileURL: fileURL)
    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(store.records.first?.proofId, proofID)
    XCTAssertEqual(store.records.first?.snapshotText, "opaque-shared-encoded-text")
    XCTAssertNil(store.quarantinedFileURL)

    // (b) triggering a write via the public `persist` API rewrites the file as
    // the versioned envelope.
    let secondProofID = UUID()
    try store.persist(aggregate: makeAggregate(deviceId: "device-a"), proofId: secondProofID)
    try assertFileIsNowVersionedEnvelope(at: fileURL)

    // (c) a fresh store against the now-rewritten file reloads correctly.
    let reloaded = SessionAggregateSnapshotStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.records.count, 2)
    XCTAssertTrue(reloaded.records.contains { $0.proofId == proofID })
    XCTAssertTrue(reloaded.records.contains { $0.proofId == secondProofID })
    XCTAssertNil(reloaded.quarantinedFileURL)
  }

  func testSessionAggregateSnapshotStoreMalformedV0FileIsQuarantinedNotSilentlyEmptied() throws {
    let directory = try makeIsolatedDirectory(named: "beid-migration-session-aggregate-snapshot-malformed")
    let fileURL = directory.appendingPathComponent("session-aggregate-snapshots.json")
    // Valid JSON array syntax, but missing the required `snapshotText` field --
    // must still be treated as corrupt (a `DecodingError`), not as an empty v0
    // file.
    let malformedFixture = Data("""
    [{"proofId":"44444444-4444-4444-4444-444444444444","createdAt":730000000}]
    """.utf8)
    try malformedFixture.write(to: fileURL, options: .atomic)

    let store = SessionAggregateSnapshotStore(fileURL: fileURL)

    XCTAssertTrue(store.records.isEmpty)
    let quarantinedURL = try XCTUnwrap(store.quarantinedFileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path))
    XCTAssertEqual(try Data(contentsOf: quarantinedURL), malformedFixture)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  // MARK: - Helpers

  /// Reproduced from `SessionAggregateSnapshotStoreTests.makeAggregate`
  /// rather than imported across test files -- builds a minimal
  /// successfully-aggregated `SessionAggregate` for `persist(aggregate:
  /// proofId:)` to encode.
  private func makeAggregate(
    deviceId: String? = nil,
    windowIndex: Int64 = 100
  ) -> BeidSharedKit.aggregation.SessionAggregate {
    let input = BeidSharedKit.aggregation.createAggregationObservationInput()
    _ = BeidSharedKit.aggregation.addAggregationObservation(
      input: input,
      windowIndex: windowIndex,
      peerKey: "peer-\(windowIndex)",
      displayId: deviceId,
      mutual: false
    )
    return BeidSharedKit.aggregation.aggregateObservationsForSession(
      input: input,
      windowsPerBand: 4
    )
  }
}
