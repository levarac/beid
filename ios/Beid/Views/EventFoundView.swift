// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Initial detection shares the live sensing surface and its explanation
/// link. Returning to Now leaves this participation running.
struct EventFoundView: View {
  @ObservedObject var sensing: SensingCoordinator
  let event: EventSession
  let onRetryVerification: () -> Void

  init(
    sensing: SensingCoordinator,
    event: EventSession,
    onRetryVerification: @escaping () -> Void = {}
  ) {
    self.sensing = sensing
    self.event = event
    self.onRetryVerification = onRetryVerification
  }

  var body: some View {
    SensingSessionSurface(
      sensing: sensing,
      event: event,
      presentation: .detecting,
      onRetryVerification: onRetryVerification
    )
    .tint(DS.Color.actionInverse)
  }
}

#Preview {
  let coordinator = AppCoordinator()
  return EventFoundView(sensing: coordinator.sensingCoordinator, event: .demoSample)
}
