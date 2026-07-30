// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import Foundation

/// `commit = H(event signing key ‖ owner key ‖ salt)` — the opaque
/// per-event identity commitment carried on peer sightings (whitepaper
/// §3.2, `docs/specs/scan-protocol-model.md` §5). No wallet address ever
/// appears in it; contents are revealed only to a later verifier.
///
/// The exact wire byte layout (salt derivation/length, field order) is not
/// finalized — `docs/specs/scan-slice2-redesign.md` §11 — this computes the
/// hash for local use (the per-window report queue), not a finished wire
/// encoding.
enum EventCommitment {
  static func compute(eventSigningKey: Data, ownerKey: Data, salt: Data) -> Data {
    let message = Array(eventSigningKey) + Array(ownerKey) + Array(salt)
    return Data(BarnardCoreCrypto.sha256(message))
  }
}
