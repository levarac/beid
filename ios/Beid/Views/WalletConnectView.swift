// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Wallet step in the `.walletFirst` `OnboardingMode` order. Direct
/// app-to-app connection via `WalletConnectPairingView` — see
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

/// Reusable direct wallet-connect UI, shared by the onboarding
/// `WalletConnectView` and the Account sheet's "Connect Wallet" action.
/// `onConnected` is called exactly once, with the paired address, when the
/// SDK reports a settled session. `secondaryAction` is an optional escape
/// hatch shown alongside the primary action (onboarding uses "Enter event
/// code instead"; the Account sheet passes `nil` and relies on its own
/// Cancel toolbar button instead).
///
/// Generic over the Coinbase connector type (defaulted to the real
/// singleton below) purely so `#Preview` can inject a fake `WalletConnector`
/// sitting in an arbitrary `state` — see `PreviewWalletConnector` at the
/// bottom of this file. `metaMaskClient` stays a concrete, non-generic
/// singleton: every state this preview machinery needs is reachable through
/// the `coinbaseClient` slot already.
struct WalletConnectPairingView<Coinbase: WalletConnector>: View {
  fileprivate enum Provider: Equatable {
    case coinbase
    case metamask
  }

  @Environment(\.openURL) private var openURL
  @StateObject private var coinbaseClient: Coinbase
  @StateObject private var metaMaskClient = MetaMaskConnector.shared
  @State private var selectedProvider: Provider?
  let onConnected: (String, any WalletConnector) -> Void
  let secondaryAction: (title: LocalizedStringKey, action: () -> Void)?

  init(
    coinbaseClient: Coinbase = CoinbaseWalletConnector.shared,
    onConnected: @escaping (String, any WalletConnector) -> Void,
    secondaryAction: (title: LocalizedStringKey, action: () -> Void)? = nil
  ) {
    _coinbaseClient = StateObject(wrappedValue: coinbaseClient)
    self.onConnected = onConnected
    self.secondaryAction = secondaryAction
  }

  #if DEBUG
  /// Preview-only: lets a `#Preview` start already on a given provider,
  /// instead of every real call site's shared entrypoint at
  /// `providerSelectionContent`. `fileprivate` (not the default `internal`)
  /// because `Provider` itself is `fileprivate` — an initializer can't be
  /// more visible than the types in its own signature — which is fine since
  /// only the `#Preview` blocks below, in this same file, need it.
  fileprivate init(
    coinbaseClient: Coinbase = CoinbaseWalletConnector.shared,
    initialProvider: Provider,
    onConnected: @escaping (String, any WalletConnector) -> Void,
    secondaryAction: (title: LocalizedStringKey, action: () -> Void)? = nil
  ) {
    _coinbaseClient = StateObject(wrappedValue: coinbaseClient)
    _selectedProvider = State(wrappedValue: initialProvider)
    self.onConnected = onConnected
    self.secondaryAction = secondaryAction
  }
  #endif

