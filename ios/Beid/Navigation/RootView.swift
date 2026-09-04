// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

struct RootView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    Group {
      switch coordinator.screen {
      case .welcome:
        WelcomeView()
      case .walletConnect:
        WalletConnectView()
      case .eventCodeEntry:
        EventCodeEntryView()
      case .bluetoothPermission:
        BluetoothPermissionView()
      case .bluetoothOff:
        BluetoothOffView()
      case .home:
        CollectionHomeView()
      }
    }
    #if DEBUG || BEID_INTERNAL_DEMO
    .overlay {
      InternalDemoBannerOverlay(sensing: coordinator.sensingCoordinator)
    }
    #endif
    .tint(DS.Color.actionPrimary)
    .animation(BeidDesign.Animation.soft, value: coordinator.screen)
    .fullScreenCover(isPresented: $coordinator.scanPresented) {
      ZStack {
        ScanFlowView(sensing: coordinator.sensingCoordinator)
          .tint(DS.Color.actionPrimary)
          .presentationBackground(.regularMaterial)
        #if DEBUG || BEID_INTERNAL_DEMO
        InternalDemoBannerOverlay(sensing: coordinator.sensingCoordinator)
        #endif
      }
    }
  }
}
