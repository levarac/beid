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
          onConnected: { address, connector in
            coordinator.completeWalletConnect(address: address, connector: connector)
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
  private enum Provider: Equatable {
    case reown
    case coinbase
    #if DEBUG
    case metamask
    #endif
  }

  @Environment(\.openURL) private var openURL
  @StateObject private var reownClient = ReownWalletConnectClient.shared
  @StateObject private var coinbaseClient = CoinbaseWalletConnector.shared
  #if DEBUG
  @StateObject private var metaMaskClient = MetaMaskConnector.shared
  #endif
  @State private var selectedProvider: Provider?
  let onConnected: (String, any WalletConnector) -> Void
  let secondaryAction: (title: LocalizedStringKey, action: () -> Void)?

  init(
    onConnected: @escaping (String, any WalletConnector) -> Void,
    secondaryAction: (title: LocalizedStringKey, action: () -> Void)? = nil
  ) {
    self.onConnected = onConnected
    self.secondaryAction = secondaryAction
  }

  var body: some View {
    VStack(spacing: DS.Space.l) {
      switch selectedProvider {
      case nil:
        providerSelectionContent
      case .reown:
        connectorContent(reownClient, provider: .reown)
      case .coinbase:
        connectorContent(coinbaseClient, provider: .coinbase)
      #if DEBUG
      case .metamask:
        connectorContent(metaMaskClient, provider: .metamask)
      #endif
      }
    }
    .task {
      reownClient.configureIfNeeded()
      coinbaseClient.configureIfNeeded()
      #if DEBUG
      metaMaskClient.configureIfNeeded()
      #endif
      // A wallet may have approved a pairing started from a previous
      // mount of this view (e.g. the user backgrounded the app, or left
      // for the event-code fallback, while `.awaitingApproval`) — deliver
      // that already-settled state now, since `.onChange` below only
      // fires on a *transition* and would otherwise never fire for a
      // state that was already `.connected` when this view appeared.
      deliverConnectedState(from: reownClient, provider: .reown)
      deliverConnectedState(from: coinbaseClient, provider: .coinbase)
      #if DEBUG
      deliverConnectedState(from: metaMaskClient, provider: .metamask)
      #endif
    }
    .onChange(of: reownClient.state) { _, newState in
      if selectedProvider == .reown, case .connected(let address) = newState {
        onConnected(address, reownClient)
      }
    }
    .onChange(of: coinbaseClient.state) { _, newState in
      if selectedProvider == .coinbase, case .connected(let address) = newState {
        onConnected(address, coinbaseClient)
      }
    }
    #if DEBUG
    .onChange(of: metaMaskClient.state) { _, newState in
      if selectedProvider == .metamask, case .connected(let address) = newState {
        onConnected(address, metaMaskClient)
      }
    }
    #endif
  }

  @ViewBuilder
  private func connectorContent<C: WalletConnector>(_ client: C, provider: Provider) -> some View {
    switch client.state {
    case .notConfigured:
      notConfiguredContent(client: client)
    case .unavailable(.walletNotInstalled):
      walletNotInstalledContent(provider: provider, client: client)
    case .idle:
      connectingContent
        .task { await client.connect() }
    case .connecting:
      connectingContent
    case .awaitingApproval(let uri):
      awaitingApprovalContent(uri: uri, provider: provider, client: client)
    case .connected(let address):
      connectedContent(address: address)
    case .failed(let message):
      failedContent(message: message, client: client)
    }
  }

  private func notConfiguredContent<C: WalletConnector>(client: C) -> some View {
    VStack(spacing: DS.Space.l) {
      BeidHeroHeader(
        systemImage: "exclamationmark.triangle.fill",
        title: "WalletConnect not configured",
        subtitle: "beid needs a Reown Cloud project ID to connect a wallet. Copy ios/Secrets.example.plist to ios/Beid/Secrets.plist and fill in PROJECT_ID from dashboard.reown.com.",
        tint: DS.Color.actionPrimary
      )
      BeidSecondaryButton(title: "Choose another wallet") {
        chooseAnotherWallet(client)
      }
      .tint(DS.Color.actionPrimary)
      if let secondaryAction {
        BeidSecondaryButton(title: secondaryAction.title, action: secondaryAction.action)
          .tint(DS.Color.actionPrimary)
      }
    }
  }

  private var providerSelectionContent: some View {
    VStack(spacing: DS.Space.s) {
      BeidHeroHeader(
        systemImage: "wallet.pass.fill",
        title: "Connect Your Wallet",
        subtitle: "beid uses your wallet to sign proofs of event attendance.",
        tint: DS.Color.actionPrimary
      )

      VStack(spacing: DS.Space.s) {
        BeidPrimaryButton("Connect Wallet", systemImage: "wallet.pass") {
          selectedProvider = .reown
        }
        .tint(DS.Color.actionPrimary)
        .padding(.top, DS.Space.s)

        BeidSecondaryButton(title: "Connect with Coinbase Wallet") {
          selectedProvider = .coinbase
        }
        .tint(DS.Color.actionPrimary)

        #if DEBUG
        BeidSecondaryButton(title: "Connect with MetaMask") {
          selectedProvider = .metamask
        }
        .tint(DS.Color.actionPrimary)
        #endif

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

  private func awaitingApprovalContent<C: WalletConnector>(
    uri: String?,
    provider: Provider,
    client: C
  ) -> some View {
    VStack(spacing: DS.Space.m) {
      Text(approvalTitle(for: provider))
        .font(DS.Font.sectionTitle)
        .foregroundStyle(DS.Color.textPrimary)
        .multilineTextAlignment(.center)

      if let uri, let qrImage = QRCodeRenderer.image(for: uri) {
        qrImage
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: DS.Size.qrCode, height: DS.Size.qrCode)
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

      if let uri {
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
      }

      HStack(spacing: DS.Space.s) {
        ProgressView()
          .tint(DS.Color.actionPrimary)
        Text("Waiting for wallet to approve…")
          .font(DS.Font.supporting)
          .foregroundStyle(DS.Color.textSecondary)
      }
      .padding(.top, DS.Space.s)

      Button("Cancel", role: .cancel) {
        chooseAnotherWallet(client)
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

  private func failedContent<C: WalletConnector>(message: String, client: C) -> some View {
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
          client.disconnect()
          Task { await client.connect() }
        }
        .tint(DS.Color.actionPrimary)

        BeidSecondaryButton(title: "Choose another wallet") {
          chooseAnotherWallet(client)
        }
        .tint(DS.Color.actionPrimary)

        if let secondaryAction {
          BeidSecondaryButton(title: secondaryAction.title, action: secondaryAction.action)
            .tint(DS.Color.actionPrimary)
        }
      }
    }
  }

  private func walletNotInstalledContent<C: WalletConnector>(
    provider: Provider,
    client: C
  ) -> some View {
    VStack(spacing: DS.Space.l) {
      BeidHeroHeader(
        systemImage: "wallet.pass.fill",
        title: walletNotInstalledTitle(for: provider),
        subtitle: walletNotInstalledSubtitle(for: provider),
        tint: DS.Color.actionPrimary
      )
      VStack(spacing: DS.Space.s) {
        BeidPrimaryButton(walletStoreButtonTitle(for: provider), systemImage: "arrow.up.right.square") {
          openURL(walletStoreURL(for: provider))
        }
        .tint(DS.Color.actionPrimary)

        BeidSecondaryButton(title: "Choose another wallet") {
          chooseAnotherWallet(client)
        }
        .tint(DS.Color.actionPrimary)

        if let secondaryAction {
          BeidSecondaryButton(title: secondaryAction.title, action: secondaryAction.action)
            .tint(DS.Color.actionPrimary)
        }
      }
    }
  }

  private func chooseAnotherWallet<C: WalletConnector>(_ client: C) {
    client.disconnect()
    selectedProvider = nil
  }

  private func approvalTitle(for provider: Provider) -> LocalizedStringKey {
    switch provider {
    case .reown:
      return "Scan with a WalletConnect-compatible wallet"
    case .coinbase:
      return "Approve the connection in Coinbase Wallet"
    #if DEBUG
    case .metamask:
      return "Approve the connection in MetaMask"
    #endif
    }
  }

  private func walletNotInstalledTitle(for provider: Provider) -> LocalizedStringKey {
    switch provider {
    case .reown, .coinbase:
      return "Coinbase Wallet is not installed"
    #if DEBUG
    case .metamask:
      return "MetaMask is not installed"
    #endif
    }
  }

  private func walletNotInstalledSubtitle(for provider: Provider) -> LocalizedStringKey {
    switch provider {
    case .reown, .coinbase:
      return "Install Coinbase Wallet to connect without a Reown project ID."
    #if DEBUG
    case .metamask:
      return "Install MetaMask to test the direct connection."
    #endif
    }
  }

  private func walletStoreButtonTitle(for provider: Provider) -> LocalizedStringKey {
    switch provider {
    case .reown, .coinbase:
      return "Get Coinbase Wallet"
    #if DEBUG
    case .metamask:
      return "Get MetaMask"
    #endif
    }
  }

  private func walletStoreURL(for provider: Provider) -> URL {
    switch provider {
    case .reown, .coinbase:
      return CoinbaseWalletConnector.appStoreURL
    #if DEBUG
    case .metamask:
      return MetaMaskConnector.appStoreURL
    #endif
    }
  }

  private func deliverConnectedState<C: WalletConnector>(from client: C, provider: Provider) {
    guard selectedProvider == nil, case .connected(let address) = client.state else { return }
    selectedProvider = provider
    onConnected(address, client)
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
