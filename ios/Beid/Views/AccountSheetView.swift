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
                .foregroundStyle(bluetoothStatusColor)
            }
          }
        }

        Section {
          NavigationLink {
            VenueDeviceOrganizerView(sensingCoordinator: coordinator.sensingCoordinator)
          } label: {
            Label("Venue Device", systemImage: "antenna.radiowaves.left.and.right")
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
    }
    .sheet(isPresented: $coordinator.eventCodeEntrySheetPresented) {
      EventCodeEntrySheetView()
    }
  }

  private var bluetoothStatusColor: Color {
    coordinator.bluetoothMonitor.isPoweredOff ? DS.Color.statusOff : DS.Color.statusOn
  }

  private var bluetoothStatusText: LocalizedStringKey {
    coordinator.bluetoothMonitor.isPoweredOff ? "Off" : "Active"
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
    if connector is CoinbaseWalletConnector {
      return "Coinbase Wallet"
    }
    if connector is ReownWalletConnectClient {
      return "WalletConnect"
    }
    #if DEBUG
    if connector is MetaMaskConnector {
      return "MetaMask"
    }
    if connector is DemoWalletConnector {
      return "Demo Wallet"
    }
    #endif
    return "WalletConnect"
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
            ReownWalletConnectClient.shared.reset()
            CoinbaseWalletConnector.shared.disconnect()
            #if DEBUG
            MetaMaskConnector.shared.disconnect()
            #endif
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
            onRejoin: { code in coordinator.rejoinPastEvent(code: code) }
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

#Preview("No wallet (Dark)") {
  AccountSheetView()
    .environmentObject(AppCoordinator())
    .preferredColorScheme(.dark)
}

#Preview("Wallet connected") {
  let coordinator = AppCoordinator()
  coordinator.walletAddress = "0x1234567890abcdef1234567890abcdef12345678"
  return AccountSheetView().environmentObject(coordinator)
}

#Preview("Wallet connected (Dark)") {
  let coordinator = AppCoordinator()
  coordinator.walletAddress = "0x1234567890abcdef1234567890abcdef12345678"
  return AccountSheetView()
    .environmentObject(coordinator)
    .preferredColorScheme(.dark)
}
