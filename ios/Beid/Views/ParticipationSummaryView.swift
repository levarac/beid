// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import SwiftUI

/// Participation summary (beid#143): a post-session summary reachable from
/// `ItemDetailView`, showing the headline mutual-device count and a
/// time-band buildup for one finished session. See
/// `docs/specs/visibility-aggregation-ui.md` §4 for the full design
/// rationale and the acceptance-criteria mapping.
///
/// iOS-only for now: Android's own record-detail screen
/// (`RecordDetailScreen`, `android/.../ui/screens/RecordDetailScreen.kt`,
/// beid#122) covers this same content — a devices-sensed metric row and a
/// time-band buildup section (unconditionally "Not yet available" today,
/// tracked by beid#327) — but was ported separately as a Compose composable
/// rather than sharing this SwiftUI view, per AGENTS.md's ownership boundary
/// (`shared/` owns decisions both platforms must answer identically; UI and
/// its presentation are native/product concerns on each side). This view
/// still has no Android counterpart being *shared*, only a
/// separately-implemented one with the same content.
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

  /// Unconditional — independent of whether `aggregate` exists, unlike
  /// `bandBuildupSection` below. The mutual (two-way) device count is
  /// structurally unmeasurable on-device by design (see
  /// `mutualCountUnavailableText`'s comment), not merely "not captured
  /// yet," so this never becomes a real value once a snapshot exists,
  /// unlike the band data `bandBuildupSection` legitimately gains.
  private var headlineRow: some View {
    BeidMetricRow(
      label: headlineLabelKey,
      verbatimValue: mutualCountUnavailableText,
      valueStyle: AnyShapeStyle(DS.Color.statusOff)
    )
  }

  private var headlineLabelKey: LocalizedStringKey { "Devices mutually confirmed" }

  /// Shared verbatim (same key/defaultValue/comment) with
  /// `SessionParticipationListView.mutualCountUnavailableText` — AGENTS.md's
  /// reuse rule.
  private var mutualCountUnavailableText: String {
    String(
      localized: "participationSummary.mutualCount.unavailable",
      defaultValue: "Not yet available",
      comment: "Value shown for the \"Devices mutually confirmed\" headline metric on the Participation summary screen — unconditionally, regardless of whether a session-aggregate snapshot exists for this proof. The mutual (two-way) device count cannot be measured on this device at all: the protocol only reports \"this device observed a peer,\" never \"the peer observed this device back,\" so establishing mutual confirmation requires reconciling two devices' signed records off-device (beid#144 stage 4, not yet built). This is a different, narrower reason than this screen's other \"Not yet available\" text (`participationSummary.notYetAvailable`, used when no session data was captured at all) — do not merge the two keys, and do not translate this as an error, warning, or declined state. Never show a numeric value (including 0) for this metric; DECISIONS 2026-08-20 (beid#222) settled that an honest-but-unmeasured 0 was read on real hardware as \"measured and got 0,\" which is misinformation."
    )
  }

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

  /// Used by `bandBuildupBody` only, when `aggregate == nil` — an explicit
  /// key per AGENTS.md's reuse rule. Deliberately a distinct key from
  /// `TransparencyView`'s `transparency.notYetAvailable`, even though the
  /// English wording matches: that key's comment is scoped to
  /// `TransparencyView`'s own three reasons (no report-submission/verifier
  /// code exists yet), while this screen's "not yet available" reflects a
  /// different data gap (no persisted session-aggregate snapshot for this
  /// proof, per beid#166). No longer reused by the headline metric (that
  /// row now always renders `mutualCountUnavailableText`, a narrower,
  /// distinct-reason key — beid#222).
  private var notYetAvailableText: String {
    String(
      localized: "participationSummary.notYetAvailable",
      defaultValue: "Not yet available",
      comment: "Status shown on the Participation summary screen when no session-aggregate snapshot was ever persisted for this proof: the session ended before the snapshot-writing feature existed, the write failed (best-effort, can fail silently), or the session never reached the recording phase at all. This means the data was never captured, not that an attempt was made and failed — do not translate as an error, warning, or declined state. Never confuse this key with `participationSummary.mutualCount.unavailable`, the headline metric's own \"not yet available\" text — a different, narrower reason (mutual confirmation is structurally unmeasurable on-device, not merely uncaptured)."
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
