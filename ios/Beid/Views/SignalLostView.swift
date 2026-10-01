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
    BeidStatusLayout(
      title: "Signal Lost",
      message: "beid lost the connection to \(event.name). Move closer and we'll pick it back up automatically.",
      accessory: {
      VStack(spacing: DS.Space.m) {
        BeidStatusPill(state: .sensingPaused)
        EventCardView(event: event, badge: .paused) {
          VStack(alignment: .leading, spacing: DS.Space.xs) {
            EventIdentityVerificationRow(
              status: event.identityVerification,
              onRetry: onRetryVerification
            )
            // Same corrected count and same label as Proof Detail — one number
            // must not carry two labels. See beid#154.
            BeidMetricRow(label: "detail.devicesSensed.label", verbatimValue: "\(peersVerified)")
          }
        }
      }
      },
      footer: {
      // "Try Again" keeps its exact label (DESIGN.md §11 requires
      // SignalLostView to always offer it), but the handler it calls
      // resumes the same session in place — never `startSensing`, which
      // would discard `peersVerified` and re-create the `Proof` (§5.4).
      BeidPrimaryButton("Try Again") {
        coordinator.sensingCoordinator.resumeSensing()
      }
      }
    )
    // Recovery screen: "Try Again" takes the actionPrimary tint — Flat 2b
    // has one ink and no per-screen motif accents (DESIGN.md §5).
    .tint(DS.Color.actionPrimary)
  }
}

#Preview {
  SignalLostView(event: .demoSample, peersVerified: 5).environmentObject(AppCoordinator())
}
