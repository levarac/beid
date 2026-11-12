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
    .modifier(OwnerKeyRestorationNoticePresenter(
      sensingCoordinator: coordinator.sensingCoordinator
    ))
    .modifier(OwnerKeyFailurePresenter(sensingCoordinator: coordinator.sensingCoordinator))
    #if DEBUG
    .modifier(EventSigningKeyFailurePresenter(
      sensingCoordinator: coordinator.sensingCoordinator,
      isActive: !coordinator.scanPresented,
      routeTrace: coordinator.stopOutcomeUITestFixture?.routeTrace,
      routeTraceOwner: "root",
      routeScanPresented: { coordinator.scanPresented }
    ))
    #else
    .modifier(EventSigningKeyFailurePresenter(
      sensingCoordinator: coordinator.sensingCoordinator,
      isActive: !coordinator.scanPresented
    ))
    #endif
    .tint(DS.Color.actionPrimary)
    .animation(reduceMotion ? nil : DS.Motion.screenTransition, value: coordinator.screen)

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
  #if DEBUG
  var routeTrace: StopOutcomeRouteTrace?
  var routeTraceOwner = "root"
  var routeScanPresented: (() -> Bool)?

  private func trace(_ event: String, detail: @autoclosure () -> String = "") {
    guard let routeTrace, let routeScanPresented else { return }
    routeTrace.record(
      "alert.\(routeTraceOwner).\(event)",
      scanPresented: routeScanPresented(),
      detail: "capturedActive=\(isActive) notice=\(presentedFailure != nil) \(detail())"
    )
  }
  #endif

  private var presentedFailure: PresentedEventSigningKeyFailure? {
    sensingCoordinator.eventSigningKeyFailure.map {
      PresentedEventSigningKeyFailure(failure: $0, eventCode: sensingCoordinator.eventSigningKeyNoticeEventCode)
    }
  }

  func body(content: Content) -> some View {
    let presented = presentedFailure
    #if DEBUG
    trace("evaluated")
    #endif
    return content.alert(item: Binding(
      get: {
        #if DEBUG
        trace("binding-get", detail: "offersNotice=\(isActive && presented != nil)")
        #endif
        return isActive ? presented : nil
      },
      set: {
        #if DEBUG
        trace("binding-set", detail: "nilInput=\($0 == nil) matches=\(presented?.id == presentedFailure?.id)")
        #endif
        if isActive, $0 == nil, presented?.id == presentedFailure?.id {
          #if DEBUG
          trace("acknowledge-before", detail: "capturedNotice=\(presented != nil) matches=true")
          #endif
          sensingCoordinator.dismissEventSigningKeyFailure()
          #if DEBUG
          trace("acknowledge-after")
          #endif
        }
      }
    )) { notice in
      #if DEBUG
      // Alert construction is not proof of native alert visibility.
      trace("constructed")
      #endif
      let failure = notice.failure
      return Alert(
        title: Text(verbatim: failure.title),
        message: Text(verbatim: failure.message),
        dismissButton: .default(Text(String(localized: "eventSigningKeyFailure.dismiss", defaultValue: "Close")))
      )
    }
  }
}
