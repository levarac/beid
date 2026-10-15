// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import Beid

/// beid#701 T1: the link table's own contract, plus its backup exclusion
/// (OD-5 (b)).
@MainActor
final class ReportProofLinkStoreTests: XCTestCase {
  private let windowA = UUID(uuidString: "0A000000-0000-4000-8000-00000000000A")!
  private let windowB = UUID(uuidString: "0B000000-0000-4000-8000-00000000000B")!
  private let proofOne = UUID(uuidString: "01000000-0000-4000-8000-000000000001")!
  private let proofTwo = UUID(uuidString: "02000000-0000-4000-8000-000000000002")!

  private struct BackupExclusionFailure: Error {}

  private func makeFileURL() throws -> URL {
    try makeReportProofLinkTestDirectory(for: self, named: "beid-report-proof-links")
      .appendingPathComponent("report-proof-links.json")
  }

  /// Reads through a fresh, uncached URL. `URL` caches resource values, so
  /// re-reading through the same instance after the file was replaced can
  /// report the old file's flag.
  private func isExcludedFromBackup(_ url: URL) throws -> Bool {
    var fresh = URL(fileURLWithPath: url.path)
    fresh.removeAllCachedResourceValues()
    return try XCTUnwrap(fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup)
  }

  // MARK: - Round trip and lookups

  func testLinksRoundTripAcrossReload() throws {
    let fileURL = try makeFileURL()
    let store = ReportProofLinkStore(fileURL: fileURL)
    try store.add(windowId: windowA, proofId: proofOne)
    try store.add(windowId: windowB, proofId: proofOne)

    let reloaded = ReportProofLinkStore(fileURL: fileURL)

    XCTAssertEqual(reloaded.links, [
      ReportProofLink(windowId: windowA, proofId: proofOne),
      ReportProofLink(windowId: windowB, proofId: proofOne)
    ])
    XCTAssertEqual(reloaded.proofId(forWindowId: windowA), .success(proofOne))
    XCTAssertEqual(reloaded.proofId(forWindowId: windowB), .success(proofOne))
    XCTAssertEqual(reloaded.windowIds(forProofId: proofOne), .success([windowA, windowB]))
    XCTAssertEqual(reloaded.windowIds(forProofId: proofTwo), .success([]))
  }

