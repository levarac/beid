// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation

enum SessionAggregateSnapshotStoreError: Error {
  case invalidAggregate
  case conflictingSnapshot
}

/// On-device JSON store for computed session-aggregate snapshots (beid#166 Phase
/// 1). Mechanical persistence only: `shared` owns the portable snapshot format
/// (`BeidSharedKit.aggregation.encodeSessionAggregateSnapshot`/
/// `decodeSessionAggregateSnapshot`), this store owns storage location and
/// atomic write — same split `UnsentWindowLedgerStore` uses for the ledger
/// snapshot codec.
///
/// One snapshot per `proofId`, and a written snapshot is immutable: `persist`
/// is a no-op for a byte-identical re-submission and throws `conflictingSnapshot`
/// for a differing one, never a silent replace. This differs from
/// `WindowReportStore`'s fail-closed `init`/opt-in-recovery shape on purpose —
/// corrupt-read handling instead follows `SelfProofStore`'s
/// `CorruptStoreQuarantine`-in-`load()` shape, because nothing downstream needs
/// to distinguish "no snapshot yet" from "unreadable file": this store is a
/// display convenience layer over already-durable evidence (`Proof`/
/// `WindowReport`/`SelfProofRecord`), never the evidence itself, so it must
/// never wedge session start the way a proof-bearing store's property
/// initializer must not (beid#135).
///
/// This type intentionally has no session-end call site. `persist(aggregate:
/// proofId:)` is the narrow Phase 1 entry point beid#166 describes: it takes an
/// already-computed, already-successful shared aggregate and a `proofId`, and
/// makes no assumption about where in a session's lifecycle it is invoked from.
/// Wiring the actual call inside `SensingCoordinator`'s session-end path is
/// Phase 2, out of scope here.
@MainActor
final class SessionAggregateSnapshotStore: ObservableObject {
  @Published private(set) var records: [SessionAggregateSnapshotRecord] = []

  /// Set when `load()` preserved a file that failed to decode, so the event is
  /// not invisible. Broader observability is beid#131's job.
  private(set) var quarantinedFileURL: URL?

  /// Set when the existing file could neither be read nor preserved. Saving
  /// would destroy bytes that were never captured, so this instance stops
  /// writing and keeps its records in memory only.
  private(set) var persistenceSuspensionReason: Error?

  var isPersistenceSuspended: Bool { persistenceSuspensionReason != nil }

  private let fileURL: URL

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    load()
  }

  private static func defaultFileURL() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("session-aggregate-snapshots.json")
  }

  /// Encodes `aggregate` via the shared codec and persists it for `proofId`.
  /// Rejects an unsuccessful aggregate (`encodeSessionAggregateSnapshot`'s own
  /// `aggregate_not_successful` case) rather than writing a placeholder —
  /// there is nothing meaningful to persist for a failed aggregation, and the
  /// caller must resolve that before calling this, not after.
  @discardableResult
  func persist(
    aggregate: BeidSharedKit.aggregation.SessionAggregate,
    proofId: UUID
  ) throws -> SessionAggregateSnapshotRecord {
    let encoded = BeidSharedKit.aggregation.encodeSessionAggregateSnapshot(aggregate: aggregate)
    guard encoded.isSuccess, let snapshotText = encoded.snapshotText else {
      throw SessionAggregateSnapshotStoreError.invalidAggregate
    }
    return try add(
      SessionAggregateSnapshotRecord(proofId: proofId, snapshotText: snapshotText)
    )
  }

  /// Decodes and returns the snapshot for `proofId`, or `nil` if none was ever
  /// persisted for it — including the case where the session that produced
  /// `proofId` never called `persist` at all (beid#166's gating invariant: no
  /// snapshot for a session with no `Proof`). That gating is enforced by
  /// Phase 2's caller choosing not to call `persist`, not by this store.
  func snapshot(
    proofId: UUID
  ) -> BeidSharedKit.aggregation.SessionAggregate? {
    guard let record = records.first(where: { $0.proofId == proofId }) else {
      return nil
    }
    let decoded = BeidSharedKit.aggregation.decodeSessionAggregateSnapshot(
      encoded: record.snapshotText
    )
    guard decoded.isSuccess else {
      return nil
    }
    return decoded.aggregate
  }

  @discardableResult
  private func add(
    _ record: SessionAggregateSnapshotRecord
  ) throws -> SessionAggregateSnapshotRecord {
    if let existing = records.first(where: { $0.proofId == record.proofId }) {
      guard existing.snapshotText == record.snapshotText else {
        throw SessionAggregateSnapshotStoreError.conflictingSnapshot
      }
      return existing
    }

    let updatedRecords = records + [record]
    guard !isPersistenceSuspended else {
      records = updatedRecords
      return record
    }

    let data = try RecordSchemaEnvelope.encodeRecords(updatedRecords)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
    records = updatedRecords
    return record
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      records = try RecordSchemaEnvelope.decodeRecords(SessionAggregateSnapshotRecord.self, from: data)
    } catch {
      let outcome = CorruptStoreQuarantine.resolve(
        loadFailure: error,
        fileURL: fileURL,
        storeDescription: "session aggregate snapshot store"
      )
      quarantinedFileURL = outcome.quarantinedFileURL
      persistenceSuspensionReason = outcome.persistenceSuspensionReason
    }
  }
}
