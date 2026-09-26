// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// On-device JSON store for venue-device (gh#138) reassignment history —
/// same pattern as `ProofStore`/`BindingRecordStore` (flat JSON, no server
/// call, newest-first). See `VenueDeviceAssignmentRecord`.
@MainActor
final class VenueDeviceAssignmentStore: ObservableObject {
  /// Newest first, matching `ProofStore.add`'s ordering — the most recent
  /// entry is also the current assignment when broadcasting is active.
  @Published private(set) var records: [VenueDeviceAssignmentRecord] = []

  /// Set when `load()` preserved a file that failed to decode, so the event
  /// is not invisible. Same contract as `BindingRecordStore`'s (beid#131).
  private(set) var quarantinedFileURL: URL?

  /// Set when the existing file could neither be read nor preserved; this
  /// instance stops writing and keeps records in memory only. Same contract
  /// as `BindingRecordStore`'s.
  private(set) var persistenceSuspensionReason: Error?

  var isPersistenceSuspended: Bool { persistenceSuspensionReason != nil }

  private let fileURL: URL

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    load()
  }

  private static func defaultFileURL() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("venue-device-assignments.json")
  }

  func add(_ record: VenueDeviceAssignmentRecord) {
    records.insert(record, at: 0)
    save()
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      records = try RecordSchemaEnvelope.decodeRecords(VenueDeviceAssignmentRecord.self, from: data)
    } catch {
      let outcome = CorruptStoreQuarantine.resolve(
        loadFailure: error,
        fileURL: fileURL,
        storeDescription: "venue-device assignment store"
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
