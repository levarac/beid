// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
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

  var shortRecordID: String { RecordIDDisplay.abbreviated(recordID) }

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
  /// This record's stored Sigil input (beid#653); `nil` keeps the ring.
  /// Kept out of the `Sendable` snapshot, which cannot hold a Kotlin object.
  var sigilInput: BeidSharedKit.sigil.SigilInput? = nil
  let onViewCollection: () -> Void
  @State private var showWhatWeSend = false

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .top, spacing: DS.Space.m) {
            Text(verbatim: "RECORD ID \(snapshot.shortRecordID)")
              // This child carries a value. Override the row's uppercase
              // label style so its VoiceOver text and future mixed-case
              // shorthand keep their exact spelling.
              .textCase(nil)
              .foregroundStyle(DS.Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityLabel(Text(verbatim: "Record ID \(snapshot.recordID.uuidString)"))
              .accessibilityIdentifier("proof-collected.record-id")
            Spacer(minLength: DS.Space.s)
            Text(verbatim: "SEALED")
              .foregroundStyle(DS.Color.textPrimary)
              .fixedSize(horizontal: true, vertical: false)
              .accessibilityIdentifier("proof-collected.status")
          }
          .beidTextStyle(DS.Font.Library.labelMono11)
          .frame(maxWidth: .infinity)

          RecordSigilSlot(input: sigilInput, placement: .proofCollected)
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

          // Figma 07 "WHAT WAS SENT →"; decided label WHAT WE SEND (#637),
          // opening 16's general disclosure (#646). Nothing is claimed sent.
          BeidTextControl(
            "What we send",
            glyph: .trailing("→", announcing: "What we send"),
            labelColor: DS.Color.textSecondary
          ) {
            showWhatWeSend = true
          }
          .accessibilityIdentifier("proof-collected.whatWeSend")
          .padding(.top, DS.Space.s)

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
    .sheet(isPresented: $showWhatWeSend) {
      NavigationStack {
        WhatWeSendView()
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              BeidTextControl("Done", accessibilityLabel: "Done") { showWhatWeSend = false }
            }
            .beidWithoutSharedBackground()
          }
      }
    }
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
