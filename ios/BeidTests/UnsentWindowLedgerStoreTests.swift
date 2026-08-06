// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation
import XCTest
@testable import Beid

final class UnsentWindowLedgerStoreTests: XCTestCase {
  func testLateOlderWriteFromAnotherStoreInstanceCannotReplaceNewerSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-ledger-multi-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("ledger.snapshot")
    let olderStore = try UnsentWindowLedgerStore(fileURL: fileURL)
    let newerStore = try UnsentWindowLedgerStore(fileURL: fileURL)
    let ledger = try XCTUnwrap(
      BeidSharedKit.report.createUnsentWindowLedger(
        ledgerInstanceIdHex: "000102030405060708090a0b0c0d0e0f"
      ).ledger
    )
    let opened = BeidSharedKit.report.openUnsentWindow(
      ledger: ledger,
      windowId: "window-1"
    )
    let closed = BeidSharedKit.report.closeUnsentWindow(
      ledger: opened.ledger,
      windowId: "window-1",
      persistedObservationReference: "observation-1"
    )

    XCTAssertEqual(try newerStore.persist(closed), 2)
    XCTAssertEqual(try olderStore.persist(opened), 2)
    XCTAssertEqual(
      try XCTUnwrap(try UnsentWindowLedgerStore(fileURL: fileURL).load()).persistenceRevision,
      2
    )
  }

  func testLateOlderWriteCannotReplaceNewerDurableSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-ledger-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("ledger.snapshot")
    let store = try UnsentWindowLedgerStore(fileURL: fileURL)
    let ledger = try XCTUnwrap(
      BeidSharedKit.report.createUnsentWindowLedger(
        ledgerInstanceIdHex: "000102030405060708090a0b0c0d0e0f"
      ).ledger
    )
    let opened = BeidSharedKit.report.openUnsentWindow(
      ledger: ledger,
      windowId: "window-1"
    )
    let closed = BeidSharedKit.report.closeUnsentWindow(
      ledger: opened.ledger,
      windowId: "window-1",
      persistedObservationReference: "observation-1"
    )

    XCTAssertEqual(try store.persist(closed), 2)
    XCTAssertEqual(try store.persist(opened), 2)
    let closedSnapshot = try XCTUnwrap(closed.snapshotText)
    XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), closedSnapshot)

    let relaunched = try UnsentWindowLedgerStore(fileURL: fileURL)
    let restored = try XCTUnwrap(try relaunched.load())
    XCTAssertTrue(restored.isSuccess)
    XCTAssertEqual(restored.persistenceRevision, 2)
    XCTAssertEqual(
      BeidSharedKit.report.encodeUnsentWindowLedgerSnapshot(
        ledger: try XCTUnwrap(restored.ledger)
      ),
      closedSnapshot
    )
    XCTAssertEqual(try Data(contentsOf: fileURL), Data(closedSnapshot.utf8))
  }

  func testKillRelaunchAndPortableTransferRestorePendingThenSameSubmission() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-ledger-portable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let ledgerFileURL = directory.appendingPathComponent("ledger.snapshot")
    let observationFileURL = directory.appendingPathComponent("observation-1.chunk")
    try Data([0x01, 0x02, 0x03]).write(to: observationFileURL, options: .atomic)

    let initialStore = try UnsentWindowLedgerStore(fileURL: ledgerFileURL)
    let empty = try XCTUnwrap(
      BeidSharedKit.report.createUnsentWindowLedger(
        ledgerInstanceIdHex: "000102030405060708090a0b0c0d0e0f"
      ).ledger
    )
    let opened = BeidSharedKit.report.openUnsentWindow(
      ledger: empty,
      windowId: "window-1"
    )
    let closed = BeidSharedKit.report.closeUnsentWindow(
      ledger: opened.ledger,
      windowId: "window-1",
      persistedObservationReference: observationFileURL.lastPathComponent
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: observationFileURL.path))
    try initialStore.persist(closed)

    let pendingAfterRelaunch = try XCTUnwrap(
      try UnsentWindowLedgerStore(fileURL: ledgerFileURL).load()
    )
    XCTAssertEqual(pendingAfterRelaunch.persistenceRevision, 2)
    let prepared = BeidSharedKit.report.prepareNextUnsentWindowSubmission(
      ledger: try XCTUnwrap(pendingAfterRelaunch.ledger),
      maximumWindowCount: 10,
      nowEpochMilliseconds: 0
    )
    try UnsentWindowLedgerStore(fileURL: ledgerFileURL).persist(prepared)

    let inFlightAfterRelaunch = try XCTUnwrap(
      try UnsentWindowLedgerStore(fileURL: ledgerFileURL).load()
    )
    let resumed = try XCTUnwrap(
      BeidSharedKit.report.resumeUnsentWindowSubmissionAfterRestore(
        ledger: try XCTUnwrap(inFlightAfterRelaunch.ledger)
      ).submission
    )
    XCTAssertEqual(
      resumed.submissionKey,
      "000102030405060708090a0b0c0d0e0f0000000000000001"
    )
    XCTAssertEqual(resumed.windowIdAt(index: 0), "window-1")
    XCTAssertEqual(
      resumed.observationReferenceAt(index: 0),
      observationFileURL.lastPathComponent
    )
    let preparedSnapshot = try XCTUnwrap(prepared.snapshotText)
    XCTAssertEqual(try Data(contentsOf: ledgerFileURL), Data(preparedSnapshot.utf8))

    let portableFileURL = directory.appendingPathComponent("icloud-restored.snapshot")
    try FileManager.default.copyItem(at: ledgerFileURL, to: portableFileURL)
    let portable = try XCTUnwrap(
      try UnsentWindowLedgerStore(fileURL: portableFileURL).load()
    )
    let portableSubmission = try XCTUnwrap(
      BeidSharedKit.report.resumeUnsentWindowSubmissionAfterRestore(
        ledger: try XCTUnwrap(portable.ledger)
      ).submission
    )
    XCTAssertEqual(portableSubmission.submissionKey, resumed.submissionKey)
    XCTAssertEqual(portableSubmission.windowIdAt(index: 0), resumed.windowIdAt(index: 0))
    XCTAssertEqual(
      portableSubmission.observationReferenceAt(index: 0),
      resumed.observationReferenceAt(index: 0)
    )
  }
}
