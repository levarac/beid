// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import SwiftUI

/// Screens 06b/06c/07 merged: the steady `.recording` phase, replacing
/// `VerifyingView` + `VerifiedView`. `ProofCollectedView`'s copy
/// becomes a one-time entrance ceremony shown the
/// instant `.recording` begins, then gives way to the steady eventCard —
/// see `docs/specs/scan-slice2-redesign.md` §5.2-§5.5.
struct RecordingView: View {
  @ObservedObject var sensing: SensingCoordinator
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let event: EventSession
  let peersVerified: Int
  let onRetryVerification: () -> Void

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
    onRetryVerification: @escaping () -> Void = {},
    ceremonyDwellNanos: UInt64 = 2_000_000_000
  ) {
    self.sensing = sensing
    self.event = event
    self.peersVerified = peersVerified
    self.onRetryVerification = onRetryVerification
    self.ceremonyDwellNanos = ceremonyDwellNanos
    _showEntranceCeremony = State(initialValue: !sensing.recordingCeremonyShown)
  }

  var body: some View {
    Group {
      if showEntranceCeremony {
        // The existing one-time collection ceremony remains reachable. #637
        // owns its Flat 2b visual pass; after its real dwell this gives way
        // to frame 05's steady sensing surface.
        BeidScreen {
          VStack(spacing: DS.Space.l) {
            BeidHeroHeader(
              title: "Proof Collected",
              subtitle: "Added to your collection."
            )
            EventCardView(event: event, badge: .recording) {
              VStack(alignment: .leading, spacing: DS.Space.xs) {
                EventIdentityVerificationRow(
                  status: event.identityVerification,
                  onRetry: onRetryVerification
                )
                HStack(spacing: DS.Space.s) {
                  ProgressView()
                    .tint(DS.Color.actionPrimary)
                  Text(recordingCaption)
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Color.textSecondary)
                }
                Text(windowBuildupCaption)
                  .font(DS.Font.meta)
                  .foregroundStyle(DS.Color.textSecondary)
                Text(diagnosticCaption)
                  .font(DS.Font.meta)
                  .foregroundStyle(DS.Color.textSecondary)
              }
            }
          }
        }
      } else {
        SensingSessionSurface(
          sensing: sensing,
          event: event,
          presentation: .steady,
          diagnosticCaption: diagnosticCaption,
          onRetryVerification: onRetryVerification
        )
      }
    }
    .safeAreaInset(edge: .bottom) {
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
    .tint(DS.Color.actionPrimary)
    .onAppear {
      // beid#222: `ScanFlowView` chains the wallet-binding sheet's
      // auto-presentation to `sensing.entranceCeremonyFinished` rather than
      // directly to `bindingState`, so the ceremony and the binding prompt
      // stay sequenced (§5.5) instead of racing. Both branches below must
      // eventually mark it — the ceremony-shown branch reaches it only
      // after the real dwell completes; a `RecordingView` identity that
      // never shows the ceremony at all (`recordingCeremonyShown` already
      // `true`, e.g. after a signal-lost → resume cycle) has nothing to
      // wait for, so it marks the ceremony finished immediately.
      guard showEntranceCeremony else {
        sensing.markEntranceCeremonyFinished()
        return
      }
      sensing.markRecordingCeremonyShown()
      Task {
        try? await Task.sleep(nanoseconds: ceremonyDwellNanos)
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : DS.Motion.proofResolve) {
          showEntranceCeremony = false
        }
        sensing.markEntranceCeremonyFinished()
      }
    }
  }

  private var recordingCaption: String {
    String(
      localized: "scan.recording.caption",
      // beid#158: unlike beid#154 (which fixed the count without touching
      // English because the noun stayed accurate), "verified" itself is
      // wrong — the protocol never exposes reciprocal confirmation, so this
      // device can only claim it sensed a peer, never that the peer sensed
      // it back. The verb-level meaning change forces real re-translation of
      // all four locales rather than a re-review pass.
      defaultValue: "Recording your attendance automatically · \(peersVerified) devices sensed",
      comment: "Cumulative count of distinct nearby devices sensed at the event, each counted once however long it stayed; no fixed target. Do NOT translate this as mutual, two-way, or reciprocal confirmation: this device cannot tell whether a peer also observed it, so any such wording would overclaim."
    )
  }

  /// Plain-text window-by-window buildup (spec §3.4's fallback; the dot-row
  /// visualization is an unratified component and out of scope for this
  /// issue). Counts only windows shared has actually reported — a session
  /// that has not yet crossed an ENIN window boundary shows `0`, not a
  /// missing value, since `SessionAggregate.windowCount` is a real count of
  /// present rows, not a sparse index.
  private var windowBuildupCaption: String {
    let windowCount = Int(sensing.sessionAggregate?.windowCount ?? 0)
    return String(
      localized: "scan.recording.windowBuildup",
      defaultValue: "\(windowCount) windows recorded",
      comment: "Count of ENIN time-windows recorded for this session so far, shown as a simple running total. This is a coverage/buildup indicator, not a device or confirmation count — a window is \"recorded\" once its time interval has been observed and closed, independent of how many devices were present in it."
    )
  }

  /// Temporary diagnostic line (beid#218, DECISIONS 2026-08-20): reads
  /// `sensing.devicesVerified`/`sensing.unidentifiedRpidCount` directly,
  /// both already `@Published` on the `SensingCoordinator` this view holds
  /// — no new wiring. Not `#if DEBUG`-gated (unlike the neighboring
  /// "Simulate Signal Lost" button above): this ships to real
  /// TestFlight/production builds because a live multi-device field test
  /// needs to read these counters without a debugger attached. Not
  /// permanent product UI and does not need to survive #141's rebuild.
  private var diagnosticCaption: String {
    let identifiedCount = sensing.devicesVerified
    let unidentifiedCount = sensing.unidentifiedRpidCount
    return String(
      localized: "scan.recording.diagnosticCaption",
      defaultValue: "Diagnostics: \(identifiedCount) identified · \(unidentifiedCount) unidentified",
      comment: "Temporary diagnostic line on the Recording screen (beid#218, DECISIONS 2026-08-20) — not permanent product UI, does not need to survive #141's rebuild, but ships to real TestFlight/production builds (not #if DEBUG) because a live multi-device field test needs to read these counters without a debugger attached. \"Identified\" is SensingCoordinator.devicesVerified: distinct nearby devices whose proximity identifier (RPID) was resolved to a display ID. \"Unidentified\" is SensingCoordinator.unidentifiedRpidCount: proximity identifiers observed but not yet resolved to a display ID — radio is arriving, but the device could not be identified. A large unidentified count with a flat identified count points at an identification failure; both flat points at nothing arriving at all — opposite fixes, which is why both numbers must be visible together. Do NOT translate this as mutual, two-way, or reciprocal confirmation of any kind — neither number says anything about whether a peer observed this device back (the protocol carries no such signal, DECISIONS 2026-08-09). Same bar as this file's `scan.recording.caption` translator comment on the line above this one."
    )
  }
}

