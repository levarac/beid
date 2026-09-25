// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit

/// Manual entry shared by wallet-optional onboarding, Account, and scan rescue.
struct EventCodeEntryView: View {
  /// Screen 13/13b's measured offsets in the 402 × 874 Figma frames.
  private enum Layout {
    static let rootTitleTop: CGFloat = 40
    static let pushedTitleTop: CGFloat = 6
    static let subtitleTop: CGFloat = 22
    static let fieldTop: CGFloat = 34
    static let fieldLabelOverlap: CGFloat = -8
    static let noteTop: CGFloat = 12
    static let detailTop: CGFloat = 9
    static let errorDotGap: CGFloat = 7
    static let footerBottom: CGFloat = 6
  }

  enum Mode: Equatable {
    case onboarding
    case accountSheet
    /// Reached from the 04b Home empty state. Shares the existing post-
    /// onboarding join behavior, but dismisses Home's own sheet on success.
    case home
    /// Pushed inside `ScanFlowView` as the rescue route when nearby discovery
    /// finds no joinable card. Success keeps the full-screen flow presented,
    /// starts sensing through the existing operator-lookup gate, and pops this
    /// manual-entry screen back to the phase content.
    case scanFlow
  }

  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.dismiss) private var dismiss
  @State private var code: String
  @State private var errorMessage: LocalizedStringKey?
  @State private var errorKind: EventCodeJoinError?
  @FocusState private var codeFieldFocused: Bool
  @ScaledMetric(relativeTo: .largeTitle) private var fieldMinHeight: CGFloat = 52
  private let mode: Mode

  init(code: String = "", errorMessage: LocalizedStringKey? = nil, mode: Mode = .onboarding) {
    #if DEBUG
    // Both launch arguments are required; normal launches never see samples.
    let fixture = AppCoordinator.eventCodeScreenshotFixture
    _code = State(initialValue: fixture?.code ?? code)
    _errorMessage = State(initialValue: fixture?.hasError == true
      ? "beid couldn't join that event. Check the code and try again."
      : errorMessage)
    _errorKind = State(initialValue: fixture?.hasError == true || errorMessage != nil
      ? .joinFailed : nil)
    #else
    _code = State(initialValue: code)
    _errorMessage = State(initialValue: errorMessage)
    _errorKind = State(initialValue: errorMessage == nil ? nil : .joinFailed)
    #endif
    self.mode = mode
  }

  private var isScreenshotFixture: Bool {
    #if DEBUG
    AppCoordinator.eventCodeScreenshotFixture != nil
    #else
    false
    #endif
  }

  var body: some View {
    ZStack {
      DS.Color.surfaceCanvas.ignoresSafeArea()

      BeidAdaptiveContent {
        VStack(spacing: 0) {
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              title

              Text("Only needed if an event didn’t appear automatically. Ask the organizer for the code.")
                .beidTextStyle(DS.Font.Library.body15)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Layout.subtitleTop)

              codeEntry
                .padding(.top, Layout.fieldTop)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, mode == .onboarding ? Layout.rootTitleTop : Layout.pushedTitleTop)
            .padding(.horizontal, DS.Space.pageMargin)
          }
          .scrollDismissesKeyboard(.interactively)

          VStack(spacing: DS.Space.s) {
            EventCodeJoinButton(action: submit)

            if mode == .onboarding && !isScreenshotFixture {
              BeidSecondaryButton(title: "Connect wallet instead") {
                coordinator.returnToWalletConnect()
              }
              .tint(DS.Color.actionPrimary)
            }
          }
          .padding(.horizontal, DS.Space.pageMargin)
          .padding(.bottom, Layout.footerBottom)
        }
      }
    }
    .onAppear { codeFieldFocused = !isScreenshotFixture }
  }

  private var title: some View {
    Text("Enter\nevent code")
      .beidTextStyle(DS.Font.Library.display52)
      .foregroundStyle(DS.Color.textPrimary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("eventCode.title")
  }

  private var codeEntry: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        Text("Event code")
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondary)

        Spacer()

        Button {
          BeidDesign.haptic()
          if let pastedCode = UIPasteboard.general.string {
            code = pastedCode
          }
        } label: {
          Text("Paste")
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textPrimary)
            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Clear text case for the spoken label. The inner Text's mono style
        // reapplies uppercase only to the visible PASTE.
        .textCase(nil)
        .accessibilityLabel(Text("Paste event code"))
        .accessibilityIdentifier("eventCode.paste")
      }
      .frame(minHeight: 44)

      TextField("Event code", text: $code, prompt: Text("e.g. ETHTOKYO2026"))
        .beidTextStyle(DS.Font.Library.displayAddress34)
        .foregroundStyle(DS.Color.textPrimary)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .submitLabel(.join)
        .focused($codeFieldFocused)
        .tint(DS.Color.textPrimary)
        .accessibilityIdentifier("Event code")
        .frame(minHeight: fieldMinHeight)
        .overlay(alignment: .leading) {
          if isScreenshotFixture {
            // Figma shows a caret without a keyboard. Ordinary entry focuses.
            Rectangle()
              .fill(DS.Color.textPrimary)
              .frame(width: 2, height: 40)
              .offset(x: 240)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
        .onSubmit(submit)
        .onChange(of: code) { _, _ in
          errorMessage = nil
          errorKind = nil
        }
        .padding(.top, Layout.fieldLabelOverlap)

      Rectangle()
        .fill(errorMessage == nil ? DS.Color.textPrimary : DS.Color.statusOff)
        .frame(height: 2)

      if let errorMessage {
        // TODO(#648): A generic joinFailed cannot establish Figma's
        // "CODE NOT RECOGNIZED". Show it only if a specific reason is exposed.
        HStack(spacing: Layout.errorDotGap) {
          Circle()
            .fill(DS.Color.statusOff)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
          if errorKind == .emptyCode {
            Text("Event code required")
              .beidTextStyle(DS.Font.Library.labelMono10)
              .foregroundStyle(DS.Color.textPrimary)
          } else {
            Text("COULD NOT JOIN EVENT")
              .beidTextStyle(DS.Font.Library.labelMono10)
              .foregroundStyle(DS.Color.textPrimary)
          }
        }
        .padding(.top, Layout.noteTop)

        Text(errorMessage)
          .beidTextStyle(DS.Font.Library.body13)
          .foregroundStyle(DS.Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, Layout.detailTop)
      } else {
        Text("Codes are case-insensitive")
          .beidTextStyle(DS.Font.Library.labelMono9)
          .foregroundStyle(DS.Color.textSecondary)
          .padding(.top, Layout.noteTop)
      }
    }
  }

  /// Capture the typed code before awaiting lookup. Superseded attempts must
  /// never overwrite a newer attempt's error or navigation state.
  private func submit() {
    let submittedCode = code
    Task { @MainActor in
      let outcome: AppCoordinator.JoinAttemptOutcome
      switch mode {
      case .onboarding:
        outcome = await coordinator.joinEventResolvingCanonicalId(code: submittedCode)
      case .accountSheet:
        outcome = await coordinator.joinEventFromAccountSheetResolvingCanonicalId(code: submittedCode)
      case .home:
        outcome = await coordinator.joinEventFromHomeResolvingCanonicalId(code: submittedCode)
      case .scanFlow:
        outcome = await coordinator.joinEventFromScanFlowResolvingCanonicalId(code: submittedCode)
      }
      guard case .completed(let error) = outcome else { return }
      errorKind = error
      errorMessage = message(for: error)
      if mode == .scanFlow, error == nil {
        dismiss()
      }
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
    }
  }
}

/// Frame 13's full-width 56 pt ink capsule. Keep the current button case
/// until #24 settles it; this view owns the shape while #643 is unmerged.
private struct EventCodeJoinButton: View {
  let action: () -> Void

  var body: some View {
    Button {
      BeidDesign.haptic()
      action()
    } label: {
      Text("Join Event")
        .beidTextStyle(DS.Font.Library.title16)
        .foregroundStyle(DS.Color.labelOnActionPrimary)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(DS.Color.actionPrimary, in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

#Preview {
  EventCodeEntryView().environmentObject(AppCoordinator())
}

#Preview("Error") {
  EventCodeEntryView(
    code: "BADCODE",
    errorMessage: "beid couldn't join that event. Check the code and try again."
  )
  .environmentObject(AppCoordinator())
}
