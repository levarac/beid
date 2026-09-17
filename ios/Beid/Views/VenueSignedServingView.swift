// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// beid#432 — the signed venue-serving screen. Supplies a public venue bundle
/// and handoff from a file or an https URL, shows what verification decided,
/// and serves the permitted container until the instant the permit fixed.
///
/// Reachable from `AccountSheetView`'s "Venue Device (Signed)" row as of this
/// PR, alongside (not replacing) the v1 `VenueDeviceOrganizerView` entry.
///
/// The screen deliberately uses passive visibility: once a permit is accepted,
/// the verified event name, the event ID and the exclusive deadline are shown
/// while serving. There is no blocking confirmation dialog; the owner
/// direction for this surface is that the operator can see what the venue
/// device is serving. The name alone cannot tell two events at the same venue
/// apart, so the full event ID of the installed permit is shown beside it
/// (beid#531).
///
/// The five `switch` statements below have NO `default` case, deliberately.
/// Adding a case to any of the five venue enums must break this build: a
/// `default` would turn a new outcome into a silently mislabelled one, and
/// the build break is the control that prevents that.
struct VenueSignedServingView: View {
  @StateObject private var viewModel: VenueSignedServingViewModel
  @Environment(\.scenePhase) private var scenePhase

  @State private var requestTask: Task<Void, Never>?
  @StateObject private var lifecycleTasks = VenueLifecycleTaskOwner()

  @State private var venueLinkText = ""
  @State private var isScanning = false

  init(viewModel: @autoclosure @escaping () -> VenueSignedServingViewModel) {
    _viewModel = StateObject(wrappedValue: viewModel())
  }

  var body: some View {
    List {
      sourceSection
      statusSection
      radioSection
    }
    .navigationTitle("Venue serving")
    .onAppear {
      viewModel.beginSession(isForeground: scenePhase != .background)
    }
    .onDisappear {
      viewModel.endSession()
      requestTask?.cancel()
      lifecycleTasks.cancelAll()
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .background:
        // Leaving the scene clears: the app can no longer observe expiry or a
        // radio failure, so it must not leave signed bytes on the air.
        //
        // `.background` only. `.inactive` also fires for Control Center, the
        // app switcher and an incoming-call banner, and treating those as
        // departure would tear down serving — and re-verify on the way back —
        // every time a notification banner appeared.
        viewModel.sceneDidEnterBackground()
      case .active:
        lifecycleTasks.start { await viewModel.sceneWillEnterForeground() }
      case .inactive:
        break
      @unknown default:
        break
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
      lifecycleTasks.start { await viewModel.systemClockDidChange() }
    }
  }

