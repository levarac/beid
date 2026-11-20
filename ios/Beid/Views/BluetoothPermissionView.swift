// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Explains the Bluetooth request before the system asks for permission.
struct BluetoothPermissionView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    BluetoothOnboardingLayout(
      actionTitle: "Continue",
      actionIdentifier: "bluetooth.permission.continue",
      action: { coordinator.requestBluetoothPermission() }
    ) {
      VStack(spacing: DS.Space.l) {
        BluetoothNearbyIllustration()

        VStack(spacing: DS.Space.s + DS.Space.xs) {
          Text("Allow Bluetooth access")
            .beidTextStyle(DS.Font.Library.title19)
            .accessibilityAddTraits(.isHeader)
          Text("beid needs Bluetooth to find your event and exchange signals with nearby devices. These observations help create your Record.")
            .beidTextStyle(DS.Font.Library.body15)
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
            .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
            .accessibilityIdentifier("bluetooth.permission.purpose")
        }
        .foregroundStyle(DS.Color.textPrimary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

        Text("Your device may ask for permission.")
          .beidTextStyle(DS.Font.Library.body13)
          .foregroundStyle(DS.Color.textSecondary)
          .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
          .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// Shares the native action and its placement across both Bluetooth states.
struct BluetoothOnboardingLayout<Content: View>: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  let actionTitle: LocalizedStringKey
  let actionIdentifier: String
  let action: () -> Void
  @ViewBuilder var content: Content

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: DS.Space.l) {
          Spacer(minLength: 0)
          content
          if horizontalSizeClass == .regular { primaryAction }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.pageMargin)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
        .frame(minHeight: geometry.size.height)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if horizontalSizeClass != .regular {
        primaryAction
          .padding(.horizontal, DS.Space.pageMargin)
          .padding(.vertical, DS.Space.s)
          .background(DS.Color.surfaceCanvas)
      }
    }
    .background(DS.Color.surfaceCanvas)
  }

  private var primaryAction: some View {
    Button(action: action) {
      Text(actionTitle)
        .foregroundStyle(DS.Color.labelOnActionPrimary)
        .frame(maxWidth: .infinity, minHeight: DS.Size.minHitTarget)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.capsule)
    .controlSize(.large)
    .tint(DS.Color.actionPrimary)
    .accessibilityIdentifier(actionIdentifier)
  }
}

struct BluetoothNearbyIllustration: View {
  var isOff = false

  var body: some View {
    HStack(spacing: DS.Space.m) {
      Image(systemName: "iphone")
        .font(DS.Font.bluetoothEndpointSymbol)
      Image(systemName: isOff ? "xmark.circle" : "dot.radiowaves.left.and.right")
        .font(DS.Font.bluetoothStateSymbol)
        .foregroundStyle(isOff ? DS.Color.statusOff : DS.Color.textPrimary)
      Image(systemName: "iphone")
        .font(DS.Font.bluetoothEndpointSymbol)
    }
    .foregroundStyle(DS.Color.textPrimary)
    .frame(maxWidth: .infinity)
    .accessibilityHidden(true)
  }
}

#Preview {
  BluetoothPermissionView().environmentObject(AppCoordinator())
}
