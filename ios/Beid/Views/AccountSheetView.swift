// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

private enum AccountSheetDetent {
  static let compact: PresentationDetent = .medium
}

/// Destinations request the large Account sheet while they are in its stack.
/// Separate keys let each Account route (Organizer tools, About sensing,
/// What we send) register without coupling its navigation state to another.
@MainActor
final class AccountLargeDetentRequests: ObservableObject {
  enum Destination: Hashable {
    case organizerTools
    case venueBroadcast
    case aboutSensing
    case whatWeSend
  }

  @Published private(set) var active: Set<Destination> = []

  func set(_ destination: Destination, active isActive: Bool) {
    var updated = active
    if isActive {
      updated.insert(destination)
    } else {
      updated.remove(destination)
    }
    if updated != active { active = updated }
  }
}

/// Add one line to an Account destination, including a nested destination,
/// to hold the sheet at its large detent for that view's visible lifetime.
private struct AccountLargeDetentModifier: ViewModifier {
  @EnvironmentObject private var requests: AccountLargeDetentRequests
  let destination: AccountLargeDetentRequests.Destination

  func body(content: Content) -> some View {
    content
      .onAppear { requests.set(destination, active: true) }
      .onDisappear { requests.set(destination, active: false) }
  }
}

extension View {
  func accountLargeDetent(_ destination: AccountLargeDetentRequests.Destination) -> some View {
    modifier(AccountLargeDetentModifier(destination: destination))
  }
}

