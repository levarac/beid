// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation

enum UnsentWindowLedgerStoreError: Error {
  case invalidTransition
  case invalidSnapshot
  case sameRevisionConflict
}

struct UnsentWindowLedgerStoreRecovery {
  let store: UnsentWindowLedgerStore
  let quarantinedSnapshotURL: URL?
}

/// Mechanical persistence for the shared unsent-window ledger.
///
/// Ledger state and transitions remain owned by `BeidSharedKit`; this store
/// only validates canonical snapshots and atomically replaces their UTF-8
/// bytes. Revision ordering prevents a delayed older write from replacing a
/// newer durable snapshot.
final class UnsentWindowLedgerStore {
  private static let persistenceLock = NSLock()

  private let fileURL: URL

  init(fileURL: URL? = nil) throws {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    _ = try withPersistenceLock {
      try durableRevision()
    }
  }

  /// Production startup policy for a snapshot whose shared decoder rejects
  /// its bytes. Strict `init`/`load` remain fail-closed; this opt-in path
  /// preserves the corrupt bytes under a timestamped sibling name and opens
  /// an empty store at the canonical path so future sensing can continue.
  /// Other I/O errors are not treated as corruption and still propagate.
  static func recoveringCorruptSnapshot(
    fileURL: URL? = nil,
    now: Date = Date()
  ) throws -> UnsentWindowLedgerStoreRecovery {
    let resolvedFileURL = fileURL ?? defaultFileURL()
    persistenceLock.lock()
    defer { persistenceLock.unlock() }

    let store = UnsentWindowLedgerStore(unvalidatedFileURL: resolvedFileURL)
    do {
      _ = try store.durableRevision()
      return UnsentWindowLedgerStoreRecovery(
        store: store,
        quarantinedSnapshotURL: nil
      )
    } catch UnsentWindowLedgerStoreError.invalidSnapshot {
      let timestampMilliseconds = Int64(
        (now.timeIntervalSince1970 * 1_000).rounded(.down)
      )
      let suffix = "corrupt-\(timestampMilliseconds)-\(UUID().uuidString.lowercased())"
      let quarantinedURL = resolvedFileURL.appendingPathExtension(suffix)
      try FileManager.default.moveItem(at: resolvedFileURL, to: quarantinedURL)
      return UnsentWindowLedgerStoreRecovery(
        store: store,
        quarantinedSnapshotURL: quarantinedURL
      )
    }
  }

  @discardableResult
  func persist(
    _ transition: BeidSharedKit.report.UnsentWindowLedgerTransition
  ) throws -> Int64 {
    try withPersistenceLock {
      guard
        transition.isSuccess,
        transition.changed,
        let snapshotText = transition.snapshotText
      else {
        throw UnsentWindowLedgerStoreError.invalidTransition
      }

      let decoded = BeidSharedKit.report.decodeUnsentWindowLedgerSnapshot(
        encoded: snapshotText
      )
      guard
        decoded.isSuccess,
        decoded.ledger != nil,
        decoded.persistenceRevision == transition.persistenceRevision
      else {
        throw UnsentWindowLedgerStoreError.invalidSnapshot
      }

      let currentRevision = try durableRevision()
      if transition.persistenceRevision < currentRevision {
        return currentRevision
      }

      let snapshotData = Data(snapshotText.utf8)
      if transition.persistenceRevision == currentRevision {
        guard
          let durableData = try? Data(contentsOf: fileURL),
          durableData == snapshotData
        else {
          throw UnsentWindowLedgerStoreError.sameRevisionConflict
        }
        return currentRevision
      }

      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try snapshotData.write(to: fileURL, options: .atomic)
      return transition.persistenceRevision
    }
  }

  func load() throws -> BeidSharedKit.report.UnsentWindowLedgerLoadResult? {
    try withPersistenceLock {
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return nil
      }
      return try decodedDurableSnapshot()
    }
  }

  private static func defaultFileURL() -> URL {
    let directory = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    )[0]
    return directory.appendingPathComponent("unsent-window-ledger.snapshot")
  }

  private init(unvalidatedFileURL: URL) {
    fileURL = unvalidatedFileURL
  }

  private func durableRevision() throws -> Int64 {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return -1
    }
    return try decodedDurableSnapshot().persistenceRevision
  }

  private func decodedDurableSnapshot() throws
    -> BeidSharedKit.report.UnsentWindowLedgerLoadResult
  {
    let data = try Data(contentsOf: fileURL)
    guard let snapshotText = String(data: data, encoding: .utf8) else {
      throw UnsentWindowLedgerStoreError.invalidSnapshot
    }
    let decoded = BeidSharedKit.report.decodeUnsentWindowLedgerSnapshot(
      encoded: snapshotText
    )
    guard decoded.isSuccess, decoded.ledger != nil else {
      throw UnsentWindowLedgerStoreError.invalidSnapshot
    }
    return decoded
  }

  private func withPersistenceLock<T>(_ body: () throws -> T) rethrows -> T {
    Self.persistenceLock.lock()
    defer { Self.persistenceLock.unlock() }
    return try body()
  }
}
