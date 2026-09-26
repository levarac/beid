// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import XCTest
@testable import Beid

/// `SigilPresenceStore` (beid#653): persistence mechanics only. What the text
/// means is pinned by the shared `SigilPresenceTest`; what may never leave
/// the device is pinned by `SigilPresenceNeverLeavesDeviceTests`.
@MainActor
final class SigilPresenceStoreTests: XCTestCase {
  private var directory: URL!

  // The async overrides, because XCTest declares them `@MainActor`; the sync
  // `setUpWithError`/`tearDownWithError` are nonisolated and could not touch
  // `directory` (same shape as `ReportProofLinkPresentationTests`).
  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("beid653-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private var fileURL: URL {
    directory.appendingPathComponent("SigilPresence", isDirectory: true)
      .appendingPathComponent("sigil-presence.json")
  }

  private typealias Session = BeidSharedKit.sigil.SigilPresenceSession
  private typealias Observations = BeidSharedKit.aggregation.AggregationObservationInput

  /// Two peers over two windows, every peer tokened unless `tokened` is false.
  private func makeSession(firstToken: Int = 1, tokened: Bool = true) -> (Session, Observations) {
    let observations = BeidSharedKit.aggregation.createAggregationObservationInput()
    let rows: [(Int64, String, String?)] = [
      (10, "r1", "d0000001"), (10, "r2", "d0000002"), (11, "r3", "d0000001"),
    ]
    for (window, rpid, displayId) in rows {
      XCTAssertTrue(BeidSharedKit.aggregation.addAggregationObservation(
        input: observations, windowIndex: window, peerKey: rpid, displayId: displayId, mutual: false
      ))
    }
    let session = BeidSharedKit.sigil.createSigilPresenceSession()
    if tokened {
      let needed = Int(BeidSharedKit.sigil.sigilPresenceTokensNeeded(session: session, observations: observations))
      XCTAssertEqual(needed, 2)
      for offset in 0..<needed {
        let token = String(format: "%032lx", firstToken + offset)
        XCTAssertTrue(BeidSharedKit.sigil.addSigilPresenceToken(
          session: session, observations: observations, token: token
        ))
      }
    }
    return (session, observations)
  }