  private var sourceSection: some View {
    Section {
      TextField("Venue link", text: $venueLinkText, prompt: Text("https://…#…"), axis: .vertical)
        .font(DS.Font.body)
        .lineLimit(1...3)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityIdentifier("Venue link")

      if VenueLinkScanner.isAvailable {
        Button("Scan QR") { isScanning = true }
          .font(DS.Font.body)
          .accessibilityIdentifier("Scan QR")
      }

      Button("Supply") {
        let link = venueLinkText
        requestTask?.cancel()
        requestTask = Task { await viewModel.supply(link: link) }
      }
      .font(DS.Font.cta)
      .accessibilityIdentifier("Supply")
      .disabled(venueLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

      // What the link's own fragment said, before anything was fetched or checked.
      // Shown as soon as it decodes, because Supply used to be silent: an operator
      // could not tell a link that decoded from one that did nothing (beid#597).
      if let eventId = viewModel.linkEventIdHex {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
          Text("Link event")
            .font(DS.Font.meta)
            .foregroundStyle(DS.Color.textSecondary)
          Text(verbatim: eventId.prefix(16) + "…")
            .font(DS.Font.ledgerMono)
        }
      }

      // Shown in the Source section, not in Status: this says the text field is
      // wrong, and Status keeps saying what the radio is actually doing.
      if let failure = viewModel.linkFailure {
        label(message(for: failure), tint: DS.Color.statusCaution)
      }

      if let stored = viewModel.storedSourceDescription {
        Button("Reload stored bundle") {
          requestTask?.cancel()
          requestTask = Task { await viewModel.restoreFromStorage() }
        }
        .font(DS.Font.body)
        Text(
          String(
            localized: "venue.serving.storedSource",
            defaultValue: "Stored source: \(stored)",
            comment: "Shows where the currently stored venue bundle came from. The value is a host name or a file name, not a person or an event name."
          )
        )
        .font(DS.Font.meta)
        .foregroundStyle(DS.Color.textSecondary)
      }
    } header: {
      Text("Source")
    } footer: {
      if viewModel.hasUnsavedArtifact {
        Text("This bundle could not be saved. It remains available only until the app closes.")
          .foregroundStyle(DS.Color.statusCaution)
      }
      // Says plainly that storage is not a shortcut past verification.
      Text("Stored bundles are verified again each time they are loaded.")
        .font(DS.Font.meta)
      // The fragment never reaches a server, so the handoff's authority is the
      // person who handed the link over. Saying so on the screen is the only place
      // an operator meets that rule.
      Text("The link carries the handoff itself. Use one handed over by the event's organiser.")
        .font(DS.Font.meta)
    }
    .sheet(isPresented: $isScanning) {
      NavigationStack {
        VenueLinkScannerView(
          onScan: { payload in
            isScanning = false
            venueLinkText = payload
            requestTask?.cancel()
            requestTask = Task { await viewModel.supply(link: payload) }
          }
        )
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("Scan QR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          // A sheet with a live camera and no way out but a swipe is a trap on a
          // venue iPad in a case.
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { isScanning = false }
          }
        }
      }
    }
  }

  private var statusSection: some View {
    Section {
      switch viewModel.status {
      case .idle:
        Text("Not serving.")
          .font(DS.Font.body)
      case .acquiring:
        Text("Fetching the bundle.")
          .font(DS.Font.body)
      case .importing:
        Text("Verifying identity.")
          .font(DS.Font.body)
      case .imported(let identity), .evaluating(let identity):
        // Identity only. A receipt has no display name, so none is shown:
        // EventDefinitionV1 does not contain one.
        VStack(alignment: .leading, spacing: DS.Space.xs) {
          Text("Identity verified. Checking whether it may be served now.")
            .font(DS.Font.body)
          // Runtime data, not copy: an explicitly verbatim API so it can never
          // be mistaken for a localizable string.
          Text(verbatim: identity.eventIdHex.prefix(16) + "…")
            .font(DS.Font.ledgerMono)
            .foregroundStyle(DS.Color.textSecondary)
        }
      case .serving(let displayName, let stopAtUnixSeconds):
        VStack(alignment: .leading, spacing: DS.Space.xs) {
          // The permit's SDK-verified name is runtime data, not app copy.
          Text(verbatim: displayName)
            .font(DS.Font.cardTitle)
          if let eventId = viewModel.servingEventIdHex {
            Text(verbatim: eventId)
              .font(DS.Font.ledgerMono)
          }
          Text(
            String(
              localized: "venue.serving.servingUntil",
              defaultValue: "Serving until \(Self.instantText(stopAtUnixSeconds)).",
              comment: "The value is a time of day. This instant is fixed by the permit and is exclusive — serving stops at it, it does not continue through it."
            )
          )
          .font(DS.Font.supporting)
          .foregroundStyle(DS.Color.textSecondary)
        }
      case .blocked(let rejection):
        label(message(for: rejection.reason), tint: DS.Color.statusCaution)
      case .importRejected(let failure):
        label(message(for: failure), tint: DS.Color.statusCaution)
      case .acquisitionFailed(let failure):
        label(message(for: failure), tint: DS.Color.statusCaution)
      case .radioRefused(let failure):
        label(message(for: failure), tint: DS.Color.statusCaution)
      }
    } header: {
      Text("Status")
    }
  }

  private var radioSection: some View {
    Section {
      label(message(for: viewModel.radio.state), tint: tint(for: viewModel.radio.state))
      if let failure = viewModel.radio.failure {
        Text(message(for: failure))
          .font(DS.Font.supporting)
          .foregroundStyle(DS.Color.textSecondary)
      }
      Button("Stop serving") {
        viewModel.stop()
        requestTask?.cancel()
        lifecycleTasks.cancelAll()
      }
        .font(DS.Font.body)
    } header: {
      Text("Radio")
    }
  }

  private func label(_ key: LocalizedStringKey, tint: Color) -> some View {
    HStack(alignment: .top, spacing: DS.Space.s) {
      Circle()
        .fill(tint)
        .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
        .padding(.top, DS.Space.xs)
        .accessibilityHidden(true)
      Text(key)
        .font(DS.Font.body)
    }
  }

  private static func instantText(_ unixSeconds: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(unixSeconds))
      .formatted(date: .omitted, time: .shortened)
  }

  // MARK: - Exhaustive outcome copy. No `default` in any of the five.

  private func message(for failure: VenueLinkFailure) -> LocalizedStringKey {
    switch failure {
    case .malformedLink:
      return "That is not a venue link. Paste the whole link, including the part after the #."
    case .missingBundleUrl:
      return "This link names an event but no bundle to fetch."
    case .unsupportedBundleUrl:
      return "This link's bundle address is not one this app can fetch."
    }
  }

  private func message(for failure: VenueImportFailure) -> LocalizedStringKey {
    switch failure {
    case .malformedOrOutOfBounds:
      return "This bundle could not be read."
    case .handoffMismatch:
      return "The handoff does not match this bundle."
    case .unsupportedDeployment:
      return "This bundle is for a deployment this app does not support."
    case .registryUnavailable:
      return "The registry could not be reached, so the bundle was not verified."
    case .registrySourceMismatch:
      return "This bundle came from a different registry source than the one configured."
    case .anchoredRecordMissing:
      return "This event has no anchored record in the registry."
    case .definitionRejected:
      return "The event definition in this bundle was rejected."
    case .gatedEventUnsupported:
      return "This event needs an entry code. Serving those is not supported yet."
    }
  }

  private func message(for reason: VenueServingBlock) -> LocalizedStringKey {
    switch reason {
    case .clockUnavailable:
      return "This device's clock is unavailable, so serving cannot be scheduled."
    case .notStarted:
      return "This event has not started yet."
    case .expired:
      return "This event's current lease has ended."
    case .noCurrentEnvelope:
      return "There is no envelope covering the present moment."
    case .envelopeRejected:
      return "The envelope covering now did not verify."
    case .staleDefinition:
      return "A newer definition exists for this event. Load the current bundle."
    case .registryUnavailable:
      return "The registry could not be reached, so eligibility is unknown."
    }
  }

  private func message(for state: VenueRadioState) -> LocalizedStringKey {
    switch state {
    case .stopped:
      return "Stopped."
    case .waitingForBluetooth:
      return "Waiting for Bluetooth."
    case .advertisingRequested:
      // The strongest honest claim. The SDK reports advertising before the
      // system confirms it and emits no success event, so this must never be
      // worded as confirmed, on air, or broadcasting.
      return "Advertising requested. The system has not confirmed it is on air."
    case .failed:
      return "The radio stopped."
    }
  }

  private func message(for failure: VenueRadioFailure) -> LocalizedStringKey {
    switch failure {
    case .containerInstallRejected:
      return "The signed container was rejected and nothing is being served."
    case .bluetoothUnavailable:
      return "Bluetooth is unavailable for this device."
    case .advertiseFailed:
      return "Advertising could not start."
    case .gattServiceFailed:
      return "The device could not publish its discovery service."
    }
  }

  private func message(for failure: VenueAcquisitionFailure) -> LocalizedStringKey {
    switch failure {
    case .unsupportedScheme:
      return "Only https and file sources are supported."
    case .redirectRefused:
      return "That address redirected elsewhere, so it was not followed."
    case .oversize:
      return "That file is larger than a venue bundle may be."
    case .unreadable:
      return "That file could not be read."
    case .transportFailure:
      return "The bundle could not be fetched."
    case .eventIdentityMismatch:
      return "The bundle does not match the selected event."
    }
  }

  private func tint(for state: VenueRadioState) -> Color {
    switch state {
    case .stopped:
      return DS.Color.statusOff
    case .waitingForBluetooth:
      return DS.Color.statusCaution
    case .advertisingRequested:
      return DS.Color.statusOn
    case .failed:
      return DS.Color.signalWarning
    }
  }
}
