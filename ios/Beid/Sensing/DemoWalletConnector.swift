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
  static let demoAddress = "0xDE00000000000000000000000000000000DEC0"

  @Published private(set) var state: WalletConnectorState = .idle

  var address: String? {
    guard case .connected(let address) = state else { return nil }
    return address
  }

  var chainId: String { "eip155:1" }

  private init() {}

  func configureIfNeeded() {}

  func connect() async {
    state = .connecting
    try? await Task.sleep(nanoseconds: 400_000_000)
    state = .connected(address: Self.demoAddress)
  }

  func requestPersonalSign(
    digestHex: String,
    responseTimeout: TimeInterval = 90,
    onDispatched: (() -> Void)? = nil
  ) async -> Result<String, WalletConnectorError> {
    guard case .connected = state else { return .failure(.notConnected) }
    onDispatched?()
    try? await Task.sleep(nanoseconds: 400_000_000)
    return .success("0x" + String(repeating: "d", count: 130))
  }

  func disconnect() {
    state = .idle
  }

  @discardableResult
  func handle(url: URL) -> Bool { false }
}
#endif
