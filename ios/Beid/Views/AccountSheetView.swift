// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit

/// Flat 2b screen 10: Account sheet and its Bluetooth, copy and disconnect
/// states. Wallet connection and Account Join remain optional routes; #647
/// and #655 still own their respective destination and exit changes.
struct AccountSheetView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.dismiss) private var dismiss
  @State private var showOrganizerTools = false
  @State private var showPastEvents = false
  @State private var showDisconnectConfirmation = false
  @State private var copied = false

  var body: some View {
    NavigationStack {
      List {
        AccountSheetRow(minHeight: DS.Space.xxl * 2, hasDivider: !showDisconnectConfirmation) {
          walletContent
        }
        if showDisconnectConfirmation {
          AccountSheetRow(hasDivider: false) {
            disconnectConfirmation
          }
        } else {
          AccountSheetRow {
            AccountBluetoothRow(monitor: coordinator.bluetoothMonitor, relayNote: relayNoteText)
          }
          AccountSheetRow {
            Button {
              showOrganizerTools = true
            } label: {
              HStack {
                Text("Organizer tools")
                  .beidTextStyle(DS.Font.Library.title17)
                Spacer()
                Text(verbatim: "→")
                  .beidTextStyle(DS.Font.Library.labelMono11)
                  .accessibilityHidden(true)
              }
              .foregroundStyle(DS.Color.actionInverse)
              .frame(minHeight: DS.Size.sessionRowMinHeight + DS.Space.xs)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Organizer tools")
          }
          AccountSheetRow(topGap: DS.Space.m + DS.Space.xs) {
            Button(role: .destructive) {
              showDisconnectConfirmation = true
            } label: {
              Text("Disconnect wallet")
                .beidTextStyle(DS.Font.Library.title17)
                .foregroundStyle(DS.Color.statusOff)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: DS.Size.sessionRowMinHeight + DS.Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(coordinator.walletAddress == nil)
          }
          // Provisional extra row: Past Events is still the only rejoin path.
          // Its gap keeps this extra route below the three Figma menu rows.
          AccountSheetRow(topGap: DS.Space.xxl) {
            Button {
              showPastEvents = true
            } label: {
              HStack {
                Text(pastEventsLabel)
                  .beidTextStyle(DS.Font.Library.title17)
                Spacer()
                Text(verbatim: "→")
                  .beidTextStyle(DS.Font.Library.labelMono11)
                  .accessibilityHidden(true)
              }
              .foregroundStyle(DS.Color.actionInverse)
              .frame(minHeight: DS.Size.sessionRowMinHeight + DS.Space.xs)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Past Events")
          }
          // Account Join stays with the owner decision that wallet is optional.
          // Leave stays until #655 supplies stop-and-finalize elsewhere.
          EventMembershipSections(sensingCoordinator: coordinator.sensingCoordinator)
        }
      }
      .id(showDisconnectConfirmation)
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(DS.Color.textPrimary)
      .foregroundStyle(DS.Color.actionInverse)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(DS.Color.textPrimary, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          // Approved accessible dismissal; Figma 10 shows only a grabber.
          BeidTextControl("Done", labelColor: DS.Color.actionInverse) { dismiss() }
        }
        .beidWithoutSharedBackground()
      }
      .safeAreaInset(edge: .bottom) {
        if !showDisconnectConfirmation {
          // Provisional footer: preserve the complete git-height and store-build
          // value (#491); Figma's shortened hash and ABOUT have no adopted path.
          Text(verbatim: "beid \(AppVersion.displayString())")
            .beidTextStyle(DS.Font.Library.labelMono9)
            .foregroundStyle(DS.Color.textSecondaryOnInk)
            .accessibilityIdentifier("account.version.value")
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.s)
            .background(DS.Color.textPrimary)
        }
      }
      .navigationDestination(isPresented: $showOrganizerTools) {
        AccountOrganizerToolsView()
      }
      .navigationDestination(isPresented: $showPastEvents) {
        PastEventsView(
          sensingCoordinator: coordinator.sensingCoordinator,
          proofStore: coordinator.proofStore,
          onRejoin: { code in
            Task { @MainActor in
              await coordinator.rejoinPastEventResolvingCanonicalId(code: code)
            }
          }
        )
      }
    }
    .sheet(isPresented: $coordinator.walletConnectSheetPresented) {
      WalletConnectSheetView()
        .environmentObject(coordinator)
    }
    // A custom `Binding`, not `$coordinator.eventCodeEntrySheetPresented`
    // directly: swipe-to-dismiss writes `false` through whatever binding
    // `.sheet(isPresented:)` was given, and only this `set` closure runs
    // synchronously with that exact write. An `.onChange(of:)` observing the
    // same property instead reacts to the write *after* SwiftUI schedules
    // it — a stale lookup resuming on the main actor in that gap would still
    // see the old, not-yet-cancelled generation and could join anyway
    // (beid#258 P1-1 round-3 fix; the explicit Cancel button in
    // `EventCodeEntrySheetView` below cancels directly in its own action
    // closure instead, since it never writes through this binding at all).
    .sheet(isPresented: Binding(
      get: { coordinator.eventCodeEntrySheetPresented },
      set: { isPresented in
        if !isPresented {
          coordinator.cancelPendingAccountSheetJoinAttempt()
        }
        coordinator.eventCodeEntrySheetPresented = isPresented
      }
    )) {
      EventCodeEntrySheetView()
        .environmentObject(coordinator)
    }
  }

  @ViewBuilder
  private var walletContent: some View {
    if let address = coordinator.walletAddress {
      VStack(alignment: .leading, spacing: DS.Space.s) {
        Text(walletHeader)
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondaryOnInk)
        HStack(spacing: DS.Space.s) {
          // Provisional #642 typeface: Figma node 208:46 uses Display/Address 34.
          Text(verbatim: truncated(address))
            .beidTextStyle(DS.Font.Library.displayAddress34)
            .foregroundStyle(DS.Color.actionInverse)
            .accessibilityLabel(Text(verbatim: address))
            .layoutPriority(1)
          Spacer(minLength: 0)
          if copied {
            Button {
              UIPasteboard.general.string = address
            } label: {
              HStack(spacing: DS.Space.xs) {
                Circle()
                  .fill(DS.Color.statusOn)
                  .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                  .accessibilityHidden(true)
                BeidTextControlLabel("Copied", labelColor: DS.Color.actionInverse)
              }
              .frame(minHeight: DS.Size.minHitTarget)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copied address")
            .accessibilityIdentifier("account.copy.feedback")
          } else {
            BeidTextControl("Copy", labelColor: DS.Color.actionInverse, accessibilityLabel: "Copy address") {
              UIPasteboard.general.string = address
              copied = true
            }
          }
        }
      }
      .padding(.top, DS.Space.xs)
    } else {
      // Wallet is optional by owner decision. Keep voluntary connection and
      // reconnection available even though Figma 10 shows only a connected wallet.
      Button {
        BeidDesign.haptic()
        coordinator.connectWalletFromAccountSheet()
      } label: {
        Text("Connect Wallet")
          .beidTextStyle(DS.Font.Library.title17)
          .foregroundStyle(DS.Color.actionInverse)
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(minHeight: DS.Size.minHitTarget)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  private var walletHeader: String {
    // Provisional truthful provider copy: MetaMask is the connected wallet;
    // Figma's WalletConnect protocol wording remains unresolved (#642).
    String(
      localized: "account.wallet.header",
      defaultValue: "Wallet · Connected via \(connectorDisplayName)",
      comment: "Account sheet label naming the connected wallet provider."
    )
  }

  private var pastEventsLabel: String {
    String(
      localized: "account.pastEvents.label",
      defaultValue: "Past Events",
      comment: "Account row opening previously joined events, including the rejoin action."
    )
  }

  private var disconnectConfirmation: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Disconnect wallet?")
        .beidTextStyle(DS.Font.Library.title19)
        .foregroundStyle(DS.Color.actionInverse)
      Text(
        "Your proofs stay on this device as self-proofs. Nothing is deleted. You can connect this or another wallet anytime."
      )
      .beidTextStyle(DS.Font.Library.body15)
      .foregroundStyle(DS.Color.textSecondaryOnInk)
      .padding(.top, DS.Space.s)

      Button(role: .destructive) {
        BeidDesign.haptic(.medium)
        coordinator.disconnectWallet()
        showDisconnectConfirmation = false
      } label: {
        Text("Disconnect")
          .beidTextStyle(DS.Font.Library.title16)
          .foregroundStyle(DS.Color.labelOnActionInverse)
          .frame(maxWidth: .infinity, minHeight: DS.Size.primaryButtonMinHeight)
          .background(DS.Color.actionInverse, in: Capsule())
      }
      .buttonStyle(.plain)
      .padding(.top, DS.Space.xxl)

      HStack {
        Spacer()
        BeidTextControl("Keep connected", labelColor: DS.Color.actionInverse) {
          showDisconnectConfirmation = false
        }
        .accessibilityIdentifier("account.disconnect.cancel")
        Spacer()
      }
      .padding(.top, DS.Space.s)
    }
    .padding(.top, DS.Space.m)
    .accessibilityIdentifier("account.disconnect.confirmation")
  }

  private var relayNoteText: String {
    String(
      localized: "account.bluetooth.relayNote",
      defaultValue:
        """
        While this phone is at an event, beid can pass the event's details on to phones \
        nearby, so people across the venue can still find it.
        """
    )
  }

  /// `WalletConnector` has no name/display-name property (adding one is out
  /// of this task's allowed scope — see `ios/Beid/Onboarding/WalletConnector.swift`),
  /// so the connector's display name is derived here from its concrete type.
  private var connectorDisplayName: String {
    let connector = coordinator.walletConnector
    if connector is MetaMaskConnector {
      return "MetaMask"
    }
    #if DEBUG
    if connector is DemoWalletConnector {
      return "Demo Wallet"
    }
    #endif
    // MetaMask is the only connector Release ever records; this is
    // unreachable there in practice, and even in Debug (Demo Wallet handled
    // above) is the sensible remaining default.
    return "MetaMask"
  }

  private func truncated(_ address: String) -> String {
    guard address.count > 10 else { return address }
    let prefix = address.prefix(6)
    let suffix = address.suffix(4)
    return "\(prefix)…\(suffix)"
  }
}

/// Measured screen-10 row geometry: 24pt side insets, 52pt menu rows and a
/// hairline on the ink sheet. Keeping this local lets #642 tune the Figma
/// comparison without changing the shared List or design-system defaults.
private struct AccountSheetRow<Content: View>: View {
  let minHeight: CGFloat
  let topGap: CGFloat
  let hasDivider: Bool
  let content: Content

  init(
    minHeight: CGFloat = DS.Size.sessionRowMinHeight + DS.Space.xs,
    topGap: CGFloat = 0,
    hasDivider: Bool = true,
    @ViewBuilder content: () -> Content
  ) {
    self.minHeight = minHeight
    self.topGap = topGap
    self.hasDivider = hasDivider
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if topGap > 0 {
        DS.Color.textPrimary.frame(height: topGap)
          .overlay(alignment: .bottom) {
            Rectangle()
              .fill(DS.Color.strokeHairlineOnInk)
              .frame(height: DS.Size.hairline)
          }
      }
      content
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: minHeight, alignment: .leading)
    }
    .background(DS.Color.textPrimary)
    .overlay(alignment: .bottom) {
      if hasDivider {
        Rectangle()
          .fill(DS.Color.strokeHairlineOnInk)
          .frame(height: DS.Size.hairline)
      }
    }
    .listRowInsets(EdgeInsets(
      top: 0,
      leading: DS.Space.pageMargin,
      bottom: 0,
      trailing: DS.Space.pageMargin
    ))
    .listRowBackground(DS.Color.textPrimary)
    .listRowSeparator(.hidden)
  }
}

