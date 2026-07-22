// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Combine
import Foundation
import WalletConnectSign

/// Real WalletConnect (Reown) pairing flow, backing `WalletConnectView` and
/// the Account sheet's "Connect Wallet" action. Uses reown-swift 2.3.0's
/// low-level `Sign`/`Pair`/`Networking` APIs directly (not `ReownAppKit`) —
/// see ios/README.md "WalletConnect". Validated on Simulator by
/// spike/walletconnect-native (commit a22d0f4): the real relay connection
/// attempt runs and fails cleanly without a project ID, with no crash.
@MainActor
final class ReownWalletConnectClient: ObservableObject, WalletConnector {
  typealias State = WalletConnectorState
  typealias SignatureRequestError = WalletConnectorError

  static let shared = ReownWalletConnectClient()

  @Published private(set) var state: State = .notConfigured

  var address: String? {
    guard case .connected(let address) = state else { return nil }
    return address
  }

  var chainId: String {
    connectedSession?.namespaces["eip155"]?.accounts.first?.blockchainIdentifier ?? "eip155:1"
  }

  /// The settled session backing the current `.connected` state — kept
  /// alongside `state` (rather than folded into its associated value) so
  /// signing (`requestPersonalSign`) can reuse the exact session/topic this
  /// pairing flow established instead of opening a second one.
  private(set) var connectedSession: Session?

  private var isConfigured = false
  private var subscriptions = Set<AnyCancellable>()

  /// Set when the user explicitly cancels an `.awaitingApproval` pairing.
  /// reown-swift 2.3.0 has no working "cancel my pending proposal" API —
  /// `Pair.instance.disconnect(topic:)` is a documented no-op ("pairing
  /// will disconnect automatically" via the URI's 5-minute expiry) — so a
  /// wallet can still approve a cancelled pairing after the user has left
  /// the screen. When that happens, `observeSessions()` immediately
  /// disconnects the just-settled *session* (a real, working call, unlike
  /// the pairing disconnect) instead of surfacing it as `.connected`.
  private var cancelledPendingApproval = false

  private init() {}

  /// Configures the SDK singletons on first use. Safe to call repeatedly.
  /// Leaves `state` as `.notConfigured` (rather than crashing) when no
  /// project ID is present — the graceful-degradation path required
  /// because Secrets.plist doesn't exist on a fresh checkout or in CI.
  func configureIfNeeded() {
    guard !isConfigured else { return }
    guard let projectId = WalletConnectSecrets.projectId else {
      state = .notConfigured
      return
    }

    let metadata = AppMetadata(
      name: "beid",
      description: "beid uses your wallet to sign proofs of event attendance.",
      url: "https://levarac.org",
      icons: [],
      redirect: try! AppMetadata.Redirect(native: "beid://", universal: nil)
    )

    Networking.configure(
      groupIdentifier: "group.org.levarac.beid",
      projectId: projectId,
      socketFactory: NativeWebSocketFactory()
    )
    Pair.configure(metadata: metadata)
    Sign.configure(crypto: NativeCryptoProvider())

    isConfigured = true
    state = .idle
    observeSessions()
  }

  /// Generates a pairing URI and moves to `.awaitingApproval`. A real
  /// wallet must scan/open the URI and approve the session proposal over
  /// the relay before `.connected` is reached.
  func connect() async {
    guard isConfigured else { return }
    cancelledPendingApproval = false
    state = .connecting
    do {
      let namespaces: [String: ProposalNamespace] = [
        "eip155": ProposalNamespace(
          chains: [Blockchain("eip155:1")!],
          methods: ["personal_sign", "eth_sendTransaction"],
          events: []
        ),
      ]
      let uri = try await Sign.instance.connect(namespaces: namespaces)
      state = .awaitingApproval(uri: uri.absoluteString)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  /// Returns to `.idle` from `.awaitingApproval`/`.failed` (Cancel/Try
  /// Again). No-op when not configured or already idle. When cancelling an
  /// in-flight `.awaitingApproval` pairing, marks it so a late-arriving
  /// wallet approval gets auto-disconnected instead of surfacing as
  /// `.connected` — see `cancelledPendingApproval`.
  func reset() {
    guard isConfigured else { return }
    if case .awaitingApproval = state {
      cancelledPendingApproval = true
    }
    connectedSession = nil
    state = .idle
  }

  /// Dispatches a redirect URL (wallet → app, via `beid://`) into the SDK.
  @discardableResult
  func handle(url: URL) -> Bool {
    guard isConfigured else { return false }
    do {
      try Sign.instance.dispatchEnvelope(url.absoluteString)
      return true
    } catch {
      return false
    }
  }

  func disconnect() {
    reset()
  }

  private func observeSessions() {
    Sign.instance.sessionSettlePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] session, _ in
        guard let self else { return }
        if cancelledPendingApproval {
          cancelledPendingApproval = false
          Task { try? await Sign.instance.disconnect(topic: session.topic) }
          return
        }
        if let account = session.namespaces.values.first?.accounts.first {
          self.connectedSession = session
          self.state = .connected(address: account.address)
        }
      }
      .store(in: &subscriptions)
  }
}

// MARK: - Signing

extension ReownWalletConnectClient {
  /// Sends a `personal_sign` request for `digestHex` over the currently
  /// connected session (reusing its topic/account — never opens a second
  /// pairing flow) and awaits the wallet's response, bounded by
  /// `responseTimeout`. Returns the hex signature on success. `onDispatched`
  /// fires once the request has been handed to the relay (before the
  /// wallet's response is known) so callers can move from a "connecting"
  /// to an "awaiting approval" UI state at the right moment.
  func requestPersonalSign(
    digestHex: String,
    responseTimeout: TimeInterval = 90,
    onDispatched: (() -> Void)? = nil
  ) async -> Result<String, WalletConnectorError> {
    guard case .connected(let address) = state,
          let session = connectedSession,
          let chain = session.namespaces["eip155"]?.accounts.first?.blockchain
    else {
      return .failure(.notConnected)
    }

    let request: Request
    do {
      request = try Request(
        topic: session.topic,
        method: "personal_sign",
        params: AnyCodable([digestHex, address]),
        chainId: chain
      )
    } catch {
      return .failure(.relayFailure(error.localizedDescription))
    }

    do {
      try await Sign.instance.request(params: request)
    } catch {
      return .failure(.relayFailure(error.localizedDescription))
    }

    onDispatched?()
    return await awaitResponse(to: request.id, timeout: responseTimeout)
  }

  private enum RaceOutcome {
    case response(Response)
    case timedOut
  }

  private func awaitResponse(to requestId: RPCID, timeout: TimeInterval) async -> Result<String, WalletConnectorError> {
    let outcome = await withTaskGroup(of: RaceOutcome.self) { group in
      group.addTask {
        for await response in Sign.instance.sessionResponsePublisher.values {
          if response.id == requestId {
            return .response(response)
          }
        }
        return .timedOut
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return .timedOut
      }
      let first = await group.next() ?? .timedOut
      group.cancelAll()
      return first
    }

    switch outcome {
    case .timedOut:
      return .failure(.timedOut)
    case .response(let response):
      switch response.result {
      case .response(let value):
        guard let signature = try? value.get(String.self) else {
          return .failure(.relayFailure("Malformed signature response"))
        }
        return .success(signature)
      case .error(let error):
        // EIP-1193 userRejectedRequest.
        return error.code == 4001 ? .failure(.rejected) : .failure(.relayFailure(error.message))
      }
    }
  }
}
