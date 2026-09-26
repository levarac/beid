// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 02: Bluetooth permission guide. The existing permission request
/// remains the action behind the Flat 2b primary button.
struct BluetoothPermissionView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  private let steps: [FlatOnboardingSteps.Step] = [
    .init("Events find you", detail: "Nearby events appear automatically — no codes, no search."),
    .init("Private by design", detail: "Phones exchange rotating anonymous IDs, not names or wallet addresses."),
    .init("Zero effort", detail: "Sensing runs quietly in the background. Nothing to tap."),
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

        Text("beid senses nearby events and people over Bluetooth Low Energy — that’s how it proves you were really there.")
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
