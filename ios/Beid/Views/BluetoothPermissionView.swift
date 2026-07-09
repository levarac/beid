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
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "dot.radiowaves.left.and.right")
        .font(.system(size: 56))
        .foregroundStyle(.blue)

      Text("Enable Bluetooth")
        .font(.title2.bold())

      VStack(alignment: .leading, spacing: 16) {
        ForEach(bullets, id: \.text) { bullet in
          HStack(spacing: 12) {
            Image(systemName: bullet.icon)
              .foregroundStyle(.blue)
              .frame(width: 24)
            Text(bullet.text)
              .font(.body)
          }
        }
      }
      .padding(.horizontal, 40)

      Spacer()

      Button {
        coordinator.requestBluetoothPermission()
      } label: {
        Text("Enable Bluetooth")
          .font(.headline)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.blue)
      .padding(.horizontal, 32)
      .padding(.bottom, 40)
    }
  }
}

#Preview {
  BluetoothPermissionView().environmentObject(AppCoordinator())
}
