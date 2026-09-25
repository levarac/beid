// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit

/// Screen 09: Account sheet — wallet address, Bluetooth status, disconnect.
/// In `.guestFirst` onboarding, the wallet may not be connected yet; this
/// sheet is where that stubbed connection happens.
struct AccountSheetView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section("Wallet") {
          if let address = coordinator.walletAddress {
            HStack(spacing: DS.Space.m) {
              Label {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                  Text(truncated(address))
                    .font(DS.Font.ledgerMono)
                    .foregroundStyle(DS.Color.textPrimary)
                  Text(connectedViaText)
                    .font(DS.Font.supporting)
                    .foregroundStyle(DS.Color.textSecondary)
                }
              } icon: {
                Image(systemName: "wallet.pass")
              }
              Spacer()
              Button {
                UIPasteboard.general.string = coordinator.walletAddress
                BeidDesign.haptic()
              } label: {
                Image(systemName: "doc.on.doc")
                  .foregroundStyle(DS.Color.actionPrimary)
              }
              .buttonStyle(.borderless)
              .frame(minWidth: DS.Size.minHitTarget, minHeight: DS.Size.minHitTarget)
              .accessibilityLabel(
                Text(
                  "Copy address",
                  comment: "Button: copies the connected wallet address to the clipboard, not a noun."
                )
              )
            }
          } else {
            Button {
              BeidDesign.haptic()
              coordinator.connectWalletFromAccountSheet()
            } label: {
              Label("Connect Wallet", systemImage: "wallet.pass")
            }
          }
        }

        Section {
          HStack(spacing: DS.Space.m) {
            Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right")
            Spacer()
            HStack(spacing: DS.Space.xs) {
              Circle()
                .fill(bluetoothStatusColor)
                .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                .accessibilityHidden(true)
              Text(bluetoothStatusText)
                .font(DS.Font.supporting)
                .fontWeight(.semibold)
                .foregroundStyle(DS.Color.textPrimary)
            }
          }
        } footer: {
          // Relay is on whenever this phone is sensing at an event it joined
          // (beid#367). It belongs on screen rather than hidden, because the
          // phone is transmitting on someone else's behalf.
          Text(relayNoteText)
            .font(DS.Font.supporting)
            .foregroundStyle(DS.Color.textSecondary)
        }

        // One venue entry, not two (beid#597). What a venue operator has is a
        // pack for an event; whether the bytes inside it are signed is how the
        // feature works, not a choice to put in front of them. The unsigned v1
        // row (gh#138) is withdrawn from this sheet rather than deleted:
        // `VenueDeviceOrganizerView` and its view model are untouched, so
        // restoring it is one NavigationLink if dispatch#4 decides it ships.
        //
        // `canonicalEventIdHex` and `bundleURLTemplate` are no longer passed.
        // They fed the operator-endpoint path, whose only caller was the old
        // screen's Supply button; a link now names its own bundle URL. The view
        // model still accepts both, because tests construct it that way to
        // exercise `supplyConfigured`, but wiring them from here would be
        // dead configuration that reads as live.
        Section {
          NavigationLink {
            VenueSignedServingView(viewModel: VenueSignedServingViewModel(
              verifier: ProductionVenueBundleVerifier(registryClient: RegistryDependencies.createClient()),
              broadcasting: BarnardVenueSignedContainerBroadcasting(),
              acquisition: VenueArtifactAcquisition(),
              store: VenuePublicArtifactStore(),
              clock: { VenueDeviceClock.read() }
            ))
          } label: {
            Label("Venue broadcast", systemImage: "antenna.radiowaves.left.and.right")
          }
        }

        Section {
          Button(role: .destructive) {
            BeidDesign.haptic(.medium)
            coordinator.disconnectWallet()
          } label: {
            Label("Disconnect Wallet", systemImage: "rectangle.portrait.and.arrow.right")
          }
          .disabled(coordinator.walletAddress == nil)
        }

        EventMembershipSections(sensingCoordinator: coordinator.sensingCoordinator)

        // beid#491: the build position, in the same shape as Android's row.
        // Two builds showing the same height came from the same commit, which
        // is what lets a tester report about iOS and one about Android be
        // matched up.
        Section {
          LabeledContent {
            Text(verbatim: AppVersion.displayString())
              .foregroundStyle(DS.Color.textSecondary)
              .accessibilityIdentifier("account.version.value")
          } label: {
            Text("Version")
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(DS.Color.surfaceCanvas)
      .navigationTitle("Account")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
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

  private var bluetoothStatusColor: Color {
    coordinator.bluetoothMonitor.isPoweredOff ? DS.Color.statusOff : DS.Color.statusOn
  }

  private var bluetoothStatusText: LocalizedStringKey {
    coordinator.bluetoothMonitor.isPoweredOff ? "Off" : "Active"
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

  private var connectedViaText: String {
    String(
      localized: "account.wallet.connectedVia",
      defaultValue: "Connected via \(connectorDisplayName)"
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
    return "\(prefix)...\(suffix)"
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
        }
    }
    .tint(DS.Color.actionPrimary)
  }
}

/// "Join Event" / "Leave Event" sections for `AccountSheetView`. `AppCoordinator`
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
      Section {
        Button {
          BeidDesign.haptic()
          coordinator.openEventCodeEntryFromAccountSheet()
        } label: {
          Label { Text(joinEventLabel) } icon: { Image(systemName: "number") }
        }
        .disabled(sensingCoordinator.joinedEventCode != nil)
      }

      Section {
        NavigationLink {
          PastEventsView(
            sensingCoordinator: sensingCoordinator,
            proofStore: coordinator.proofStore,
            onRejoin: { code in
              Task { @MainActor in
                await coordinator.rejoinPastEventResolvingCanonicalId(code: code)
              }
            }
          )
        } label: {
          Label { Text(pastEventsLabel) } icon: { Image(systemName: "clock.arrow.circlepath") }
        }
      }

      Section {
        Button(role: .destructive) {
          BeidDesign.haptic(.medium)
          coordinator.leaveEvent()
        } label: {
          Label("Leave Event", systemImage: "rectangle.portrait.and.arrow.right")
        }
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

  private var pastEventsLabel: String {
    String(
      localized: "account.pastEvents.label",
      defaultValue: "Past Events",
      comment: "Menu row in the Account sheet that opens the list of previously joined events (beid#230), for rejoining one without retyping its code."
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
