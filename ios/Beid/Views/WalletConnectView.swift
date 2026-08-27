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
/// MetaMask is currently the only wallet this connects to (Coinbase Wallet
/// was removed, thegreeting/beid#270 — the Base app rebrand broke its
/// approval-dialog handshake and the SDK has no native-iOS fix). Generic
/// over the connector type (defaulted to the real singleton below) purely
/// so `#Preview` can inject a fake `WalletConnector` sitting in an
/// arbitrary `state` — see `PreviewWalletConnector` at the bottom of this
/// file.
struct WalletConnectPairingView<Connector: WalletConnector>: View {
  @Environment(\.openURL) private var openURL
  @StateObject private var client: Connector
  @State private var hasStarted = false
  let onConnected: (String, any WalletConnector) -> Void
  let secondaryAction: (title: LocalizedStringKey, action: () -> Void)?

  init(
    client: Connector = MetaMaskConnector.shared,
    onConnected: @escaping (String, any WalletConnector) -> Void,
    secondaryAction: (title: LocalizedStringKey, action: () -> Void)? = nil
  ) {
    _client = StateObject(wrappedValue: client)
    self.onConnected = onConnected
    self.secondaryAction = secondaryAction
  }

  #if DEBUG
  /// Preview-only: lets a `#Preview` start already mid-flow, instead of
  /// every real call site's shared entrypoint at `providerSelectionContent`.
  fileprivate init(
    client: Connector = MetaMaskConnector.shared,
    startedImmediately: Bool,
    onConnected: @escaping (String, any WalletConnector) -> Void,
    secondaryAction: (title: LocalizedStringKey, action: () -> Void)? = nil
  ) {
    _client = StateObject(wrappedValue: client)
    _hasStarted = State(wrappedValue: startedImmediately)
    self.onConnected = onConnected
    self.secondaryAction = secondaryAction
  }
  #endif

  var body: some View {
    VStack(spacing: DS.Space.l) {
      if hasStarted {
        connectorContent
      } else {
        providerSelectionContent
      }
    }
    .task {
      client.configureIfNeeded()
      // A wallet may have approved a connection started from a previous
      // mount of this view (e.g. the user backgrounded the app, or left
      // for the event-code fallback, while `.awaitingApproval`) — deliver
      // that already-settled state now, since `.onChange` below only
      // fires on a *transition* and would otherwise never fire for a
      // state that was already `.connected` when this view appeared.
      deliverConnectedState()
    }
    .onChange(of: client.state) { _, newState in
      if hasStarted, case .connected(let address) = newState {
        onConnected(address, client)
      }
    }
  }

  @ViewBuilder
  private var connectorContent: some View {
    switch client.state {
    case .notConfigured:
      notConfiguredContent
    case .unavailable(.walletNotInstalled):
      walletNotInstalledContent
    case .idle:
      connectingContent
        .task { await client.connect() }
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

  /// `WalletConnectorState.notConfigured` is part of the shared
  /// `WalletConnector` protocol (see WalletConnector.swift), but
  /// `MetaMaskConnector` never produces it — it starts at `.idle` and
  /// needs no external credential. This branch exists only so
  /// `connectorContent`'s switch stays exhaustive against the protocol's
  /// full state space.
  private var notConfiguredContent: some View {
    VStack(spacing: DS.Space.l) {
      BeidHeroHeader(
        systemImage: "exclamationmark.triangle.fill",
        title: "Wallet not available",
        subtitle: "This wallet can't be used right now. Try again in a moment.",
        tint: DS.Color.actionPrimary
      )
      BeidSecondaryButton(title: "Start Over") {
        chooseAnotherWallet()
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
        BeidPrimaryButton("Connect with MetaMask", systemImage: "wallet.pass") {
          hasStarted = true
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

  private func awaitingApprovalContent(uri: String?) -> some View {
    VStack(spacing: DS.Space.m) {
      Text("Approve the connection in MetaMask")
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
        chooseAnotherWallet()
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
          client.disconnect()
          Task { await client.connect() }
        }
        .tint(DS.Color.actionPrimary)

        BeidSecondaryButton(title: "Start Over") {
          chooseAnotherWallet()
        }
        .tint(DS.Color.actionPrimary)

        if let secondaryAction {
          BeidSecondaryButton(title: secondaryAction.title, action: secondaryAction.action)
            .tint(DS.Color.actionPrimary)
        }
      }
    }
  }

  private var walletNotInstalledContent: some View {
    VStack(spacing: DS.Space.l) {
      BeidHeroHeader(
        systemImage: "wallet.pass.fill",
        title: "MetaMask is not installed",
        subtitle: "Install MetaMask to connect directly.",
        tint: DS.Color.actionPrimary
      )
      VStack(spacing: DS.Space.s) {
        BeidPrimaryButton("Get MetaMask", systemImage: "arrow.up.right.square") {
          openURL(MetaMaskConnector.appStoreURL)
        }
        .tint(DS.Color.actionPrimary)

        BeidSecondaryButton(title: "Start Over") {
          chooseAnotherWallet()
        }
        .tint(DS.Color.actionPrimary)

        if let secondaryAction {
          BeidSecondaryButton(title: secondaryAction.title, action: secondaryAction.action)
            .tint(DS.Color.actionPrimary)
        }
      }
    }
  }

  private func chooseAnotherWallet() {
    client.disconnect()
    hasStarted = false
  }

  private func deliverConnectedState() {
    guard !hasStarted, case .connected(let address) = client.state else { return }
    hasStarted = true
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
    client: PreviewWalletConnector(state: .connecting),
    startedImmediately: true,
    onConnected: { _, _ in }
  )
  .padding(.horizontal, DS.Space.pageMargin)
}

#Preview("Awaiting Approval") {
  WalletConnectPairingView(
    client: PreviewWalletConnector(
      state: .awaitingApproval(
        uri: "wc:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
          + "@2?relay-protocol=irn&symKey=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
      )
    ),
    startedImmediately: true,
    onConnected: { _, _ in }
  )
  .padding(.horizontal, DS.Space.pageMargin)
}

#Preview("Connected") {
  WalletConnectPairingView(
    client: PreviewWalletConnector(
      state: .connected(address: "0x1234567890abcdef1234567890abcdef12345678")
    ),
    startedImmediately: true,
    onConnected: { _, _ in }
  )
  .padding(.horizontal, DS.Space.pageMargin)
}

#Preview("Failed") {
  WalletConnectPairingView(
    client: PreviewWalletConnector(
      state: .failed("The wallet rejected the connection request.")
    ),
    startedImmediately: true,
    onConnected: { _, _ in }
  )
  .padding(.horizontal, DS.Space.pageMargin)
}
#endif
