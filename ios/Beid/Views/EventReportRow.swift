// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import SwiftUI

/// Session and proof copy shared by screens 08, 11 and 12, so one session
/// reads the same everywhere it appears.
enum SessionDisplay {
  static func title(_ ordinal: Int) -> String {
    String(
      localized: "eventDetail.session.title",
      defaultValue: "Session \(ordinal)",
      comment: "Ordinal label for one stored recording session within an event, oldest first."
    )
  }

  static func measurements(_ aggregate: BeidSharedKit.aggregation.SessionAggregate) -> String {
    let devices = Int(aggregate.deviceCount)
    let windows = Int(aggregate.windowCount)
    return String(
      localized: "eventDetail.session.measurements",
      defaultValue: "\(devices) devices · \(windows) windows",
      comment: "Session's independently pluralized sensed-device and observation-window counts, read only from its persisted aggregate snapshot."
    )
  }

  static func proofTitle(_ ordinal: Int) -> String {
    String(
      localized: "eventDetail.proof.title",
      defaultValue: "Session \(ordinal) proof",
      comment: "Opens the existing detail for the stored Proof collected in this numbered recording session."
    )
  }

  /// The only proof-row state. `SEALED` needs a `SelfProofRecord` for that
  /// exact Proof; nothing on the device is verified, so neither `VERIFIED`
  /// nor a mutual claim can come from here.
  static func proofState(hasSelfProof: Bool) -> String {
    if hasSelfProof {
      return String(
        localized: "eventDetail.proof.state.sealed",
        defaultValue: "SEALED",
        comment: "Proof row state when a self-proof signature record exists for this exact stored Proof."
      )
    }
    return String(
      localized: "eventDetail.proof.state.recorded",
      defaultValue: "RECORDED ON DEVICE",
      comment: "Proof row state when no self-proof signature record exists for this exact stored Proof."
    )
  }
}

/// One report of an event, numbered by its position in Event Detail's
/// event-wide report list.
struct LinkedReport: Equatable {
  let ordinal: Int
  let record: ReportSubmissionRecord
}

/// The session a report was closed in, for frame 12.
struct LinkedSession: Equatable {
  let proof: Proof
  let ordinal: Int
  let proofState: String

  var proofSubtitle: String {
    let recordID = RecordIDDisplay.abbreviated(proof.id)
    return String(
      localized: "reportDetail.sessionProof.subtitle",
      defaultValue: "\(proofState) · \(recordID)",
      comment: "Report Detail proof row: the same local proof state Event Detail shows, then the shortened Proof record ID. No verification or mutual claim."
    )
  }
}

/// beid#701's single display decision. Link content exists only when a
/// stored link row names a Proof that is in `ProofStore` under the same
/// normalized event code; an unreadable table, a missing Proof or another
/// event is unlinked, never a guess.
@MainActor
enum ReportProofLinkPresentation {
  static func session(
    for record: ReportSubmissionRecord,
    linkStore: ReportProofLinkStore,
    proofStore: ProofStore,
    hasSelfProof: (UUID) -> Bool
  ) -> LinkedSession? {
    guard case .success(let proofId?) = linkStore.proofId(forWindowId: record.id),
          let proof = proofStore.proof(withId: proofId),
          EventGrouping.sameEvent(proof.eventCode, record.eventCode),
          let ordinal = EventGrouping.sessionOrdinal(of: proof, in: proofStore.proofs)
    else { return nil }
    return LinkedSession(
      proof: proof,
      ordinal: ordinal,
      proofState: SessionDisplay.proofState(hasSelfProof: hasSelfProof(proof.id))
    )
  }

  /// In Event Detail's report order, keeping its event-wide ordinals.
  static func reports(
    for proof: Proof,
    submissionStore: ReportSubmissionStore,
    linkStore: ReportProofLinkStore,
    proofStore: ProofStore
  ) -> [LinkedReport] {
    guard proofStore.proof(withId: proof.id) != nil,
          let eventCode = proof.eventCode,
          case .success(let records) = submissionStore.eventRecords(forEventCode: eventCode),
          case .success(let windowIds) = linkStore.windowIds(forProofId: proof.id),
          !windowIds.isEmpty
    else { return [] }
    return records.enumerated().compactMap { offset, record in
      guard windowIds.contains(record.id),
            EventGrouping.sameEvent(proof.eventCode, record.eventCode)
      else { return nil }
      return LinkedReport(ordinal: offset + 1, record: record)
    }
  }
}

/// The Event Detail report row. 09 and 11 reuse it unchanged (beid#701
/// OD-8 (a)), so one report reads identically on all three screens.
struct EventReportRow: View {
  let ordinal: Int
  let record: ReportSubmissionRecord
  let identifier: String
  let submissionStore: ReportSubmissionStore
  let proofStore: ProofStore
  let linkStore: ReportProofLinkStore
  let sensing: SensingCoordinator

