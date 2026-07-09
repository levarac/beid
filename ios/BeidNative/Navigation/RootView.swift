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
      case .bluetoothPermission:
        BluetoothPermissionView()
      case .bluetoothOff:
        BluetoothOffView()
      case .home:
        CollectionHomeView()
      }
    }
    .fullScreenCover(isPresented: $coordinator.scanPresented) {
      ScanFlowView(sensing: coordinator.sensingCoordinator)
    }
  }
}
