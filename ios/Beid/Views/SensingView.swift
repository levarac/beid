// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 05: Scan screen with a radar animation, "Sensing automatically".
struct SensingView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulse = false

  var body: some View {
    BeidScreen {
      VStack(spacing: BeidDesign.Spacing.section) {
        radar

        VStack(spacing: BeidDesign.Spacing.compact) {
          Text("Sensing automatically")
            .font(DS.Font.sectionTitle)
            .multilineTextAlignment(.center)

          Text("Keep beid open nearby to collect proof of attendance.")
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.textSecondary)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .onAppear { pulse = !reduceMotion }
    .accessibilityIdentifier("scan.sensing")
  }

  private var radar: some View {
    ZStack {
      ForEach(0..<3, id: \.self) { index in
        Circle()
          .stroke(.tint.opacity(0.34), lineWidth: 2)
          .scaleEffect(pulse ? 1.6 : 0.48)
          .opacity(pulse ? 0 : 0.75)
          .animation(reduceMotion ? nil : pulseAnimation(delay: Double(index) * 0.5), value: pulse)
      }

      BeidGlyph(
        systemImage: "dot.radiowaves.left.and.right",
        assetImage: "encounter-field-pulse",
        tint: .accentColor,
        size: 86
      )
    }
    .frame(width: 210, height: 210)
  }

  private func pulseAnimation(delay: Double) -> Animation {
    .easeOut(duration: 1.8)
      .repeatForever(autoreverses: false)
      .delay(delay)
  }
}

#Preview {
  SensingView().environmentObject(AppCoordinator())
}
