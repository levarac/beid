// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

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

/// Receipt progress over an explicitly scoped set, never the event's best state.
struct ReportProgressPresentation {
  let receivedCount: Int
  let summary: String

  init(records: [ReportSubmissionRecord]) {
    receivedCount = records.filter { !$0.isTerminal && $0.submissionState == .accepted && $0.isReceiptStored }.count
    if records.isEmpty {
      summary = String(localized: "NO LINKED REPORTS")
    } else if records.count == 1, let record = records.first {
      summary = ReportDetailPresentation(record: record).caption
    } else {
      summary = String(
        localized: "record.receivedProgress",
        defaultValue: "\(receivedCount) OF \(records.count) RECEIVED"
      )
    }
  }
}

/// The selected report's stored evidence, shared by Session and old routes.
struct ReportEvidenceSection: View {
  let record: ReportSubmissionRecord
  let ordinal: Int
  var selected = false
  var identifierPrefix = "session-report"
  var showsHeader = true
  var showsDisclosure = true

  private var presentation: ReportDetailPresentation { ReportDetailPresentation(record: record) }
  private var received: Bool {
    !record.isTerminal && record.submissionState == .accepted && record.isReceiptStored
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s) {
      if showsHeader {
        Text(String(localized: "eventDetail.report.title", defaultValue: "Report #\(ordinal)"))
          .beidTextStyle(DS.Font.Library.title15)
        Text(verbatim: presentation.caption)
          .beidTextStyle(DS.Font.Library.labelMono10)
      }
      evidenceRow("REPORT ID", value: record.id.uuidString, identifier: "\(identifierPrefix).record-id")
      evidenceRow(
        received ? "SENT TO" : "DESTINATION",
        value: submissionOperatorOrigin(record.endpoint) ?? String(localized: "NOT YET AVAILABLE")
      )
      evidenceRow("DELIVERY", value: presentation.delivery, identifier: "\(identifierPrefix).delivery")
      evidenceRow("DELIVERY TIME", value: String(localized: "NOT YET AVAILABLE"))
      evidenceRow("ACCEPTANCE RECEIPT", value: presentation.receipt, identifier: "\(identifierPrefix).receipt")
      evidenceRow("RECEIPT TIME", value: String(localized: "NOT YET AVAILABLE"))
      if presentation.showsPreparedAt {
        evidenceRow("PREPARED ON DEVICE", value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
      }
      evidenceRow("OBSERVATION DIGEST", value: record.observationDigestHex)
      evidenceRow("MUTUAL OBSERVATION", value: String(localized: "NOT YET AVAILABLE"))
      evidenceRow("INCLUDED IN PUBLISHED DATA", value: String(localized: "NOT YET AVAILABLE"))
      if showsDisclosure {
        NavigationLink { WhatWeSendView() } label: {
          BeidTextControlLabel("WHAT WAS SENT", glyph: .trailing("→", announcing: "WHAT WAS SENT"))
        }
        .buttonStyle(.plain)
      }
    }
    .foregroundStyle(DS.Color.textPrimary)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("session.report.\(record.id.uuidString)")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .padding(.vertical, DS.Space.m)
  }

  private func evidenceRow(_ label: LocalizedStringKey, value: String, identifier: String = "") -> some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      Text(label).beidTextStyle(DS.Font.Library.labelMono10).foregroundStyle(DS.Color.textSecondary)
      Text(verbatim: value).beidTextStyle(DS.Font.Library.body13).textSelection(.enabled)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier)
  }
}

/// Report-only fallback when no authoritative observed window is available.
/// The selected UUID, not the possibly-changing list
/// ordinal, identifies the report. The observed store is the coordinator's
/// same instance used by Event Detail and the submission runtime. The
/// session and proof rows appear only for a linked report (beid#701); an
/// unlinked report shows exactly the pre-#701 screen.
struct ReportDetailView: View {
  @ObservedObject private var submissionStore: ReportSubmissionStore
  @ObservedObject private var proofStore: ProofStore
  @ObservedObject private var linkStore: ReportProofLinkStore
  @ObservedObject private var sensing: SensingCoordinator
  let recordID: UUID
  let reportIndex: Int

