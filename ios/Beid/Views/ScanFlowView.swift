// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screens 05-07 (+06d), switched on `SensingCoordinator.phase`.
struct ScanFlowView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  // `AppCoordinator` doesn't republish when its nested `sensingCoordinator`
  // changes, so this view observes it directly to react to `phase` updates.
  @ObservedObject private var sensing: SensingCoordinator
  @Environment(\.scenePhase) private var scenePhase
  /// The connect+binding interstitial (§5.6). Presented over this view
  /// (never blocking `.recording`) through two triggers that both funnel
  /// into `presentBindingSheetIfNeeded()` below:
  ///
  /// 1. **Primary — `.onChange(of: sensing.entranceCeremonyFinished)`**:
  ///    fires the moment `RecordingView`'s one-time entrance ceremony
  ///    finishes, whether or not the app is foreground at that instant.
  ///    Presenting while the user is already looking at the screen is
  ///    intended, not an interruption to avoid — owner decision
  ///    2026-08-18. DECISIONS 2026-07-30 already specified binding at
  ///    `.recording`'s own start ("recording 開始 = 前面化 binding と同時");
  ///    gating presentation on a background→foreground transition alone
  ///    left it unreachable for any session that never backgrounds (the
  ///    whole DemoEvent walkthrough, for one) — 2026-08-18 fixed that
  ///    wiring gap, it did not introduce a new policy.
  /// 2. **Safety net — `.onChange(of: scenePhase)`**: re-checks
  ///    `presentBindingSheetIfNeeded()` on return to foreground, covering a
  ///    session that *did* background before the ceremony finished.
  ///    `presentBindingSheetIfNeeded()` re-checks `bindingState ==
  ///    .pendingConnect` and no-ops if the sheet is already up, so both
  ///    triggers firing is harmless.
  @State private var bindingSheetPresented = false
  @State private var restoreBindingSheetAfterKeepSensing = false
  @State private var preflightStateKey: String?

  init(sensing: SensingCoordinator) {
    self.sensing = sensing
  }

  var body: some View {
    NavigationStack {
      content
        .animation(DS.Motion.screenTransition, value: sensing.phase)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(
          usesInkGround ? DS.Color.textPrimary : DS.Color.surfaceCanvas,
          for: .navigationBar
        )
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(usesInkGround ? .dark : .light, for: .navigationBar)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: DS.Space.s) {
              Circle()
                .fill(usesInkGround ? DS.Color.labelOnActionPrimary : DS.Color.textPrimary)
                .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                .accessibilityHidden(true)
              Text(statusTitle)
                .beidTextStyle(DS.Font.Library.labelMono11)
                .foregroundStyle(
                  usesInkGround ? DS.Color.labelOnActionPrimary : DS.Color.textPrimary
                )
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
          }
          // #631 / 2026-09-25: suppress iOS 26's item glass; #630 removed
          // branches that added glass, not this branch that removes it.
          .beidWithoutSharedBackground()
          ToolbarItem(placement: .topBarTrailing) {
            if coordinator.sealedSnapshot != nil || isSealedScreenshotFixture {
              BeidTextControl(
                "Done",
                labelColor: DS.Color.textSecondaryOnInk,
                accessibilityLabel: "Done"
              ) {
                if coordinator.sealedSnapshot != nil {
                  coordinator.doneWithSealedRecord()
                } else {
                  coordinator.finishScan()
                }
              }
            } else if coordinator.stopConfirmSnapshot == nil && !isStopConfirmScreenshotFixture {
              BeidTextControl(
                "Close",
                labelColor: usesInkGround ? DS.Color.textSecondaryOnInk : DS.Color.textPrimary,
                accessibilityLabel: "Close"
              ) {
                restoreBindingSheetAfterKeepSensing = bindingSheetPresented
                bindingSheetPresented = false
                coordinator.requestScanClose()
              }
            }
          }
          .beidWithoutSharedBackground()
        }
    }
    .sheet(isPresented: $bindingSheetPresented) {
      EventBindingSheetView(sensing: sensing)
        .environmentObject(coordinator)
    }
    .onChange(of: scenePhase) { oldPhase, newPhase in
      // Extends the existing observer rather than adding a second
      // `.onChange(of: scenePhase)` — two independent handlers on the same
      // transition would be a needless duplicate-firing risk with no
      // offsetting benefit (`docs/specs/session-end-finalization.md` §3.4).
      //
      // Gated on the bare `newPhase == .background` value, with no
      // additional `oldPhase` check — deliberately, not by omission.
      // `onChange`'s own semantics only invoke this closure when
      // `scenePhase` actually *changes*, so reaching this branch already
      // means a real .active/.inactive → .background TRANSITION just
      // happened, not a bare state re-check on every render. That is
      // exactly the bug the foreground branch below once had (originally
      // gated on "is scenePhase currently .active", which fired on every
      // re-render while already active because it wasn't tied to a change
      // event at all) — the fix there was moving the check into
      // `onChange`, which this branch already lives inside of. The
      // `oldPhase != .active` guard on the foreground branch is in fact
      // always true once `onChange` fires with `newPhase == .active` (two
      // different values are required to fire), so it is self-documenting
      // rather than load-bearing; the same reasoning means an
      // `oldPhase != .background` clause here would be equally redundant,
      // so it's omitted. If the app backgrounds more than once in a
      // session (background → foreground → background again), this
      // correctly checkpoints each real entry — the checkpoint's own
      // guard-on-nil (`SensingCoordinator.checkpointOpenWindowForBackgrounding()`)
      // already makes a second checkpoint with nothing new observed a safe
      // no-op, so firing on every genuine entry is correct, not a risk.
      if newPhase == .background {
        sensing.checkpointOpenWindowForBackgrounding()
      }
      guard oldPhase != .active, newPhase == .active else { return }
      presentBindingSheetIfNeeded()
    }
    .onReceive(coordinator.clockPreflight.$stateKey) { preflightStateKey = $0 }
    // Dismisses off `bindingState` itself, not off any one specific caller
    // of `reset()`. `SensingCoordinator.resetSessionState()` (reached by
    // confirmed stop, direct prejoin CLOSE, and every fresh `.eventFound`)
    // is the single choke point
    // that sets `bindingState = .none`, from ANY prior state — driving
    // dismissal off that value change covers every current and future
    // caller uniformly, including a confirmed CLOSE that resets the
    // session and the `scenePhase` background checkpoint path.
    //
    // Any transition INTO `.none`, from any prior state. Never fires
    // mid-attempt — `.connecting`/`.awaitingApproval`/`.bound`/`.failed`
    // are none of them `.none`, so the sheet stays up through the whole
    // round trip, including `.failed` -> (Try Again -> `declineBinding()`)
    // -> `.pendingConnect`, which never passes through `.none` at all.
    .onChange(of: sensing.bindingState) { _, newValue in
      guard case .none = newValue else { return }
      bindingSheetPresented = false
    }
    // Presentation is chained to the entrance ceremony finishing, not
    // directly to `bindingState` reaching `.pendingConnect` — §5.5 wants
    // the one-time "Proof Collected" ceremony and the binding prompt
    // sequenced one after the other, not the sheet's presentation
    // animation starting on top of the ceremony's. `RecordingView.onAppear`
    // marks this even when there's no ceremony to show at all (a resumed
    // session), so this still fires promptly in that case rather than
    // waiting on something that will never happen.
    .onChange(of: sensing.entranceCeremonyFinished) { _, newValue in
      guard newValue else { return }
      presentBindingSheetIfNeeded()
    }
  }

  private func presentBindingSheetIfNeeded() {
    guard coordinator.stopConfirmSnapshot == nil, coordinator.sealedSnapshot == nil else { return }
    guard case .pendingConnect = sensing.bindingState else { return }
    bindingSheetPresented = true
  }

  private var usesInkGround: Bool {
    if coordinator.stopConfirmSnapshot != nil || coordinator.sealedSnapshot != nil { return true }
    #if DEBUG
    if sensing.sensingScreenshotFixture != nil { return true }
    #endif
    if preflightStateKey == "overTolerance" || preflightStateKey == "undeterminable"
      || sensing.joinRefusalReasonKey != nil {
      return true
    }
    switch sensing.phase {
    case .eventFound, .recording: return true
    case .idle, .sensing, .signalLost: return false
    }
  }

  private var statusTitle: String {
    if let sealed = coordinator.sealedSnapshot {
      return "Sealed · \(Int(sealed.aggregate?.windowCount ?? 0)) windows"
    }
    if coordinator.stopConfirmSnapshot != nil {
      let count = Int(sensing.sessionAggregate?.windowCount ?? 0)
      return count > 0 ? "Sensing · window \(count)" : "Sensing"
    }
    #if DEBUG
    if sensing.sensingScreenshotFixture == .sealed {
      return "Sealed · \(Int(sensing.sessionAggregate?.windowCount ?? 0)) windows"
    }
    if sensing.sensingScreenshotFixture == .cantJoin { return "Can't join · clock off" }
    #endif
    if preflightStateKey == "overTolerance" { return "Can't join · clock off" }
    if preflightStateKey == "undeterminable" { return "Can't join · clock unchecked" }
    if sensing.joinRefusalReasonKey != nil { return "Can't join" }
    switch sensing.phase {
    case .eventFound, .recording:
      let count = Int(sensing.sessionAggregate?.windowCount ?? 0)
      return count > 0 ? "Sensing · window \(count)" : "Sensing"
    case .idle, .sensing, .signalLost:
      return "Sensing"
    }
  }

  private var isSealedScreenshotFixture: Bool {
    #if DEBUG
    return sensing.sensingScreenshotFixture == .sealed
    #else
    return false
    #endif
  }

  private var isStopConfirmScreenshotFixture: Bool {
    #if DEBUG
    return sensing.sensingScreenshotFixture == .stopConfirm
    #else
    return false
    #endif
  }

  @ViewBuilder
  private var content: some View {
    if let sealed = coordinator.sealedSnapshot {
      SensingSealedView(snapshot: sealed)
    } else if let pending = coordinator.stopConfirmSnapshot {
      SensingStopConfirmView(
        sensing: sensing,
        snapshot: pending,
        onStop: {
          restoreBindingSheetAfterKeepSensing = false
          coordinator.confirmStopSensing()
        },
        onKeepSensing: {
          coordinator.keepSensing()
          guard restoreBindingSheetAfterKeepSensing else { return }
          restoreBindingSheetAfterKeepSensing = false
          Task { @MainActor in
            await Task.yield()
            presentBindingSheetIfNeeded()
          }
        }
      )
    } else {
      ScanFlowContent.view(
        phase: sensing.phase,
        sensing: sensing,
        clockPreflight: coordinator.clockPreflight
      )
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
    clockPreflight: ClockPreflightController? = nil,
    recordingCeremonyDwellNanos: UInt64 = 2_000_000_000
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
        clockPreflight: clockPreflight,
        recordingCeremonyDwellNanos: recordingCeremonyDwellNanos
      )
    }
    #else
    productionView(
      phase: phase,
      sensing: sensing,
      clockPreflight: clockPreflight,
      recordingCeremonyDwellNanos: recordingCeremonyDwellNanos
    )
    #endif
  }

  @ViewBuilder
  private static func productionView(
    phase: ScanPhase,
    sensing: SensingCoordinator,
    clockPreflight: ClockPreflightController?,
    recordingCeremonyDwellNanos: UInt64
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
    case .recording(let event, let peersVerified):
      RecordingView(
        sensing: sensing,
        event: event,
        peersVerified: peersVerified,
        onRetryVerification: { sensing.retryEventIdentityVerification() },
        ceremonyDwellNanos: recordingCeremonyDwellNanos
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
      SensingCantJoinView(
        reason: .clockOff,
        code: event.id,
        event: event,
        candidate: NearbyEventCard(
          beaconDisplayName: event.name,
          eventIdHex: "fixture-event-id",
          displayValidFromEpochSeconds: nil,
          displayValidUntilEpochSeconds: nil,
          eventCodeHashHex: "fixture-hash"
        ),
        onCheckAgain: {}
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
    }
  }
  #endif
}

/// A thin preview-only state observer. It deliberately delegates every phase
/// to `ScanFlowContent`, so preview scenarios exercise the same production
/// views and routing as a real scan flow.
struct ScanFlowPreviewHarness: View {
  @ObservedObject var sensing: SensingCoordinator
  let recordingCeremonyDwellNanos: UInt64

  init(sensing: SensingCoordinator, recordingCeremonyDwellNanos: UInt64 = 0) {
    self.sensing = sensing
    self.recordingCeremonyDwellNanos = recordingCeremonyDwellNanos
  }

  var body: some View {
    ScanFlowContent.view(
      phase: sensing.phase,
      sensing: sensing,
      recordingCeremonyDwellNanos: recordingCeremonyDwellNanos
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
