// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Signal B of gh#156's regeneration-detectability mechanism
/// (`docs/specs/owner-key-seed-read-failure.md` §8): does any
/// already-persisted self-proof/binding record's owner public key differ
/// from the one currently active? A mismatch is evidence the owner key
/// changed since that record was created — regardless of cause, which is
/// what makes this signal broader than (but complementary to)
/// `OwnerKeyProvider.quarantinedSeedKey` (Signal A, precise about cause but
/// narrow to this fix's own failure mode). Both records' `ownerPublicKeyHex`
/// already existed for an unrelated reason (§3.5) — no new persisted field.
///
/// A pure comparison, decoupled from `SensingCoordinator`'s own lifecycle,
/// so it is directly testable without constructing the coordinator's BLE
/// engine or file-backed stores.
enum OwnerKeyRegenerationDetector {
  static func ownerPublicKeyMismatchDetected(
    activeOwnerPublicKey: Data,
    selfProofRecords: [SelfProofRecord],
    bindingRecords: [BindingRecord]
  ) -> Bool {
    let activeHex = activeOwnerPublicKey.hexString
    return selfProofRecords.contains { $0.ownerPublicKeyHex != activeHex }
      || bindingRecords.contains { $0.ownerPublicKeyHex != activeHex }
  }
}

private extension Data {
  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
