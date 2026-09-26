// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

#if DEBUG
import BarnardCore
import Combine
import Foundation

/// DEBUG-only mock `WalletConnector` so the connect+binding interstitial's
/// full round trip (connect → wallet `personal_sign` → device countersign →
/// `BindingRecord`) is exercisable in the simulator/demo walkthrough without
/// a real wallet app installed — mirrors `SensingCoordinator
/// .useDemoEventMode`'s existing demo-fixture convention. Offered only by
/// `EventBindingSheetView`'s demo escape hatch (gated on `useDemoEventMode`,
/// same as `simulateSignalLost()`), never by `WalletConnectPairingView`
/// (onboarding/Account sheet reuse it as-is, per
/// `docs/specs/scan-slice2-redesign.md` §5.6 — no demo option there).
@MainActor
final class DemoWalletConnector: ObservableObject, WalletConnector {
  static let shared = DemoWalletConnector()

  /// Fixed synthetic EOA keypair backing the demo "wallet" — DEBUG-only,
  /// non-custodial, and holds nothing of value. Derived deterministically
  /// via `BarnardCoreSigning.deriveOwnerKeyPair` purely because it is the
  /// existing fixed-seed-to-keypair primitive of the right shape; this is
  /// an ordinary synthetic dev-tool wallet key, not beid's owner key.
  /// Replaces the previous hardcoded vanity address string (no private key
  /// ever backed it, so it could never produce a signature that piece (b)
  /// verification — beid#316 — would accept), and `requestPersonalSign`/
  /// `connectAndSign` below now actually sign with it instead of returning
  /// a hardcoded signature string.
  private static let demoWalletKeyPair = BarnardCoreSigning.deriveOwnerKeyPair(
    accountSecret: [UInt8](repeating: 0xDE, count: 32)
  )

  /// Derived from `demoWalletKeyPair`, not a hand-picked literal — a real
  /// private key backs it, so a `personal_sign` request against this
  /// address can actually be answered with a valid signature.
  static let demoAddress: String = {
    guard
      let addressBytes = BarnardCoreSigning.ethereumAddress(
        publicKeyCompressed: demoWalletKeyPair.publicKeyCompressed
      )
    else {
      preconditionFailure("demoWalletKeyPair must yield a valid Ethereum address")
    }
    return "0x" + addressBytes.map { String(format: "%02x", $0) }.joined()
  }()

  @Published private(set) var state: WalletConnectorState = .idle

  var address: String? {
    guard case .connected(let live) = state else { return nil }
    return live.address
  }

  var chainId: String { "eip155:1" }

  private init() {}

  func configureIfNeeded() {}

  func connect() async {
    state = .connecting
    try? await Task.sleep(nanoseconds: 400_000_000)
    state = .connected(LiveWalletAddress.fromConnectorResult(address: Self.demoAddress, chainId: chainId))
  }

  func requestPersonalSign(
    messageHex: String,
    responseTimeout: TimeInterval = 90,
    onDispatched: (() -> Void)? = nil
  ) async -> Result<String, WalletConnectorError> {
    guard case .connected = state else { return .failure(.notConnected) }
    onDispatched?()
    try? await Task.sleep(nanoseconds: 400_000_000)
    guard let signatureHex = Self.sign(messageHex: messageHex) else {
      return .failure(.relayFailure("Demo wallet could not decode the message to sign"))
    }
    return .success(signatureHex)
  }

  /// DEBUG-only parity with `MetaMaskConnector.connectAndSign` (dispatch#26
  /// condition 2) — no `.restored` cache-hint round trip exists for this
  /// connector (it is never wired to `WalletHintStore`, see the type doc
  /// comment above), so this exists only so `EventBindingSheetView`'s demo
  /// escape hatch keeps compiling against the shared `WalletConnector`
  /// protocol, not because the demo path exercises the restored-hint UI.
  func connectAndSign(
    messageHex: String,
    responseTimeout: TimeInterval = 90,
    onDispatched: (() -> Void)? = nil
  ) async -> Result<(LiveWalletAddress, String), WalletConnectorError> {
    state = .connecting
    try? await Task.sleep(nanoseconds: 400_000_000)
    let live = LiveWalletAddress.fromConnectorResult(address: Self.demoAddress, chainId: chainId)
    state = .connected(live)
    onDispatched?()
    try? await Task.sleep(nanoseconds: 400_000_000)
    guard let signatureHex = Self.sign(messageHex: messageHex) else {
      return .failure(.relayFailure("Demo wallet could not decode the message to sign"))
    }
    return .success((live, signatureHex))
  }

  func disconnect() {
    state = .idle
  }

  func cancelPendingOperation() {
    state = .idle
  }

  @discardableResult
  func handle(url: URL) -> Bool { false }

  /// Signs `messageHex` (the `0x`-prefixed hex `SensingCoordinator
  /// .beginBinding` hands every `WalletConnector`) with `demoWalletKeyPair`'s
  /// private key, producing the 65-byte wallet-format signature (`r ‖ s ‖
  /// v`) that `BarnardCoreSigning.verifyWalletBinding` expects. `nil` only
  /// if `messageHex` isn't well-formed hex, which does not happen for a
  /// message this connector itself was handed by `beginBinding`.
  private static func sign(messageHex: String) -> String? {
    guard let messageBytes = decodeHex(messageHex) else { return nil }
    let digest = BarnardCoreSigning.computeEip191Digest(messageBytes: messageBytes)
    let signature = BarnardCoreSigning.signRecoverable(
      privateKey: demoWalletKeyPair.privateKey,
      messageHash32: digest
    )
    let signatureBytes = signature.r + signature.s + [UInt8(signature.v)]
    return "0x" + signatureBytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func decodeHex(_ string: String) -> [UInt8]? {
    let stripped = string.hasPrefix("0x") || string.hasPrefix("0X")
      ? String(string.dropFirst(2))
      : string
    guard stripped.count.isMultiple(of: 2) else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(stripped.count / 2)
    var index = stripped.startIndex
    while index < stripped.endIndex {
      let next = stripped.index(index, offsetBy: 2)
      guard let byte = UInt8(stripped[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return bytes
  }
}
#endif
