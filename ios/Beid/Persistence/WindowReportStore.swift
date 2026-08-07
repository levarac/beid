// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

enum WindowReportStoreError: Error {
  case conflictingReportId
}

struct WindowReportStoreRecovery {
  let store: WindowReportStore
  let quarantinedReportsURL: URL?
}

/// On-device JSON store for locally signed window reports — same pattern
/// as `ProofStore` (flat JSON, no server call). See `WindowReport`.
@MainActor
final class WindowReportStore: ObservableObject {
  @Published private(set) var reports: [WindowReport] = []

  private let fileURL: URL
  private let replacePersistedFile: (URL, URL) throws -> Void
  private var loadError: Error?

  init(
    fileURL: URL? = nil,
    replacePersistedFile: @escaping (URL, URL) throws -> Void = { destinationURL, stagedURL in
      _ = try FileManager.default.replaceItemAt(
        destinationURL,
        withItemAt: stagedURL
      )
    }
  ) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    self.replacePersistedFile = replacePersistedFile
    load()
  }

  private static func defaultFileURL() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("window-reports.json")
  }

  /// Production startup policy for a report file that cannot be decoded.
  /// Strict `init` and report access remain fail-closed; this opt-in path
  /// preserves the corrupt bytes under a timestamped sibling name and opens
  /// an empty store at the canonical path so future reports can be persisted.
  /// Other I/O errors are not treated as corruption and still propagate.
  static func recoveringCorruptReports(
    fileURL: URL? = nil,
    now: Date = Date()
  ) throws -> WindowReportStoreRecovery {
    let resolvedFileURL = fileURL ?? defaultFileURL()
    let store = WindowReportStore(fileURL: resolvedFileURL)
    guard let loadError = store.loadError else {
      return WindowReportStoreRecovery(
        store: store,
        quarantinedReportsURL: nil
      )
    }
    guard loadError is DecodingError else {
      throw loadError
    }

    let timestampMilliseconds = Int64(
      (now.timeIntervalSince1970 * 1_000).rounded(.down)
    )
    let suffix = "corrupt-\(timestampMilliseconds)-\(UUID().uuidString.lowercased())"
    let quarantinedURL = resolvedFileURL.appendingPathExtension(suffix)
    try FileManager.default.moveItem(at: resolvedFileURL, to: quarantinedURL)
    return WindowReportStoreRecovery(
      store: WindowReportStore(fileURL: resolvedFileURL),
      quarantinedReportsURL: quarantinedURL
    )
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
    let stagedURL = fileURL.deletingLastPathComponent().appendingPathComponent(
      ".window-reports-\(UUID().uuidString.lowercased()).tmp"
    )
    defer { try? FileManager.default.removeItem(at: stagedURL) }
    try data.write(to: stagedURL)
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try replacePersistedFile(fileURL, stagedURL)
    } else {
      try FileManager.default.moveItem(at: stagedURL, to: fileURL)
    }
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
