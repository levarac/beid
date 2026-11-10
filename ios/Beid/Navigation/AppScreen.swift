// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// Top-level onboarding and home screens. Sensing details are pushed from
/// the Now navigation stack rather than represented by a separate root.
enum AppScreen: Equatable {
  case welcome
  case eventCodeEntry
  case bluetoothPermission
  case bluetoothDenied
  case bluetoothOff
  case home
}
