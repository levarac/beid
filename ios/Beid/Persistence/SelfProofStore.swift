// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// On-device JSON store for owner-key-signed self-proofs — same pattern as
/// `BindingRecordStore`/`WindowReportStore` (flat JSON, no server call).
/// See `SelfProofRecord`.
@MainActor
final class SelfProofStore: ObservableObject {
  @Published private(set) var records: [SelfProofRecord] = []

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
    return dir.appendingPathComponent("self-proofs.json")
  }

  func add(_ record: SelfProofRecord) {
    records.append(record)
    save()
  }

  /// A `Proof` gets at most one self-proof (mirrors `BindingRecord`'s own
  /// `proofId` linkage), so the first match is the only match. Used by
  /// checkpoint reconciliation to tell whether a graceful session end
  /// already produced the real record.
  func record(forProofId proofId: UUID) -> SelfProofRecord? {
    records.first { $0.proofId == proofId }
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      records = try JSONDecoder().decode([SelfProofRecord].self, from: data)
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

  private func save() {
    guard !isPersistenceSuspended else { return }
    guard let data = try? JSONEncoder().encode(records) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
