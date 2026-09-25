// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 01: Welcome. Event-first entry (docs/specs/onboarding-redesign.md
/// §3/§4.1): the CTA does not connect a wallet — it resolves
/// `OnboardingMode.current` via `beginOnboarding()`, which routes to
/// `.bluetoothPermission` for the event-first (guestFirst) path. No
/// Terms/Privacy footer here; that belongs to the later wallet-connect step.
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
