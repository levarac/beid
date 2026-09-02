// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#if DEBUG
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
  // 40 hex chars after "0x" — a valid 20-byte EVM address shape. (Was
  // previously 38 chars/19 bytes, an off-by-one-byte typo invisible while
  // this string was only ever displayed, never decoded — sub-slice C's
  // `BarnardCoreSigning.buildAccountBindingText` now requires exactly 20
  // bytes, which would otherwise make the DEBUG-only "Simulate binding"
  // path silently no-op.)
  static let demoAddress = "0xDE0000000000000000000000000000000000DEC0"

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
    return .success("0x" + String(repeating: "d", count: 130))
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
    return .success((live, "0x" + String(repeating: "d", count: 130)))
  }

  func disconnect() {
    state = .idle
  }

  @discardableResult
  func handle(url: URL) -> Bool { false }
}
#endif
