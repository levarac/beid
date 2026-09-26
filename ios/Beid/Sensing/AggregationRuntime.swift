// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation

/// Thin adapter over shared's observation-aggregation API
/// (`BeidSharedKit.aggregation`, beid#109/#162/#142). Accumulates one
/// observation per detection and hands back the shared session aggregate —
/// device counts (all-observation and mutual scope) plus the window series —
/// as shared's own type, not a re-projection into new native properties.
///
/// Carries no counting logic of its own: `SensingCoordinator` supplies raw
/// observations (window index, per-window peer key, optional stable display
/// id), and shared decides distinctness. Follows the same shape as
/// `UnsentWindowLedgerRuntime`: translate native input, call shared once,
/// project the result back. Handing back `BeidSharedKit.aggregation
/// .SessionAggregate` itself (rather than unpacking every field into a
/// parallel native struct) keeps native callers reading values whose type
/// alone proves they are shared-sourced.
///
/// `mutual` is always passed as `false` today — no reciprocity signal exists
/// on-device yet (documented limitation carried from beid#109, not solved
/// here). Every mutual-scope field on the returned aggregate is therefore
/// `0` for as long as that remains true.
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

  /// The current session aggregate, recomputed fresh over every observation
  /// recorded so far — matches #109's "no subscription API, caller
  /// recomputes" contract (a session's observation count is small, so
  /// recomputing on every new observation is cheap). `windowsPerBand` is
  /// fixed at 1: nothing reads the band series yet, only the window series
  /// and the session-wide totals (#142).
  var sessionAggregate: BeidSharedKit.aggregation.SessionAggregate {
    BeidSharedKit.aggregation.aggregateObservationsForSession(
      input: input,
      windowsPerBand: 1
    )
  }
}
