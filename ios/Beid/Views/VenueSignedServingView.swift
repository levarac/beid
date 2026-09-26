// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

/// The venue broadcast screen: what this device is holding for an event, and
/// what can be done with it.
///
/// beid#432 built it as a supply form — two URL fields and a Supply button, with
/// the outcome reported as a status line underneath. beid#597 turned the input
/// into one link, and then turned the screen around: the pack this device holds
/// is the subject, and pasting, scanning, refreshing and stopping are verbs
/// applied to it. An operator at a venue is looking after one thing, an event's
/// pack, not operating two transports.
///
/// One entry reaches this screen. Whether the bytes inside a pack are signed is
/// how the feature works, not a choice to put in front of an operator, so
/// `AccountSheetView` no longer offers the unsigned v1 row beside this one.
///
/// Words on screen are the ones a venue operator uses. Pack, link, event, check,
/// broadcast. Not bundle, handoff, supply, import or signed — those name the
/// protocol and the code, and they are in this file's comments where they belong.
///
/// The seven `switch` statements below have NO `default` case, deliberately.
/// Adding a case to any of the seven venue enums must break this build: a
/// `default` would turn a new outcome into a silently mislabelled one, and
/// the build break is the control that prevents that.
struct VenueSignedServingView: View {
  @StateObject private var viewModel: VenueSignedServingViewModel
  @Environment(\.scenePhase) private var scenePhase

  @State private var requestTask: Task<Void, Never>?
  @StateObject private var lifecycleTasks = VenueLifecycleTaskOwner()

  @State private var venueLinkText = ""
  @State private var isScanning = false
  /// The system's own description of why scanning would not start, kept so the
  /// operator can report it rather than describe a black screen.
  @State private var scannerStartFailure: String?
  /// Why the camera was not opened after the operator asked for it.
  @State private var scannerRefusal: VenueLinkScanner.Authorization?

  init(viewModel: @autoclosure @escaping () -> VenueSignedServingViewModel) {
    _viewModel = StateObject(wrappedValue: viewModel())
  }

