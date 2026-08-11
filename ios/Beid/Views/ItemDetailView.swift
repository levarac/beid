// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

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
                BeidMetricRow(label: "detail.devicesSensed.label", verbatimValue: "\(proof.peersVerified)")
                statusRow
              }
            }

            BeidPanel {
              ProofSignatureControlsView(proofId: proof.id)
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
        .fill(DS.Artwork.proofCardGradient(seed: proof.gradientSeed))
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

  /// Fixed, unconditional "Verified" — deliberately not derived from
  /// `proof.signatureState`, which already has its own distinct readout in
  /// the `ProofSignatureControlsView` panel below. See
  /// `docs/specs/itemdetail-redesign.md` §5.2.
  private var statusRow: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Status")
        .font(DS.Font.supporting)
        .foregroundStyle(DS.Color.textSecondary)
      Spacer(minLength: DS.Space.m)
      Label("Verified", systemImage: "checkmark.circle.fill")
        .font(DS.Font.cardTitle)
        .foregroundStyle(DS.Color.proofSeal)
    }
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
        recordedOnDeviceCount: recordedOnDeviceCount
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

  /// Entry point for beid#143's Participation summary screen — sits
  /// alongside (not replacing) the Transparency row above, per its own
  /// `BeidPanel`, matching that row's `NavigationLink` push pattern.
  private var participationSummaryRow: some View {
    NavigationLink {
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
