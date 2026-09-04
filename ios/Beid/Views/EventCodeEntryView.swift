// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Wallet-optional fallback reached from `WalletConnectView`'s secondary
/// action: joins an event by manually entered code (calling the Barnard
/// SDK's `BarnardEngine.joinEvent` via `SensingCoordinator`) instead
/// of connecting a wallet, then continues onboarding exactly where
/// `completeWalletConnect()` does.
struct EventCodeEntryView: View {
  /// Where this view is being presented from, and therefore which
  /// coordinator call `submit()` makes and whether the wallet-connect
  /// secondary action applies. `.onboarding` reproduces the view's original
  /// (and only, pre-#101-fix) behavior exactly.
  enum Mode: Equatable {
    /// Reached via `WalletConnectView`'s secondary action during onboarding.
    /// `submit()` calls `coordinator.joinEvent(code:)`, which advances
    /// `screen` to `.bluetoothPermission` on success. The "Connect wallet
    /// instead" secondary button is shown.
    case onboarding
    /// Reached via the Account sheet's "Join Event" action, for a user
    /// already past onboarding. `submit()` calls
    /// `coordinator.joinEventFromAccountSheet(code:)`, which dismisses the
    /// sheet on success without touching `screen`. The secondary button is
    /// not shown — the presenting sheet's own Cancel toolbar button is the
    /// escape hatch instead.
    case accountSheet
  }

  @EnvironmentObject private var coordinator: AppCoordinator
  @State private var code: String
  @State private var errorMessage: LocalizedStringKey?
  @FocusState private var codeFieldFocused: Bool
  private let mode: Mode

  /// `code`/`errorMessage` defaults reproduce the view's normal empty
  /// starting state; the parameters exist so previews can seed the error
  /// state without faking a `submit()` tap. `mode` defaults to `.onboarding`
  /// so the existing onboarding call site needs no change.
  init(code: String = "", errorMessage: LocalizedStringKey? = nil, mode: Mode = .onboarding) {
    _code = State(initialValue: code)
    _errorMessage = State(initialValue: errorMessage)
    self.mode = mode
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

          if mode == .onboarding {
            BeidSecondaryButton(title: "Connect wallet instead") {
              coordinator.returnToWalletConnect()
            }
            .tint(DS.Color.actionPrimary)
          }
        }
        .padding(.horizontal, DS.Space.pageMargin)
        .padding(.bottom, DS.Space.xl)
      }
    }
    .onAppear { codeFieldFocused = true }
  }

  /// Resolves a canonical Event ID for the typed code (beid#258 P1-1 —
  /// best-effort, bounded by the lookup's own timeout, never blocks on an
  /// unbounded hang) before joining, so the normal manual-entry path
  /// carries a lookup-derived ID instead of always joining with `nil`.
  /// `code` is captured once into `submittedCode` before the `Task` starts:
  /// `AppCoordinator`'s composed methods take it as a plain value and never
  /// re-read this view's live `@State`, but capturing it here too keeps that
  /// guarantee visible at the call site rather than relying on it silently.
  private func submit() {
    let submittedCode = code
    Task { @MainActor in
      let outcome: AppCoordinator.JoinAttemptOutcome
      switch mode {
      case .onboarding:
        outcome = await coordinator.joinEventResolvingCanonicalId(code: submittedCode)
      case .accountSheet:
        outcome = await coordinator.joinEventFromAccountSheetResolvingCanonicalId(code: submittedCode)
      }
      // `.superseded` must not touch `errorMessage` at all — a stale attempt
      // resuming after a newer one (or a cancellation) started must never
      // overwrite whatever the current attempt already showed.
      guard case .completed(let error) = outcome else { return }
      errorMessage = message(for: error)
    }
  }

  private func message(for error: EventCodeJoinError?) -> LocalizedStringKey? {
    switch error {
    case nil:
      return nil
    case .emptyCode:
      return "Enter an event code to continue. Ask the event organizer for it."
    case .joinFailed:
      return "beid couldn't join that event. Check the code and try again."
    #if DEBUG || BEID_INTERNAL_DEMO
    case .reservedDemoCodeUnavailable:
      return "That demo scenario is not available in this build."
    #endif
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