  var body: some View {
    NavigationLink {
      ReportDetailView(
        recordID: record.id, reportIndex: ordinal, submissionStore: submissionStore,
        proofStore: proofStore, linkStore: linkStore, sensing: sensing
      )
      .toolbar(.visible, for: .navigationBar)
    } label: {
      VStack(alignment: .leading, spacing: DS.Space.xs) {
        HStack {
          Text(reportTitle)
            .beidTextStyle(DS.Font.Library.title15)
            .foregroundStyle(DS.Color.textPrimary)
          Spacer(minLength: DS.Space.s)
          Text(reportStatus)
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textPrimary)
        }
        Text(reportMetadata)
          .beidTextStyle(DS.Font.Library.labelMono10Tight)
          .foregroundStyle(DS.Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, minHeight: DS.Size.reportRowMinHeight, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }

  private var reportTitle: String {
    String(
      localized: "eventDetail.report.title",
      defaultValue: "Report #\(ordinal)",
      comment: "Ordinal label for a stored canonical Observation submission record, oldest first."
    )
  }

  private var reportStatus: String {
    if record.isTerminal { return String(localized: "Stopped") }
    switch record.submissionState {
    case .prepared: return String(localized: "Prepared")
    case .submitting: return String(localized: "Submitting")
    case .accepted:
      return record.acceptanceReceiptHex == nil
        ? String(localized: "Status unavailable") : String(localized: "Receipt stored")
    }
  }

  private var reportMetadata: String {
    let digest = shortDigest(record.observationDigestHex)
    if record.isTerminal {
      return String(
        localized: "eventDetail.report.stoppedMetadata",
        defaultValue: "\(digest) · Submission stopped",
        comment: "Stored report digest followed by a terminal local submission state; no rejection or operator verdict is implied."
      )
    }
    switch record.submissionState {
    case .prepared:
      return String(
        localized: "eventDetail.report.preparedMetadata",
        defaultValue: "\(digest) · On device · not sent",
        comment: "Stored report digest followed by the PREPARED local submission state; no network send has started."
      )
    case .submitting:
      return String(
        localized: "eventDetail.report.submittingMetadata",
        defaultValue: "\(digest) · Receipt unavailable",
        comment: "Stored report digest for a submission started without a stored operator receipt."
      )
    case .accepted:
      if record.acceptanceReceiptHex == nil {
        return String(
          localized: "eventDetail.report.missingReceiptMetadata",
          defaultValue: "\(digest) · Receipt unavailable",
          comment: "Stored report digest when a state says accepted but no operator receipt is stored; no acceptance claim is shown."
        )
      }
      return String(
        localized: "eventDetail.report.receiptMetadata",
        defaultValue: "\(digest) · Operator receipt on device",
        comment: "Stored report digest with an operator acceptance receipt durably present on this device."
      )
    }
  }

  private func shortDigest(_ digest: String) -> String {
    guard digest.count > 8 else { return digest }
    return "\(digest.prefix(4))…\(digest.suffix(4))"
  }
}

/// 09's `FROM REPORTS` and 11's `INCLUDED IN REPORTS`: the reports linked to
/// one session's Proof. Not rendered at all when there are none or the link
/// table is unreadable, and the heading carries no count (beid#701 OD-6).
struct LinkedReportsSection: View {
  let heading: String
  let identifierPrefix: String
  let proof: Proof
  @ObservedObject var submissionStore: ReportSubmissionStore
  @ObservedObject var proofStore: ProofStore
  @ObservedObject var linkStore: ReportProofLinkStore
  let sensing: SensingCoordinator

  var body: some View {
    let reports = ReportProofLinkPresentation.reports(
      for: proof, submissionStore: submissionStore, linkStore: linkStore, proofStore: proofStore
    )
    if !reports.isEmpty {
      VStack(alignment: .leading, spacing: DS.Space.s) {
        Text(verbatim: heading)
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondary)
        ForEach(reports, id: \.record.id) { report in
          hairline
          EventReportRow(
            ordinal: report.ordinal,
            record: report.record,
            identifier: "\(identifierPrefix).\(report.record.id.uuidString)",
            submissionStore: submissionStore,
            proofStore: proofStore,
            linkStore: linkStore,
            sensing: sensing
          )
        }
        hairline
      }
      .padding(.top, DS.Space.xl)
    }
  }

  private var hairline: some View {
    Rectangle()
      .fill(DS.Color.strokeHairline)
      .frame(height: DS.Size.hairline)
  }
}
