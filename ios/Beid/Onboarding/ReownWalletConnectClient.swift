// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Combine
import Foundation
import WalletConnectSign

/// Real WalletConnect (Reown) pairing flow — spike implementation reachable
/// from `WalletConnectView` when `WalletConnectMode.current == .reown`.
/// Does not replace `WalletConnectStub`; the two live side by side behind
/// the mode flag — see ios/README.md "WalletConnect (spike)".
@MainActor
final class ReownWalletConnectClient: ObservableObject {
  enum State: Equatable {
    case notConfigured
    case idle
    case awaitingApproval(uri: String)
    case connected(address: String)
    case failed(String)
  }

  static let shared = ReownWalletConnectClient()

  @Published private(set) var state: State = .notConfigured

  private var isConfigured = false
  private var subscriptions = Set<AnyCancellable>()

  private init() {}

  /// Configures the SDK singletons on first use. Safe to call repeatedly.
  /// Leaves `state` as `.notConfigured` (rather than crashing) when no
  /// project ID is present.
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
    state = .idle
    do {
      let namespaces: [String: ProposalNamespace] = [
        "eip155": ProposalNamespace(
          chains: [Blockchain("eip155:1")!],
          methods: ["personal_sign", "eth_sendTransaction"],
          events: []
        )
      ]
      let uri = try await Sign.instance.connect(namespaces: namespaces)
      state = .awaitingApproval(uri: uri.absoluteString)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func reset() {
    guard isConfigured else { return }
    state = .idle
  }

  /// Dispatches a redirect URL (wallet → app, via `beid://`) into the SDK.
  /// Not exercised by this spike's simulator testing (no wallet app to
  /// redirect from), but wired for real-device use.
  func handle(url: URL) {
    guard isConfigured else { return }
    try? Sign.instance.dispatchEnvelope(url.absoluteString)
  }

  private func observeSessions() {
    Sign.instance.sessionSettlePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] session, _ in
        guard let self else { return }
        if let account = session.namespaces.values.first?.accounts.first {
          self.state = .connected(address: account.address)
        }
      }
      .store(in: &subscriptions)
  }
}
