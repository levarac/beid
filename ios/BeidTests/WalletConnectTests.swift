// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Combine
import XCTest
@testable import Beid

/// Covers the graceful-degradation path (no Secrets.plist/project ID) and
/// the coordinator wiring around the real WalletConnect (Reown) flow. Does
/// not exercise `ReownWalletConnectClient.connect()` itself — that requires
/// a live relay connection and a real Reown Cloud project ID, neither of
/// which are available in CI; see ios/README.md "WalletConnect".
@MainActor
final class WalletConnectTests: XCTestCase {
  func testReownClientConformsToWalletConnector() {
    assertWalletConnector(ReownWalletConnectClient.shared)
  }

  func testProjectIdIsNilWithoutSecretsPlist() throws {
    // On a fresh checkout (and in CI) `Beid/Secrets.plist` doesn't exist —
    // it's gitignored. This documents that WalletConnectSecrets degrades to
    // nil rather than crashing, which is what lets the pairing UI reach
    // `.notConfigured` instead of the app failing to build or launch. Skips
    // on a dev machine that has installed its own Secrets.plist per the
    // README's setup instructions — this assertion is only meaningful when
    // no project ID is present.
    try XCTSkipIf(WalletConnectSecrets.projectId != nil, "Secrets.plist with a project ID is installed on this machine")
    XCTAssertNil(WalletConnectSecrets.projectId)
  }

  func testClientReachesNotConfiguredWithoutProjectId() throws {
    try XCTSkipIf(WalletConnectSecrets.projectId != nil, "Secrets.plist with a project ID is installed on this machine")
    let client = ReownWalletConnectClient.shared
    client.configureIfNeeded()
    XCTAssertEqual(client.state, .notConfigured)
  }

  func testCompleteWalletConnectSetsAddressAndAdvancesScreen() {
    let coordinator = AppCoordinator()
    coordinator.completeWalletConnect(address: "0xREALADDRESS")
    XCTAssertEqual(coordinator.walletAddress, "0xREALADDRESS")
    XCTAssertEqual(coordinator.screen, .bluetoothPermission)
  }

  func testConnectWalletFromAccountSheetPresentsSheetWithoutChangingScreen() {
    let coordinator = AppCoordinator()
    coordinator.screen = .home
    coordinator.connectWalletFromAccountSheet()
    XCTAssertTrue(coordinator.walletConnectSheetPresented)
    XCTAssertEqual(coordinator.screen, .home)
    XCTAssertNil(coordinator.walletAddress)
  }

  func testDisconnectWalletClearsAddressAndResetsClient() throws {
    try XCTSkipIf(WalletConnectSecrets.projectId != nil, "Secrets.plist with a project ID is installed on this machine")
    let coordinator = AppCoordinator()
    coordinator.walletAddress = "0xREALADDRESS"

    coordinator.disconnectWallet()

    XCTAssertNil(coordinator.walletAddress)
    // Without a project ID the shared client never leaves .notConfigured,
    // so reset() is a documented no-op here — this asserts it doesn't
    // crash or otherwise misbehave when called on an unconfigured client.
    XCTAssertEqual(ReownWalletConnectClient.shared.state, .notConfigured)
  }

  func testCoinbaseConnectDoesNotStartHandshakeWhenWalletIsMissing() async {
    let transport = FakeCoinbaseWalletTransport(isWalletInstalled: false)
    let connector = CoinbaseWalletConnector(transport: transport)

    await connector.connect()

    XCTAssertEqual(connector.state, .unavailable(.walletNotInstalled))
    XCTAssertEqual(transport.handshakeCount, 0)
  }

  func testCoinbaseConnectPublishesConnectedAddressAndChain() async {
    let transport = FakeCoinbaseWalletTransport(isWalletInstalled: true)
    transport.handshakeResult = .success(
      CoinbaseWalletAccount(address: "0xCOINBASE", chainId: "eip155:8453")
    )
    let connector = CoinbaseWalletConnector(transport: transport)

    await connector.connect()

    XCTAssertEqual(connector.state, .connected(address: "0xCOINBASE"))
    XCTAssertEqual(connector.address, "0xCOINBASE")
    XCTAssertEqual(connector.chainId, "eip155:8453")
  }

  func testCoinbasePersonalSignUsesConnectedAccountAndDigest() async {
    let transport = FakeCoinbaseWalletTransport(isWalletInstalled: true)
    transport.handshakeResult = .success(
      CoinbaseWalletAccount(address: "0xCOINBASE", chainId: "eip155:1")
    )
    transport.signatureResult = .success("0xSIGNATURE")
    let connector = CoinbaseWalletConnector(transport: transport)
    await connector.connect()

    var dispatched = false
    let result = await connector.requestPersonalSign(digestHex: "0xDIGEST") {
      dispatched = true
    }

    XCTAssertEqual(result, .success("0xSIGNATURE"))
    XCTAssertEqual(transport.requestedAddress, "0xCOINBASE")
    XCTAssertEqual(transport.requestedDigest, "0xDIGEST")
    XCTAssertTrue(dispatched)
  }

  func testCoinbaseDisconnectClearsSessionState() async {
    let transport = FakeCoinbaseWalletTransport(isWalletInstalled: true)
    transport.handshakeResult = .success(
      CoinbaseWalletAccount(address: "0xCOINBASE", chainId: "eip155:1")
    )
    let connector = CoinbaseWalletConnector(transport: transport)
    await connector.connect()

    connector.disconnect()

    XCTAssertEqual(connector.state, .idle)
    XCTAssertNil(connector.address)
    XCTAssertEqual(transport.disconnectCount, 1)
  }

  private func assertWalletConnector<C: WalletConnector>(_ connector: C) {
    _ = connector
  }
}

@MainActor
private final class FakeCoinbaseWalletTransport: CoinbaseWalletTransport {
  let isWalletInstalled: Bool
  var handshakeResult: Result<CoinbaseWalletAccount, CoinbaseWalletTransportError> =
    .failure(.failed("No handshake result"))
  var signatureResult: Result<String, CoinbaseWalletTransportError> =
    .failure(.failed("No signature result"))
  private(set) var handshakeCount = 0
  private(set) var disconnectCount = 0
  private(set) var requestedAddress: String?
  private(set) var requestedDigest: String?

  init(isWalletInstalled: Bool) {
    self.isWalletInstalled = isWalletInstalled
  }

  func initiateHandshake(
    completion: @MainActor @escaping (Result<CoinbaseWalletAccount, CoinbaseWalletTransportError>) -> Void
  ) {
    handshakeCount += 1
    completion(handshakeResult)
  }

  func requestPersonalSign(
    address: String,
    digestHex: String,
    completion: @escaping (Result<String, CoinbaseWalletTransportError>) -> Void
  ) {
    requestedAddress = address
    requestedDigest = digestHex
    completion(signatureResult)
  }

  func disconnect() {
    disconnectCount += 1
  }

  func handle(url: URL) -> Bool {
    false
  }
}
