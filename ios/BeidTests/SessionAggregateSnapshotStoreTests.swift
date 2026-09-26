// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation
import XCTest
@testable import Beid

@MainActor
final class SessionAggregateSnapshotStoreTests: XCTestCase {
  func testPersistAndReadRoundTripsThroughTheSharedCodecOnly() throws {
    let directory = try makeIsolatedDirectory(named: "beid-session-aggregate-roundtrip")
    let fileURL = directory.appendingPathComponent("session-aggregate-snapshots.json")
    let store = SessionAggregateSnapshotStore(fileURL: fileURL)
    let aggregate = makeAggregate(deviceId: "device-a")
    let proofId = UUID()

    let record = try store.persist(aggregate: aggregate, proofId: proofId)
    XCTAssertEqual(record.proofId, proofId)

    // Ownership proof: the persisted file's bytes decode via the shared codec
    // directly (not just through the store), so the store cannot be reshaping
    // or reinterpreting the aggregate on its own — it only carries the shared
    // encoder's opaque output. If the store ever hand-rolled its own encoding
    // instead of calling `encodeSessionAggregateSnapshot`, this would fail.
    let restored = try XCTUnwrap(store.snapshot(proofId: proofId))
    XCTAssertEqual(restored.deviceCount, aggregate.deviceCount)
    XCTAssertEqual(restored.observationCount, aggregate.observationCount)
    XCTAssertEqual(restored.windowCount, aggregate.windowCount)
    XCTAssertEqual(restored.bandCount, aggregate.bandCount)

    let onDiskRecords = try RecordSchemaEnvelope.decodeRecords(
      SessionAggregateSnapshotRecord.self,
      from: Data(contentsOf: fileURL)
    )
    let onDiskRecord = try XCTUnwrap(onDiskRecords.first { $0.proofId == proofId })
    XCTAssertEqual(onDiskRecord.snapshotText, record.snapshotText)
    let decodedFromDisk = BeidSharedKit.aggregation.decodeSessionAggregateSnapshot(
      encoded: onDiskRecord.snapshotText
    )
    XCTAssertTrue(decodedFromDisk.isSuccess)
    XCTAssertEqual(decodedFromDisk.aggregate?.deviceCount, aggregate.deviceCount)
  }

  func testSnapshotReturnsNilForAProofIdThatWasNeverPersisted() throws {
    let directory = try makeIsolatedDirectory(named: "beid-session-aggregate-missing")
    let store = SessionAggregateSnapshotStore(
      fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
    )

    XCTAssertNil(store.snapshot(proofId: UUID()))
  }

  func testUnsuccessfulAggregateIsRejectedRatherThanPersistingAPlaceholder() throws {
    let directory = try makeIsolatedDirectory(named: "beid-session-aggregate-failed")
    let store = SessionAggregateSnapshotStore(
      fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
    )
    let input = BeidSharedKit.aggregation.createAggregationObservationInput()
    _ = BeidSharedKit.aggregation.addAggregationObservation(
      input: input,
      windowIndex: 1,
      peerKey: "peer-1",
      displayId: "device-1",
      mutual: true
    )
    let failedAggregate = BeidSharedKit.aggregation.aggregateObservationsForSession(
      input: input,
      windowsPerBand: 0
    )
    XCTAssertFalse(failedAggregate.isSuccess)

    XCTAssertThrowsError(try store.persist(aggregate: failedAggregate, proofId: UUID())) { error in
      guard case SessionAggregateSnapshotStoreError.invalidAggregate = error else {
        return XCTFail("expected invalidAggregate, got \(error)")
      }
    }
    XCTAssertTrue(store.records.isEmpty)
  }

  func testASecondIdenticalPersistForTheSameProofIdIsANoOp() throws {
    let directory = try makeIsolatedDirectory(named: "beid-session-aggregate-idempotent")
    let store = SessionAggregateSnapshotStore(
      fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
    )
    let aggregate = makeAggregate(deviceId: "device-a")
    let proofId = UUID()

    let first = try store.persist(aggregate: aggregate, proofId: proofId)
    let second = try store.persist(aggregate: aggregate, proofId: proofId)

    XCTAssertEqual(first, second)
    XCTAssertEqual(store.records.count, 1)
  }

