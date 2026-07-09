// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Ordering of the wallet step relative to the rest of onboarding.
///
/// Team ruling is WalletConnect-first (no account abstraction), but an
/// App-Store-risk review recommends guest-first. That product decision is
/// unresolved, so both orders are wired behind this flag and demonstrable by
/// flipping it — see README "Onboarding flag".
enum OnboardingMode: String, CaseIterable {
  case walletFirst
  case guestFirst

  /// Single toggle point for this slice. Flip to demo the other order.
  static let current: OnboardingMode = .walletFirst
}
