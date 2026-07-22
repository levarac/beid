// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

enum WalletConnectorUnavailableReason: Equatable {
  case walletNotInstalled
}

enum WalletConnectorState: Equatable {
  case notConfigured
  case unavailable(WalletConnectorUnavailableReason)
  case idle
  case connecting
  case awaitingApproval(uri: String?)
  case connected(address: String)
  case failed(String)
}

enum WalletConnectorError: Error, Equatable {
  case notConnected
  case rejected
  case timedOut
  case relayFailure(String)
}

/// Common wallet surface used by onboarding and AttendanceProof/v1 signing.
/// Implementations own their SDK-specific session while callers only depend
/// on connection state, address, chain, personal_sign, and disconnect.
@MainActor
protocol WalletConnector: ObservableObject {
  var state: WalletConnectorState { get }
  var address: String? { get }
  var chainId: String { get }

  func configureIfNeeded()
  func connect() async
  func requestPersonalSign(
    digestHex: String,
    responseTimeout: TimeInterval,
    onDispatched: (() -> Void)?
  ) async -> Result<String, WalletConnectorError>
  func disconnect()
  @discardableResult func handle(url: URL) -> Bool
}

extension WalletConnector {
  func requestPersonalSign(
    digestHex: String,
    onDispatched: (() -> Void)? = nil
  ) async -> Result<String, WalletConnectorError> {
    await requestPersonalSign(
      digestHex: digestHex,
      responseTimeout: 90,
      onDispatched: onDispatched
    )
  }
}
