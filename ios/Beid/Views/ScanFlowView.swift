// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Sensing details are pushed from Now. Back preserves participation.
struct ScanFlowView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @ObservedObject private var sensing: SensingCoordinator
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("beid.sensing.firstTimeHintShown") private var hasShownFirstTimeHint = false
  // Latch eligibility for this navigation lifetime, including phase changes
  // and returning from About sensing. Only a later visit reads persistence.
  @State private var showsFirstTimeHint: Bool?

  init(sensing: SensingCoordinator) {
    self.sensing = sensing
  }

  var body: some View {
    VStack(spacing: 0) {
      content
      if showsStopControl {
        stopFooter
          .layoutPriority(1)
      }
    }
      .environment(\.showsFirstSensingHint, showsFirstTimeHint ?? false)
      .onAppear {
        if showsFirstTimeHint == nil { showsFirstTimeHint = !hasShownFirstTimeHint }
      }
      .animation(reduceMotion ? nil : DS.Motion.screenTransition, value: sensing.phase)
      .navigationTitle(statusTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar(proofCollectedForDisplay == nil ? .visible : .hidden, for: .navigationBar)
      .toolbar(.hidden, for: .tabBar)
      .toolbarBackground(usesInkGround ? DS.Color.textPrimary : DS.Color.surfaceCanvas, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarColorScheme(usesInkGround ? .dark : .light, for: .navigationBar)
      .toolbar {
        if proofCollectedForDisplay == nil {
          if coordinator.sealedSnapshot != nil || isSealedScreenshotFixture {
            ToolbarItem(placement: .confirmationAction) { doneButton }
          }
          #if DEBUG
          if sensing.isDemoAdvanceEnabled, let token = sensing.demoAdvanceToken,
             coordinator.stopConfirmSnapshot == nil, coordinator.sealedSnapshot == nil {
            ToolbarItem(placement: .topBarTrailing) {
              Button("Advance demo") { sensing.advanceDemo(token: token) }
                .accessibilityIdentifier("demo.advance.\(token.uuidString)")
                .accessibilityValue(String(describing: ScanFlowContent.route(for: sensing.phase)))
            }
          }
          #endif
        }
      }
      #if DEBUG
      .safeAreaInset(edge: .top) {
        if NearbyJoinUITestFixture.isEnabled { NearbyJoinUITestReceipt() }
      }
      .safeAreaInset(edge: .bottom) {
        if coordinator.stopOutcomeUITestFixture != nil {
          Button("Repeat STOP confirmation") { coordinator.confirmStopSensing() }
            .accessibilityIdentifier("stop.fixture.repeat-confirmation")
        }
      }
      #endif
      .modifier(EventSigningKeyFailurePresenter(
        sensingCoordinator: sensing,
        isActive: coordinator.scanPresented
      ))
      .onChange(of: scenePhase) { _, newPhase in
        if newPhase == .background { sensing.checkpointOpenWindowForBackgrounding() }
        if newPhase == .active { sensing.retryPendingSubmissionsOnForeground() }
      }
  }

  private var stopFooter: some View {
    BeidAdaptiveContent {
      Button {
        coordinator.requestScanClose()
      } label: {
        Text("Stop sensing")
          .frame(maxWidth: .infinity, minHeight: DS.Size.minHitTarget)
      }
      .font(DS.Font.Library.title16.font)
      .buttonStyle(.bordered)
      .tint(usesInkGround ? DS.Color.labelOnActionPrimary : DS.Color.textPrimary)
      .accessibilityIdentifier("scan.stop-sensing")
      .padding(.horizontal, DS.Space.pageMargin)
    }
    .alert(
      "Stop sensing?",
      isPresented: stopConfirmationPresented,
      presenting: coordinator.stopConfirmSnapshot
    ) { snapshot in
      Button(LocalizedStringKey(snapshot.copy.stopTitle)) {
        coordinator.confirmStopSensing()
      }
      Button("Cancel", role: .cancel) {
        coordinator.keepSensing()
      }
    } message: { snapshot in
      Text(verbatim: snapshot.copy.body)
    }
    .padding(.vertical, DS.Space.s)
    .background(usesInkGround ? DS.Color.textPrimary : DS.Color.surfaceCanvas)
  }

  @ViewBuilder private var doneButton: some View {
    if #available(iOS 26, *) {
      Button(role: .confirm, action: finishSealedScan)
    } else {
      Button("Done", systemImage: "checkmark", action: finishSealedScan)
    }
  }

  private func finishSealedScan() {
    if coordinator.sealedSnapshot != nil {
      coordinator.doneWithSealedRecord()
    } else {
      coordinator.finishScan()
    }
  }

  private var showsStopControl: Bool {
    // Keep the stop control mounted while it presents its confirmation alert.
    guard coordinator.sealedSnapshot == nil,
      coordinator.stopOutcome == nil, proofCollectedForDisplay == nil else { return false }
    #if DEBUG
    if let fixture = sensing.sensingScreenshotFixture {
      switch fixture {
      case .sensing, .detecting, .detectingLong, .detectingFirstTime, .stopConfirm: return true
      case .cantJoin, .sealed, .proofCollected: return false
      }
    }
    #endif
    return Self.showsStopControl(phase: sensing.phase, joinedEventCode: sensing.joinedEventCode)
  }

  private var stopConfirmationPresented: Binding<Bool> {
    Binding(
      get: { coordinator.stopConfirmSnapshot != nil },
      set: { isPresented in
        if !isPresented { coordinator.keepSensing() }
      }
    )
  }

  /// After JOIN the phase stays `.sensing` until the first detection. A
  /// participant whose event is not nearby must still be able to end, so the
  /// control shows in `.sensing` once an event has been joined.
  static func showsStopControl(phase: ScanPhase, joinedEventCode: String?) -> Bool {
    switch phase {
    case .eventFound, .recording, .signalLost: return true
    case .sensing: return joinedEventCode != nil
    case .idle: return false
    }
  }

  private var usesInkGround: Bool {
    if proofCollectedForDisplay != nil { return false }
    if coordinator.sealedSnapshot != nil { return true }
    #if DEBUG
    if sensing.sensingScreenshotFixture != nil { return true }
    #endif
    if sensing.joinRefusalReasonKey != nil { return true }
    switch sensing.phase {
    case .eventFound, .recording: return true
    case .idle, .sensing, .signalLost: return false
    }
  }

  private var statusTitle: LocalizedStringKey {
    if coordinator.stopOutcome != nil { return "stop.outcome.title" }
    if coordinator.sealedSnapshot != nil || isSealedScreenshotFixture { return "Record saved" }
    if sensing.joinRefusalReasonKey != nil { return "Can't join" }
    #if DEBUG
    if sensing.sensingScreenshotFixture == .cantJoin { return "Can't join" }
    #endif
    return "Sensing"
  }

  private var isSealedScreenshotFixture: Bool {
    #if DEBUG
    return sensing.sensingScreenshotFixture == .sealed
    #else
    return false
    #endif
  }

  private var proofCollectedForDisplay: ProofCollectedSnapshot? {
    if let snapshot = coordinator.proofCollectedSnapshot { return snapshot }
    #if DEBUG
    if sensing.sensingScreenshotFixture == .proofCollected { return .screenshotFixture }
    #endif
    return nil
  }

  @ViewBuilder private var content: some View {
    if coordinator.stopOutcome != nil {
      stopOutcomeView
    } else if let collected = proofCollectedForDisplay {
      ProofCollectedView(snapshot: collected, sigilInput: sensing.sigilInput(forProofId: collected.recordID)) {
        if coordinator.proofCollectedSnapshot != nil {
          coordinator.viewCollectionAfterProofCollected()
        } else {
          coordinator.finishScan()
        }
      }
    } else if let sealed = coordinator.sealedSnapshot {
      SensingSealedView(snapshot: sealed, sigilInput: sealed.recordID.flatMap { sensing.sigilInput(forProofId: $0) })
    } else {
      ScanFlowContent.view(phase: sensing.phase, sensing: sensing, clockPreflight: coordinator.clockPreflight)
    }
  }

  private var stopOutcomeView: some View {
    ScrollView {
      BeidAdaptiveContent(regularMaxWidth: DS.Layout.collectionContentMaxWidth) {
        VStack(spacing: DS.Space.l) {
          BeidEmptyState(
            Text("stop.outcome.title"), description: Text("stop.outcome.message"),
            descriptionIdentifier: "stop.outcome.message"
          ) {
            BeidPrimaryButton("stop.outcome.action") { coordinator.dismissStopOutcome() }
              .accessibilityIdentifier("stop.outcome.action")
          }
        }
        .padding(DS.Space.pageMargin)
      }
    }
    .background(DS.Color.surfaceCanvas.ignoresSafeArea())
  }
}

