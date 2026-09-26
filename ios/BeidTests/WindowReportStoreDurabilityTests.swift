// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

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

  func testRecoveringStorePrunesOldestQuarantineFilesBeyondRetentionCap() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-window-report-quarantine-retention-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("window-reports.json")
    var quarantinedURLs: [URL] = []
    for index in 0..<6 {
      try Data("not-window-report-json-\(index)".utf8).write(to: fileURL, options: .atomic)
      let recovery = try WindowReportStore.recoveringCorruptReports(
        fileURL: fileURL,
        now: Date(timeIntervalSince1970: Double(1_000 + index))
      )
      quarantinedURLs.append(try XCTUnwrap(recovery.quarantinedReportsURL))
    }

    let siblings = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    let survivingQuarantineFiles = Set(
      siblings.filter { $0.lastPathComponent.contains(".corrupt-") }
    )

    XCTAssertEqual(survivingQuarantineFiles.count, 5)
    XCTAssertFalse(survivingQuarantineFiles.contains(quarantinedURLs[0]))
    for keptURL in quarantinedURLs.suffix(5) {
      XCTAssertTrue(survivingQuarantineFiles.contains(keptURL))
    }
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

  func testAddSynchronizesStagedFileBeforeAtomicSwap() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-window-report-fsync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("window-reports.json")
    let report = try makeReport(id: "00000000-0000-0000-0000-000000000001")
    var synchronizedURLs: [URL] = []
    let store = WindowReportStore(
      fileURL: fileURL,
      synchronizeStagedFile: { stagedURL in
        synchronizedURLs.append(stagedURL)
        // The durable file must not yet reflect the new bytes: synchronizing
        // the staged file must happen before the atomic swap, not after.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
      }
    )

    XCTAssertEqual(try store.add(report), "00000000-0000-0000-0000-000000000001")

    XCTAssertEqual(synchronizedURLs.count, 1)
    XCTAssertNotEqual(synchronizedURLs[0], fileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
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
