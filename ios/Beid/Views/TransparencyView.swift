// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Transparency view (beid#137): separates 参加操作 (join action) / 参加記録
/// (participation record) / 検証済みの参加証明 (verified proof) into three
/// distinct tiers, so a "not yet available" sub-state never reads as a
/// false negative for something else. See
/// `docs/specs/visibility-aggregation-ui.md` §5 for the full design
/// rationale and the acceptance-criteria mapping.
///
/// iOS-only for now: Android's own record-detail screen
/// (`RecordDetailScreen`, `android/.../ui/screens/RecordDetailScreen.kt`,
/// beid#122) covers this same content — self-proof/binding presence and a
/// mutual-confirmation row — but was ported separately as a Compose
/// composable rather than sharing this SwiftUI view, per AGENTS.md's
/// ownership boundary (`shared/` owns decisions both platforms must answer
/// identically; UI and its presentation are native/product concerns on each
/// side). This view still has no Android counterpart being *shared*, only a
/// separately-implemented one with the same content.
///
/// Historically scoped, per `Proof` (DECISIONS 2026-08-09 "#137 は履歴スコープ
/// を採り、Proof に eventCode を optional で追加する") — reachable from
/// `ItemDetailView`, not the live/current session. `recordedOnDeviceCount`
/// is computed by the caller from `SensingCoordinator
/// .recordedWindowCount(forEventCode:)` filtered against `Proof.eventCode`;
/// it is `nil` for any proof persisted before that field existed, and
/// renders identically to the other not-yet-available sub-states below it
/// — never a false zero.
struct TransparencyView: View {
  let eventName: String
  /// Tier 1 (参加操作): whether this device has joined the event this
  /// screen is about. Always a known, live fact — never "not yet
  /// available" — so it is rendered as plain value text, not the
  /// availability-gap treatment Tiers 2/3 use below. Always `true` from
  /// this screen's only call site (`ItemDetailView`), since a stored
  /// `Proof` cannot exist without having joined — see the type doc
  /// comment above.
  let hasJoined: Bool
  /// Tier 2 (参加記録), first sub-state (端末内に記録済み): the number of
  /// ENIN windows locally signed and stored for this event so far. `nil`
  /// means the calling `Proof` predates `Proof.eventCode` (see the type
  /// doc comment above), and renders exactly like "Sent"/"Included in
  /// published data" below it — an honest "not yet available," never a
  /// fabricated zero.
  let recordedOnDeviceCount: Int?
  /// Tier 2 count of legacy windows that only retained a device count and
  /// therefore can never become a canonical report-server submission.
  /// `nil` uses the same honest-gap treatment as the adjacent count.
  let excludedWindowCount: Int?
  /// Tier 2 (参加記録), third and fourth sub-states (送信済み / 受領確認済み):
  /// the most-advanced durable state of this event's report submissions,
  /// read from `SensingCoordinator.submissionState(forEventCode:)` (beid#292).
  /// Event-code scoped like `recordedOnDeviceCount` above, for the same
  /// historically-scoped reason (this screen's type doc comment) — not a
  /// second design decision, matching the convention that property already
  /// established. `nil` renders both the "Sent" and "Acceptance receipt"
  /// rows as "not yet available," identically to a legacy proof with no
  /// `eventCode` — this is honest either when report submission is gated
  /// off in production (`BeidReportSubmissionEnabled`) or when this event
  /// simply has no submission queued yet; never a false negative for either.
  let submissionState: ReportSubmissionState?

