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
        trailingValue
        Image(systemName: "chevron.right")
          .font(DS.Font.meta)
          .foregroundStyle(DS.Color.textSecondary)
          .accessibilityHidden(true)
      }
      .frame(minHeight: DS.Size.minHitTarget)
    }
  }

  /// beid#222, DECISIONS 2026-08-20: the mutual (two-way) device count
  /// cannot be measured on-device at all — same reason as
  /// `ParticipationSummaryView.headlineRow`, which this row duplicates on a
  /// per-session basis via its own `mutualDeviceCount` read. In scope for
  /// the same fix because it renders that identical, structurally
  /// unmeasurable metric a second time. Unconditional, independent of
  /// whether `aggregate` exists for this session — never a literal number,
  /// including 0.
  private var trailingValue: some View {
    Text(mutualCountUnavailableText)
      .font(DS.Font.supporting)
      .foregroundStyle(DS.Color.statusOff)
  }

  /// Shared verbatim (same key/defaultValue/comment) with
  /// `ParticipationSummaryView.mutualCountUnavailableText` — AGENTS.md's
  /// reuse rule.
  private var mutualCountUnavailableText: String {
    String(
      localized: "participationSummary.mutualCount.unavailable",
      defaultValue: "Not yet available",
      comment: "Value shown for the \"Devices mutually confirmed\" headline metric on the Participation summary screen — unconditionally, regardless of whether a session-aggregate snapshot exists for this proof. The mutual (two-way) device count cannot be measured on this device at all: the protocol only reports \"this device observed a peer,\" never \"the peer observed this device back,\" so establishing mutual confirmation requires reconciling two devices' signed records off-device (beid#144 stage 4, not yet built). This is a different, narrower reason than this screen's other \"Not yet available\" text (`participationSummary.notYetAvailable`, used when no session data was captured at all) — do not merge the two keys, and do not translate this as an error, warning, or declined state. Never show a numeric value (including 0) for this metric; DECISIONS 2026-08-20 (beid#222) settled that an honest-but-unmeasured 0 was read on real hardware as \"measured and got 0,\" which is misinformation."
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
