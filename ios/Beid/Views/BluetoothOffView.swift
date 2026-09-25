// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit

/// Screen 03: Bluetooth-off state — numbered recovery steps + open Settings
/// CTA (docs/specs/onboarding-redesign.md §4.3). Verification note: the iOS
/// Simulator always reports Bluetooth as powered on, so this screen is
/// reachable only via #Preview/snapshot there, never a live device state.
struct BluetoothOffView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  private let steps: [LocalizedStringKey] = [
    "Open Settings",
    "Tap Bluetooth",
    "Switch it on",
  ]

  var body: some View {
    BeidStatusLayout(
      title: "Bluetooth is off",
      message: "beid can't sense events or collect proofs while Bluetooth is off.",
      accessory: {
        BeidNumberedStepList(steps: steps)
      },
      footer: {
        VStack(spacing: DS.Space.s) {
          BeidPrimaryButton("Open Settings") {
            coordinator.sensingCoordinator.reset()
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
          }

          BeidSecondaryButton(title: "I've turned it on") {
            coordinator.evaluateBluetoothState()
          }
        }
      }
    )
    // Keep the recovery actions in the same actionPrimary tint as the rest
    // of the app (DESIGN.md §5).
    .tint(DS.Color.actionPrimary)
  }
}

#Preview {
  BluetoothOffView().environmentObject(AppCoordinator())
}

#Preview("Dark") {
  BluetoothOffView()
    .environmentObject(AppCoordinator())
    .preferredColorScheme(.dark)
}
