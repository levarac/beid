// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// A simulated event used by `DemoEvent` mode to drive the 06a→06c scan
/// states without real BLE. The simulator has no Bluetooth radio, so this
/// doubles as the future App-Review demo mode (see README).
struct DemoEvent: Equatable {
  let name: String
  let totalPeersToVerify: Int

  static let sample = DemoEvent(name: "ETHGlobal Tokyo", totalPeersToVerify: 3)
}
