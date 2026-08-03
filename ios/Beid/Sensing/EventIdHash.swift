// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import Foundation

/// `eventIdHash` input to the self-proof message
/// (`docs/specs/barnard-binding-conformance.md` §2.2) — Barnard requires a
/// 32-byte digest; beid's `eventCode` is a `String`. Barnard's own spec does
/// not mandate a specific mapping, only that the input is 32 bytes; this
/// follows the spec document's own recommendation, `SHA256(UTF8(eventCode))`.
enum EventIdHash {
  static func compute(eventCode: String) -> Data {
    Data(BarnardCoreCrypto.sha256(Array(eventCode.utf8)))
  }
}
