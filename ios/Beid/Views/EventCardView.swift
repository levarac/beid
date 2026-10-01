// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Shared event-summary panel: name + optional venue + a status
/// badge + a trailing caption slot. Used by `EventFoundView`,
/// `RecordingView`, and `SignalLostView` — see
/// `docs/specs/scan-slice2-redesign.md` §5.1/§6 "New eventCard component".
struct EventCardView<Caption: View>: View {
  /// Badge vocabulary: DETECTED / RECORDING / PAUSED. Drops
  /// VERIFYING/VERIFIED (§6 — those phases no longer exist). Badge text
  /// itself differs per state (never color alone, DESIGN.md §2.9).
  enum Badge: Equatable {
    case detected
    case recording
    case paused
  }

  let event: EventSession
  let badge: Badge
  @ViewBuilder var caption: () -> Caption

  init(event: EventSession, badge: Badge, @ViewBuilder caption: @escaping () -> Caption = { EmptyView() }) {
    self.event = event
    self.badge = badge
    self.caption = caption
  }

  var body: some View {
    BeidPanel {
      VStack(alignment: .leading, spacing: DS.Space.m) {
        HStack(alignment: .top, spacing: DS.Space.m) {
          VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(event.name)
              .font(DS.Font.cardTitle)
              .fixedSize(horizontal: false, vertical: true)

            if let venue = event.venue {
              Text(venue)
                .font(DS.Font.meta)
                .foregroundStyle(DS.Color.textSecondary)
            }
          }

          Spacer(minLength: DS.Space.s)

          badgeView
            .layoutPriority(1)
            .fixedSize()
        }

        caption()
      }
    }
  }

  @ViewBuilder
  private var badgeView: some View {
    switch badge {
    case .detected:
      badgeLabel(Text("DETECTED", comment: "Status badge on the event card during BLE sensing, not audio/video recording."))
    case .recording:
      badgeLabel(Text("RECORDING", comment: "Status badge on the event card during BLE sensing, not audio/video recording."))
    case .paused:
      badgeLabel(Text("PAUSED", comment: "Status badge on the event card during BLE sensing, not audio/video recording."))
    }
  }

  private func badgeLabel(_ text: Text) -> some View {
    text
      .font(DS.Font.meta.weight(.semibold))
      .foregroundStyle(.tint)
      .padding(.horizontal, DS.Space.s)
      .padding(.vertical, DS.Space.xs)
      .background(.tint.opacity(0.14), in: Capsule())
  }
}

#Preview("Detected") {
  EventCardView(event: .demoSample, badge: .detected) {
    Text("Verification starts automatically — stay nearby")
      .font(DS.Font.meta)
      .foregroundStyle(DS.Color.textSecondary)
  }
  .padding()
  .tint(DS.Color.actionPrimary)
}

#Preview("Recording") {
  EventCardView(event: .demoSample, badge: .recording) {
    Text("Recording your attendance automatically · 7 devices sensed")
      .font(DS.Font.meta)
      .foregroundStyle(DS.Color.textSecondary)
  }
  .padding()
  .tint(DS.Color.actionPrimary)
}

#Preview("Paused") {
  EventCardView(event: .demoSample, badge: .paused) {
    BeidMetricRow(label: "detail.devicesSensed.label", verbatimValue: "5")
  }
  .padding()
  .tint(DS.Color.actionPrimary)
}

#Preview("No venue, long name") {
  EventCardView(
    event: EventSession(id: "X", name: "A Very Long Conference Name That Should Wrap Gracefully", venue: nil),
    badge: .recording
  ) {
    Text("Recording your attendance automatically · 12 devices sensed")
      .font(DS.Font.meta)
      .foregroundStyle(DS.Color.textSecondary)
  }
  .padding()
  .tint(DS.Color.actionPrimary)
}
