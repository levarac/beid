// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Screen 06d: Signal Lost — a pause, not a restart. `peersVerified` is
/// frozen but preserved (never reset) while signal is lost — see
/// `docs/specs/scan-slice2-redesign.md` §5.4.
struct SignalLostView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  let event: EventSession
  let peersVerified: Int
  let onRetryVerification: () -> Void

  init(
    event: EventSession,
    peersVerified: Int,
    onRetryVerification: @escaping () -> Void = {}
  ) {
    self.event = event
    self.peersVerified = peersVerified
    self.onRetryVerification = onRetryVerification
  }

  var body: some View {
    SensingSessionSurface(
      sensing: coordinator.sensingCoordinator,
      event: event,
      presentation: .signalLost,
      onRetryVerification: onRetryVerification,
      onResume: { coordinator.sensingCoordinator.resumeSensing() }
    )
    .tint(DS.Color.actionPrimary)
  }

}

#Preview {
  SignalLostView(event: .demoSample, peersVerified: 5).environmentObject(AppCoordinator())
}
