// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Interim stand-in for the merged 06b/06c `.recording` phase — reuses the
/// pre-Slice-2 "Verifying" screen shell with the model changes needed to
/// compile against `EventSession`/the merged phase (sub-slice 2a); its
/// full visual redesign into `RecordingView` is sub-slice 2c.
struct VerifyingView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  let event: EventSession
  let peersVerified: Int

  var body: some View {
    BeidStatusLayout(
      systemImage: "person.2.wave.2.fill",
      title: "Verifying proof",
      message: "Nearby peers are confirming your attendance automatically.",
      accessory: {
      BeidPanel {
        VStack(alignment: .leading, spacing: BeidDesign.Spacing.content) {
          Text(event.name)
            .font(DS.Font.cardTitle)
            .fixedSize(horizontal: false, vertical: true)

          // No fixed denominator exists anymore (§4.2 drops
          // `totalPeersToVerify`), so this is an indeterminate indicator,
          // not `ProgressView(value:)` — the fixed-fraction bar's full
          // removal across the scan flow is sub-slice 2c.
          ProgressView {
            Text(peersVerifiedCaption)
              .font(DS.Font.supporting)
              .foregroundStyle(DS.Color.textSecondary)
          }
          .tint(DS.Color.signalActive)
        }
      }
      },
      footer: {
      // Demo-mode-only affordance so the Signal Lost screen stays
      // reachable even though the golden EventSession path keeps
      // recording indefinitely otherwise.
      Button("Simulate Signal Lost", role: .destructive) {
        BeidDesign.haptic(.medium)
        coordinator.sensingCoordinator.simulateSignalLost()
      }
      .font(.footnote)
      }
    )
    // Sensing screen: DESIGN.md §5 "one motif accent per screen".
    .tint(DS.Color.signalActive)
  }

  private var peersVerifiedCaption: String {
    String(
      localized: "scan.verifying.peersVerifiedCount",
      defaultValue: "\(peersVerified) peers verified",
      comment: "Cumulative count of distinct peers who have mutually sensed this device at the event; no fixed target."
    )
  }
}

#Preview {
  VerifyingView(event: .demoSample, peersVerified: 1).environmentObject(AppCoordinator())
}

#Preview("Dark") {
  VerifyingView(event: .demoSample, peersVerified: 1)
    .environmentObject(AppCoordinator())
    .preferredColorScheme(.dark)
}

#Preview("Growing") {
  VerifyingView(event: .demoSample, peersVerified: 7)
    .environmentObject(AppCoordinator())
}
