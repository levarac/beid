// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 01: Welcome.
struct WelcomeView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "checkmark.seal.fill")
        .font(.system(size: 72))
        .foregroundStyle(.blue)

      Text("beid")
        .font(.largeTitle.bold())

      Text("Prove you were there. Automatically.")
        .font(.title3)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 32)

      Spacer()

      Button {
        coordinator.beginOnboarding()
      } label: {
        Text("Get Started")
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
  WelcomeView().environmentObject(AppCoordinator())
}
