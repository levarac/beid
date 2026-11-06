// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import SwiftUI

/// One observed ENIN row. A gap means that no observation was recorded in
/// intervening windows; it is never a measured zero.
struct ObservationDetailWindow: Identifiable, Equatable {
  let windowIndex: Int64
  let peerCount: Int
  let ordinal: Int
  let gapBefore: Int64

  var id: Int64 { windowIndex }
}

/// Screen 11 reads one finished Proof's immutable shared aggregate snapshot.
/// Device count is the number of distinct display IDs observed across that
/// session; per-window peer counts use the rotating window-scoped peer key.
struct ObservationDetailPresentation {
  let deviceCount: Int
  let windowCount: Int
  let windows: [ObservationDetailWindow]

  init?(aggregate: BeidSharedKit.aggregation.SessionAggregate?) {
    guard let aggregate else { return nil }
    deviceCount = Int(aggregate.deviceCount)
    windowCount = Int(aggregate.windowCount)

    var rows: [ObservationDetailWindow] = []
    var previousIndex: Int64?
    for position in 0..<windowCount {
      guard let row = aggregate.windowAt(index: Int32(position)) else { continue }
      let gap = previousIndex.map { max(0, row.windowIndex - $0 - 1) } ?? 0
      rows.append(ObservationDetailWindow(
        windowIndex: row.windowIndex,
        peerCount: Int(row.peerCount),
        ordinal: position + 1,
        gapBefore: gap
      ))
      previousIndex = row.windowIndex
    }
    windows = rows
  }

  /// Both immutable inputs belong to the same saved session. Their writers
  /// rank the same sorted distinct observed windows; count equality is only
  /// a consistency check, since stored Sigil text contains no ENIN list.
  func selectedSigilInput(
    storedInput: BeidSharedKit.sigil.SigilInput?,
    storedProofID: UUID,
    selectedProofID: UUID,
    throughWindowIndex: Int64
  ) -> BeidSharedKit.sigil.SigilInput? {
    guard storedProofID == selectedProofID, let storedInput,
          windowCount > 0, windows.count == windowCount,
          Int(storedInput.windowCount) == windowCount,
          zip(windows, windows.dropFirst()).allSatisfy({ $0.0.windowIndex < $0.1.windowIndex }),
          let rank = windows.firstIndex(where: { $0.windowIndex == throughWindowIndex })
    else { return nil }
    return BeidSharedKit.sigil.sigilInputPrefixOrNull(
      input: storedInput, observedWindowCount: Int32(rank + 1)
    )
  }
}