  func testASnapshotIsImmutableOnceWrittenAndRejectsADifferingResubmission() throws {
    let directory = try makeIsolatedDirectory(named: "beid-session-aggregate-immutable")
    let store = SessionAggregateSnapshotStore(
      fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
    )
    let proofId = UUID()
    try store.persist(aggregate: makeAggregate(deviceId: "device-a"), proofId: proofId)

    // A different `windowIndex`, not a different `deviceId`: the codec persists
    // counts, not raw peer/display identities (`SessionAggregateSnapshot.kt`
    // never encodes `peerKey`/`displayId`), so two aggregates that differ only
    // in which device was observed can legitimately encode to the same bytes.
    // A different window index changes the encoded window series itself.
    XCTAssertThrowsError(
      try store.persist(aggregate: makeAggregate(windowIndex: 200), proofId: proofId)
    ) { error in
      guard case SessionAggregateSnapshotStoreError.conflictingSnapshot = error else {
        return XCTFail("expected conflictingSnapshot, got \(error)")
      }
    }
    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(store.snapshot(proofId: proofId)?.windowAt(index: 0)?.windowIndex, 100)
  }

  func testTwoDifferentProofIdsPersistIndependently() throws {
    let directory = try makeIsolatedDirectory(named: "beid-session-aggregate-multi")
    let store = SessionAggregateSnapshotStore(
      fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
    )
    let firstProofId = UUID()
    let secondProofId = UUID()
    try store.persist(aggregate: makeAggregate(deviceId: "device-a"), proofId: firstProofId)
    try store.persist(aggregate: makeAggregate(windowIndex: 900), proofId: secondProofId)

    XCTAssertEqual(store.records.count, 2)
    XCTAssertNotNil(store.snapshot(proofId: firstProofId))
    XCTAssertNotNil(store.snapshot(proofId: secondProofId))

    let relaunched = SessionAggregateSnapshotStore(
      fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
    )
    XCTAssertEqual(relaunched.records.count, 2)
  }

  func testCorruptSnapshotsFileIsPreservedWhenTheNextSnapshotIsPersisted() throws {
    let directory = try makeIsolatedDirectory(named: "beid-session-aggregate-quarantine")
    let fileURL = directory.appendingPathComponent("session-aggregate-snapshots.json")
    let corruptBytes = Data("not-session-aggregate-snapshot-json".utf8)
    try corruptBytes.write(to: fileURL, options: .atomic)

    let store = SessionAggregateSnapshotStore(fileURL: fileURL)
    XCTAssertTrue(store.records.isEmpty, "a corrupt file must read as empty, not halt")

    try store.persist(aggregate: makeAggregate(deviceId: "device-a"), proofId: UUID())

    let survivors = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    .filter { $0 != fileURL }
    .filter { (try? Data(contentsOf: $0)) == corruptBytes }
    XCTAssertEqual(survivors.count, 1, "the bytes that failed to decode must survive a later write")
    XCTAssertTrue(survivors.first?.lastPathComponent.contains(".corrupt-") ?? false)

    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(SessionAggregateSnapshotStore(fileURL: fileURL).records.count, 1)
  }

  func testEachQuarantineIsReportedRatherThanSilent() throws {
    let directory = try makeIsolatedDirectory(named: "beid-session-aggregate-detectable")
    let fileURL = directory.appendingPathComponent("session-aggregate-snapshots.json")
    try Data("not-json".utf8).write(to: fileURL, options: .atomic)

    let store = SessionAggregateSnapshotStore(fileURL: fileURL)

    let quarantinedURL = try XCTUnwrap(store.quarantinedFileURL)
    XCTAssertTrue(quarantinedURL.lastPathComponent.contains(".corrupt-"))
    XCTAssertFalse(
      store.isPersistenceSuspended,
      "the bytes were preserved, so the store may keep writing"
    )
  }

  func testUnreadableExistingFileIsNeitherQuarantinedNorOverwritten() throws {
    let directory = try makeIsolatedDirectory(named: "beid-session-aggregate-unreadable")
    let fileURL = directory.appendingPathComponent("session-aggregate-snapshots.json")
    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

    let store = SessionAggregateSnapshotStore(fileURL: fileURL)
    XCTAssertNil(store.quarantinedFileURL)
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertTrue(store.isPersistenceSuspended)
    XCTAssertNotNil(store.persistenceSuspensionReason)

    try store.persist(aggregate: makeAggregate(deviceId: "device-a"), proofId: UUID())

    XCTAssertEqual(store.records.count, 1, "the app keeps working in memory")
    var isDirectory: ObjCBool = false
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
    )
    XCTAssertTrue(isDirectory.boolValue, "the store must not have replaced it")
  }

  // MARK: - Helpers

  private func makeIsolatedDirectory(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

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
