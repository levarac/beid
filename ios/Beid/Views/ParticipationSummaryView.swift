// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import SwiftUI

/// Participation summary (beid#143): a post-session summary reachable from
/// `ItemDetailView`, showing the headline mutual-device count and a
/// time-band buildup for one finished session. See
/// `docs/specs/visibility-aggregation-ui.md` §4 for the full design
/// rationale and the acceptance-criteria mapping.
///
/// iOS-only for now: Android has no post-join screen flow at all yet
/// (AGENTS.md's current-state paragraph — `EventJoinCoordinator` stops at
/// `Idle`/`RequestingPermission`/`Sensing`/`PermissionDenied`), so there is
/// no Android surface for this to extend.
///
/// Historically scoped, per `Proof.id` (beid#166 Phase 1,
/// `SessionAggregateSnapshotStore.snapshot(proofId:)`) — reachable from
/// `ItemDetailView`, not the live/current session, mirroring
/// `TransparencyView`'s shape. `aggregate` is `nil` when no snapshot was
/// ever persisted for this proof: the session ended before beid#166 Phase
/// 2's session-end hook was wired (an old `Proof`), the persist failed at
/// session end (best-effort, can fail), or the session never reached
/// `.recording` at all. Renders identically to `TransparencyView`'s
/// not-yet-available treatment — never a fabricated zero, never a hidden
/// entry point.
///
/// The time-band buildup is a plain-text fallback, not a dot/step-row
/// visualization: the dot-row is an unratified DESIGN.md component with no
/// design sign-off (spec §3.4/§4.3, §9-7's ruling), the same posture
/// already applied to beid#142's window buildup — see
/// `RecordingView.windowBuildupCaption` for the precedent this matches in
/// tone and shape.
struct ParticipationSummaryView: View {
  let eventName: String
  /// `nil` when no session-aggregate snapshot exists for this proof — see
  /// the type doc comment above for the three reasons that can happen.
  let aggregate: BeidSharedKit.aggregation.SessionAggregate?
  /// beid#217: additive, defaults to `nil` at every existing call site, so
  /// this screen renders byte-for-byte as it does today whenever it is
  /// absent (spec §6.3.1/§6.4). When non-`nil` — set only by
  /// `SessionParticipationListView`'s per-row navigation — renders as a
  /// small secondary line under the header, so tapping session row 1 vs.
  /// row 2 of the same event does not land on two visually identical
  /// screens with no way to tell which session is being viewed.
  var sessionDate: Date? = nil

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
            BeidPanel { headlineRow }
            BeidPanel { bandBuildupSection }
          }
          .padding(BeidDesign.Spacing.screenHorizontal)
        }
      }
    }
    .background(DS.Color.surfaceCanvas)
    .navigationTitle("Participation summary")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      Text(verbatim: eventName)
        .font(DS.Font.sectionTitle)
        .foregroundStyle(DS.Color.textPrimary)
      if let sessionDate {
        Text(Self.dateFormatter.string(from: sessionDate))
          .font(DS.Font.supporting)
          .foregroundStyle(DS.Color.textSecondary)
      }
    }
  }

  // MARK: - Headline

  private var headlineRow: some View {
    Group {
      if let aggregate {
        BeidMetricRow(
          label: headlineLabelKey,
          verbatimValue: "\(Int(aggregate.mutualDeviceCount))"
        )
      } else {
        BeidMetricRow(
          label: headlineLabelKey,
          verbatimValue: notYetAvailableText,
          valueStyle: AnyShapeStyle(DS.Color.statusOff)
        )
      }
    }
  }

  private var headlineLabelKey: LocalizedStringKey { "Devices mutually confirmed" }

  // MARK: - Time-band buildup

  private var bandBuildupSection: some View {
    VStack(alignment: .leading, spacing: DS.Space.m) {
      Text("Time-band buildup")
        .font(DS.Font.supporting)
        .foregroundStyle(DS.Color.textSecondary)
      bandBuildupBody
    }
  }

  @ViewBuilder
  private var bandBuildupBody: some View {
    if let aggregate {
      if aggregate.bandCount > 0 {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
          ForEach(0..<aggregate.bandCount, id: \.self) { index in
            if let band = aggregate.bandAt(index: index) {
              Text(bandRowText(band))
                .font(DS.Font.meta)
                .foregroundStyle(DS.Color.textSecondary)
            }
          }
        }
      } else {
        Text("No time bands recorded for this session")
          .font(DS.Font.meta)
          .foregroundStyle(DS.Color.textSecondary)
      }
    } else {
      Text(notYetAvailableText)
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.statusOff)
    }
  }

  /// One row per present band, in ascending `bandIndex` order — sparse: a
  /// gap between two consecutive rows' `bandIndex` values means that time
  /// period was never recorded (spec §4.3, §6 "missing ≠ zero"; the
  /// underlying AC is "遅刻・中断があっても記録された範囲がそのまま見える (無い時間を
  /// 埋めない)"). Never zero-fills a missing band into this list.
  private func bandRowText(_ band: BeidSharedKit.aggregation.BandAggregate) -> String {
    let bandIndex = Int(band.bandIndex)
    let deviceCount = Int(band.deviceCount)
    return String(
      localized: "participationSummary.bandBuildup.row",
      defaultValue: "Band \(bandIndex): \(deviceCount) devices sensed",
      comment: "One row in the time-band buildup list on the Participation summary screen. The first number is the band's absolute index — bands are anchored at an absolute origin, not the session start, and a band spans a fixed count of ENIN time-windows, never a duration in seconds or minutes, so do not translate it as a clock time or a duration. The second number is the distinct-device count sensed during that band, over the all-observation scope (not the mutually-confirmed scope shown in the headline metric above this list) — do not translate this as mutual/reciprocal confirmation. A gap between two consecutive rows' band index numbers means that time period was not recorded at all (for example a late arrival or a signal-loss interruption), not that it recorded zero devices — never phrase this row or the list around it as if every band number appears."
    )
  }

  /// Reused for both the headline metric and the band-buildup section when
  /// `aggregate == nil` — an explicit key per AGENTS.md's reuse rule.
  /// Deliberately a distinct key from `TransparencyView`'s
  /// `transparency.notYetAvailable`, even though the English wording
  /// matches: that key's comment is scoped to `TransparencyView`'s own
  /// three reasons (no report-submission/verifier code exists yet), while
  /// this screen's "not yet available" reflects a different data gap (no
  /// persisted session-aggregate snapshot for this proof, per beid#166).
  private var notYetAvailableText: String {
    String(
      localized: "participationSummary.notYetAvailable",
      defaultValue: "Not yet available",
      comment: "Status shown on the Participation summary screen when no session-aggregate snapshot was ever persisted for this proof: the session ended before the snapshot-writing feature existed, the write failed (best-effort, can fail silently), or the session never reached the recording phase at all. This means the data was never captured, not that an attempt was made and failed — do not translate as an error, warning, or declined state, and do not confuse it with a real, present value of zero (this screen's headline metric can legitimately show a real 0, which is a different, available state)."
    )
  }
}

