// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// The observed, pre-recording session. Its first sighting is 05a; when the
/// same real session has remained here for 20 seconds, the shared surface
/// reveals 05a2's manual-entry rescue without resetting a timer on redraw.
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
