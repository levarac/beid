// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation
import XCTest
@testable import Beid

final class UnsentWindowLedgerStoreTests: XCTestCase {
  func testStrictStoreOpeningRejectsCorruptSnapshotAndLeavesBytesUntouched() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-ledger-strict-corrupt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("ledger.snapshot")
    let corruptBytes = Data([0xff, 0xfe, 0x00, 0x01])
    try corruptBytes.write(to: fileURL, options: .atomic)

    XCTAssertThrowsError(try UnsentWindowLedgerStore(fileURL: fileURL)) { error in
      guard case UnsentWindowLedgerStoreError.invalidSnapshot = error else {
        return XCTFail("expected invalidSnapshot, got \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes)
    let siblings = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    XCTAssertTrue(siblings.filter { $0.lastPathComponent.contains(".corrupt-") }.isEmpty)
  }

  func testRecoveringStoreQuarantinesInvalidSnapshotWithTimestampAndStartsFresh() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-ledger-recover-corrupt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("ledger.snapshot")
    let corruptBytes = Data("not-a-ledger".utf8)
    try corruptBytes.write(to: fileURL, options: .atomic)

    let recovery = try UnsentWindowLedgerStore.recoveringCorruptSnapshot(
      fileURL: fileURL,
      now: Date(timeIntervalSince1970: 1_234.567)
    )

    let quarantinedURL = try XCTUnwrap(recovery.quarantinedSnapshotURL)
    XCTAssertTrue(quarantinedURL.lastPathComponent.contains(".corrupt-1234567-"))
    XCTAssertEqual(try Data(contentsOf: quarantinedURL), corruptBytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertNil(try recovery.store.load())

    let runtime = try UnsentWindowLedgerRuntime(
      store: recovery.store,
      ledgerInstanceIdHex: "000102030405060708090a0b0c0d0e0f"
    )
    try runtime.openWindow(windowId: "fresh-window")
    XCTAssertEqual(try XCTUnwrap(try recovery.store.load()).persistenceRevision, 1)
  }

  func testRecoveringStorePrunesOldestQuarantineFilesBeyondRetentionCap() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-ledger-quarantine-retention-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("ledger.snapshot")
    var quarantinedURLs: [URL] = []
    for index in 0..<6 {
      try Data("not-a-ledger-\(index)".utf8).write(to: fileURL, options: .atomic)
      let recovery = try UnsentWindowLedgerStore.recoveringCorruptSnapshot(
        fileURL: fileURL,
        now: Date(timeIntervalSince1970: Double(1_000 + index))
      )
      quarantinedURLs.append(try XCTUnwrap(recovery.quarantinedSnapshotURL))
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

  func testRecoveringStoreLeavesValidSnapshotInPlace() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-ledger-recover-valid-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("ledger.snapshot")
    let initialStore = try UnsentWindowLedgerStore(fileURL: fileURL)
    let runtime = try UnsentWindowLedgerRuntime(
      store: initialStore,
      ledgerInstanceIdHex: "000102030405060708090a0b0c0d0e0f"
    )
    try runtime.openWindow(windowId: "window-1")
    let originalBytes = try Data(contentsOf: fileURL)

    let recovery = try UnsentWindowLedgerStore.recoveringCorruptSnapshot(
      fileURL: fileURL,
      now: Date(timeIntervalSince1970: 1_234.567)
    )

    XCTAssertNil(recovery.quarantinedSnapshotURL)
    XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
    XCTAssertEqual(try XCTUnwrap(try recovery.store.load()).persistenceRevision, 1)
  }

  func testPersistSynchronizesStagedFileBeforeAtomicSwap() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid-ledger-fsync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("ledger.snapshot")
    var synchronizedURLs: [URL] = []
    let store = try UnsentWindowLedgerStore(
      fileURL: fileURL,
      synchronizeStagedFile: { stagedURL in
        synchronizedURLs.append(stagedURL)
        // The durable file must not yet reflect the new bytes: synchronizing
        // the staged file must happen before the atomic swap, not after.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
      }
    )
    let ledger = try XCTUnwrap(
      BeidSharedKit.report.createUnsentWindowLedger(
        ledgerInstanceIdHex: "000102030405060708090a0b0c0d0e0f"
      ).ledger
    )
    let opened = BeidSharedKit.report.openUnsentWindow(
      ledger: ledger,
      windowId: "window-1"
    )

    try store.persist(opened)

    XCTAssertEqual(synchronizedURLs.count, 1)
    XCTAssertNotEqual(synchronizedURLs[0], fileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
  }

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
