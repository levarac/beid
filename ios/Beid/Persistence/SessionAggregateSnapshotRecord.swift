// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// One finished session's computed aggregate, persisted as opaque shared-encoded
/// text (beid#166). `snapshotText` is `BeidSharedKit.aggregation
/// .encodeSessionAggregateSnapshot`'s canonical output — this type never decodes
/// or interprets it; only `shared` does.
///
/// Unlike `SelfProofRecord`/`WindowReport`, there is no separate synthetic `id`:
/// `proofId` itself is this store's uniqueness key (beid#166's invariant is one
/// snapshot per proof, not "zero or more records referencing a proof"), so using
/// it directly as `Identifiable`'s `id` does not lose any information a fresh
/// random id would have carried.
struct SessionAggregateSnapshotRecord: Identifiable, Codable, Equatable {
  var id: UUID { proofId }

  let proofId: UUID
  let snapshotText: String
  let createdAt: Date

  init(proofId: UUID, snapshotText: String, createdAt: Date = Date()) {
    self.proofId = proofId
    self.snapshotText = snapshotText
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case proofId, snapshotText, createdAt
  }
}
