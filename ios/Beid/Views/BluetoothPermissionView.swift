// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 02: Bluetooth permission guide — 3 benefit bullets.
struct BluetoothPermissionView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  private let bullets: [(icon: String, text: String)] = [
    ("sparkles", "Events find you"),
    ("lock.shield", "Private by design"),
    ("bolt.fill", "Zero effort"),
  ]

  var body: some View {
    BeidScreen {
      BeidHeroHeader(
        systemImage: "dot.radiowaves.left.and.right",
        title: "Enable Bluetooth",
        subtitle: "beid senses nearby event signals without making you scan codes or check in manually."
      )

      BeidPanel {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(bullets, id: \.text) { bullet in
            BeidBulletRow(systemImage: bullet.icon, title: bullet.text)
          }
        }
      }
    } footer: {
      BeidPrimaryButton("Enable Bluetooth", systemImage: "dot.radiowaves.left.and.right") {
        coordinator.requestBluetoothPermission()
      }
    }
  }
}

#Preview {
  BluetoothPermissionView().environmentObject(AppCoordinator())
}
