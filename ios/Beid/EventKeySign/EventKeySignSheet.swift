// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// The one screen between a web page's signing request and the event key.
///
/// It shows only fields the app decoded itself, never text the page
/// supplied. A claim shows the full recipient address in groups of four: a
/// truncated `0x12AB…9F3E` can be matched by a generated look-alike.
struct EventKeySignSheet: View {
  let request: EventKeySignCoordinator.Pending
  let onConfirm: () -> Void
  let onDecline: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.l) {
      VStack(alignment: .leading, spacing: DS.Space.s) {
        Text(title)
          .font(DS.Font.sectionTitle)
          .foregroundStyle(DS.Color.textPrimary)
        Text(verbatim: request.eventTitle)
          .font(DS.Font.body)
          .foregroundStyle(DS.Color.textPrimary)
      }

      if case let .claim(chainId, contract, recipient) = request.purpose {
        VStack(alignment: .leading, spacing: DS.Space.m) {
          field("Recipient", value: Self.grouped(recipient))
          field("Network", value: Self.networkName(chainId: chainId))
          field("Contract", value: Self.grouped(contract))
        }
      }

      Text(explanation)
        .font(DS.Font.supporting)
        .foregroundStyle(DS.Color.textSecondary)

      Spacer(minLength: 0)

      VStack(spacing: DS.Space.s) {
        BeidPrimaryButton(confirmTitle, action: onConfirm)
          .accessibilityIdentifier("eventKeySign.confirm")
        BeidSecondaryButton(title: "Not now", action: onDecline)
          .accessibilityIdentifier("eventKeySign.decline")
      }
    }
    .padding(DS.Space.pageMargin)
    .frame(maxWidth: DS.Layout.stateContentMaxWidth, alignment: .leading)
    .background(DS.Color.surfaceCanvas)
    .interactiveDismissDisabled()
  }

  private var title: LocalizedStringKey {
    switch request.purpose {
    case .personhoodBinding: "Confirm you are one person"
    case .claim: "Send your event record"
    }
  }

  private var confirmTitle: LocalizedStringKey {
    switch request.purpose {
    case .personhoodBinding: "Confirm"
    case .claim: "Send record"
    }
  }

  private var explanation: LocalizedStringKey {
    switch request.purpose {
    case .personhoodBinding:
      "The result goes to \(request.callbackHost). Your record for this event will be linked to this check."
    case .claim:
      "The result goes to \(request.callbackHost). Only continue if the recipient above is an address you chose. This links that address to your record for this event."
    }
  }

  private func field(_ label: LocalizedStringKey, value: String) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      Text(label)
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.textSecondary)
      Text(verbatim: value)
        .font(DS.Font.ledgerMono)
        .foregroundStyle(DS.Color.textPrimary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }

  /// `0x12ab34cd…` → `0x12AB 34CD …`, every character shown.
  static func grouped(_ address: String) -> String {
    let digits = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
    var groups: [String] = []
    var index = digits.startIndex
    while index < digits.endIndex {
      let next = digits.index(index, offsetBy: 4, limitedBy: digits.endIndex) ?? digits.endIndex
      groups.append(String(digits[index..<next]).uppercased())
      index = next
    }
    return "0x" + groups.joined(separator: " ")
  }

  static func networkName(chainId: String) -> String {
    switch chainId {
    case "1": "Ethereum"
    case "11155111": "Sepolia (test network)"
    default: "Network \(chainId)"
    }
  }
}

/// Presents the pending request and any refusal. Applied once at the root.
struct EventKeySignPresentation: ViewModifier {
  @ObservedObject var coordinator: EventKeySignCoordinator

  func body(content: Content) -> some View {
    content
      .sheet(item: Binding(get: { coordinator.pending }, set: { _ in })) { request in
        EventKeySignSheet(request: request, onConfirm: coordinator.approve, onDecline: coordinator.decline)
          .presentationDetents([.large])
      }
      .alert(item: $coordinator.failure) { failure in
        Alert(title: Text(Self.message(for: failure)))
      }
  }

  private static func message(for failure: EventKeySignCoordinator.Failure) -> LocalizedStringKey {
    switch failure {
    case .eventNotOnThisPhone: "This event isn't recorded on this phone."
    case .keyMismatch: "This request is for a different phone."
    case .unavailable: "This request can't be completed here."
    }
  }
}
