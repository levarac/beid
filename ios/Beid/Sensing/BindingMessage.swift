// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import Foundation

/// Canonical content of the wallet `personal_sign` + device countersign
/// binding round trip (beid#33, confirmed 2026-07-23): the wallet signs
/// "per-event signing pubkey K belongs to wallet W". `W` itself is never
/// embedded here — the act of signing is what proves `W`'s endorsement; this
/// type only fixes what `K` attests to and when, so both signatures commit
/// to the exact same bytes (`docs/specs/scan-slice2-redesign.md` §5.6,
/// `docs/specs/scan-protocol-model.md` §4/§6's "verifiable timestamp").
///
/// Exact byte layout was left as an implementation-time TBD by
/// `scan-slice2-redesign.md` §11 ("needs pinning down alongside whichever
/// wallet SDK integration lands it") — this is that pinning for sub-slice
/// 2b. Not a finished protocol/report wire format; see `EventCommitment` and
/// `SensingCoordinator.windowReportPayload` for the separate per-window
/// report payload, which this does not change.
struct BindingMessage: Equatable {
  private static let schemaTag = Data("beid-binding/v1".utf8)

  let eventCode: String
  /// Per-event signing public key `K`, compressed secp256k1 —
  /// `BarnardIdentity.signingPublicKey(eventCode:)`.
  let eventSigningPublicKey: Data
  /// The verifiable timestamp the protocol model requires in the signing
  /// payload (`scan-protocol-model.md` §6) so late binding can't be hidden;
  /// millisecond precision, truncated to whole milliseconds before signing.
  let issuedAt: Date

  /// Canonical bytes both signatures commit to: schema tag ‖ UTF-8
  /// `eventCode` ‖ compressed `eventSigningPublicKey` ‖ big-endian Int64
  /// Unix milliseconds. Fixed-order `‖`-concatenation (like `EventCommitment
  /// .compute` and `SensingCoordinator.windowReportPayload`'s big-endian
  /// ENIN encoding) rather than JSON, so the wallet's `personal_sign` digest
  /// and the device countersign (`BarnardIdentity.sign`, which hashes its
  /// own `bytes` argument internally) provably cover identical content.
  var canonicalBytes: Data {
    var bytes = Self.schemaTag
    bytes.append(Data(eventCode.utf8))
    bytes.append(eventSigningPublicKey)
    let millis = Int64((issuedAt.timeIntervalSince1970 * 1000).rounded())
    bytes.append(contentsOf: withUnsafeBytes(of: millis.bigEndian) { Array($0) })
    return bytes
  }

  /// What the wallet's `personal_sign` actually signs: SHA-256 of
  /// `canonicalBytes`, `0x`-prefixed hex. Mirrors `SignaturePayload
  /// .signingDigestHex()`'s convention — every `WalletConnector
  /// .requestPersonalSign` call site in this app (Coinbase/MetaMask/Reown)
  /// already expects a `0x`-prefixed hex digest as the "message" parameter,
  /// not a literal human-readable string.
  func walletDigestHex() -> String {
    "0x" + Data(BarnardCoreCrypto.sha256(Array(canonicalBytes))).hexString
  }
}

private extension Data {
  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
