// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// In-progress self-proof state (`docs/specs/session-end-finalization.md`
/// §7.1 Option B, §8.3), durably checkpointed on every real window rotation
/// so a device kill after binding completes but before session end still
/// leaves enough to reconstruct the self-proof on next launch
/// (`SensingCoordinator.reconcileSelfProofCheckpointIfNeeded()`).
///
/// Deliberately not added as fields on `SelfProofRecord` (spec §5) — this is
/// intermediate, in-progress state, cleared the moment a real
/// `SelfProofRecord` exists for `proofId`, either because the session ended
/// gracefully or because reconciliation itself just produced one.
struct SelfProofCheckpoint: Codable, Equatable {
  let proofId: UUID
  let eventCode: String
  let eninStart: UInt64
  let eninEnd: UInt64
}
