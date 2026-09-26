// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

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
    coordinator.completeWalletConnect(
      address: LiveWalletAddress.fromConnectorResult(address: "0xREALADDRESS", chainId: "eip155:1")
    )
    XCTAssertEqual(coordinator.walletAddress, "0xREALADDRESS")
    XCTAssertEqual(
      coordinator.liveWalletAddress,
      LiveWalletAddress.fromConnectorResult(address: "0xREALADDRESS", chainId: "eip155:1")
    )
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
    XCTAssertNil(coordinator.liveWalletAddress)
    // No connector was ever recorded on this coordinator, so
    // disconnectWallet() falls back to MetaMaskConnector.shared — this
    // asserts that fallback doesn't crash and leaves the singleton idle.
    XCTAssertEqual(MetaMaskConnector.shared.state, .idle)
  }

  /// `AppCoordinator.disconnectWallet()` is the one production call site
  /// that clears `WalletHintStore` (beid#315 / dispatch#26 condition 3) —
  /// it hardcodes `UserDefaults.standard`, same as `hasCompletedOnboardingKey`
  /// elsewhere in `AppCoordinator`, so this test cleans that one real key up
  /// around itself rather than injecting an isolated store, matching
  /// `AppCoordinatorRestoreTests`' existing convention for that key.
  func testDisconnectWalletClearsThePersistedHint() {
    let hintKey = "beid.walletConnect.lastAddressHint"
    UserDefaults.standard.removeObject(forKey: hintKey)
    defer { UserDefaults.standard.removeObject(forKey: hintKey) }
    WalletHintStore().save(CachedWalletHint(address: "0xREALADDRESS", chainId: "eip155:1"))
    XCTAssertNotNil(WalletHintStore().load(), "precondition: a hint is cached before disconnecting")

    let coordinator = AppCoordinator()
    coordinator.disconnectWallet()

    XCTAssertNil(WalletHintStore().load())
  }

  func testMetaMaskConnectDoesNotStartHandshakeWhenWalletIsMissing() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: false)
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())

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
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())

    await connector.connect()

    XCTAssertEqual(
      connector.state,
      .connected(LiveWalletAddress.fromConnectorResult(address: "0xMETAMASK", chainId: "eip155:1"))
    )
    XCTAssertEqual(connector.address, "0xMETAMASK")
    XCTAssertEqual(connector.chainId, "eip155:1")
  }

  func testMetaMaskConnectSavesTheHintForNextLaunch() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.connectResult = .success(
      MetaMaskWalletAccount(address: "0xMETAMASK", chainId: "eip155:1")
    )
    let store = makeIsolatedHintStore()
    let connector = MetaMaskConnector(transport: transport, hintStore: store)

    await connector.connect()

    XCTAssertEqual(store.load(), CachedWalletHint(address: "0xMETAMASK", chainId: "eip155:1"))
  }

  /// dispatch#26 condition 1: a fresh `MetaMaskConnector` reads whatever
  /// hint its store already has and starts at `.restored`, before any
  /// `connect()`/network call.
  func testMetaMaskConnectorStartsRestoredWhenAHintExists() {
    let store = makeIsolatedHintStore()
    store.save(CachedWalletHint(address: "0xPREVIOUS", chainId: "eip155:1"))

    let connector = MetaMaskConnector(transport: FakeMetaMaskTransport(isWalletInstalled: true), hintStore: store)

    XCTAssertEqual(connector.state, .restored(CachedWalletHint(address: "0xPREVIOUS", chainId: "eip155:1")))
  }

  func testMetaMaskConnectorStartsIdleWithNoHint() {
    let connector = MetaMaskConnector(
      transport: FakeMetaMaskTransport(isWalletInstalled: true),
      hintStore: makeIsolatedHintStore()
    )

    XCTAssertEqual(connector.state, .idle)
  }

  /// dispatch#26 condition 3: `disconnect()` is what every Cancel/Try
  /// Again/Start Over path in `WalletConnectPairingView` calls — it must
  /// reset the connector's in-memory session without touching the
  /// persisted hint. Only `AppCoordinator.disconnectWallet()` ("Disconnect
  /// Wallet") does that; see `testDisconnectWalletClearsThePersistedHint`.
  func testMetaMaskDisconnectDoesNotClearThePersistedHint() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.connectResult = .success(
      MetaMaskWalletAccount(address: "0xMETAMASK", chainId: "eip155:1")
    )
    let store = makeIsolatedHintStore()
    let connector = MetaMaskConnector(transport: transport, hintStore: store)
    await connector.connect()
    XCTAssertNotNil(store.load(), "precondition: connect() cached a hint")

    connector.disconnect()

    XCTAssertEqual(store.load(), CachedWalletHint(address: "0xMETAMASK", chainId: "eip155:1"))
  }

  /// `.restored` and `.connected` must never compare equal even when they
  /// describe the "same" address — `WalletConnectPairingView`'s exhaustive
  /// switch (and any future one) depends on the compiler, not a runtime
  /// check, to force a distinct branch for each; this pins the `Equatable`
  /// behavior that makes that possible.
  func testRestoredStateIsNeverEqualToConnectedStateForTheSameAddress() {
    let restored = WalletConnectorState.restored(
      CachedWalletHint(address: "0xSAME", chainId: "eip155:1")
    )
    let connected = WalletConnectorState.connected(
      LiveWalletAddress.fromConnectorResult(address: "0xSAME", chainId: "eip155:1")
    )
    XCTAssertNotEqual(restored, connected)
  }

  func testMetaMaskDisconnectClearsOwnedStateEvenWhenSDKRemainsConnected() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.connectResult = .success(
      MetaMaskWalletAccount(address: "0xMETAMASK", chainId: "eip155:1")
    )
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())
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
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())
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
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())
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

  // MARK: - `cancelPendingOperation()` (dispatch#26 condition 3)
  //
  // The light, in-app cancel used by Cancel/Try Again/Start Over — unlike
  // `disconnect()`, it must never reach the SDK's own persisted session
  // (`transport.disconnectCount` staying 0 is the proof of that) or clear
  // `WalletHintStore`.

  /// Mirrors `testMetaMaskLateConnectResultCannotRestoreDisconnectedSession`,
  /// but for the light cancel path: a stale late `connect()` response must
  /// not resurrect `.connected` after `cancelPendingOperation()`, and the
  /// SDK's own session must never have been touched.
  func testCancelPendingOperationDuringConnectLeavesTheSDKSessionAlone() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.suspendConnect = true
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())
    let connectTask = Task { await connector.connect() }
    await transport.waitUntilConnectStarts()

    connector.cancelPendingOperation()

    XCTAssertEqual(transport.disconnectCount, 0)
    XCTAssertEqual(connector.state, .idle)
    XCTAssertNil(connector.address)

    transport.completeConnect(
      with: .success(MetaMaskWalletAccount(address: "0xLATE", chainId: "eip155:8453"))
    )
    await connectTask.value

    XCTAssertEqual(connector.state, .idle)
    XCTAssertNil(connector.address)
    XCTAssertEqual(transport.disconnectCount, 0)
  }

  /// Mirrors `testMetaMaskDisconnectDoesNotClearThePersistedHint` — the
  /// light cancel path must be at least as non-destructive as `disconnect()`
  /// already is, and additionally must never touch the SDK session at all.
  func testCancelPendingOperationNeverClearsTheHint() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.connectResult = .success(
      MetaMaskWalletAccount(address: "0xMETAMASK", chainId: "eip155:1")
    )
    let store = makeIsolatedHintStore()
    let connector = MetaMaskConnector(transport: transport, hintStore: store)
    await connector.connect()
    XCTAssertNotNil(store.load(), "precondition: connect() cached a hint")

    connector.cancelPendingOperation()

    XCTAssertEqual(store.load(), CachedWalletHint(address: "0xMETAMASK", chainId: "eip155:1"))
    XCTAssertEqual(transport.disconnectCount, 0)
  }

  /// A pending sign request that gets cancelled must resolve `.cancelled` —
  /// not `.rejected` (a wallet-side decline), `.notConnected` (implies the
  /// session itself is gone), or `.timedOut` (implies the wallet never
  /// responded) — and must not touch the SDK's own session either.
  func testCancelPendingOperationDuringSignResolvesCancelledNotRejectedOrNotConnected() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.connectResult = .success(
      MetaMaskWalletAccount(address: "0xMETAMASK", chainId: "eip155:1")
    )
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())
    await connector.connect()
    transport.suspendPersonalSign = true

    let signTask = Task { await connector.requestPersonalSign(messageHex: "0xMESSAGE") }
    await transport.waitUntilPersonalSignStarts()

    connector.cancelPendingOperation()

    let result = await signTask.value
    XCTAssertEqual(result, .failure(.cancelled))
    XCTAssertEqual(transport.disconnectCount, 0)
  }

  /// Positive mirror: the property under test is "light paths leave the SDK
  /// session and hint alone, the ONE explicit path still tears both down" —
  /// a suite that only proved the light paths above would also pass for a
  /// regression that made every path non-destructive. Exercised at the
  /// `AppCoordinator` level (not just `MetaMaskConnector` directly) since
  /// `disconnectWallet()` is the actual production "Disconnect Wallet"
  /// entry point. Deliberately uses the real `UserDefaults.standard`-backed
  /// `WalletHintStore()` for the hint assertions (matching
  /// `testDisconnectWalletClearsThePersistedHint`'s existing convention):
  /// `AppCoordinator.disconnectWallet()` clears via its own fresh
  /// `WalletHintStore()`, not whatever hintStore was injected into the
  /// connector, so an isolated hintStore on the connector would not prove
  /// anything about the clear.
  func testDisconnectWalletStillDisconnectsTransportAndClearsHint() async {
    let hintKey = "beid.walletConnect.lastAddressHint"
    UserDefaults.standard.removeObject(forKey: hintKey)
    defer { UserDefaults.standard.removeObject(forKey: hintKey) }
    WalletHintStore().save(CachedWalletHint(address: "0xREALADDRESS", chainId: "eip155:1"))
    XCTAssertNotNil(WalletHintStore().load(), "precondition: a hint is cached before disconnecting")

    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.connectResult = .success(MetaMaskWalletAccount(address: "0xREALADDRESS", chainId: "eip155:1"))
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())
    await connector.connect()
    let coordinator = AppCoordinator(walletConnector: connector)

    coordinator.disconnectWallet()

    XCTAssertEqual(transport.disconnectCount, 1)
    XCTAssertNil(WalletHintStore().load())
  }

  // MARK: - `connectAndSign` (dispatch#26 condition 2)

  func testConnectAndSignPublishesConnectedStateAndReturnsSignature() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.connectAndSignResult = .success(
      (MetaMaskWalletAccount(address: "0xMETAMASK", chainId: "eip155:1"), "0xSIGNATURE")
    )
    let store = makeIsolatedHintStore()
    let connector = MetaMaskConnector(transport: transport, hintStore: store)

    var dispatched = false
    let result = await connector.connectAndSign(messageHex: "0xMESSAGE") { dispatched = true }

    guard case .success(let (live, signature)) = result else {
      XCTFail("expected success, got \(result)")
      return
    }
    XCTAssertEqual(live, LiveWalletAddress.fromConnectorResult(address: "0xMETAMASK", chainId: "eip155:1"))
    XCTAssertEqual(signature, "0xSIGNATURE")
    XCTAssertTrue(dispatched)
    XCTAssertEqual(connector.state, .connected(live))
    XCTAssertEqual(transport.connectAndSignMessage, "0xMESSAGE")
    XCTAssertEqual(
      store.load(),
      CachedWalletHint(address: "0xMETAMASK", chainId: "eip155:1"),
      "a successful connectAndSign refreshes the hint just like a plain connect() does"
    )
  }

  /// The address `connectAndSign` reports connected may differ from
  /// whatever guess a caller built its message with (the user switched
  /// accounts inside the wallet) — callers must use this returned address,
  /// never their own guess, past this point (dispatch#26 condition 4).
  func testConnectAndSignReturnsWhicheverAccountTheWalletActuallyConnected() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.connectAndSignResult = .success(
      (MetaMaskWalletAccount(address: "0xACTUAL", chainId: "eip155:1"), "0xSIGNATURE")
    )
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())

    let result = await connector.connectAndSign(messageHex: "0xMESSAGE")

    guard case .success(let (live, _)) = result else {
      XCTFail("expected success, got \(result)")
      return
    }
    XCTAssertEqual(live.address, "0xACTUAL")
  }

  func testConnectAndSignMapsRejectionToFailedState() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.connectAndSignResult = .failure(.rejected)
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())

    let result = await connector.connectAndSign(messageHex: "0xMESSAGE")

    guard case .failure(let error) = result else {
      XCTFail("expected failure, got \(result)")
      return
    }
    XCTAssertEqual(error, .rejected)
    XCTAssertEqual(connector.state, .failed("Connection declined"))
  }

  func testCancelPendingOperationDuringConnectAndSignResolvesCancelled() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.suspendConnectAndSign = true
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())
    let connectAndSignTask = Task { await connector.connectAndSign(messageHex: "0xMESSAGE") }
    await transport.waitUntilConnectAndSignStarts()

    connector.cancelPendingOperation()
    transport.completeConnectAndSign(
      with: .success((MetaMaskWalletAccount(address: "0xLATE", chainId: "eip155:1"), "0xSIGNATURE"))
    )

    guard case .failure(let error) = await connectAndSignTask.value else {
      XCTFail("expected cancellation")
      return
    }
    XCTAssertEqual(error, .cancelled)
  }

  func testDisconnectDuringConnectAndSignResolvesNotConnected() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.suspendConnectAndSign = true
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())
    let connectAndSignTask = Task { await connector.connectAndSign(messageHex: "0xMESSAGE") }
    await transport.waitUntilConnectAndSignStarts()

    connector.disconnect()
    transport.completeConnectAndSign(
      with: .success((MetaMaskWalletAccount(address: "0xLATE", chainId: "eip155:1"), "0xSIGNATURE"))
    )

    guard case .failure(let error) = await connectAndSignTask.value else {
      XCTFail("expected disconnected failure")
      return
    }
    XCTAssertEqual(error, .notConnected)
    XCTAssertEqual(connector.state, .idle)
    XCTAssertEqual(transport.disconnectCount, 1)
  }

  func testNewConnectAndSignSupersedesPendingAttemptAsCancelled() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.suspendConnectAndSign = true
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())
    let firstTask = Task { await connector.connectAndSign(messageHex: "0xFIRST") }
    await transport.waitUntilConnectAndSignStarts()

    transport.suspendConnectAndSign = false
    transport.connectAndSignResult = .success(
      (MetaMaskWalletAccount(address: "0xCURRENT", chainId: "eip155:1"), "0xCURRENT_SIGNATURE")
    )
    let currentResult = await connector.connectAndSign(messageHex: "0xCURRENT")
    transport.completeConnectAndSign(
      with: .success((MetaMaskWalletAccount(address: "0xSTALE", chainId: "eip155:1"), "0xSTALE_SIGNATURE"))
    )

    guard case .failure(let firstError) = await firstTask.value else {
      XCTFail("expected the superseded attempt to fail")
      return
    }
    XCTAssertEqual(firstError, .cancelled)
    guard case .success(let (live, signature)) = currentResult else {
      XCTFail("expected the current attempt to succeed")
      return
    }
    XCTAssertEqual(live.address, "0xCURRENT")
    XCTAssertEqual(signature, "0xCURRENT_SIGNATURE")
    XCTAssertEqual(connector.state, .connected(live))
  }

  func testNewConnectSupersedesPendingConnectAndSignAsCancelled() async {
    let transport = FakeMetaMaskTransport(isWalletInstalled: true)
    transport.suspendConnectAndSign = true
    let connector = MetaMaskConnector(transport: transport, hintStore: makeIsolatedHintStore())
    let firstTask = Task { await connector.connectAndSign(messageHex: "0xFIRST") }
    await transport.waitUntilConnectAndSignStarts()

    transport.connectResult = .success(
      MetaMaskWalletAccount(address: "0xCURRENT", chainId: "eip155:1")
    )
    await connector.connect()
    transport.completeConnectAndSign(
      with: .success((MetaMaskWalletAccount(address: "0xSTALE", chainId: "eip155:1"), "0xSTALE_SIGNATURE"))
    )

    guard case .failure(let firstError) = await firstTask.value else {
      XCTFail("expected the superseded attempt to fail")
      return
    }
    XCTAssertEqual(firstError, .cancelled)
    XCTAssertEqual(connector.address, "0xCURRENT")
    XCTAssertEqual(
      connector.state,
      .connected(LiveWalletAddress.fromConnectorResult(address: "0xCURRENT", chainId: "eip155:1"))
    )
  }
}

