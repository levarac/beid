// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 07: Proof Collected — confirmation.
struct ProofCollectedView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  let proof: Proof

  var body: some View {
    BeidStatusLayout(
      systemImage: "seal.fill",
      assetImage: "proof-seal-mark",
      title: "Proof Collected",
      message: "Added to your collection.",
      accessory: {
      VStack(spacing: BeidDesign.Spacing.section) {
        BeidPanel {
          VStack(alignment: .leading, spacing: BeidDesign.Spacing.content) {
            Text(proof.eventName)
              .font(DS.Font.cardTitle)
              .fixedSize(horizontal: false, vertical: true)
            BeidMetricRow(label: "Peers verified", verbatimValue: "\(proof.peersVerified)")
            BeidMetricRow(label: "Status", value: "Stored", valueStyle: AnyShapeStyle(DS.Color.proofSeal))
          }
        }
        BeidPanel {
          ProofSignatureControlsView(proofId: proof.id)
        }
      }
      },
      footer: {
      BeidPrimaryButton("Done", systemImage: "checkmark") {
        coordinator.finishScan()
      }
      }
    )
    // Ceremony screen: header glyph + "Done" both get the shared proofSeal
    // accent — DESIGN.md §5 "one motif accent per screen". (Previously
    // this fell through to the screen switch's ambient actionPrimary tint,
    // since `tint:` only colored the header glyph, not the footer button —
    // a real §5 gap, not just a debug-tool artifact.)
    .tint(DS.Color.proofSeal)
  }
}

#Preview("Wallet connected") {
  let coordinator = AppCoordinator()
  let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
  coordinator.proofStore.add(proof)
  coordinator.walletAddress = "0x1234567890abcdef1234567890abcdef12345678"
  return ProofCollectedView(proof: proof)
    .environmentObject(coordinator)
}

#Preview("Wallet connected (Dark)") {
  let coordinator = AppCoordinator()
  let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
  coordinator.proofStore.add(proof)
  coordinator.walletAddress = "0x1234567890abcdef1234567890abcdef12345678"
  return ProofCollectedView(proof: proof)
    .environmentObject(coordinator)
    .preferredColorScheme(.dark)
}

#Preview("No wallet") {
  let coordinator = AppCoordinator()
  let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
  coordinator.proofStore.add(proof)
  return ProofCollectedView(proof: proof)
    .environmentObject(coordinator)
}
