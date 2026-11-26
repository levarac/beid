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
  }

  private var diagnosticCaption: String? {
    #if DEBUG
    let identifiedCount = sensing.devicesVerified
    let unidentifiedCount = sensing.unidentifiedRpidCount
    return "Diagnostics: \(identifiedCount) identified · \(unidentifiedCount) unidentified"
    #else
    return nil
    #endif
  }

}

#Preview("Recording") {
  let coordinator = AppCoordinator()
  return RecordingView(sensing: coordinator.sensingCoordinator, event: .demoSample)
    .environmentObject(coordinator)
}

/// Immutable inputs for the terminal 06 surface. #655 supplies this only
/// after its stop/finalization path has actually sealed the record. The
/// Sigil itself is passed to `SensingSealedView` separately (beid#653): it is
/// read from the store the session end has just written.
struct SensingSealedSnapshot {
  let recordID: UUID?
  let event: EventSession
  let aggregate: BeidSharedKit.aggregation.SessionAggregate?
  let detectedDeviceCount: Int
  let firstSightingAt: Date?
  let sealedAt: Date?
}

/// Frame 06. Routing and the DONE action belong to #655's closure flow.
/// The Sigil is the record's stored presence (beid#653), or the neutral ring
/// when there is none (screenshot tours pass none). Neither path fabricates
/// nodes or strands from aggregate counts.
struct SensingSealedView: View {
  let snapshot: SensingSealedSnapshot
  /// This record's stored Sigil input; `nil` keeps the ring.
  var sigilInput: BeidSharedKit.sigil.SigilInput? = nil

  var body: some View {
    GeometryReader { _ in
      ScrollView {
        BeidAdaptiveContent {
          BeidLiveSessionPanel {
            VStack(alignment: .leading, spacing: 0) {
              Text(verbatim: snapshot.event.name)
                .beidTextStyle(DS.Font.Library.title19)
                .foregroundStyle(DS.Color.labelOnActionPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

              Text(verbatim: sealedSubtitle)
                .beidTextStyle(DS.Font.Library.body15)
                .foregroundStyle(DS.Color.textSecondaryOnInk)
                .padding(.top, DS.Space.s)

              RecordSigilSlot(input: sigilInput, placement: .sensingSealed, isDeviceRecord: true)
                .frame(maxWidth: .infinity)
                .padding(.top, DS.Space.xl)

              Spacer(minLength: DS.Space.l)
              SensingWindowBars(
                aggregate: snapshot.aggregate,
                endsSession: true
              )

              Rectangle()
                .fill(DS.Color.strokeHairlineOnInk)
                .frame(height: DS.Size.hairline)
                .padding(.top, DS.Space.l)

              metrics
                .padding(.top, DS.Space.m)

              Spacer(minLength: DS.Space.m)
              VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("DONE · YOU CAN CLOSE THE APP")
                  .beidTextStyle(DS.Font.Library.labelMono10)
                  .foregroundStyle(DS.Color.labelOnActionPrimary)
                Text("Your record is saved on this device. You'll find it in Records.")
                  .beidTextStyle(DS.Font.Library.body13)
                  .foregroundStyle(DS.Color.textSecondaryOnInk)
                Text("record.explainer", comment: "One-line explanation of what a Record is, shown where people first meet one.")
                  .beidTextStyle(DS.Font.Library.body13)
                  .foregroundStyle(DS.Color.textSecondaryOnInk)
                  .accessibilityIdentifier("scan.sealed.explainer")
              }
              .padding(DS.Space.m)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(DS.Color.strokeHairlineOnInk, in: RoundedRectangle(cornerRadius: DS.Radius.card))
              .padding(.vertical, DS.Space.l)
            }
          }
          .padding(.horizontal, DS.Space.pageMargin)
          .padding(.vertical, DS.Space.m)
        }
      }
    }
    .beidScreenBackground(DS.Color.surfaceCanvas)
    .accessibilityIdentifier("scan.sealed")
  }

  private var observedWindowCount: Int {
    Int(snapshot.aggregate?.windowCount ?? 0)
  }

  private var sealedSubtitle: String {
    guard let firstSightingAt = snapshot.firstSightingAt, let sealedAt = snapshot.sealedAt else {
      return "Record saved"
    }
    let start = firstSightingAt.formatted(date: .omitted, time: .shortened)
    let end = sealedAt.formatted(date: .omitted, time: .shortened)
    return "Record saved · \(start) – \(end)"
  }

  private var metrics: some View {
    let elapsed = snapshot.firstSightingAt.flatMap { start in
      snapshot.sealedAt.map { max(0, Int($0.timeIntervalSince(start))) }
    }
    var items = [
      SensingMetric(value: String(snapshot.detectedDeviceCount), label: "DEVICES HEARD")
    ]
    if let elapsed {
      items.append(SensingMetric(value: ElapsedTimeFormat.minutesSeconds(TimeInterval(elapsed)), label: "ELAPSED"))
    }
    return SensingMetricsView(items: items)

  }
}
