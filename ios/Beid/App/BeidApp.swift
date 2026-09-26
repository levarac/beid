// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

@main
struct BeidApp: App {
  @StateObject private var coordinator = AppCoordinator()

  init() {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = UIColor(DS.Color.surfaceCanvas)
    // UIKit draws the navigation bar's shadow at its bottom edge.
    appearance.shadowColor = UIColor(DS.Color.strokeHairline)

    let navigationBar = UINavigationBar.appearance()
    navigationBar.standardAppearance = appearance
    navigationBar.scrollEdgeAppearance = appearance
    navigationBar.compactAppearance = appearance
    navigationBar.compactScrollEdgeAppearance = appearance
  }

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
