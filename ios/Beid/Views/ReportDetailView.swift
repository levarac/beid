// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import SwiftUI

/// Copy derived only from one durable canonical Observation submission.
/// SUBMITTING is persisted before POST and cannot establish delivery.
struct ReportDetailPresentation {
  let caption: String
  let delivery: String
  let receipt: String
  let showsPreparedAt: Bool

  init(record: ReportSubmissionRecord) {
    if record.isTerminal {
      caption = String(localized: "reportDetail.stopped", defaultValue: "SUBMISSION STOPPED")
      delivery = String(localized: "reportDetail.deliveryUnconfirmed", defaultValue: "DELIVERY UNCONFIRMED")
      receipt = String(localized: "reportDetail.receiptUnavailable", defaultValue: "RECEIPT UNAVAILABLE")
      showsPreparedAt = false
      return
    }

    switch record.submissionState {
    case .prepared:
      caption = String(localized: "reportDetail.prepared", defaultValue: "PREPARED ON DEVICE")
      delivery = String(localized: "reportDetail.notSent", defaultValue: "NOT SENT")
      receipt = String(localized: "reportDetail.notYetAvailable", defaultValue: "NOT YET AVAILABLE")
      showsPreparedAt = true
    case .submitting:
      caption = String(localized: "reportDetail.inProgress", defaultValue: "SUBMISSION IN PROGRESS")
      delivery = String(localized: "reportDetail.deliveryUnconfirmed", defaultValue: "DELIVERY UNCONFIRMED")
      receipt = String(localized: "reportDetail.receiptUnavailable", defaultValue: "RECEIPT UNAVAILABLE")
      showsPreparedAt = false
    case .accepted:
      if record.isReceiptStored {
        caption = String(localized: "reportDetail.operatorAccepted", defaultValue: "ACCEPTED BY OPERATOR")
        delivery = String(localized: "reportDetail.operatorAccepted", defaultValue: "ACCEPTED BY OPERATOR")
        receipt = String(localized: "reportDetail.receiptStored", defaultValue: "STORED")
      } else {
        // A state flag without a verified stored receipt is not acceptance evidence.
        caption = String(localized: "reportDetail.statusUnavailable", defaultValue: "STATUS UNAVAILABLE")
        delivery = String(localized: "reportDetail.statusUnavailable", defaultValue: "STATUS UNAVAILABLE")
        receipt = String(localized: "reportDetail.statusUnavailable", defaultValue: "STATUS UNAVAILABLE")
      }
      showsPreparedAt = false
    }
  }
}

/// Flat 2b frame 12. The selected UUID, not the possibly-changing list
/// ordinal, identifies the report. The observed store is the coordinator's
/// same instance used by Event Detail and the submission runtime.
struct ReportDetailView: View {
  @ObservedObject private var submissionStore: ReportSubmissionStore
  let recordID: UUID
  let reportIndex: Int

  init(
    recordID: UUID,
    reportIndex: Int,
    submissionStore: ReportSubmissionStore
  ) {
    self.recordID = recordID
    self.reportIndex = reportIndex
    self._submissionStore = ObservedObject(wrappedValue: submissionStore)
  }

