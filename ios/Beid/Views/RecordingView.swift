// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import SwiftUI

/// The steady `.recording` phase. Frame 07 is reached only after a successful
/// stop and the sealed frame 06, so recording never claims collection is done.
struct RecordingView: View {
  @ObservedObject var sensing: SensingCoordinator
  let event: EventSession
  let onRetryVerification: () -> Void

  init(
    sensing: SensingCoordinator,
    event: EventSession,
    onRetryVerification: @escaping () -> Void = {}
  ) {
    self.sensing = sensing
    self.event = event
    self.onRetryVerification = onRetryVerification
  }

  var body: some View {
    SensingSessionSurface(
      sensing: sensing,
      event: event,
      presentation: .steady,
      diagnosticCaption: diagnosticCaption,
      onRetryVerification: onRetryVerification
    )
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
    .task { @MainActor in
      // Cross the first render transaction before presenting the binding
      // sheet. The old ceremony supplied this separation with a timer.
      await Task.yield()
      guard !Task.isCancelled else { return }
      sensing.markRecordingSurfaceReady()
    }
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

#Preview("Recording") {
  let coordinator = AppCoordinator()
  return RecordingView(sensing: coordinator.sensingCoordinator, event: .demoSample)
    .environmentObject(coordinator)
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