  func testAPersistedRecordReadsBackAsASigilInputAndSurvivesReload() throws {
    let store = SigilPresenceStore(fileURL: fileURL)
    let proofId = UUID()
    let (session, observations) = makeSession()
    let record = try store.persist(session: session, observations: observations, proofId: proofId)

    XCTAssertEqual(record.proofId, proofId)
    XCTAssertEqual(
      record.presenceText,
      "beid-sigil-presence\t1\nwindows\t2\npeers\t2\n"
        + "peer\t00000000000000000000000000000001\t0,1\n"
        + "peer\t00000000000000000000000000000002\t0\nend\n"
    )
    XCTAssertEqual(store.sigilInput(proofId: proofId)?.windowCount, 2)

    let reloaded = SigilPresenceStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.records, store.records)
    XCTAssertEqual(reloaded.sigilInput(proofId: proofId)?.windowCount, 2)
  }

  func testARepeatedLookupReturnsTheSameInstanceUntilTheRowIsRemoved() throws {
    let store = SigilPresenceStore(fileURL: fileURL)
    let proofId = UUID()
    let (session, observations) = makeSession()
    try store.persist(session: session, observations: observations, proofId: proofId)

    let first = try XCTUnwrap(store.sigilInput(proofId: proofId))
    let second = try XCTUnwrap(store.sigilInput(proofId: proofId))
    XCTAssertTrue(first === second, "a row must be decoded once, not on every view render")

    try store.remove(proofId: proofId)
    XCTAssertNil(store.sigilInput(proofId: proofId), "remove must drop the cached input too")
  }

  func testResetForUITestingDropsCachedInputs() throws {
    let store = SigilPresenceStore(fileURL: fileURL)
    let proofId = UUID()
    let (session, observations) = makeSession()
    try store.persist(session: session, observations: observations, proofId: proofId)
    XCTAssertNotNil(store.sigilInput(proofId: proofId))
    store.resetForUITesting()
    XCTAssertNil(store.sigilInput(proofId: proofId))
  }

  func testALookupBeforeTheRowExistsDoesNotHideItLater() throws {
    let store = SigilPresenceStore(fileURL: fileURL)
    let proofId = UUID()
    XCTAssertNil(store.sigilInput(proofId: proofId))
    let (session, observations) = makeSession()
    try store.persist(session: session, observations: observations, proofId: proofId)
    XCTAssertNotNil(store.sigilInput(proofId: proofId), "a missing row must not be cached as absent")
  }

  func testAnUnknownRecordHasNoInput() {
    let store = SigilPresenceStore(fileURL: fileURL)
    XCTAssertNil(store.sigilInput(proofId: UUID()))
  }

  func testAnUnencodableSessionWritesNothing() throws {
    let store = SigilPresenceStore(fileURL: fileURL)
    let proofId = UUID()
    let (session, observations) = makeSession(tokened: false)
    XCTAssertThrowsError(try store.persist(session: session, observations: observations, proofId: proofId)) {
      guard case SigilPresenceStoreError.unencodable = $0 else {
        return XCTFail("expected unencodable, got \($0)")
      }
    }
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertNil(store.sigilInput(proofId: proofId))
  }

  func testAnIdenticalRewriteIsANoOpAndADifferentOneConflicts() throws {
    let store = SigilPresenceStore(fileURL: fileURL)
    let proofId = UUID()
    let (session, observations) = makeSession()
    let first = try store.persist(session: session, observations: observations, proofId: proofId)
    let again = try store.persist(session: session, observations: observations, proofId: proofId)
    XCTAssertEqual(first, again)
    XCTAssertEqual(store.records.count, 1)

    let (other, otherObservations) = makeSession(firstToken: 100)
    XCTAssertThrowsError(try store.persist(session: other, observations: otherObservations, proofId: proofId)) {
      guard case SigilPresenceStoreError.conflictingPresence = $0 else {
        return XCTFail("expected conflictingPresence, got \($0)")
      }
    }
    XCTAssertEqual(store.records, [first])
  }

  func testRemoveDeletesOnlyThatRecordAndPersists() throws {
    let store = SigilPresenceStore(fileURL: fileURL)
    let kept = UUID()
    let removed = UUID()
    let (a, aObservations) = makeSession(firstToken: 1)
    let (b, bObservations) = makeSession(firstToken: 50)
    try store.persist(session: a, observations: aObservations, proofId: kept)
    try store.persist(session: b, observations: bObservations, proofId: removed)

    try store.remove(proofId: removed)
    XCTAssertNil(store.sigilInput(proofId: removed))
    XCTAssertNotNil(store.sigilInput(proofId: kept))
    let reloaded = SigilPresenceStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.records.map(\.proofId), [kept])

    try store.remove(proofId: UUID()) // unknown: no-op
    XCTAssertEqual(store.records.map(\.proofId), [kept])
  }

  func testResetForUITestingClearsMemoryAndFile() throws {
    let store = SigilPresenceStore(fileURL: fileURL)
    let (session, observations) = makeSession()
    try store.persist(session: session, observations: observations, proofId: UUID())
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    store.resetForUITesting()
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  func testEveryWriteKeepsTheFileAndItsDirectoryOutOfBackups() throws {
    let store = SigilPresenceStore(fileURL: fileURL)
    for firstToken in [1, 10, 20] {
      let (session, observations) = makeSession(firstToken: firstToken)
      try store.persist(session: session, observations: observations, proofId: UUID())
      // An atomic write replaces the file, which drops a mark set on the old
      // one; the store must mark the new file every time.
      XCTAssertEqual(try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
      XCTAssertEqual(
        try fileURL.deletingLastPathComponent()
          .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
        true
      )
    }
  }

  func testACorruptFileIsQuarantinedAndReadsAsNoData() throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("{not json".utf8).write(to: fileURL)
    let store = SigilPresenceStore(fileURL: fileURL)
    XCTAssertNotNil(store.quarantinedFileURL)
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertNil(store.sigilInput(proofId: UUID()))
  }

  func testARowTheSharedDecoderRejectsReadsAsNoData() throws {
    let proofId = UUID()
    let tampered = [
      SigilPresenceRecord(
        proofId: proofId,
        // A presence column does not exist in v1: this must never draw.
        presenceText: "beid-sigil-presence\t1\nwindows\t1\npeers\t1\n"
          + "peer\t00000000000000000000000000000001\t0\t2\nend\n"
      ),
    ]
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try RecordSchemaEnvelope.encodeRecords(tampered).write(to: fileURL)
    let store = SigilPresenceStore(fileURL: fileURL)
    XCTAssertEqual(store.records.count, 1)
    XCTAssertNil(store.sigilInput(proofId: proofId))
  }
}
