// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#if DEBUG || BEID_INTERNAL_DEMO
import SwiftUI

struct InternalDemoBannerOverlay: View {
  @ObservedObject var sensing: SensingCoordinator

  var body: some View {
    if DemoBannerPresentation.isVisible(
      pendingScenarioIdentifier: sensing.pendingDemoScenarioIdentifier,
      activeScenarioIdentifier: sensing.activeDemoScenarioIdentifier
    ) {
      VStack(spacing: 0) {
        Text("DEMO")
          .font(.caption.bold())
          .foregroundStyle(.black)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 5)
          .background(Color.yellow)
          .accessibilityLabel("Demo mode")
          .accessibilityIdentifier("Demo mode banner")
        Spacer(minLength: 0)
      }
      .allowsHitTesting(false)
      .ignoresSafeArea(edges: .top)
    }
  }
}
#endif
