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
    BeidStatusLayout(
      systemImage: "person.2.wave.2.fill",
      title: "Verifying proof",
      message: "Nearby peers are confirming your attendance automatically.",
      accessory: {
      BeidPanel {
        VStack(alignment: .leading, spacing: BeidDesign.Spacing.content) {
          Text(event.name)
            .font(DS.Font.cardTitle)
            .fixedSize(horizontal: false, vertical: true)

          ProgressView(value: progress) {
            Text("\(peersVerified) of \(event.totalPeersToVerify) peers verified")
              .font(DS.Font.supporting)
              .foregroundStyle(DS.Color.textSecondary)
          }
          .tint(DS.Color.signalActive)
        }
      }
      },
      footer: {
      // Demo-mode-only affordance so the 06d Signal Lost screen stays
      // reachable even though the golden DemoEvent path completes
      // successfully.
      Button("Simulate Signal Lost", role: .destructive) {
        BeidDesign.haptic(.medium)
        coordinator.sensingCoordinator.simulateSignalLost()
      }
      .font(.footnote)
      }
    )
  }
}

#Preview {
  VerifyingView(event: .sample, peersVerified: 1).environmentObject(AppCoordinator())
}