#Preview("Entrance ceremony") {
  let coordinator = AppCoordinator()
  return RecordingView(sensing: coordinator.sensingCoordinator, event: .demoSample, peersVerified: 3)
    .environmentObject(coordinator)
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
/// hero after all three phase updates — it shows the steady event card.
#Preview("Ceremony does not replay across peersVerified updates") {
  let coordinator = AppCoordinator()
  let sensing = coordinator.sensingCoordinator
  sensing.runDemoScenario(.appReviewGolden, stepDelayNanos: 0)
  return ScanFlowPreviewHarness(sensing: sensing)
    .environmentObject(coordinator)
    .task {
      await sensing.waitForDemoScenarioPreviewToSettle()
      // Grace period for the near-zero ceremony dwell timer (kicked off by
      // the first `.recording` render's `.onAppear`) to resolve before the
      // static snapshot is taken.
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
}

/// Immutable inputs for the terminal 06 surface. #655 supplies this only
/// after its stop/finalization path has actually sealed the record. The
/// RecordSigilSlot draws only a neutral ring: #653 owns the missing per-peer,
/// per-window history and its privacy decision.
struct SensingSealedSnapshot {
  let recordID: UUID?
  let event: EventSession
  let aggregate: BeidSharedKit.aggregation.SessionAggregate?
  let detectedDeviceCount: Int
  let firstSightingAt: Date?
  let sealedAt: Date?
}

