// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screen 04 (+04b empty state): Collection home.
struct CollectionHomeView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    CollectionHomeContent(
      proofStore: coordinator.proofStore,
      sensing: coordinator.sensingCoordinator
    )
    .environmentObject(coordinator)
  }
}

/// Observes the two stores directly: AppCoordinator does not republish their
/// changes, and recording inserts its Proof before the scan cover closes.
private struct CollectionHomeContent: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @ObservedObject var proofStore: ProofStore
  @ObservedObject var sensing: SensingCoordinator
  @State private var showsClockInstructions = false
  @State private var clockInstructionsForNetwork = false

  /// One row per distinct event. The newest dated session drives title/date
  /// and the existing detail route; every stored Proof remains session-level.
  private struct EventCard: Identifiable {
    let id: UUID
    let representative: Proof
    let sessionCount: Int
  }

  private var eventCards: [EventCard] {
    EventGrouping.homeGroups(
      from: proofStore.proofs,
      activeEventCode: activeEvent?.id
    ).map { group in
      EventCard(
        id: group[0].id,
        representative: group[0],
        sessionCount: group.count
      )
    }
  }

  private var activeEvent: EventSession? {
    switch sensing.phase {
    case .eventFound(let event), .recording(let event, _): return event
    case .idle, .sensing, .signalLost: return nil
    }
  }

  var body: some View {
    NavigationStack {
      ZStack {
        DS.Color.surfaceCanvas
          .ignoresSafeArea()

        ScrollView {
          BeidAdaptiveContent(regularMaxWidth: DS.Layout.collectionContentMaxWidth) {
            VStack(alignment: .leading, spacing: 0) {
              header
              Text("Events")
                .beidTextStyle(DS.Font.Library.display60)
                .foregroundStyle(DS.Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, DS.Space.s)

              HomeClockWarning(preflight: coordinator.clockPreflight) { stateKey in
                clockInstructionsForNetwork = stateKey != "overTolerance"
                showsClockInstructions = true
              }

              if let activeEvent {
                activeCard(for: activeEvent)
                  .padding(.top, DS.Space.l)
              }

              if eventCards.isEmpty && activeEvent == nil {
                emptyState
                  .padding(.top, DS.Space.l)
              } else {
                if !eventCards.isEmpty {
                  pastEvents
                    .padding(.top, DS.Space.l)
                }
              }

              // #644 has not settled Today. Keep its real destination visible
              // until an authorized navigation decision replaces it. Follow
              // the list's final rule with the same quiet text-control rhythm.
              BeidTextControl("collection.dailySummaryButton") {
                coordinator.dailySummaryPresented = true
              }
              .padding(.top, DS.Space.s)
            }
            .padding(.horizontal, DS.Space.pageMargin)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.s)
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          BeidAdaptiveContent(regularMaxWidth: DS.Layout.collectionContentMaxWidth) {
            VStack(spacing: 0) {
              if sensing.isScanning || sensing.isAdvertising {
                ContinuousSensingStatus(sensing: sensing)
                  .padding(.bottom, DS.Space.s)
              }
              scanButton
                .padding(.bottom, DS.Space.s)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DS.Space.pageMargin)
          }
          .background(DS.Color.surfaceCanvas)
        }
      }
      .toolbar(.hidden, for: .navigationBar)
      .sheet(isPresented: $coordinator.accountSheetPresented) {
        AccountSheetView()
          .environmentObject(coordinator)
          // Account owns its compact/large detent as destinations are pushed.
          .presentationDragIndicator(.visible)
          // Sheets don't inherit the presenter's .tint (unlike push
          // navigation) — without this, the Done/Connect Wallet buttons
          // render system blue. Same fix as AccountSheetView's own
          // WalletConnectSheetView doc comment already describes.
          .tint(DS.Color.actionPrimary)
          .presentationBackground(DS.Color.textPrimary)
      }
      .sheet(isPresented: $coordinator.homeEventCodeSheetPresented) {
        HomeEventCodeEntrySheet()
          .environmentObject(coordinator)
      }
      .navigationDestination(isPresented: $coordinator.dailySummaryPresented) {
        DailySummaryView()
          .toolbar(.visible, for: .navigationBar)
      }
      .navigationDestination(item: $coordinator.selectedProof) { proof in
        ItemDetailView(proof: proof)
          .toolbar(.visible, for: .navigationBar)
      }
      .alert(
        clockInstructionsTitle,
        isPresented: $showsClockInstructions
      ) {
        Button("Check again") {
          Task { await coordinator.clockPreflight.check(force: true) }
        }
        Button("Close", role: .cancel) {}
      } message: {
        if clockInstructionsForNetwork {
          Text("Connect to the network, then check the clock again before joining an event.")
        } else {
          Text("Open Settings, choose General, then Date & Time, and turn on Set Automatically.")
        }
      }
      .task {
        // Home owns frame 04c. Keep startScan's check and the nearby-event
        // join-time recheck too: both can catch a clock change after Home.
        await coordinator.checkClockOnHome()
      }
    }
  }

  private var clockInstructionsTitle: String {
    if clockInstructionsForNetwork {
      return String(
        localized: "home.clock.networkInstructions.title",
        defaultValue: "Check your connection",
        comment: "Title of Home clock help when beid could not compare the device clock with network time."
      )
    }
    return String(
      localized: "home.clock.timeInstructions.title",
      defaultValue: "Set the time automatically",
      comment: "Title of Home clock help when network comparison found the device clock outside tolerance."
    )
  }

  private var header: some View {
    HStack {
      Text(headerCountText)
        .beidTextStyle(DS.Font.Library.labelMono11)
        .foregroundStyle(DS.Color.textSecondary)
      Spacer()
    }
    .frame(height: DS.Space.m)
    .overlay(alignment: .topTrailing) {
      Button {
        coordinator.accountSheetPresented = true
      } label: {
        Text(verbatim: accountCaption)
          .beidTextStyle(DS.Font.Library.labelMono11Time)
          .foregroundStyle(DS.Color.textPrimary)
          .frame(minWidth: DS.Size.minHitTarget, minHeight: DS.Size.minHitTarget, alignment: .topTrailing)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(accountAccessibilityLabel)
      .accessibilityIdentifier("home.account")
    }
  }

  private var headerCountText: String {
    let events = eventCards.count + (activeEvent == nil ? 0 : 1)
    let proofs = proofStore.proofs.count
    return String(
      localized: "home.header.counts",
      defaultValue: "\(events) events · \(proofs) proofs",
      comment: "Collection Home header: distinct event count, including the active event, followed by the total stored Proof record count. Each noun must inflect independently for its count."
    )
  }

  private var accountAccessibilityLabel: String {
    String(
      localized: "home.account.accessibilityLabel",
      defaultValue: "Account, \(accountCaption)",
      comment: "VoiceOver label for the Collection Home account control. The inserted value is either a shortened wallet address or the localized word Account when no wallet is connected."
    )
  }

  private var accountCaption: String {
    guard let address = coordinator.walletAddress, address.count > 10 else {
      return String(
        localized: "home.account.title",
        defaultValue: "Account",
        comment: "Collection Home account control when no wallet address is available; opens the account sheet."
      )
    }
    return "\(address.prefix(6))…\(address.suffix(4))"
  }

  /// Figma 04 places the mutual count here. The value is read from the live
  /// shared aggregate; current production observations carry no reciprocal
  /// evidence, so it evaluates to 0 without a hard-coded display value.
  private func activeCard(for event: EventSession) -> some View {
    HStack(alignment: .top, spacing: DS.Space.m) {
      RecordSigilSlot(recordID: sensing.currentProofID, size: 84, ground: .ink)
      VStack(alignment: .leading, spacing: DS.Space.xs) {
        Text("NOW · SENSING")
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondaryOnInk)
        Text(verbatim: event.name)
          .beidTextStyle(DS.Font.Library.title19)
          .foregroundStyle(DS.Color.labelOnActionPrimary)
          .lineLimit(2)
        // nil precedes the first observation, so all three observed counts
        // are zero; subsequent values always come from the shared aggregate.
        let mutual = sensing.sessionAggregate.map { Int($0.mutualDeviceCount) } ?? 0
        let detected = sensing.sessionAggregate.map { Int($0.deviceCount) } ?? 0
        let windows = sensing.sessionAggregate.map { Int($0.windowCount) } ?? 0
        Text(activeMetricsText(mutual: mutual, windows: windows))
          .beidTextStyle(DS.Font.Library.labelMono11Time)
          .foregroundStyle(DS.Color.textSecondaryOnInk)
          .accessibilityLabel(activeMetricsAccessibilityLabel(
            mutual: mutual, detected: detected, windows: windows
          ))
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, DS.Space.m)
    .padding(.vertical, DS.Space.l)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      DS.Color.textPrimary,
      in: RoundedRectangle(cornerRadius: DS.Radius.nowCard, style: .continuous)
    )
    .overlay(alignment: .bottomTrailing) {
      BeidTextControl(
        "OPEN", glyph: .trailing("→", announcing: "Open sensing event"),
        labelColor: DS.Color.labelOnActionPrimary
      ) {
        coordinator.scanPresented = true
      }
      .padding(.trailing, DS.Space.s)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("home.active-event")
  }

  private func activeMetricsText(mutual: Int, windows: Int) -> String {
    String(
      localized: "home.active.metrics",
      defaultValue: "\(mutual) mutual · window \(windows)",
      comment: "Live active event metrics: number of mutually observed devices from SessionAggregate and the current sensing window count. A zero mutual count is truthful when there is no reciprocal evidence."
    )
  }

  private func activeMetricsAccessibilityLabel(mutual: Int, detected: Int, windows: Int) -> String {
    String(
      localized: "home.active.metrics.accessibilityLabel",
      defaultValue: "\(mutual) mutual, \(detected) detected, window \(windows)",
      comment: "VoiceOver expansion of the active event metrics. Mutual and detected are separate live counts; window is the sensing window count."
    )
  }

  private var pastEvents: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("PAST")
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondary)
      hairline
        .padding(.top, DS.Space.s)
      ForEach(eventCards) { card in
        pastEventRow(card)
        hairline
      }
    }
  }

  private var hairline: some View {
    Rectangle()
      .fill(DS.Color.strokeHairline)
      .frame(height: DS.Size.hairline)
  }

  private func pastEventRow(_ card: EventCard) -> some View {
    Button {
      BeidDesign.haptic()
      coordinator.openProof(card.representative)
    } label: {
      HStack(spacing: 0) {
        RecordSigilSlot(recordID: card.representative.id, size: 60, ground: .canvas)
          .padding(.trailing, DS.Space.m)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
          Text(verbatim: card.representative.eventName)
            .beidTextStyle(DS.Font.Library.title17)
            .foregroundStyle(DS.Color.textPrimary)
            .lineLimit(1)
          Text(pastSessionCaption(card))
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textSecondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(pastProofAction(card))
          .beidTextStyle(DS.Font.Library.labelMono11Time)
          .foregroundStyle(DS.Color.textPrimary)
          .fixedSize(horizontal: true, vertical: false)
          .padding(.leading, DS.Space.s)
      }
      .frame(minHeight: DS.Size.listRowMinHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(pastEventAccessibilityLabel(card))
  }

  private func pastSessionCaption(_ card: EventCard) -> String {
    let date = eventDate(card.representative.date)
    let sessions = card.sessionCount
    return String(
      localized: "home.past.sessionCaption",
      defaultValue: "\(date) · \(sessions) sessions",
      comment: "Past event row: its latest session date followed by the number of stored recording sessions in that event group."
    )
  }

  private func pastProofAction(_ card: EventCard) -> String {
    let proofs = card.sessionCount
    return String(
      localized: "home.past.proofAction",
      defaultValue: "\(proofs) proofs →",
      comment: "Trailing action on a past event row. Count is the number of stored Proof records in that event group; the arrow means open its newest proof detail."
    )
  }

  private func pastEventAccessibilityLabel(_ card: EventCard) -> String {
    let eventName = card.representative.eventName
    let proofs = card.sessionCount
    return String(
      localized: "home.past.accessibilityLabel",
      defaultValue: "\(eventName), \(proofs) proofs, open event",
      comment: "VoiceOver label for a past event row. The inserted event name is operator supplied; the count is its stored Proof records, and activating opens the newest proof detail."
    )
  }

  private func eventDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MMM d"
    let year = Calendar.current.component(.year, from: date)
    let currentYear = Calendar.current.component(.year, from: Date())
    let monthDay = formatter.string(from: date).uppercased()
    return year < currentYear - 1 ? "\(monthDay) \(year)" : monthDay
  }

  private var scanButton: some View {
    Button {
      BeidDesign.haptic()
      coordinator.startScan()
    } label: {
      Text(String(
        localized: "home.scan.action",
        defaultValue: "Scan",
        comment: "Primary Collection Home button: verb meaning start sensing nearby events."
      ))
        .beidTextStyle(DS.Font.Library.title16)
        .foregroundStyle(DS.Color.labelOnActionPrimary)
        .frame(minWidth: DS.Size.compactPrimaryButtonWidth, minHeight: DS.Size.compactPrimaryButtonMinHeight)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(DS.Color.actionPrimary, in: Capsule())
    .accessibilityIdentifier("home.scan")
  }

  private var emptyState: some View {
    VStack(spacing: DS.Space.s) {
      BeidEmptyBlock {
        VStack(spacing: DS.Space.s) {
          Text("NO EVENTS YET")
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textPrimary)
          Text(String(
            localized: "home.empty.description",
            defaultValue: "Walk into an event — it will show up\nhere automatically.",
            comment: "Collection Home empty-state explanation. The English line break after show up matches the two-line design; other locales may wrap as needed."
          ))
            .beidTextStyle(DS.Font.Library.body13)
            .foregroundStyle(DS.Color.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      BeidTextControl(
        "ENTER EVENT CODE", glyph: .trailing("→", announcing: "Enter event code")
      ) {
        coordinator.homeEventCodeSheetPresented = true
      }
      .frame(maxWidth: .infinity)
    }
  }
}

/// 04c's measured Home placement, driven by the same controller that Scan
/// continues to check. The offset is deliberately omitted: the production
/// controller exposes a verdict but no signed clock difference. FIX opens
/// instructions and a retry; iOS supplies no Date & Time Settings deep link.
private struct HomeClockWarning: View {
  @ObservedObject var preflight: ClockPreflightController
  let onFix: (String) -> Void

  @ViewBuilder
  var body: some View {
    if let stateKey = preflight.stateKey, stateKey != "withinTolerance" {
      VStack(alignment: .leading, spacing: 0) {
        hairline
        HStack(spacing: DS.Space.s) {
          Circle()
            .fill(DS.Color.statusPending)
            .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
            .accessibilityHidden(true)
          if stateKey == "overTolerance" {
            Text("CLOCK OUT OF SYNC")
              .beidTextStyle(DS.Font.Library.labelMono11)
              .foregroundStyle(DS.Color.textPrimary)
              .accessibilityAddTraits(.isHeader)
          } else {
            Text("CLOCK CHECK UNAVAILABLE")
              .beidTextStyle(DS.Font.Library.labelMono11)
              .foregroundStyle(DS.Color.textPrimary)
              .accessibilityAddTraits(.isHeader)
          }
        }
        .padding(.top, DS.Space.m)
        if stateKey == "overTolerance" {
          Text("Proofs need an accurate clock. Turn on “Set automatically” in Settings.")
            .beidTextStyle(DS.Font.Library.body13)
            .foregroundStyle(DS.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, DS.Space.m)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.s)
        } else {
          Text("beid couldn't compare the clock with the network. Check your connection, then try again.")
            .beidTextStyle(DS.Font.Library.body13)
            .foregroundStyle(DS.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, DS.Space.m)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.s)
        }
        hairline
      }
      .padding(.top, DS.Space.m)
      .overlay(alignment: .topTrailing) {
        BeidTextControl("FIX", glyph: .trailing("→", announcing: "Clock help")) {
          onFix(stateKey)
        }
        .padding(.top, DS.Space.m)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("home.clock-warning")
    }
  }

  private var hairline: some View {
    Rectangle()
      .fill(DS.Color.strokeHairline)
      .frame(height: DS.Size.hairline)
  }
}

/// Home's post-onboarding event-code action has a separate sheet flag from
/// Account's, so their private wrappers never compete for one presentation.
private struct HomeEventCodeEntrySheet: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    NavigationStack {
      EventCodeEntryView(mode: .home)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) {
              coordinator.cancelPendingAccountSheetJoinAttempt()
              coordinator.homeEventCodeSheetPresented = false
            }
          }
          .beidWithoutSharedBackground()
        }
    }
    .tint(DS.Color.actionPrimary)
  }
}

