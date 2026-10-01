// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import Security

/// The randomness port for Sigil presence tokens (beid#653,
/// `docs/decisions/issue-653-design.md` §1.1). `shared/` never generates a
/// token itself; it assigns the ones supplied here, verbatim, to display ids
/// in first-seen order.
///
/// A token is random, never derived from a display id, so a stored token says
/// nothing about the peer and the same peer gets an unrelated token in every
/// record. `nil` means "no token could be drawn": the caller then assigns
/// nothing, and a record whose peers are not all tokened is never written.
protocol SigilPresenceTokenSource {
  func nextToken() -> String?
}

/// 16 bytes from `SecRandomCopyBytes`, as 32 lowercase hex characters.
///
/// Checks the status, unlike `BeidSystemRandomSource`
/// (`OwnerKeyProvider.swift`), which ignores it: a failed call leaves the
/// buffer zeroed, and repeated zero tokens would merge every peer into one.
/// Shared also refuses a duplicate token and fails the record, so a broken
/// source can never draw a wrong Sigil; this check makes it fail earlier.
struct SystemSigilPresenceTokenSource: SigilPresenceTokenSource {
  func nextToken() -> String? {
    var bytes = [UInt8](repeating: 0, count: 16)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else { return nil }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }
}
