// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Whether the wallet-connect screen uses the `WalletConnectStub` fake
/// address or attempts a real Reown/WalletConnect pairing via
/// `ReownWalletConnectClient`. Spike flag, same pattern as
/// `OnboardingMode.current` — see ios/README.md "WalletConnect (spike)".
enum WalletConnectMode: String, CaseIterable {
  case stub
  case reown

  /// Single toggle point for this spike. Flip to demo the stub-only path.
  static let current: WalletConnectMode = .reown
}
