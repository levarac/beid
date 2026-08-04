// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// On-device JSON store for owner-key-signed self-proofs — same pattern as
/// `BindingRecordStore`/`WindowReportStore` (flat JSON, no server call).
/// See `SelfProofRecord`.
@MainActor
final class SelfProofStore: ObservableObject {
  @Published private(set) var records: [SelfProofRecord] = []

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

  private func load() {
    guard let data = try? Data(contentsOf: fileURL) else { return }
    records = (try? JSONDecoder().decode([SelfProofRecord].self, from: data)) ?? []
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(records) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
