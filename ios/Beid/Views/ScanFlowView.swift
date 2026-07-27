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
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              BeidDesign.haptic()
              coordinator.finishScan()
            } label: {
              Image(systemName: "xmark")
                .foregroundStyle(DS.Color.textPrimary)
                .frame(width: DS.Size.minHitTarget, height: DS.Size.minHitTarget)
                .beidSurface(interactive: true, cornerRadius: DS.Radius.pill)
            }
            .accessibilityLabel("Close")
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

#Preview("Sensing") {
  let coordinator = AppCoordinator()
  return ScanFlowView(sensing: coordinator.sensingCoordinator).environmentObject(coordinator)
}

#Preview("Sensing (Dark)") {
  let coordinator = AppCoordinator()
  return ScanFlowView(sensing: coordinator.sensingCoordinator)
    .environmentObject(coordinator)
    .preferredColorScheme(.dark)
}

// Only the container's default (.idle/.sensing) phase is previewed here.
// `phase` is `private(set)` on `SensingCoordinator` by design (state only
// advances through the real/demo sensing sequence) so other phases aren't
// independently reachable from a preview; each phase already has its own
// dedicated #Preview on its view (EventFoundView, VerifyingView,
// VerifiedView, SignalLostView, ProofCollectedView).
