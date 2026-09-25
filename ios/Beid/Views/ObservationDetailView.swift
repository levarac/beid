// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

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
}

/// Flat 2b 11. A selected session, not the event-wide representative Proof.
/// The native NavigationStack supplies its back control and pop gesture.
struct ObservationDetailView: View {
  let proof: Proof
  let sessionNumber: Int
  let aggregate: BeidSharedKit.aggregation.SessionAggregate?

  private var presentation: ObservationDetailPresentation? {
    ObservationDetailPresentation(aggregate: aggregate)
  }

  var body: some View {
    ScrollView {
      BeidAdaptiveContent {
        VStack(alignment: .leading, spacing: 0) {
          Text(sessionTitle)
            .beidTextStyle(DS.Font.Library.display46)
            .foregroundStyle(DS.Color.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("observation-detail.title")

          Text(verbatim: proof.date.formatted(.dateTime.month(.abbreviated).day().year()).uppercased())
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textSecondary)
            .padding(.top, DS.Space.s + DS.Space.xs)

          if let presentation {
            observedWindowsChart(presentation)
              .padding(.top, DS.Space.xl)
            sensingData(presentation)
              .padding(.top, DS.Space.xxl)
          } else {
            Text("Measurements unavailable")
              .beidTextStyle(DS.Font.Library.body13)
              .foregroundStyle(DS.Color.textSecondary)
              .padding(.top, DS.Space.xl)
              .accessibilityIdentifier("observation-detail.unavailable")
          }
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
    String(
      localized: "eventDetail.session.title",
      defaultValue: "Session \(sessionNumber)",
      comment: "Ordinal label for one stored recording session within an event, oldest first."
    )
  }

  private func observedWindowsChart(_ presentation: ObservationDetailPresentation) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("PEERS PER OBSERVED WINDOW")
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondary)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .bottom, spacing: DS.Size.observationChartBarGap) {
          ForEach(presentation.windows) { window in
            Rectangle()
              // D-627 notes the Figma chart-muted #D9D9DE is 1.41:1 on white.
              // This local blend is approximately #92929A, 3.09:1.
              .fill(DS.Color.textSecondary.opacity(0.75))
              .frame(
                width: DS.Size.observationChartBarWidth,
                height: barHeight(window.peerCount, in: presentation)
              )
              .frame(height: DS.Size.observationChartHeight, alignment: .bottom)
              .accessibilityLabel(accessibilityLabel(for: window))
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
