// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// On-device JSON store for owner-key-signed self-proofs — same pattern as
/// `BindingRecordStore`/`WindowReportStore` (flat JSON, no server call).
/// See `SelfProofRecord`.
@MainActor
final class SelfProofStore: ObservableObject {
  @Published private(set) var records: [SelfProofRecord] = []
  @Published private(set) var lastPersistenceError: Error?
  private var durableRecords: [SelfProofRecord] = []

  /// Set when `load()` preserved a file that failed to decode, so the event
  /// is not invisible. Broader observability is beid#131's job.
  private(set) var quarantinedFileURL: URL?

  /// Set when the existing file could neither be read nor preserved.
  /// Saving would destroy bytes that were never captured, so this instance
  /// stops writing and keeps its records in memory only. Readable for the
  /// same reason `quarantinedFileURL` is: a `print` is invisible in a
  /// shipped build, and a store that silently stops persisting is the shape
  /// of the defect this file exists to fix.
  private(set) var persistenceSuspensionReason: Error?

  var isPersistenceSuspended: Bool { persistenceSuspensionReason != nil }

  private let fileURL: URL
  private let encodeRecords: ([SelfProofRecord]) throws -> Data
  private let writeData: (Data, URL) throws -> Void

  init(
    fileURL: URL? = nil,
    encodeRecords: @escaping ([SelfProofRecord]) throws -> Data = { try RecordSchemaEnvelope.encodeRecords($0) },
    writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
  ) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    self.encodeRecords = encodeRecords
    self.writeData = writeData
    load()
  }

  private static func defaultFileURL() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("self-proofs.json")
  }

  /// True means this proof's record is durable, including an idempotent retry.
  @discardableResult
  func add(_ record: SelfProofRecord) -> Bool {
    if durableRecord(forProofId: record.proofId) != nil {
      lastPersistenceError = nil
      return true
    }
    var updated = records.filter { $0.proofId != record.proofId }
    updated.append(record)
    if let reason = persistenceSuspensionReason {
      records = updated
      lastPersistenceError = reason
      return false
    }
    do {
      let data = try encodeRecords(updated)
      try writeData(data, fileURL)
      durableRecords = updated
      records = updated
      lastPersistenceError = nil
      return true
    } catch {
      lastPersistenceError = error
      return false
    }
  }

  /// Memory-only fallback records must never authorize checkpoint removal.
  func durableRecord(forProofId proofId: UUID) -> SelfProofRecord? {
    durableRecords.first { $0.proofId == proofId }
  }

  /// Confirms the replacement is durable before a checkpoint can be removed.
  func addDurably(_ record: SelfProofRecord) throws {
    guard add(record) else {
      throw lastPersistenceError ?? CocoaError(.fileWriteUnknown)
    }
  }

  /// A `Proof` gets at most one self-proof (mirrors `BindingRecord`'s own
  /// `proofId` linkage), so the first match is the only match. Used by
  /// checkpoint recovery and record presentation; only durable records qualify.
  func record(forProofId proofId: UUID) -> SelfProofRecord? {
    durableRecord(forProofId: proofId)
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      records = try RecordSchemaEnvelope.decodeRecords(SelfProofRecord.self, from: data)
      durableRecords = records
    } catch {
      // A file that fails to decode used to be discarded silently and then
      // destroyed by the next save, taking every self-proof with it
      // (beid#135). Preserve it first, then continue empty.
      let outcome = CorruptStoreQuarantine.resolve(
        loadFailure: error,
        fileURL: fileURL,
        storeDescription: "self-proof store"
      )
      quarantinedFileURL = outcome.quarantinedFileURL
      persistenceSuspensionReason = outcome.persistenceSuspensionReason
    }
  }
}
