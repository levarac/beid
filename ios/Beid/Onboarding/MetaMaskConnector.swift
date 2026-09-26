// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidMetaMaskSupport
import Combine
import Foundation

struct MetaMaskWalletAccount: Equatable {
  let address: String
  let chainId: String
}

enum MetaMaskTransportError: Error, Equatable {
  case rejected
  case failed(String)
}

@MainActor
protocol MetaMaskTransport: AnyObject {
  var isWalletInstalled: Bool { get }
  func connect() async -> Result<MetaMaskWalletAccount, MetaMaskTransportError>
  /// Connect and sign in one SDK round trip (`Ethereum.connectAndSign`,
  /// pinned metamask-ios-sdk 0.8.10) — the account/chain the wallet actually
  /// connected with is read back from `sdk.account`/`sdk.chainId` after the
  /// signature settles, since `connectAndSign` itself only returns the
  /// signature.
  func connectAndSign(
    messageHex: String
  ) async -> Result<(MetaMaskWalletAccount, String), MetaMaskTransportError>
  func requestPersonalSign(
    address: String,
    messageHex: String
  ) async -> Result<String, MetaMaskTransportError>
  func disconnect()
  func handle(url: URL) -> Bool
}

/// Direct MetaMask connector, shipped in Release as well as Debug
/// (DECISIONS 2026-08-21). Session truth lives here rather than in
/// metamask-ios-sdk's `connected` property, which remains true after
/// `disconnect()` in 0.8.10.
@MainActor
final class MetaMaskConnector: ObservableObject, WalletConnector {
  static let shared = MetaMaskConnector(transport: MetaMaskSDKTransport())
  static let appStoreURL = URL(string: "https://apps.apple.com/app/id1438144202")!

  /// Starts at `.restored(hint)` instead of `.idle` when a cached hint
  /// exists (beid#315 / dispatch#26 condition 1) — read once here, at
  /// construction, never re-derived from a live connect. `hintStore` is
  /// this instance's single owner of hint persistence: every successful
  /// `connect()`/`connectAndSign()` below refreshes it, and no other type
  /// writes to it in production (see `AppCoordinator.disconnectWallet()`
  /// for the one place that clears it).
  @Published private(set) var state: WalletConnectorState

  var address: String? {
    account?.address
  }

  var chainId: String {
    account?.chainId ?? "eip155:1"
  }

  private let transport: MetaMaskTransport
  private let hintStore: WalletHintStore
  private var account: MetaMaskWalletAccount?
  private var connectionAttemptID: UUID?
  private var connectionGenerationID: UUID?
  private var connectAndSignGate: MetaMaskConnectAndSignResultGate?
  private var signAttemptID: UUID?
  private var signGate: MetaMaskSignResultGate?

  init(transport: MetaMaskTransport, hintStore: WalletHintStore = WalletHintStore()) {
    self.transport = transport
    self.hintStore = hintStore
    if let hint = hintStore.load() {
      state = .restored(hint)
    } else {
      state = .idle
    }
  }

  func configureIfNeeded() {}

  func connect() async {
    invalidatePendingConnectionAttempt(with: .cancelled)
    guard transport.isWalletInstalled else {
      account = nil
      connectionGenerationID = nil
      state = .unavailable(.walletNotInstalled)
      return
    }

    let attemptID = UUID()
    connectionAttemptID = attemptID
    state = .connecting
    state = .awaitingApproval(uri: nil)

    let result = await transport.connect()
    guard connectionAttemptID == attemptID else { return }
    connectionAttemptID = nil

    switch result {
    case .success(let account):
      self.account = account
      connectionGenerationID = UUID()
      let live = LiveWalletAddress.fromConnectorResult(address: account.address, chainId: account.chainId)
      state = .connected(live)
      hintStore.save(CachedWalletHint(address: live.address, chainId: live.chainId))
    case .failure(.rejected):
      account = nil
      connectionGenerationID = nil
      state = .failed("Connection declined")
    case .failure(.failed(let message)):
      account = nil
      connectionGenerationID = nil
      state = .failed(message)
    }
  }

