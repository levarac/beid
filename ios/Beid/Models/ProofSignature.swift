// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import CryptoKit
import Foundation

/// Per-proof wallet-signature lifecycle. Deliberately decoupled from proof
/// collection/persistence: `ProofStore` already stores a `Proof` the instant
/// BLE evidence resolves, unconditionally, regardless of this state — see
/// `AppCoordinator.init`'s `onProofCollected` wiring. Signing is an optional
/// enrichment layered on top, never a gate.
///
/// A signature proves only that the connected wallet's key holder approved
/// `SignaturePayload`'s hash — it is not evidence of physical attendance
/// (that claim belongs to the BLE sensing that produced the `Proof` itself).
enum ProofSignatureState: Codable, Equatable, Hashable {
  case notRequested
  case connecting
  case awaitingApproval
  case signed(SignatureRecord)
  /// The request timed out waiting on the relay/wallet — the underlying
  /// proof is untouched and the user can retry later.
  case deferred
  /// The wallet explicitly declined the request (EIP-1193 code 4001).
  case rejected
  case failed(reason: String)
}

/// A completed wallet signature over `SignaturePayload`'s canonical digest.
struct SignatureRecord: Codable, Equatable, Hashable {
  let signerAddress: String
  let signatureHex: String
  let payload: SignaturePayload
  let signedAt: Date
}

/// **PROVISIONAL — not the protocol's self-proof.** This schema is a local
/// convenience signature only. It is unconnected to barnard's per-event
/// signing key / RPID-ownership proof, to whitepaper §3.4's EAS
/// EventGraphCommitment, or to §3.5's three-leg credential model. The
/// whitepaper's §3.2 "self-proof" leg explicitly calls for a separate
/// **account key** (distinct from the per-event key barnard already
/// implements) — whether the wallet key fills that role is an open protocol
/// design question, deliberately left "仮決めでよい" at the 2026-07-09 MTG.
/// No backend/verifier may depend on this payload. See beid#33 before
/// changing this schema or building anything against it.
///
/// Canonical, versioned payload a wallet signs for a given `Proof` — never
/// the raw `Proof` fields directly. Schema `AttendanceProof/v1`:
///
/// ```
/// {
///   "schema": "AttendanceProof/v1",
///   "proofId": "<Proof.id, UUID>",       // stands in for eventId: the
///                                        // unique identifier of the thing
///                                        // being attested, since this
///                                        // codebase has no separate
///                                        // event-id concept (DemoEvent is
///                                        // name-only)
///   "proofHash": "<sha256 hex of the collected-proof's own fields>",
///   "nonce": "<random UUID, one per signing attempt>",
///   "issuedAt": "<ISO 8601>",
///   "expiresAt": "<ISO 8601, issuedAt + validity window>",
///   "chainId": "<CAIP-2, e.g. eip155:1, the signing account's chain>"
/// }
/// ```
///
/// The wallet is never shown this JSON directly: `signingDigestHex()` hashes
/// the canonical (sorted-key) JSON encoding again, and that digest — not
/// the proof, not the JSON — is what `personal_sign` actually signs. This
/// keeps the signed message fixed-size and keeps `nonce`/`expiresAt` inside
/// what's cryptographically covered, so a captured signature can't be
/// replayed against a different signing attempt for the same proof.
struct SignaturePayload: Codable, Equatable, Hashable {
  static let schemaVersion = "AttendanceProof/v1"
  /// Signature requests are valid for 10 minutes from issuance — long enough
  /// to cover relay round-trips and wallet-approval latency, short enough
  /// that a stale, unsigned request can't be replayed much later.
  static let validityWindow: TimeInterval = 600

  let schema: String
  let proofId: UUID
  let proofHash: String
  let nonce: String
  let issuedAt: Date
  let expiresAt: Date
  let chainId: String

  init(proof: Proof, chainId: String, issuedAt: Date = Date()) {
    self.schema = Self.schemaVersion
    self.proofId = proof.id
    self.proofHash = Self.hash(of: proof)
    self.nonce = UUID().uuidString
    self.issuedAt = issuedAt
    self.expiresAt = issuedAt.addingTimeInterval(Self.validityWindow)
    self.chainId = chainId
  }

  /// SHA-256 of the collected proof's own fields (excluding this payload's
  /// signing metadata) — what identifies *which* proof was approved.
  private static func hash(of proof: Proof) -> String {
    let canonical = [
      proof.id.uuidString,
      proof.eventName,
      String(proof.date.timeIntervalSince1970),
      proof.method,
      String(proof.peersVerified),
    ].joined(separator: "|")
    return SHA256.hash(data: Data(canonical.utf8)).hexString
  }

  /// The exact bytes handed to `personal_sign`: SHA-256 of this payload's
  /// own canonical (sorted-key, ISO 8601 dates) JSON encoding, hex-encoded
  /// with a `0x` prefix.
  func signingDigestHex() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(self)
    return "0x" + SHA256.hash(data: data).hexString
  }
}

private extension SHA256Digest {
  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
