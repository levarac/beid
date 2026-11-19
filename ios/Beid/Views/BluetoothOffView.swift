// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Explains how to turn Bluetooth back on before checking its state again.
struct BluetoothOffView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 0) {
          Spacer(minLength: DS.Space.l)

          VStack(spacing: DS.Space.l) {
            BluetoothNearbyIllustration(isOff: true)

            VStack(spacing: DS.Space.s + DS.Space.xs) {
              Text("Bluetooth is off")
                .beidTextStyle(DS.Font.Library.title19)
                .accessibilityAddTraits(.isHeader)
              Text("beid can’t find nearby events or record observations while Bluetooth is off.")
                .beidTextStyle(DS.Font.Library.body15)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
            }
            .foregroundStyle(DS.Color.textPrimary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: DS.Space.s + DS.Space.xs) {
              Text("Turn on Bluetooth in Settings > Bluetooth, then return to beid.")
                .beidTextStyle(DS.Font.Library.body13)
                .foregroundStyle(DS.Color.textSecondary)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
              Button {
                coordinator.evaluateBluetoothState()
              } label: {
                Text("Check again").frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .tint(DS.Color.actionPrimary)
              .accessibilityIdentifier("bluetooth.off.check-again")
            }
          }
          .padding(.horizontal, DS.Space.l)
          .frame(maxWidth: 440)

          Spacer(minLength: DS.Space.l)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: geometry.size.height)
      }
      .background(DS.Color.surfaceCanvas)
    }
  }
}

#Preview {
  BluetoothOffView().environmentObject(AppCoordinator())
}
