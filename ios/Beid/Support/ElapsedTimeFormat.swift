// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// The "m:ss" elapsed-time text shared by the Now screen and the stop
/// confirmation. Minutes are not wrapped into hours (3600 s is "60:00").
enum ElapsedTimeFormat {
  static func minutesSeconds(_ seconds: TimeInterval) -> String {
    let elapsed = max(0, Int(seconds))
    return "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
  }
}
