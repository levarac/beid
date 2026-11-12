// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

final class ReportDetailPresentationTests: XCTestCase {
  func testRecordLadderAlwaysHasFourRungsAndOnlyReceiptsAdvanceDelivery() {
    let pending = RecordSendingLadderPresentation(hasSelfProof: true, records: [record(state: .submitting)])
    XCTAssertEqual(pending.rungs.map(\.number), [1, 2, 3, 4])
    XCTAssertEqual(pending.rungs.map(\.title), [
      "SEALED ON THIS PHONE", "SENT TO ORGANIZER", "ACCEPTED", "THIRD-PARTY RESULT"
    ])
    XCTAssertEqual(pending.rungs.map(\.reached), [true, false, false, false])

    for incomplete in [
      record(state: .prepared), record(state: .accepted),
      record(state: .accepted, receipt: "ab", terminalError: "local-error")
    ] {
      XCTAssertEqual(
        RecordSendingLadderPresentation(hasSelfProof: false, records: [incomplete]).rungs.map(\.reached),
        [false, false, false, false]
      )
    }
    let accepted = RecordSendingLadderPresentation(
      hasSelfProof: true, records: [record(state: .accepted, receipt: "ab")]
    )
    XCTAssertEqual(accepted.rungs.map(\.reached), [true, true, true, false])
    XCTAssertEqual(accepted.rungs[1].title, "SENT TO https://example.invalid:443")
  }

  func testRecordLadderKeepsPartialAndUnavailableDeliveryPending() {
    let mixed = RecordSendingLadderPresentation(hasSelfProof: false, records: [
      record(state: .accepted, receipt: "ab"), record(state: .prepared)
    ])
    XCTAssertEqual(mixed.rungs[0].title, "RECORDED ON THIS PHONE")
    XCTAssertEqual(mixed.rungs.map(\.reached), [false, false, false, false])
    for records in [nil, []] as [[ReportSubmissionRecord]?] {
      let missing = RecordSendingLadderPresentation(hasSelfProof: false, records: records)
      XCTAssertEqual(missing.rungs.count, 4)
      XCTAssertEqual(missing.rungs.map(\.reached), [false, false, false, false])
    }
  }

  func testExcludedWindowsUseAReasonNeutralLabel() {
    XCTAssertEqual(ReportDetailPresentation.excludedWindowLabel, "Not submittable")
  }

  func testSubmittingDoesNotClaimSentOrAccepted() {
    let presentation = ReportDetailPresentation(record: record(state: .submitting))
    XCTAssertEqual(presentation.caption, "SUBMISSION IN PROGRESS")
    XCTAssertEqual(presentation.delivery, "DELIVERY UNCONFIRMED")
    XCTAssertEqual(presentation.receipt, "RECEIPT UNAVAILABLE")
    XCTAssertFalse(presentation.showsPreparedAt)
  }

  func testPreparedTimeIsOnlyShownForPreparation() {
    let presentation = ReportDetailPresentation(record: record(state: .prepared))
    XCTAssertEqual(presentation.caption, "PREPARED ON THIS PHONE")
    XCTAssertEqual(presentation.delivery, "NOT SENT")
    XCTAssertTrue(presentation.showsPreparedAt)
  }

  func testAcceptedFlagWithoutReceiptDoesNotClaimAcceptance() {
    let presentation = ReportDetailPresentation(record: record(state: .accepted))
    XCTAssertEqual(presentation.delivery, "STATUS UNAVAILABLE")
    XCTAssertEqual(presentation.receipt, "STATUS UNAVAILABLE")
  }

  func testStoredReceiptIsTheAcceptanceEvidence() {
    // This in-memory value exercises display mapping only; no receipt is
    // seeded into a screenshot fixture or sent over the network.
    let presentation = ReportDetailPresentation(record: record(state: .accepted, receipt: "ab"))
    XCTAssertEqual(presentation.delivery, "ACCEPTED BY OPERATOR")
    XCTAssertEqual(presentation.receipt, "STORED")
  }

