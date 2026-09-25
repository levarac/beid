// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import SwiftUI

/// Screen 01. The owner chose wallet-optional onboarding on 2026-09-26:
/// Get Started truthfully follows the existing guest-first route.
struct WelcomeView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    FlatOnboardingPage {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("beid")
            .beidTextStyle(DS.Font.Library.labelMono11)
            .foregroundStyle(DS.Color.textPrimary)
          Spacer()
          Text("V 1.0")
            .beidTextStyle(DS.Font.Library.labelMono11)
            .foregroundStyle(DS.Color.textSecondary)
        }

        // A fixed illustrative sample, never a proof or device observation.
        BeidSigilView(
          input: WelcomeSigilIllustration.input,
          size: DS.Onboarding.welcomeHeroSize,
          ground: .OUTLINE
        )
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity)
        .padding(.top, DS.Onboarding.welcomeHeroGap)

        Text("Prove you\nwere there.")
          .beidTextStyle(DS.Font.Library.display52)
          .foregroundStyle(DS.Color.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, DS.Onboarding.welcomeTitleGap)

        Text("Proofs of presence, collected automatically while you are at an event. No codes, no taps.")
          .beidTextStyle(DS.Font.Library.body15)
          .foregroundStyle(DS.Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: DS.Onboarding.welcomeBodyWidth, alignment: .leading)
          .padding(.top, DS.Onboarding.welcomeBodyGap)

        // HOW IT WORKS awaits #646's destination decision. The Figma
        // connecting/terms footer is false for this guest-first route.
      }
    } footer: {
      FlatOnboardingPrimaryButton("Get Started") {
        coordinator.beginOnboarding()
      }
    }
  }
}

/// Stable illustration input for the Welcome hero only. It deliberately
/// contains sample mutual marks, which live observations cannot supply yet.
private enum WelcomeSigilIllustration {
  static var input: BeidSharedKit.sigil.SigilInput {
    let windowCount: Int32 = 12
    let input = BeidSharedKit.sigil.createSigilInput(windowCount: windowCount)
    for peer in 0..<9 {
      for window in 0..<windowCount where (peer + Int(window)) % 3 != 0 {
        _ = BeidSharedKit.sigil.addSigilPresence(
          input: input,
          peerKey: "illustration-peer-\(peer)",
          windowIndex: window,
          presence: (peer + Int(window)) % 4 == 0 ? 2 : 1
        )
      }
    }
    return input
  }
}

#Preview {
  WelcomeView().environmentObject(AppCoordinator())
}
