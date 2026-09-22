// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 06a: Event Found — event card slides in.
struct EventFoundView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let event: EventSession
  let onRetryVerification: () -> Void

  @State private var appeared = false

  init(
    event: EventSession,
    onRetryVerification: @escaping () -> Void = {}
  ) {
    self.event = event
    self.onRetryVerification = onRetryVerification
  }

  var body: some View {
    BeidStatusLayout(
      systemImage: "sparkles",
      title: "Event Found",
      message: "Verification starts automatically — stay nearby",
      accessory: {
      EventCardView(event: event, badge: .detected) {
        EventIdentityVerificationRow(
          status: event.identityVerification,
          onRetry: onRetryVerification
        )
      }
        .offset(y: appeared ? 0 : 40)
        .opacity(appeared ? 1 : 0)
      }
    )
    // Sensing screen: actionPrimary tint — Flat 2b has one ink and no
    // per-screen motif accents (DESIGN.md §5).
    .tint(DS.Color.actionPrimary)
    .onAppear {
      withAnimation(reduceMotion ? nil : DS.Motion.entrance) {
        appeared = true
      }
    }
  }
}

#Preview {
  EventFoundView(event: .demoSample)
}

#Preview("Dark") {
  EventFoundView(event: .demoSample)
    .preferredColorScheme(.dark)
}