/// Flat 2b 11. A selected session, not the event-wide representative Proof.
/// The native NavigationStack supplies its back control and pop gesture.
struct ObservationDetailView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  let proof: Proof
  let sessionNumber: Int
  let aggregate: BeidSharedKit.aggregation.SessionAggregate?
  var initialWindowIndex: Int64? = nil
  var initialReportID: UUID? = nil
  @State private var selectedWindowIndex: Int64? = nil

  private var selectedWindow: ObservationDetailWindow? {
    guard let presentation else { return nil }
    let index = selectedWindowIndex ?? initialWindowIndex ?? presentation.windows.last?.windowIndex
    return presentation.windows.first { $0.windowIndex == index }
  }

  private var presentation: ObservationDetailPresentation? {
    ObservationDetailPresentation(aggregate: aggregate)
  }

  var body: some View {
    ScrollView {
      BeidAdaptiveContent {
        VStack(alignment: .leading, spacing: 0) {
          Text(proof.date.formatted(date: .omitted, time: .shortened))
            .beidTextStyle(DS.Font.Library.display46)
            .foregroundStyle(DS.Color.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("observation-detail.title")

          Text(verbatim: "\(sessionTitle) · \(proof.date.formatted(.dateTime.month(.abbreviated).day().year()))")
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textSecondary)
            .padding(.top, DS.Space.s + DS.Space.xs)

          if let presentation {
            observedWindowsChart(presentation)
              .padding(.top, DS.Space.xl)
            if let selectedWindow {
              selectedWindowContent(selectedWindow, presentation: presentation)
                .padding(.top, DS.Space.l)
            }
            sensingData(presentation)
              .padding(.top, DS.Space.xxl)
            timeBands
              .padding(.top, DS.Space.l)
          } else {
            Text("Measurements unavailable")
              .beidTextStyle(DS.Font.Library.body13)
              .foregroundStyle(DS.Color.textSecondary)
              .padding(.top, DS.Space.xl)
              .accessibilityIdentifier("observation-detail.unavailable")
          }

          SessionWindowReports(
            proof: proof, windowIndex: selectedWindow?.windowIndex,
            observedIndices: Set(presentation?.windows.map(\.windowIndex) ?? []),
            selectedReportID: initialReportID,
            submissionStore: coordinator.reportSubmissionStore, proofStore: coordinator.proofStore,
            linkStore: coordinator.reportProofLinkStore, sensing: coordinator.sensingCoordinator
          )
          .padding(.top, DS.Space.l)
          NavigationLink { ItemDetailView(proof: proof) } label: {
            BeidTextControlLabel("VIEW THIS SESSION'S RECORD", glyph: .trailing("→", announcing: "View this session's record"))
          }
          .buttonStyle(.plain)
          .padding(.top, DS.Space.l)
        }
        .padding(.horizontal, DS.Space.pageMargin)
        .padding(.top, DS.Space.s)
        .padding(.bottom, DS.Space.xl)
      }
    }
    .background(DS.Color.surfaceCanvas)
    .navigationTitle(proof.eventName)
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("observation-detail")
  }

  private var sessionTitle: String {
    SessionDisplay.title(sessionNumber)
  }

  private func observedWindowsChart(_ presentation: ObservationDetailPresentation) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("PEERS PER OBSERVED WINDOW")
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondary)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .bottom, spacing: DS.Size.observationChartBarGap) {
          ForEach(presentation.windows) { window in
            Button {
              selectedWindowIndex = window.windowIndex
            } label: {
              Rectangle()
                .fill(selectedWindow?.windowIndex == window.windowIndex ? DS.Color.textPrimary : DS.Color.textSecondary.opacity(0.75))
                .frame(width: DS.Size.observationChartBarWidth, height: barHeight(window.peerCount, in: presentation))
                .frame(height: DS.Size.observationChartHeight, alignment: .bottom)
                .frame(minWidth: DS.Size.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(for: window))
            .accessibilityAddTraits(selectedWindow?.windowIndex == window.windowIndex ? .isSelected : [])
          }
        }
        .frame(minHeight: DS.Size.observationChartHeight, alignment: .bottom)
      }
      .frame(maxWidth: DS.Size.observationChartWidth)
      .padding(.top, DS.Space.s)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("observation-detail.chart")
    }
  }

  private func selectedWindowContent(
    _ window: ObservationDetailWindow,
    presentation: ObservationDetailPresentation
  ) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.m) {
      Text(String(localized: "record.selectedWindow", defaultValue: "WINDOW \(window.ordinal)"))
        .beidTextStyle(DS.Font.Library.labelMono10)
      if let input = presentation.selectedSigilInput(
        storedInput: coordinator.sensingCoordinator.sigilInput(forProofId: proof.id),
        storedProofID: proof.id, selectedProofID: proof.id, throughWindowIndex: window.windowIndex
      ) {
        RecordSigilSlot(input: input, placement: .proofDetail)
          .frame(maxWidth: .infinity)
      } else {
        Text("Artwork is not available for this window.")
          .beidTextStyle(DS.Font.Library.body13)
          .foregroundStyle(DS.Color.textSecondary)
      }
      metricRow("PEERS IN THIS WINDOW", value: window.peerCount)
      unavailableRow("WINDOW DURATION")
      unavailableRow("AVG SIGNAL")
    }
  }

  private var timeBands: some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
      Text("Time-band buildup").beidTextStyle(DS.Font.Library.labelMono10)
      if let aggregate {
        if aggregate.bandCount == 0 {
          Text("No time bands recorded for this session").beidTextStyle(DS.Font.Library.body13)
        }
        ForEach(0..<Int(aggregate.bandCount), id: \.self) { index in
          if let band = aggregate.bandAt(index: Int32(index)) {
            Text(String(
              localized: "participationSummary.bandBuildup.row",
              defaultValue: "Band \(Int(band.bandIndex)): \(Int(band.deviceCount)) devices sensed"
            ))
            .beidTextStyle(DS.Font.Library.body13)
          }
        }
      }
    }
  }

  private func unavailableRow(_ label: LocalizedStringKey) -> some View {
    HStack {
      Text(label).beidTextStyle(DS.Font.Library.labelMono10)
      Spacer(minLength: DS.Space.s)
      Text("NOT YET AVAILABLE").beidTextStyle(DS.Font.Library.labelMono10)
    }
    .foregroundStyle(DS.Color.textSecondary)
    .frame(minHeight: DS.Size.keyValueRowMinHeight)
  }

  private func barHeight(
    _ peerCount: Int,
    in presentation: ObservationDetailPresentation
  ) -> CGFloat {
    let maximum = max(1, presentation.windows.map(\.peerCount).max() ?? 0)
    return CGFloat(peerCount) / CGFloat(maximum) * DS.Size.observationChartMaxBarHeight
  }

  private func accessibilityLabel(for window: ObservationDetailWindow) -> String {
    if window.gapBefore > 0 {
      return String(
        localized: "observationDetail.chart.windowAfterGap",
        defaultValue: "Observed window \(window.ordinal); peer count \(window.peerCount); preceding unobserved window count \(window.gapBefore)",
        comment: "VoiceOver description for a chart bar after a gap in the saved ENIN window indices. The gap means no observation was recorded, not zero peers measured."
      )
    }
    return String(
      localized: "observationDetail.chart.window",
      defaultValue: "Observed window \(window.ordinal); peer count \(window.peerCount)",
      comment: "VoiceOver description for one saved observation window. Peer count is distinct within this window, not an event-wide total or mutual confirmation."
    )
  }

  private func sensingData(_ presentation: ObservationDetailPresentation) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("SENSING DATA")
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondary)
        .padding(.bottom, DS.Space.s + DS.Space.xs)
      metricRow("PEERS OBSERVED", value: presentation.deviceCount)
        .accessibilityIdentifier("observation-detail.peers")
      metricRow("WINDOWS", value: presentation.windowCount)
        .accessibilityIdentifier("observation-detail.windows")
    }
  }

  private func metricRow(_ label: LocalizedStringKey, value: Int) -> some View {
    HStack {
      Text(label)
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondary)
      Spacer(minLength: DS.Space.s)
      Text(verbatim: String(value))
        .beidTextStyle(DS.Font.Library.title15)
        .foregroundStyle(DS.Color.textPrimary)
    }
    .frame(minHeight: DS.Size.keyValueRowMinHeight)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(DS.Color.strokeHairline)
        .frame(height: DS.Size.hairline)
    }
  }
}

