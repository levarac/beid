// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

struct RootView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      switch coordinator.screen {
      case .welcome:
        WelcomeView()
      case .eventCodeEntry:
        EventCodeEntryView()
      case .bluetoothPermission:
        BluetoothPermissionView()
      case .bluetoothDenied:
        BluetoothDeniedView()
      case .bluetoothOff:
        BluetoothOffView()
      case .home:
        CollectionHomeView()
      }
    }
    // Home's visible tab/destination owns its state-colored backing instead.
    .beidScreenBackground(DS.Color.surfaceCanvas, updatesBacking: coordinator.screen != .home)
    .modifier(OwnerKeyRestorationNoticePresenter(
      sensingCoordinator: coordinator.sensingCoordinator
    ))
    .modifier(OwnerKeyFailurePresenter(sensingCoordinator: coordinator.sensingCoordinator))
    .modifier(EventSigningKeyFailurePresenter(
      sensingCoordinator: coordinator.sensingCoordinator,
      isActive: coordinator.canPresentRootEventSigningKeyFailure
    ))
    .modifier(FirstUploadNoticePresenter(
      coordinator: coordinator, sensingCoordinator: coordinator.sensingCoordinator
    ))
    .tint(DS.Color.actionPrimary)
    .animation(reduceMotion ? nil : DS.Motion.screenTransition, value: coordinator.screen)
    #if DEBUG
    .background {
      if ProcessInfo.processInfo.arguments.contains("-beid-ui-test") {
        AdaptiveLayoutUITestHost(sensing: coordinator.sensingCoordinator)
          .allowsHitTesting(false)
      }
    }
    #endif
  }
}

private struct FirstUploadNoticePresenter: ViewModifier {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var sensingCoordinator: SensingCoordinator
  @Environment(\.scenePhase) private var scenePhase

  private var canPresent: Bool {
    scenePhase == .active && coordinator.canPresentRootEventSigningKeyFailure &&
      !coordinator.accountSheetPresented && !coordinator.homeEventCodeSheetPresented &&
      !coordinator.welcomeAboutSensingPresented &&
      !coordinator.accountSheetUntilDismissed && !coordinator.homeEventCodeSheetUntilDismissed &&
      !coordinator.welcomeAboutSensingUntilDismissed &&
      sensingCoordinator.ownerKeyRestorationNotice == nil &&
      sensingCoordinator.ownerKeyOperationFailure == nil && sensingCoordinator.eventSigningKeyFailure == nil
  }

  func body(content: Content) -> some View {
    content.sheet(isPresented: Binding(
      get: { canPresent && sensingCoordinator.firstUploadNoticeRequested },
      set: { if !$0 && canPresent { sensingCoordinator.dismissFirstUploadNotice() } }
    )) {
      FirstUploadNoticeView(sensingCoordinator: sensingCoordinator)
    }
  }
}

private struct FirstUploadNoticeView: View {
  @ObservedObject var sensingCoordinator: SensingCoordinator
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: DS.Space.m) {
          Text("Before your first upload")
            .font(DS.Font.sectionTitle)
            .accessibilityAddTraits(.isHeader)
          Text("The event operator receives signed observations that participating devices make of one another with their sensors. Raw observations are available through a public verification API. Others can use them to reconstruct a graph of pseudonymous devices within the event.")
          Text("Device counts and observed relationships are public even at small events. These records show what nearby devices observed about one another. They do not establish that a person attended.")
          Text("Records stay on your device until you delete the local data or delete the app. Backups may retain a copy, depending on your settings.")
          Text("Deleting a Record on your device or deleting the app does not delete observations you already sent. The event operator has no automatic deletion period. We cannot guarantee removal of sent records, third-party copies, or records on public chains.")
          Text("For access or deletion requests, contact hi@levarac.org.")
          // The design-system text control (mono uppercase with a trailing
          // arrow and a 44 pt hit region), so the link no longer reads as body
          // text. It stays a SwiftUI Link and opens the system browser.
          Link(destination: URL(string: "https://levarac.org/privacy")!) {
            BeidTextControlLabel("Privacy Policy", glyph: .trailing("→", announcing: "Privacy Policy"))
          }
          .accessibilityIdentifier("firstUpload.privacyPolicy")
          Button("Continue") {
            sensingCoordinator.continueAfterFirstUploadNotice()
            dismiss()
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("firstUpload.continue")
        }
        .frame(maxWidth: 600, alignment: .leading)
        .padding()
      }
      .accessibilityIdentifier("firstUpload.notice")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
            .accessibilityIdentifier("firstUpload.close")
        }
      }
    }
  }
}

