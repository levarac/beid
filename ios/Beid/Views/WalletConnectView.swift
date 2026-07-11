// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Wallet step in the `.walletFirst` `OnboardingMode` order. Real
/// WalletConnect (Reown) pairing via `WalletConnectPairingView` — see
/// ios/README.md "WalletConnect". Not a motif-accent screen (§5): every
/// tint here is `DS.Color.actionPrimary`, same as the rest of onboarding.
struct WalletConnectView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    BeidAdaptiveContent {
      VStack(spacing: DS.Space.l) {
        Spacer()

        WalletConnectPairingView(
          onConnected: { address in
            coordinator.completeWalletConnect(address: address)
          },
          secondaryAction: (
            title: "Enter event code instead",
            action: { coordinator.skipWalletForEventCode() }
          )
        )
        .padding(.horizontal, DS.Space.pageMargin)

        Spacer()
      }
      .padding(.bottom, DS.Space.xl)
    }
  }
}

/// Reusable real WalletConnect pairing UI, shared by the onboarding
/// `WalletConnectView` and the Account sheet's "Connect Wallet" action.
/// `onConnected` is called exactly once, with the paired address, when the
/// SDK reports a settled session. `secondaryAction` is an optional escape
/// hatch shown alongside the primary action (onboarding uses "Enter event
/// code instead"; the Account sheet passes `nil` and relies on its own
/// Cancel toolbar button instead).
struct WalletConnectPairingView: View {
  @StateObject private var client = ReownWalletConnectClient.shared
  let onConnected: (String) -> Void
  let secondaryAction: (title: LocalizedStringKey, action: () -> Void)?

  init(
    onConnected: @escaping (String) -> Void,
    secondaryAction: (title: LocalizedStringKey, action: () -> Void)? = nil
  ) {
    self.onConnected = onConnected
    self.secondaryAction = secondaryAction
  }

  var body: some View {
    VStack(spacing: DS.Space.l) {
      switch client.state {
      case .notConfigured:
        notConfiguredContent
      case .idle:
        idleContent
      case .connecting:
        connectingContent
      case .awaitingApproval(let uri):
        awaitingApprovalContent(uri: uri)
      case .connected(let address):
        connectedContent(address: address)
      case .failed(let message):
        failedContent(message: message)
      }
    }
    .task {
      client.configureIfNeeded()
      // A wallet may have approved a pairing started from a previous
      // mount of this view (e.g. the user backgrounded the app, or left
      // for the event-code fallback, while `.awaitingApproval`) — deliver
      // that already-settled state now, since `.onChange` below only
      // fires on a *transition* and would otherwise never fire for a
      // state that was already `.connected` when this view appeared.
      if case .connected(let address) = client.state {
        onConnected(address)
      }
    }
    .onChange(of: client.state) { _, newState in
      if case .connected(let address) = newState {
        onConnected(address)
      }
    }
  }

  private var notConfiguredContent: some View {
    VStack(spacing: DS.Space.l) {
      BeidHeroHeader(
        systemImage: "exclamationmark.triangle.fill",
        title: "WalletConnect not configured",
        subtitle: "beid needs a Reown Cloud project ID to connect a wallet. Copy ios/Secrets.example.plist to ios/Beid/Secrets.plist and fill in PROJECT_ID from dashboard.reown.com.",
        tint: DS.Color.actionPrimary
      )
      if let secondaryAction {
        BeidSecondaryButton(title: secondaryAction.title, action: secondaryAction.action)
          .tint(DS.Color.actionPrimary)
      }
    }
  }

  private var idleContent: some View {
    VStack(spacing: DS.Space.s) {
      BeidHeroHeader(
        systemImage: "wallet.pass.fill",
        title: "Connect Your Wallet",
        subtitle: "beid uses your wallet to sign proofs of event attendance.",
        tint: DS.Color.actionPrimary
      )

      VStack(spacing: DS.Space.s) {
        BeidPrimaryButton("Connect Wallet", systemImage: "wallet.pass") {
          Task { await client.connect() }
        }
        .tint(DS.Color.actionPrimary)
        .padding(.top, DS.Space.s)

        if let secondaryAction {
          BeidSecondaryButton(title: secondaryAction.title, action: secondaryAction.action)
            .tint(DS.Color.actionPrimary)
        }
      }
    }
  }

  private var connectingContent: some View {
    VStack(spacing: DS.Space.l) {
      BeidHeroHeader(
        systemImage: "wallet.pass.fill",
        title: "Connect Your Wallet",
        subtitle: nil,
        tint: DS.Color.actionPrimary
      )
      ProgressView()
        .tint(DS.Color.actionPrimary)
    }
  }

  private func awaitingApprovalContent(uri: String) -> some View {
    VStack(spacing: DS.Space.m) {
      Text("Scan with a WalletConnect-compatible wallet")
        .font(DS.Font.sectionTitle)
        .foregroundStyle(DS.Color.textPrimary)
        .multilineTextAlignment(.center)

      if let qrImage = QRCodeRenderer.image(for: uri) {
        qrImage
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: 220, height: 220)
          .padding(DS.Space.s)
          .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
              .fill(DS.Color.surfaceRaised)
          )
          .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
              .strokeBorder(DS.Color.strokeHairline, lineWidth: 1)
          )
          .accessibilityHidden(true)
      }

      Text(verbatim: uri)
        .font(DS.Font.ledgerMono)
        .lineLimit(3)
        .truncationMode(.middle)
        .foregroundStyle(DS.Color.textSecondary)
        .textSelection(.enabled)
        .accessibilityLabel(Text("Pairing URI"))

      BeidSecondaryButton(title: "Copy URI") {
        UIPasteboard.general.string = uri
      }
      .tint(DS.Color.actionPrimary)

      HStack(spacing: DS.Space.s) {
        ProgressView()
          .tint(DS.Color.actionPrimary)
        Text("Waiting for wallet to approve…")
          .font(DS.Font.supporting)
          .foregroundStyle(DS.Color.textSecondary)
      }
      .padding(.top, DS.Space.s)

      Button("Cancel", role: .cancel) {
        client.reset()
      }
      .tint(DS.Color.actionPrimary)
      .padding(.top, DS.Space.xs)
    }
  }

  private func connectedContent(address: String) -> some View {
    BeidHeroHeader(
      systemImage: "checkmark.circle.fill",
      title: "Connected",
      subtitle: nil,
      tint: DS.Color.actionPrimary
    )
  }

  private func failedContent(message: String) -> some View {
    VStack(spacing: DS.Space.l) {
      BeidHeroHeader(
        systemImage: "xmark.octagon.fill",
        title: "Connection failed",
        subtitle: "beid couldn't connect to your wallet. Check your connection and try again.",
        tint: DS.Color.actionPrimary
      )
      Text(verbatim: message)
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.textSecondary)
        .multilineTextAlignment(.center)
      VStack(spacing: DS.Space.s) {
        BeidSecondaryButton(title: "Try Again") {
          client.reset()
        }
        .tint(DS.Color.actionPrimary)

        if let secondaryAction {
          BeidSecondaryButton(title: secondaryAction.title, action: secondaryAction.action)
            .tint(DS.Color.actionPrimary)
        }
      }
    }
  }
}

#Preview {
  WalletConnectView().environmentObject(AppCoordinator())
}

#Preview("Dark") {
  WalletConnectView()
    .environmentObject(AppCoordinator())
    .preferredColorScheme(.dark)
}
