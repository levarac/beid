// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// `EventSession` fixture used by `DemoEvent` mode to drive the scan phase
/// machine without real BLE. The simulator has no Bluetooth radio, so this
/// doubles as the future App-Review demo mode (see README). Kept in this
/// file per `AGENTS.md`'s localization note — demo fixture data is real
/// user-visible copy, not a test-only value.
extension EventSession {
  static let demoSample = EventSession(id: "ETHGLOBALTOKYO-DEMO", name: "ETHGlobal Tokyo", venue: "Shibuya Hikarie")
}
