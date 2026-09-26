// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// Ordering of the wallet step relative to the rest of onboarding.
///
/// Resolved 2026-07-26 (docs/specs/onboarding-redesign.md §3): the entry
/// flow is event-first. Welcome does not connect a wallet; wallet connect +
/// binding happens later, after event confirmation. Both orders stay wired
/// behind this flag so the earlier wallet-first order remains demonstrable
/// by flipping it back.
enum OnboardingMode: String, CaseIterable {
  case walletFirst
  case guestFirst

  /// Single toggle point for this slice. Event-first per the 2026-07-26
  /// decision record.
  static let current: OnboardingMode = .guestFirst
}
