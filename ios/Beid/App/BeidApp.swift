// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Darwin
import SwiftUI
import UIKit

@main
struct BeidApp: App {
  @StateObject private var coordinator = AppCoordinator()
  @StateObject private var diagnostics = DiagnosticsController.live()
  @Environment(\.scenePhase) private var scenePhase

  init() {
    DeviceSecretKeychainStore.removeLegacyUserDefaultsCopy(from: .standard)
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
        .environment(\.diagnosticsController, diagnostics)
        .onAppear {
          coordinator.sensingCoordinator.diagnostics = diagnostics
          coordinator.clockPreflight.diagnostics = diagnostics
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
          if phase == .active { diagnostics.setForeground(true) }
          if phase == .background { diagnostics.setForeground(false) }
        }
        .onOpenURL { url in
          MetaMaskConnector.shared.handle(url: url)
        }
    }
  }
}

private extension DiagnosticsController {
  static func live() -> DiagnosticsController {
    let bundle = Bundle.main
    let base = URL.applicationSupportDirectory
    let isolated = ProcessInfo.processInfo.arguments.contains("-beid-ui-test")
    let directory = (isolated ? FileManager.default.temporaryDirectory : base)
      .appendingPathComponent("SensingDiagnostics-v1", isDirectory: true)
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    let source = bundle.object(forInfoDictionaryKey: "BeidDiagnosticsSourceSHA") as? String
    let validSource = source.flatMap {
      $0.utf8.count == 40 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        ? $0 : nil
    }
    var machine = utsname()
    let model = uname(&machine) == 0
      ? withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      : "unknown"
    let metadata = DiagnosticsMetadata(
      model: String(model.prefix(64)), osVersion: String(UIDevice.current.systemVersion.prefix(32)),
      appBuild: String((build ?? "unknown").prefix(64)),
      sourceSHA: validSource
    )
    let queue = DiagnosticsQueue(directory: directory, metadata: metadata)
    let transport = isolated ? nil : DiagnosticsTransport(
      origin: bundle.object(forInfoDictionaryKey: "BeidDiagnosticsOrigin") as? String,
      writeToken: bundle.object(forInfoDictionaryKey: "BeidDiagnosticsWriteToken") as? String
    )
    return DiagnosticsController(queue: queue, upload: transport.map { transport in
      { body in try await transport.upload(body) }
    })
  }
}
