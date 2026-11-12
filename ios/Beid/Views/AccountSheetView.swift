// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

private enum AccountSheetDetent {
  static let compact: PresentationDetent = .fraction(0.575)
}

/// Destinations request the large Account sheet while they are in its stack.
/// Separate keys let future Account routes (About sensing / What we send)
/// register without coupling their navigation state to Organizer tools.
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

/// Flat 2b screen 10. H1 removes all wallet rows in v1.1; Bluetooth,
/// Organizer tools, privacy, support and the existing sensing routes remain.
struct AccountSheetView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.dismiss) private var dismiss
  @State private var showOrganizerTools = false
  @State private var showPastEvents = false
  @State private var showAboutSensing = false
  @State private var supportShareItem: SupportShareItem?
  @StateObject private var largeDetentRequests = AccountLargeDetentRequests()
  @State private var selectedDetent: PresentationDetent = AccountSheetDetent.compact

  var body: some View {
    NavigationStack {
      List {
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
        // DECISIONS 2026-09-26: keep the sole Past events/rejoin path as an
        // extra Account row below the three Figma menu rows.
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
          .accessibilityLabel("Past events")
        }
        AccountSheetRow {
          Button {
            largeDetentRequests.set(.aboutSensing, active: true)
            selectedDetent = .large
            showAboutSensing = true
          } label: {
            HStack {
              Text("About sensing")
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
          .accessibilityIdentifier("account.aboutSensing")
          .accessibilityLabel("About sensing")
        }
        AccountSheetRow {
          Link("Privacy Policy", destination: URL(string: "https://levarac.org/privacy")!)
            .beidTextStyle(DS.Font.Library.title17)
            .foregroundStyle(DS.Color.actionInverse)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: DS.Size.sessionRowMinHeight + DS.Space.xs)
            .accessibilityIdentifier("account.privacy-policy")
        }
        // Account Join retains the existing event-code route.
        // Sensing ends through STOP SENSING in the details opened from Now.
        EventMembershipSections(sensingCoordinator: coordinator.sensingCoordinator)
        // beid#466: a user-initiated, frozen support snapshot. Flat 2b
        // text row (#631 keeps icons out of controls); its explanation
        // sits under the action like the Bluetooth relay note.
        AccountSheetRow {
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
      .listStyle(.plain)
      // Keep Done clear of the first row at the compact detent.
      .contentMargins(.top, DS.Space.l + DS.Space.xs, for: .scrollContent)
      .scrollContentBackground(.hidden)
      .background(DS.Color.textPrimary)
      .foregroundStyle(DS.Color.actionInverse)
      // The root sheet has no navigation bar in Figma. Hiding it removes its
      // ~44pt content offset; pushed destinations restore the stock back bar.
      .toolbar(.hidden, for: .navigationBar)
      .overlay(alignment: .topTrailing) {
        // DECISIONS 2026-09-26: retain an accessible Done dismissal even
        // though Figma 10 shows only the grabber. The overlay uses no space.
        AccountTextControl(
          "Done",
          labelColor: DS.Color.actionInverse,
          accessibilityLabel: "Done"
        ) { dismiss() }
        .padding(.trailing, DS.Space.m)
        .padding(.top, DS.Space.s)
      }
      .safeAreaInset(edge: .bottom) {
        Text(verbatim: "beid \(AppVersion.displayString())")
          .beidTextStyle(DS.Font.Library.labelMono9)
          .foregroundStyle(DS.Color.textSecondaryOnInk)
          .accessibilityIdentifier("account.version.value")
          .frame(maxWidth: .infinity)
          .padding(.vertical, DS.Space.s)
          .background(DS.Color.textPrimary)
      }
      .navigationDestination(isPresented: $showOrganizerTools) {
        OrganizerToolsView()
          .toolbar(.visible, for: .navigationBar)
      }
      .onChange(of: showOrganizerTools) { _, isShown in
        largeDetentRequests.set(.organizerTools, active: isShown)
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
        .toolbar(.visible, for: .navigationBar)
      }
      .navigationDestination(isPresented: $showAboutSensing) {
        AboutSensingView()
          .toolbar(.visible, for: .navigationBar)
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
    .sheet(item: $supportShareItem) { item in
      SupportShareSheet(item: item)
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

  private var pastEventsLabel: String {
    String(
      localized: "account.pastEvents.label",
      defaultValue: "Past events",
      comment: "Account row opening previously joined events, including the rejoin action."
    )
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

/// Sheet wrapper around `EventCodeEntryView` (in `.accountSheet` mode) for
/// the Account sheet's "Join event" action. Unlike `EventCodeEntryView`'s
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
            BeidTextControl("Cancel", accessibilityLabel: "Cancel", role: .cancel) {
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

/// "Join event" row for `AccountSheetView`. `AppCoordinator` holds its
/// sensing coordinator as a plain `let` and does not re-publish changes to
/// its state. Observe it here so the row follows `canSelectEventToJoin`:
/// enabled while idle and disabled during a live session. STOP enables it
/// again even though `joinedEventCode` remains set.
private struct EventMembershipSections: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @ObservedObject var sensingCoordinator: SensingCoordinator

  var body: some View {
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
      .disabled(!sensingCoordinator.canSelectEventToJoin)
    }
  }

  private var joinEventLabel: String {
    String(
      localized: "account.joinEvent.label",
      defaultValue: "Join event",
      comment: "Menu row in the Account sheet that opens the manual event-code entry form. Distinct from that form's own submit button, which is also labeled \"Join event\" in English but is a separate translation unit and may need different wording in other languages."
    )
  }

}

#Preview {
  AccountSheetView().environmentObject(AppCoordinator())
}
