// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Corrupt-file policy for the proof-bearing flat-JSON stores
/// (`ProofStore`, `BindingRecordStore`, `SelfProofStore`).
///
/// The mechanism is the one `WindowReportStore.recoveringCorruptReports`
/// and `UnsentWindowLedgerStore.recoveringCorruptSnapshot` already use: the
/// bytes that failed to decode are moved to a timestamped sibling name
/// before anything can overwrite them, and the read continues as an empty
/// collection. What differs is where it is applied. Those two stores keep a
/// fail-closed `init` and expose recovery as an opt-in production factory,
/// because a consumer there must be able to tell "empty" from "unreadable"
/// (`WindowReportStore.persistedReportsForLedgerRecovery`). The proof
/// stores have no such consumer and must never wedge the app, so they
/// quarantine inside `load()` — the only placement under which the
/// guarantee holds for every construction site, including
/// `SensingCoordinator`'s `BindingRecordStore()` property initializer
/// (beid#135).
enum CorruptStoreQuarantine {
  /// What a store may do after a load failure on a file that exists.
  enum Outcome {
    /// The bytes were preserved here, so the canonical path is now free and
    /// safe to write.
    case quarantined(URL)
    /// The bytes are still at the canonical path and could not be
    /// preserved, so that path must not be written — the store keeps
    /// working in memory only.
    case unpreserved(Error)

    var quarantinedFileURL: URL? {
      guard case let .quarantined(url) = self else { return nil }
      return url
    }

    /// Why this store must stop writing, or `nil` when it may continue.
    /// Carried as the error rather than a flag so the store can expose the
    /// reason: a `print` alone is invisible in a shipped build, and a store
    /// that silently stops persisting is the same shape as the defect this
    /// type exists to fix.
    var persistenceSuspensionReason: Error? {
      guard case let .unpreserved(error) = self else { return nil }
      return error
    }
  }

  /// Decides that policy for one load failure, performing the move when it
  /// applies.
  ///
  /// Only a decode failure counts as corruption. Any other read error —
  /// most importantly a data-protection-locked read during a background
  /// relaunch before first unlock — leaves a perfectly good file in place
  /// rather than quarantining it, at the cost of suspending writes for this
  /// store instance. Both branches keep the same guarantee: the existing
  /// bytes are never overwritten.
  static func resolve(
    loadFailure: Error,
    fileURL: URL,
    storeDescription: String,
    now: Date = Date()
  ) -> Outcome {
    guard loadFailure is DecodingError else {
      print(
        """
        Suspended \(storeDescription) persistence: the existing file could \
        not be read and must not be overwritten: \(loadFailure)
        """
      )
      return .unpreserved(loadFailure)
    }

    let timestampMilliseconds = Int64(
      (now.timeIntervalSince1970 * 1_000).rounded(.down)
    )
    let suffix = "corrupt-\(timestampMilliseconds)-\(UUID().uuidString.lowercased())"
    let quarantinedURL = fileURL.appendingPathExtension(suffix)
    do {
      try FileManager.default.moveItem(at: fileURL, to: quarantinedURL)
      print("Quarantined a corrupt \(storeDescription) file at \(quarantinedURL.path)")
      return .quarantined(quarantinedURL)
    } catch {
      print(
        """
        Suspended \(storeDescription) persistence: the corrupt file could \
        not be quarantined and must not be overwritten: \(error)
        """
      )
      return .unpreserved(error)
    }
  }
}
