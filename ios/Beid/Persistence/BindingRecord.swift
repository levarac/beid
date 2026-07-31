// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import Foundation

/// Evidence that a wallet endorsed this device's per-event signing key for
/// one event — the combined wallet `personal_sign` + device countersign
/// round trip (beid#33, `docs/specs/scan-slice2-redesign.md` §5.6). Mutual
/// signature: valid only with BOTH `walletSignatureHex` AND the device
/// countersign (`deviceSignature*`) — a third party cannot steal the
/// binding without the device holder's consent
/// (`scan-protocol-model.md` §4).
///
/// Attached to the `Proof` it endorses via `proofId`, same relationship
/// `WindowReport` has to its event via `eventCode` — never embedded inside
/// `Proof` itself (binding is optional enrichment, same contract
/// `signatureState` already has on `Proof`, extended to this new state).
struct BindingRecord: Identifiable, Codable, Equatable, Hashable {
  let id: UUID
  let proofId: UUID
  let eventCode: String
  let walletAddress: String
  /// Compressed secp256k1 per-event signing public key `K`, hex-encoded —
  /// the same key `BindingMessage.eventSigningPublicKey` embeds.
  let eventSigningPublicKeyHex: String
  /// The verifiable timestamp embedded in the signed `BindingMessage`, not
  /// the moment persistence happened.
  let boundAt: Date
  let walletSignatureHex: String
  let deviceSignatureRHex: String
  let deviceSignatureSHex: String
  let deviceSignatureV: Int

  init(
    proofId: UUID,
    eventCode: String,
    walletAddress: String,
    eventSigningPublicKey: Data,
    boundAt: Date,
    walletSignatureHex: String,
    deviceSignature: BarnardRecoverableSignature
  ) {
    self.id = UUID()
    self.proofId = proofId
    self.eventCode = eventCode
    self.walletAddress = walletAddress
    self.eventSigningPublicKeyHex = eventSigningPublicKey.hexString
    self.boundAt = boundAt
    self.walletSignatureHex = walletSignatureHex
    self.deviceSignatureRHex = deviceSignature.r.hexString
    self.deviceSignatureSHex = deviceSignature.s.hexString
    self.deviceSignatureV = deviceSignature.v
  }
}

private extension Data {
  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
