// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

enum WindowReportStoreError: Error {
  case conflictingReportId
}

/// On-device JSON store for locally signed window reports — same pattern
/// as `ProofStore` (flat JSON, no server call). See `WindowReport`.
@MainActor
final class WindowReportStore: ObservableObject {
  @Published private(set) var reports: [WindowReport] = []

  private let fileURL: URL
  private var loadError: Error?

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    load()
  }

  private static func defaultFileURL() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("window-reports.json")
  }

  @discardableResult
  func add(_ report: WindowReport) throws -> String {
    if let loadError {
      throw loadError
    }
    if let existing = reports.first(where: { $0.id == report.id }) {
      guard existing == report else {
        throw WindowReportStoreError.conflictingReportId
      }
      return report.id.uuidString.lowercased()
    }

    let updatedReports = reports + [report]
    let data = try JSONEncoder().encode(updatedReports)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
    reports = updatedReports
    return report.id.uuidString.lowercased()
  }

  func report(id: UUID) -> WindowReport? {
    reports.first { $0.id == id }
  }

  /// Returns the complete durable artifact set for shared-ledger relaunch
  /// reconciliation. A corrupt/unreadable store must throw instead of looking
  /// like an authoritative empty set, because that could discard recoverable
  /// open ledger windows.
  func persistedReportsForLedgerRecovery() throws -> [WindowReport] {
    if let loadError {
      throw loadError
    }
    return reports
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      reports = try JSONDecoder().decode([WindowReport].self, from: data)
    } catch {
      loadError = error
    }
  }
}
