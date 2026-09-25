// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import SwiftUI

/// Display data for frame 07. Production builds this from the stored Proof
/// after finalization; screenshot tours use only in-memory display values.
struct ProofCollectedSnapshot: Sendable {
  let recordID: UUID
  let eventName: String
  let date: Date
  let detectedPeerCount: Int
  let observedWindowCount: Int?

  init(proof: Proof, detectedPeerCount: Int, observedWindowCount: Int?) {
    recordID = proof.id
    eventName = proof.eventName
    date = proof.date
    self.detectedPeerCount = detectedPeerCount
    self.observedWindowCount = observedWindowCount
  }

  #if DEBUG
  static let screenshotFixture = ProofCollectedSnapshot(
    recordID: UUID(uuidString: "42110000-0000-4000-8000-000000000000")!,
    eventName: "ETH Tokyo 2026",
    date: Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 26))!,
    detectedPeerCount: 15,
    observedWindowCount: 6
  )

  private init(
    recordID: UUID,
    eventName: String,
    date: Date,
    detectedPeerCount: Int,
    observedWindowCount: Int?
  ) {
    self.recordID = recordID
    self.eventName = eventName
    self.date = date
    self.detectedPeerCount = detectedPeerCount
    self.observedWindowCount = observedWindowCount
  }
  #endif

  var shortRecordID: String { String(recordID.uuidString.prefix(8)) }

  var withValue: String {
    let peers = "\(detectedPeerCount) \(detectedPeerCount == 1 ? "peer" : "peers")"
    guard let observedWindowCount else { return peers }
    let windows = "\(observedWindowCount) \(observedWindowCount == 1 ? "window" : "windows")"
    return "\(peers) · \(windows)"
  }
}

/// Persistent frame 07. The only action returns to Collection Home.
struct ProofCollectedView: View {
  let snapshot: ProofCollectedSnapshot
  let onViewCollection: () -> Void

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .top, spacing: DS.Space.m) {
            Text(verbatim: "RECORD ID \(snapshot.shortRecordID)")
              .beidTextStyle(DS.Font.Library.labelMono11)
              .foregroundStyle(DS.Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityLabel("Record ID \(snapshot.recordID.uuidString)")
              .accessibilityIdentifier("proof-collected.record-id")
            Spacer(minLength: DS.Space.s)
            Text(verbatim: "SEALED")
              .beidTextStyle(DS.Font.Library.labelMono11)
              .foregroundStyle(DS.Color.textPrimary)
              .fixedSize(horizontal: true, vertical: false)
              .accessibilityIdentifier("proof-collected.status")
          }
          .frame(maxWidth: .infinity)

          RecordSigilSlot(recordID: snapshot.recordID, size: 290, ground: .canvas)
            .frame(maxWidth: .infinity)
            .padding(.top, DS.Space.m)

          Text("Proof\ncollected")
            .beidTextStyle(DS.Font.Library.display46)
            .foregroundStyle(DS.Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, DS.Space.l)

          VStack(spacing: 0) {
            keyValueRow("EVENT", value: snapshot.eventName)
            keyValueRow("DATE", value: snapshot.date.formatted(.dateTime.month(.abbreviated).day().year()))
            keyValueRow("WITH", value: snapshot.withValue)
          }
          .padding(.top, DS.Space.l)

          Spacer(minLength: DS.Space.l)

          BeidPrimaryButton("View collection", action: onViewCollection)
            .tint(DS.Color.actionPrimary)
            .padding(.bottom, DS.Space.m)
        }
        .frame(maxWidth: DS.Layout.stateContentMaxWidth)
        .frame(maxWidth: .infinity)
        .frame(minHeight: geometry.size.height, alignment: .top)
        .padding(.horizontal, DS.Space.pageMargin)
      }
    }
    .background(DS.Color.surfaceCanvas.ignoresSafeArea())
    .accessibilityIdentifier("scan.proof-collected")
  }

  private func keyValueRow(_ label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
      Text(verbatim: label)
        .beidTextStyle(DS.Font.Library.labelMono11)
        .foregroundStyle(DS.Color.textSecondary)
      Spacer(minLength: DS.Space.s)
      Text(verbatim: value)
        .beidTextStyle(DS.Font.Library.title15)
        .foregroundStyle(DS.Color.textPrimary)
        .multilineTextAlignment(.trailing)
    }
    .frame(minHeight: DS.Size.keyValueRowMinHeight)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(DS.Color.strokeHairline)
        .frame(height: DS.Size.hairline)
    }
  }
}
