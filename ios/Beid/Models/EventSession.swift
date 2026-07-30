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
}
