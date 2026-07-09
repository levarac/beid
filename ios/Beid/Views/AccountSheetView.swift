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
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
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
            coordinator.walletAddress = nil
          }
          .disabled(coordinator.walletAddress == nil)
        }
      }
      .scrollContentBackground(.hidden)
      .background(Color(.systemGroupedBackground))
      .navigationTitle("Account")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private func truncated(_ address: String) -> String {
    guard address.count > 10 else { return address }
    let prefix = address.prefix(6)
    let suffix = address.suffix(4)
    return "\(prefix)...\(suffix)"
  }
}

#Preview {
  AccountSheetView().environmentObject(AppCoordinator())
}
