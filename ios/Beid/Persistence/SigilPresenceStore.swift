// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation

/// One finished record's Sigil presence, persisted as opaque shared-encoded
/// text (beid#653). `presenceText` is
/// `BeidSharedKit.sigil.encodeSigilPresenceSnapshot`'s canonical output; this
/// type never decodes or interprets it. `proofId` is the uniqueness key, as in
/// `SessionAggregateSnapshotRecord`.
struct SigilPresenceRecord: Identifiable, Codable, Equatable {
  var id: UUID { proofId }

  let proofId: UUID
  let presenceText: String
  let createdAt: Date

  init(proofId: UUID, presenceText: String, createdAt: Date = Date()) {
    self.proofId = proofId
    self.presenceText = presenceText
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case proofId, presenceText, createdAt
  }
}

/// Payload-free on purpose: these values are logged, and a log line must never
/// carry a token or a display id (`docs/decisions/issue-653-design.md` §3).
/// Do not add associated values.
enum SigilPresenceStoreError: Error {
  /// Shared refused to encode the session (too many peers, a missing or
  /// duplicate token, no windows). Nothing is written, so the record keeps
  /// its neutral ring.
  case unencodable
  /// A different text is already stored for this record.
  case conflictingPresence
}

/// On-device store for per-record Sigil presence (beid#653).
///
/// **On the device only.** The owner authorized keeping per-window, per-peer
/// presence on this device and nowhere else (DECISIONS 2026-09-27). This store
/// is the only place it is written. Nothing reads it except the Sigil drawing
/// path: it is never part of a submission, a signature, a public artifact or a
/// log line, and it is excluded from device backup. Its directory and its
/// file are both marked, because an atomic write replaces the file and so
/// drops a mark set on the old one. Every other store in this app lives in
/// Documents and IS backed up; that is a separate, known gap and deliberately
/// not copied here.
///
/// Shape. Mechanical persistence only, the same split as
/// `SessionAggregateSnapshotStore`: `shared` owns the format, this store owns
/// the location and the atomic write. One immutable row per `proofId`; a
/// byte-identical re-submission is a no-op and a differing one throws
/// `conflictingPresence`. Corrupt-read handling follows the same
/// `CorruptStoreQuarantine` shape, because this is display data over durable
/// evidence and must never wedge a session.
///
/// Absence is the only "no data" signal: no row, a row that fails to decode,
/// or a session that could not be encoded all make `sigilInput(proofId:)`
/// return `nil`, and a `nil` record keeps the neutral ring. Nothing is ever
/// inferred from counts.
@MainActor
final class SigilPresenceStore: ObservableObject {
  @Published private(set) var records: [SigilPresenceRecord] = []

  private(set) var quarantinedFileURL: URL?
  private(set) var persistenceSuspensionReason: Error?

  var isPersistenceSuspended: Bool { persistenceSuspensionReason != nil }

  let fileURL: URL

  /// What `sigilInput(proofId:)` decoded for a row, kept because the lookup
  /// runs in view bodies: during a session the home list re-renders on every
  /// detection, and each past row would otherwise re-decode its text each
  /// time. Safe because a row never changes once written (`add` refuses a
  /// differing text). Only rows that exist are cached, so a row written later
  /// is still found. Invalidated in `remove(proofId:)`; cleared in
  /// `resetForUITesting()`.
  private enum DecodedInput {
    case decoded(BeidSharedKit.sigil.SigilInput)
    case rejected
  }

