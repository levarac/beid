// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// The presentation contract for the event-registry status row. Keeping this
/// mapping pure makes visibility, copy, status styling, and retry affordance
/// testable without starting asynchronous work from a SwiftUI body.
struct EventIdentityVerificationPresentation: Equatable {
  static let rowAccessibilityIdentifier = "event-identity-verification-row"
  static let retryButtonKey = "event.identityVerification.retry"
  static let retryButtonDefaultMessage = "Retry event registry verification"
  static let retryAccessibilityIdentifier = "event-identity-verification-retry"

  let messageKey: String
  let defaultMessage: String
  let statusAccessibilityIdentifier: String
  let showsProgress: Bool
  let showsRetry: Bool
  let isVerified: Bool

  static func forStatus(
    _ status: EventIdentityVerification
  ) -> EventIdentityVerificationPresentation? {
    switch status {
    case .notChecked:
      return nil
    case .checking:
      return EventIdentityVerificationPresentation(
        messageKey: "event.identityVerification.checking",
        defaultMessage: "Checking event registry…",
        statusAccessibilityIdentifier: "event-identity-verification-status-checking",
        showsProgress: true,
        showsRetry: false,
        isVerified: false
      )
    case .verified:
      return EventIdentityVerificationPresentation(
        messageKey: "event.identityVerification.verified",
        defaultMessage: "Event identity verified",
        statusAccessibilityIdentifier: "event-identity-verification-status-verified",
        showsProgress: false,
        showsRetry: false,
        isVerified: true
      )
    case .unavailable:
      return EventIdentityVerificationPresentation(
        messageKey: "event.identityVerification.unavailable",
        defaultMessage: "Event registry is temporarily unavailable.",
        statusAccessibilityIdentifier: "event-identity-verification-status-unavailable",
        showsProgress: false,
        showsRetry: true,
        isVerified: false
      )
    case .notFound:
      return EventIdentityVerificationPresentation(
        messageKey: "event.identityVerification.notFound",
        defaultMessage: "No registry definition was found for this event.",
        statusAccessibilityIdentifier: "event-identity-verification-status-not-found",
        showsProgress: false,
        showsRetry: true,
        isVerified: false
      )
    }
  }
}

/// Inline status row shown beneath the event card's existing caption content.
/// It never resolves anything itself; the coordinator owns lookup lifecycle
/// and the row only invokes the injected retry action when available.
struct EventIdentityVerificationRow: View {
  let status: EventIdentityVerification
  let onRetry: () -> Void

  init(
    status: EventIdentityVerification,
    onRetry: @escaping () -> Void = {}
  ) {
    self.status = status
    self.onRetry = onRetry
  }

  @ViewBuilder
  var body: some View {
    if let presentation = EventIdentityVerificationPresentation.forStatus(status) {
      VStack(alignment: .leading, spacing: DS.Space.xs) {
        statusView(presentation)

        if presentation.showsRetry {
          Button {
            BeidDesign.haptic()
            onRetry()
          } label: {
            Text(LocalizedStringKey(EventIdentityVerificationPresentation.retryButtonKey))
              .font(DS.Font.meta.weight(.semibold))
              .frame(
                minWidth: DS.Size.minHitTarget,
                minHeight: DS.Size.minHitTarget,
                alignment: .leading
              )
              .contentShape(Rectangle())
          }
          .buttonStyle(.borderless)
          .tint(DS.Color.actionPrimary)
          .accessibilityIdentifier(
            EventIdentityVerificationPresentation.retryAccessibilityIdentifier
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func statusView(
    _ presentation: EventIdentityVerificationPresentation
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
      if presentation.showsProgress {
        ProgressView()
          .controlSize(.small)
          .tint(statusColor(for: presentation))
          .accessibilityHidden(true)
      }

      Text(LocalizedStringKey(presentation.messageKey))
        .font(DS.Font.meta)
        .foregroundStyle(statusColor(for: presentation))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(presentation.statusAccessibilityIdentifier)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(EventIdentityVerificationPresentation.rowAccessibilityIdentifier)
  }

  private func statusColor(
    for presentation: EventIdentityVerificationPresentation
  ) -> Color {
    presentation.isVerified ? DS.Color.textPrimary : DS.Color.textSecondary
  }
}

#Preview("Verification statuses") {
  VStack(alignment: .leading, spacing: DS.Space.m) {
    ForEach(
      [
        EventIdentityVerification.notChecked,
        .checking,
        .verified,
        .unavailable,
        .notFound
      ],
      id: \.self
    ) { status in
      EventIdentityVerificationRow(status: status)
    }
  }
  .padding()
}
