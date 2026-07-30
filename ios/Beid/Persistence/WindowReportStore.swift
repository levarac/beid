// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// On-device JSON store for locally signed window reports — same pattern
/// as `ProofStore` (flat JSON, no server call). See `WindowReport`.
@MainActor
final class WindowReportStore: ObservableObject {
  @Published private(set) var reports: [WindowReport] = []

  private let fileURL: URL

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    load()
  }

  private static func defaultFileURL() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("window-reports.json")
  }

  func add(_ report: WindowReport) {
    reports.append(report)
    save()
  }

  private func load() {
    guard let data = try? Data(contentsOf: fileURL) else { return }
    reports = (try? JSONDecoder().decode([WindowReport].self, from: data)) ?? []
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(reports) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
