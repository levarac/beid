// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// The two public byte sequences a venue device was last given, plus where
/// they came from, so a restart can offer the same source again.
///
/// This record holds PUBLIC SOURCE BYTES ONLY, and that is a rule rather than
/// an omission. There is deliberately no field for an import receipt, a
/// permit, a display name, a digest verdict or a deadline: restoring any of
/// those would let a device resume serving on last run's verification, and a
/// stored verdict cannot notice that the lease it was granted under has since
/// expired. Everything in this file must be re-imported and re-evaluated
/// before it can authorize anything.
struct VenuePublicArtifactRecord: Codable, Equatable {
  let bundleBytes: Data
  let handoffBytes: Data
  /// Human-readable origin for the UI, e.g. a file name or an https URL.
  /// Never used to re-fetch automatically and never treated as trusted.
  let sourceDescription: String
  let storedAt: Date

  var artifact: VenuePublicArtifact {
    VenuePublicArtifact(bundleBytes: bundleBytes, handoffBytes: handoffBytes)
  }
}

/// On-device JSON store for the venue device's current public artifact —
/// same pattern as `VenueDeviceAssignmentStore`/`ProofStore` (flat JSON,
/// atomic write, quarantine on corruption).
///
/// Holds at most one record: a venue device serves one event's bundle at a
/// time, and keeping a history of supplied bundles would invite restoring
/// an older one.
@MainActor
final class VenuePublicArtifactStore: ObservableObject {
  @Published private(set) var record: VenuePublicArtifactRecord?
  @Published private(set) var persistenceWriteFailure: Error?

  /// Set when `load()` preserved a file that failed to decode, so the event
  /// is not invisible. Same contract as `VenueDeviceAssignmentStore`'s.
  private(set) var quarantinedFileURL: URL?

  /// Set when the existing file could neither be read nor preserved; this
  /// instance stops writing and keeps the record in memory only.
  private(set) var persistenceSuspensionReason: Error?

  var isPersistenceSuspended: Bool { persistenceSuspensionReason != nil }

  private let fileURL: URL

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    load()
  }

  private static func defaultFileURL() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("venue-public-artifact.json")
  }

  func store(_ record: VenuePublicArtifactRecord) {
    self.record = record
    save()
  }

  func clear() {
    record = nil
    save()
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      record = try RecordSchemaEnvelope.decodeRecords(VenuePublicArtifactRecord.self, from: data).first
    } catch {
      let outcome = CorruptStoreQuarantine.resolve(
        loadFailure: error,
        fileURL: fileURL,
        storeDescription: "venue public artifact store"
      )
      quarantinedFileURL = outcome.quarantinedFileURL
      persistenceSuspensionReason = outcome.persistenceSuspensionReason
    }
  }

  private func save() {
    if let reason = persistenceSuspensionReason {
      persistenceWriteFailure = reason
      return
    }
    do {
      let data = try RecordSchemaEnvelope.encodeRecords(record.map { [$0] } ?? [])
      try data.write(to: fileURL, options: .atomic)
      persistenceWriteFailure = nil
    } catch {
      // Keep the selected public bytes in memory, but expose failed durability.
      persistenceWriteFailure = error
    }
  }
}