  func testTerminalFailureDoesNotClaimOperatorRejection() {
    let presentation = ReportDetailPresentation(
      record: record(state: .submitting, terminalError: "local-error")
    )
    XCTAssertEqual(presentation.caption, "SUBMISSION STOPPED")
    XCTAssertEqual(presentation.delivery, "DELIVERY UNCONFIRMED")
  }

  func testMixedWindowsDoNotBorrowAnotherWindowsReceipt() {
    let records = [
      record(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001"), state: .accepted, receipt: "ab"),
      record(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002"), state: .prepared),
      record(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003"), state: .accepted)
    ]
    let progress = ReportProgressPresentation(records: records)
    XCTAssertEqual(progress.summary, "1 OF 3 RECEIVED")
    XCTAssertEqual(progress.receivedCount, 1)
    XCTAssertEqual(ReportProgressPresentation(records: [records[1]]).summary, "PREPARED ON THIS PHONE")
    XCTAssertEqual(ReportProgressPresentation(records: [records[2]]).summary, "STATUS UNAVAILABLE")
    XCTAssertEqual(ReportProgressPresentation(records: []).summary, "NO LINKED REPORTS")
  }

  func testStoppedWindowDoesNotContributeReceiptSuccess() {
    let stopped = record(state: .accepted, receipt: "ab", terminalError: "local-error")
    XCTAssertEqual(ReportProgressPresentation(records: [stopped]).receivedCount, 0)
    XCTAssertEqual(ReportProgressPresentation(records: [stopped]).summary, "SUBMISSION STOPPED")
  }

  func testWindowSelectionKeepsEveryKnownReportAndItsOwnServerReceipt() {
    let first = record(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000001"),
      endpoint: "https://first.example.invalid/observations", state: .accepted, receipt: "ab"
    )
    let second = record(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000002"),
      endpoint: "https://second.example.invalid/observations", state: .prepared
    )
    let third = record(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003"), state: .accepted)
    let unknown = record(id: UUID(uuidString: "00000000-0000-4000-8000-000000000004"), state: .submitting)
    let reports = [first, second, third, unknown].enumerated().map { LinkedReport(ordinal: $0.offset + 1, record: $0.element) }
    let indices = [first.id: Int64(7), second.id: 7, third.id: 9]
    let selected = WindowReportSelection.reports(reports, at: 7) { indices[$0] }
    XCTAssertEqual(selected.map(\.record.id), [first.id, second.id])
    XCTAssertEqual(selected.map(\.record.endpoint), [first.endpoint, second.endpoint])
    XCTAssertEqual(ReportDetailPresentation(record: selected[0].record).receipt, "STORED")
    XCTAssertEqual(ReportDetailPresentation(record: selected[1].record).delivery, "NOT SENT")
    let other = WindowReportSelection.reports(reports, at: 9) { indices[$0] }
    XCTAssertEqual(other.map(\.record.id), [third.id])
    XCTAssertEqual(ReportDetailPresentation(record: other[0].record).receipt, "STATUS UNAVAILABLE")
    XCTAssertTrue(WindowReportSelection.reports(reports, at: 8) { indices[$0] }.isEmpty)
  }

  private func record(
    id: UUID? = nil,
    endpoint: String = "https://example.invalid/observations",
    state: ReportSubmissionState,
    receipt: String? = nil,
    terminalError: String? = nil
  ) -> ReportSubmissionRecord {
    ReportSubmissionRecord(
      id: id ?? UUID(uuidString: "00000000-0000-4000-8000-000000000641")!,
      eventCode: "ETHTOKYO2026",
      endpoint: endpoint,
      receiptPublicKeyHex: String(repeating: "a", count: 64),
      eventIdHex: nil,
      eventDefinitionDigestHex: nil,
      validFrom: nil,
      validUntil: nil,
      signedObservationHex: "d28440a04040",
      observationDigestHex: String(repeating: "b", count: 64),
      submissionState: state,
      acceptanceReceiptHex: receipt,
      terminalErrorCode: terminalError,
      createdAt: Date(timeIntervalSince1970: 1_774_486_920)
    )
  }
}
