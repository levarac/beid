// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import SwiftUI
import UIKit

/// One code-entry route owns its pending task. Consuming cancellation clears
/// that ownership so later disappearance cannot invalidate a newer route.
@MainActor
final class EventCodeEntrySubmission: ObservableObject {
  @Published var isSubmitting = false
  var task: Task<Void, Never>?

  func cancel(coordinator: AppCoordinator) {
    let wasSubmitting = isSubmitting
    task?.cancel()
    task = nil
    isSubmitting = false
    if wasSubmitting { coordinator.cancelPendingAccountSheetJoinAttempt() }
  }

  func presentationBinding(_ presented: Binding<Bool>, coordinator: AppCoordinator) -> Binding<Bool> {
    Binding(
      get: { presented.wrappedValue },
      set: { value in
        // Native Back and interactive pop write through this binding. Invalidate
        // before forwarding that write, rather than waiting for onDisappear.
        if !value, presented.wrappedValue { self.cancel(coordinator: coordinator) }
        presented.wrappedValue = value
      }
    )
  }
}

/// Both scan-flow entry points retain the system Back button and interactive
/// pop. Each push gets its own submission lifetime, including after a retry.
struct ScanFlowEventCodeEntryLink<Label: View>: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @State private var isPresented = false
  @State private var submission = EventCodeEntrySubmission()
  private let label: () -> Label

  init(@ViewBuilder label: @escaping () -> Label) {
    self.label = label
  }

  var body: some View {
    Button {
      submission = EventCodeEntrySubmission()
      isPresented = true
    } label: {
      label()
    }
    .navigationDestination(isPresented: submission.presentationBinding($isPresented, coordinator: coordinator)) {
      EventCodeEntryView(mode: .scanFlow, submission: submission)
        .id(ObjectIdentifier(submission))
    }
  }
}