/// Observes the radio independently of AppCoordinator's published state, so
/// turning Bluetooth off while Account is open refreshes its status promptly.
private struct AccountBluetoothRow: View {
  @ObservedObject var monitor: BluetoothMonitor
  let relayNote: String

  private var isOff: Bool {
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("-beid-ui-test"),
      arguments.contains("-beid-account-bluetooth-off-fixture")
    {
      return true
    }
    #endif
    return monitor.isPoweredOff
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if isOff {
        Button {
          UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        } label: {
          HStack(spacing: DS.Space.s) {
            Text("Bluetooth")
              .beidTextStyle(DS.Font.Library.title17)
            Spacer()
            Circle()
              .fill(DS.Color.statusOff)
              .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
              .accessibilityHidden(true)
            BeidTextControlLabel(
              "Off · Fix",
              glyph: .trailing("→", announcing: "Open Bluetooth Settings"),
              labelColor: DS.Color.actionInverse
            )
          }
          .foregroundStyle(DS.Color.actionInverse)
          .frame(minHeight: DS.Size.sessionRowMinHeight + DS.Space.xs)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Bluetooth Settings")
        .accessibilityIdentifier("account.bluetooth.status")

        Text("Sensing is paused until Bluetooth is on. Tap to open Settings.")
          .beidTextStyle(DS.Font.Library.body13)
          .foregroundStyle(DS.Color.textSecondaryOnInk)
      } else {
        HStack(spacing: DS.Space.s) {
          Text("Bluetooth")
            .beidTextStyle(DS.Font.Library.title17)
          Spacer()
          Circle()
            .fill(DS.Color.statusOn)
            .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
            .accessibilityHidden(true)
          Text("Active")
            .beidTextStyle(DS.Font.Library.labelMono11)
            .foregroundStyle(DS.Color.textSecondaryOnInk)
            .accessibilityIdentifier("account.bluetooth.status")
        }
        .foregroundStyle(DS.Color.actionInverse)
        .frame(minHeight: DS.Size.sessionRowMinHeight + DS.Space.xs)
      }

      // Provisional #642 Q2 / #644 placement. This phone may relay another
      // event's details, so the note stays visible below Bluetooth. It makes
      // this row taller than Figma 10 and moves the rows below it down.
      Text(verbatim: relayNote)
        .beidTextStyle(DS.Font.Library.body13)
        .foregroundStyle(DS.Color.textSecondaryOnInk)
        .padding(.bottom, DS.Space.s)
    }
  }
}

