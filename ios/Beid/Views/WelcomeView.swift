// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Screen 01. Continue opens Bluetooth setup without a wallet step.
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
          if let version = AppVersion.shortVersion() {
            Text(String(
              localized: "welcome.version",
              defaultValue: "V \(version)",
              comment: "The app's short version in the Welcome header. The value comes from app metadata."
            ))
            .beidTextStyle(DS.Font.Library.labelMono11)
            .foregroundStyle(DS.Color.textSecondary)
            .accessibilityIdentifier("welcome.version")
          }
        }

        // Figma's fixed sample illustration, never a proof or observation.
        Image("welcome-figma-sample-sigil")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: DS.Onboarding.welcomeHeroSize, height: DS.Onboarding.welcomeHeroSize)
          .accessibilityHidden(true)
          .frame(maxWidth: .infinity)
          .padding(.top, DS.Onboarding.welcomeHeroGap)

        Text("Record you were there.")
          .beidTextStyle(DS.Font.Library.display52)
          .foregroundStyle(DS.Color.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, DS.Onboarding.welcomeTitleGap)

        Text("Your phones say hello to each other, and keep a note anyone can verify.")
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
      BeidPrimaryButton("Continue") {
        coordinator.beginOnboarding()
      }
    }
    .sheet(isPresented: $showAboutSensing) {
      NavigationStack {
        AboutSensingView()
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              if #available(iOS 26, *) {
                Button(role: .confirm) { showAboutSensing = false }
              } else {
                Button("Done") { showAboutSensing = false }
              }
            }
          }
      }
    }
  }
}

#Preview {
  WelcomeView().environmentObject(AppCoordinator())
}