/// Explicit code entry shared by onboarding, Account, Home, and the scan flow.
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
    /// Pushed inside `ScanFlowView` as manual entry when nearby discovery
    /// finds no joinable card. Success keeps the existing scan flow presented,
    /// starts sensing through the existing operator-lookup gate, and pops this
    /// manual-entry screen back to the phase content.
    case scanFlow
  }

  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.dismiss) private var dismiss
  @State private var code: String
  @State private var errorMessage: LocalizedStringKey?
  @State private var errorKind: EventCodeJoinError?
  @StateObject private var submission: EventCodeEntrySubmission
  @FocusState private var codeFieldFocused: Bool
  @ScaledMetric(relativeTo: .largeTitle) private var fieldMinHeight: CGFloat = 52
  private let mode: Mode

  init(
    code: String = "", errorMessage: LocalizedStringKey? = nil, mode: Mode = .onboarding,
    submission: EventCodeEntrySubmission? = nil
  ) {
    _submission = StateObject(wrappedValue: submission ?? EventCodeEntrySubmission())
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

  private var isSubmitting: Bool { submission.isSubmitting }

  var body: some View {
    ZStack {
      DS.Color.surfaceCanvas.ignoresSafeArea()

      BeidAdaptiveContent {
        VStack(spacing: 0) {
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              title

              Text("If your event is not listed, ask the organizer for its event code and paste it here.")
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
            if isSubmitting {
              Text("eventCode.lookup.pending")
                .beidTextStyle(DS.Font.Library.body13)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("eventCode.pending")
            }

            EventCodeJoinButton(action: submit)
              .disabled(isSubmitting)
              .accessibilityIdentifier("eventCode.join")

            #if DEBUG
            if EventCodeEntryProgressFixture.isEnabled {
              EventCodeEntryProgressFixtureControls(resubmit: submit)
            }
            #endif

            if mode == .onboarding && !isScreenshotFixture {
              BeidSecondaryButton(title: "Continue without a code") {
                coordinator.returnToBluetoothPermission()
              }
              .tint(DS.Color.actionPrimary)
            }
          }
          .padding(.horizontal, DS.Space.pageMargin)
          .padding(.bottom, Layout.footerBottom)
        }
      }
    }
    .onAppear {
      codeFieldFocused = !isScreenshotFixture
      #if DEBUG
      if EventCodeEntryProgressFixture.isEnabled {
        // Suspend the real generation-owned lookup, with no transport.
        coordinator.resolveCanonicalEventIdHexOverride = { _ in
          await EventCodeEntryProgressFixture.shared.lookup()
        }
        coordinator.eventCodeJoinErrorForUITesting = {
          EventCodeEntryProgressFixture.shared.completionError
        }
      }
      #endif
    }
    .onChange(of: isSubmitting) { _, pending in
      if pending {
        UIAccessibility.post(notification: .announcement, argument: String(localized: "eventCode.lookup.pending"))
      }
    }
    .onDisappear {
      // Cancel a task that has not entered the coordinator yet as well as a
      // lookup already owned by its generation. The scan-flow binding has
      // already consumed pop cancellation; this remains fallback cleanup.
      submission.cancel(coordinator: coordinator)
    }
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
          Text(verbatim: "PASTE")
            // This literal is already uppercase; keep the mono style's text
            // case from uppercasing the spoken label.
            .textCase(nil)
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textPrimary)
            .frame(minWidth: DS.Size.minHitTarget, minHeight: DS.Size.minHitTarget, alignment: .trailing)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(verbatim: String(localized: "Paste event code")))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .accessibilityIdentifier("eventCode.paste")
      }
      .frame(minHeight: DS.Size.minHitTarget)

      TextField("Event code", text: $code, prompt: Text("eventCode.input.placeholder"))
        .beidTextStyle(DS.Font.Library.displayAddress34)
        .foregroundStyle(DS.Color.textPrimary)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .submitLabel(.join)
        .focused($codeFieldFocused)
        .disabled(isSubmitting)
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
            .frame(width: DS.Onboarding.statusDot, height: DS.Onboarding.statusDot)
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
    guard !isSubmitting else { return }
    let submittedCode = code
    // Use the same validation as the coordinator, before creating a task or
    // pending UI. Empty input is an immediate field error, never a lookup.
    guard BeidSharedKit.event.normalizedEventCodeOrNull(rawEventCode: submittedCode) != nil else {
      errorKind = .emptyCode
      errorMessage = message(for: .emptyCode)
      return
    }
    submission.isSubmitting = true
    errorKind = nil
    errorMessage = nil
    codeFieldFocused = false
    submission.task = Task { @MainActor in
      guard !Task.isCancelled else { return }
      let outcome = await join(submittedCode)
      guard !Task.isCancelled else { return }
      finishSubmission(outcome)
    }
  }

  private func join(_ submittedCode: String) async -> AppCoordinator.JoinAttemptOutcome {
    switch mode {
    case .onboarding:
      return await coordinator.joinEventResolvingCanonicalId(code: submittedCode)
    case .accountSheet:
      return await coordinator.joinEventFromAccountSheetResolvingCanonicalId(code: submittedCode)
    case .home:
      return await coordinator.joinEventFromHomeResolvingCanonicalId(code: submittedCode)
    case .scanFlow:
      return await coordinator.joinEventFromScanFlowResolvingCanonicalId(code: submittedCode)
    }
  }

  private func finishSubmission(_ outcome: AppCoordinator.JoinAttemptOutcome) {
    submission.isSubmitting = false
    submission.task = nil
    guard case .completed(let error) = outcome else { return }
    errorKind = error
    errorMessage = message(for: error)
    if error != nil {
      codeFieldFocused = true
    } else if mode == .scanFlow {
      dismiss()
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

#if DEBUG
/// A UI-test-only suspension of the real coordinator's lookup. Failure is
/// injected because the current nonempty-code selector cannot return
/// `joinFailed`; transport refusals belong to the later sensing screen.
/// Success resumes the actual coordinator route. No timer, network or SDK
/// result drives this gate, and cancelled tasks resume only to exit.
@MainActor
private final class EventCodeEntryProgressFixture: ObservableObject {
  static let shared = EventCodeEntryProgressFixture()

  static var isEnabled: Bool {
    let arguments = ProcessInfo.processInfo.arguments
    return arguments.contains("-beid-ui-test") && arguments.contains("-beid-code-entry-progress-fixture")
  }

  @Published private(set) var receipt = "submissions=0 resumed=0"
  private(set) var completionError: EventCodeJoinError?
  private var submissions = 0
  private var resumed = 0
  private var pending: [CheckedContinuation<Void, Never>] = []

  func lookup() async -> AppCoordinator.CanonicalEventIdLookup {
    submissions += 1
    updateReceipt()
    await withCheckedContinuation { pending.append($0) }
    resumed += 1
    updateReceipt()
    return .noAnswer
  }

  func complete(error: EventCodeJoinError?) {
    guard !pending.isEmpty else { return }
    completionError = error
    pending.removeFirst().resume()
  }

  private func updateReceipt() {
    receipt = "submissions=\(submissions) resumed=\(resumed)"
  }
}

private struct EventCodeEntryProgressFixtureControls: View {
  @ObservedObject private var fixture = EventCodeEntryProgressFixture.shared
  let resubmit: () -> Void

  var body: some View {
    VStack(spacing: DS.Space.s) {
      Text(verbatim: fixture.receipt)
        .accessibilityIdentifier("fixture.code.receipt")
      HStack {
        Button("Complete success") { fixture.complete(error: nil) }
          .frame(minHeight: DS.Size.minHitTarget)
          .accessibilityIdentifier("fixture.code.succeed")
        Button("Complete failure") { fixture.complete(error: .joinFailed) }
          .frame(minHeight: DS.Size.minHitTarget)
          .accessibilityIdentifier("fixture.code.fail")
      }
      // Invoke the real handler, as an already queued keyboard submit would,
      // even after the visible field and JOIN button become disabled.
      Button("Submit again", action: resubmit)
        .frame(minHeight: DS.Size.minHitTarget)
        .accessibilityIdentifier("fixture.code.resubmit")
    }
    .beidTextStyle(DS.Font.Library.body13)
  }
}
#endif

/// Frame 13's full-width ink capsule uses the shared Flat 2b primary button.
private struct EventCodeJoinButton: View {
  let action: () -> Void

  var body: some View {
    BeidPrimaryButton("Join event", action: action)
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
