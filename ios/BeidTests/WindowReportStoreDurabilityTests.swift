// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import XCTest
@testable import Beid

@MainActor
final class WindowReportStoreDurabilityTests: XCTestCase {
  func testDecodeFailureStaysFailClosedUntilExplicitRecoveryThenAddPersistsFreshReport() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-window-report-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("window-reports.json")
    let corruptBytes = Data("not-window-report-json".utf8)
    try corruptBytes.write(to: fileURL, options: .atomic)
    let report = try makeReport(id: "00000000-0000-0000-0000-000000000001")

    let strictStore = WindowReportStore(fileURL: fileURL)
    XCTAssertThrowsError(try strictStore.add(report))
    XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes)

    let recovery = try WindowReportStore.recoveringCorruptReports(
      fileURL: fileURL,
      now: Date(timeIntervalSince1970: 1_234.567)
    )
    let quarantinedURL = try XCTUnwrap(recovery.quarantinedReportsURL)
    XCTAssertTrue(quarantinedURL.lastPathComponent.contains(".corrupt-1234567-"))
    XCTAssertEqual(try Data(contentsOf: quarantinedURL), corruptBytes)

    XCTAssertEqual(
      try recovery.store.add(report),
      "00000000-0000-0000-0000-000000000001"
    )
    XCTAssertEqual(recovery.store.reports, [report])
    XCTAssertEqual(WindowReportStore(fileURL: fileURL).reports, [report])
  }

  func testDirectoryCreationFailureDoesNotPublishAnUndurableReport() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-window-report-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let blockingFile = directory.appendingPathComponent("not-a-directory")
    try Data([0x01]).write(to: blockingFile)
    let store = WindowReportStore(
      fileURL: blockingFile.appendingPathComponent("window-reports.json")
    )
    let reportData = Data(
      """
      {
        "id":"00000000-0000-0000-0000-000000000001",
        "eventCode":"event-1",
        "enin":1,
        "peerCount":1,
        "commitHex":"00",
        "signatureRHex":"01",
        "signatureSHex":"02",
        "signatureV":0,
        "signedAt":0
      }
      """.utf8
    )
    let report = try JSONDecoder().decode(WindowReport.self, from: reportData)

    XCTAssertThrowsError(try store.add(report))
    XCTAssertTrue(store.reports.isEmpty)
  }

  func testAtomicReplacementFailureLeavesDurableAndPublishedReportsUnchanged() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-window-report-replacement-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("window-reports.json")
    let first = try makeReport(id: "00000000-0000-0000-0000-000000000001")
    let second = try makeReport(id: "00000000-0000-0000-0000-000000000002")
    try JSONEncoder().encode([first]).write(to: fileURL)
    var replacementAttempted = false
    let store = WindowReportStore(
      fileURL: fileURL,
      replacePersistedFile: { destinationURL, stagedURL in
        replacementAttempted = true
        XCTAssertEqual(destinationURL, fileURL)
        XCTAssertEqual(
          try JSONDecoder().decode([WindowReport].self, from: Data(contentsOf: stagedURL)),
          [first, second]
        )
        throw InjectedReplacementError.expected
      }
    )

    XCTAssertEqual(store.reports, [first])
    XCTAssertThrowsError(try store.add(second))
    XCTAssertTrue(replacementAttempted)
    XCTAssertEqual(store.reports, [first])
    XCTAssertEqual(WindowReportStore(fileURL: fileURL).reports, [first])
  }

  private func makeReport(id: String) throws -> WindowReport {
    let reportData = Data(
      """
      {
        "id":"\(id)",
        "eventCode":"event-1",
        "enin":1,
        "peerCount":1,
        "commitHex":"00",
        "signatureRHex":"01",
        "signatureSHex":"02",
        "signatureV":0,
        "signedAt":0
      }
      """.utf8
    )
    return try JSONDecoder().decode(WindowReport.self, from: reportData)
  }

  private enum InjectedReplacementError: Error {
    case expected
  }
}