  var body: some View {
    ScrollView {
      BeidAdaptiveContent {
        VStack(alignment: .leading, spacing: DS.Space.l) {
          header
          participationPanel
          participationRecordPanel
          verifiedProofPanel
        }
        .padding(DS.Space.pageMargin)
      }
    }
    .background(DS.Color.surfaceCanvas)
    .navigationTitle("Transparency")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var header: some View {
    Text(verbatim: eventName)
      .font(DS.Font.sectionTitle)
      .foregroundStyle(DS.Color.textPrimary)
  }

  private var participationPanel: some View {
    BeidPanel {
      VStack(alignment: .leading, spacing: DS.Space.s) {
        tierTitle(
          "Participation",
          comment: "Tier 1 of 3 on the Transparency screen: whether this device has joined the event at all. Distinct from the \"Participation record\" tier below it, which is about what has happened to the data after joining (stored/sent/published), not about the join action itself."
        )
        Text(
          hasJoined ? "Joined" : "Not joined",
          comment: "Value shown under the \"Participation\" tier: whether this device has joined the event. \"Joined\" here means the join action was taken, not a social/group-membership sense of the word."
        )
        .font(DS.Font.cardTitle)
        .foregroundStyle(DS.Color.textPrimary)
      }
    }
  }

  private var participationRecordPanel: some View {
    BeidPanel {
      VStack(alignment: .leading, spacing: DS.Space.m) {
        tierTitle(
          "Participation record",
          comment: "Tier 2 of 3 on the Transparency screen: what has happened to this device's sensing data after joining (mutually observed / recorded on-device / sent to a report server / receipt confirmed / included in published data). Distinct from \"Verified proof\" below it, which is about third-party verification, not data handling."
        )
        TierRow(
          label: Text(verbatim: mutualObservationLabelText),
          isAvailable: false,
          valueText: nil
        )
        Divider()
        TierRow(
          label: Text(verbatim: recordedOnDeviceLabelText),
          isAvailable: recordedOnDeviceCount != nil,
          valueText: recordedOnDeviceCount.map { String($0) }
        )
        Divider()
        TierRow(
          label: Text(
            "Not submittable (count-only record)",
            comment: "Sub-state row under \"Participation record\": windows recorded with only a device count and no reporter RPID can never be submitted to a report server. This row makes that exclusion explicit instead of silently dropping those windows (levarac/dispatch#3)."
          ),
          isAvailable: excludedWindowCount != nil,
          valueText: excludedWindowCount.map { String($0) }
        )
        Divider()
        TierRow(
          label: Text(
            "Sent",
            comment: "Sub-state row under \"Participation record\": whether this device's sensing data has been transmitted to a report server for this event. Available once at least one submission has reached the SUBMITTING or ACCEPTED durable state (beid#292); report-submission code exists in the app today but is gated off in production by the BeidReportSubmissionEnabled build setting, so this reflects genuinely stored state, not a permanently-unbuilt capability like the rows below it. Shows \"Not yet available\" (not a failed-send state) before any submission for this event has been attempted."
          ),
          isAvailable: isSent,
          valueText: isSent ? sentValueText : nil
        )
        Divider()
        TierRow(
          label: Text(verbatim: acceptanceReceiptLabelText),
          isAvailable: hasAcceptanceReceipt,
          valueText: hasAcceptanceReceipt ? receivedValueText : nil
        )
        Divider()
        TierRow(
          label: Text(
            "Included in published data",
            comment: "Sub-state row under \"Participation record\": whether this device's data has been incorporated into the report server's published dataset. Always shows \"Not yet available\" today because no report server or publishing pipeline exists yet."
          ),
          isAvailable: false,
          valueText: nil
        )
      }
    }
  }

  private var isSent: Bool {
    submissionState == .submitting || submissionState == .accepted
  }

  private var hasAcceptanceReceipt: Bool {
    submissionState == .accepted
  }

  private var verifiedProofPanel: some View {
    BeidPanel {
      VStack(alignment: .leading, spacing: DS.Space.m) {
        tierTitle(
          "Verified proof",
          comment: "Tier 3 of 3 on the Transparency screen: whether this device's participation has passed third-party verification (a status that would include a pending sub-state once it exists). Always shows \"Not yet available\" today because no verifier exists yet in the product. Distinct from the Proof Detail screen's Status row, which shows \"Recorded on device\" (this screen's Participation record tier text above, reused verbatim — beid#240) rather than any claim about third-party verification."
        )
        TierRow(label: nil, isAvailable: false, valueText: nil)
      }
    }
  }

  private func tierTitle(_ text: LocalizedStringKey, comment: StaticString) -> some View {
    Text(text, comment: comment)
      .font(DS.Font.cardTitle)
      .foregroundStyle(DS.Color.textPrimary)
  }

  /// Explicit shared key with `ItemDetailView.statusRow` (AGENTS.md's
  /// reuse rule — the same English text now appears at a second call
  /// site): key/defaultValue/comment must stay byte-identical at both
  /// call sites so Xcode's String Catalog treats them as one entry.
  private var recordedOnDeviceLabelText: String {
    String(
      localized: "status.recordedOnDevice",
      defaultValue: "Recorded on device",
      comment: "Label shown when a proof's sensing data is known to be locally signed and stored on this device (not yet sent anywhere). Used in two places: (1) the Transparency screen's Participation record tier, where it's one of three rows (Sent / Included in published data are separate, always-unavailable rows below it); (2) the Proof Detail screen's Status row, where it replaced a prior unconditional \"Verified\" claim that had no backing model (beid#240, DECISIONS 2026-08-20) — the device only has its own signature, which shows \"this device recorded this,\" nothing more. Refers to on-device storage, not a video/audio recording."
    )
  }

  /// First row under "Participation record" (beid#292): always flat and
  /// unavailable by design, not merely unwired-so-far. Two devices
  /// confirming they mutually sensed each other is not measurable on-device
  /// today — `SessionAggregate.mutual*` exists in `shared/` but its only
  /// production writer hardcodes `mutual: false` on every call, so those
  /// fields are structurally meaningless and are never read here (that would
  /// repeat beid#222's corrected mistake: a measured-looking zero reads as
  /// "we measured and got zero," not "we can't measure this yet"). This row
  /// stays unavailable until beid#144 stage 4 delivers a real reciprocity
  /// signal.
  private var mutualObservationLabelText: String {
    String(
      localized: "transparency.mutualObservation",
      defaultValue: "Mutual observation",
      comment: "Sub-state row under \"Participation record\": whether two devices have confirmed they mutually sensed each other during this event. Always shows \"Not yet available\" today because there is no on-device reciprocity signal in the product yet — this is not a failed-measurement or zero-result state, the capability itself does not exist yet. Refers to two devices detecting each other, not audio/video observation."
    )
  }

  /// Trailing value on the "Sent" row once available. Deliberately the same
  /// word as that row's own label (beid#292) — DESIGN.md §2.9 requires the
  /// icon shape and the trailing text to change together, and there is no
  /// separate status word for "a report was sent"; a distinct explicit key
  /// from the row's label so translators can adjust either independently.
  private var sentValueText: String {
    String(
      localized: "transparency.sent",
      defaultValue: "Sent",
      comment: "Trailing value on the \"Sent\" sub-state row under \"Participation record\", shown once at least one submission for this event has actually been transmitted to a report server. Same word as the row's own label — confirming the label is now true, not a separate or more specific status."
    )
  }

  /// Fourth row under "Participation record" (beid#292): whether the report
  /// server has confirmed receipt of at least one of this device's
  /// submissions for this event — a verified, stored `AcceptanceReceipt`,
  /// not merely that a POST was attempted. Distinct from "Sent" above it,
  /// which only means transmission was attempted.
  private var acceptanceReceiptLabelText: String {
    String(
      localized: "transparency.acceptanceReceipt",
      defaultValue: "Acceptance receipt",
      comment: "Sub-state row under \"Participation record\": whether the report server has confirmed receipt of at least one of this device's submissions for this event. Always shows \"Not yet available\" until a receipt has actually been verified and stored — a submission that was merely sent, with no confirmed receipt yet, is not enough for this row."
    )
  }

  /// Trailing value on the "Acceptance receipt" row once available.
  private var receivedValueText: String {
    String(
      localized: "transparency.received",
      defaultValue: "Received",
      comment: "Trailing value on the \"Acceptance receipt\" sub-state row under \"Participation record\", shown once the report server has actually confirmed receipt for at least one submission for this event. Not a separate status word like \"pending\" or \"delivered\" — it means the receipt itself is confirmed and stored."
    )
  }
}

/// One participation-record or verified-proof sub-state row: an icon +
/// optional label on the leading side, and either a live value or an
/// honest "Not yet available" on the trailing side. Never conveys state by
/// color alone (DESIGN.md §2.9) — the icon shape (`checkmark.circle.fill`
/// vs. outlined `circle`) and the trailing text both change together.
private struct TierRow: View {
  var label: Text?
  let isAvailable: Bool
  var valueText: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
      Image(systemName: isAvailable ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(isAvailable ? DS.Color.textPrimary : DS.Color.textSecondary)
        .accessibilityHidden(true)

      if let label {
        label
          .font(DS.Font.supporting)
          .foregroundStyle(DS.Color.textSecondary)
      }

      Spacer(minLength: DS.Space.s)

      statusValue
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var statusValue: some View {
    if isAvailable, let valueText {
      Text(verbatim: valueText)
        .font(DS.Font.cardTitle)
        .foregroundStyle(DS.Color.textPrimary)
    } else {
      Text(notYetAvailableText)
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.textSecondary)
    }
  }

