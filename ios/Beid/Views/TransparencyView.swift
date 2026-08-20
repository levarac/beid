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
/// iOS-only for now: Android has no post-join screen flow at all yet
/// (AGENTS.md's current-state paragraph — `EventJoinCoordinator` stops at
/// `Idle`/`RequestingPermission`/`Sensing`/`PermissionDenied`), so there is
/// no Android surface for this to extend.
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

  var body: some View {
    ScrollView {
      BeidAdaptiveContent {
        BeidGlassGroup(spacing: BeidDesign.Spacing.section) {
          VStack(alignment: .leading, spacing: BeidDesign.Spacing.section) {
            header
            participationPanel
            participationRecordPanel
            verifiedProofPanel
          }
          .padding(BeidDesign.Spacing.screenHorizontal)
        }
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
          comment: "Tier 2 of 3 on the Transparency screen: what has happened to this device's sensing data after joining (recorded on-device / sent to a report server / included in published data). Distinct from \"Verified proof\" below it, which is about third-party verification, not data handling."
        )
        TierRow(
          label: Text(verbatim: recordedOnDeviceLabelText),
          isAvailable: recordedOnDeviceCount != nil,
          valueText: recordedOnDeviceCount.map { String($0) }
        )
        Divider()
        TierRow(
          label: Text(
            "Sent",
            comment: "Sub-state row under \"Participation record\": whether this device's sensing data has been transmitted to a report server. Always shows \"Not yet available\" today (see the adjacent status text) because no report-submission code exists in the app yet — this is not a failed-send state."
          ),
          isAvailable: false,
          valueText: nil
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
        .foregroundStyle(isAvailable ? DS.Color.proofSeal : DS.Color.statusOff)
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
        .foregroundStyle(DS.Color.statusOff)
    }
  }

  /// Reused across three rows on this screen (Sent / Included in published
  /// data / Verified proof) with identical, non-parameterized text — an
  /// explicit key per AGENTS.md's localization rule ("about to write the
  /// same `Text(...)` in a second place"), rather than a literal-English
  /// key repeated at each call site.
  private var notYetAvailableText: String {
    String(
      localized: "transparency.notYetAvailable",
      defaultValue: "Not yet available",
      comment: "Status for a participation-record or verified-proof row whose data source doesn't exist in the product yet (no report submission or verifier is implemented). This means the capability itself is not built yet, not that an attempt was made and failed — do not translate as an error, warning, or declined state."
    )
  }
}

#Preview("Recorded, live") {
  NavigationStack {
    TransparencyView(eventName: "ETHGlobal Tokyo", hasJoined: true, recordedOnDeviceCount: 5)
  }
}

#Preview("Recorded, live (Dark)") {
  NavigationStack {
    TransparencyView(eventName: "ETHGlobal Tokyo", hasJoined: true, recordedOnDeviceCount: 5)
  }
  .preferredColorScheme(.dark)
}

#Preview("Legacy proof, no eventCode") {
  NavigationStack {
    TransparencyView(eventName: "ETHGlobal Tokyo", hasJoined: true, recordedOnDeviceCount: nil)
  }
}
