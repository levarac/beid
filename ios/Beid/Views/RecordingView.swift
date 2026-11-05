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

          RecordSigilSlot(input: sigilInput, placement: .sensingSealed)
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
          VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("DONE · YOU CAN CLOSE THE APP")
              .beidTextStyle(DS.Font.Library.labelMono10)
            Text("Your record is saved on this phone. You can close the app.")
              .beidTextStyle(DS.Font.Library.body13)
              .foregroundStyle(DS.Color.textSecondaryOnInk)
          }
          .padding(DS.Space.m)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(DS.Color.strokeHairlineOnInk, in: RoundedRectangle(cornerRadius: DS.Radius.card))
          .padding(.vertical, DS.Space.l)
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
      items.append(SensingMetric(value: "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))", label: "ELAPSED"))
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

  }
}
