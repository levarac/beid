// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

/// Now owns current participation; Records owns stored records and events.
struct CollectionHomeView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    TabView(selection: $coordinator.selectedHomeTab) {
      NowHomeView(sensing: coordinator.sensingCoordinator, bluetooth: coordinator.bluetoothMonitor)
        .tabItem { Label("home.now.title", systemImage: "antenna.radiowaves.left.and.right") }
        .tag(HomeTab.now)
      RecordsHomeView(proofStore: coordinator.proofStore, sensing: coordinator.sensingCoordinator)
        .tabItem { Label("records.title", systemImage: "square.grid.2x2") }
        .tag(HomeTab.records)
    }
    .sheet(isPresented: $coordinator.accountSheetPresented) {
      AccountSheetView()
        .environmentObject(coordinator)
        .presentationDragIndicator(.visible)
        .tint(DS.Color.actionPrimary)
        .presentationBackground(DS.Color.textPrimary)
    }
    .sheet(isPresented: $coordinator.homeEventCodeSheetPresented) {
      HomeEventCodeEntrySheet().environmentObject(coordinator)
    }
  }
}

private struct HomeAccountToolbar: ViewModifier {
  @EnvironmentObject private var coordinator: AppCoordinator
  let title: LocalizedStringKey
  let iconColor: Color

  func body(content: Content) -> some View {
    content
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("home.account.title", systemImage: "person.crop.circle") {
            coordinator.accountSheetPresented = true
          }
          .tint(iconColor)
          .accessibilityIdentifier("home.account")
        }
      }
  }
}

