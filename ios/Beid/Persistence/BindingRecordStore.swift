// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// On-device JSON store for completed wallet-binding records — same pattern
/// as `ProofStore`/`WindowReportStore` (flat JSON, no server call). See
/// `BindingRecord`.
@MainActor
final class BindingRecordStore: ObservableObject {
  @Published private(set) var records: [BindingRecord] = []

  private let fileURL: URL

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    load()
  }

  private static func defaultFileURL() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("binding-records.json")
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
    guard let data = try? Data(contentsOf: fileURL) else { return }
    records = (try? JSONDecoder().decode([BindingRecord].self, from: data)) ?? []
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(records) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
