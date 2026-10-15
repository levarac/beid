// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import Beid

/// beid#701 T6: files written before beid#701 decode exactly as before, and
/// every record in them is unlinked. Nothing infers or backfills a link.
///
/// The fixtures are the bytes `62531fe` writes: a bare JSON array (no
/// envelope), `Date` as seconds since the reference date, and `Data` as
/// base64. One record predates `submissionState` and must still load as
/// PREPARED.
@MainActor
final class ReportProofLinkOldFileTests: XCTestCase {
  private let acceptedId = UUID(uuidString: "70100000-0000-4000-8000-00000000a001")!
  private let legacyId = UUID(uuidString: "70100000-0000-4000-8000-00000000a002")!
  private let captureId = UUID(uuidString: "70100000-0000-4000-8000-00000000a003")!

  private var recordsFixture: String {
    """
    [{"id":"\(acceptedId.uuidString)","eventCode":"ETHTOKYO2026",\
    "endpoint":"https://example.invalid/observations",\
    "receiptPublicKeyHex":"\(String(repeating: "ab", count: 33))",\
    "operatorIdHex":"\(String(repeating: "56", count: 32))",\
    "eventIdHex":"\(String(repeating: "11", count: 32))",\
    "eventDefinitionDigestHex":"\(String(repeating: "22", count: 32))",\
    "signedObservationHex":"d28440a04040",\
    "observationDigestHex":"\(String(repeating: "34", count: 32))",\
    "submissionState":"ACCEPTED",\
    "acceptanceReceiptHex":"\(String(repeating: "78", count: 32))",\
    "createdAt":796000000},\
    {"id":"\(legacyId.uuidString)","eventCode":"ETHTOKYO2026",\
    "endpoint":"https://example.invalid/observations",\
    "receiptPublicKeyHex":"\(String(repeating: "ab", count: 33))",\
    "signedObservationHex":"d28440a04041",\
    "observationDigestHex":"\(String(repeating: "35", count: 32))",\
    "createdAt":796000300}]
    """
  }

  private var pendingCapturesFixture: String {
    """
    [{"id":"\(captureId.uuidString)","eventCode":"ETHTOKYO2026",\
    "eventIdHex":"\(String(repeating: "11", count: 32))","enin":7,\
    "peerRpids":["01aa","01bb"],"reporterRpid":"01cc",\
    "participantCommitment":"XFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFw=",\
    "finalizedAt":1774487000,"createdAt":796000600}]
    """
  }

  private var expectedRecords: [ReportSubmissionRecord] {
    [
      ReportSubmissionRecord(
        id: acceptedId,
        eventCode: "ETHTOKYO2026",
        endpoint: "https://example.invalid/observations",
        receiptPublicKeyHex: String(repeating: "ab", count: 33),
        eventIdHex: String(repeating: "11", count: 32),
        eventDefinitionDigestHex: String(repeating: "22", count: 32),
        validFrom: nil,
        validUntil: nil,
        signedObservationHex: "d28440a04040",
        observationDigestHex: String(repeating: "34", count: 32),
        operatorIdHex: String(repeating: "56", count: 32),
        submissionState: .accepted,
        acceptanceReceiptHex: String(repeating: "78", count: 32),
        createdAt: Date(timeIntervalSinceReferenceDate: 796_000_000)
      ),
      ReportSubmissionRecord(
        id: legacyId,
        eventCode: "ETHTOKYO2026",
        endpoint: "https://example.invalid/observations",
        receiptPublicKeyHex: String(repeating: "ab", count: 33),
        eventIdHex: nil,
        eventDefinitionDigestHex: nil,
        validFrom: nil,
        validUntil: nil,
        signedObservationHex: "d28440a04041",
        observationDigestHex: String(repeating: "35", count: 32),
        submissionState: .prepared,
        createdAt: Date(timeIntervalSinceReferenceDate: 796_000_300)
      )
    ]
  }

  func testPreBeid701FilesDecodeUnchangedAndEveryRecordIsUnlinked() throws {
    let directory = try makeReportProofLinkTestDirectory(for: self, named: "beid-report-proof-link-old-files")
    let submissionURL = directory.appendingPathComponent("report-submissions.json")
    let pendingURL = directory.appendingPathComponent("report-submissions.pending.json")
    let linkURL = directory.appendingPathComponent("report-proof-links.json")
    let recordBytes = Data(recordsFixture.utf8)
    let pendingBytes = Data(pendingCapturesFixture.utf8)
    try recordBytes.write(to: submissionURL)
    try pendingBytes.write(to: pendingURL)

    let submissionStore = ReportSubmissionStore(fileURL: submissionURL)
    let linkStore = ReportProofLinkStore(fileURL: linkURL)

    XCTAssertEqual(submissionStore.records, expectedRecords)
    XCTAssertEqual(submissionStore.pendingCaptures, [
      ReportSubmissionCapture(
        id: captureId,
        eventCode: "ETHTOKYO2026",
        eventIdHex: String(repeating: "11", count: 32),
        enin: 7,
        peerRpids: ["01aa", "01bb"],
        reporterRpid: "01cc",
        participantCommitment: Data(repeating: 0x5c, count: 32),
        finalizedAt: 1_774_487_000,
        createdAt: Date(timeIntervalSinceReferenceDate: 796_000_600)
      )
    ])
    XCTAssertEqual(try Data(contentsOf: submissionURL), recordBytes, "loading must not rewrite the queue")
    XCTAssertEqual(try Data(contentsOf: pendingURL), pendingBytes, "loading must not rewrite pending captures")

    for id in [acceptedId, legacyId, captureId] {
      XCTAssertEqual(
        linkStore.proofId(forWindowId: id),
        .success(nil),
        "a record written before beid#701 must read as unlinked, never inferred"
      )
    }
    XCTAssertEqual(linkStore.links, [])
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: linkURL.path),
      "no link file may be created for existing records"
    )
  }
}
