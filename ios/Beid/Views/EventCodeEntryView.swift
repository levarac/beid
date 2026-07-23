// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Wallet-optional fallback reached from `WalletConnectView`'s secondary
/// action: joins an event by manually entered code (calling the Barnard
/// SDK's `BarnardEngine.joinEvent` via `SensingCoordinator`) instead
/// of connecting a wallet, then continues onboarding exactly where
/// `completeWalletConnect()` does.
struct EventCodeEntryView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @State private var code: String
  @State private var errorMessage: LocalizedStringKey?
  @FocusState private var codeFieldFocused: Bool

  /// `code`/`errorMessage` defaults reproduce the view's normal empty
  /// starting state; the parameters exist so previews can seed the error
  /// state without faking a `submit()` tap.
  init(code: String = "", errorMessage: LocalizedStringKey? = nil) {
    _code = State(initialValue: code)
    _errorMessage = State(initialValue: errorMessage)
  }

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
              .tint(DS.Color.actionPrimary)
              .accessibilityIdentifier("Event code")
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

        VStack(spacing: DS.Space.s) {
          BeidPrimaryButton("Join Event", systemImage: "checkmark.circle", action: submit)
            .tint(DS.Color.actionPrimary)

          BeidSecondaryButton(title: "Connect wallet instead") {
            coordinator.returnToWalletConnect()
          }
          .tint(DS.Color.actionPrimary)
        }
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

#Preview("Error") {
  EventCodeEntryView(
    code: "BADCODE",
    errorMessage: "beid couldn't join that event. Check the code and try again."
  )
  .environmentObject(AppCoordinator())
}