/// #647 owns the full Organizer tools surface. Until it lands, this narrow
/// route preserves the sole production entrance to Venue broadcast (#597)
/// without restoring the withdrawn Venue device path.
private struct AccountOrganizerToolsView: View {
  @State private var showVenueBroadcast = false

  var body: some View {
    List {
      Button {
        showVenueBroadcast = true
      } label: {
        HStack {
          Text("Venue broadcast")
          Spacer()
          Text(verbatim: "→")
            .accessibilityHidden(true)
        }
        .frame(minHeight: DS.Size.minHitTarget)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Venue broadcast")
    }
    .navigationDestination(isPresented: $showVenueBroadcast) {
        VenueSignedServingView(viewModel: VenueSignedServingViewModel(
          verifier: ProductionVenueBundleVerifier(registryClient: RegistryDependencies.createClient()),
          broadcasting: BarnardVenueSignedContainerBroadcasting(),
          acquisition: VenueArtifactAcquisition(),
          store: VenuePublicArtifactStore(),
          clock: { VenueDeviceClock.read() }
        ))
    }
    .navigationTitle("Organizer tools")
    .scrollContentBackground(.hidden)
    .background(DS.Color.surfaceCanvas)
    .toolbarBackground(DS.Color.surfaceCanvas, for: .navigationBar)
    .toolbarColorScheme(.light, for: .navigationBar)
  }
}

/// Sheet wrapper around `WalletConnectPairingView` for the Account sheet's
/// "Connect Wallet" action. Unlike `WalletConnectView` (onboarding), success
/// here just sets `walletAddress` and dismisses — it does not advance
/// `coordinator.screen`. No `secondaryAction`; Cancel in the toolbar is the
/// escape hatch instead.
private struct WalletConnectSheetView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    NavigationStack {
      BeidAdaptiveContent {
        VStack(spacing: DS.Space.l) {
          Spacer()
          WalletConnectPairingView { address, connector in
            coordinator.recordWalletConnection(address: address, connector: connector)
            coordinator.walletConnectSheetPresented = false
          }
          .padding(.horizontal, DS.Space.pageMargin)
          Spacer()
        }
        .padding(.bottom, DS.Space.xl)
      }
      .navigationTitle("Connect Wallet")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) {
            // Light in-app cancel, not forget-wallet (dispatch#26
            // condition 3) — leaves the SDK session and cached hint alone.
            MetaMaskConnector.shared.cancelPendingOperation()
            coordinator.walletConnectSheetPresented = false
          }
        }
        .beidWithoutSharedBackground()
      }
    }
    // Sheets don't inherit the presenter's .tint (unlike push navigation),
    // so without this the toolbar Cancel button renders system blue — a
    // §5 MUST-NOT violation (see WalletConnectView's doc comment).
    .tint(DS.Color.actionPrimary)
  }
}

