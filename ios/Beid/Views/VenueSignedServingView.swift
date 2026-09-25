// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit

/// Flat 2b screen 14b and its link, camera, radio and persistence outcomes.
/// The view model remains the only owner of verification, effects and teardown.
struct VenueSignedServingView: View {
  @StateObject private var viewModel: VenueSignedServingViewModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var requestTask: Task<Void, Never>?
  @StateObject private var lifecycleTasks = VenueLifecycleTaskOwner()
  @State private var venueLinkText = ""
  @State private var isScanning = false
  @State private var scannerStartFailure: String?
  @State private var scannerRefusal: VenueLinkScanner.Authorization?

  init(viewModel: @autoclosure @escaping () -> VenueSignedServingViewModel) {
    _viewModel = StateObject(wrappedValue: viewModel())
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        Text("Organizer tools · iOS only")
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondary)
          .padding(.bottom, DS.Space.s)
        Text("Venue\nbroadcast")
          .beidTextStyle(DS.Font.Library.display52)
          .foregroundStyle(DS.Color.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
        Text("Load the signed pack the organiser gave you. Once it checks out, this phone broadcasts it.")
          .beidTextStyle(DS.Font.Library.body15)
          .foregroundStyle(DS.Color.textSecondary)
          .padding(.top, DS.Space.m)
          .padding(.bottom, DS.Space.m)
        linkSection
        statusSection
      }
      .frame(maxWidth: DS.Layout.stateContentMaxWidth, alignment: .leading)
      .padding(.horizontal, DS.Space.pageMargin)
      .frame(maxWidth: .infinity)
    }
    .background(DS.Color.surfaceCanvas)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(DS.Color.surfaceCanvas, for: .navigationBar)
    .toolbarColorScheme(.light, for: .navigationBar)
    .safeAreaInset(edge: .bottom) {
      BeidPrimaryButton("Stop broadcasting") {
        guard fixtureCode == nil else { return }
        viewModel.stop()
        venueLinkText = ""
        requestTask?.cancel()
        lifecycleTasks.cancelAll()
      }
      .accessibilityIdentifier("Stop broadcasting")
      .frame(maxWidth: DS.Layout.stateContentMaxWidth)
      .padding(.horizontal, DS.Space.pageMargin)
      .padding(.top, DS.Space.s)
      .padding(.bottom, DS.Space.l)
      .frame(maxWidth: .infinity)
      .background(DS.Color.surfaceCanvas)
    }
    .onAppear {
      if let fixtureCode {
        switch fixtureCode {
        case "14e": venueLinkText = "https://organizer.eth/eth-tokyo-26"
        case "14e2": venueLinkText = "https://organizer.eth/#eth-tokyo-26"
        case "14e3": venueLinkText = "ftp://organizer.eth/eth-tokyo-26.pack"
        default: break
        }
      } else {
        viewModel.beginSession(isForeground: scenePhase != .background)
      }
    }
    .onDisappear {
      guard fixtureCode == nil else { return }
      // The camera uses a sheet, which leaves this presenting route mounted.
      // A real route departure always ends the session and clears the radio.
      viewModel.endSession()
      requestTask?.cancel()
      lifecycleTasks.cancelAll()
    }
    .onChange(of: scenePhase) { _, phase in
      guard fixtureCode == nil else { return }
      switch phase {
      case .background:
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
      guard fixtureCode == nil else { return }
      lifecycleTasks.start { await viewModel.systemClockDidChange() }
    }
    .sheet(isPresented: $isScanning) {
      VenueScannerScreen(isFixture: fixtureCode != nil, onCancel: { isScanning = false }, onScan: { payload in
        isScanning = false
        guard fixtureCode == nil else { return }
        venueLinkText = payload
        supply(payload)
      }, onStartFailure: { description in
        isScanning = false
        scannerStartFailure = description
      })
      .presentationDetents([.large])
      .presentationDragIndicator(.hidden)
    }
  }

  private var linkSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Link")
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondary)
        Spacer()
        Button {
          guard fixtureCode == nil else { return }
          if let pasted = UIPasteboard.general.string { venueLinkText = pasted }
        } label: {
          BeidTextControlLabel("Paste", accessibilityLabel: "Paste venue link")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Paste venue link")
      }
      TextField("Link", text: $venueLinkText, prompt: Text("Paste the link"), axis: .vertical)
        .beidTextStyle(DS.Font.Library.title17)
        .lineLimit(1...3)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityIdentifier("Venue link")
        .frame(minHeight: DS.Size.minHitTarget)
      Rectangle()
        .fill(linkFailure != nil ? DS.Color.statusOff : DS.Color.textPrimary)
        .frame(height: DS.Size.hairline)
      if let failure = linkFailure {
        outcome(title: linkFailureTitle(failure), message: message(for: failure))
          .padding(.top, DS.Space.s)
      }
      textAction("Use this link", identifier: "Use this link") {
        guard fixtureCode == nil else { return }
        supply(venueLinkText)
      }
      .disabled(venueLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .padding(.top, DS.Space.s)
      if VenueLinkScanner.isSupported || fixtureCode != nil {
        textAction("Scan QR code", identifier: "Scan QR code") {
          if fixtureCode != nil {
            isScanning = true
            return
          }
          scannerStartFailure = nil
          scannerRefusal = nil
          requestTask?.cancel()
          requestTask = Task {
            switch await VenueLinkScanner.authorize() {
            case .granted: isScanning = true
            case .denied: scannerRefusal = .denied
            case .unavailableAnyway: scannerRefusal = .unavailableAnyway
            }
          }
        }
      } else {
        Text("This device cannot scan QR codes. Paste the link instead.")
          .beidTextStyle(DS.Font.Library.body13)
          .foregroundStyle(DS.Color.textSecondary)
          .padding(.vertical, DS.Space.s)
      }
      if let refusal = effectiveScannerRefusal {
        outcome(title: scannerRefusalTitle(refusal), message: message(for: refusal))
          .padding(.top, DS.Space.s)
        if refusal == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
          Link(destination: settings) {
            BeidTextControlLabel("Open Settings", glyph: .trailing("→", announcing: "Open Settings"))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .accessibilityIdentifier("Open Settings")
        }
      }
      if let failure = effectiveScannerStartFailure {
        outcome(title: "Camera could not start", message: "The camera could not start. Paste the link instead.")
          .padding(.top, DS.Space.s)
        Text(verbatim: failure)
          .beidTextStyle(DS.Font.Library.labelMono9)
          .foregroundStyle(DS.Color.textSecondary)
      }
    }
  }

  private var statusSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: DS.Space.xs) {
        Text("Status")
        Text(verbatim: "·")
        Text(statusLabel)
      }
      .beidTextStyle(DS.Font.Library.labelMono10)
      .foregroundStyle(DS.Color.textSecondary)
      .padding(.top, DS.Space.xl)
      .padding(.bottom, DS.Space.s)
      hairline
      switch effectiveStatus {
      case .serving(let displayName, let stopAtUnixSeconds):
        keyValueRow("Event") { Text(verbatim: displayName) }
        if let eventId = effectiveEventId { keyValueRow("Event ID") { eventIdCopyControl(eventId) } }
        keyValueRow("Until") {
          if fixtureCode != nil {
            Text("Broadcasting until 18:00")
          } else {
            Text(String(localized: "venue.serving.servingUntil", defaultValue: "Broadcasting until \(Self.instantText(stopAtUnixSeconds)).", comment: "The permit's exclusive end time."))
          }
        }
      case .idle:
        if let eventId = viewModel.linkEventIdHex {
          keyValueRow("Event ID") { Text(verbatim: shortEventId(eventId)) }
        } else {
          Text("No pack yet. Paste the link the organiser gave you, or scan its QR code.")
            .beidTextStyle(DS.Font.Library.body13)
            .foregroundStyle(DS.Color.textSecondary)
            .padding(.vertical, DS.Space.s)
        }
      case .acquiring:
        statusMessage("Getting the pack.")
      case .importing:
        statusMessage("Checking the pack.")
      case .imported(let identity), .evaluating(let identity):
        keyValueRow("Event ID") { Text(verbatim: shortEventId(identity.eventIdHex)) }
        statusMessage("Checked. Deciding whether it can broadcast now.")
      case .blocked(let rejection):
        statusMessage(message(for: rejection.reason))
      case .importRejected(let failure):
        statusMessage(message(for: failure))
      case .acquisitionFailed(let failure):
        statusMessage(message(for: failure))
      case .radioRefused(let failure):
        statusMessage(message(for: failure))
      }
      keyValueRow("Radio") {
        HStack(spacing: DS.Space.s) {
          Circle()
            .fill(tint(for: effectiveRadio.state))
            .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
            .accessibilityHidden(true)
          Text(message(for: effectiveRadio.state))
        }
      }
      if let failure = effectiveRadio.failure {
        statusMessage(message(for: failure))
      }
      if viewModel.storedSourceDescription != nil, fixtureCode == nil {
        textAction(isBroadcasting ? "Refresh pack" : "Start broadcasting", identifier: "Refresh pack") {
          requestTask?.cancel()
          requestTask = Task { await viewModel.restoreFromStorage() }
        }
      }
      if effectiveUnsavedArtifact {
        outcome(title: "Not saved", message: "This pack could not be saved. It stays on this device only until the app closes.")
          .padding(.top, DS.Space.s)
      }
      Text("A saved pack is checked again every time it is loaded.")
        .beidTextStyle(DS.Font.Library.body13)
        .foregroundStyle(DS.Color.textSecondary)
        .padding(.top, DS.Space.m)
      Text("The link carries the event's details itself. Use one the event's organiser gave you.")
        .beidTextStyle(DS.Font.Library.body13)
        .foregroundStyle(DS.Color.textSecondary)
    }
  }

  private var hairline: some View {
    Rectangle().fill(DS.Color.strokeHairline).frame(height: DS.Size.hairline)
  }

  private func eventIdCopyControl(_ eventId: String) -> some View {
    Button {
      guard fixtureCode == nil else { return }
      UIPasteboard.general.string = eventId
    } label: {
      HStack(spacing: DS.Space.xs) {
        Text(verbatim: shortEventId(eventId))
        Text(verbatim: "·")
        Text("Copy")
      }
      .frame(minHeight: DS.Size.minHitTarget)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Copy event ID")
    .accessibilityValue(Text(verbatim: eventId))
    .accessibilityIdentifier("Copy event ID")
  }

  private func keyValueRow<Value: View>(_ key: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: DS.Space.s) {
        Text(key)
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondary)
        Spacer(minLength: DS.Space.s)
        value()
          .beidTextStyle(DS.Font.Library.labelMono11Time)
          .foregroundStyle(DS.Color.textPrimary)
          .multilineTextAlignment(.trailing)
      }
      .frame(minHeight: DS.Size.keyValueRowMinHeight)
      hairline
    }
  }

  private func textAction(_ title: LocalizedStringKey, identifier: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        Text(title)
        Spacer()
        Text(verbatim: "→")
          .accessibilityHidden(true)
      }
      .beidTextStyle(DS.Font.Library.labelMono11)
      .foregroundStyle(DS.Color.textPrimary)
      .frame(minHeight: DS.Size.minHitTarget)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityIdentifier(identifier)
    .overlay(alignment: .bottom) { hairline }
  }

  private func statusMessage(_ message: LocalizedStringKey) -> some View {
    Text(message)
      .beidTextStyle(DS.Font.Library.body13)
      .foregroundStyle(DS.Color.textPrimary)
      .padding(.vertical, DS.Space.s)
  }

  private func outcome(title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
      HStack(spacing: DS.Space.s) {
        Circle()
          .fill(DS.Color.statusOff)
          .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
          .accessibilityHidden(true)
        Text(title)
          .beidTextStyle(DS.Font.Library.labelMono10)
      }
      Text(message)
        .beidTextStyle(DS.Font.Library.body13)
        .foregroundStyle(DS.Color.textSecondary)
    }
    .foregroundStyle(DS.Color.textPrimary)
  }

  private var isBroadcasting: Bool {
    if case .serving = effectiveStatus { return true }
    return false
  }

  private func supply(_ link: String) {
    requestTask?.cancel()
    requestTask = Task { await viewModel.supply(link: link) }
  }

  private static func instantText(_ unixSeconds: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(unixSeconds)).formatted(date: .omitted, time: .shortened)
  }

  private func shortEventId(_ value: String) -> String {
    value.count > 12 ? "\(value.prefix(4))…\(value.suffix(4))" : value
  }

  private var statusLabel: LocalizedStringKey {
    switch effectiveStatus {
    case .idle: return "Not broadcasting"
    case .acquiring: return "Getting pack"
    case .importing: return "Checking pack"
    case .imported, .evaluating: return "Checking permission"
    case .serving: return "Asked to broadcast"
    case .blocked: return "Cannot broadcast"
    case .importRejected: return "Pack rejected"
    case .acquisitionFailed: return "Pack unavailable"
    case .radioRefused: return "Radio stopped"
    }
  }

  private func linkFailureTitle(_ failure: VenueLinkFailure) -> LocalizedStringKey {
    switch failure {
    case .malformedLink: return "Not a venue link"
    case .missingBundleUrl: return "Link names no source"
    case .unsupportedBundleUrl: return "Source not supported"
    }
  }

  private func scannerRefusalTitle(_ refusal: VenueLinkScanner.Authorization) -> LocalizedStringKey {
    switch refusal {
    case .granted: return "Camera ready"
    case .denied: return "No camera access"
    case .unavailableAnyway: return "Scanning unavailable"
    }
  }

  // A display-only, two-argument Debug gate. No fixture enters the verifier,
  // acquisition port or Barnard radio; no fixture is recognized in Release.
  private var fixtureCode: String? {
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    guard arguments.contains("-beid-ui-test"),
      let index = arguments.firstIndex(of: "-beid-venue-frame"),
      arguments.indices.contains(index + 1) else { return nil }
    let code = arguments[index + 1]
    return ["14b", "14d", "14e", "14e2", "14e3", "14f", "14f2", "14f3", "14g"].contains(code) ? code : nil
    #else
    return nil
    #endif
  }

  private var effectiveStatus: VenueServingStatus {
    if fixtureCode != nil { return .serving(displayName: "ETH Tokyo 2026", stopAtUnixSeconds: 0) }
    return viewModel.status
  }

  private var effectiveEventId: String? {
    if fixtureCode != nil { return "3d1a0000000000000000000000000000000000000000000000000000000077c2" }
    return viewModel.servingEventIdHex
  }

  private var effectiveRadio: VenueRadioUpdate {
    if fixtureCode != nil { return VenueRadioUpdate(state: .advertisingRequested)! }
    return viewModel.radio
  }

  private var linkFailure: VenueLinkFailure? {
    switch fixtureCode {
    case "14e": return .malformedLink
    case "14e2": return .missingBundleUrl
    case "14e3": return .unsupportedBundleUrl
    default: return viewModel.linkFailure
    }
  }

  private var effectiveScannerRefusal: VenueLinkScanner.Authorization? {
    switch fixtureCode {
    case "14f": return .denied
    case "14f2": return .unavailableAnyway
    default: return scannerRefusal
    }
  }

  private var effectiveScannerStartFailure: String? {
    if fixtureCode == "14f3" { return "AVCaptureSession could not start — the camera is in use by another app." }
    return scannerStartFailure
  }

  private var effectiveUnsavedArtifact: Bool {
    fixtureCode == "14g" || viewModel.hasUnsavedArtifact
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
      return DS.Color.statusPending
    case .advertisingRequested:
      return DS.Color.statusOn
    case .failed:
      return DS.Color.statusOff
    }
  }
}
