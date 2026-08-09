// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 08: Item Detail — method, devices sensed, status.
struct ItemDetailView: View {
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
