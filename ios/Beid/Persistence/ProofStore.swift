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

  private func load() {
    guard let data = try? Data(contentsOf: fileURL) else { return }
    var loaded = (try? JSONDecoder().decode([Proof].self, from: data)) ?? []

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
    guard let data = try? JSONEncoder().encode(proofs) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
