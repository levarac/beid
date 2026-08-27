// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Combine
import XCTest
@testable import Beid

/// Covers the `AppCoordinator` wiring around wallet connect/disconnect, and
/// the `MetaMaskConnector` implementation of `WalletConnector` against a
/// fake transport. Does not exercise the SDK's real handshake — that
/// requires a live wallet app installed on a device; see
/// docs/field-test-procedure.md.
@MainActor
final class WalletConnectTests: XCTestCase {
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

  func testDisconnectWalletClearsAddressAndResetsFallbackConnector() {
    let coordinator = AppCoordinator()
    coordinator.walletAddress = "0xREALADDRESS"

    coordinator.disconnectWallet()

    XCTAssertNil(coordinator.walletAddress)
    // No connector was ever recorded on this coordinator, so
    // disconnectWallet() falls back to MetaMaskConnector.shared — this
    // asserts that fallback doesn't crash and leaves the singleton idle.
    XCTAssertEqual(MetaMaskConnector.shared.state, .idle)
  }

  func testMetaMaskConnectDoesNotStartHandshakeWhenWalletIsMissing() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: false)
    let connector = MetaMaskConnector(transport: transport)

    await connector.connect()

    XCTAssertEqual(connector.state, .unavailable(.walletNotInstalled))
    XCTAssertNil(connector.address)
    XCTAssertEqual(transport.connectCount, 0)
  }

  func testMetaMaskConnectPublishesOwnedSessionState() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.connectResult = .success(
      MetaMaskWalletAccount(address: "0xMETAMASK", chainId: "eip155:1")
    )
    let connector = MetaMaskConnector(transport: transport)

    await connector.connect()

    XCTAssertEqual(connector.state, .connected(address: "0xMETAMASK"))
    XCTAssertEqual(connector.address, "0xMETAMASK")
    XCTAssertEqual(connector.chainId, "eip155:1")
  }

  func testMetaMaskDisconnectClearsOwnedStateEvenWhenSDKRemainsConnected() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.connectResult = .success(
      MetaMaskWalletAccount(address: "0xMETAMASK", chainId: "eip155:1")
    )
    let connector = MetaMaskConnector(transport: transport)
    await connector.connect()

    connector.disconnect()

    XCTAssertTrue(transport.sdkConnected)
    XCTAssertEqual(connector.state, .idle)
    XCTAssertNil(connector.address)
    XCTAssertEqual(connector.chainId, "eip155:1")
    XCTAssertEqual(transport.disconnectCount, 1)
  }

  func testMetaMaskPersonalSignUsesOwnedSessionAccount() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.connectResult = .success(
      MetaMaskWalletAccount(address: "0xMETAMASK", chainId: "eip155:1")
    )
    transport.signatureResult = .success("0xSIGNATURE")
    let connector = MetaMaskConnector(transport: transport)
    await connector.connect()

    var dispatched = false
    let result = await connector.requestPersonalSign(messageHex: "0xMESSAGE") {
      dispatched = true
    }

    XCTAssertEqual(result, .success("0xSIGNATURE"))
    XCTAssertEqual(transport.requestedAddress, "0xMETAMASK")
    XCTAssertEqual(transport.requestedMessage, "0xMESSAGE")
    XCTAssertTrue(dispatched)
  }

  func testMetaMaskLateConnectResultCannotRestoreDisconnectedSession() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.suspendConnect = true
    let connector = MetaMaskConnector(transport: transport)
    let connectTask = Task { await connector.connect() }
    await transport.waitUntilConnectStarts()

    connector.disconnect()
    transport.completeConnect(
      with: .success(MetaMaskWalletAccount(address: "0xLATE", chainId: "eip155:8453"))
    )
    await connectTask.value

    XCTAssertTrue(transport.sdkConnected)
    XCTAssertEqual(connector.state, .idle)
    XCTAssertNil(connector.address)
    XCTAssertEqual(connector.chainId, "eip155:1")
  }
}

@MainActor
private final class FakeMetaMaskTransport: MetaMaskTransport {
  let isWalletInstalled: Bool
  var connectResult: Result<MetaMaskWalletAccount, MetaMaskTransportError> =
    .failure(.failed("No connect result"))
  var signatureResult: Result<String, MetaMaskTransportError> =
    .failure(.failed("No signature result"))
  var suspendConnect = false
  private(set) var connectCount = 0
  private(set) var disconnectCount = 0
  private(set) var sdkConnected = false
  private(set) var requestedAddress: String?
  private(set) var requestedMessage: String?
  private var connectContinuation:
    CheckedContinuation<Result<MetaMaskWalletAccount, MetaMaskTransportError>, Never>?

  init(isWalletInstalled: Bool) {
    self.isWalletInstalled = isWalletInstalled
  }

  func connect() async -> Result<MetaMaskWalletAccount, MetaMaskTransportError> {
    connectCount += 1
    sdkConnected = true
    guard suspendConnect else { return connectResult }
    return await withCheckedContinuation { continuation in
      connectContinuation = continuation
    }
  }

  func requestPersonalSign(
    address: String,
    messageHex: String
  ) async -> Result<String, MetaMaskTransportError> {
    requestedAddress = address
    requestedMessage = messageHex
    return signatureResult
  }

  func disconnect() {
    disconnectCount += 1
    // Mirrors metamask-ios-sdk 0.8.10's known behavior: its public
    // `connected` property can remain true after `disconnect()`.
  }

  func handle(url: URL) -> Bool {
    false
  }

  func waitUntilConnectStarts() async {
    while connectCount == 0 {
      await Task.yield()
    }
  }

  func completeConnect(
    with result: Result<MetaMaskWalletAccount, MetaMaskTransportError>
  ) {
    connectContinuation?.resume(returning: result)
    connectContinuation = nil
  }
}