  func testAbsentFileIsAnEmptyTableAndReadsCreateNoFile() throws {
    let fileURL = try makeFileURL()
    let store = ReportProofLinkStore(fileURL: fileURL)

    XCTAssertEqual(store.links, [])
    XCTAssertEqual(store.proofId(forWindowId: windowA), .success(nil))
    XCTAssertEqual(store.windowIds(forProofId: proofOne), .success([]))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fileURL.path),
      "reading an absent table must not create the file"
    )
  }

  func testSamePairIsIdempotentAndDoesNotRewriteTheFile() throws {
    let fileURL = try makeFileURL()
    let store = ReportProofLinkStore(fileURL: fileURL)
    try store.add(windowId: windowA, proofId: proofOne)
    let bytesAfterFirstAdd = try Data(contentsOf: fileURL)

    try store.add(windowId: windowA, proofId: proofOne)

    XCTAssertEqual(store.links, [ReportProofLink(windowId: windowA, proofId: proofOne)])
    XCTAssertEqual(try Data(contentsOf: fileURL), bytesAfterFirstAdd)
  }

  func testConflictingProofForALinkedWindowThrowsAndKeepsTheStoredRow() throws {
    let fileURL = try makeFileURL()
    let store = ReportProofLinkStore(fileURL: fileURL)
    try store.add(windowId: windowA, proofId: proofOne)
    let bytesBefore = try Data(contentsOf: fileURL)

    XCTAssertThrowsError(try store.add(windowId: windowA, proofId: proofTwo)) { error in
      XCTAssertEqual(error as? ReportProofLinkStoreError, .conflictingLink)
    }

    XCTAssertEqual(store.proofId(forWindowId: windowA), .success(proofOne))
    XCTAssertEqual(try Data(contentsOf: fileURL), bytesBefore)
    XCTAssertEqual(
      ReportProofLinkStore(fileURL: fileURL).proofId(forWindowId: windowA),
      .success(proofOne)
    )
  }

  // MARK: - Unreadable files latch

  func testUndecodableFileLatchesReadsFailWritesThrowAndBytesAreUntouched() throws {
    try assertLatchesUnreadable(Data("not json".utf8))
  }

  func testUnknownSchemaVersionLatchesInsteadOfReadingAsEmpty() throws {
    try assertLatchesUnreadable(Data(#"{"schemaVersion":2,"records":[]}"#.utf8))
  }

  func testConflictingRowsForOneWindowLatchInsteadOfPickingOne() throws {
    let json = """
    {"schemaVersion":1,"records":[\
    {"windowId":"\(windowA.uuidString)","proofId":"\(proofOne.uuidString)"},\
    {"windowId":"\(windowA.uuidString)","proofId":"\(proofTwo.uuidString)"}]}
    """
    try assertLatchesUnreadable(Data(json.utf8))
  }

  private func assertLatchesUnreadable(
    _ contents: Data,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let fileURL = try makeFileURL()
    try contents.write(to: fileURL)

    let store = ReportProofLinkStore(fileURL: fileURL)

    XCTAssertEqual(store.links, [], file: file, line: line)
    XCTAssertEqual(store.proofId(forWindowId: windowA), .failure(.unreadable), file: file, line: line)
    XCTAssertEqual(store.windowIds(forProofId: proofOne), .failure(.unreadable), file: file, line: line)
    XCTAssertThrowsError(try store.add(windowId: windowB, proofId: proofOne), file: file, line: line) { error in
      XCTAssertEqual(error as? ReportProofLinkStoreError, .unreadable, file: file, line: line)
    }
    XCTAssertEqual(
      try Data(contentsOf: fileURL),
      contents,
      "an unreadable link file must never be overwritten",
      file: file,
      line: line
    )
  }

  // MARK: - File format

  func testFileIsSchemaVersionOneEnvelopeWithOnlyWindowAndProofIds() throws {
    let fileURL = try makeFileURL()
    let store = ReportProofLinkStore(fileURL: fileURL)
    try store.add(windowId: windowA, proofId: proofOne)

    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    XCTAssertEqual(Set(object.keys), ["schemaVersion", "records"])
    let records = try XCTUnwrap(object["records"] as? [[String: Any]])
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(Set(records[0].keys), ["windowId", "proofId"])
    XCTAssertEqual(
      (records[0]["windowId"] as? String).flatMap(UUID.init(uuidString:)),
      windowA
    )
    XCTAssertEqual(
      (records[0]["proofId"] as? String).flatMap(UUID.init(uuidString:)),
      proofOne
    )
  }

  // MARK: - Backup exclusion (OD-5 (b))

  func testEveryWriteLeavesTheFileExcludedFromBackup() throws {
    let fileURL = try makeFileURL()
    let store = ReportProofLinkStore(fileURL: fileURL)

    try store.add(windowId: windowA, proofId: proofOne)
    XCTAssertTrue(try isExcludedFromBackup(fileURL))

    // The second write renames a new file over the first, which is exactly
    // what would drop a flag set only once.
    try store.add(windowId: windowB, proofId: proofOne)
    XCTAssertTrue(try isExcludedFromBackup(fileURL))
    XCTAssertFalse(store.isBackupExclusionPending)
  }

  func testLoadingABackedUpFileExcludesIt() throws {
    let fileURL = try makeFileURL()
    let json = """
    {"schemaVersion":1,"records":[\
    {"windowId":"\(windowA.uuidString)","proofId":"\(proofOne.uuidString)"}]}
    """
    try Data(json.utf8).write(to: fileURL)
    XCTAssertFalse(try isExcludedFromBackup(fileURL), "precondition: a freshly written file is backed up")

    let store = ReportProofLinkStore(fileURL: fileURL)

    XCTAssertEqual(store.proofId(forWindowId: windowA), .success(proofOne))
    XCTAssertTrue(try isExcludedFromBackup(fileURL))
  }

  func testBackupExclusionFailureKeepsTheLinkAndIsRetriedOnTheNextWrite() throws {
    let fileURL = try makeFileURL()
    var failNextExclusion = true
    var exclusionAttempts = 0
    let store = ReportProofLinkStore(fileURL: fileURL) { url in
      exclusionAttempts += 1
      if failNextExclusion {
        failNextExclusion = false
        throw BackupExclusionFailure()
      }
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableURL = url
      try mutableURL.setResourceValues(values)
    }

    XCTAssertNoThrow(
      try store.add(windowId: windowA, proofId: proofOne),
      "the link is durable once renamed; a backup-flag failure must not report it as unwritten"
    )
    XCTAssertEqual(exclusionAttempts, 1)
    XCTAssertTrue(store.isBackupExclusionPending)
    XCTAssertEqual(store.proofId(forWindowId: windowA), .success(proofOne))
    XCTAssertEqual(
      ReportProofLinkStore(fileURL: fileURL).proofId(forWindowId: windowA),
      .success(proofOne)
    )

    try store.add(windowId: windowB, proofId: proofOne)

    XCTAssertEqual(exclusionAttempts, 2)
    XCTAssertFalse(store.isBackupExclusionPending)
    XCTAssertTrue(try isExcludedFromBackup(fileURL))
  }
}