  var body: some View {
    ScrollView {
      BeidAdaptiveContent {
        VStack(alignment: .leading, spacing: 0) {
          if let record = submissionStore.record(id: recordID) {
            reportContent(record)
          } else {
            Text("Report unavailable on this device")
              .beidTextStyle(DS.Font.Library.body13)
              .foregroundStyle(DS.Color.textSecondary)
              .accessibilityIdentifier("report-detail.unavailable")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.pageMargin)
        .padding(.top, DS.Space.s)
        .padding(.bottom, DS.Space.xl)
      }
    }
    .background(DS.Color.surfaceCanvas.ignoresSafeArea())
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func reportContent(_ record: ReportSubmissionRecord) -> some View {
    let presentation = ReportDetailPresentation(record: record)
    return VStack(alignment: .leading, spacing: 0) {
      Text(reportTitle)
        .beidTextStyle(DS.Font.Library.display46)
        .foregroundStyle(DS.Color.textPrimary)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("report-detail.heading")

      Text(caption(presentation, record: record))
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondary)
        .padding(.top, DS.Space.s + DS.Space.xs)
        .accessibilityIdentifier("report-detail.status")

      sectionHeading(
        String(localized: "reportDetail.record", defaultValue: "RECORD")
      )
      .padding(.top, DS.Space.xl)

      hairline
      keyValueRow(
        String(localized: "reportDetail.reportID", defaultValue: "REPORT ID"),
        value: RecordIDDisplay.abbreviated(record.id),
        fullAccessibilityValue: String(
          localized: "reportDetail.reportID.accessibility",
          defaultValue: "Report ID \(record.id.uuidString)",
          comment: "VoiceOver reads the full durable report UUID; the visible value is shortened."
        ),
        identifier: "report-detail.record-id"
      )
      hairline
      keyValueRow(
        String(localized: "reportDetail.recorded", defaultValue: "RECORDED ON DEVICE"),
        value: String(localized: "reportDetail.oneObservation", defaultValue: "1 OBSERVATION")
      )
      hairline
      keyValueRow(
        String(localized: "reportDetail.mutual", defaultValue: "MUTUAL OBSERVATION"),
        value: notYetAvailable,
        unavailable: true
      )
      hairline
      keyValueRow(
        String(localized: "reportDetail.sent", defaultValue: "SENT"),
        value: presentation.delivery,
        identifier: "report-detail.delivery"
      )
      hairline
      keyValueRow(
        String(localized: "reportDetail.acceptanceReceipt", defaultValue: "ACCEPTANCE RECEIPT"),
        value: presentation.receipt,
        unavailable: !record.isReceiptStored,
        identifier: "report-detail.receipt"
      )
      hairline
      keyValueRow(
        String(localized: "reportDetail.published", defaultValue: "PUBLISHED"),
        value: notYetAvailable,
        unavailable: true
      )
      hairline

      HStack(alignment: .firstTextBaseline) {
        sectionHeading(
          String(localized: "reportDetail.observations", defaultValue: "OBSERVATIONS INCLUDED")
        )
        Spacer(minLength: DS.Space.s)
        // Figma 12: WHAT WE SEND → opens 16, the general disclosure (#646).
        NavigationLink {
          WhatWeSendView()
            .toolbar(.visible, for: .navigationBar)
        } label: {
          BeidTextControlLabel("What we send", glyph: .trailing("→", announcing: "What we send"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("report-detail.whatWeSend")
      }
      .padding(.top, DS.Space.l)
      hairline
      HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
        Text("1 signed observation")
          .beidTextStyle(DS.Font.Library.title15)
          .foregroundStyle(DS.Color.textPrimary)
        Spacer(minLength: DS.Space.s)
        Text(shortDigest(record.observationDigestHex))
          .beidTextStyle(DS.Font.Library.labelMono11Time)
          .foregroundStyle(DS.Color.textSecondary)
          .accessibilityLabel(String(
            localized: "reportDetail.observationDigest.accessibility",
            defaultValue: "Observation digest \(record.observationDigestHex)",
            comment: "VoiceOver reads the full digest of the selected signed Observation."
          ))
      }
      .frame(minHeight: DS.Size.reportRowMinHeight)
      hairline
    }
  }

  private var reportTitle: String {
    String(
      localized: "eventDetail.report.title",
      defaultValue: "Report #\(reportIndex)",
      comment: "Ordinal label for a stored canonical Observation submission record, oldest first."
    )
  }

  private var notYetAvailable: String {
    String(localized: "reportDetail.notYetAvailable", defaultValue: "NOT YET AVAILABLE")
  }

  private func caption(_ presentation: ReportDetailPresentation, record: ReportSubmissionRecord) -> String {
    guard presentation.showsPreparedAt else { return presentation.caption }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "MMM d, HH:mm"
    let preparedAt = formatter.string(from: record.createdAt).uppercased()
    return String(
      localized: "reportDetail.preparedAt",
      defaultValue: "PREPARED ON DEVICE · \(preparedAt)",
      comment: "Preparation time on this device, not a network send or operator acceptance time."
    )
  }

  private func sectionHeading(_ value: String) -> some View {
    Text(verbatim: value)
      .beidTextStyle(DS.Font.Library.labelMono10)
      .foregroundStyle(DS.Color.textSecondary)
      .frame(minHeight: DS.Space.l, alignment: .topLeading)
  }

  private func keyValueRow(
    _ label: String,
    value: String,
    fullAccessibilityValue: String? = nil,
    unavailable: Bool = false,
    identifier: String? = nil
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
      Text(verbatim: label)
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondary)
      Spacer(minLength: DS.Space.s)
      Text(verbatim: value)
        .beidTextStyle(DS.Font.Library.labelMono11Time)
        .foregroundStyle(unavailable ? DS.Color.textSecondary : DS.Color.textPrimary)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(fullAccessibilityValue ?? value)
    }
    .frame(minHeight: DS.Size.minHitTarget)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier ?? "report-detail.row.\(label)")
  }

  private var hairline: some View {
    Rectangle()
      .fill(DS.Color.strokeHairline)
      .frame(height: 1)
      .accessibilityHidden(true)
  }

  private func shortDigest(_ digest: String) -> String {
    guard digest.count > 8 else { return digest }
    return "\(digest.prefix(4))…\(digest.suffix(4))"
  }
}
