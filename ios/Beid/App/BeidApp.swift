// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

@main
struct BeidApp: App {
  @StateObject private var coordinator = AppCoordinator()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(coordinator)
        .onOpenURL { url in
          MetaMaskConnector.shared.handle(url: url)
        }
    }
  }
}
