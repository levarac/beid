// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Explains the Bluetooth request before the system asks for permission.
struct BluetoothPermissionView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 0) {
          Spacer(minLength: DS.Space.l)

          VStack(spacing: DS.Space.l) {
            BluetoothNearbyIllustration()

            VStack(spacing: DS.Space.s + DS.Space.xs) {
              Text("Allow Bluetooth access")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
              Text("beid needs Bluetooth to find your event and exchange signals with nearby devices. These observations help create your Record.")
                .font(.body)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                .accessibilityIdentifier("bluetooth.permission.purpose")
            }
            .foregroundStyle(DS.Color.textPrimary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: DS.Space.s + DS.Space.xs) {
              Text("Your device may ask for permission.")
                .font(.subheadline)
                .foregroundStyle(DS.Color.textSecondary)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
              Button {
                coordinator.requestBluetoothPermission()
              } label: {
                Text("Continue").frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .tint(DS.Color.actionPrimary)
              .accessibilityIdentifier("bluetooth.permission.continue")
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

struct BluetoothNearbyIllustration: View {
  var isOff = false

  var body: some View {
    HStack(spacing: DS.Space.m) {
      Image(systemName: "iphone")
        .font(.system(size: 40))
      Image(systemName: isOff ? "xmark.circle" : "dot.radiowaves.left.and.right")
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(isOff ? DS.Color.statusOff : DS.Color.textPrimary)
      Image(systemName: "iphone")
        .font(.system(size: 40))
    }
    .foregroundStyle(DS.Color.textPrimary)
    .frame(maxWidth: .infinity)
    .accessibilityHidden(true)
  }
}

#Preview {
  BluetoothPermissionView().environmentObject(AppCoordinator())
}
