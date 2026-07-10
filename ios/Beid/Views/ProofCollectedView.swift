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
      title: "Proof Collected",
      message: "Added to your collection.",
      tint: .accentColor,
      accessory: {
      BeidPanel {
        VStack(alignment: .leading, spacing: BeidDesign.Spacing.content) {
          Text(proof.eventName)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
          BeidMetricRow(label: "Peers verified", verbatimValue: "\(proof.peersVerified)")
          BeidMetricRow(label: "Status", value: "Stored", valueStyle: AnyShapeStyle(.green))
        }
      }
      },
      footer: {
      BeidPrimaryButton("Done", systemImage: "checkmark") {
        coordinator.finishScan()
      }
      }
    )
  }
}

#Preview {
  ProofCollectedView(proof: Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
    .environmentObject(AppCoordinator())
}
