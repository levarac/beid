// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Owns every asynchronous lifecycle callback started by the venue-serving
/// view. A new notification must not hide the handle for an older callback:
/// disappearance and an explicit stop need to be able to cancel all of them.
@MainActor
final class VenueLifecycleTaskOwner: ObservableObject {
  private var tasks: [UUID: Task<Void, Never>] = [:]

  var taskCount: Int { tasks.count }

  @discardableResult
  func start(_ operation: @escaping @MainActor () async -> Void) -> UUID {
    let id = UUID()
    let task = Task { @MainActor [weak self] in
      await operation()
      self?.remove(id)
    }
    tasks[id] = task
    return id
  }

  func cancelAll() {
    let running = tasks.values
    tasks.removeAll()
    running.forEach { $0.cancel() }
  }

  private func remove(_ id: UUID) {
    tasks.removeValue(forKey: id)
  }
}
