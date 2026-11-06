// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

final class ReportDetailPresentationTests: XCTestCase {
  func testSubmittingDoesNotClaimSentOrAccepted() {
    let presentation = ReportDetailPresentation(record: record(state: .submitting))
    XCTAssertEqual(presentation.caption, "SUBMISSION IN PROGRESS")
    XCTAssertEqual(presentation.delivery, "DELIVERY UNCONFIRMED")
    XCTAssertEqual(presentation.receipt, "RECEIPT UNAVAILABLE")
    XCTAssertFalse(presentation.showsPreparedAt)
  }

  func testPreparedTimeIsOnlyShownForPreparation() {
    let presentation = ReportDetailPresentation(record: record(state: .prepared))
    XCTAssertEqual(presentation.caption, "PREPARED ON DEVICE")
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

  func testTransparencySubmittingIsDeliveryUnconfirmed() {
    let display = TransparencySubmissionDisplay(state: .submitting, receiptStored: false)
    XCTAssertTrue(display.isSubmitting)
    XCTAssertFalse(display.isSent)
  }

  func testTransparencyAcceptanceRequiresStoredReceipt() {
    XCTAssertFalse(TransparencySubmissionDisplay(state: .accepted, receiptStored: false).isSent)
    XCTAssertTrue(TransparencySubmissionDisplay(state: .accepted, receiptStored: true).isSent)
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
    XCTAssertEqual(ReportProgressPresentation(records: [records[1]]).summary, "PREPARED ON DEVICE")
    XCTAssertEqual(ReportProgressPresentation(records: [records[2]]).summary, "STATUS UNAVAILABLE")
    XCTAssertEqual(ReportProgressPresentation(records: []).summary, "NO LINKED REPORTS")
  }

  func testStoppedWindowDoesNotContributeReceiptSuccess() {
    let stopped = record(state: .accepted, receipt: "ab", terminalError: "local-error")
    XCTAssertEqual(ReportProgressPresentation(records: [stopped]).receivedCount, 0)
    XCTAssertEqual(ReportProgressPresentation(records: [stopped]).summary, "SUBMISSION STOPPED")
  }

  private func record(
    id: UUID? = nil,
    state: ReportSubmissionState,
    receipt: String? = nil,
    terminalError: String? = nil
  ) -> ReportSubmissionRecord {
    ReportSubmissionRecord(
      id: id ?? UUID(uuidString: "00000000-0000-4000-8000-000000000641")!,
      eventCode: "ETHTOKYO2026",
      endpoint: "https://example.invalid/observations",
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