/// Frame 06. Routing and the DONE action belong to #655's closure flow.
/// The neutral RecordSigilSlot is used in production and screenshot tours;
/// neither path fabricates nodes or strands from aggregate counts.
struct SensingSealedView: View {
  let snapshot: SensingSealedSnapshot

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Text(verbatim: snapshot.event.name)
            .beidTextStyle(DS.Font.Library.display46)
            .foregroundStyle(DS.Color.labelOnActionPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 220, alignment: .leading)
            .accessibilityAddTraits(.isHeader)

          Text(verbatim: sealedSubtitle)
            .beidTextStyle(DS.Font.Library.body15)
            .foregroundStyle(DS.Color.textSecondaryOnInk)
            .padding(.top, DS.Space.s)

          RecordSigilSlot(
            recordID: snapshot.recordID,
            size: DS.Size.sensingSealedSigil,
            ground: .ink
          )
          .frame(maxWidth: .infinity)
          .padding(.top, DS.Space.xl)

          Spacer(minLength: DS.Space.l)
          SensingWindowBars(
            aggregate: snapshot.aggregate,
            firstSightingAt: snapshot.firstSightingAt,
            endsSession: true
          )

          Rectangle()
            .fill(DS.Color.strokeHairlineOnInk)
            .frame(height: DS.Size.hairline)
            .padding(.top, DS.Space.l)

          metrics
            .padding(.top, DS.Space.m)

          Spacer(minLength: DS.Space.m)
          Text("Added to your collection · no action needed")
            .beidTextStyle(DS.Font.Library.labelMono9)
            .foregroundStyle(DS.Color.textSecondaryOnInk)
            .frame(maxWidth: .infinity)
        }
        .frame(minHeight: geometry.size.height, alignment: .top)
        .padding(.horizontal, DS.Space.pageMargin)
      }
    }
    .background(DS.Color.textPrimary.ignoresSafeArea())
    .accessibilityIdentifier("scan.sealed")
  }

  private var observedWindowCount: Int {
    Int(snapshot.aggregate?.windowCount ?? 0)
  }

  private var sealedSubtitle: String {
    guard let firstSightingAt = snapshot.firstSightingAt, let sealedAt = snapshot.sealedAt else {
      return "Proof sealed"
    }
    let start = firstSightingAt.formatted(date: .omitted, time: .shortened)
    let end = sealedAt.formatted(date: .omitted, time: .shortened)
    return "Proof sealed · \(start) – \(end)"
  }

  private var metrics: some View {
    let elapsed = snapshot.firstSightingAt.flatMap { start in
      snapshot.sealedAt.map { max(0, Int($0.timeIntervalSince(start))) }
    }
    var items = [
      SensingMetric(value: String(snapshot.aggregate?.mutualDeviceCount ?? 0), label: "MUTUAL"),
      SensingMetric(value: String(snapshot.detectedDeviceCount), label: "DETECTED")
    ]
    if let elapsed {
      items.append(SensingMetric(value: "\(elapsed / 60)′", label: "ELAPSED"))
    }
    return HStack(alignment: .top, spacing: 0) {
      ForEach(items) { item in
        VStack(alignment: .leading, spacing: DS.Space.xs) {
          Text(verbatim: item.value)
            .beidTextStyle(DS.Font.Library.displayNumber40)
            .foregroundStyle(DS.Color.labelOnActionPrimary)
          Text(verbatim: item.label)
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textSecondaryOnInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(snapshot.aggregate?.mutualDeviceCount ?? 0) mutual, "
        + "\(snapshot.detectedDeviceCount) detected, window \(observedWindowCount)"
    )
  }
}
