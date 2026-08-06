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
  /// (never blocking `.recording`) the *next* time the app becomes active
  /// while `bindingState` is `.pendingConnect` — deliberately gated on an
  /// actual background/inactive→active scene transition (not merely "is
  /// currently active"), matching D3's own rationale for splitting this
  /// trigger from the confirm/recording transition: popping the sheet the
  /// instant the threshold trips, while the user may be actively looking at
  /// this same screen, would be the intrusive mid-interaction interruption
  /// D3 specifically avoided by choosing the next-foreground moment.
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
    .sheet(isPresented: $bindingSheetPresented) {
      EventBindingSheetView(sensing: sensing)
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
  }

  private func presentBindingSheetIfNeeded() {
    guard case .pendingConnect = sensing.bindingState else { return }
    bindingSheetPresented = true
  }

  @ViewBuilder
  private var content: some View {
    switch sensing.phase {
    case .idle, .sensing:
      SensingView()
    case .eventFound(let event):
      EventFoundView(event: event)
    case .recording(let event, let peersVerified):
      RecordingView(sensing: sensing, event: event, peersVerified: peersVerified)
    case .signalLost(let event, let peersVerified):
      SignalLostView(event: event, peersVerified: peersVerified)
    }
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

// Only the container's default (.idle/.sensing) phase is previewed here.
// `phase` is `private(set)` on `SensingCoordinator` by design (state only
// advances through the real/demo sensing sequence) so other phases aren't
// independently reachable from a preview; each phase already has its own
// dedicated #Preview on its view (EventFoundView, RecordingView,
// SignalLostView).
