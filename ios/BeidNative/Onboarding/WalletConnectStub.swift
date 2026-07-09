// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Stand-in for a real WalletConnect SDK integration, which is out of scope
/// for this slice (team ruling: WalletConnect login, no account
/// abstraction). Produces a fake address so onboarding is demonstrable in
/// both `OnboardingMode` orders without a live wallet.
enum WalletConnectStub {
  static func fakeConnect() -> String {
    let hex = (0..<40).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()
    return "0x" + hex
  }
}
