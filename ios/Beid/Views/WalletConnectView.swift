// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Wallet step in the `.walletFirst` `OnboardingMode` order. Stubbed: no
/// real WalletConnect SDK in this slice — tapping Connect produces a fake
/// address via `WalletConnectStub`.
struct WalletConnectView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    BeidAdaptiveContent {
      VStack(spacing: DS.Space.l) {
        Spacer()

        BeidHeroHeader(
          systemImage: "wallet.pass.fill",
          title: "Connect Your Wallet",
          subtitle: "beid uses your wallet to sign proofs. This is a stub for now — no real WalletConnect session is created.",
          tint: DS.Color.actionPrimary
        )

        Spacer()

        BeidPrimaryButton("Connect Wallet", systemImage: "wallet.pass") {
          coordinator.completeWalletConnect()
        }
        .tint(DS.Color.actionPrimary)
        .padding(.horizontal, DS.Space.pageMargin)
        .padding(.bottom, DS.Space.xl)
      }
    }
  }
}

#Preview {
  WalletConnectView().environmentObject(AppCoordinator())
}
