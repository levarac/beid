// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

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

  func body(content: Content) -> some View {
    content
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("home.account.title", systemImage: "person.crop.circle") {
            coordinator.accountSheetPresented = true
          }
          .accessibilityIdentifier("home.account")
        }
      }
  }
}

private struct NowHomeView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var sensing: SensingCoordinator
  @ObservedObject var bluetooth: BluetoothMonitor
  @State private var isRootVisible = false
  @State private var showAboutSensing = false
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
          BeidAdaptiveContent(regularMaxWidth: DS.Layout.collectionContentMaxWidth) {
            VStack(alignment: .leading, spacing: DS.Space.l) {
              if !isIdle && coordinator.homeBluetoothIsOff { bluetoothOff }
              if let event = activeEvent {
                activeSummary(event: event, now: context.date)
              } else if isIdle && sensing.isAdvertising {
                continuingSummary
              } else if !isIdle {
                joiningSummary
              } else {
                standbyContent
              }
              #if DEBUG
              if coordinator.isHomeStandbyFixture { standbyFixtureControls }
              #endif
            }
            .padding(.horizontal, DS.Space.pageMargin)
            .padding(.vertical, DS.Space.s)
          }
        }
        .accessibilityIdentifier("home.now")
        .background(usesInk ? DS.Color.textPrimary : DS.Color.surfaceCanvas)
      }
      .background(usesInk ? DS.Color.textPrimary : DS.Color.surfaceCanvas)
      .modifier(HomeAccountToolbar())
      .toolbarBackground(usesInk ? DS.Color.textPrimary : DS.Color.surfaceCanvas, for: .navigationBar, .tabBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarColorScheme(usesInk ? .dark : .light, for: .navigationBar, .tabBar)
      .navigationDestination(isPresented: $showAboutSensing) { AboutSensingView() }
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
    .onChange(of: coordinator.scanPresented) { _, _ in refreshStandby() }
    .onChange(of: coordinator.accountSheetPresented) { _, _ in refreshStandby() }
    .onChange(of: coordinator.homeEventCodeSheetPresented) { _, _ in refreshStandby() }
    .onChange(of: bluetooth.state) { _, _ in refreshStandby() }
    .onChange(of: sensing.isAdvertising) { _, _ in refreshStandby() }
    .onChange(of: sensing.phase) { _, _ in refreshStandby() }
    .onChange(of: sensing.nearbyEventCandidates.candidateCount) { _, _ in refreshStandby() }
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
      Text("home.now.title")
        .beidTextStyle(DS.Font.Library.display60)
        .accessibilityAddTraits(.isHeader)
      HomeClockWarning(preflight: coordinator.clockPreflight) { stateKey in
        clockInstructionsForNetwork = stateKey != "overTolerance"
        showsClockInstructions = true
      }
      if coordinator.homeBluetoothIsOff {
        bluetoothOff
      } else {
        listeningStrip
        instructionTile(
          title: "Keep the app open and head to the venue.",
          body: "beid listens for nearby events over Bluetooth. Tap JOIN when your event appears."
        )
        if coordinator.homeHasDemoCandidate {
          demoCandidate
        } else if let first = nearby.cards.first {
          candidateCard(first)
          if nearby.cards.count > 1 { additionalCandidates }
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
    }
    .padding(.vertical, DS.Space.m)
  }

  private func candidateCard(_ card: NearbyEventCard) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
      Text("FOUND NEARBY")
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondaryOnInk)
      Text("NAME ANNOUNCED NEARBY")
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondaryOnInk)
      Text(verbatim: candidateName(card))
        .beidTextStyle(DS.Font.Library.title19)
        .accessibilityIdentifier("home.nearby.primary-name")
      Text(candidateRegistrationStatus(card))
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondaryOnInk)
      BeidTextControl("now.join.action", labelColor: DS.Color.labelOnActionPrimary) {
        coordinator.joinNearbyEventFromHome(card)
      }
      .disabled(card.joinActionEventCodeHashHex == nil)
      .accessibilityIdentifier("home.nearby.join.\(card.eventCodeHashHex)")
    }
    .foregroundStyle(DS.Color.labelOnActionPrimary)
    .padding(DS.Space.l)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DS.Color.textPrimary, in: RoundedRectangle(cornerRadius: DS.Radius.nowCard))
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
        .accessibilityIdentifier("home.nearby.additional.\(card.eventCodeHashHex)")
        Divider()
      }
    }
  }

  private var demoCandidate: some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
      Text("DEMO EVENT · FOR APP REVIEW")
        .beidTextStyle(DS.Font.Library.labelMono10)
      Text("Demo event").beidTextStyle(DS.Font.Library.title19)
      Text("Sample devices and records. No Bluetooth event is joined.")
        .beidTextStyle(DS.Font.Library.body13)
      BeidTextControl("now.join.action", labelColor: DS.Color.labelOnActionPrimary) {
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
      Text("SENSING")
        .beidTextStyle(DS.Font.Library.labelMono11)
        .accessibilityIdentifier("collection.continuous-sensing")
      Text("Sensing continues").beidTextStyle(DS.Font.Library.display46)
      instructionTile(title: "now.keep-open.title", body: "Nearby phones can keep observing each other.")
      openDetails
    }
    .foregroundStyle(foreground)
  }

  private var joiningSummary: some View {
    VStack(alignment: .leading, spacing: DS.Space.l) {
      Text("JOINING").beidTextStyle(DS.Font.Library.labelMono11)
      if let registration = coordinator.nowEventRegistration {
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
      Text("NOW · SENSING")
        .beidTextStyle(DS.Font.Library.labelMono11)
        .foregroundStyle(secondary)
      Text(verbatim: event.name)
        .beidTextStyle(DS.Font.Library.display46)
        .accessibilityAddTraits(.isHeader)
      HStack(alignment: .top, spacing: DS.Space.xl) {
        metric(value: "\(sensing.devicesVerified)", label: "DEVICES HEARD")
        metric(value: elapsedString(sensing.firstSightingAt.map {
          sensing.sensingPresentationNow(now).timeIntervalSince($0)
        } ?? 0), label: "ELAPSED")
      }
      instructionTile(
        title: "Stay nearby. Keep the app open.",
        body: "Keeping beid open helps nearby phones observe each other and keep signed records."
      )
      if let registration = coordinator.nowEventRegistration { organizerTile(registration) }
      openDetails
    }
    .foregroundStyle(foreground)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("home.active-event")
  }

  private func metric(value: String, label: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      Text(verbatim: value).beidTextStyle(DS.Font.Library.displayNumber40)
      Text(label).beidTextStyle(DS.Font.Library.labelMono10).foregroundStyle(secondary)
    }
  }

  private var openDetails: some View {
    BeidTextControl("OPEN DETAILS", glyph: .trailing("→", announcing: "Open sensing details"),
                    labelColor: foreground) { coordinator.scanPresented = true }
      .accessibilityIdentifier("home.open-details")
  }

  private func instructionTile(title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
      Text("DO THIS NOW").beidTextStyle(DS.Font.Library.labelMono10).foregroundStyle(secondary)
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

  private func candidateRegistrationStatus(_ card: NearbyEventCard) -> LocalizedStringKey {
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
    return card.beaconDisplayName ?? String(localized: "nearbyEvent.beaconName.missing", defaultValue: "No name announced by nearby beacon")
  }

  private func elapsedString(_ seconds: TimeInterval) -> String {
    let elapsed = max(0, Int(seconds))
    return "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
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
  @EnvironmentObject private var coordinator: AppCoordinator
  @ObservedObject var proofStore: ProofStore
  @ObservedObject var sensing: SensingCoordinator
  @State private var showsEvents = false
  @State private var selectedRecord: Proof?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var eventGroups: [[Proof]] { EventGrouping.homeGroups(from: proofStore.proofs, activeEventCode: nil) }
  private var columns: [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: DS.Space.l), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        BeidAdaptiveContent(regularMaxWidth: DS.Layout.collectionContentMaxWidth) {
          VStack(alignment: .leading, spacing: DS.Space.l) {
            Text(String(
              localized: "records.header.counts",
              defaultValue: "\(eventGroups.count) records · \(eventGroups.count) events",
              comment: "Number of saved records and number of distinct recorded events."
            ))
              .beidTextStyle(DS.Font.Library.labelMono10)
              .foregroundStyle(DS.Color.textSecondary)
            Text("records.title").beidTextStyle(DS.Font.Library.display60).accessibilityAddTraits(.isHeader)
            BeidTextControl("BY EVENT", glyph: .trailing("→", announcing: "Records by event")) {
              showsEvents = true
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("records.by-event")
            if proofStore.proofs.isEmpty {
              BeidEmptyBlock {
                Text("Saved records appear here after sensing.")
                  .beidTextStyle(DS.Font.Library.body13)
                  .foregroundStyle(DS.Color.textSecondary)
              }
            } else {
              LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.l) {
                ForEach(eventGroups, id: \.first?.id) { group in
                  if let proof = group.first { recordTile(proof) }
                }
              }
            }
          }
          .padding(.horizontal, DS.Space.pageMargin)
          .padding(.vertical, DS.Space.s)
        }
      }
      .accessibilityIdentifier("records.grid")
      .background(DS.Color.surfaceCanvas)
      .modifier(HomeAccountToolbar())
      .navigationDestination(isPresented: $showsEvents) { eventList }
      .navigationDestination(item: $selectedRecord) { HomeRecordDetail(proof: $0) }
    }
  }

  private func recordTile(_ proof: Proof) -> some View {
    Button {
      selectedRecord = proof
    } label: {
      VStack(alignment: .leading, spacing: DS.Space.s) {
        RecordSigilSlot(input: sensing.sigilInput(forProofId: proof.id), placement: .recordsGrid)
        Text("Attendance").beidTextStyle(DS.Font.Library.title17)
        Text(verbatim: proof.eventName.uppercased())
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondary)
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
    List {
      ForEach(eventGroups, id: \.first?.id) { group in
        if let proof = group.first {
          NavigationLink {
            EventDetailView(representative: proof, sensing: sensing, proofStore: proofStore,
                            submissionStore: coordinator.reportSubmissionStore)
          } label: {
            HStack(spacing: DS.Space.m) {
              RecordSigilSlot(input: sensing.sigilInput(forProofId: proof.id), placement: .homePastRow)
              VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(verbatim: proof.eventName).beidTextStyle(DS.Font.Library.title17)
                Text(proof.date.formatted(date: .abbreviated, time: .omitted))
                  .beidTextStyle(DS.Font.Library.labelMono10)
                  .foregroundStyle(DS.Color.textSecondary)
              }
              Spacer(minLength: 0)
              Text(String(
                localized: "records.event.sessionAction",
                defaultValue: "\(group.count) sessions →",
                comment: "Number of saved recording sessions for this event; opens event details."
              ))
              .beidTextStyle(DS.Font.Library.labelMono10)
            }
            .frame(minHeight: DS.Size.listRowMinHeight)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("home.past-event.\(proof.eventCode ?? proof.id.uuidString)")
          .listRowBackground(DS.Color.surfaceCanvas)
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(DS.Color.surfaceCanvas)
    .navigationTitle("By event")
    .accessibilityIdentifier("records.events")
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
