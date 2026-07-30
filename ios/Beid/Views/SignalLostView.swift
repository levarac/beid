// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 06d: Signal Lost — warning state.
struct SignalLostView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  let event: EventSession

  var body: some View {
    BeidStatusLayout(
      systemImage: "exclamationmark.triangle.fill",
      title: "Signal Lost",
      message: "beid lost the connection to \(event.name). Move closer and we'll pick it back up automatically.",
      footer: {
      BeidPrimaryButton("Try Again", systemImage: "arrow.clockwise", labelColor: DS.Color.labelOnWarning) {
        coordinator.sensingCoordinator.resumeSensing()
      }
      }
    )
    // Recovery screen: header glyph + "Try Again" both get the shared
    // signalWarning accent — DESIGN.md §5 "one motif accent per screen".
    .tint(DS.Color.signalWarning)
  }
}

#Preview {
  SignalLostView(event: .demoSample).environmentObject(AppCoordinator())
}

#Preview("Dark") {
  SignalLostView(event: .demoSample)
    .environmentObject(AppCoordinator())
    .preferredColorScheme(.dark)
}