/// Sheet wrapper around `EventCodeEntryView` (in `.accountSheet` mode) for
/// the Account sheet's "Join Event" action. Unlike `EventCodeEntryView`'s
/// onboarding usage, success here just dismisses the sheet — it does not
/// advance `coordinator.screen`. No secondary action; Cancel in the toolbar
/// is the escape hatch instead. No `navigationTitle`: the hero header inside
/// `EventCodeEntryView` already states "Enter Event Code", so a nav bar
/// title would just repeat it.
private struct EventCodeEntrySheetView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    NavigationStack {
      EventCodeEntryView(mode: .accountSheet)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) {
              // Direct property write, not through AccountSheetView's
              // custom cancelling `Binding` — cancel synchronously here too
              // (beid#258 P1-1 round-3 fix).
              coordinator.cancelPendingAccountSheetJoinAttempt()
              coordinator.eventCodeEntrySheetPresented = false
            }
          }
          .beidWithoutSharedBackground()
        }
    }
    .tint(DS.Color.actionPrimary)
  }
}

/// "Join Event" and interim "Leave Event" rows for `AccountSheetView`. `AppCoordinator`
/// holds `sensingCoordinator` as a plain `let` and does not re-publish its
/// `@Published` state, so `AccountSheetView` (which observes only
/// `AppCoordinator`) never invalidates when `joinedEventCode` changes on
/// `SensingCoordinator`. Observing `SensingCoordinator` directly here — the
/// same pattern `VenueDeviceOrganizerView` already uses — fixes that without
/// making `AppCoordinator` republish all of `SensingCoordinator`'s frequent
/// sensing-state updates.
private struct EventMembershipSections: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @ObservedObject var sensingCoordinator: SensingCoordinator

  var body: some View {
    Group {
      AccountSheetRow {
        Button {
          BeidDesign.haptic()
          coordinator.openEventCodeEntryFromAccountSheet()
        } label: {
          Text(joinEventLabel)
            .beidTextStyle(DS.Font.Library.title17)
            .foregroundStyle(DS.Color.actionInverse)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: DS.Size.sessionRowMinHeight + DS.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sensingCoordinator.joinedEventCode != nil)
      }

      AccountSheetRow {
        Button(role: .destructive) {
          BeidDesign.haptic(.medium)
          coordinator.leaveEvent()
        } label: {
          Text("Leave Event")
            .beidTextStyle(DS.Font.Library.title17)
            .foregroundStyle(DS.Color.statusOff)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: DS.Size.sessionRowMinHeight + DS.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sensingCoordinator.joinedEventCode == nil)
      }
    }
  }

  private var joinEventLabel: String {
    String(
      localized: "account.joinEvent.label",
      defaultValue: "Join Event",
      comment: "Menu row in the Account sheet that opens the manual event-code entry form. Distinct from that form's own submit button, which is also labeled \"Join Event\" in English but is a separate translation unit and may need different wording in other languages."
    )
  }

}

#Preview("No wallet") {
  AccountSheetView().environmentObject(AppCoordinator())
}

#Preview("Wallet connected") {
  let coordinator = AppCoordinator()
  coordinator.walletAddress = "0x1234567890abcdef1234567890abcdef12345678"
  return AccountSheetView().environmentObject(coordinator)
}