  /// Single-round-trip connect+sign (dispatch#26 condition 2) — see
  /// `WalletConnector.connectAndSign`'s doc comment. The address in the
  /// returned `LiveWalletAddress` is read back from the transport's account
  /// after the signature settles, not from whatever hint the caller used to
  /// build `messageHex`; a caller building a binding message from a
  /// `.restored` hint before this call must still treat the returned
  /// address, not the hint, as the true connected address for anything
  /// past this point (dispatch#26 condition 4).
  func connectAndSign(
    messageHex: String,
    responseTimeout: TimeInterval = 90,
    onDispatched: (() -> Void)? = nil
  ) async -> Result<(LiveWalletAddress, String), WalletConnectorError> {
    invalidatePendingConnectionAttempt(with: .cancelled)
    guard transport.isWalletInstalled else {
      account = nil
      connectionGenerationID = nil
      state = .unavailable(.walletNotInstalled)
      return .failure(.relayFailure("MetaMask is not installed"))
    }

    let attemptID = UUID()
    connectionAttemptID = attemptID
    state = .connecting
    state = .awaitingApproval(uri: nil)

    let result = await withCheckedContinuation { continuation in
      let gate = MetaMaskConnectAndSignResultGate(continuation: continuation)
      connectAndSignGate = gate

      gate.requestTask = Task { @MainActor [weak self, weak gate] in
        guard let self, let gate else { return }
        guard self.connectionAttemptID == attemptID else {
          gate.finish(.failure(.notConnected))
          return
        }

        onDispatched?()
        let result = await self.transport.connectAndSign(messageHex: messageHex)
        // Non-destructive invalidation (`cancelPendingOperation()` or a
        // newer attempt) resolves this one-shot gate as `.cancelled`.
        // Explicit disconnect resolves it as `.notConnected`.
        guard self.connectionAttemptID == attemptID else {
          gate.finish(.failure(.notConnected))
          return
        }

        switch result {
        case .success(let (account, signature)):
          self.account = account
          self.connectionGenerationID = UUID()
          let live = LiveWalletAddress.fromConnectorResult(address: account.address, chainId: account.chainId)
          self.state = .connected(live)
          self.hintStore.save(CachedWalletHint(address: live.address, chainId: live.chainId))
          gate.finish(.success((live, signature)))
        case .failure(.rejected):
          self.account = nil
          self.connectionGenerationID = nil
          self.state = .failed("Connection declined")
          gate.finish(.failure(.rejected))
        case .failure(.failed(let message)):
          self.account = nil
          self.connectionGenerationID = nil
          self.state = .failed(message)
          gate.finish(.failure(.relayFailure(message)))
        }
      }
    }

    if connectionAttemptID == attemptID {
      connectionAttemptID = nil
      connectAndSignGate = nil
    }
    return result
  }

  func requestPersonalSign(
    messageHex: String,
    responseTimeout: TimeInterval = 90,
    onDispatched: (() -> Void)? = nil
  ) async -> Result<String, WalletConnectorError> {
    guard let account, let connectionGenerationID else {
      return .failure(.notConnected)
    }
    guard transport.isWalletInstalled else {
      return .failure(.relayFailure("MetaMask is not installed"))
    }

    let attemptID = UUID()
    signAttemptID = attemptID

    let result = await withCheckedContinuation { continuation in
      let gate = MetaMaskSignResultGate(continuation: continuation)
      signGate = gate

      gate.requestTask = Task { @MainActor [weak self, weak gate] in
        guard let self, let gate else { return }
        guard self.connectionGenerationID == connectionGenerationID, self.signAttemptID == attemptID else {
          gate.finish(.failure(.notConnected))
          return
        }

        onDispatched?()
        let result = await self.transport.requestPersonalSign(
          address: account.address,
          messageHex: messageHex
        )
        guard self.connectionGenerationID == connectionGenerationID, self.signAttemptID == attemptID else {
          gate.finish(.failure(.notConnected))
          return
        }

        switch result {
        case .success(let signature):
          gate.finish(.success(signature))
        case .failure(.rejected):
          gate.finish(.failure(.rejected))
        case .failure(.failed(let message)):
          gate.finish(.failure(.relayFailure(message)))
        }
      }

      gate.timeoutTask = Task { @MainActor [weak gate] in
        try? await Task.sleep(nanoseconds: UInt64(responseTimeout * 1_000_000_000))
        guard !Task.isCancelled else { return }
        gate?.finish(.failure(.timedOut))
      }
    }

    if signAttemptID == attemptID {
      signAttemptID = nil
      signGate = nil
    }
    return result
  }

  func disconnect() {
    invalidatePendingConnectionAttempt(with: .notConnected)
    connectionGenerationID = nil
    signAttemptID = nil
    signGate?.finish(.failure(.notConnected))
    signGate = nil
    transport.disconnect()
    account = nil
    state = .idle
  }