#Preview("With snapshot") {
  NavigationStack {
    ParticipationSummaryView(
      eventName: "ETHGlobal Tokyo",
      aggregate: PreviewAggregateFactory.sessionAggregate(
        observations: [
          (windowIndex: 0, peerKey: "peer-1", displayId: "device-1"),
          (windowIndex: 1, peerKey: "peer-2", displayId: "device-2"),
          (windowIndex: 5, peerKey: "peer-3", displayId: "device-3"),
        ],
        windowsPerBand: 2
      )
    )
  }
}

#Preview("With snapshot (Dark)") {
  NavigationStack {
    ParticipationSummaryView(
      eventName: "ETHGlobal Tokyo",
      aggregate: PreviewAggregateFactory.sessionAggregate(
        observations: [
          (windowIndex: 0, peerKey: "peer-1", displayId: "device-1"),
          (windowIndex: 1, peerKey: "peer-2", displayId: "device-2"),
          (windowIndex: 5, peerKey: "peer-3", displayId: "device-3"),
        ],
        windowsPerBand: 2
      )
    )
  }
  .preferredColorScheme(.dark)
}

#Preview("No snapshot yet") {
  NavigationStack {
    ParticipationSummaryView(eventName: "ETHGlobal Tokyo", aggregate: nil)
  }
}

/// beid#217: reached via `SessionParticipationListView`'s per-row
/// navigation — the additive `sessionDate` line under the header.
#Preview("Reached from session list") {
  NavigationStack {
    ParticipationSummaryView(
      eventName: "ETHGlobal Tokyo",
      aggregate: PreviewAggregateFactory.sessionAggregate(
        observations: [
          (windowIndex: 0, peerKey: "peer-1", displayId: "device-1"),
        ],
        windowsPerBand: 2
      ),
      sessionDate: Date().addingTimeInterval(-86400 * 5)
    )
  }
}

/// Preview-only helper: builds a real `BeidSharedKit.aggregation
/// .SessionAggregate` from plain observation tuples, the same shared call
/// production code uses, rather than a hand-rolled preview stand-in type.
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
