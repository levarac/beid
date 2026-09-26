// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// Top-level onboarding/home screens. The Scan flow (05-07) is presented as
/// a full-screen cover from `.home` rather than a case here, driven by
/// `SensingCoordinator.phase`.
enum AppScreen: Equatable {
  case welcome
  case walletConnect
  case eventCodeEntry
  case bluetoothPermission
  case bluetoothDenied
  case bluetoothOff
  case home
}
