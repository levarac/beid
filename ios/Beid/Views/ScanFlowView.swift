// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screens 05-07 (+06d), switched on `SensingCoordinator.phase`.
struct ScanFlowView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  // `AppCoordinator` doesn't republish when its nested `sensingCoordinator`
  // changes, so this view observes it directly to react to `phase` updates.
  @ObservedObject private var sensing: SensingCoordinator

  init(sensing: SensingCoordinator) {
    self.sensing = sensing
  }

  var body: some View {
    NavigationStack {
      content
        .animation(BeidDesign.Animation.soft, value: sensing.phase)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              BeidDesign.haptic()
              coordinator.finishScan()
            } label: {
              Label("Cancel", systemImage: "xmark")
            }
          }
        }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch sensing.phase {
    case .idle, .sensing:
      SensingView()
    case .eventFound(let event):
      EventFoundView(event: event)
    case .verifying(let event, let peersVerified):
      VerifyingView(event: event, peersVerified: peersVerified)
    case .verified(let event, let peersVerified):
      VerifiedView(event: event, peersVerified: peersVerified)
    case .signalLost(let event):
      SignalLostView(event: event)
    case .collected(let proof):
      ProofCollectedView(proof: proof)
    }
  }
}

#Preview {
  let coordinator = AppCoordinator()
  return ScanFlowView(sensing: coordinator.sensingCoordinator).environmentObject(coordinator)
}
