// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// A confirmed or in-progress event in the scan phase machine. Replaces
/// `DemoEvent` as the single event type carried by `ScanPhase` — see
/// `docs/specs/scan-slice2-redesign.md` §3.
struct EventSession: Equatable, Identifiable {
  /// The event code (e.g. "ETHTOKYO2026") — what `BarnardEngine
  /// .joinEvent`/`.configure` already key on.
  let id: String
  /// The display value carried by the card. Real sensing sessions keep this
  /// equal to the raw event code; registry verification never replaces it
  /// with a definition display name. Demo fixtures may retain their existing
  /// review presentation.
  let name: String
  /// e.g. "Tokyo Big Sight". `nil` when the source (real or demo) has no
  /// venue to report — rendered as an absent line, never a placeholder.
  let venue: String?
  /// A canonical registry Event ID supplied as an untrusted routing hint. It
  /// is intentionally optional and is never itself proof of registration.
  let canonicalEventIdHex: String?
  /// Stable identity for one live session. `id` remains the raw event code for
  /// compatibility and card/proof semantics, so this UUID protects async
  /// completions when the same code is used by a later session.
  let sessionID: UUID
  /// Registry status is a separate axis from sensing phase and event naming.
  let identityVerification: EventIdentityVerification

  init(
    id: String,
    name: String,
    venue: String?,
    canonicalEventIdHex: String? = nil,
    sessionID: UUID = UUID(),
    identityVerification: EventIdentityVerification = .notChecked
  ) {
    self.id = id
    self.name = name
    self.venue = venue
    self.canonicalEventIdHex = canonicalEventIdHex
    self.sessionID = sessionID
    self.identityVerification = identityVerification
  }

  /// Returns a copy with only the registry status changed. All raw event
  /// identity fields and the stable session UUID remain untouched.
  func replacingIdentityVerification(
    _ identityVerification: EventIdentityVerification
  ) -> EventSession {
    EventSession(
      id: id,
      name: name,
      venue: venue,
      canonicalEventIdHex: canonicalEventIdHex,
      sessionID: sessionID,
      identityVerification: identityVerification
    )
  }
}