private struct NowHomeView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ObservedObject var sensing: SensingCoordinator
  @ObservedObject var bluetooth: BluetoothMonitor
  @State private var isRootVisible = false
  @State private var showAboutSensing = false
  @State private var showWhatWeSend = false
  @State private var showsClockInstructions = false
  @State private var clockInstructionsForNetwork = false

  private var activeEvent: EventSession? {
    switch sensing.phase {
    case .eventFound(let event), .recording(let event, _), .signalLost(let event, _): return event
    case .idle, .sensing: return nil
    }
  }

  private var isIdle: Bool {
    if case .idle = sensing.phase { return true }
    return false
  }

  private var usesInk: Bool { !isIdle || sensing.isAdvertising }
  private var foreground: Color { usesInk ? DS.Color.labelOnActionPrimary : DS.Color.textPrimary }
  private var secondary: Color { usesInk ? DS.Color.textSecondaryOnInk : DS.Color.textSecondary }

  var body: some View {
    NavigationStack {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        ScrollView {
          BeidLargeTitleContent(regularMaxWidth: DS.Layout.collectionContentMaxWidth) {
            VStack(alignment: .leading, spacing: DS.Space.l) {
              HomeUnsentNotice(store: coordinator.reportSubmissionStore, usesInk: usesInk)
              #if DEBUG
              if coordinator.isPendingRecordFixture {
                Button("Accept pending fixture record") { coordinator.acceptPendingRecordForUITesting() }
                  .accessibilityIdentifier("home.pending-fixture.accept")
              }
              #endif
              if !isIdle && coordinator.homeBluetoothIsOff { bluetoothOff }
              if let event = activeEvent {
                activeSummary(event: event, now: context.date)
              } else if isIdle, let saved = coordinator.sealedSnapshot {
                savedSummary(saved)
              } else if isIdle && sensing.isAdvertising {
                continuingSummary
              } else if !isIdle {
                joiningSummary
              } else {
                standbyContent
              }
              #if DEBUG
              if coordinator.isHomeStandbyFixture { standbyFixtureControls }
              if coordinator.stopOutcomeUITestFixture != nil {
                Button("Repeat STOP confirmation") { coordinator.confirmStopSensing() }
                  .accessibilityIdentifier("stop.fixture.repeat-confirmation")
              }
              #endif
            }
            .padding(.vertical, DS.Space.s)
          }
        }
        .accessibilityIdentifier("home.now")
        .background(usesInk ? DS.Color.textPrimary : DS.Color.surfaceCanvas, ignoresSafeAreaEdges: .bottom)
      }
      .background(DS.Color.surfaceCanvas.ignoresSafeArea())
      .modifier(HomeAccountToolbar(title: "home.now.title", iconColor: DS.Color.textPrimary))
      .toolbarBackground(usesInk ? DS.Color.textPrimary : DS.Color.surfaceCanvas, for: .tabBar)
      .toolbarBackground(.hidden, for: .navigationBar)
      .toolbarColorScheme(.light, for: .navigationBar)
      .toolbarColorScheme(usesInk ? .dark : .light, for: .tabBar)
      .navigationDestination(isPresented: $showAboutSensing) { AboutSensingView() }
      .navigationDestination(isPresented: $showWhatWeSend) { WhatWeSendView() }
      .navigationDestination(isPresented: $coordinator.scanPresented) {
        let routeID = coordinator.scanRouteID
        ScanFlowView(sensing: sensing)
          .environmentObject(coordinator)
          .onDisappear { coordinator.scanRouteDidDisappear(routeID) }
          .id(routeID)
      }
      .navigationDestination(item: $coordinator.selectedProof) { proof in
        HomeRecordDetail(proof: proof)
      }
      .onAppear { isRootVisible = true; refreshStandby() }
      .onDisappear { isRootVisible = false; refreshStandby() }
      .task { await coordinator.checkClockOnHome() }
      .alert(clockInstructionsTitle, isPresented: $showsClockInstructions) {
        Button("Check again") { Task { await coordinator.clockPreflight.check(force: true) } }
        Button("Close", role: .cancel) {}
      } message: {
        if clockInstructionsForNetwork {
          Text("Connect to the network, then check the clock again before joining an event.")
        } else {
          Text("Open Settings, choose General, then Date & Time, and check the time settings.")
        }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if !coordinator.scanPresented {
        if phase == .background { sensing.checkpointOpenWindowForBackgrounding() }
        if phase == .active { sensing.retryPendingSubmissionsOnForeground() }
      }
      refreshStandby()
    }
    .onChange(of: coordinator.selectedHomeTab) { _, _ in refreshStandby() }
    .onChange(of: coordinator.scanPresented) { _, isPresented in
      if !isPresented, coordinator.stopConfirmSnapshot != nil {
        coordinator.keepSensing()
      }
      refreshStandby()
    }
    .onChange(of: coordinator.accountSheetPresented) { _, _ in refreshStandby() }
    .onChange(of: coordinator.homeEventCodeSheetPresented) { _, _ in refreshStandby() }
    .onChange(of: bluetooth.state) { _, _ in refreshStandby() }
    .onChange(of: sensing.isAdvertising) { _, _ in refreshStandby() }
    .onChange(of: sensing.phase) { _, _ in refreshStandby() }
    .onChange(of: sensing.nearbyEventCandidates.candidateCount) { _, _ in refreshStandby() }
    // Joinability can change with the count unchanged (registry resolution
    // completes, a definition's validity expires), and the code-entry timer
    // follows joinability.
    .onChange(of: nearby.cards.compactMap(\.joinActionEventCodeHashHex)) { _, _ in refreshStandby() }
    .onChange(of: sensing.homeDemoEventAvailable) { _, _ in refreshStandby() }
    #if DEBUG
    .onChange(of: coordinator.homeStandbyFixtureHasCandidate) { _, _ in refreshStandby() }
    #endif
  }

  private var clockInstructionsTitle: String {
    if clockInstructionsForNetwork {
      return String(localized: "home.clock.networkInstructions.title", defaultValue: "Check your connection")
    }
    return String(localized: "home.clock.timeInstructions.title", defaultValue: "Check your device's time")
  }

  private func refreshStandby() {
    coordinator.updateHomeStandby(isVisible: isRootVisible, isSceneActive: scenePhase == .active)
  }

  private var nearby: NearbyEventCardListPresentation {
    NearbyEventCardListPresentation(
      candidates: sensing.nearbyEventCandidates,
      nowEpochSeconds: Int64(Date().timeIntervalSince1970.rounded(.down))
    )
  }

  private var standbyContent: some View {
    VStack(alignment: .leading, spacing: DS.Space.l) {
      HomeClockWarning(preflight: coordinator.clockPreflight) { stateKey in
        clockInstructionsForNetwork = stateKey != "overTolerance"
        showsClockInstructions = true
      }
      if coordinator.homeBluetoothIsOff {
        bluetoothOff
      } else {
        listeningStrip
        if coordinator.homeHasDemoCandidate {
          instructionTile(
            title: "Try sensing with a demo event.",
            body: "Tap JOIN to start the demo."
          )
          demoCandidate
        } else {
          instructionTile(
            title: "Keep the app open and head to the venue.",
            body: "beid listens for nearby events over Bluetooth. Tap your event’s card or row to join."
          )
          if let first = nearby.cards.first {
            candidateCard(first)
            if nearby.cards.count > 1 { additionalCandidates }
          }
        }
        if nearby.hasOmittedEvents {
          Text("Some nearby events are not shown.")
            .beidTextStyle(DS.Font.Library.body13)
            .foregroundStyle(DS.Color.textSecondary)
        }
        if let card = nearby.cards.first, let registration = coordinator.homeRegistration(for: card) {
          organizerTile(registration)
        }
        if coordinator.homeStandby.offersCodeEntry(at: coordinator.homeStandbyNow) {
          BeidTextControl("ENTER EVENT CODE", glyph: .trailing("→", announcing: "Enter event code")) {
            coordinator.homeEventCodeSheetPresented = true
          }
          .accessibilityIdentifier("home.enter-code")
        }
      }
      BeidTextControl("HOW SENSING WORKS", glyph: .trailing("→", announcing: "How sensing works"),
                      labelColor: DS.Color.textSecondary) { showAboutSensing = true }
        .accessibilityIdentifier("home.aboutSensing")
      #if DEBUG
      if NearbyJoinUITestFixture.isEnabled { NearbyJoinUITestReceipt() }
      #endif
    }
    .foregroundStyle(DS.Color.textPrimary)
  }

  private var listeningStrip: some View {
    HStack(spacing: DS.Space.s) {
      Circle()
        .fill(DS.Color.textPrimary)
        .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
        .accessibilityHidden(true)
      Text("LISTENING FOR EVENTS NEARBY")
        .beidTextStyle(DS.Font.Library.labelMono10)
        .accessibilityIdentifier("home.listening")
      Spacer(minLength: 0)
      Text(elapsedString(coordinator.homeStandby.elapsed(at: coordinator.homeStandbyNow)))
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondary)
    }
    .padding(.vertical, DS.Space.m)
    .overlay(alignment: .top) { Divider() }
    .overlay(alignment: .bottom) { Divider() }
  }

  private var bluetoothOff: some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
      Text("BLUETOOTH OFF · SENSING PAUSED")
        .beidTextStyle(DS.Font.Library.labelMono11)
        .foregroundStyle(DS.Color.statusOff)
      BeidTextControl("FIX", glyph: .trailing("→", announcing: "Turn on Bluetooth")) {
        coordinator.screen = .bluetoothOff
      }
      .accessibilityIdentifier("home.bluetooth.fix")
      instructionTile(
        title: "Turn Bluetooth back on.",
        body: "Your records are safe. Sensing resumes when Bluetooth is back."
      )
      .foregroundStyle(foreground)
      BeidTextControl("OPEN SETTINGS", glyph: .trailing("→", announcing: "Open Settings"),
                      labelColor: foreground) {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
      }
      .accessibilityIdentifier("home.bluetooth.open-settings")
    }
    .padding(.vertical, DS.Space.m)
  }

  private func candidateCard(_ card: NearbyEventCard) -> some View {
    Button {
      BeidDesign.haptic()
      coordinator.joinNearbyEventFromHome(card)
    } label: {
      VStack(alignment: .leading, spacing: DS.Space.s) {
        Text("FOUND NEARBY")
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondaryOnInk)
        Text("NAME ANNOUNCED NEARBY")
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondaryOnInk)
        Text(verbatim: candidateName(card))
          .beidTextStyle(DS.Font.Library.title19)
        Text(candidateRegistrationStatus(card))
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondaryOnInk)
      }
      .foregroundStyle(DS.Color.labelOnActionPrimary)
      .padding(DS.Space.l)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DS.Color.textPrimary, in: RoundedRectangle(cornerRadius: DS.Radius.nowCard))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(card.joinActionEventCodeHashHex == nil)
    .accessibilityLabel(candidateAccessibilityLabel(card))
    .accessibilityIdentifier("home.nearby.join.\(card.eventCodeHashHex)")
  }

  private var additionalCandidates: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("ALSO NEARBY")
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondary)
      ForEach(Array(nearby.cards.dropFirst())) { card in
        Button {
          coordinator.joinNearbyEventFromHome(card)
        } label: {
          HStack(spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
              Text(verbatim: candidateName(card)).beidTextStyle(DS.Font.Library.title17)
              Text(candidateRegistrationStatus(card))
                .beidTextStyle(DS.Font.Library.labelMono10)
                .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer(minLength: 0)
            Text("JOIN →").beidTextStyle(DS.Font.Library.labelMono11)
          }
          .frame(minHeight: DS.Size.listRowMinHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(card.joinActionEventCodeHashHex == nil)
        .accessibilityLabel(candidateAccessibilityLabel(card))
        .accessibilityIdentifier("home.nearby.additional.\(card.eventCodeHashHex)")
        Divider()
      }
    }
  }

  private var demoCandidate: some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
      Text("DEMO EVENT · SAMPLE DATA")
        .beidTextStyle(DS.Font.Library.labelMono10)
      Text("Demo event").beidTextStyle(DS.Font.Library.title19)
      Text("Sample devices and records. No Bluetooth event is joined.")
        .beidTextStyle(DS.Font.Library.body13)
      BeidTextControl("now.join.action", labelColor: DS.Color.labelOnActionPrimary, haptic: true) {
        coordinator.joinDemoEventFromHome()
      }
      .accessibilityIdentifier("home.demo.join")
    }
    .foregroundStyle(DS.Color.labelOnActionPrimary)
    .padding(DS.Space.l)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DS.Color.textPrimary, in: RoundedRectangle(cornerRadius: DS.Radius.nowCard))
  }

  private var continuingSummary: some View {
    VStack(alignment: .leading, spacing: DS.Space.l) {
      Text("Sensing continues")
        .beidTextStyle(DS.Font.Library.display46)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("collection.continuous-sensing")
      instructionTile(title: "now.keep-open.title", body: "Nearby devices can keep observing each other.")
      openDetails
    }
    .foregroundStyle(foreground)
  }

  private var joiningSummary: some View {
    VStack(alignment: .leading, spacing: DS.Space.l) {
      if let registration = coordinator.nowEventRegistration {
        Text("JOINING").beidTextStyle(DS.Font.Library.labelMono11)
        Text(verbatim: registration.name).beidTextStyle(DS.Font.Library.display46)
      } else {
        Text("Joining event…").beidTextStyle(DS.Font.Library.display46)
      }
      instructionTile(title: "now.keep-open.title", body: "beid is starting sensing for the event you chose.")
      openDetails
    }
    .foregroundStyle(foreground)
  }

  private func activeSummary(event: EventSession, now: Date) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.l) {
      Text(activeStatusTitle)
        .beidTextStyle(DS.Font.Library.labelMono11)
        .foregroundStyle(secondary)
      Text(verbatim: event.name)
        .beidTextStyle(DS.Font.Library.display46)
        .accessibilityAddTraits(.isHeader)
      let metricLayout = dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.l))
        : AnyLayout(HStackLayout(alignment: .top, spacing: DS.Space.xl))
      metricLayout {
        metric(value: "\(sensing.devicesVerified)", label: "DEVICES HEARD")
        metric(value: elapsedString(sensing.firstSightingAt.map {
          sensing.sensingPresentationNow(now).timeIntervalSince($0)
        } ?? 0), label: "ELAPSED")
      }
      instructionTile(
        title: "Stay nearby. Keep the app open.",
        body: "Keeping beid open helps nearby devices observe each other and keep signed records."
      )
      openDetails
      if let registration = coordinator.nowEventRegistration { organizerTile(registration) }
    }
    .foregroundStyle(foreground)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("home.active-event")
  }

  private func savedSummary(_ snapshot: SensingSealedSnapshot) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.l) {
      Text(verbatim: snapshot.event.name)
        .beidTextStyle(DS.Font.Library.labelMono11)
        .foregroundStyle(secondary)
      Text("You’re done.")
        .beidTextStyle(DS.Font.Library.display46)
        .accessibilityIdentifier("home.saved.title")
      Text("Your record is saved on this device. You can close the app.")
        .beidTextStyle(DS.Font.Library.body15)
        .foregroundStyle(secondary)
      if let recordID = snapshot.recordID, let record = coordinator.proofStore.proof(withId: recordID) {
        BeidTextControl("VIEW RECORD", glyph: .trailing("→", announcing: "View record")) {
          coordinator.openProof(record)
        }
        .accessibilityIdentifier("home.saved.view-record")
      }
      BeidTextControl("WHAT WE SEND", glyph: .trailing("→", announcing: "What we send")) {
        showWhatWeSend = true
      }
      .accessibilityIdentifier("home.saved.what-was-sent")
      if let registration = coordinator.nowEventRegistration { organizerTile(registration) }
      listeningStrip
      if coordinator.homeHasDemoCandidate {
        demoCandidate
      } else if let first = nearby.cards.first {
        candidateCard(first)
        if nearby.cards.count > 1 { additionalCandidates }
      }
    }
    .foregroundStyle(foreground)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("home.saved-record")
  }

  private func metric(value: String, label: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      Text(verbatim: value).beidTextStyle(DS.Font.Library.displayNumber40)
      Text(label).beidTextStyle(DS.Font.Library.labelMono10).foregroundStyle(secondary)
    }
  }

  private var activeStatusTitle: LocalizedStringKey {
    if case .signalLost = sensing.phase { return "Signal lost" }
    return "Sensing"
  }

  private var openDetails: some View {
    Button {
      coordinator.scanPresented = true
    } label: {
      HStack {
        Text("Sensing details")
        Spacer(minLength: DS.Space.m)
        Image(systemName: "chevron.forward")
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, minHeight: DS.Size.minHitTarget, alignment: .leading)
    }
    .font(DS.Font.Library.title16.font)
    .buttonStyle(.bordered)
    .tint(foreground)
    .accessibilityIdentifier("home.open-details")
  }

  private func instructionTile(title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
      Text(title).beidTextStyle(DS.Font.Library.title17)
      Text(body).beidTextStyle(DS.Font.Library.body13).foregroundStyle(secondary)
    }
    .padding(DS.Space.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(usesInk ? DS.Color.strokeHairlineOnInk : DS.Color.surfaceTile,
                in: RoundedRectangle(cornerRadius: DS.Radius.control))
  }

  private func organizerTile(_ registration: HomeEventRegistration) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
      Text("FROM THE ORGANIZER").beidTextStyle(DS.Font.Library.labelMono10)
      Text(verbatim: registration.name).beidTextStyle(DS.Font.Library.title17)
      Text(String(
        localized: "now.organizer.dates",
        defaultValue: "\(registration.startsAt.formatted(date: .abbreviated, time: .shortened)) – \(registration.endsAt.formatted(date: .abbreviated, time: .shortened))",
        comment: "The start and end dates in the event's registration."
      ))
      .beidTextStyle(DS.Font.Library.body13)
    }
    .padding(DS.Space.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(usesInk ? DS.Color.strokeHairlineOnInk : DS.Color.surfaceTile,
                in: RoundedRectangle(cornerRadius: DS.Radius.control))
  }

  private func candidateAccessibilityLabel(_ card: NearbyEventCard) -> String {
    let format = String(
      localized: "now.nearby.event.accessibilityLabel",
      defaultValue: "%1$@, name announced nearby %2$@, %3$@",
      comment: "VoiceOver label for a nearby event. %1$@ is the localized join action and comes first, %2$@ is the name announced by Bluetooth, and %3$@ is the registration status."
    )
    let action = String(localized: "now.join.action", defaultValue: "JOIN")
    let status = String(localized: candidateRegistrationStatus(card))
    return String(format: format, locale: Locale.current, arguments: [action, candidateName(card), status])
  }

  private func candidateRegistrationStatus(_ card: NearbyEventCard) -> LocalizedStringResource {
    if card.joinActionEventCodeHashHex != nil { return "EVENT REGISTRATION CHECKED" }
    let candidates = sensing.nearbyEventCandidates
    for index in 0..<candidates.candidateCount {
      guard let candidate = candidates.candidateAt(index: index),
        candidate.eventCodeHashHex == card.eventCodeHashHex,
        let validUntil = candidate.definitionValidUntilEpochSeconds else { continue }
      if validUntil < Int64(Date().timeIntervalSince1970.rounded(.down)) {
        return "EVENT REGISTRATION EXPIRED"
      }
    }
    return "Checking event registration…"
  }

  private func candidateName(_ card: NearbyEventCard) -> String {
    if card.hasDisplayNameConflict { return String(localized: "nearbyEvent.beaconName.conflict", defaultValue: "Multiple names reported nearby") }
    return card.beaconDisplayName ?? String(localized: "nearbyEvent.beaconName.missing", defaultValue: "This event didn't send a name")
  }

  private func elapsedString(_ seconds: TimeInterval) -> String {
    ElapsedTimeFormat.minutesSeconds(seconds)
  }

  #if DEBUG
  private var standbyFixtureControls: some View {
    VStack {
      Button("Advance 29 seconds") { coordinator.advanceHomeStandbyFixture(by: 29) }
        .accessibilityIdentifier("fixture.now.advance29")
      Button("Advance one second") { coordinator.advanceHomeStandbyFixture(by: 1) }
        .accessibilityIdentifier("fixture.now.advance1")
      Button("Add candidate") { coordinator.setHomeStandbyFixtureCandidate(true) }
        .accessibilityIdentifier("fixture.now.add-candidate")
      Button("Remove candidate") { coordinator.setHomeStandbyFixtureCandidate(false) }
        .accessibilityIdentifier("fixture.now.remove-candidate")
    }
    .buttonStyle(.bordered)
  }
  #endif
}

