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
  private let synchronizeStagedFile: (URL) throws -> Void
  private var loadError: Error?

  init(
    fileURL: URL? = nil,
    replacePersistedFile: @escaping (URL, URL) throws -> Void = { destinationURL, stagedURL in
      _ = try FileManager.default.replaceItemAt(
        destinationURL,
        withItemAt: stagedURL
      )
    },
    synchronizeStagedFile: @escaping (URL) throws -> Void = WindowReportStore
      .defaultSynchronizeStagedFile
  ) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    self.replacePersistedFile = replacePersistedFile
    self.synchronizeStagedFile = synchronizeStagedFile
    load()
  }

  /// Flushes the staged file's in-memory data to permanent storage before it
  /// is atomically swapped into place. See `UnsentWindowLedgerStore`'s
  /// identical helper for why `FileHandle.synchronize()` (POSIX `fsync(2)`)
  /// is the right level here, matching Android's `FileDescriptor.sync()`
  /// rather than the costlier `F_FULLFSYNC`.
  private static func defaultSynchronizeStagedFile(_ url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
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
    pruneOldQuarantinedReports(around: resolvedFileURL)
    return WindowReportStoreRecovery(
      store: WindowReportStore(fileURL: resolvedFileURL),
      quarantinedReportsURL: quarantinedURL
    )
  }

  /// Quarantine files accumulate one per corruption event with nothing that
  /// ever removes them. Cap how many survive: see `UnsentWindowLedgerStore`'s
  /// identical helper for why a count cap (rather than an age cutoff) is used
  /// here, applied synchronously as part of quarantining the next file.
  private static let maxQuarantinedReportsCount = 5

  private static func pruneOldQuarantinedReports(around fileURL: URL) {
    let directory = fileURL.deletingLastPathComponent()
    let prefix = fileURL.lastPathComponent + ".corrupt-"
    guard let siblings = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ) else {
      return
    }

    let quarantined = siblings
      .compactMap { url -> (url: URL, timestampMilliseconds: Int64)? in
        guard let timestamp = quarantineTimestampMilliseconds(of: url, prefix: prefix) else {
          return nil
        }
        return (url, timestamp)
      }
      .sorted { $0.timestampMilliseconds < $1.timestampMilliseconds }

    guard quarantined.count > maxQuarantinedReportsCount else {
      return
    }
    for entry in quarantined.prefix(quarantined.count - maxQuarantinedReportsCount) {
      try? FileManager.default.removeItem(at: entry.url)
    }
  }

  /// Parses the millisecond timestamp out of the existing
  /// `corrupt-<milliseconds>-<uuid>` suffix convention, without introducing a
  /// second naming or indexing scheme.
  private static func quarantineTimestampMilliseconds(of url: URL, prefix: String) -> Int64? {
    let name = url.lastPathComponent
    guard name.hasPrefix(prefix) else {
      return nil
    }
    let afterPrefix = name.dropFirst(prefix.count)
    guard let dashIndex = afterPrefix.firstIndex(of: "-") else {
      return nil
    }
    return Int64(afterPrefix[..<dashIndex])
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
    try synchronizeStagedFile(stagedURL)
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
