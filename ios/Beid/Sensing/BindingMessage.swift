// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import Foundation

/// Canonical content of the wallet `personal_sign` step in the wallet
/// connect+binding round trip (beid#33, gh#88) — the literal
/// `barnard-account-binding:v1` text a Barnard-conformant verifier expects
/// (`docs/specs/barnard-binding-conformance.md` §2.3), built via
/// `BarnardCoreSigning.buildAccountBindingText`. Replaces the old
/// beid-native scheme, where the wallet signed a bare SHA-256 digest of
/// beid's own byte layout: the wallet now signs the literal ~400-byte
/// human-readable text itself (EIP-191), so wallet apps can render the
/// statement instead of falling back to an opaque-hex blind-sign warning
/// (§3).
///
/// Fixed once per binding attempt and reused across both the wallet
/// signature and the later owner-key wallet-ack (§2.4), so both reference
/// the identical `nonce`/`issuedAt` — recomputing either between the two
/// steps would desync them (mirrors the old `BindingMessage`'s same
/// invariant, `SensingCoordinator.pendingBindingMessage`).
struct BindingMessage: Equatable {
  /// Resolved 2026-08-03 (decision 6.a): the literal example domain from
  /// Barnard's own worked example and pinned test vector. Not a domain
  /// beid currently serves or proves ownership of (§6.a) — Barnard's own
  /// validation treats the domain as an opaque label, not a fetched URL.
  static let domain = "beid.levarac.org"

  let walletAddress: Data
  let ownerPublicKey: Data
  let chainId: UInt64
  let nonce: Data
  /// RFC 3339 UTC, second precision (`YYYY-MM-DDTHH:MM:SSZ`) — the exact
  /// literal string both signatures' content ultimately references.
  /// Carried as the already-formatted `String` (via
  /// `canonicalIssuedAt(_:)`), not a `Date` reformatted at each use site,
  /// so there is exactly one formatting call per attempt and no risk of
  /// the stored/signed text drifting from a later re-derivation.
  let issuedAt: String

  /// The literal canonical text, or `nil` if any field fails Barnard's own
  /// shape validation (`BarnardCoreSigning.buildAccountBindingText`) —
  /// should not happen in practice given this type's fields are only ever
  /// constructed from already-validated shapes (`SensingCoordinator
  /// .beginBinding`), but the underlying API is optional so this stays
  /// optional too rather than asserting.
  func canonicalText() -> String? {
    BarnardCoreSigning.buildAccountBindingText(
      domain: Self.domain,
      walletAddress: Array(walletAddress),
      ownerPublicKey: Array(ownerPublicKey),
      chainId: chainId,
      nonce: Array(nonce),
      issuedAt: issuedAt
    )
  }

  /// What the wallet's `personal_sign` actually signs: `0x`-prefixed hex of
  /// the canonical text's UTF-8 bytes (not a digest of it) — every
  /// `WalletConnector.requestPersonalSign` call site already accepts a
  /// `0x`-prefixed hex string as an opaque "message" parameter and never
  /// inspects its length, so only what the hex decodes to changes
  /// (`docs/specs/barnard-binding-conformance.md` §2.3).
  func walletMessageHex() -> String? {
    guard let text = canonicalText() else { return nil }
    return "0x" + Data(text.utf8).hexString
  }

  /// Formats `date` as the RFC 3339 UTC second-precision string
  /// `BarnardCoreSigning.buildAccountBindingText`'s own validation
  /// requires (`YYYY-MM-DDTHH:MM:SSZ`, no fractional seconds, literal `Z`).
  static func canonicalIssuedAt(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return formatter.string(from: date)
  }
}

private extension Data {
  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
