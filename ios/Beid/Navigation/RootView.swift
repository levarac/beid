// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

struct RootView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    Group {
      switch coordinator.screen {
      case .welcome:
        WelcomeView()
      case .walletConnect:
        WalletConnectView()
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
    .tint(DS.Color.actionPrimary)
    .animation(BeidDesign.Animation.soft, value: coordinator.screen)
    .fullScreenCover(isPresented: $coordinator.scanPresented) {
      ScanFlowView(sensing: coordinator.sensingCoordinator)
        .environmentObject(coordinator)
        .tint(DS.Color.actionPrimary)
        .presentationBackground(.regularMaterial)
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
        primaryButton: .default(Text(String(localized: "ownerKeyFailure.retry", defaultValue: "Try Again"))) {
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
