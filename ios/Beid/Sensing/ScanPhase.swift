// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Drives the scan modal's screens. `.verifying`/`.verified`/`.collected`
/// (pre-Slice-2) merge into `.recording`: window-based reporting has no
/// finish line, so there is no "verified" moment distinct from "still
/// recording," and no "collected" moment distinct from either — a `Proof`
/// exists in `ProofStore` from the instant `.recording` begins, not at a
/// later terminal step. See `docs/specs/scan-slice2-redesign.md` §4.2.
enum ScanPhase: Equatable {
  case idle
  case sensing
  case eventFound(EventSession)
  /// `peersVerified` is a cumulative, no-denominator count — the same
  /// counter used internally for the threshold-confirm check
  /// (`BeidConfig.eventConfirmThreshold`) and displayed as-is in the UI.
  case recording(event: EventSession, peersVerified: Int)
  /// Frozen count, resumable via `SensingCoordinator.resumeSensing()` —
  /// not a restart. Nothing already recorded is lost.
  case signalLost(event: EventSession, peersVerified: Int)
}