/// The sole production router for scan-phase content. Keeping the route next
/// to the actual view construction means preview scenarios exercise the same
/// Sensing/Event Found/Recording/Signal Lost views as the app, not a reduced
/// card or diagnostic placeholder.
enum ScanFlowContent {
  enum Route: Equatable {
    case sensing
    case eventFound
    case recording
    case signalLost
  }

  static func route(for phase: ScanPhase) -> Route {
    switch phase {
    case .idle, .sensing:
      .sensing
    case .eventFound:
      .eventFound
    case .recording:
      .recording
    case .signalLost:
      .signalLost
    }
  }

  @MainActor
  @ViewBuilder
  static func view(
    phase: ScanPhase,
    sensing: SensingCoordinator,
    clockPreflight: ClockPreflightController? = nil
  ) -> some View {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-beid-ui-test"),
      let fixture = sensing.sensingScreenshotFixture,
      let event = sensing.sensingScreenshotEvent {
      screenshotView(fixture: fixture, event: event, sensing: sensing)
    } else {
      productionView(
        phase: phase,
        sensing: sensing,
        clockPreflight: clockPreflight
      )
    }
    #else
    productionView(
      phase: phase,
      sensing: sensing,
      clockPreflight: clockPreflight
    )
    #endif
  }

  @ViewBuilder
  private static func productionView(
    phase: ScanPhase,
    sensing: SensingCoordinator,
    clockPreflight: ClockPreflightController?
  ) -> some View {
    switch phase {
    case .idle, .sensing:
      if let clockPreflight {
        SensingPrejoinRouter(sensing: sensing, clockPreflight: clockPreflight)
      } else {
        SensingView(sensing: sensing)
      }
    case .eventFound(let event):
      EventFoundView(
        sensing: sensing,
        event: event,
        onRetryVerification: { sensing.retryEventIdentityVerification() }
      )
    case .recording(let event, _):
      RecordingView(
        sensing: sensing,
        event: event,
        onRetryVerification: { sensing.retryEventIdentityVerification() }
      )
    case .signalLost(let event, let peersVerified):
      SignalLostView(
        event: event,
        peersVerified: peersVerified,
        onRetryVerification: { sensing.retryEventIdentityVerification() }
      )
    }
  }