private struct RecordsHomeView: View {
  private enum Grouping: Hashable {
    case allRecords, byEvent
  }

  @EnvironmentObject private var coordinator: AppCoordinator
  @ObservedObject var proofStore: ProofStore
  @ObservedObject var sensing: SensingCoordinator
  @State private var grouping: Grouping = .allRecords
  @State private var selectedRecord: Proof?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var eventGroups: [[Proof]] { EventGrouping.homeGroups(from: proofStore.proofs, activeEventCode: nil) }
  private var columns: [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: DS.Space.l), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        BeidLargeTitleContent(regularMaxWidth: DS.Layout.recordsContentMaxWidth) {
          VStack(alignment: .leading, spacing: DS.Space.l) {
            Picker("Record grouping", selection: $grouping) {
              Text("All records").tag(Grouping.allRecords)
              Text("By event").tag(Grouping.byEvent)
            }
            .pickerStyle(.segmented)
            if eventGroups.isEmpty {
              BeidEmptyBlock {
                Text("Saved records appear here after sensing.")
                  .beidTextStyle(DS.Font.Library.body13)
                  .foregroundStyle(DS.Color.textSecondary)
              }
            } else if grouping == .byEvent {
              eventList
            } else {
              LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.l) {
                ForEach(eventGroups, id: \.first?.id) { group in
                  if let proof = group.first { recordTile(proof) }
                }
              }
            }
          }
          .padding(.vertical, DS.Space.s)
        }
      }
      .accessibilityIdentifier(grouping == .byEvent ? "records.events" : "records.grid")
      .background(DS.Color.surfaceCanvas.ignoresSafeArea())
      .modifier(HomeAccountToolbar(title: "records.title", iconColor: DS.Color.textPrimary))
      .toolbarBackground(.hidden, for: .navigationBar)
      .toolbarColorScheme(.light, for: .navigationBar)
      .navigationDestination(item: $selectedRecord) { HomeRecordDetail(proof: $0) }
    }
  }

  private func recordTile(_ proof: Proof) -> some View {
    Button {
      selectedRecord = proof
    } label: {
      VStack(alignment: .leading, spacing: DS.Space.s) {
        RecordSigilSlot(input: sensing.sigilInput(forProofId: proof.id), placement: .recordsGrid)
        Text(verbatim: proof.eventName)
          .beidTextStyle(DS.Font.Library.title17)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(String(
      localized: "records.record.accessibilityLabel",
      defaultValue: "Record for \(proof.eventName)",
      comment: "Opens the saved participation record for the named event."
    ))
    .accessibilityIdentifier("records.record.\(proof.id.uuidString)")
  }

  private var eventList: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(eventGroups, id: \.first?.id) { group in
        if let proof = group.first {
          // v1.1 has one Attendance record per event, with multiple stored sessions.
          let recordCount = 1
          NavigationLink {
            EventDetailView(representative: proof, sensing: sensing, proofStore: proofStore,
                            submissionStore: coordinator.reportSubmissionStore)
          } label: {
            HStack(spacing: DS.Space.m) {
              RecordSigilSlot(input: sensing.sigilInput(forProofId: proof.id), placement: .homePastRow)
              VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(verbatim: proof.eventName).beidTextStyle(DS.Font.Library.title17)
                Text(String(
                  localized: "home.past.sessionCaption",
                  defaultValue: "\(proof.date.formatted(.dateTime.month(.abbreviated).day())) · \(group.count) sessions",
                  comment: "Latest saved session date and count of stored sessions for this event."
                ))
                  .beidTextStyle(DS.Font.Library.labelMono10)
                  .foregroundStyle(DS.Color.textSecondary)
              }
              Spacer(minLength: 0)
              Text(String(
                localized: "records.event.recordAction",
                defaultValue: "\(recordCount) records →",
                comment: "Number of participation records for this event; opens event details, including its stored sessions."
              ))
              .beidTextStyle(DS.Font.Library.labelMono10Tight)
            }
            .frame(minHeight: DS.Size.listRowMinHeight)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("home.past-event.\(proof.eventCode ?? proof.id.uuidString)")
          Divider()
        }
      }
    }
  }
}

