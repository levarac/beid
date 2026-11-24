// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

/// Account screen 10. H1 removes all wallet rows in v1.1; Bluetooth,
/// Organizer tools, privacy, support and the existing sensing routes remain.
struct AccountSheetView: View {
  private enum Destination: Hashable {
    case organizerTools
    case pastEvents
    case aboutSensing
  }

  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.dismiss) private var dismiss
  @State private var path: [Destination] = []
  @State private var supportShareItem: SupportShareItem?

  var body: some View {
    NavigationStack(path: $path) {
      List {
        AccountBluetoothRow(monitor: coordinator.bluetoothMonitor, relayNote: relayNoteText)
        Section {
          NavigationLink("Organizer tools", value: Destination.organizerTools)
            .accessibilityLabel("Organizer tools")

          // Row removal is a separate decision in beid#852.
          NavigationLink(pastEventsLabel, value: Destination.pastEvents)
            .accessibilityLabel("Past events")

          NavigationLink("About sensing", value: Destination.aboutSensing)
            .accessibilityIdentifier("account.aboutSensing")
            .accessibilityLabel("About sensing")

          Link("Privacy Policy", destination: URL(string: "https://levarac.org/privacy")!)
            .accessibilityIdentifier("account.privacy-policy")
        }
        // Account Join retains the existing event-code route.
        // Sensing ends through STOP SENSING in the details opened from Now.
        EventMembershipSections(sensingCoordinator: coordinator.sensingCoordinator)
        // beid#466: export a frozen snapshot only after the user's action.
        Section {
          Button("Share support information") {
            supportShareItem = SupportShareItem(text: coordinator.supportDiagnostics.exportJson())
          }
          .accessibilityIdentifier("account.support.share")
        } footer: {
          Text("Includes app version, recent states and failure reasons from this app session. Choose who to share it with.")
        }
      }
      .listStyle(.insetGrouped)
      .environment(\.defaultMinListRowHeight, AccountSheetHitTarget.minimum)
      .navigationTitle("Account")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar(.visible, for: .navigationBar)
      .toolbar {
        if path.isEmpty {
          ToolbarItem(placement: .confirmationAction) {
            Button {
              BeidDesign.haptic()
              dismiss()
            } label: {
              Text("Done")
                .frame(minWidth: AccountSheetHitTarget.minimum, minHeight: AccountSheetHitTarget.minimum)
            }
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        Text(verbatim: "beid \(AppVersion.displayString())")
          .beidTextStyle(DS.Font.Library.labelMono9)
          .foregroundStyle(DS.Color.textSecondary)
          .accessibilityIdentifier("account.version.value")
          .frame(maxWidth: .infinity)
          .padding(.vertical, DS.Space.s)
          .background(DS.Color.surfaceCanvas)
      }
      .navigationDestination(for: Destination.self) { destination in
        switch destination {
        case .organizerTools:
          OrganizerToolsView()
            .navigationTitle("Organizer tools")
        case .pastEvents:
          PastEventsView(
            sensingCoordinator: coordinator.sensingCoordinator,
            proofStore: coordinator.proofStore,
            onRejoin: { code in
              Task { @MainActor in
                await coordinator.rejoinPastEventResolvingCanonicalId(code: code)
              }
            }
          )
        case .aboutSensing:
          AboutSensingView()
        }
      }
    }
    .background(DS.Color.surfaceCanvas)
    .presentationDetents([.large])
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
        While this device is at an event, beid can pass the event's details on to devices \
        nearby, so people across the venue can still find it.
        """
    )
  }


}

private enum AccountSheetHitTarget {
  // Keep rendered controls above 44pt after the system sheet's scaling.
  static let minimum = DS.Size.minHitTarget + DS.Space.xs
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
    Section {
      if isOff {
        Button {
          UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        } label: {
          statusRow
        }
        .accessibilityLabel("Open Bluetooth Settings")
        .accessibilityIdentifier("account.bluetooth.status")
      } else {
        statusRow
      }
    } footer: {
      VStack(alignment: .leading, spacing: DS.Space.s) {
        if isOff {
          Text("Sensing is paused until Bluetooth is on. Tap to open Settings.")
        }
        // DECISIONS 2026-09-26 (#642 Q2 / #644): keep relay disclosure visible.
        Text(verbatim: relayNote)
      }
    }
  }

  private var statusRow: some View {
    HStack(spacing: DS.Space.s) {
      Text("Bluetooth")
      Spacer()
      Circle()
        .fill(isOff ? DS.Color.statusOff : DS.Color.statusOn)
        .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
        .accessibilityHidden(true)
      if isOff {
        Text("Off · Fix")
      } else {
        Text("Active")
          .foregroundStyle(DS.Color.textSecondary)
          .accessibilityIdentifier("account.bluetooth.status")
      }
    }
    .frame(minHeight: AccountSheetHitTarget.minimum)
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
    Section {
      Button(joinEventLabel) {
        BeidDesign.haptic()
        coordinator.openEventCodeEntryFromAccountSheet()
      }
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
