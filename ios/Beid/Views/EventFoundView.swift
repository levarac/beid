// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 06a: Event Found — event card slides in.
struct EventFoundView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let event: DemoEvent

  @State private var appeared = false

  var body: some View {
    BeidStatusLayout(
      systemImage: "sparkles",
      title: "Event Found",
      message: "beid found a nearby event signal.",
      accessory: {
      BeidPanel {
        VStack(alignment: .leading, spacing: BeidDesign.Spacing.compact) {
          Text("Detected event")
            .font(DS.Font.supporting)
            .foregroundStyle(DS.Color.textSecondary)
          Text(event.name)
            .font(DS.Font.sectionTitle)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .offset(y: appeared ? 0 : 40)
      .opacity(appeared ? 1 : 0)
      }
    )
    .onAppear {
      withAnimation(reduceMotion ? nil : BeidDesign.Animation.entrance) {
        appeared = true
      }
    }
  }
}

#Preview {
  EventFoundView(event: .sample)
}
