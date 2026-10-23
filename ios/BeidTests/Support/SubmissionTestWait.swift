// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

enum SubmissionTestWait {
  // A loopback request also schedules KMP work; receipt verification continues
  // after the server sees it. Ten seconds was insufficient on macos-26.
  static let timeout: TimeInterval = 30

  /// Yield while observing progress, with a monotonic deadline rather than an
  /// iteration count. A successful operation never pays the full timeout.
  @MainActor
  static func until(
    timeout: TimeInterval = timeout,
    _ condition: () throws -> Bool
  ) async throws -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while true {
      try Task.checkCancellation()
      if try condition() { return true }
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else { return false }
      try await Task.sleep(nanoseconds: UInt64(min(remaining, 0.05) * 1_000_000_000))
    }
  }
}
