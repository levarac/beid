// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// `EventSession` fixture used by `DemoEvent` mode to drive the scan phase
/// machine without real BLE. The simulator has no Bluetooth radio, so this
/// doubles as the future App-Review demo mode (see README). Kept in this
/// file per `AGENTS.md`'s localization note — demo fixture data is real
/// user-visible copy, not a test-only value.
extension EventSession {
  /// `id` is the event code the scan machine matches on, not display copy —
  /// it stays a literal. `name` and `venue` are what the card actually
  /// renders, so they resolve through the String Catalog like any other
  /// user-visible string; `EventSession` keeps them as `String` because a
  /// real event's name is its runtime event code, not authored copy.
  static let demoSample = EventSession(
    id: "ETHGLOBALTOKYO-DEMO",
    name: String(
      localized: "ETHGlobal Tokyo",
      comment: "Event name shown on the demo event card. A real conference name, used as sample data in DemoEvent mode — translate it the way that conference would be referred to in the target language, or leave it as-is if it is normally written in Latin script."
    ),
    venue: String(
      localized: "Shibuya Hikarie",
      comment: "Venue name shown under the demo event name. A real Tokyo building; translate only if the target language has a conventional rendering of it."
    ),
    identityVerification: .notChecked
  )
}
