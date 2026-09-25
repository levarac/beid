// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit

/// Screen 03: Bluetooth-off state. Verification note: the iOS
/// Simulator always reports Bluetooth as powered on, so this screen is
/// reachable only via #Preview/snapshot there, never a live device state.
struct BluetoothOffView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  private let steps: [FlatOnboardingSteps.Step] = [
    .init("Open Settings"),
    .init("Tap Bluetooth"),
    .init("Switch it on"),
  ]

  var body: some View {
    FlatOnboardingPage(footerInsetReduction: DS.Onboarding.recoveryFooterDrop) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: DS.Onboarding.statusLabelGap) {
          Circle()
            .fill(DS.Color.statusOff)
            .frame(width: DS.Onboarding.statusDot, height: DS.Onboarding.statusDot)
            .accessibilityHidden(true)
          Text("Bluetooth · off")
            .beidTextStyle(DS.Font.Library.labelMono11)
            .foregroundStyle(DS.Color.textPrimary)
        }

        Text("Bluetooth\nis off")
          .beidTextStyle(DS.Font.Library.display52)
          .foregroundStyle(DS.Color.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, DS.Onboarding.titleGap)

        Text("beid can’t sense events or collect proofs while Bluetooth is off.")
          .beidTextStyle(DS.Font.Library.body15)
          .foregroundStyle(DS.Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, DS.Onboarding.titleToBodyGap)

        FlatOnboardingSteps(steps: steps)
          .padding(.top, DS.Onboarding.recoveryStepsGap)
      }
    } footer: {
      VStack(spacing: DS.Onboarding.recoveryActionGap) {
        BeidPrimaryButton("Open Settings") {
          coordinator.sensingCoordinator.reset()
          UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        }

        BeidTextControl("I’ve turned it on") {
          coordinator.evaluateBluetoothState()
        }
        .frame(maxWidth: .infinity)
      }
    }
  }
}

#Preview {
  BluetoothOffView().environmentObject(AppCoordinator())
}