@MainActor
private final class FakeMetaMaskTransport: MetaMaskTransport {
  let isWalletInstalled: Bool
  var connectResult: Result<MetaMaskWalletAccount, MetaMaskTransportError> =
    .failure(.failed("No connect result"))
  var connectAndSignResult: Result<(MetaMaskWalletAccount, String), MetaMaskTransportError> =
    .failure(.failed("No connectAndSign result"))
  var signatureResult: Result<String, MetaMaskTransportError> =
    .failure(.failed("No signature result"))
  var suspendConnect = false
  var suspendConnectAndSign = false
  var suspendPersonalSign = false
  private(set) var connectCount = 0
  private(set) var disconnectCount = 0
  private(set) var sdkConnected = false
  private(set) var requestedAddress: String?
  private(set) var requestedMessage: String?
  private(set) var connectAndSignMessage: String?
  private var connectContinuation:
    CheckedContinuation<Result<MetaMaskWalletAccount, MetaMaskTransportError>, Never>?
  private var connectAndSignContinuation:
    CheckedContinuation<Result<(MetaMaskWalletAccount, String), MetaMaskTransportError>, Never>?
  private var personalSignContinuation:
    CheckedContinuation<Result<String, MetaMaskTransportError>, Never>?

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

  func connectAndSign(
    messageHex: String
  ) async -> Result<(MetaMaskWalletAccount, String), MetaMaskTransportError> {
    connectAndSignMessage = messageHex
    sdkConnected = true
    guard suspendConnectAndSign else { return connectAndSignResult }
    return await withCheckedContinuation { continuation in
      connectAndSignContinuation = continuation
    }
  }