private struct HomeRecordDetail: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  let proof: Proof

  var body: some View {
    #if DEBUG
    ItemDetailView(proof: proof, presentationOverride: coordinator.proofDetailScreenshotPresentation)
    #else
    ItemDetailView(proof: proof)
    #endif
  }
}

private struct HomeUnsentNotice: View {
  @ObservedObject var store: ReportSubmissionStore
  let usesInk: Bool

  var body: some View {
    if store.hasRecordsWaitingToSend {
      VStack(alignment: .leading, spacing: DS.Space.s) {
        hairline
        HStack(spacing: DS.Space.s) {
          Circle()
            .fill(DS.Color.statusPending)
            .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
            .accessibilityHidden(true)
          Text("home.unsent.title")
            .beidTextStyle(DS.Font.Library.labelMono11)
            .foregroundStyle(usesInk ? DS.Color.labelOnActionPrimary : DS.Color.textPrimary)
            .accessibilityAddTraits(.isHeader)
        }
        Text("home.unsent.message")
          .beidTextStyle(DS.Font.Library.body13)
          .foregroundStyle(usesInk ? DS.Color.textSecondaryOnInk : DS.Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        hairline
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("home.unsent-notice")
    }
  }

  private var hairline: some View {
    Rectangle()
      .fill(usesInk ? DS.Color.strokeHairlineOnInk : DS.Color.strokeHairline)
      .frame(height: DS.Size.hairline)
  }
}

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
          Text("Records need an accurate clock. Check Date & Time in Settings.")
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
        }
    }
    .tint(DS.Color.actionPrimary)
  }
}
