// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Wallet step in the `.walletFirst` `OnboardingMode` order. Stubbed: no
/// real WalletConnect SDK in this slice — tapping Connect produces a fake
/// address via `WalletConnectStub`.
struct WalletConnectView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "wallet.pass.fill")
        .font(.system(size: 56))
        .foregroundStyle(.blue)

      Text("Connect Your Wallet")
        .font(.title2.bold())

      Text("beid uses your wallet to sign proofs. This is a stub for now — no real WalletConnect session is created.")
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 32)

      Spacer()

      Button {
        coordinator.completeWalletConnect()
      } label: {
        Text("Connect Wallet")
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
  WalletConnectView().environmentObject(AppCoordinator())
}
