// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

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

  init(sensing: SensingCoordinator) {
    self.sensing = sensing
  }

  var body: some View {
    NavigationStack {
      content
        .animation(BeidDesign.Animation.soft, value: sensing.phase)
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              BeidDesign.haptic()
              coordinator.finishScan()
            } label: {
              Image(systemName: "xmark")
                .foregroundStyle(DS.Color.textPrimary)
                .frame(width: DS.Size.minHitTarget, height: DS.Size.minHitTarget)
                .beidSurface(interactive: true, cornerRadius: DS.Radius.pill)
            }
            .accessibilityLabel("Close")
          }
        }
    }
    #if DEBUG
    .safeAreaInset(edge: .top) {
      if NearbyJoinUITestFixture.isEnabled { NearbyJoinUITestReceipt() }
    }
    #endif
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
    // Dismisses off `bindingState` itself, not off any one specific caller
    // of `finishScan()`/`reset()`. `SensingCoordinator.resetSessionState()`
    // (which `finishScan()` -> `reset()` always goes through, and which
    // also runs at every fresh `.eventFound`) is the single choke point
    // that sets `bindingState = .none`, from ANY prior state — driving
    // dismissal off that value change covers every current and future
    // caller uniformly, including the Close button above (which no longer
    // special-cases the binding sheet at all — it just calls
    // `finishScan()` unconditionally and lets this handler keep
    // `bindingSheetPresented` in sync) and the `scenePhase` background
    // checkpoint path.
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
    guard case .pendingConnect = sensing.bindingState else { return }
    bindingSheetPresented = true
  }

  @ViewBuilder
  private var content: some View {
    ScanFlowContent.view(
      phase: sensing.phase,
      sensing: sensing,
      clockPreflight: coordinator.clockPreflight
    )
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

  @ViewBuilder
  static func view(
    phase: ScanPhase,
    sensing: SensingCoordinator,
    clockPreflight: ClockPreflightController? = nil,
    recordingCeremonyDwellNanos: UInt64 = 2_000_000_000
  ) -> some View {
    switch phase {
    case .idle, .sensing:
      SensingView(sensing: sensing, clockPreflight: clockPreflight)
    case .eventFound(let event):
      EventFoundView(
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

#Preview("Sensing (Dark)") {
  let coordinator = AppCoordinator()
  return ScanFlowView(sensing: coordinator.sensingCoordinator)
    .environmentObject(coordinator)
    .preferredColorScheme(.dark)
}

#Preview("Signal Lost scenario") {
  let coordinator = AppCoordinator()
  let sensing = coordinator.sensingCoordinator
  sensing.runDemoScenario(.signalLostMidway, stepDelayNanos: 0)
  return ScanFlowPreviewHarness(sensing: sensing)
    .environmentObject(coordinator)
    .task { await sensing.waitForDemoScenarioPreviewToSettle() }
}
