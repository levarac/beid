// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import XCTest
@testable import Beid

/// Proves `ReportSubmissionRuntime.submissionState(forEventCode:)` — the
/// query beid#292's Transparency screen uses for its "Sent" and "Acceptance
/// receipt" rows — reads real, durable `ReportSubmissionStore` state rather
/// than returning a constant. Seeds a record through the store's own
/// state-machine API (`add` -> `markSubmitting` -> `storeReceipt`), not by
/// constructing `.accepted` directly, and asserts the runtime built on top
/// of that same file reports it correctly and only for the matching event
/// code.
@MainActor
final class ReportSubmissionStateQueryTests: XCTestCase {
  func testSubmissionStateReflectsRealStoredAcceptanceAndIsScopedByEventCode() throws {
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-query")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")

    let seedStore = ReportSubmissionStore(fileURL: fileURL)
    let record = makeRecord(eventCode: "EVENTA")
    try seedStore.add(record)
    try seedStore.markSubmitting(for: record.id)
    try seedStore.storeReceipt(
      for: record.id,
      signedReceiptHex: String(repeating: "ab", count: 24)
    )

    let runtime = try XCTUnwrap(
      makeEnabledRuntime(fileURL: fileURL),
      "expected an enabled ReportSubmissionRuntime for this test bundle"
    )

    XCTAssertEqual(runtime.submissionState(forEventCode: "EVENTA"), .accepted)
    XCTAssertNil(
      runtime.submissionState(forEventCode: "EVENTB"),
      "a different event code with no records must not read the seeded event's state"
    )
  }

  func testSubmissionStateReportsSubmittingBeforeAReceiptExists() throws {
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-query-submitting")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")

    let seedStore = ReportSubmissionStore(fileURL: fileURL)
    let record = makeRecord(eventCode: "EVENTA")
    try seedStore.add(record)
    try seedStore.markSubmitting(for: record.id)

    let runtime = try XCTUnwrap(makeEnabledRuntime(fileURL: fileURL))

    XCTAssertEqual(runtime.submissionState(forEventCode: "EVENTA"), .submitting)
  }

  private func makeEnabledRuntime(fileURL: URL) throws -> ReportSubmissionRuntime? {
    let bundleDirectory = try makeIsolatedDirectory(named: "beid-report-submission-query-bundle")
    let plist: [String: Any] = [
      "CFBundleIdentifier": "org.levarac.beid.tests.\(UUID().uuidString)",
      "CFBundlePackageType": "BNDL",
      "BeidReportSubmissionEnabled": "1"
    ]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try plistData.write(to: bundleDirectory.appendingPathComponent("Info.plist"))
    let bundle = try XCTUnwrap(Bundle(url: bundleDirectory))
    return ReportSubmissionRuntime.makeIfEnabled(
      bundle: bundle,
      eventSigningCryptography: NeverInvokedSensingCryptography(),
      definitionProvider: NeverInvokedEventDefinitionContextProvider(),
      fileURL: fileURL
    )
  }

  private func makeRecord(eventCode: String) -> ReportSubmissionRecord {
    ReportSubmissionRecord(
      id: UUID(),
      eventCode: eventCode,
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

/// Never expected to run any cryptographic operation — this test only
/// exercises the read-only `submissionState(forEventCode:)` query, never
/// `captureAndQueueWindow`/`submitPending`, so no signing call should ever
/// reach this stub.
private final class NeverInvokedSensingCryptography: SensingCryptography {
  func eventSigningPublicKey(eventCode: String) -> Data {
    XCTFail("not expected to be invoked by this test")
    return Data()
  }

  func ownerPublicKey() -> Data {
    XCTFail("not expected to be invoked by this test")
    return Data()
  }

  func signWindowReport(eventCode: String, bytes: Data) -> SensingRecoverableSignature {
    XCTFail("not expected to be invoked by this test")
    return SensingRecoverableSignature(r: Data(), s: Data(), v: 0)
  }

  func signSelfProof(
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64
  ) -> SensingRecoverableSignature? {
    XCTFail("not expected to be invoked by this test")
    return nil
  }

  func signWalletAcknowledgement(
    walletAddress: Data,
    walletSignature: Data
  ) -> SensingRecoverableSignature? {
    XCTFail("not expected to be invoked by this test")
    return nil
  }
}

/// Never expected to run — this test never calls `captureAndQueueWindow`, so
/// no registry resolution should ever reach this stub.
@MainActor
private final class NeverInvokedEventDefinitionContextProvider: EventDefinitionContextProvider {
  func resolve(
    eventIdHex: String,
    completion: @escaping (VerifiedSubmissionDefinition?) -> Void
  ) {
    XCTFail("not expected to be invoked by this test")
    completion(nil)
  }
}
