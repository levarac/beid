// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 01: Welcome.
struct WelcomeView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    BeidScreen {
      BeidHeroHeader(
        systemImage: "checkmark.seal.fill",
        assetImage: "welcome-mark",
        title: "beid",
        subtitle: "Prove you were there. Automatically."
      )

      BeidPanel {
        VStack(alignment: .leading, spacing: BeidDesign.Spacing.content) {
          BeidMetricRow(label: "Sensing", value: "Nearby events")
          BeidMetricRow(label: "Proof", value: "Automatic")
          BeidMetricRow(label: "Privacy", value: "On-device first")
        }
      }
    } footer: {
      BeidPrimaryButton("Get Started", systemImage: "arrow.right") {
        coordinator.beginOnboarding()
      }
    }
  }
}

#Preview {
  WelcomeView().environmentObject(AppCoordinator())
}
