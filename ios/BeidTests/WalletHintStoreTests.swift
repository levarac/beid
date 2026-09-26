// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

/// Covers `CachedWalletHint`/`WalletHintStore` persistence (beid#315 /
/// dispatch#26 conditions 1 and 3) in isolation from `MetaMaskConnector` —
/// `WalletConnectTests` covers the connector-level wiring (starting
/// `.restored`, refreshing the hint on connect/connectAndSign).
final class WalletHintStoreTests: XCTestCase {
  func testLoadReturnsNilWhenNothingIsCached() {
    let store = WalletHintStore(defaults: makeIsolatedDefaults())
    XCTAssertNil(store.load())
  }

  func testSaveThenLoadRoundTrips() {
    let store = WalletHintStore(defaults: makeIsolatedDefaults())
    let hint = CachedWalletHint(address: "0xABCDEF1234567890ABCDEF1234567890ABCDEF12", chainId: "eip155:1")

    store.save(hint)

    XCTAssertEqual(store.load(), hint)
  }

  /// Simulates a process boundary the same way `OwnerKeyProviderTests`
  /// does for `BeidUserDefaultsKeyStorage`: writes through one store
  /// instance, then reads back through a brand-new instance pointed at the
  /// same `UserDefaults` suite (standing in for a fresh app launch reading
  /// what a previous run persisted) — dispatch#26 condition 1.
  func testHintSurvivesAFreshStoreInstanceAgainstTheSameDefaults() {
    let defaults = makeIsolatedDefaults()
    let hint = CachedWalletHint(address: "0x1111111111111111111111111111111111111", chainId: "eip155:8453")
    WalletHintStore(defaults: defaults).save(hint)

    let freshStore = WalletHintStore(defaults: defaults)

    XCTAssertEqual(freshStore.load(), hint)
  }

  func testSaveOverwritesAPreviousHint() {
    let store = WalletHintStore(defaults: makeIsolatedDefaults())
    store.save(CachedWalletHint(address: "0xOLD", chainId: "eip155:1"))

    store.save(CachedWalletHint(address: "0xNEW", chainId: "eip155:8453"))

    XCTAssertEqual(store.load(), CachedWalletHint(address: "0xNEW", chainId: "eip155:8453"))
  }

  func testClearRemovesTheHint() {
    let store = WalletHintStore(defaults: makeIsolatedDefaults())
    store.save(CachedWalletHint(address: "0xABC", chainId: "eip155:1"))

    store.clear()

    XCTAssertNil(store.load())
  }

  func testClearWithNothingCachedIsSafe() {
    let store = WalletHintStore(defaults: makeIsolatedDefaults())
    store.clear() // must not crash
    XCTAssertNil(store.load())
  }

  func testTruncatedAddressShortensALongAddress() {
    let hint = CachedWalletHint(address: "0x1234567890abcdef1234567890abcdef12345678", chainId: "eip155:1")
    XCTAssertEqual(hint.truncatedAddress, "0x1234...5678")
  }

  func testTruncatedAddressLeavesAShortAddressAlone() {
    let hint = CachedWalletHint(address: "0xshort", chainId: "eip155:1")
    XCTAssertEqual(hint.truncatedAddress, "0xshort")
  }

  private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "org.levarac.beid.tests.walletHintStore.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
