// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Screens 06b/06c/07 merged: the steady `.recording` phase, replacing
/// `VerifyingView` + `VerifiedView`. `ProofCollectedView`'s Figma content
/// (checkmark artwork + copy) becomes a one-time entrance ceremony shown the
/// instant `.recording` begins, then gives way to the steady eventCard —
/// see `docs/specs/scan-slice2-redesign.md` §5.2-§5.5.
struct RecordingView: View {
  @ObservedObject var sensing: SensingCoordinator
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let event: EventSession
  let peersVerified: Int

  /// Seeded once at this view identity's creation from
  /// `sensing.recordingCeremonyShown` — SwiftUI preserves `@State` across
  /// re-renders of the same identity (e.g. as `peersVerified` grows), so
  /// this only evaluates `true` on the very first appearance of this
  /// identity. A fresh `RecordingView` identity created after a
  /// signal-lost → resume cycle correctly sees `false` here, since
  /// `sensing.recordingCeremonyShown` (not view-local state) is the source
  /// of truth and is never reset by `resumeSensing()`.
  @State private var showEntranceCeremony: Bool
  /// How long the ceremony dwells before fading into the steady eventCard.
  /// Overridable only so previews/tests can make the transition
  /// deterministic instead of racing a real 2-second timer; production call
  /// sites (`ScanFlowView`) always use the default.
  private let ceremonyDwellNanos: UInt64

  init(
    sensing: SensingCoordinator,
    event: EventSession,
    peersVerified: Int,
    ceremonyDwellNanos: UInt64 = 2_000_000_000
  ) {
    self.sensing = sensing
    self.event = event
    self.peersVerified = peersVerified
    self.ceremonyDwellNanos = ceremonyDwellNanos
    _showEntranceCeremony = State(initialValue: !sensing.recordingCeremonyShown)
  }

  var body: some View {
    BeidScreen {
      VStack(spacing: BeidDesign.Spacing.section) {
        if showEntranceCeremony {
          // Reuses ProofCollectedView's retired hero content verbatim (same
          // already-localized strings, §5.5) as a one-time highlight, not a
          // separate screen.
          BeidHeroHeader(
            systemImage: "seal.fill",
            assetImage: "proof-seal-mark",
            title: "Proof Collected",
            subtitle: "Added to your collection.",
            tint: DS.Color.proofSeal
          )
          .transition(.opacity)
        }

        EventCardView(event: event, badge: .recording) {
          HStack(spacing: DS.Space.s) {
            // Indeterminate, non-fractional activity indicator — no
            // denominator exists to show a fraction of (§5.2). Not
            // `ProgressView(value:)`.
            ProgressView()
              .tint(DS.Color.proofSeal)
            Text(recordingCaption)
              .font(DS.Font.meta)
              .foregroundStyle(DS.Color.textSecondary)
          }
        }
      }
    } footer: {
      // Demo-mode-only affordance so the Signal Lost screen stays
      // reachable even though the golden EventSession path keeps
      // recording indefinitely otherwise.
      #if DEBUG
      if sensing.useDemoEventMode {
        Button("Simulate Signal Lost", role: .destructive) {
          BeidDesign.haptic(.medium)
          sensing.simulateSignalLost()
        }
        .font(DS.Font.meta)
      }
      #endif
    }
    // Ceremony screen: DESIGN.md §5 "one motif accent per screen" — the
    // one-time change from 06a's signalActive to proofSeal once recording
    // is confirmed (§5.2).
    .tint(DS.Color.proofSeal)
    .onAppear {
      guard showEntranceCeremony else { return }
      sensing.markRecordingCeremonyShown()
      Task {
        try? await Task.sleep(nanoseconds: ceremonyDwellNanos)
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : DS.Motion.proofResolve) {
          showEntranceCeremony = false
        }
      }
    }
  }

  private var recordingCaption: String {
    String(
      localized: "scan.recording.caption",
      defaultValue: "Recording your attendance automatically · \(peersVerified) peers verified",
      comment: "Cumulative count of distinct peers who have mutually sensed this device at the event; no fixed target."
    )
  }
}

#Preview("Entrance ceremony") {
  let coordinator = AppCoordinator()
  return RecordingView(sensing: coordinator.sensingCoordinator, event: .demoSample, peersVerified: 3)
    .environmentObject(coordinator)
}

#Preview("Entrance ceremony (Dark)") {
  let coordinator = AppCoordinator()
  return RecordingView(sensing: coordinator.sensingCoordinator, event: .demoSample, peersVerified: 3)
    .environmentObject(coordinator)
    .preferredColorScheme(.dark)
}

// Steady-state previews pre-consume the ceremony flag directly (rather than
// relying on the view's own timer) so the snapshot is deterministic: this
// is what a `RecordingView` created *after* the ceremony already played
// looks like — e.g. reopening the scan modal mid-session, or every
// `peersVerified` re-render after the first.

#Preview("Steady state, growing (no wallet)") {
  let coordinator = AppCoordinator()
  coordinator.sensingCoordinator.markRecordingCeremonyShown()
  return RecordingView(sensing: coordinator.sensingCoordinator, event: .demoSample, peersVerified: 9)
    .environmentObject(coordinator)
}

#Preview("Steady state (Dark)") {
  let coordinator = AppCoordinator()
  coordinator.sensingCoordinator.markRecordingCeremonyShown()
  return RecordingView(sensing: coordinator.sensingCoordinator, event: .demoSample, peersVerified: 9)
    .environmentObject(coordinator)
    .preferredColorScheme(.dark)
}

/// Demonstrates the ceremony-shows-once contract (§5.5, §8) end to end
/// through the real state machine, not a hand-assembled scenario: drives
/// `SensingCoordinator`'s real demo sequence so `.recording` begins exactly
/// once (marking `recordingCeremonyShown` via `RecordingView`'s own
/// `.onAppear`), then lets `peersVerified` grow for two further updates
/// while `RecordingView` stays mounted at the same SwiftUI identity — the
/// same identity-preservation `ScanFlowView` relies on. `ceremonyDwellNanos:
/// 0` only removes the *timer race* from this snapshot; it does not change
/// which mechanism gates the ceremony (still `sensing.recordingCeremonyShown`,
/// set once in `.onAppear`). If the ceremony instead reset itself on every
/// re-render, this preview would still be showing the "Proof Collected"
/// hero after all three phase updates — it shows the steady eventCard.
#Preview("Ceremony does not replay across peersVerified updates") {
  let coordinator = AppCoordinator()
  let sensing = coordinator.sensingCoordinator
  sensing.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
  return ScanFlowPreviewHarness(sensing: sensing)
    .environmentObject(coordinator)
    .task {
      await sensing.waitForDemoSequenceToFinish()
      // Grace period for the near-zero ceremony dwell timer (kicked off by
      // the first `.recording` render's `.onAppear`) to resolve before the
      // static snapshot is taken.
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
}

/// Thin `#Preview`-only wrapper that re-reads `sensing.phase` on every
/// change, the same way `ScanFlowView` does, so the "ceremony does not
/// replay" preview above renders `RecordingView` fresh for each
/// `peersVerified` update rather than a single static snapshot.
private struct ScanFlowPreviewHarness: View {
  @ObservedObject var sensing: SensingCoordinator

  var body: some View {
    switch sensing.phase {
    case .recording(let event, let peersVerified):
      RecordingView(sensing: sensing, event: event, peersVerified: peersVerified, ceremonyDwellNanos: 0)
    default:
      Text(verbatim: "phase: \(sensing.phase)")
    }
  }
}
