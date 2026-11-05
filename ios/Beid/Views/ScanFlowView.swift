// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Sensing details are pushed from Now. Back preserves participation.
struct ScanFlowView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @ObservedObject private var sensing: SensingCoordinator
  @Environment(\.scenePhase) private var scenePhase

  init(sensing: SensingCoordinator) {
    self.sensing = sensing
  }

  var body: some View {
    content
      .animation(DS.Motion.screenTransition, value: sensing.phase)
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar(proofCollectedForDisplay == nil ? .visible : .hidden, for: .navigationBar)
      .toolbar(.hidden, for: .tabBar)
      .toolbarBackground(usesInkGround ? DS.Color.textPrimary : DS.Color.surfaceCanvas, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarColorScheme(usesInkGround ? .dark : .light, for: .navigationBar)
      .toolbar {
        if proofCollectedForDisplay == nil {
          ToolbarItem(placement: .principal) {
            Text(statusTitle)
              .beidTextStyle(DS.Font.Library.labelMono11)
          }
          if coordinator.sealedSnapshot != nil || isSealedScreenshotFixture {
            ToolbarItem(placement: .confirmationAction) { doneButton }
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        if showsStopControl {
          BeidTextControl("STOP SENSING", labelColor: usesInkGround ? DS.Color.labelOnActionPrimary : DS.Color.textPrimary) {
            coordinator.requestScanClose()
          }
          .frame(maxWidth: .infinity)
          .padding(DS.Space.m)
          .background(usesInkGround ? DS.Color.textPrimary : DS.Color.surfaceCanvas)
          .accessibilityIdentifier("scan.stop-sensing")
        }
      }
      #if DEBUG
      .safeAreaInset(edge: .top) {
        if NearbyJoinUITestFixture.isEnabled { NearbyJoinUITestReceipt() }
      }
      #endif
      .onChange(of: scenePhase) { _, newPhase in
        if newPhase == .background { sensing.checkpointOpenWindowForBackgrounding() }
        if newPhase == .active { sensing.retryPendingSubmissionsOnForeground() }
      }
  }

  @ViewBuilder private var doneButton: some View {
    if #available(iOS 26, *) {
      Button(role: .confirm, action: finishSealedScan)
    } else {
      Button("Done", action: finishSealedScan)
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
    guard coordinator.sealedSnapshot == nil, coordinator.stopConfirmSnapshot == nil,
      proofCollectedForDisplay == nil else { return false }
    #if DEBUG
    if let fixture = sensing.sensingScreenshotFixture {
      switch fixture {
      case .sensing, .detecting, .detectingLong, .detectingFirstTime: return true
      case .cantJoin, .stopConfirm, .sealed, .proofCollected: return false
      }
    }
    #endif
    switch sensing.phase {
    case .eventFound, .recording, .signalLost: return true
    case .idle, .sensing: return false
    }
  }

  private var usesInkGround: Bool {
    if proofCollectedForDisplay != nil { return false }
    if coordinator.stopConfirmSnapshot != nil || coordinator.sealedSnapshot != nil { return true }
    #if DEBUG
    if sensing.sensingScreenshotFixture != nil { return true }
    #endif
    if sensing.joinRefusalReasonKey != nil { return true }
    switch sensing.phase {
    case .eventFound, .recording: return true
    case .idle, .sensing, .signalLost: return false
    }
  }

  private var statusTitle: String {
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
    if let collected = proofCollectedForDisplay {
      ProofCollectedView(snapshot: collected, sigilInput: sensing.sigilInput(forProofId: collected.recordID)) {
        if coordinator.proofCollectedSnapshot != nil {
          coordinator.viewCollectionAfterProofCollected()
        } else {
          coordinator.finishScan()
        }
      }
    } else if let sealed = coordinator.sealedSnapshot {
      SensingSealedView(snapshot: sealed, sigilInput: sealed.recordID.flatMap { sensing.sigilInput(forProofId: $0) })
    } else if let pending = coordinator.stopConfirmSnapshot {
      SensingStopConfirmView(
        sensing: sensing,
        snapshot: pending,
        onStop: { coordinator.confirmStopSensing() },
        onKeepSensing: { coordinator.keepSensing() }
      )
    } else {
      ScanFlowContent.view(phase: sensing.phase, sensing: sensing, clockPreflight: coordinator.clockPreflight)
    }
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
      SensingStopConfirmView(
        sensing: sensing,
        snapshot: SensingStopConfirmSnapshot(
          proofID: nil,
          event: event
        ),
        onStop: {},
        onKeepSensing: {}
      )
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
