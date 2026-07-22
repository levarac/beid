// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 09: Account sheet — wallet address placeholder, Bluetooth status,
/// disconnect. In `.guestFirst` onboarding, the wallet may not be connected
/// yet; this sheet is where that stubbed connection happens.
struct AccountSheetView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section("Wallet") {
          if let address = coordinator.walletAddress {
            LabeledContent {
              Text(truncated(address))
                .font(DS.Font.ledgerMono)
                .foregroundStyle(DS.Color.textSecondary)
            } label: {
              Label("Address", systemImage: "wallet.pass")
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

        Section("Bluetooth") {
          LabeledContent {
            Text(coordinator.bluetoothMonitor.isPoweredOff ? "Off" : "On")
              .foregroundStyle(coordinator.bluetoothMonitor.isPoweredOff ? AnyShapeStyle(.orange) : AnyShapeStyle(.green))
              .fontWeight(.semibold)
          } label: {
            Label("Status", systemImage: "dot.radiowaves.left.and.right")
          }
        }

        Section {
          Button("Disconnect Wallet", role: .destructive) {
            BeidDesign.haptic(.medium)
            coordinator.disconnectWallet()
          }
          .disabled(coordinator.walletAddress == nil)
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
    }
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

#Preview {
  AccountSheetView().environmentObject(AppCoordinator())
}
