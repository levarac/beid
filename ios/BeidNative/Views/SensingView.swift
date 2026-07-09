// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 05: Scan screen with a radar animation, "Sensing automatically".
struct SensingView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @State private var pulse = false

  var body: some View {
    VStack(spacing: 32) {
      Spacer()

      ZStack {
        ForEach(0..<3, id: \.self) { index in
          Circle()
            .stroke(Color.blue.opacity(0.4), lineWidth: 2)
            .scaleEffect(pulse ? 1.6 : 0.4)
            .opacity(pulse ? 0 : 0.8)
            .animation(
              .easeOut(duration: 1.8)
                .repeatForever(autoreverses: false)
                .delay(Double(index) * 0.5),
              value: pulse
            )
        }
        Circle()
          .fill(Color.blue)
          .frame(width: 64, height: 64)
        Image(systemName: "dot.radiowaves.left.and.right")
          .foregroundStyle(.white)
          .font(.title2)
      }
      .frame(width: 200, height: 200)

      Text("Sensing automatically")
        .font(.title3.weight(.semibold))

      Text("Keep beid open nearby to collect proof of attendance.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)

      Spacer()
      Spacer()
    }
    .onAppear { pulse = true }
    .accessibilityIdentifier("scan.sensing")
  }
}

#Preview {
  SensingView().environmentObject(AppCoordinator())
}
