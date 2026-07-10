// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Wallet-optional fallback reached from `WalletConnectView`'s secondary
/// action: joins an event by manually entered code (calling the vendored
/// Barnard SDK's `BarnardEngine.joinEvent` via `SensingCoordinator`) instead
/// of connecting a wallet, then continues onboarding exactly where
/// `completeWalletConnect()` does.
struct EventCodeEntryView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.dismiss) private var dismiss
  @State private var code = ""
  @State private var errorMessage: LocalizedStringKey?
  @FocusState private var codeFieldFocused: Bool

  var body: some View {
    BeidAdaptiveContent {
      VStack(spacing: DS.Space.l) {
        Spacer()

        BeidHeroHeader(
          systemImage: "number",
          title: "Enter Event Code",
          subtitle: "Ask the event organizer for the code. This joins the event directly, without connecting a wallet.",
          tint: DS.Color.actionPrimary
        )

        BeidPanel {
          VStack(alignment: .leading, spacing: DS.Space.s) {
            TextField("Event code", text: $code, prompt: Text("e.g. ETHTOKYO2026"))
              .font(DS.Font.body)
              .foregroundStyle(DS.Color.textPrimary)
              .textInputAutocapitalization(.characters)
              .autocorrectionDisabled()
              .submitLabel(.join)
              .focused($codeFieldFocused)
              .padding(DS.Space.m)
              .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                  .fill(DS.Color.surfaceRaised)
              )
              .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                  .strokeBorder(DS.Color.strokeHairline, lineWidth: 1)
              )
              .onSubmit(submit)
              .onChange(of: code) { _, _ in errorMessage = nil }

            if let errorMessage {
              HStack(alignment: .top, spacing: DS.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundStyle(DS.Color.textPrimary)
                  .accessibilityHidden(true)
                Text(errorMessage)
                  .font(DS.Font.supporting)
                  .foregroundStyle(DS.Color.textPrimary)
              }
            }
          }
        }

        Spacer()

        BeidPrimaryButton("Join Event", systemImage: "checkmark.circle", action: submit)
          .tint(DS.Color.actionPrimary)
          .padding(.horizontal, DS.Space.pageMargin)
          .padding(.bottom, DS.Space.xl)
      }
    }
    .onAppear { codeFieldFocused = true }
  }

  private func submit() {
    errorMessage = message(for: coordinator.joinEvent(code: code))
  }

  private func message(for error: EventCodeJoinError?) -> LocalizedStringKey? {
    switch error {
    case nil:
      return nil
    case .emptyCode:
      return "Enter an event code to continue. Ask the event organizer for it."
    case .joinFailed:
      return "beid couldn't join that event. Check the code and try again."
    }
  }
}

#Preview {
  EventCodeEntryView().environmentObject(AppCoordinator())
}

#Preview("Dark") {
  EventCodeEntryView()
    .environmentObject(AppCoordinator())
    .preferredColorScheme(.dark)
}
