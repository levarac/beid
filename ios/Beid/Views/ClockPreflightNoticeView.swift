// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// The presentation contract for beid#464's device-clock notice. The verdict
/// is shared's (`clockPreflightStateKey`); this only chooses the words, which
/// match Android's `clock_preflight_*` strings.
struct ClockPreflightPresentation: Equatable {
  static let noticeAccessibilityIdentifier = "scan.clock-preflight"
  static let retryAccessibilityIdentifier = "scan.clock-preflight.retry"

  let title: LocalizedStringKey
  let message: LocalizedStringKey
  let statusAccessibilityIdentifier: String

  /// nil while the first check runs and when the clock is within tolerance.
  /// A key shared adds later without this switch being updated is shown as
  /// undeterminable: saying "couldn't check" is never false, silence could be.
  static func forStateKey(_ key: String?) -> ClockPreflightPresentation? {
    switch key {
    case nil, "withinTolerance":
      return nil
    case "overTolerance":
      return ClockPreflightPresentation(
        title: "This device's clock is off",
        message: "beid can't trust event times while the clock is wrong. Turn on automatic date and time in Settings, then check again.",
        statusAccessibilityIdentifier: "scan.clock-preflight.over-tolerance"
      )
    default:
      return ClockPreflightPresentation(
        title: "Couldn't check this device's clock",
        message: "beid couldn't compare the clock with the network, so event times can't be trusted yet. Check your connection, then try again.",
        statusAccessibilityIdentifier: "scan.clock-preflight.undeterminable"
      )
    }
  }
}

/// Rendered above the nearby list on the pre-join Scan screen (DESIGN.md §15:
/// what happened, one action). It informs and never blocks joining: neither
/// clock state refused a join before the Flat 2b redesign, and Android's
/// `ClockPreflightNotice` does not either.
struct ClockPreflightNoticeView: View {
  @ObservedObject var preflight: ClockPreflightController

  var body: some View {
    ClockPreflightNotice(stateKey: preflight.stateKey) {
      Task { await preflight.check(force: true) }
    }
  }
}

/// Stateless body of the notice, so previews do not need a controller.
struct ClockPreflightNotice: View {
  let stateKey: String?
  let onRetry: () -> Void

  @ViewBuilder
  var body: some View {
    if let presentation = ClockPreflightPresentation.forStateKey(stateKey) {
      BeidPanel {
        VStack(alignment: .leading, spacing: DS.Space.s) {
          Text(presentation.title)
            .font(DS.Font.cardTitle)
            .foregroundStyle(DS.Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(presentation.statusAccessibilityIdentifier)
          Text(presentation.message)
            .font(DS.Font.supporting)
            .foregroundStyle(DS.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
          // #631: a Flat 2b text control, not an accent-tinted button.
          BeidTextControl("Check again", accessibilityLabel: "Check again") {
            onRetry()
          }
          .accessibilityIdentifier(ClockPreflightPresentation.retryAccessibilityIdentifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(ClockPreflightPresentation.noticeAccessibilityIdentifier)
    }
  }
}

#Preview("Clock preflight notices") {
  VStack(spacing: DS.Space.m) {
    ClockPreflightNotice(stateKey: "overTolerance") {}
    ClockPreflightNotice(stateKey: "undeterminable") {}
  }
  .padding()
}