  private var decodedInputs: [UUID: DecodedInput] = [:]

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    load()
  }

  /// A dedicated directory in Application Support (not Documents), so the
  /// backup exclusion covers this data and nothing else.
  static func defaultFileURL() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support
      .appendingPathComponent("SigilPresence", isDirectory: true)
      .appendingPathComponent("sigil-presence.json")
  }

  /// Encodes the finished session through shared and stores it for
  /// `proofId`. Throws `unencodable`, writing nothing, when shared refuses.
  @discardableResult
  func persist(
    session: BeidSharedKit.sigil.SigilPresenceSession,
    observations: BeidSharedKit.aggregation.AggregationObservationInput,
    proofId: UUID
  ) throws -> SigilPresenceRecord {
    let encoded = BeidSharedKit.sigil.encodeSigilPresenceSnapshot(
      session: session,
      observations: observations
    )
    guard encoded.isSuccess, let presenceText = encoded.snapshotText else {
      throw SigilPresenceStoreError.unencodable
    }
    return try add(SigilPresenceRecord(proofId: proofId, presenceText: presenceText))
  }

  /// The record's Sigil input, or `nil` when there is no usable row.
  ///
  /// Memoized per `proofId`: repeated calls return the SAME instance. A
  /// caller must treat it as read-only. Never pass it to `addSigilPresence`
  /// or `addSigilPeer`, which would change the Sigil of every later reader of
  /// that record. It is only ever handed to `layoutSigil`, which does not
  /// mutate its input.
  func sigilInput(proofId: UUID) -> BeidSharedKit.sigil.SigilInput? {
    if let cached = decodedInputs[proofId] {
      switch cached {
      case let .decoded(input): return input
      case .rejected: return nil
      }
    }
    guard let record = records.first(where: { $0.proofId == proofId }) else {
      return nil
    }
    let loaded = BeidSharedKit.sigil.decodeSigilPresenceSnapshot(encoded: record.presenceText)
    guard loaded.isSuccess, let input = loaded.input else {
      decodedInputs[proofId] = .rejected
      return nil
    }
    decodedInputs[proofId] = .decoded(input)
    return input
  }

  /// Removes the row for `proofId`, if any. There is no record-delete
  /// feature yet; whichever path deletes a record must call this.
  func remove(proofId: UUID) throws {
    decodedInputs[proofId] = nil
    guard records.contains(where: { $0.proofId == proofId }) else { return }
    let updatedRecords = records.filter { $0.proofId != proofId }
    guard !isPersistenceSuspended else {
      records = updatedRecords
      return
    }
    try write(updatedRecords)
    records = updatedRecords
  }

  /// Test-only reset, called with `ProofStore.resetForUITesting()`, so a
  /// `-beid-ui-test` launch never shows presence from an earlier run.
  func resetForUITesting() {
    records = []
    decodedInputs = [:]
    quarantinedFileURL = nil
    persistenceSuspensionReason = nil
    try? FileManager.default.removeItem(at: fileURL)
  }

  @discardableResult
  private func add(_ record: SigilPresenceRecord) throws -> SigilPresenceRecord {
    if let existing = records.first(where: { $0.proofId == record.proofId }) {
      guard existing.presenceText == record.presenceText else {
        throw SigilPresenceStoreError.conflictingPresence
      }
      return existing
    }

    let updatedRecords = records + [record]
    guard !isPersistenceSuspended else {
      records = updatedRecords
      return record
    }

    try write(updatedRecords)
    records = updatedRecords
    return record
  }

  private func write(_ updatedRecords: [SigilPresenceRecord]) throws {
    let data = try RecordSchemaEnvelope.encodeRecords(updatedRecords)
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Before the first byte is written, so the data is never backup-eligible.
    try Self.excludeFromBackup(directory)
    try data.write(to: fileURL, options: .atomic)
    try Self.excludeFromBackup(fileURL)
  }

  private static func excludeFromBackup(_ url: URL) throws {
    var markedURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try markedURL.setResourceValues(values)
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      records = try RecordSchemaEnvelope.decodeRecords(SigilPresenceRecord.self, from: data)
    } catch {
      let outcome = CorruptStoreQuarantine.resolve(
        loadFailure: error,
        fileURL: fileURL,
        storeDescription: "Sigil presence store"
      )
      quarantinedFileURL = outcome.quarantinedFileURL
      persistenceSuspensionReason = outcome.persistenceSuspensionReason
    }
  }
}
