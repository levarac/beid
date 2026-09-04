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
      systemImage: "antenna.radiowaves.left.and.right.slash",
      title: "Bluetooth is off",
      message: "beid can't sense events or collect proofs while Bluetooth is off.",
      accessory: {
        BeidNumberedStepList(steps: steps, labelColor: DS.Color.labelOnWarning)
      },
      footer: {
        VStack(spacing: DS.Space.s) {
          BeidPrimaryButton("Open settings", systemImage: "gearshape", labelColor: DS.Color.labelOnWarning) {
            coordinator.sensingCoordinator.reset()
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
          }

          BeidSecondaryButton(title: "I've turned it on") {
            coordinator.evaluateBluetoothState()
          }
        }
      }
    )
    // Recovery screen: the whole screen (header glyph, step-list badges, and
    // both buttons) gets the shared signalWarning accent, not just the
    // header — DESIGN.md §5 "one motif accent per screen" for
    // BluetoothOffView/SignalLostView.
    .tint(DS.Color.signalWarning)
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