/// Compact home-surface status for sensing that continues after the scan
/// sheet closes (beid#200). This is a separate observed view because
/// `AppCoordinator` intentionally does not republish nested sensing state.
private struct ContinuousSensingStatus: View {
  @ObservedObject var sensing: SensingCoordinator

  var body: some View {
    if isSensing {
      BeidPanel {
        HStack(spacing: DS.Space.m) {
          Text("Sensing continues in background")
            .font(DS.Font.supporting)
            .foregroundStyle(DS.Color.textPrimary)
            .accessibilityIdentifier("collection.continuous-sensing")

          Spacer(minLength: DS.Space.s)

          BeidTextControl("Stop sensing") {
            sensing.stopSensing()
          }
          .accessibilityIdentifier("collection.stop-sensing")
        }
      }
    }
  }

  private var isSensing: Bool {
    sensing.isScanning || sensing.isAdvertising
  }
}

#Preview("Empty") {
  CollectionHomeView().environmentObject(AppCoordinator())
}

#Preview("Populated") {
  let coordinator = AppCoordinator()
  coordinator.proofStore.add(Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))
  coordinator.proofStore.add(Proof(eventName: "Devcon SEA", date: Date().addingTimeInterval(-86400 * 3), peersVerified: 7))
  coordinator.proofStore.add(Proof(eventName: "beid Meetup", date: Date().addingTimeInterval(-86400 * 30), peersVerified: 1))
  return CollectionHomeView().environmentObject(coordinator)
}

/// A multi-session group (shared `eventCode`) beside a single-session event,
/// so Home's grouped row count and plural labels are visible in preview.
/// The two ETHGlobal Tokyo records keep distinct seeds as stored sample data;
/// Home now displays neutral Sigil slots rather than gradient artwork.
#Preview("Populated with multi-session event") {
  let coordinator = AppCoordinator()
  coordinator.proofStore.add(Proof(
    eventName: "ETHGlobal Tokyo", date: Date().addingTimeInterval(-86400 * 5),
    peersVerified: 3, gradientSeed: 111, eventCode: "ETHTOKYO"
  ))
  coordinator.proofStore.add(Proof(
    eventName: "ETHGlobal Tokyo", date: Date(),
    peersVerified: 5, gradientSeed: 999, eventCode: "ETHTOKYO"
  ))
  coordinator.proofStore.add(Proof(eventName: "Devcon SEA", date: Date().addingTimeInterval(-86400 * 3), peersVerified: 7))
  return CollectionHomeView().environmentObject(coordinator)
}
