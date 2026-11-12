// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Screen 02: Bluetooth permission guide. The existing permission request
/// remains the action behind the Flat 2b primary button.
struct BluetoothPermissionView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  private let steps: [FlatOnboardingSteps.Step] = [
    .init("sensing.explainer.chooseEvent.title", detail: "sensing.explainer.chooseEvent.detail"),
    .init("Private by design", detail: "Phones exchange rotating anonymous IDs, not names or wallet addresses."),
    .init("sensing.explainer.keepOpen.title", detail: "sensing.explainer.keepOpen.detail"),
  ]

  var body: some View {
    FlatOnboardingPage {
      VStack(alignment: .leading, spacing: 0) {
        Text("Setup · 1 / 1")
          .beidTextStyle(DS.Font.Library.labelMono11)
          .foregroundStyle(DS.Color.textPrimary)

        Text("Enable\nBluetooth")
          .beidTextStyle(DS.Font.Library.display52)
          .foregroundStyle(DS.Color.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, DS.Onboarding.titleGap)

        Text("beid uses Bluetooth Low Energy to find nearby events and hear nearby phones.")
          .beidTextStyle(DS.Font.Library.body15)
          .foregroundStyle(DS.Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, DS.Onboarding.titleToBodyGap)

        FlatOnboardingSteps(steps: steps)
          .padding(.top, DS.Onboarding.permissionStepsGap)
      }
    } footer: {
      VStack(spacing: DS.Onboarding.noteToButtonGap) {
        Text("You can change this anytime in Settings")
          .beidTextStyle(DS.Font.Library.labelMono9)
          .foregroundStyle(DS.Color.textSecondary)
          .frame(maxWidth: .infinity)

        BeidPrimaryButton("Allow Bluetooth") {
          coordinator.requestBluetoothPermission()
        }
      }
    }
  }
}

#Preview {
  BluetoothPermissionView().environmentObject(AppCoordinator())
}
