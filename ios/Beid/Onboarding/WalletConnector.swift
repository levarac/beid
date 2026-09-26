// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

enum WalletConnectorUnavailableReason: Equatable {
  case walletNotInstalled
}

/// A wallet address produced by this process's own live connector session —
/// i.e. it was read back from a `connect()`/`connectAndSign()` result, never
/// read from `CachedWalletHint`/`WalletHintStore`. This is the structural
/// half of dispatch#26 condition 4 (a cached address must never reach a
/// binding signature): `performBinding`/`completeBinding`'s call site in
/// `EventBindingSheetView` only ever accepts this type, and nothing in this
/// codebase converts a `CachedWalletHint`/`String` into one — the memberwise
/// initializer is `private` to this file, and the only way to construct a
/// value from any other file is `fromConnectorResult(address:chainId:)`
/// below, called from inside a connector's own successful-connect/sign code
/// path (`MetaMaskConnector`, `DemoWalletConnector`) or a call site that
/// already holds one it got from there (beid#315 Phase 3: this narrows
/// "what can construct this type" to "read this one file", it is not a
/// compile-time guarantee that every caller of the factory passes a truly
/// live value). Grep both facts before relying on this comment: it is not
/// itself the enforcement.
struct LiveWalletAddress: Equatable {
  let address: String
  let chainId: String

  private init(address: String, chainId: String) {
    self.address = address
    self.chainId = chainId
  }

  /// The sole construction path for `LiveWalletAddress` outside this file.
  /// Every legitimate caller is a connector reporting what its own
  /// transport/SDK just returned from a live `connect()`/`connectAndSign()`
  /// round trip — never a cached/guessed value (`CachedWalletHint`/
  /// `WalletHintStore`). This narrows "what can construct this type" to "read
  /// this one file" (beid#315 Phase 3); it does not stop a future careless
  /// caller from invoking this factory with cache-sourced data — it only
  /// removes the bare memberwise initializer from every other file in the
  /// target.
  static func fromConnectorResult(address: String, chainId: String) -> LiveWalletAddress {
    LiveWalletAddress(address: address, chainId: chainId)
  }
}

enum WalletConnectorState: Equatable {
  case notConfigured
  case unavailable(WalletConnectorUnavailableReason)
  case idle
  /// A cached hint exists from a previous launch/process and no live
  /// session has connected yet this run (beid#315 / dispatch#26 condition
  /// 1) — set once, from `WalletHintStore`, at connector init, never from a
  /// live connect. `CachedWalletHint`'s `address` is display-only: nothing
  /// reads it into a `LiveWalletAddress` without a real `connect()`/
  /// `connectAndSign()` round trip first.
  case restored(CachedWalletHint)
  case connecting
  case awaitingApproval(uri: String?)
  case connected(LiveWalletAddress)
  case failed(String)
}

enum WalletConnectorError: Error, Equatable {
  case notConnected
  case rejected
  case timedOut
  case relayFailure(String)
  /// An in-flight operation that did not complete while the SDK session was
  /// deliberately left intact. Both `cancelPendingOperation()` and a newer
  /// connection attempt superseding an older one produce this result. The
  /// active gate MUST resolve its `CheckedContinuation` with some value
  /// before dropping the reference — an unresumed continuation traps on
  /// deallocation, so the awaiting caller either crashes (debug) or hangs
  /// forever (release). Of the other three existing cases, none is a
  /// truthful value to resolve it with: `.rejected` means MetaMask error
  /// 4001, a wallet-side decline, which never happened; `.notConnected` is
  /// the literal string `EventBindingSheetView` shows a user ("Wallet not
  /// connected"), which overclaims — it reads as "your wallet link is
  /// broken, reconnect from zero," when the SDK session is deliberately
  /// left intact; `.timedOut` claims a response timer lapsed, which also
  /// never happened. `.cancelled` is the only honest value available — this
  /// justifies the case's existence on its own, independent of whether any
  /// UI path reaches it today. For direct user cancellation, it also
  /// describes what happened: the user stopped this specific operation from
  /// beid's own UI (Cancel, Try Again, Start Over) before it reached — or
  /// heard back from — the wallet.
  case cancelled
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
    messageHex: String,
    responseTimeout: TimeInterval,
    onDispatched: (() -> Void)?
  ) async -> Result<String, WalletConnectorError>
  /// Connect and sign `messageHex` in a single wallet round trip (dispatch#26
  /// condition 2) — used when a `.restored` hint exists and the user acts on
  /// it, so the wallet app is switched to at most once instead of once for
  /// `connect()` and once more for `requestPersonalSign`. On success, the
  /// returned `LiveWalletAddress` is whatever the wallet actually reports as
  /// connected — which may differ from the `.restored` hint's guess if the
  /// user switched accounts inside the wallet app; callers must use the
  /// returned address, never the hint's, for anything past this point.
  func connectAndSign(
    messageHex: String,
    responseTimeout: TimeInterval,
    onDispatched: (() -> Void)?
  ) async -> Result<(LiveWalletAddress, String), WalletConnectorError>
  /// Tears down the wallet SDK's own persisted session (e.g.
  /// `sdk.disconnect()`/`sdk.clearSession()`) in addition to this
  /// connector's in-memory state. This is the destructive one — reserve it
  /// for an explicit "forget this wallet" action (`AppCoordinator
  /// .disconnectWallet()`'s "Disconnect Wallet"). A user cancelling out of
  /// beid's own UI should call `cancelPendingOperation()` instead.
  func disconnect()
  /// Aborts whatever connect/sign attempt is currently in flight and returns
  /// to `.idle`, without touching the wallet SDK's own persisted session or
  /// `WalletHintStore` (dispatch#26 condition 3). Use this for a user
  /// cancelling out of beid's own UI (Cancel, Try Again, Start Over) —
  /// reserve `disconnect()` for an explicit "forget this wallet" action.
  func cancelPendingOperation()
  @discardableResult func handle(url: URL) -> Bool
}

extension WalletConnector {
  func requestPersonalSign(
    messageHex: String,
    onDispatched: (() -> Void)? = nil
  ) async -> Result<String, WalletConnectorError> {
    await requestPersonalSign(
      messageHex: messageHex,
      responseTimeout: 90,
      onDispatched: onDispatched
    )
  }

  func connectAndSign(
    messageHex: String,
    onDispatched: (() -> Void)? = nil
  ) async -> Result<(LiveWalletAddress, String), WalletConnectorError> {
    await connectAndSign(
      messageHex: messageHex,
      responseTimeout: 90,
      onDispatched: onDispatched
    )
  }
}
