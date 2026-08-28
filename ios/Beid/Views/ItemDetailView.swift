// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import SwiftUI

/// Screen 08: Item Detail — method, devices sensed, status.
struct ItemDetailView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  let proof: Proof

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    return formatter
  }()

  /// Every session sharing `proof`'s event (beid#217, spec §2/§3), newest
  /// first. `proof` is always this group's newest session by construction
  /// (it is exactly the representative `CollectionHomeView` passed to
  /// `openProof(_:)` per spec §5.1), so `groupSessions.first == proof`
  /// always holds — title/date below use `proof` directly rather than
  /// `groupSessions.first` for that reason, not by coincidence.
  private var groupSessions: [Proof] {
    EventGrouping.sessions(for: proof, in: coordinator.proofStore.proofs)
  }

  /// Artwork gradient seed, sourced from the group's *oldest* session
  /// (`groupSessions.last`, since `groupSessions` is newest-first) so this
  /// screen's artwork never changes across re-scans — mirrors
  /// `ProofCardView`'s `artworkSeed` fix. For a single-session group
  /// (including every `eventCode == nil` singleton), `groupSessions.last
  /// == groupSessions.first == proof`, so this is identical to
  /// `proof.gradientSeed` — see spec §6.1's degenerate-case check.
  private var artworkSeed: Int {
    groupSessions.last?.gradientSeed ?? proof.gradientSeed
  }

  var body: some View {
    ScrollView {
      BeidAdaptiveContent {
        BeidGlassGroup(spacing: BeidDesign.Spacing.section) {
          VStack(alignment: .leading, spacing: BeidDesign.Spacing.section) {
            artworkHeader

            BeidPanel {
              VStack(alignment: .leading, spacing: DS.Space.m) {
                BeidMetricRow(label: "Method", verbatimValue: proof.method)
                // "Devices", not "Peers": the number counts distinct nearby
                // devices, and only those whose identity could be read. See
                // beid#154 and `SensingCoordinator.devicesVerified`.
                //
                // Omitted entirely for a multi-session group (beid#217,
                // spec §6.2): `proof.peersVerified` is session-scoped, and
                // showing only the representative session's count here
                // would carry the same false whole-event signal risk the
                // ruling rejected for Participation summary — no
                // fabricated event-scoped substitute exists (summing would
                // double-count a device seen in more than one session).
                // Each session's own count stays fully visible, correctly
                // scoped, in the session list (§6.3) instead.
                if groupSessions.count == 1 {
                  BeidMetricRow(label: "detail.devicesSensed.label", verbatimValue: "\(proof.peersVerified)")
                }
                statusRow
              }
            }

            BeidPanel {
              transparencyRow
            }

            BeidPanel {
              participationSummaryRow
            }
          }
          .padding(BeidDesign.Spacing.screenHorizontal)
        }
      }
    }
    .background(DS.Color.surfaceCanvas)
    .navigationTitle("Proof Detail")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var artworkHeader: some View {
    VStack(spacing: DS.Space.l) {
      Circle()
        .fill(DS.Artwork.proofCardGradient(seed: artworkSeed))
        .frame(width: DS.Size.itemDetailArtwork, height: DS.Size.itemDetailArtwork)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.xl)
        .beidSurface(interactive: false, cornerRadius: DS.Radius.seal)

      VStack(spacing: DS.Space.s) {
        Text(proof.eventName)
          .font(DS.Font.sectionTitle)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)

        Text(Self.dateFormatter.string(from: proof.date))
          .font(DS.Font.body)
          .foregroundStyle(DS.Color.textSecondary)
      }
    }
  }

  /// Shows "Recorded on device" — the step before verification, and the
  /// only claim about this proof's signature the app can currently back.
  /// Third-party verification does not exist in the product (#144 stage 4,
  /// unstarted); the device only holds its own signature, which shows
  /// "this device recorded this," nothing more. Unconditional (not derived
  /// from `proof.signatureState`) because "Recorded on device" is
  /// unconditionally true for any `Proof` reaching this screen — see
  /// `transparencyRow`'s doc comment on `hasJoined`. Was unconditional
  /// "Verified" until beid#240 (DECISIONS 2026-08-20); superseded
  /// `docs/specs/itemdetail-redesign.md` §5.2's OD-2, see that section's
  /// 2026-08-20 superseding note.
  private var statusRow: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Status")
        .font(DS.Font.supporting)
        .foregroundStyle(DS.Color.textSecondary)
      Spacer(minLength: DS.Space.m)
      Label(recordedOnDeviceStatusText, systemImage: "checkmark.circle.fill")
        .font(DS.Font.cardTitle)
        .foregroundStyle(DS.Color.proofSeal)
    }
  }

  /// Explicit shared key with `TransparencyView`'s Participation record
  /// tier (AGENTS.md's reuse rule — the same English text appears at a
  /// second call site here): key/defaultValue/comment must stay
  /// byte-identical at both call sites so Xcode's String Catalog treats
  /// them as one entry.
  private var recordedOnDeviceStatusText: String {
    String(
      localized: "status.recordedOnDevice",
      defaultValue: "Recorded on device",
      comment: "Label shown when a proof's sensing data is known to be locally signed and stored on this device (not yet sent anywhere). Used in two places: (1) the Transparency screen's Participation record tier, where it's one of three rows (Sent / Included in published data are separate, always-unavailable rows below it); (2) the Proof Detail screen's Status row, where it replaced a prior unconditional \"Verified\" claim that had no backing model (beid#240, DECISIONS 2026-08-20) — the device only has its own signature, which shows \"this device recorded this,\" nothing more. Refers to on-device storage, not a video/audio recording."
    )
  }

  /// Entry point for beid#137's Transparency screen — the only "check the
  /// status of your data" surface this app has today, so it hangs off the
  /// durable per-proof screen rather than a not-yet-existing History/tab
  /// bar IA (DECISIONS 2026-08-09 "#137 は履歴スコープを採り...").
  private var transparencyRow: some View {
    NavigationLink {
      TransparencyView(
        eventName: proof.eventName,
        // A stored `Proof` only ever exists once `.recording` has begun,
        // which itself only happens after the join action — see
        // `ScanPhase`'s doc comment. Reaching this row therefore always
        // implies "joined."
        hasJoined: true,
        recordedOnDeviceCount: recordedOnDeviceCount,
        submissionState: submissionState
      )
    } label: {
      HStack {
        Text(
          "Transparency",
          comment: "Row label on Proof Detail linking to the Transparency screen, which shows the participant the status of their own data (recorded/sent/published/verified). Noun referring to open, checkable data status — not visual/window transparency or opacity."
        )
        .font(DS.Font.cardTitle)
        .foregroundStyle(DS.Color.textPrimary)
        Spacer(minLength: DS.Space.m)
        Image(systemName: "chevron.right")
          .font(DS.Font.meta)
          .foregroundStyle(DS.Color.textSecondary)
          .accessibilityHidden(true)
      }
      .frame(minHeight: DS.Size.minHitTarget)
    }
  }

  /// `nil` when `proof.eventCode` is absent — a proof persisted before
  /// beid#137 added that field (see `Proof.eventCode`'s doc comment).
  /// Renders as "not yet available" on `TransparencyView`, the same
  /// honest-gap treatment as the rows with no data source at all, never a
  /// false zero.
  private var recordedOnDeviceCount: Int? {
    guard let eventCode = proof.eventCode else { return nil }
    return coordinator.sensingCoordinator.recordedWindowCount(forEventCode: eventCode)
  }

  /// `nil` when `proof.eventCode` is absent — same reason and same
  /// historically-scoped treatment as `recordedOnDeviceCount` above, not a
  /// second design decision. Feeds Transparency's "Sent"/"Acceptance
  /// receipt" rows (beid#292) via
  /// `SensingCoordinator.submissionState(forEventCode:)`, which is `nil`
  /// both when report submission is gated off in production and when no
  /// submission has been queued for this event yet.
  private var submissionState: ReportSubmissionState? {
    guard let eventCode = proof.eventCode else { return nil }
    return coordinator.sensingCoordinator.submissionState(forEventCode: eventCode)
  }

  /// Entry point for beid#143's Participation summary screen — sits
  /// alongside (not replacing) the Transparency row above, per its own
  /// `BeidPanel`, matching that row's `NavigationLink` push pattern.
  ///
  /// beid#217, spec §6.3: for a multi-session group this must let the user
  /// reach *every* session's own aggregate, each correctly scoped to its
  /// own `proofId` — never one aggregate presented as if it covered the
  /// whole event. `groupSessions.count == 1` (including every
  /// `eventCode == nil` singleton) keeps today's direct push unchanged —
  /// see §6.4's must-not-regress bar.
  private var participationSummaryRow: some View {
    NavigationLink {
      if groupSessions.count > 1 {
        SessionParticipationListView(eventName: proof.eventName, sessions: sessionParticipationPairs)
      } else {
        ParticipationSummaryView(
          eventName: proof.eventName,
          // `Proof.id`, not `eventCode`, is the snapshot store's key. Reads
          // through `sensingCoordinator.sessionAggregateSnapshot(forProofId:)`
          // (beid#166 Phase 2), not a separate store instance — that method
          // forwards to the exact same coordinator-owned store the
          // session-end hook writes, so a snapshot persisted moments ago in
          // this same app run is visible immediately. `nil` here means no
          // snapshot was ever persisted for this proof — the new screen
          // renders that as an honest "not yet available" state, the same
          // posture `TransparencyView` already established.
          aggregate: coordinator.sensingCoordinator.sessionAggregateSnapshot(forProofId: proof.id)
        )
      }
    } label: {
      HStack {
        Text(
          "View participation summary",
          comment: "Row label on Proof Detail linking to the Participation summary screen, which shows a post-session summary (mutually-confirmed device count and a time-band buildup) for this proof's recording session."
        )
        .font(DS.Font.cardTitle)
        .foregroundStyle(DS.Color.textPrimary)
        Spacer(minLength: DS.Space.m)
        Image(systemName: "chevron.right")
          .font(DS.Font.meta)
          .foregroundStyle(DS.Color.textSecondary)
          .accessibilityHidden(true)
      }
      .frame(minHeight: DS.Size.minHitTarget)
    }
  }

  /// `(proof, aggregate)` pairs for every session in this group, newest
  /// first (matches `groupSessions`'s order — spec §6.3), resolved via the
  /// same per-proof snapshot lookup `participationSummaryRow`'s
  /// single-session branch already makes, just repeated per session.
  private var sessionParticipationPairs: [(proof: Proof, aggregate: BeidSharedKit.aggregation.SessionAggregate?)] {
    groupSessions.map { session in
      (proof: session, aggregate: coordinator.sensingCoordinator.sessionAggregateSnapshot(forProofId: session.id))
    }
  }
}

