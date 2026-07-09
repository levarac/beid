// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 07: Proof Collected — confirmation.
struct ProofCollectedView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  let proof: Proof

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      ZStack {
        Circle()
          .fill(Color.blue.opacity(0.15))
          .frame(width: 120, height: 120)
        Image(systemName: "seal.fill")
          .font(.system(size: 48))
          .foregroundStyle(.blue)
      }

      Text("Proof Collected")
        .font(.title.bold())

      Text(proof.eventName)
        .font(.title3)
        .foregroundStyle(.secondary)

      Text("Added to your collection")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Spacer()

      Button {
        coordinator.finishScan()
      } label: {
        Text("Done")
          .font(.headline)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.blue)
      .padding(.horizontal, 32)
      .padding(.bottom, 40)
    }
  }
}

#Preview {
  ProofCollectedView(proof: Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
    .environmentObject(AppCoordinator())
}
