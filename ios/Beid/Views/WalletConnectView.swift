// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Wallet step in the `.walletFirst` `OnboardingMode` order. Direct
/// app-to-app connection via `WalletConnectPairingView` — see
/// ios/README.md "WalletConnect". Every tint here is
/// `DS.Color.actionPrimary`, as on every screen (DESIGN.md §5).
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
  /// View-local only, never persisted: set when the user explicitly taps
  /// "Connect a different wallet" off a `.restored` hint, so this mount of
  /// the view falls through to `providerSelectionContent` instead of
  /// re-showing the hint. Does not touch `WalletHintStore` — dispatch#26
  /// condition 3 requires the cache to survive exactly this kind of light,
  /// non-destructive choice.
  @State private var bypassRestoredHint = false
  let onConnected: (LiveWalletAddress, any WalletConnector) -> Void
  let secondaryAction: (title: LocalizedStringKey, action: () -> Void)?

  init(
    client: Connector = MetaMaskConnector.shared,
    onConnected: @escaping (LiveWalletAddress, any WalletConnector) -> Void,
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
    onConnected: @escaping (LiveWalletAddress, any WalletConnector) -> Void,
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
      } else if !bypassRestoredHint, case .restored = client.state {
        // dispatch#26 condition 1: show the hint immediately, before any
        // tap and before any network/deep-link call — `providerSelectionContent`
        // below is what every other (non-restored) first appearance shows.
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
      if hasStarted, case .connected(let live) = newState {
        onConnected(live, client)
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
    case .restored(let hint):
      restoredContent(hint: hint)
    case .idle:
      connectingContent
        .task { await client.connect() }
    case .connecting:
      connectingContent
    case .awaitingApproval(let uri):
      awaitingApprovalContent(uri: uri)
    case .connected(let live):
      connectedContent(address: live.address)
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
        title: "Wallet not available",
        subtitle: "This wallet can't be used right now. Try again in a moment."
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
        title: "Connect Your Wallet",
        subtitle: "beid uses your wallet to sign proofs of event attendance."
      )

      VStack(spacing: DS.Space.s) {
        BeidPrimaryButton("Connect with MetaMask") {
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

  /// dispatch#26 condition 1/4: shows the previous session's address
  /// immediately as a reference, with an explicit path both to resume it
  /// (a real `connect()` round trip, same as `providerSelectionContent`'s
  /// button — this view has no signature to collapse into that trip, see
  /// `EventBindingSheetView`'s own restored-hint handling for the
  /// connect+sign collapse) and to bypass it for a fresh connection.
  private func restoredContent(hint: CachedWalletHint) -> some View {
    VStack(spacing: DS.Space.l) {
      BeidHeroHeader(
        title: "Continue with your wallet",
        subtitle: LocalizedStringKey(restoredHintSubtitle(hint: hint))
      )
      VStack(spacing: DS.Space.s) {
        BeidPrimaryButton(
          LocalizedStringKey(continueAsButtonTitle(hint: hint))
        ) {
          hasStarted = true
          Task { await client.connect() }
        }
        .tint(DS.Color.actionPrimary)

        BeidSecondaryButton(title: LocalizedStringKey(connectDifferentWalletTitle)) {
          bypassRestoredHint = true
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
        title: "Connect Your Wallet",
        subtitle: nil
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
      title: "Connected",
      subtitle: nil
    )
  }

  private func failedContent(message: String) -> some View {
    VStack(spacing: DS.Space.l) {
      BeidHeroHeader(
        title: "Connection failed",
        subtitle: "beid couldn't connect to your wallet. Check your connection and try again."
      )
      Text(verbatim: message)
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.textSecondary)
        .multilineTextAlignment(.center)
      VStack(spacing: DS.Space.s) {
        BeidSecondaryButton(title: "Try Again") {
          // Light in-app cancel, not forget-wallet (dispatch#26 condition 3)
          // — leaves the SDK session and cached hint alone.
          client.cancelPendingOperation()
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
        title: "MetaMask is not installed",
        subtitle: "Install MetaMask to connect directly."
      )
      VStack(spacing: DS.Space.s) {
        BeidPrimaryButton("Get MetaMask") {
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
    // Light in-app cancel, not forget-wallet (dispatch#26 condition 3) —
    // leaves the SDK session and cached hint alone.
    client.cancelPendingOperation()
    hasStarted = false
  }

  private func deliverConnectedState() {
    guard !hasStarted, case .connected(let live) = client.state else { return }
    hasStarted = true
    onConnected(live, client)
  }

  // MARK: - Localized copy (restored-hint content)

  private func restoredHintSubtitle(hint: CachedWalletHint) -> String {
    String(
      localized: "wallet.restored.subtitle",
      defaultValue: "\(hint.truncatedAddress) was used last time — shown for reference. Approve in your wallet to continue.",
      comment: "Subtitle shown under the restored-wallet heading when a cached wallet address exists from a previous launch. %@ is the truncated wallet address, e.g. '0x1234...5678'. This address is a reference only, not a verified signer, until the user approves again in their wallet (dispatch#26 condition 4)."
    )
  }

  private func continueAsButtonTitle(hint: CachedWalletHint) -> String {
    String(
      localized: "wallet.restored.continueButton",
      defaultValue: "Continue as \(hint.truncatedAddress)",
      comment: "Primary button that resumes a previously connected wallet without picking it again. %@ is the truncated wallet address, e.g. '0x1234...5678'."
    )
  }

  private var connectDifferentWalletTitle: String {
    String(
      localized: "wallet.restored.connectDifferent",
      defaultValue: "Connect a different wallet",
      comment: "Secondary button next to a restored-wallet suggestion, for a user who wants to pick a different wallet instead of continuing with the one shown."
    )
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
    if case .connected(let live) = state { return live.address }
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

  func connectAndSign(
    messageHex: String,
    responseTimeout: TimeInterval,
    onDispatched: (() -> Void)?
  ) async -> Result<(LiveWalletAddress, String), WalletConnectorError> {
    .failure(.notConnected)
  }

  func disconnect() {}

  func cancelPendingOperation() {}

  @discardableResult
  func handle(url: URL) -> Bool { false }
}
#endif

#Preview {
  WalletConnectView().environmentObject(AppCoordinator())
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
      state: .connected(LiveWalletAddress.fromConnectorResult(
        address: "0x1234567890abcdef1234567890abcdef12345678",
        chainId: "eip155:8453"
      ))
    ),
    startedImmediately: true,
    onConnected: { _, _ in }
  )
  .padding(.horizontal, DS.Space.pageMargin)
}

#Preview("Restored") {
  WalletConnectPairingView(
    client: PreviewWalletConnector(
      state: .restored(CachedWalletHint(
        address: "0x1234567890abcdef1234567890abcdef12345678",
        chainId: "eip155:8453"
      ))
    ),
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