#Preview("Wallet connected") {
  let coordinator = AppCoordinator()
  let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
  coordinator.proofStore.add(proof)
  coordinator.walletAddress = "0x1234567890abcdef1234567890abcdef12345678"
  return NavigationStack {
    ItemDetailView(proof: proof)
  }
  .environmentObject(coordinator)
}

#Preview("Wallet connected (Dark)") {
  let coordinator = AppCoordinator()
  let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
  coordinator.proofStore.add(proof)
  coordinator.walletAddress = "0x1234567890abcdef1234567890abcdef12345678"
  return NavigationStack {
    ItemDetailView(proof: proof)
  }
  .environmentObject(coordinator)
  .preferredColorScheme(.dark)
}

#Preview("No wallet") {
  let coordinator = AppCoordinator()
  let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
  coordinator.proofStore.add(proof)
  return NavigationStack {
    ItemDetailView(proof: proof)
  }
  .environmentObject(coordinator)
}

#Preview("No wallet (Dark)") {
  let coordinator = AppCoordinator()
  let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
  coordinator.proofStore.add(proof)
  return NavigationStack {
    ItemDetailView(proof: proof)
  }
  .environmentObject(coordinator)
  .preferredColorScheme(.dark)
}

/// beid#217: a multi-session group — top panel omits "Devices sensed"
/// (§6.2), and the newest session (passed to `ItemDetailView`) carries a
/// deliberately different `gradientSeed` than the oldest, so a correct fix
/// shows the *oldest* session's gradient here (§6.1's degenerate-case
/// check only holds for single-session groups).
#Preview("Multiple sessions") {
  let coordinator = AppCoordinator()
  let oldest = Proof(
    eventName: "ETHGlobal Tokyo", date: Date().addingTimeInterval(-86400 * 5),
    peersVerified: 3, gradientSeed: 111, eventCode: "ETHTOKYO"
  )
  let newest = Proof(
    eventName: "ETHGlobal Tokyo", date: Date(),
    peersVerified: 5, gradientSeed: 999, eventCode: "ETHTOKYO"
  )
  coordinator.proofStore.add(oldest)
  coordinator.proofStore.add(newest)
  return NavigationStack {
    ItemDetailView(proof: newest)
  }
  .environmentObject(coordinator)
}

#Preview("Multiple sessions (Dark)") {
  let coordinator = AppCoordinator()
  let oldest = Proof(
    eventName: "ETHGlobal Tokyo", date: Date().addingTimeInterval(-86400 * 5),
    peersVerified: 3, gradientSeed: 111, eventCode: "ETHTOKYO"
  )
  let newest = Proof(
    eventName: "ETHGlobal Tokyo", date: Date(),
    peersVerified: 5, gradientSeed: 999, eventCode: "ETHTOKYO"
  )
  coordinator.proofStore.add(oldest)
  coordinator.proofStore.add(newest)
  return NavigationStack {
    ItemDetailView(proof: newest)
  }
  .environmentObject(coordinator)
  .preferredColorScheme(.dark)
}
