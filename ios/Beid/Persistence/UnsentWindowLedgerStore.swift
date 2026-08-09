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
  private let synchronizeStagedFile: (URL) throws -> Void

  init(
    fileURL: URL? = nil,
    synchronizeStagedFile: @escaping (URL) throws -> Void = UnsentWindowLedgerStore
      .defaultSynchronizeStagedFile
  ) throws {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    self.synchronizeStagedFile = synchronizeStagedFile
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

    let store = UnsentWindowLedgerStore(
      unvalidatedFileURL: resolvedFileURL,
      synchronizeStagedFile: UnsentWindowLedgerStore.defaultSynchronizeStagedFile
    )
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
      pruneOldQuarantinedSnapshots(around: resolvedFileURL)
      return UnsentWindowLedgerStoreRecovery(
        store: store,
        quarantinedSnapshotURL: quarantinedURL
      )
    }
  }

  /// Quarantine files accumulate one per corruption event with nothing that
  /// ever removes them. Cap how many survive: on a device that corrupts
  /// repeatedly, this bounds worst-case disk usage to a small constant while
  /// still keeping the most recent occurrences around for diagnosis. A count
  /// cap is used rather than an age cutoff because this runs only when a new
  /// quarantine event happens (not a background job), so an age check would
  /// only ever fire relative to that same rare moment anyway — a count is
  /// simpler and needs no extra clock reasoning.
  private static let maxQuarantinedSnapshotCount = 5

  private static func pruneOldQuarantinedSnapshots(around fileURL: URL) {
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

    guard quarantined.count > maxQuarantinedSnapshotCount else {
      return
    }
    for entry in quarantined.prefix(quarantined.count - maxQuarantinedSnapshotCount) {
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
      // `Data.write(options: .atomic)` guarantees the rename is atomic but not
      // that the bytes reached stable storage first — the same gap Android's
      // store closes with `output.fd.sync()` before its `ATOMIC_MOVE`. Stage
      // the write ourselves so we can fsync the descriptor before the swap.
      let stagedURL = fileURL.deletingLastPathComponent().appendingPathComponent(
        ".unsent-window-ledger-\(UUID().uuidString.lowercased()).tmp"
      )
      defer { try? FileManager.default.removeItem(at: stagedURL) }
      try snapshotData.write(to: stagedURL)
      try synchronizeStagedFile(stagedURL)
      if FileManager.default.fileExists(atPath: fileURL.path) {
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: stagedURL)
      } else {
        try FileManager.default.moveItem(at: stagedURL, to: fileURL)
      }
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

  private init(
    unvalidatedFileURL: URL,
    synchronizeStagedFile: @escaping (URL) throws -> Void
  ) {
    fileURL = unvalidatedFileURL
    self.synchronizeStagedFile = synchronizeStagedFile
  }

  /// Flushes the staged file's in-memory data to permanent storage before it
  /// is atomically swapped into place. `FileHandle.synchronize()` wraps the
  /// POSIX `fsync(2)` call — the same durability level Android's
  /// `FileDescriptor.sync()` provides before its `ATOMIC_MOVE`. The stronger
  /// `F_FULLFSYNC` fcntl is intentionally not used here: it forces a physical
  /// media flush at a real latency cost meant for strict-ordering database
  /// workloads, which exceeds what parity with Android's own guarantee
  /// requires for this ledger.
  private static func defaultSynchronizeStagedFile(_ url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
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
