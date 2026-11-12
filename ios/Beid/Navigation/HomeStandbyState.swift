// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// A visible, uninterrupted empty-discovery interval, measured by uptime.
/// This is presentation timing; event eligibility remains in shared code.
struct HomeStandbyState: Equatable {
  private(set) var listeningStartedAt: TimeInterval?

  mutating func update(isEnabled: Bool, hasCandidates: Bool, now: TimeInterval) {
    guard isEnabled, !hasCandidates else {
      listeningStartedAt = nil
      return
    }
    if listeningStartedAt == nil { listeningStartedAt = now }
  }

  func elapsed(at now: TimeInterval) -> TimeInterval {
    guard let listeningStartedAt else { return 0 }
    return max(0, now - listeningStartedAt)
  }

  func offersCodeEntry(at now: TimeInterval) -> Bool {
    listeningStartedAt != nil && elapsed(at: now) >= 30
  }
}

enum HomeTab: Hashable {
  case now
  case records
}

/// Display metadata retained from an eligible event, never join authority.
struct HomeEventRegistration {
  let name: String
  let startsAt: Date
  let endsAt: Date
}
