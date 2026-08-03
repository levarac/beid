// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import Foundation

/// Owner-key-signed attestation that this device's per-event signing key
/// `K` observed peers for one event, over ENIN range
/// `[eninStart, eninEnd]` (`docs/specs/barnard-binding-conformance.md`
/// §2.2). A "holder-held artifact" — MUST NOT appear in Advertise data,
/// GATT values, public anchors, or witness blobs (Barnard's own spec,
/// quoted in §2.2); this is forward groundwork only, nothing in beid
/// consumes it yet (no verifier/credential-presentation flow exists).
///
/// Attached to the `Proof` it attests to via `proofId`, same relationship
/// `BindingRecord` has to its `Proof` — never embedded inside `Proof`
/// itself.
struct SelfProofRecord: Identifiable, Codable, Equatable, Hashable {
  let id: UUID
  let proofId: UUID
  let eventCode: String
  /// `EventIdHash.compute(eventCode:)`, hex-encoded.
  let eventIdHashHex: String
  /// Compressed secp256k1 per-event signing public key `K`, hex-encoded —
  /// the same key `BindingRecord.eventSigningPublicKeyHex` embeds.
  let eventSigningPublicKeyHex: String
  let eninStart: UInt64
  let eninEnd: UInt64
  /// Compressed secp256k1 owner public key, hex-encoded.
  let ownerPublicKeyHex: String
  let signatureRHex: String
  let signatureSHex: String
  let signatureV: Int
  let signedAt: Date

  init(
    proofId: UUID,
    eventCode: String,
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64,
    ownerPublicKey: Data,
    signature: BarnardCoreRecoverableSignature,
    signedAt: Date = Date()
  ) {
    self.id = UUID()
    self.proofId = proofId
    self.eventCode = eventCode
    self.eventIdHashHex = eventIdHash.hexString
    self.eventSigningPublicKeyHex = eventSigningPublicKey.hexString
    self.eninStart = eninStart
    self.eninEnd = eninEnd
    self.ownerPublicKeyHex = ownerPublicKey.hexString
    self.signatureRHex = Data(signature.r).hexString
    self.signatureSHex = Data(signature.s).hexString
    self.signatureV = signature.v
    self.signedAt = signedAt
  }
}

private extension Data {
  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
