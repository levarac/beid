// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// On-device JSON store for one in-progress `SelfProofCheckpoint` — same
/// pattern as `WindowReportStore`/`SelfProofStore`/`BindingRecordStore`
/// (flat, atomic, on-device only), except it holds at most one record
/// rather than an accumulating collection: a session has at most one
/// self-proof in progress at a time (`docs/specs/session-end-finalization.md`
/// §7.1 Option B, §8.3).
@MainActor
final class SelfProofCheckpointStore: ObservableObject {
  @Published private(set) var checkpoint: SelfProofCheckpoint?

  /// Set when `load()` preserved a file that failed to decode, so the event
  /// is not invisible. Broader observability is beid#131's job.
  private(set) var quarantinedFileURL: URL?

  /// Set when the existing file could neither be read nor preserved.
  /// Saving would destroy bytes that were never captured, so this instance
  /// stops writing and keeps its checkpoint in memory only. Readable for
  /// the same reason `quarantinedFileURL` is: a `print` is invisible in a
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
    return dir.appendingPathComponent("self-proof-checkpoint.json")
  }

  /// Overwrites any prior in-progress checkpoint — only the most recent
  /// window's `eninEnd` matters for reconciliation, so this upserts rather
  /// than accumulates.
  func save(_ checkpoint: SelfProofCheckpoint) {
    self.checkpoint = checkpoint
    persist()
  }

  /// Removes the checkpoint, either because the real `SelfProofRecord` it
  /// was standing in for now exists (a graceful session end, or
  /// reconciliation itself just produced one) or because it was already
  /// stale when reconciliation ran.
  func clear() {
    guard checkpoint != nil else { return }
    checkpoint = nil
    persist()
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      checkpoint = try RecordSchemaEnvelope.decodeRecord(SelfProofCheckpoint.self, from: data)
    } catch {
      // Same corrupt-file policy as the other proof-bearing stores
      // (beid#135) — preserve the unreadable bytes before anything can
      // overwrite them, then continue as if no checkpoint existed.
      let outcome = CorruptStoreQuarantine.resolve(
        loadFailure: error,
        fileURL: fileURL,
        storeDescription: "self-proof checkpoint store"
      )
      quarantinedFileURL = outcome.quarantinedFileURL
      persistenceSuspensionReason = outcome.persistenceSuspensionReason
    }
  }

  private func persist() {
    guard !isPersistenceSuspended else { return }
    guard let checkpoint else {
      try? FileManager.default.removeItem(at: fileURL)
      return
    }
    guard let data = try? RecordSchemaEnvelope.encodeRecord(checkpoint) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
