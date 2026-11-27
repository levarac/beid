// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// Presentation-only translation between demo window indices and wall time.
enum SensingWindowTimeline {
  static func endIndex(now: Date?, lastObserved: Int64?, demoCurrent: Int64?, windowSeconds: TimeInterval) -> Int64? {
    if let demoCurrent { return demoCurrent }
    if let now { return Int64(floor(now.timeIntervalSince1970 / windowSeconds)) }
    return lastObserved
  }

  static func oldestStart(
    end: Int64, firstObserved: Int64?, firstSighting: Date?, isDemo: Bool,
    windowSeconds: TimeInterval, slotCount: Int
  ) -> Date? {
    let oldest = end - Int64(slotCount - 1)
    if isDemo {
      guard let firstObserved, let firstSighting else { return nil }
      let anchor = floor(firstSighting.timeIntervalSince1970 / windowSeconds) * windowSeconds
      return Date(timeIntervalSince1970: anchor + TimeInterval(oldest - firstObserved) * windowSeconds)
    }
    return Date(timeIntervalSince1970: TimeInterval(oldest) * windowSeconds)
  }
}