  #if DEBUG
  @MainActor
  @ViewBuilder
  private static func screenshotView(
    fixture: SensingScreenshotFixture,
    event: EventSession,
    sensing: SensingCoordinator
  ) -> some View {
    switch fixture {
    case .sensing:
      SensingSessionSurface(sensing: sensing, event: event, presentation: .steady)
    case .detecting:
      SensingSessionSurface(sensing: sensing, event: event, presentation: .detecting)
    case .detectingLong:
      SensingSessionSurface(sensing: sensing, event: event, presentation: .detectingLong)
    case .detectingFirstTime:
      SensingSessionSurface(sensing: sensing, event: event, presentation: .detectingFirstTime)
    case .cantJoin:
      // 05d is reached only by a join refusal: a clock notice never blocks.
      SensingCantJoinView(
        reason: .refused("event_not_active"),
        code: event.id,
        event: event,
        candidate: NearbyEventCard(
          beaconDisplayName: event.name,
          eventIdHex: "fixture-event-id",
          displayValidFromEpochSeconds: nil,
          displayValidUntilEpochSeconds: nil,
          eventCodeHashHex: "fixture-hash"
        )
      )
    case .stopConfirm:
      SensingSessionSurface(sensing: sensing, event: event, presentation: .steady)
    case .sealed:
      SensingSealedView(snapshot: SensingSealedSnapshot(
        recordID: nil,
        event: event,
        aggregate: sensing.sessionAggregate,
        detectedDeviceCount: sensing.devicesVerified,
        firstSightingAt: sensing.firstSightingAt,
        sealedAt: sensing.sensingPresentationNow(Date())
      ))
    case .proofCollected:
      ProofCollectedView(snapshot: .screenshotFixture, onViewCollection: {})
    }
  }
  #endif
}

/// A thin preview-only state observer. It deliberately delegates every phase
/// to `ScanFlowContent`, so preview scenarios exercise the same production
/// views and routing as a real scan flow.
struct ScanFlowPreviewHarness: View {
  @ObservedObject var sensing: SensingCoordinator

  var body: some View {
    ScanFlowContent.view(
      phase: sensing.phase,
      sensing: sensing
    )
  }
}

#Preview("Sensing") {
  let coordinator = AppCoordinator()
  return ScanFlowView(sensing: coordinator.sensingCoordinator).environmentObject(coordinator)
}

#Preview("Signal Lost scenario") {
  let coordinator = AppCoordinator()
  let sensing = coordinator.sensingCoordinator
  sensing.runDemoScenario(.signalLostMidway, stepDelayNanos: 0)
  return ScanFlowPreviewHarness(sensing: sensing)
    .environmentObject(coordinator)
    .task { await sensing.waitForDemoScenarioPreviewToSettle() }
}