  func cancelPendingOperation() {
    invalidatePendingConnectionAttempt(with: .cancelled)
    connectionGenerationID = nil
    signAttemptID = nil
    signGate?.finish(.failure(.cancelled))
    signGate = nil
    account = nil
    state = .idle
  }

  @discardableResult
  func handle(url: URL) -> Bool {
    transport.handle(url: url)
  }

  private func invalidatePendingConnectionAttempt(with error: WalletConnectorError) {
    connectionAttemptID = nil
    connectAndSignGate?.finish(.failure(error))
    connectAndSignGate = nil
  }
}

@MainActor
private final class MetaMaskConnectAndSignResultGate {
  private var continuation:
    CheckedContinuation<Result<(LiveWalletAddress, String), WalletConnectorError>, Never>?
  var requestTask: Task<Void, Never>?

  init(
    continuation: CheckedContinuation<Result<(LiveWalletAddress, String), WalletConnectorError>, Never>
  ) {
    self.continuation = continuation
  }

  func finish(_ result: Result<(LiveWalletAddress, String), WalletConnectorError>) {
    requestTask?.cancel()
    requestTask = nil
    continuation?.resume(returning: result)
    continuation = nil
  }
}

@MainActor
private final class MetaMaskSignResultGate {
  private var continuation: CheckedContinuation<Result<String, WalletConnectorError>, Never>?
  var requestTask: Task<Void, Never>?
  var timeoutTask: Task<Void, Never>?

  init(continuation: CheckedContinuation<Result<String, WalletConnectorError>, Never>) {
    self.continuation = continuation
  }

  func finish(_ result: Result<String, WalletConnectorError>) {
    requestTask?.cancel()
    timeoutTask?.cancel()
    requestTask = nil
    timeoutTask = nil
    continuation?.resume(returning: result)
    continuation = nil
  }
}

@MainActor
private final class MetaMaskSDKTransport: MetaMaskTransport {
  private let sdk: MetaMaskSDK

  var isWalletInstalled: Bool {
    sdk.isMetaMaskInstalled
  }

  init() {
    sdk = MetaMaskSDK.shared(
      AppMetadata(
        name: "beid",
        url: "https://levarac.org"
      ),
      transport: .deeplinking(dappScheme: "beid"),
      enableDebug: false,
      sdkOptions: nil
    )
  }

  func connect() async -> Result<MetaMaskWalletAccount, MetaMaskTransportError> {
    switch await sdk.connect() {
    case .success(let accounts):
      guard let address = accounts.first, !address.isEmpty else {
        return .failure(.failed("MetaMask returned no account"))
      }
      return .success(MetaMaskWalletAccount(
        address: address,
        chainId: Self.caip2ChainId(sdk.chainId)
      ))
    case .failure(let error):
      return error.code == 4001
        ? .failure(.rejected)
        : .failure(.failed(error.localizedDescription))
    }
  }

  func connectAndSign(
    messageHex: String
  ) async -> Result<(MetaMaskWalletAccount, String), MetaMaskTransportError> {
    switch await sdk.connectAndSign(message: messageHex) {
    case .success(let signature):
      let address = sdk.account
      guard !address.isEmpty else {
        return .failure(.failed("MetaMask returned no account"))
      }
      let account = MetaMaskWalletAccount(
        address: address,
        chainId: Self.caip2ChainId(sdk.chainId)
      )
      return .success((account, signature))
    case .failure(let error):
      return error.code == 4001
        ? .failure(.rejected)
        : .failure(.failed(error.localizedDescription))
    }
  }

  func requestPersonalSign(
    address: String,
    messageHex: String
  ) async -> Result<String, MetaMaskTransportError> {
    switch await sdk.personalSign(message: messageHex, address: address) {
    case .success(let signature):
      return .success(signature)
    case .failure(let error):
      return error.code == 4001
        ? .failure(.rejected)
        : .failure(.failed(error.localizedDescription))
    }
  }

  func disconnect() {
    sdk.disconnect()
    sdk.clearSession()
  }

  func handle(url: URL) -> Bool {
    guard url.scheme == "beid", url.host == "mmsdk" else { return false }
    sdk.handleUrl(url)
    return true
  }

  private static func caip2ChainId(_ rawChainId: String) -> String {
    if rawChainId.hasPrefix("eip155:") {
      return rawChainId
    }
    if rawChainId.lowercased().hasPrefix("0x"),
       let decimal = UInt64(rawChainId.dropFirst(2), radix: 16) {
      return "eip155:\(decimal)"
    }
    if let decimal = UInt64(rawChainId) {
      return "eip155:\(decimal)"
    }
    return "eip155:1"
  }
}
