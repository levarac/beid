// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit

/// Screen 03: Bluetooth-off state — open Settings CTA.
struct BluetoothOffView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    BeidStatusLayout(
      systemImage: "antenna.radiowaves.left.and.right.slash",
      title: "Bluetooth Is Off",
      message: "beid needs Bluetooth to sense nearby events automatically. Turn it on in Settings, then come back here.",
      tint: .orange,
      footer: {
      VStack(spacing: 12) {
        BeidPrimaryButton("Open Settings", systemImage: "gearshape") {
          coordinator.sensingCoordinator.reset()
          UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        }

        BeidSecondaryButton(title: "I've Enabled It") {
          coordinator.evaluateBluetoothState()
        }
      }
      }
    )
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
