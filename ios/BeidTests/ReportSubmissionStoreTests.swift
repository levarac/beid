// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import XCTest
@testable import Beid

@MainActor
final class ReportSubmissionStoreTests: XCTestCase {
  func testExactObservationBytesAndVerifiedReceiptSurviveReload() throws {
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-store")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let windowId = UUID()
    let record = makeRecord(id: windowId)
    let store = ReportSubmissionStore(fileURL: fileURL)

    XCTAssertEqual(try store.add(record), record)
    let receiptHex = String(repeating: "ab", count: 24)
    let storedReceipt = try store.storeReceipt(
      for: windowId,
      signedReceiptHex: receiptHex
    )

    XCTAssertEqual(storedReceipt.acceptanceReceiptHex, receiptHex)
    let reloaded = ReportSubmissionStore(fileURL: fileURL)
    let restored = try XCTUnwrap(reloaded.record(id: windowId))
    XCTAssertEqual(restored.signedObservationHex, record.signedObservationHex)
    XCTAssertEqual(restored.observationDigestHex, record.observationDigestHex)
    XCTAssertEqual(restored.acceptanceReceiptHex, receiptHex)
    XCTAssertEqual(restored.submissionState, .accepted)
  }

  func testSubmissionStatePersistsPreparedSubmittingAcceptedAcrossReloads() throws {
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-state-machine")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let record = makeRecord()
    let store = ReportSubmissionStore(fileURL: fileURL)

    try store.add(record)
    XCTAssertEqual(store.record(id: record.id)?.submissionState, .prepared)

    let submitting = try store.markSubmitting(for: record.id)
    XCTAssertEqual(submitting.submissionState, .submitting)
    let reloadedSubmitting = try XCTUnwrap(
      ReportSubmissionStore(fileURL: fileURL).record(id: record.id)
    )
    XCTAssertEqual(reloadedSubmitting.submissionState, .submitting)

    let accepted = try store.storeReceipt(
      for: record.id,
      signedReceiptHex: String(repeating: "ab", count: 24)
    )
    XCTAssertEqual(accepted.submissionState, .accepted)
    XCTAssertTrue(ReportSubmissionStore(fileURL: fileURL).pendingRecords.isEmpty)
  }

  func testDuplicateWindowAndReceiptWritesAreIdempotent() throws {
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-idempotent")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let record = makeRecord()
    let store = ReportSubmissionStore(fileURL: fileURL)

    XCTAssertEqual(try store.add(record), record)
    XCTAssertEqual(try store.add(record), record)
    let receiptHex = String(repeating: "cd", count: 24)
    XCTAssertEqual(
      try store.storeReceipt(for: record.id, signedReceiptHex: receiptHex).acceptanceReceiptHex,
      receiptHex
    )
    XCTAssertEqual(
      try store.storeReceipt(for: record.id, signedReceiptHex: receiptHex).acceptanceReceiptHex,
      receiptHex
    )
    XCTAssertEqual(store.records.count, 1)
  }

  func testDifferentObservationBytesForOneWindowAreRejected() throws {
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-conflict")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let record = makeRecord()
    let store = ReportSubmissionStore(fileURL: fileURL)
    try store.add(record)

    XCTAssertThrowsError(
      try store.add(
        ReportSubmissionRecord(
          id: record.id,
          eventCode: record.eventCode,
          endpoint: record.endpoint,
          receiptPublicKeyHex: record.receiptPublicKeyHex,
          eventIdHex: record.eventIdHex,
          eventDefinitionDigestHex: record.eventDefinitionDigestHex,
          validFrom: record.validFrom,
          validUntil: record.validUntil,
          signedObservationHex: "bb",
          observationDigestHex: record.observationDigestHex,
          createdAt: record.createdAt
        )
      )
    ) { error in
      guard case ReportSubmissionStoreError.conflictingObservation = error else {
        return XCTFail("expected conflictingObservation, got \(error)")
      }
    }
  }

  func testTerminalFailureStopsFutureSubmissionAttempts() throws {
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-terminal")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let record = makeRecord()
    let store = ReportSubmissionStore(fileURL: fileURL)
    try store.add(record)

    XCTAssertEqual(
      try store.markTerminalFailure(for: record.id, code: "rejected").terminalErrorCode,
      "rejected"
    )
    XCTAssertTrue(store.pendingRecords.isEmpty)
    XCTAssertEqual(
      try store.markTerminalFailure(for: record.id, code: "rejected").terminalErrorCode,
      "rejected"
    )
    XCTAssertThrowsError(
      try store.storeReceipt(for: record.id, signedReceiptHex: String(repeating: "ef", count: 24))
    )
  }

  private func makeRecord(id: UUID = UUID()) -> ReportSubmissionRecord {
    ReportSubmissionRecord(
      id: id,
      eventCode: "event-1",
      endpoint: "https://operator.example",
      receiptPublicKeyHex: "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5",
      eventIdHex: String(repeating: "11", count: 32),
      eventDefinitionDigestHex: String(repeating: "22", count: 32),
      validFrom: 1,
      validUntil: 2,
      signedObservationHex: "aabbcc",
      observationDigestHex: String(repeating: "33", count: 32),
      createdAt: Date(timeIntervalSince1970: 123)
    )
  }

  private func makeIsolatedDirectory(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
