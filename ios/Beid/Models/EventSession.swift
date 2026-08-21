// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// A confirmed or in-progress event in the scan phase machine. Replaces
/// `DemoEvent` as the single event type carried by `ScanPhase` — see
/// `docs/specs/scan-slice2-redesign.md` §3.
struct EventSession: Equatable, Identifiable {
  /// The event code (e.g. "ETHTOKYO2026") — what `BarnardEngine
  /// .joinEvent`/`.configure` already key on.
  let id: String
  /// Display name, e.g. "ETH Tokyo 2026".
  let name: String
  /// e.g. "Tokyo Big Sight". `nil` when the source (real or demo) has no
  /// venue to report — rendered as an absent line, never a placeholder.
  let venue: String?
  /// The canonical registry Event ID resolved for this joined event. It is
  /// intentionally optional at this boundary because the current manual
  /// event-code entry path does not resolve registry definitions yet; the
  /// submission runtime fails closed when it is absent.
  let canonicalEventIdHex: String?

  init(
    id: String,
    name: String,
    venue: String?,
    canonicalEventIdHex: String? = nil
  ) {
    self.id = id
    self.name = name
    self.venue = venue
    self.canonicalEventIdHex = canonicalEventIdHex
  }
}
