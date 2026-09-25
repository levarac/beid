// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit

@main
struct BeidApp: App {
  @StateObject private var coordinator: AppCoordinator
  @StateObject private var eventKeySign: EventKeySignCoordinator

  init() {
    let app = AppCoordinator()
    _coordinator = StateObject(wrappedValue: app)
    _eventKeySign = StateObject(wrappedValue: EventKeySignCoordinator(
      resolveEvent: { eventIdHex in
        guard let event = app.sensingCoordinator.eventKeySigningEvent(forCanonicalEventIdHex: eventIdHex) else {
          return nil
        }
        let recordedName = app.proofStore.proofs.last { $0.eventCode == event.eventCode }?.eventName
        return (event.eventCode, event.displayName ?? recordedName)
      },
      cryptography: { app.sensingCoordinator.eventKeySigningCryptography },
      openURL: { UIApplication.shared.open($0) }
    ))

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
        .modifier(EventKeySignPresentation(coordinator: eventKeySign))
        .onOpenURL { url in
          // MetaMask shares the `beid` scheme; the signing entry point
          // claims only its own host and passes everything else on.
          if eventKeySign.handle(url: url) { return }
          MetaMaskConnector.shared.handle(url: url)
        }
    }
  }
}
