// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

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

  private func record(
    state: ReportSubmissionState,
    receipt: String? = nil,
    terminalError: String? = nil
  ) -> ReportSubmissionRecord {
    ReportSubmissionRecord(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000641")!,
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
