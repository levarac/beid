// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Screen 01. The owner chose wallet-optional onboarding on 2026-09-26:
/// Get Started truthfully follows the existing guest-first route.
struct WelcomeView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @State private var showAboutSensing = false

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

        // Figma's fixed sample illustration, never a proof or observation.
        Image("welcome-figma-sample-sigil")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: DS.Onboarding.welcomeHeroSize, height: DS.Onboarding.welcomeHeroSize)
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

        // Figma 01 HOW IT WORKS → opens 15 About sensing (#646). The Figma
        // connecting/terms footer stays out: this guest-first route connects nothing.
        BeidTextControl("How it works", glyph: .trailing("→", announcing: "How it works"))
        {
          showAboutSensing = true
        }
        .accessibilityIdentifier("welcome.howItWorks")
        .padding(.top, DS.Space.m)
      }
    } footer: {
      BeidPrimaryButton("Get Started") {
        coordinator.beginOnboarding()
      }
    }
    .sheet(isPresented: $showAboutSensing) {
      NavigationStack {
        AboutSensingView()
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              BeidTextControl("Done", accessibilityLabel: "Done") { showAboutSensing = false }
            }
            .beidWithoutSharedBackground()
          }
      }
    }
  }
}

#Preview {
  WelcomeView().environmentObject(AppCoordinator())
}
