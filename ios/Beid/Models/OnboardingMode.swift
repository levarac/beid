// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// Legacy onboarding modes retained for compatibility.
/// Both values enter Bluetooth permission directly; this flag does not
/// introduce a wallet step in the current onboarding flow.
enum OnboardingMode: String, CaseIterable {
  case walletFirst
  case guestFirst

  /// Compatibility default; onboarding does not branch on this value.
  static let current: OnboardingMode = .guestFirst
}