  init(
    recordID: UUID,
    reportIndex: Int,
    submissionStore: ReportSubmissionStore,
    proofStore: ProofStore,
    linkStore: ReportProofLinkStore,
    sensing: SensingCoordinator
  ) {
    self.recordID = recordID
    self.reportIndex = reportIndex
    self._submissionStore = ObservedObject(wrappedValue: submissionStore)
    self._proofStore = ObservedObject(wrappedValue: proofStore)
    self._linkStore = ObservedObject(wrappedValue: linkStore)
    self._sensing = ObservedObject(wrappedValue: sensing)
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
    let session = ReportProofLinkPresentation.session(
      for: record, linkStore: linkStore, proofStore: proofStore,
      hasSelfProof: { sensing.selfProofRecord(forProofId: $0) != nil }
    )
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

      ReportEvidenceSection(
        record: record, ordinal: reportIndex, identifierPrefix: "report-detail",
        showsHeader: false, showsDisclosure: false
      )
      .padding(.top, DS.Space.l)

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
          BeidTextControlLabel("WHAT WAS SENT", glyph: .trailing("→", announcing: "WHAT WAS SENT"))
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

      if let session {
        sessionRow(session)
        hairline

        sectionHeading(
          String(
            localized: "reportDetail.sessionProof",
            defaultValue: "SESSION RECORD",
            comment: "Section for the one stored Proof of the recording session this report was closed in. Not a verification or earned-reward claim."
          )
        )
        .padding(.top, DS.Space.l)
        hairline
        sessionProofRow(session)
        hairline
      }
    }
  }

  /// Not a link: 11 already opens this screen, so linking back would make an
  /// unbounded push cycle. The session stays reachable from Event Detail.
  private func sessionRow(_ session: LinkedSession) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
      HStack(alignment: .firstTextBaseline) {
        Text(SessionDisplay.title(session.ordinal))
          .beidTextStyle(DS.Font.Library.title15)
          .foregroundStyle(DS.Color.textPrimary)
        Spacer(minLength: DS.Space.s)
        Text(session.proof.date.formatted(date: .omitted, time: .shortened))
          .beidTextStyle(DS.Font.Library.labelMono11Time)
          .foregroundStyle(DS.Color.textPrimary)
      }
      // Omitted, not "unavailable", when no aggregate snapshot was persisted.
      if let aggregate = sensing.sessionAggregateSnapshot(forProofId: session.proof.id) {
        Text(SessionDisplay.measurements(aggregate))
          .beidTextStyle(DS.Font.Library.labelMono10Tight)
          .foregroundStyle(DS.Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, minHeight: DS.Size.sessionRowMinHeight, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("report-detail.session")
  }

  private func sessionProofRow(_ session: LinkedSession) -> some View {
    NavigationLink {
      ItemDetailView(proof: session.proof)
    } label: {
      HStack(spacing: DS.Space.m) {
        RecordSigilSlot(
          input: sensing.sigilInput(forProofId: session.proof.id),
          placement: .reportDetailRow,
          isDeviceRecord: true
        )
        VStack(alignment: .leading, spacing: DS.Space.xs) {
          Text(SessionDisplay.proofTitle(session.ordinal))
            .beidTextStyle(DS.Font.Library.title15)
            .foregroundStyle(DS.Color.textPrimary)
          Text(session.proofSubtitle)
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textSecondary)
        }
        Spacer(minLength: 0)
        Text("→")
          .beidTextStyle(DS.Font.Library.labelMono11Time)
          .foregroundStyle(DS.Color.textPrimary)
          .accessibilityHidden(true)
      }
      .frame(minHeight: DS.Size.proofRowMinHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(sessionProofAccessibilityLabel(session))
    .accessibilityIdentifier("report-detail.session-proof")
  }

  private func sessionProofAccessibilityLabel(_ session: LinkedSession) -> String {
    let title = SessionDisplay.proofTitle(session.ordinal)
    let state = session.proofState
    return String(
      localized: "reportDetail.sessionProof.accessibilityLabel",
      defaultValue: "Open \(title), \(state)",
      comment: "VoiceOver label for the Report Detail proof row. The first value is the visible proof title; the state comes only from a matching self-proof signature record."
    )
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
