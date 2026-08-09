// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation

/// Thin adapter over shared's observation-aggregation API
/// (`BeidSharedKit.aggregation`, beid#109/#162). Accumulates one observation
/// per detection and projects the shared session aggregate's
/// all-observation device count back to a native-facing value.
///
/// Carries no counting logic of its own: `SensingCoordinator` supplies raw
/// observations (window index, per-window peer key, optional stable display
/// id), and shared decides distinctness. Follows the same shape as
/// `UnsentWindowLedgerRuntime`: translate native input, call shared once,
/// project the result back.
///
/// `mutual` is always passed as `false` today — no reciprocity signal exists
/// on-device yet (documented limitation carried from beid#109, not solved
/// here). This type reads only the all-observation scope; it never surfaces
/// the `mutual*` fields.
final class AggregationRuntime {
  private var input: BeidSharedKit.aggregation.AggregationObservationInput

  init() {
    input = BeidSharedKit.aggregation.createAggregationObservationInput()
  }

  /// Records one detection as an observation. `windowIndex` is the ENIN
  /// window the detection occurred in; `peerKey` is the per-window proximity
  /// identifier (rotates every window by design); `displayId` is the stable
  /// per-event identifier when B003 succeeded, `nil` otherwise. Returns
  /// whether shared accepted it (boundary shape check only — null, length,
  /// capacity); a caller passing values sourced from a real detection is not
  /// expected to see `false`.
  @discardableResult
  func recordObservation(windowIndex: Int, peerKey: String, displayId: String?) -> Bool {
    BeidSharedKit.aggregation.addAggregationObservation(
      input: input,
      windowIndex: Int64(windowIndex),
      peerKey: peerKey,
      displayId: displayId,
      mutual: false
    )
  }

  /// The session-wide device count observed so far, at all-observation
  /// scope. A lower bound, not an exact figure — shared's own documented
  /// limitation, since a 4-byte display id can in principle collide across
  /// two real devices.
  var deviceCount: Int {
    // `windowsPerBand` only affects the band series, which this adapter does
    // not read; any valid (>= 1) width works, so a fixed 1 keeps this call
    // unconditional. `Int(...)` normalizes shared's Kotlin `Int` result to
    // Swift's native `Int` width regardless of the exact Swift Export
    // integer mapping.
    Int(
      BeidSharedKit.aggregation.aggregateObservationsForSession(
        input: input,
        windowsPerBand: 1
      ).deviceCount
    )
  }
}
