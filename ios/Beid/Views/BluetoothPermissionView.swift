// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 02: Bluetooth permission guide — 3 benefit bullets, each with a
/// title and a supporting sentence (docs/specs/onboarding-redesign.md §4.2).
struct BluetoothPermissionView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  private let bullets: [(title: LocalizedStringKey, subtitle: LocalizedStringKey)] = [
    ("Events find you", "Nearby events appear automatically — no codes, no search."),
    ("Private by design", "Only anonymous proofs are exchanged, never your identity."),
    ("Zero effort", "Sensing runs quietly in the background. Nothing to tap."),
  ]

  var body: some View {
    BeidScreen {
      BeidHeroHeader(
        title: "Enable Bluetooth",
        subtitle: "beid senses nearby events and people over Bluetooth Low Energy — that's how it proves you were really there."
      )

      BeidPanel {
        VStack(alignment: .leading, spacing: DS.Space.m) {
          ForEach(bullets.indices, id: \.self) { index in
            let bullet = bullets[index]
            BeidBulletRow(title: bullet.title, subtitle: bullet.subtitle)
          }
        }
      }
    } footer: {
      VStack(spacing: DS.Space.s) {
        BeidPrimaryButton("Allow Bluetooth") {
          coordinator.requestBluetoothPermission()
        }

        Text("You can change this anytime in Settings.")
          .font(DS.Font.meta)
          .foregroundStyle(DS.Color.textSecondary)
      }
    }
  }
}

#Preview {
  BluetoothPermissionView().environmentObject(AppCoordinator())
}

#Preview("Dark") {
  BluetoothPermissionView()
    .environmentObject(AppCoordinator())
    .preferredColorScheme(.dark)
}
