// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// Display-only "last connected wallet" hint (beid#315 / dispatch#26
/// condition 1/4). Deliberately its own small, isolated type — not a field
/// on `BindingRecord`/`Proof`/`SelfProofRecord` — so DECISIONS 2026-08-09's
/// "optional-field-only, no enum case additions" rule for those existing
/// `Codable` domain schemas never comes into play here at all.
///
/// This type must never be usable as, or convertible to, a
/// `LiveWalletAddress` (see that type's doc comment in `WalletConnector.swift`)
/// — it carries a plain `String` address that was last read from
/// `WalletHintStore`, not from a live wallet session.
struct CachedWalletHint: Equatable, Codable {
  let address: String
  let chainId: String
}

extension CachedWalletHint {
  /// `0x1234...5678` display form, mirroring `AccountSheetView.truncated(_:)`.
  var truncatedAddress: String {
    guard address.count > 10 else { return address }
    return "\(address.prefix(6))...\(address.suffix(4))"
  }
}

/// UserDefaults-backed store for the single cached `CachedWalletHint` —
/// UserDefaults, not Keychain, because the address is not a secret (it is
/// already disclosed elsewhere in this app's own persisted data, e.g.
/// `BindingRecord.walletAddress`); beid#315 Phase 1 decision. Mirrors
/// `BeidUserDefaultsKeyStorage`'s injectable-`UserDefaults` shape
/// (`ios/Beid/Sensing/OwnerKeyProvider.swift`) so tests can point this at an
/// isolated `UserDefaults(suiteName:)` instead of `.standard`.
///
/// Cleared only by an explicit disconnect ("Forget"/"Disconnect Wallet")
/// action — never by Cancel, Try Again, Start Over, or a sheet dismissal.
/// Callers enforce that by simply never calling `clear()` from those paths;
/// see `AppCoordinator.disconnectWallet()` for the one production call site.
struct WalletHintStore {
  private let defaults: UserDefaults
  private let key = "beid.walletConnect.lastAddressHint"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> CachedWalletHint? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(CachedWalletHint.self, from: data)
  }

  func save(_ hint: CachedWalletHint) {
    guard let data = try? JSONEncoder().encode(hint) else { return }
    defaults.set(data, forKey: key)
  }

  func clear() {
    defaults.removeObject(forKey: key)
  }
}