  func requestPersonalSign(
    address: String,
    messageHex: String
  ) async -> Result<String, MetaMaskTransportError> {
    requestedAddress = address
    requestedMessage = messageHex
    guard suspendPersonalSign else { return signatureResult }
    return await withCheckedContinuation { continuation in
      personalSignContinuation = continuation
    }
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

  func waitUntilConnectAndSignStarts() async {
    while connectAndSignMessage == nil {
      await Task.yield()
    }
  }

  func completeConnectAndSign(
    with result: Result<(MetaMaskWalletAccount, String), MetaMaskTransportError>
  ) {
    connectAndSignContinuation?.resume(returning: result)
    connectAndSignContinuation = nil
  }

  func waitUntilPersonalSignStarts() async {
    while requestedMessage == nil {
      await Task.yield()
    }
  }

  func completePersonalSign(with result: Result<String, MetaMaskTransportError>) {
    personalSignContinuation?.resume(returning: result)
    personalSignContinuation = nil
  }
}

/// Isolated `WalletHintStore` per test — mirrors
/// `OwnerKeyProviderTests.makeIsolatedDefaults()`'s `UserDefaults(suiteName:)`
/// pattern, so `MetaMaskConnector` tests never read or write the real
/// `UserDefaults.standard` wallet-hint key.
@MainActor
private func makeIsolatedHintStore() -> WalletHintStore {
  let suiteName = "WalletConnectTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defaults.removePersistentDomain(forName: suiteName)
  return WalletHintStore(defaults: defaults)
}
