// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// On-device JSON store for completed wallet-binding records — same pattern
/// as `ProofStore`/`WindowReportStore` (flat JSON, no server call). See
/// `BindingRecord`.
@MainActor
final class BindingRecordStore: ObservableObject {
  @Published private(set) var records: [BindingRecord] = []

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

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    load()
  }

  private static func defaultFileURL() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    // v2: pre-conformance records (`binding-records.json`) are orphaned by
    // construction, never migrated — old records decode successfully under
    // the new `BindingRecord` shape while being cryptographically
    // meaningless (wrong signer, wrong signed content), so the new code
    // must never open the old filename
    // (`docs/specs/barnard-binding-conformance.md` §6.d).
    return dir.appendingPathComponent("binding-records-v2.json")
  }

  func add(_ record: BindingRecord) {
    records.append(record)
    save()
  }

  /// A `Proof` is bound at most once (wallet at most once per event,
  /// `scan-protocol-model.md` §4), so the first match is the only match.
  func record(forProofId proofId: UUID) -> BindingRecord? {
    records.first { $0.proofId == proofId }
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      records = try RecordSchemaEnvelope.decodeRecords(BindingRecord.self, from: data)
    } catch {
      // A file that fails to decode used to be discarded silently and then
      // destroyed by the next save, taking every binding record with it
      // (beid#135). Preserve it first, then continue empty.
      let outcome = CorruptStoreQuarantine.resolve(
        loadFailure: error,
        fileURL: fileURL,
        storeDescription: "binding record store"
      )
      quarantinedFileURL = outcome.quarantinedFileURL
      persistenceSuspensionReason = outcome.persistenceSuspensionReason
    }
  }

  private func save() {
    guard !isPersistenceSuspended else { return }
    guard let data = try? RecordSchemaEnvelope.encodeRecords(records) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
