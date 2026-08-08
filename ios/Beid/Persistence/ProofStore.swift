// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// On-device JSON store for collected proofs. Chosen over SwiftData for this
/// slice: the data model is a single flat array with no relationships or
/// migrations yet, so a JSON file is the simplest thing that works — revisit
/// SwiftData once proofs need querying/relationships beyond a flat list.
@MainActor
final class ProofStore: ObservableObject {
  @Published private(set) var proofs: [Proof] = []

  /// Set when `load()` preserved a file that failed to decode, so the event
  /// is not invisible. Broader observability is beid#131's job.
  private(set) var quarantinedFileURL: URL?

  /// Set when the existing file could neither be read nor preserved.
  /// Saving would destroy bytes that were never captured, so this instance
  /// stops writing and keeps its proofs in memory only. Readable for the
  /// same reason `quarantinedFileURL` is: a `print` is invisible in a
  /// shipped build, and a store that silently stops persisting is the shape
  /// of the defect this file exists to fix.
  private(set) var persistenceSuspensionReason: Error?

  var isPersistenceSuspended: Bool { persistenceSuspensionReason != nil }

  private let fileURL: URL

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    load()
  }

  private static func defaultFileURL() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("proofs.json")
  }

  func add(_ proof: Proof) {
    proofs.insert(proof, at: 0)
    save()
  }

  func proof(withId id: UUID) -> Proof? {
    proofs.first { $0.id == id }
  }

  /// Updates only the signature lifecycle of an already-stored proof — the
  /// proof's own collected fields are immutable once added. No-op if the
  /// proof was removed since the caller last read it.
  func updateSignatureState(for id: UUID, to state: ProofSignatureState) {
    guard let index = proofs.firstIndex(where: { $0.id == id }) else { return }
    proofs[index].signatureState = state
    save()
  }

  /// Updates a recording proof's peer count in place as
  /// `SensingCoordinator` observes more distinct peers — the proof itself
  /// is created once, at the instant `.recording` begins, and never
  /// re-created (`docs/specs/scan-slice2-redesign.md` §4.6). No-op if the
  /// proof was removed since the caller last read it.
  func updatePeersVerified(for id: UUID, to peersVerified: Int) {
    guard let index = proofs.firstIndex(where: { $0.id == id }) else { return }
    proofs[index].peersVerified = peersVerified
    save()
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    var loaded: [Proof]
    do {
      let data = try Data(contentsOf: fileURL)
      loaded = try JSONDecoder().decode([Proof].self, from: data)
    } catch {
      // A file that fails to decode used to be discarded silently and then
      // destroyed by the next save, taking every stored proof with it
      // (beid#135). Preserve it first, then continue empty.
      let outcome = CorruptStoreQuarantine.resolve(
        loadFailure: error,
        fileURL: fileURL,
        storeDescription: "proof store"
      )
      quarantinedFileURL = outcome.quarantinedFileURL
      persistenceSuspensionReason = outcome.persistenceSuspensionReason
      return
    }

    // `.connecting`/`.awaitingApproval` are only meaningful while this
    // process is alive and actively waiting on a wallet response. If the
    // process was killed mid-wait (e.g. iOS jetsam while the user is
    // backgrounded approving in their wallet app — the prime scenario,
    // since that's exactly what the flow asks the user to do) and the
    // proof reloads still "awaiting approval", there is no live request to
    // ever resolve it: it would spin forever with no retry affordance.
    // Sanitize to `.deferred` on load so it's always retryable, matching
    // the "proof is untouched and safe to retry" contract in
    // `ProofSignature.swift`.
    var didSanitize = false
    for index in loaded.indices {
      switch loaded[index].signatureState {
      case .connecting, .awaitingApproval:
        loaded[index].signatureState = .deferred
        didSanitize = true
      case .notRequested, .signed, .deferred, .rejected, .failed:
        break
      }
    }

    proofs = loaded
    if didSanitize {
      save()
    }
  }

  private func save() {
    guard !isPersistenceSuspended else { return }
    guard let data = try? JSONEncoder().encode(proofs) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
