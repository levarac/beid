// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import CoinbaseWalletSDK
import Combine
import Foundation

struct CoinbaseWalletAccount: Equatable {
  let address: String
  let chainId: String
}

enum CoinbaseWalletTransportError: Error, Equatable {
  case rejected
  case failed(String)
}

@MainActor
protocol CoinbaseWalletTransport: AnyObject {
  var isWalletInstalled: Bool { get }
  func initiateHandshake(
    completion: @MainActor @escaping (Result<CoinbaseWalletAccount, CoinbaseWalletTransportError>) -> Void
  )
  func requestPersonalSign(
    address: String,
    messageHex: String,
    completion: @escaping (Result<String, CoinbaseWalletTransportError>) -> Void
  )
  func disconnect()
  func handle(url: URL) -> Bool
}

@MainActor
final class CoinbaseWalletConnector: ObservableObject, WalletConnector {
  static let shared = CoinbaseWalletConnector(transport: CoinbaseWalletSDKTransport())
  static let appStoreURL = URL(string: "https://apps.apple.com/app/id1278383455")!

  @Published private(set) var state: WalletConnectorState = .idle

  var address: String? {
    account?.address
  }

  var chainId: String {
    account?.chainId ?? "eip155:1"
  }

  private let transport: CoinbaseWalletTransport
  private var account: CoinbaseWalletAccount?
  private var connectionAttemptID: UUID?

  init(transport: CoinbaseWalletTransport) {
    self.transport = transport
  }

  func configureIfNeeded() {}

  func connect() async {
    guard transport.isWalletInstalled else {
      state = .unavailable(.walletNotInstalled)
      return
    }

    state = .connecting
    state = .awaitingApproval(uri: nil)
    let attemptID = UUID()
    connectionAttemptID = attemptID
    transport.initiateHandshake { [weak self] result in
      guard let self, self.connectionAttemptID == attemptID else { return }
      self.connectionAttemptID = nil
      switch result {
      case .success(let account):
        self.account = account
        self.state = .connected(address: account.address)
      case .failure(.rejected):
        self.state = .failed("Connection declined")
      case .failure(.failed(let message)):
        self.state = .failed(message)
      }
    }
  }

  func requestPersonalSign(
    messageHex: String,
    responseTimeout: TimeInterval = 90,
    onDispatched: (() -> Void)? = nil
  ) async -> Result<String, WalletConnectorError> {
    guard let account else {
      return .failure(.notConnected)
    }
    guard transport.isWalletInstalled else {
      return .failure(.relayFailure("Coinbase Wallet is not installed"))
    }

    return await withCheckedContinuation { continuation in
      let gate = CoinbaseSignResultGate(continuation: continuation)
      transport.requestPersonalSign(address: account.address, messageHex: messageHex) { result in
        Task { @MainActor in
          switch result {
          case .success(let signature):
            gate.finish(.success(signature))
          case .failure(.rejected):
            gate.finish(.failure(.rejected))
          case .failure(.failed(let message)):
            gate.finish(.failure(.relayFailure(message)))
          }
        }
      }
      // Contract divergence from ReownWalletConnectClient: the Coinbase SDK
      // exposes no dispatch-success signal (makeRequest only calls back with a
      // response or failure), so onDispatched fires as soon as the request is
      // handed to the SDK. An immediate dispatch failure briefly persists
      // .awaitingApproval before the failure result overwrites it; the
      // installed-wallet guard above removes the dominant failure mode.
      onDispatched?()
      gate.timeoutTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(responseTimeout * 1_000_000_000))
        guard !Task.isCancelled else { return }
        gate.finish(.failure(.timedOut))
      }
    }
  }

  func disconnect() {
    connectionAttemptID = nil
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
private final class CoinbaseSignResultGate {
  private var continuation: CheckedContinuation<Result<String, WalletConnectorError>, Never>?
  var timeoutTask: Task<Void, Never>?

  init(continuation: CheckedContinuation<Result<String, WalletConnectorError>, Never>) {
    self.continuation = continuation
  }

  func finish(_ result: Result<String, WalletConnectorError>) {
    timeoutTask?.cancel()
    timeoutTask = nil
    continuation?.resume(returning: result)
    continuation = nil
  }
}

@MainActor
private final class CoinbaseWalletSDKTransport: CoinbaseWalletTransport {
  private let sdk: CoinbaseWalletSDK

  var isWalletInstalled: Bool {
    CoinbaseWalletSDK.isCoinbaseWalletInstalled()
  }

  init() {
    if !CoinbaseWalletSDK.isConfigured {
      CoinbaseWalletSDK.configure(callback: URL(string: "beid://coinbase-wallet")!)
    }
    sdk = CoinbaseWalletSDK.shared
  }

  func initiateHandshake(
    completion: @MainActor @escaping (Result<CoinbaseWalletAccount, CoinbaseWalletTransportError>) -> Void
  ) {
    sdk.initiateHandshake(initialActions: [Action(jsonRpc: .eth_requestAccounts)]) { result, account in
      Task { @MainActor in
        switch result {
        case .success:
          guard let account else {
            completion(.failure(.failed("Coinbase Wallet returned no account")))
            return
          }
          completion(.success(CoinbaseWalletAccount(
            address: account.address,
            chainId: "eip155:\(account.networkId)"
          )))
        case .failure(let error):
          completion(.failure(.failed(String(describing: error))))
        }
      }
    }
  }

  func requestPersonalSign(
    address: String,
    messageHex: String,
    completion: @escaping (Result<String, CoinbaseWalletTransportError>) -> Void
  ) {
    sdk.makeRequest(Request(actions: [
      Action(jsonRpc: .personal_sign(address: address, message: messageHex)),
    ])) { result in
      Task { @MainActor in
        switch result {
        case .success(let response):
          guard let actionResult = response.content.first else {
            completion(.failure(.failed("Coinbase Wallet returned no signature")))
            return
          }
          switch actionResult {
          case .success(let value):
            guard let signature = value.decode() as? String else {
              completion(.failure(.failed("Malformed signature response")))
              return
            }
            completion(.success(signature))
          case .failure(let error):
            completion(error.code == 4001 ? .failure(.rejected) : .failure(.failed(error.message)))
          }
        case .failure(let error):
          completion(.failure(.failed(String(describing: error))))
        }
      }
    }
  }

  func disconnect() {
    _ = sdk.resetSession()
  }

  func handle(url: URL) -> Bool {
    (try? sdk.handleResponse(url)) == true
  }
}