  /// Reused across this screen's `TierRow`s whenever `isAvailable` is
  /// `false`, with identical, non-parameterized text — an explicit key per
  /// AGENTS.md's localization rule ("about to write the same `Text(...)` in
  /// a second place"), rather than a literal-English key repeated at each
  /// call site. Covers two different reasons a row can be unavailable, both
  /// honestly described by the same words: a row whose capability does not
  /// exist in the product at all yet (Mutual observation, Included in
  /// published data, Verified proof — permanently, until a future feature
  /// lands), and a row whose capability exists but has not happened for
  /// this specific event yet (Sent, Acceptance receipt, before a submission
  /// reaches that state).
  private var notYetAvailableText: String {
    String(
      localized: "transparency.notYetAvailable",
      defaultValue: "Not yet available",
      comment: "Status for a participation-record or verified-proof row that has no data to show yet — either because the underlying capability isn't implemented in the product at all, or because it exists but hasn't happened for this event yet (e.g. no submission has been sent/received). This means there is nothing to report yet, not that an attempt was made and failed — do not translate as an error, warning, or declined state."
    )
  }
}

#Preview("Recorded, live") {
  NavigationStack {
    TransparencyView(
      eventName: "ETHGlobal Tokyo",
      hasJoined: true,
      recordedOnDeviceCount: 5,
      excludedWindowCount: 1,
      submissionState: nil
    )
  }
}

#Preview("Recorded, live (Dark)") {
  NavigationStack {
    TransparencyView(
      eventName: "ETHGlobal Tokyo",
      hasJoined: true,
      recordedOnDeviceCount: 5,
      excludedWindowCount: 1,
      submissionState: nil
    )
  }
  .preferredColorScheme(.dark)
}

#Preview("Legacy proof, no eventCode") {
  NavigationStack {
    TransparencyView(
      eventName: "ETHGlobal Tokyo",
      hasJoined: true,
      recordedOnDeviceCount: nil,
      excludedWindowCount: nil,
      submissionState: nil
    )
  }
}

#Preview("Sent, awaiting receipt") {
  NavigationStack {
    TransparencyView(
      eventName: "ETHGlobal Tokyo",
      hasJoined: true,
      recordedOnDeviceCount: 5,
      excludedWindowCount: 1,
      submissionState: .submitting
    )
  }
}

#Preview("Receipt confirmed") {
  NavigationStack {
    TransparencyView(
      eventName: "ETHGlobal Tokyo",
      hasJoined: true,
      recordedOnDeviceCount: 5,
      excludedWindowCount: 1,
      submissionState: .accepted
    )
  }
}
