// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 06d: Signal Lost — warning state.
struct SignalLostView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  let event: DemoEvent

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 56))
        .foregroundStyle(.orange)

      Text("Signal Lost")
        .font(.title.bold())

      Text("beid lost the connection to \(event.name). Move closer and we'll pick it back up automatically.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)

      Spacer()

      Button {
        coordinator.sensingCoordinator.startSensing(demoEvent: event)
      } label: {
        Text("Try Again")
          .font(.headline)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.blue)
      .padding(.horizontal, 32)
      .padding(.bottom, 40)
    }
  }
}

#Preview {
  SignalLostView(event: .sample).environmentObject(AppCoordinator())
}
