// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

@main
struct BeidApp: App {
  @StateObject private var coordinator = AppCoordinator()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(coordinator)
        .onOpenURL { url in
          CoinbaseWalletConnector.shared.handle(url: url)
          MetaMaskConnector.shared.handle(url: url)
        }
    }
  }
}
