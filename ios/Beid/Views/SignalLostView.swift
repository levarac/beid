// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 06d: Signal Lost — warning state.
struct SignalLostView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  let event: DemoEvent

  var body: some View {
    BeidStatusLayout(
      systemImage: "exclamationmark.triangle.fill",
      title: "Signal Lost",
      message: "beid lost the connection to \(event.name). Move closer and we'll pick it back up automatically.",
      tint: .orange,
      footer: {
      BeidPrimaryButton("Try Again", systemImage: "arrow.clockwise") {
        coordinator.sensingCoordinator.startSensing(demoEvent: event)
      }
      }
    )
  }
}

#Preview {
  SignalLostView(event: .sample).environmentObject(AppCoordinator())
}

#Preview("Dark") {
  SignalLostView(event: .sample)
    .environmentObject(AppCoordinator())
    .preferredColorScheme(.dark)
}
