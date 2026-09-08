// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit

/// Preview-only helper: builds a real `BeidSharedKit.aggregation
/// .SessionAggregate` from plain observation tuples, through the same shared
/// call production code uses rather than a hand-rolled preview stand-in type.
///
/// One definition, deliberately. `ParticipationSummaryView` and
/// `SessionParticipationListView` each carried a `private enum` of this name
/// with byte-identical bodies, which is two places for one decision: a change
/// to how a preview aggregate is built had to be made twice, and a preview
/// that silently disagreed with its neighbour would look correct in isolation
/// on both sides. Consolidating it is beid#399's first item.
///
/// Kept internal rather than `private` so both call sites reach the same
/// symbol, and named without "demo" or "scenario" so it stays outside the
/// source walk in `ParticipantRelayIsolationTests` — that walk is scoped to
/// demo and scenario sources on purpose, and widening it by filename here
/// would be an accident rather than a decision.
enum PreviewAggregateFactory {
  static func sessionAggregate(
    observations: [(windowIndex: Int, peerKey: String, displayId: String?)],
    windowsPerBand: Int32
  ) -> BeidSharedKit.aggregation.SessionAggregate {
    let input = BeidSharedKit.aggregation.createAggregationObservationInput()
    for observation in observations {
      _ = BeidSharedKit.aggregation.addAggregationObservation(
        input: input,
        windowIndex: Int64(observation.windowIndex),
        peerKey: observation.peerKey,
        displayId: observation.displayId,
        mutual: false
      )
    }
    return BeidSharedKit.aggregation.aggregateObservationsForSession(
      input: input,
      windowsPerBand: windowsPerBand
    )
  }
}