  var body: some View {
    List {
      packSection
      actionsSection
      radioSection
    }
    .navigationTitle("Venue broadcast")
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
    .sheet(isPresented: $isScanning) {
      NavigationStack {
        VenueLinkScannerView(
          onScan: { payload in
            isScanning = false
            venueLinkText = payload
            supply(payload)
          },
          onStartFailure: { description in
            isScanning = false
            scannerStartFailure = description
          }
        )
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("Scan QR code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          // A sheet holding a live camera and no way out but a swipe is a trap
          // on a venue iPad in a case.
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { isScanning = false }
          }
        }
      }
    }
  }

  // MARK: - The object

  /// The pack itself, first on the screen and before any control.
  ///
  /// Each fact is shown only where something fixed it. A pack has no name until a
  /// permit carries one — `EventDefinitionV1` does not contain one — so no name is
  /// invented for the states before that, and the event id stands in. The id shown
  /// while broadcasting is the permit's, because that is what is actually on the
  /// air; the id shown before is the one the link named, which is a claim and not
  /// yet a verified fact.
  private var packSection: some View {
    Section {
      packBody
    } header: {
      Text("This event")
    }
  }

  @ViewBuilder
  private var packBody: some View {
    switch viewModel.status {
    case .idle:
      if let eventId = viewModel.linkEventIdHex {
        packRow(eventIdHex: eventId, detail: "Not broadcasting.")
      } else {
        emptyPack
      }
    case .acquiring:
      packRow(eventIdHex: viewModel.linkEventIdHex, detail: "Getting the pack.")
    case .importing:
      packRow(eventIdHex: viewModel.linkEventIdHex, detail: "Checking the pack.")
    case .imported(let identity), .evaluating(let identity):
      packRow(eventIdHex: identity.eventIdHex, detail: "Checked. Deciding whether it can broadcast now.")
    case .serving(let displayName, let stopAtUnixSeconds):
      servingPack(displayName: displayName, stopAtUnixSeconds: stopAtUnixSeconds)
    case .blocked(let rejection):
      label(message(for: rejection.reason), tint: DS.Color.statusCaution)
    case .importRejected(let failure):
      label(message(for: failure), tint: DS.Color.statusCaution)
    case .acquisitionFailed(let failure):
      label(message(for: failure), tint: DS.Color.statusCaution)
    case .radioRefused(let failure):
      label(message(for: failure), tint: DS.Color.statusCaution)
    }
  }

  private var emptyPack: some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      Text("No pack yet.")
        .font(DS.Font.body)
      Text("Paste the link the organiser gave you, or scan its QR code.")
        .font(DS.Font.supporting)
        .foregroundStyle(DS.Color.textSecondary)
    }
  }

  private func servingPack(displayName: String, stopAtUnixSeconds: Int64) -> some View {
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
          defaultValue: "Broadcasting until \(Self.instantText(stopAtUnixSeconds)).",
          // The catalogue holds a translated `en` unit for this key and it WINS
          // over this defaultValue — changing the wording here alone left the
          // screen still saying "Serving until" (beid#599 review). The
          // catalogue entry is the one to edit; this stays in step with it.
          comment: "The value is a time of day. This instant is fixed by the permit and is exclusive — broadcasting stops at it, it does not continue through it."
        )
      )
      .font(DS.Font.supporting)
      .foregroundStyle(DS.Color.textSecondary)
    }
  }

  private func packRow(eventIdHex: String?, detail: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      if let eventIdHex {
        // Runtime data, not copy: an explicitly verbatim API so it can never be
        // mistaken for a localizable string.
        Text(verbatim: eventIdHex.prefix(16) + "…")
          .font(DS.Font.ledgerMono)
          .foregroundStyle(DS.Color.textSecondary)
      }
      Text(detail)
        .font(DS.Font.body)
    }
  }

  // MARK: - The verbs

  private var actionsSection: some View {
    Section {
      TextField("Link", text: $venueLinkText, prompt: Text("Paste the link"), axis: .vertical)
        .font(DS.Font.body)
        .lineLimit(1...3)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityIdentifier("Venue link")

      Button("Use this link") { supply(venueLinkText) }
        .font(DS.Font.cta)
        .accessibilityIdentifier("Use this link")
        .disabled(venueLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

      if VenueLinkScanner.isSupported {
        Button("Scan QR code") {
          scannerStartFailure = nil
          scannerRefusal = nil
          // Ask for the camera here rather than inferring the answer from a
          // property. The button stays visible before anyone has been asked,
          // because that is the only moment at which asking can happen.
          requestTask?.cancel()
          requestTask = Task {
            switch await VenueLinkScanner.authorize() {
            case .granted:
              isScanning = true
            case .denied:
              scannerRefusal = .denied
            case .unavailableAnyway:
              scannerRefusal = .unavailableAnyway
            }
          }
        }
        .font(DS.Font.body)
        .accessibilityIdentifier("Scan QR code")
      } else {
        // Not offered, so say why rather than leaving a gap where an operator
        // expects a button. Silence there reads as a missing feature.
        Text("This device cannot scan QR codes. Paste the link instead.")
          .font(DS.Font.supporting)
          .foregroundStyle(DS.Color.textSecondary)
      }

      if let refusal = scannerRefusal {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
          Text(message(for: refusal))
            .font(DS.Font.supporting)
            .foregroundStyle(DS.Color.statusCaution)
          if refusal == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
            Link("Open Settings", destination: settings)
              .font(DS.Font.body)
          }
        }
      }

      if let failure = scannerStartFailure {
        Text("The camera could not start. Paste the link instead.")
          .font(DS.Font.supporting)
          .foregroundStyle(DS.Color.statusCaution)
        Text(verbatim: failure)
          .font(DS.Font.meta)
          .foregroundStyle(DS.Color.textSecondary)
      }

      // Said beside the field it is about, and never through `status`: a link
      // refused here is a fact about this text, not about what the radio is
      // doing, and an operator already broadcasting must stay on the air.
      if let failure = viewModel.linkFailure {
        label(message(for: failure), tint: DS.Color.statusCaution)
      }

      if viewModel.storedSourceDescription != nil {
        // One action, named for what it does from where the screen is. Nothing
        // starts a broadcast without checking the pack again, so "start" and
        // "refresh" are the same act seen from a stopped and a running device.
        Button(isBroadcasting ? "Refresh pack" : "Start broadcasting") {
          requestTask?.cancel()
          requestTask = Task { await viewModel.restoreFromStorage() }
        }
        .font(DS.Font.body)
        .accessibilityIdentifier("Refresh pack")
      }

      Button("Stop broadcasting") {
        viewModel.stop()
        venueLinkText = ""
        requestTask?.cancel()
        lifecycleTasks.cancelAll()
      }
      .font(DS.Font.body)
      .accessibilityIdentifier("Stop broadcasting")
    } header: {
      Text("Actions")
    } footer: {
      VStack(alignment: .leading, spacing: DS.Space.xs) {
        if viewModel.hasUnsavedArtifact {
          Text("This pack could not be saved. It stays on this device only until the app closes.")
            .foregroundStyle(DS.Color.statusCaution)
        }
        // Says plainly that keeping a pack is not a shortcut past checking it.
        Text("A saved pack is checked again every time it is loaded.")
          .font(DS.Font.meta)
        // The fragment never reaches a server, so the pack's authority is the
        // person who handed the link over. This screen is the only place an
        // operator meets that rule.
        Text("The link carries the event's details itself. Use one the event's organiser gave you.")
          .font(DS.Font.meta)
      }
    }
  }

  private var isBroadcasting: Bool {
    if case .serving = viewModel.status { return true }
    return false
  }

  private func supply(_ link: String) {
    requestTask?.cancel()
    requestTask = Task { await viewModel.supply(link: link) }
  }

  private var radioSection: some View {
    Section {
      label(message(for: viewModel.radio.state), tint: tint(for: viewModel.radio.state))
      if let failure = viewModel.radio.failure {
        Text(message(for: failure))
          .font(DS.Font.supporting)
          .foregroundStyle(DS.Color.textSecondary)
      }
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

  // MARK: - Exhaustive outcome copy. No `default` in any of the seven.

  private func message(for authorization: VenueLinkScanner.Authorization) -> LocalizedStringKey {
    switch authorization {
    case .granted:
      // Not shown; the camera opens instead. Present so that adding an
      // authorization outcome later breaks this build rather than going unsaid.
      return "The camera is ready."
    case .denied:
      return "beid does not have camera access, so it cannot scan. Turn it on in Settings, or paste the link instead."
    case .unavailableAnyway:
      return "Camera access is on, but scanning is unavailable on this device — a Screen Time restriction can do this. Paste the link instead."
    }
  }

  private func message(for failure: VenueLinkFailure) -> LocalizedStringKey {
    switch failure {
    case .malformedLink:
      return "That is not a venue link. Paste the whole link, including everything after the #."
    case .missingBundleUrl:
      return "This link names an event but does not say where to get its pack."
    case .unsupportedBundleUrl:
      return "This link points somewhere this app cannot fetch from."
    }
  }

  private func message(for failure: VenueImportFailure) -> LocalizedStringKey {
    switch failure {
    case .malformedOrOutOfBounds:
      return "This pack could not be read."
    case .handoffMismatch:
      return "The link and the pack do not agree. Ask the organiser for a current link."
    case .unsupportedDeployment:
      return "This pack is for a network this app does not support."
    case .registryUnavailable:
      return "The event record could not be reached, so the pack was not checked."
    case .registrySourceMismatch:
      return "This pack came from a different event record than the one this app is set up for."
    case .anchoredRecordMissing:
      return "This event has no record on chain."
    case .definitionRejected:
      return "This event's details were rejected."
    case .gatedEventUnsupported:
      return "This event needs an entry code. Broadcasting those is not supported yet."
    }
  }

  private func message(for reason: VenueServingBlock) -> LocalizedStringKey {
    switch reason {
    case .clockUnavailable:
      return "This device's clock is unavailable, so broadcasting cannot be scheduled."
    case .notStarted:
      return "This event has not started yet."
    case .expired:
      return "This pack's current period has ended. Refresh it."
    case .noCurrentEnvelope:
      return "This pack covers no part of right now."
    case .envelopeRejected:
      return "The part of this pack covering right now did not check out."
    case .staleDefinition:
      return "This event has been updated. Ask the organiser for a current link."
    case .registryUnavailable:
      return "The event record could not be reached, so it is unknown whether this may broadcast."
    }
  }

  private func message(for failure: VenueAcquisitionFailure) -> LocalizedStringKey {
    switch failure {
    case .unsupportedScheme:
      return "This link points somewhere this app cannot fetch from."
    case .redirectRefused:
      return "That address sent us somewhere else, so it was not followed."
    case .oversize:
      return "That file is larger than a pack may be."
    case .unreadable:
      return "That file could not be read."
    case .transportFailure:
      return "The pack could not be fetched."
    case .eventIdentityMismatch:
      return "The pack is not for the event this link named."
    case .timedOut:
      return "Fetching the pack took too long. Check the network and try again."
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
      return "Asked to broadcast. The system has not confirmed it is on air."
    case .failed:
      return "The radio stopped."
    }
  }

  private func message(for failure: VenueRadioFailure) -> LocalizedStringKey {
    switch failure {
    case .containerInstallRejected:
      return "The radio refused this pack and nothing is going out."
    case .bluetoothUnavailable:
      return "Bluetooth is unavailable for this device."
    case .advertiseFailed:
      return "Broadcasting could not start."
    case .gattServiceFailed:
      return "The device could not publish its discovery service."
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