private struct OwnerKeyFailurePresenter: ViewModifier {
  @ObservedObject var sensingCoordinator: SensingCoordinator

  func body(content: Content) -> some View {
    content.alert(item: failureBinding) { failure in
      Alert(
        title: Text(verbatim: failure.title),
        message: Text(verbatim: failure.message),
        primaryButton: .default(Text(String(localized: "ownerKeyFailure.retry", defaultValue: "Try again"))) {
          sensingCoordinator.retryOwnerKeyOperation()
        },
        secondaryButton: .cancel(Text(String(localized: "ownerKeyFailure.dismiss", defaultValue: "Close")))
      )
    }
  }

  private var failureBinding: Binding<OwnerKeyOperationFailure?> {
    Binding(get: { sensingCoordinator.ownerKeyOperationFailure }, set: { _ in })
  }
}

/// Observes `SensingCoordinator` directly because `AppCoordinator` owns it as
/// a plain property and does not republish nested changes. Keeping the alert
/// at the root lets a startup notice appear on whichever onboarding or home
/// screen is current without changing any route.
private struct OwnerKeyRestorationNoticePresenter: ViewModifier {
  @ObservedObject var sensingCoordinator: SensingCoordinator

  func body(content: Content) -> some View {
    content.alert(item: noticeBinding) { notice in
      Alert(
        title: Text(verbatim: notice.title),
        message: Text(verbatim: notice.message),
        dismissButton: .default(Text(closeWarningTitle))
      )
    }
  }

  private var noticeBinding: Binding<OwnerKeyRestorationNotice?> {
    Binding(
      get: { sensingCoordinator.ownerKeyRestorationNotice },
      set: { notice in
        if notice == nil {
          sensingCoordinator.acknowledgeOwnerKeyRestorationNotice()
        }
      }
    )
  }

  private var closeWarningTitle: String {
    String(
      localized: "ownerKeyRestoration.dismiss",
      defaultValue: "Close warning",
      comment: "Button that closes an owner-key restoration warning after the user has read it."
    )
  }
}

private struct PresentedEventSigningKeyFailure: Identifiable {
  let failure: EventSigningKeyFailure
  let eventCode: String?
  var id: String { eventCode.map { "\(failure.id):\($0)" } ?? failure.id }
}

struct EventSigningKeyFailurePresenter: ViewModifier {
  @ObservedObject var sensingCoordinator: SensingCoordinator
  let isActive: Bool

  private var presentedFailure: PresentedEventSigningKeyFailure? {
    sensingCoordinator.eventSigningKeyFailure.map {
      PresentedEventSigningKeyFailure(failure: $0, eventCode: sensingCoordinator.eventSigningKeyNoticeEventCode)
    }
  }

  func body(content: Content) -> some View {
    let presented = presentedFailure
    return content.alert(item: Binding(
      get: { isActive ? presented : nil },
      set: {
        if isActive, $0 == nil, presented?.id == presentedFailure?.id {
          sensingCoordinator.dismissEventSigningKeyFailure()
        }
      }
    )) { notice in
      let failure = notice.failure
      return Alert(
        title: Text(verbatim: failure.title),
        message: Text(verbatim: failure.message),
        dismissButton: .default(Text(String(localized: "eventSigningKeyFailure.dismiss", defaultValue: "Close")))
      )
    }
  }
}
