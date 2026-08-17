// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import SwiftUI

/// beid#217: a pure router into `ParticipationSummaryView` for a
/// multi-session event — one row per session, each pushing the *same*,
/// unmodified `ParticipationSummaryView`, scoped to its own proof. Never
/// presents one aggregate as if it covered the whole event; see
/// `docs/specs/collection-event-aggregation.md` §6.3.
///
/// Stays a pure display component with no coordinator dependency, matching
/// `ParticipationSummaryView`'s own existing shape (`eventName` + data in,
/// no store/coordinator ref) — `ItemDetailView` resolves the
/// `(proof, aggregate)` pairs before constructing this view.
struct SessionParticipationListView: View {
  let eventName: String
  let sessions: [(proof: Proof, aggregate: BeidSharedKit.aggregation.SessionAggregate?)]

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    return formatter
  }()

  var body: some View {
    ScrollView {
      BeidAdaptiveContent {
        BeidGlassGroup(spacing: BeidDesign.Spacing.section) {
          VStack(alignment: .leading, spacing: BeidDesign.Spacing.section) {
            header
            BeidPanel {
              VStack(alignment: .leading, spacing: DS.Space.m) {
                ForEach(Array(sessions.enumerated()), id: \.offset) { index, session in
                  if index > 0 {
                    Divider()
                  }
                  sessionRow(session)
                }
              }
            }
          }
          .padding(BeidDesign.Spacing.screenHorizontal)
        }
      }
    }
    .background(DS.Color.surfaceCanvas)
    // Reuses the same nav title as the single-session destination: from the
    // user's perspective this list *is* the participation summary for the
    // event, just structured as a list when there is more than one session
    // to show (spec §6.3).
    .navigationTitle("Participation summary")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      Text(verbatim: eventName)
        .font(DS.Font.sectionTitle)
        .foregroundStyle(DS.Color.textPrimary)
      Text(headerCountText)
        .font(DS.Font.supporting)
        .foregroundStyle(DS.Color.textSecondary)
    }
  }

  private var headerCountText: String {
    String(
      localized: "participationSummary.sessionList.header",
      defaultValue: "^[\(sessions.count) sessions](inflect: true) recorded for this event",
      comment: "Header above the per-session list on the Participation summary screen for an event recorded more than once. Count of distinct recording sessions for this event, not devices."
    )
  }

  private func sessionRow(
    _ session: (proof: Proof, aggregate: BeidSharedKit.aggregation.SessionAggregate?)
  ) -> some View {
    NavigationLink {
      ParticipationSummaryView(
        eventName: eventName,
        aggregate: session.aggregate,
        sessionDate: session.proof.date
      )
    } label: {
      HStack(alignment: .firstTextBaseline) {
        Text(Self.dateFormatter.string(from: session.proof.date))
          .font(DS.Font.cardTitle)
          .foregroundStyle(DS.Color.textPrimary)
        Spacer(minLength: DS.Space.m)
        trailingValue(for: session.aggregate)
        Image(systemName: "chevron.right")
          .font(DS.Font.meta)
          .foregroundStyle(DS.Color.textSecondary)
          .accessibilityHidden(true)
      }
      .frame(minHeight: DS.Size.minHitTarget)
    }
  }

  @ViewBuilder
  private func trailingValue(for aggregate: BeidSharedKit.aggregation.SessionAggregate?) -> some View {
    if let aggregate {
      Text(mutualCountText(for: aggregate))
        .font(DS.Font.supporting)
        .foregroundStyle(DS.Color.textSecondary)
    } else {
      Text(notYetAvailableText)
        .font(DS.Font.supporting)
        .foregroundStyle(DS.Color.statusOff)
    }
  }

  private func mutualCountText(for aggregate: BeidSharedKit.aggregation.SessionAggregate) -> String {
    String(
      localized: "participationSummary.sessionList.row.mutualCount",
      defaultValue: "\(Int(aggregate.mutualDeviceCount)) confirmed",
      comment: "Trailing value on one row of the per-session list on the Participation summary screen: the mutually-confirmed device count for that one specific session, matching the scope of the headline metric shown on the single-session Participation summary screen. Not a duration, not an index, not the event-wide Transparency count."
    )
  }

  /// Reused verbatim from `ParticipationSummaryView` — same meaning (no
  /// session-aggregate snapshot was ever persisted for this proof), now
  /// also read per-row instead of full-screen only. Must not be duplicated
  /// under a new key (spec §6.3/§8).
  private var notYetAvailableText: String {
    String(
      localized: "participationSummary.notYetAvailable",
      defaultValue: "Not yet available",
      comment: "Status shown on the Participation summary screen when no session-aggregate snapshot was ever persisted for this proof: the session ended before the snapshot-writing feature existed, the write failed (best-effort, can fail silently), or the session never reached the recording phase at all. This means the data was never captured, not that an attempt was made and failed — do not translate as an error, warning, or declined state, and do not confuse it with a real, present value of zero (this screen's headline metric can legitimately show a real 0, which is a different, available state)."
    )
  }
}

#Preview("Multiple sessions") {
  NavigationStack {
    SessionParticipationListView(
      eventName: "ETHGlobal Tokyo",
      sessions: [
        (
          proof: Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 5, eventCode: "ETHTOKYO"),
          aggregate: PreviewAggregateFactory.sessionAggregate(
            observations: [
              (windowIndex: 0, peerKey: "peer-1", displayId: "device-1"),
              (windowIndex: 1, peerKey: "peer-2", displayId: "device-2"),
            ],
            windowsPerBand: 2
          )
        ),
        (
          proof: Proof(
            eventName: "ETHGlobal Tokyo", date: Date().addingTimeInterval(-86400 * 5),
            peersVerified: 3, eventCode: "ETHTOKYO"
          ),
          aggregate: nil
        ),
      ]
    )
  }
}

#Preview("Multiple sessions (Dark)") {
  NavigationStack {
    SessionParticipationListView(
      eventName: "ETHGlobal Tokyo",
      sessions: [
        (
          proof: Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 5, eventCode: "ETHTOKYO"),
          aggregate: PreviewAggregateFactory.sessionAggregate(
            observations: [
              (windowIndex: 0, peerKey: "peer-1", displayId: "device-1"),
              (windowIndex: 1, peerKey: "peer-2", displayId: "device-2"),
            ],
            windowsPerBand: 2
          )
        ),
        (
          proof: Proof(
            eventName: "ETHGlobal Tokyo", date: Date().addingTimeInterval(-86400 * 5),
            peersVerified: 3, eventCode: "ETHTOKYO"
          ),
          aggregate: nil
        ),
      ]
    )
  }
  .preferredColorScheme(.dark)
}

/// Preview-only helper: builds a real `BeidSharedKit.aggregation
/// .SessionAggregate` from plain observation tuples — the same shared call
/// production code uses, matching `ParticipationSummaryView`'s own preview
/// helper of the same name rather than a hand-rolled preview stand-in type.
private enum PreviewAggregateFactory {
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
