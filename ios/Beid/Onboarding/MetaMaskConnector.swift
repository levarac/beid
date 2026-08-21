// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

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

  @Published private(set) var state: WalletConnectorState = .idle

  var address: String? {
    account?.address
  }

  var chainId: String {
    account?.chainId ?? "eip155:1"
  }

  private let transport: MetaMaskTransport
  private var account: MetaMaskWalletAccount?
  private var connectionAttemptID: UUID?
  private var sessionID: UUID?
  private var signAttemptID: UUID?
  private var signGate: MetaMaskSignResultGate?

  init(transport: MetaMaskTransport) {
    self.transport = transport
  }

  func configureIfNeeded() {}

  func connect() async {
    guard transport.isWalletInstalled else {
      account = nil
      sessionID = nil
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
      sessionID = UUID()
      state = .connected(address: account.address)
    case .failure(.rejected):
      account = nil
      sessionID = nil
      state = .failed("Connection declined")
    case .failure(.failed(let message)):
      account = nil
      sessionID = nil
      state = .failed(message)
    }
  }

  func requestPersonalSign(
    messageHex: String,
    responseTimeout: TimeInterval = 90,
    onDispatched: (() -> Void)? = nil
  ) async -> Result<String, WalletConnectorError> {
    guard let account, let sessionID else {
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
        guard self.sessionID == sessionID, self.signAttemptID == attemptID else {
          gate.finish(.failure(.notConnected))
          return
        }

        onDispatched?()
        let result = await self.transport.requestPersonalSign(
          address: account.address,
          messageHex: messageHex
        )
        guard self.sessionID == sessionID, self.signAttemptID == attemptID else {
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
    connectionAttemptID = nil
    sessionID = nil
    signAttemptID = nil
    signGate?.finish(.failure(.notConnected))
    signGate = nil
    transport.disconnect()
    account = nil
    state = .idle
  }

  @discardableResult
  func handle(url: URL) -> Bool {
    transport.handle(url: url)
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
