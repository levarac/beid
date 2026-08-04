// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import Foundation

/// Evidence that a wallet endorsed this device's app-generated owner key —
/// the combined wallet `personal_sign` (over the `barnard-account-binding:v1`
/// canonical text) + owner-key wallet-ack (`barnard-wallet-ack:v1`) round
/// trip (beid#33, gh#88, `docs/specs/barnard-binding-conformance.md` §2.3/
/// §2.4). Mutual signature: valid only with BOTH `walletSignatureHex` AND
/// the owner-key acknowledgement (`deviceSignature*`) — a third party
/// cannot steal the binding without the device holder's consent
/// (`scan-protocol-model.md` §4).
///
/// `deviceSignatureRHex`/`SHex`/`V`'s field names are unchanged from the
/// pre-conformance scheme even though their signer changed (event signing
/// key K → owner key) — the on-disk `Codable` shape is deliberately stable
/// (§2.4's plumbing note, §6.d); `binding-records-v2.json`'s filename, not
/// a field rename, is what marks the cryptographic-meaning break.
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
  /// Compressed secp256k1 per-event signing public key `K` active during
  /// this session. No longer referenced by the signed binding text itself
  /// (§2.3 binds wallet↔owner key, not wallet↔K) — kept as beid-side
  /// bookkeeping only, to correlate this record with the session's
  /// self-proof (`SelfProofRecord.eventSigningPublicKeyHex`).
  let eventSigningPublicKeyHex: String
  /// The owner key the wallet endorsed — embedded in, and covered by, the
  /// wallet's EIP-191 signature over the canonical binding text. Required
  /// (along with `chainId`/`nonceHex`/`issuedAt` below) for a conformant
  /// verifier to reconstruct that exact text and check the signature
  /// against it (`BarnardCoreSigning.verifyWalletBinding`).
  let ownerPublicKeyHex: String
  let chainId: UInt64
  let nonceHex: String
  /// RFC 3339 UTC, second precision — the literal string embedded in (and
  /// covered by) the signed canonical binding text, not re-derived from a
  /// stored `Date` (`BindingMessage.issuedAt`).
  let issuedAt: String
  let walletSignatureHex: String
  let deviceSignatureRHex: String
  let deviceSignatureSHex: String
  let deviceSignatureV: Int

  init(
    proofId: UUID,
    eventCode: String,
    walletAddress: String,
    eventSigningPublicKey: Data,
    ownerPublicKey: Data,
    chainId: UInt64,
    nonce: Data,
    issuedAt: String,
    walletSignatureHex: String,
    deviceSignature: BarnardCoreRecoverableSignature
  ) {
    self.id = UUID()
    self.proofId = proofId
    self.eventCode = eventCode
    self.walletAddress = walletAddress
    self.eventSigningPublicKeyHex = eventSigningPublicKey.hexString
    self.ownerPublicKeyHex = ownerPublicKey.hexString
    self.chainId = chainId
    self.nonceHex = nonce.hexString
    self.issuedAt = issuedAt
    self.walletSignatureHex = walletSignatureHex
    self.deviceSignatureRHex = Data(deviceSignature.r).hexString
    self.deviceSignatureSHex = Data(deviceSignature.s).hexString
    self.deviceSignatureV = deviceSignature.v
  }
}

private extension Data {
  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