  var body: some View {
    VStack(spacing: DS.Space.l) {
      switch selectedProvider {
      case nil:
        providerSelectionContent
      case .coinbase:
        connectorContent(coinbaseClient, provider: .coinbase)
      case .metamask:
        connectorContent(metaMaskClient, provider: .metamask)
      }
    }
    .task {
      coinbaseClient.configureIfNeeded()
      metaMaskClient.configureIfNeeded()
      // A wallet may have approved a connection started from a previous
      // mount of this view (e.g. the user backgrounded the app, or left
      // for the event-code fallback, while `.awaitingApproval`) — deliver
      // that already-settled state now, since `.onChange` below only
      // fires on a *transition* and would otherwise never fire for a
      // state that was already `.connected` when this view appeared.
      deliverConnectedState(from: coinbaseClient, provider: .coinbase)
      deliverConnectedState(from: metaMaskClient, provider: .metamask)
    }
    .onChange(of: coinbaseClient.state) { _, newState in
      if selectedProvider == .coinbase, case .connected(let address) = newState {
        onConnected(address, coinbaseClient)
      }
    }
    .onChange(of: metaMaskClient.state) { _, newState in
      if selectedProvider == .metamask, case .connected(let address) = newState {
        onConnected(address, metaMaskClient)
      }
    }
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

  /// `WalletConnectorState.notConfigured` is part of the shared
  /// `WalletConnector` protocol (see WalletConnector.swift), but neither
  /// `CoinbaseWalletConnector` nor `MetaMaskConnector` ever produces it —
  /// both start at `.idle` and need no external credential. This branch
  /// exists only so `connectorContent`'s switch stays exhaustive against the
  /// protocol's full state space.
  private func notConfiguredContent<C: WalletConnector>(client: C) -> some View {
    VStack(spacing: DS.Space.l) {
      BeidHeroHeader(
        systemImage: "exclamationmark.triangle.fill",
        title: "Wallet not available",
        subtitle: "This wallet can't be used right now. Choose another wallet to continue.",
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
        BeidPrimaryButton("Connect with Coinbase Wallet", systemImage: "wallet.pass") {
          selectedProvider = .coinbase
        }
        .tint(DS.Color.actionPrimary)
        .padding(.top, DS.Space.s)

        BeidSecondaryButton(title: "Connect with MetaMask") {
          selectedProvider = .metamask
        }
        .tint(DS.Color.actionPrimary)

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
    case .coinbase:
      return "Approve the connection in Coinbase Wallet"
    case .metamask:
      return "Approve the connection in MetaMask"
    }
  }

  private func walletNotInstalledTitle(for provider: Provider) -> LocalizedStringKey {
    switch provider {
    case .coinbase:
      return "Coinbase Wallet is not installed"
    case .metamask:
      return "MetaMask is not installed"
    }
  }

  private func walletNotInstalledSubtitle(for provider: Provider) -> LocalizedStringKey {
    switch provider {
    case .coinbase:
      return "Install Coinbase Wallet to connect directly."
    case .metamask:
      return "Install MetaMask to connect directly."
    }
  }

  private func walletStoreButtonTitle(for provider: Provider) -> LocalizedStringKey {
    switch provider {
    case .coinbase:
      return "Get Coinbase Wallet"
    case .metamask:
      return "Get MetaMask"
    }
  }

  private func walletStoreURL(for provider: Provider) -> URL {
    switch provider {
    case .coinbase:
      return CoinbaseWalletConnector.appStoreURL
    case .metamask:
      return MetaMaskConnector.appStoreURL
    }
  }

  private func deliverConnectedState<C: WalletConnector>(from client: C, provider: Provider) {
    guard selectedProvider == nil, case .connected(let address) = client.state else { return }
    selectedProvider = provider
    onConnected(address, client)
  }
}

#if DEBUG
/// Preview-only fake `WalletConnector` with a freely settable `state`, so
/// the `#Preview` blocks below can exercise every `WalletConnectorState`
/// case without a real wallet SDK. Not `DemoWalletConnector`: that one is
/// reserved for `EventBindingSheetView`'s demo escape hatch, is a singleton
/// with a `private(set)` state, and only ever transitions
/// `.idle → .connecting → .connected` — insufficient for previewing
/// `.awaitingApproval`, `.failed`, `.notConfigured`, or `.unavailable`.
@MainActor
private final class PreviewWalletConnector: ObservableObject, WalletConnector {
  @Published var state: WalletConnectorState

  init(state: WalletConnectorState) {
    self.state = state
  }

  var address: String? {
    if case .connected(let address) = state { return address }
    return nil
  }

  var chainId: String { "eip155:8453" }

  func configureIfNeeded() {}

  func connect() async {}

  func requestPersonalSign(
    messageHex: String,
    responseTimeout: TimeInterval,
    onDispatched: (() -> Void)?
  ) async -> Result<String, WalletConnectorError> {
    .failure(.notConnected)
  }

  func disconnect() {}

  @discardableResult
  func handle(url: URL) -> Bool { false }
}
#endif

#Preview {
  WalletConnectView().environmentObject(AppCoordinator())
}

#Preview("Dark") {
  WalletConnectView()
    .environmentObject(AppCoordinator())
    .preferredColorScheme(.dark)
}

#if DEBUG
#Preview("Connecting") {
  WalletConnectPairingView(
    coinbaseClient: PreviewWalletConnector(state: .connecting),
    initialProvider: .coinbase,
    onConnected: { _, _ in }
  )
  .padding(.horizontal, DS.Space.pageMargin)
}

#Preview("Awaiting Approval") {
  WalletConnectPairingView(
    coinbaseClient: PreviewWalletConnector(
      state: .awaitingApproval(
        uri: "wc:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
          + "@2?relay-protocol=irn&symKey=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
      )
    ),
    initialProvider: .coinbase,
    onConnected: { _, _ in }
  )
  .padding(.horizontal, DS.Space.pageMargin)
}

#Preview("Connected") {
  WalletConnectPairingView(
    coinbaseClient: PreviewWalletConnector(
      state: .connected(address: "0x1234567890abcdef1234567890abcdef12345678")
    ),
    initialProvider: .coinbase,
    onConnected: { _, _ in }
  )
  .padding(.horizontal, DS.Space.pageMargin)
}

#Preview("Failed") {
  WalletConnectPairingView(
    coinbaseClient: PreviewWalletConnector(
      state: .failed("The wallet rejected the connection request.")
    ),
    initialProvider: .coinbase,
    onConnected: { _, _ in }
  )
  .padding(.horizontal, DS.Space.pageMargin)
}
#endif