/// Unknown ENIN metadata stays in a report-only route, never a guessed bar.
private struct SessionWindowReports: View {
  let proof: Proof
  let windowIndex: Int64?
  let observedIndices: Set<Int64>
  let selectedReportID: UUID?
  @ObservedObject var submissionStore: ReportSubmissionStore
  @ObservedObject var proofStore: ProofStore
  @ObservedObject var linkStore: ReportProofLinkStore
  @ObservedObject var sensing: SensingCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
      switch ReportProofLinkPresentation.readReports(
        for: proof, submissionStore: submissionStore, linkStore: linkStore, proofStore: proofStore
      ) {
      case .failure:
        Text("Reports unavailable on this device").beidTextStyle(DS.Font.Library.body13)
      case .success(let reports):
        if let windowIndex {
          Text("REPORTS FOR SELECTED WINDOW").beidTextStyle(DS.Font.Library.labelMono10)
          let selected = WindowReportSelection.reports(reports, at: windowIndex) {
            sensing.observedWindowIndex(forWindowID: $0)
          }
          if selected.isEmpty {
            Text("Report information is not available for this window.").beidTextStyle(DS.Font.Library.body13)
          }
          ForEach(selected, id: \.record.id) { report in
            ReportEvidenceSection(record: report.record, ordinal: report.ordinal, selected: selectedReportID == report.record.id)
          }
        }
        let unknown = reports.filter {
          guard let index = sensing.observedWindowIndex(forWindowID: $0.record.id) else { return true }
          return !observedIndices.contains(index)
        }
        if !unknown.isEmpty {
          Text("OTHER STORED REPORTS").beidTextStyle(DS.Font.Library.labelMono10)
          Text("The observation window is unavailable for these reports.").beidTextStyle(DS.Font.Library.body13)
          ForEach(unknown, id: \.record.id) { report in
            EventReportRow(
              ordinal: report.ordinal, record: report.record,
              identifier: "observation-detail.report.\(report.record.id.uuidString)",
              submissionStore: submissionStore, proofStore: proofStore, linkStore: linkStore, sensing: sensing
            )
          }
        }
      }
    }
  }
}
