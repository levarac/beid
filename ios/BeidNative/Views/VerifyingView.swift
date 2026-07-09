// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 06b: Verifying — progress + "N peers verified".
struct VerifyingView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  let event: DemoEvent
  let peersVerified: Int

  private var progress: Double {
    guard event.totalPeersToVerify > 0 else { return 0 }
    return Double(peersVerified) / Double(event.totalPeersToVerify)
  }

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      ProgressView(value: progress)
        .progressViewStyle(.circular)
        .controlSize(.large)
        .tint(.blue)

      Text("Verifying proof automatically")
        .font(.title3.weight(.semibold))

      Text("\(peersVerified) of \(event.totalPeersToVerify) peers verified")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Text(event.name)
        .font(.footnote)
        .foregroundStyle(.tertiary)

      Spacer()

      // Demo-mode-only affordance so the 06d Signal Lost screen stays
      // reachable even though the golden DemoEvent path completes
      // successfully.
      Button("Simulate Signal Lost", role: .destructive) {
        coordinator.sensingCoordinator.simulateSignalLost()
      }
      .font(.footnote)
      .padding(.bottom, 24)
    }
  }
}

#Preview {
  VerifyingView(event: .sample, peersVerified: 1).environmentObject(AppCoordinator())
}