/// Flat 2b v2 screen 10 and its states 10b (no wallet), 10c (Bluetooth off),
/// 10d (disconnect confirm) and 10e (copied). DECISIONS 2026-10-15 sets the
/// rows (Bluetooth / Organizer tools / Disconnect wallet), keeps Share
/// support information and the Bluetooth relay note, and moves About to the
/// footer; DECISIONS 2026-09-23 removes Account Leave.
struct AccountSheetView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @State private var showOrganizerTools = false
  @State private var showAboutSensing = false
  @State private var showDisconnectConfirmation = false
  @State private var copied = false
  @State private var supportShareItem: SupportShareItem?
  @StateObject private var largeDetentRequests = AccountLargeDetentRequests()
  @State private var selectedDetent: PresentationDetent = AccountSheetDetent.compact

  var body: some View {
    NavigationStack {
      List {
        AccountSheetRow(hasDivider: !showDisconnectConfirmation) {
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
              largeDetentRequests.set(.organizerTools, active: true)
              selectedDetent = .large
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
          if coordinator.walletAddress != nil {
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
            }
          } else {
            // 10b: the note sits 20pt under the Organizer tools hairline.
            AccountSheetRow(minHeight: 0, hasDivider: false) {
              Text("Proofs stay on this device until a wallet is connected.")
                .beidTextStyle(DS.Font.Library.body13)
                .foregroundStyle(DS.Color.textSecondaryOnInk)
                .padding(.top, DS.Space.m + DS.Space.xs)
                .accessibilityIdentifier("account.wallet.note")
            }
          }
          // beid#466 and DECISIONS 2026-10-15: a user-initiated, frozen
          // support snapshot kept below the v2 rows. A text row (no icons in
          // content, DESIGN.md §12); its explanation sits under the action
          // like the Bluetooth relay note.
          AccountSheetRow(topGap: DS.Space.m + DS.Space.xs) {
            VStack(alignment: .leading, spacing: 0) {
              Button {
                supportShareItem = SupportShareItem(text: coordinator.supportDiagnostics.exportJson())
              } label: {
                Text("Share support information")
                  .beidTextStyle(DS.Font.Library.title17)
                  .foregroundStyle(DS.Color.actionInverse)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .frame(minHeight: DS.Size.sessionRowMinHeight + DS.Space.xs)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("account.support.share")

              Text("Includes app version, recent states and failure reasons from this app session. Choose who to share it with.")
                .beidTextStyle(DS.Font.Library.body13)
                .foregroundStyle(DS.Color.textSecondaryOnInk)
                .padding(.bottom, DS.Space.s)
            }
          }
        }
      }
      .id(showDisconnectConfirmation)
      .listStyle(.plain)
      // Figma 10 places the wallet label 48pt below the sheet's top edge,
      // with or without the Copy item. The list runs under the untitled bar
      // so both states share that position and the item sits beside the
      // wallet block rather than above it.
      .contentMargins(.top, DS.Space.xxl, for: .scrollContent)
      .ignoresSafeArea(.container, edges: .top)
      .scrollContentBackground(.hidden)
      .background(DS.Color.textPrimary)
      .foregroundStyle(DS.Color.actionInverse)
      // Figma 10 has no title. The bar stays for the OS-standard Copy item
      // (DESIGN.md §12) and gives pushed destinations their back button.
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.hidden, for: .navigationBar)
      .toolbar {
        if let address = coordinator.walletAddress {
          ToolbarItem(placement: .topBarTrailing) {
            copyItem(address: address)
              // The sheet's inherited tint is ink, which would vanish on
              // the ink ground behind the item.
              .tint(DS.Color.actionInverse)
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        if !showDisconnectConfirmation {
          aboutFooter
        }
      }
      .overlay(alignment: .bottom) {
        if showDisconnectConfirmation {
          disconnectConfirmationActions
            .padding(.horizontal, DS.Space.pageMargin)
            .padding(.bottom, DS.Space.l)
        }
      }
      .navigationDestination(isPresented: $showOrganizerTools) {
        OrganizerToolsView()
      }
      .onChange(of: showOrganizerTools) { _, isShown in
        largeDetentRequests.set(.organizerTools, active: isShown)
      }
      .navigationDestination(isPresented: $showAboutSensing) {
        AboutSensingView()
      }
      .onChange(of: showAboutSensing) { _, isShown in
        // 15 (and 16 pushed from it) stay at .large while 15 is in the stack.
        largeDetentRequests.set(.aboutSensing, active: isShown)
      }
    }
    .environmentObject(largeDetentRequests)
    .presentationDetents(
      largeDetentRequests.active.isEmpty ? [AccountSheetDetent.compact] : [.large],
      selection: $selectedDetent
    )
    .onChange(of: largeDetentRequests.active) { _, active in
      selectedDetent = active.isEmpty ? AccountSheetDetent.compact : .large
    }
    .sheet(isPresented: $coordinator.walletConnectSheetPresented) {
      WalletConnectSheetView()
        .environmentObject(coordinator)
    }
    .sheet(item: $supportShareItem) { item in
      SupportShareSheet(item: item)
    }
  }

  @ViewBuilder
  private var walletContent: some View {
    if let address = coordinator.walletAddress {
      VStack(alignment: .leading, spacing: DS.Space.s) {
        Text(walletHeader)
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondaryOnInk)
        // DECISIONS 2026-09-26: use Figma's Display/Address 34 typeface.
        Text(verbatim: truncated(address))
          .beidTextStyle(DS.Font.Library.displayAddress34)
          .foregroundStyle(DS.Color.actionInverse)
          .accessibilityLabel(Text(verbatim: address))
      }
      .padding(.bottom, DS.Space.l)
    } else {
      // 10b. DECISIONS 2026-09-26: wallet is optional, so voluntary connect
      // and reconnect stay here.
      VStack(alignment: .leading, spacing: DS.Space.s) {
        Text("Wallet · Not connected")
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondaryOnInk)
        HStack(spacing: DS.Space.s) {
          Text("No wallet")
            .beidTextStyle(DS.Font.Library.displayAddress34)
            .foregroundStyle(DS.Color.actionInverse)
            .layoutPriority(1)
          Spacer(minLength: 0)
          Button {
            BeidDesign.haptic()
            coordinator.connectWalletFromAccountSheet()
          } label: {
            BeidTextControlLabel(
              "Connect",
              glyph: .trailing("→", announcing: "Connect Wallet"),
              labelColor: DS.Color.actionInverse
            )
            .frame(minWidth: AccountSheetHitTarget.minimum, minHeight: AccountSheetHitTarget.minimum)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("account.wallet.connect")
        }
      }
      .padding(.bottom, DS.Space.m)
    }
  }

  /// DESIGN.md §12: an OS-standard toolbar item with an SF Symbol and a
  /// title; the OS draws its glass. 10e swaps it for the copied state.
  @ViewBuilder
  private func copyItem(address: String) -> some View {
    if copied {
      Button {
        UIPasteboard.general.string = address
      } label: {
        Label("Copied", systemImage: "checkmark")
      }
      .accessibilityLabel("Copied address")
      .accessibilityIdentifier("account.copy.feedback")
    } else {
      Button {
        BeidDesign.haptic()
        UIPasteboard.general.string = address
        copied = true
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
      }
      .accessibilityLabel("Copy address")
      .accessibilityIdentifier("account.copy")
    }
  }

  /// Figma's footer with beid as the product name (DECISIONS 2026-10-15)
  /// and AppVersion's complete build value (#491). It opens About sensing
  /// (15), which holds the sheet at its large detent like Organizer tools.
  private var aboutFooter: some View {
    Button {
      largeDetentRequests.set(.aboutSensing, active: true)
      selectedDetent = .large
      showAboutSensing = true
    } label: {
      Text(verbatim: footerText)
        .beidTextStyle(DS.Font.Library.labelMono9)
        .foregroundStyle(DS.Color.textSecondaryOnInk)
        .frame(maxWidth: .infinity, minHeight: AccountSheetHitTarget.minimum)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("About sensing")
        .accessibilityValue(Text(verbatim: "beid \(AppVersion.displayString())"))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("account.version.value")
    .background(DS.Color.textPrimary)
  }

  private var footerText: String {
    String(
      localized: "account.footer.about",
      defaultValue: "beid \(AppVersion.displayString()) · About →",
      comment: "Account sheet footer: product name and build, then a link to About sensing. The argument is the app version and build."
    )
  }

  private var walletHeader: String {
    // DECISIONS 2026-09-26: name the actual MetaMask connector rather than
    // Figma's WalletConnect protocol wording.
    String(
      localized: "account.wallet.header",
      defaultValue: "Wallet · Connected via \(connectorDisplayName)",
      comment: "Account sheet label naming the connected wallet provider."
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
    }
    .padding(.top, DS.Space.m)
    .accessibilityIdentifier("account.disconnect.confirmation")
  }

  private var disconnectConfirmationActions: some View {
    VStack(spacing: DS.Space.s) {
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
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)

      AccountTextControl(
        "Keep connected",
        labelColor: DS.Color.actionInverse,
        accessibilityLabel: "Keep connected"
      ) {
        showDisconnectConfirmation = false
      }
    }
    .frame(maxWidth: .infinity)
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

private enum AccountSheetHitTarget {
  // PM build #2: 44pt source size became 42.25pt in the native sheet's
  // XCTest frame. A 48pt label keeps its rendered button frame above 44pt.
  static let minimum = DS.Size.minHitTarget + DS.Space.xs
}

/// Account-local BeidTextControl label/button with a larger label hit region.
/// Keeping the minimum inside the Button label enlarges its real hit target,
/// rather than only the outer SwiftUI layout frame.
private struct AccountTextControl: View {
  let title: LocalizedStringKey
  let labelColor: Color
  let accessibilityLabel: LocalizedStringKey
  let action: () -> Void

  init(
    _ title: LocalizedStringKey,
    labelColor: Color,
    accessibilityLabel: LocalizedStringKey,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.labelColor = labelColor
    self.accessibilityLabel = accessibilityLabel
    self.action = action
  }

  var body: some View {
    Button {
      BeidDesign.haptic()
      action()
    } label: {
      BeidTextControlLabel(title, labelColor: labelColor, accessibilityLabel: accessibilityLabel)
        .frame(minWidth: AccountSheetHitTarget.minimum, minHeight: AccountSheetHitTarget.minimum)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// Measured screen-10 row geometry: 16pt row insets plus the system sheet's
/// 8pt side inset place content 24pt from the screen edge. Menu rows are
/// 52pt with a hairline; this stays local to Account.
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
      leading: DS.Space.m,
      bottom: 0,
      trailing: DS.Space.m
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

      // DECISIONS 2026-09-26 (#642 Q2 / #644): keep relay disclosure visible
      // below Bluetooth. This adds row height and moves later rows down.
      Text(verbatim: relayNote)
        .beidTextStyle(DS.Font.Library.body13)
        .foregroundStyle(DS.Color.textSecondaryOnInk)
        .padding(.bottom, DS.Space.s)
    }
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

#Preview("No wallet") {
  AccountSheetView().environmentObject(AppCoordinator())
}

#Preview("Wallet connected") {
  let coordinator = AppCoordinator()
  coordinator.walletAddress = "0x1234567890abcdef1234567890abcdef12345678"
  return AccountSheetView().environmentObject(coordinator)
}
