// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import Foundation
import XCTest
@testable import Beid

/// The proof-bearing JSON stores (`ProofStore`, `BindingRecordStore`,
/// `SelfProofStore`) used to decode with a broad `try?`, fall back to an
/// empty array, and then let the next `save()` overwrite the file that
/// failed to decode — so a file that corrupted once took its contents to
/// the grave with no error and no trace (beid#135).
///
/// The contract proven here is the one `WindowReportStore` and
/// `UnsentWindowLedgerStore` already implement: the bytes are preserved
/// under a timestamped sibling name *before* anything can overwrite them,
/// while the read still yields an empty array so the app keeps working.
///
/// These three tests deliberately use only the stores' pre-existing API so
/// they compile — and fail — against the unfixed stores. Detectability is
/// asserted separately in `testEachStoreReportsTheQuarantineItPerformed`,
/// which needs API the fix introduces.
@MainActor
final class CorruptStoreQuarantineTests: XCTestCase {
  func testCorruptProofsFileIsPreservedWhenTheNextProofIsSaved() throws {
    let directory = try makeIsolatedDirectory(named: "beid-proof-quarantine")
    let fileURL = directory.appendingPathComponent("proofs.json")
    let corruptBytes = Data("not-proof-json".utf8)
    try corruptBytes.write(to: fileURL, options: .atomic)

    let store = ProofStore(fileURL: fileURL)
    XCTAssertTrue(store.proofs.isEmpty, "a corrupt file must read as empty, not halt")

    store.add(Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))

    try assertCorruptBytesSurvived(
      corruptBytes,
      in: directory,
      canonicalFileURL: fileURL
    )
    XCTAssertEqual(store.proofs.count, 1)
    XCTAssertEqual(ProofStore(fileURL: fileURL).proofs.count, 1)
  }

  func testCorruptBindingRecordsFileIsPreservedWhenTheNextRecordIsSaved() throws {
    let directory = try makeIsolatedDirectory(named: "beid-binding-quarantine")
    let fileURL = directory.appendingPathComponent("binding-records-v2.json")
    let corruptBytes = Data("not-binding-record-json".utf8)
    try corruptBytes.write(to: fileURL, options: .atomic)

    let store = BindingRecordStore(fileURL: fileURL)
    XCTAssertTrue(store.records.isEmpty, "a corrupt file must read as empty, not halt")

    store.add(makeBindingRecord())

    try assertCorruptBytesSurvived(
      corruptBytes,
      in: directory,
      canonicalFileURL: fileURL
    )
    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(BindingRecordStore(fileURL: fileURL).records.count, 1)
  }

  func testCorruptSelfProofsFileIsPreservedWhenTheNextRecordIsSaved() throws {
    let directory = try makeIsolatedDirectory(named: "beid-self-proof-quarantine")
    let fileURL = directory.appendingPathComponent("self-proofs.json")
    let corruptBytes = Data("not-self-proof-json".utf8)
    try corruptBytes.write(to: fileURL, options: .atomic)

    let store = SelfProofStore(fileURL: fileURL)
    XCTAssertTrue(store.records.isEmpty, "a corrupt file must read as empty, not halt")

    store.add(makeSelfProofRecord())

    try assertCorruptBytesSurvived(
      corruptBytes,
      in: directory,
      canonicalFileURL: fileURL
    )
    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(SelfProofStore(fileURL: fileURL).records.count, 1)
  }

  /// Criterion 3: the quarantine must not be invisible. Unlike the three
  /// tests above, this one uses API the fix introduces, so it cannot be run
  /// against the unfixed stores.
  func testEachStoreReportsTheQuarantineItPerformed() throws {
    let directory = try makeIsolatedDirectory(named: "beid-quarantine-detectable")
    let corruptBytes = Data("not-json".utf8)

    let proofsURL = directory.appendingPathComponent("proofs.json")
    let bindingURL = directory.appendingPathComponent("binding-records-v2.json")
    let selfProofsURL = directory.appendingPathComponent("self-proofs.json")
    for fileURL in [proofsURL, bindingURL, selfProofsURL] {
      try corruptBytes.write(to: fileURL, options: .atomic)
    }

    let reported = [
      ProofStore(fileURL: proofsURL).quarantinedFileURL,
      BindingRecordStore(fileURL: bindingURL).quarantinedFileURL,
      SelfProofStore(fileURL: selfProofsURL).quarantinedFileURL,
    ]

    for quarantinedFileURL in reported {
      let url = try XCTUnwrap(quarantinedFileURL, "the store did not report its quarantine")
      XCTAssertTrue(url.lastPathComponent.contains(".corrupt-"))
      XCTAssertEqual(try Data(contentsOf: url), corruptBytes)
    }
  }

  /// A file that exists but cannot be read is not corruption — a
  /// data-protection-locked read during a background relaunch looks exactly
  /// like this, and quarantining there would move a perfectly good file
  /// aside. The store must instead leave the bytes alone and stop writing,
  /// which keeps the same guarantee: nothing overwrites them.
  func testUnreadableExistingFileIsNeitherQuarantinedNorOverwritten() throws {
    let directory = try makeIsolatedDirectory(named: "beid-quarantine-unreadable")
    let fileURL = directory.appendingPathComponent("proofs.json")
    // A directory at the store's path is readable-as-existing but not
    // readable-as-data, and it fails with a file error rather than a
    // `DecodingError`.
    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

    let store = ProofStore(fileURL: fileURL)
    XCTAssertNil(store.quarantinedFileURL)
    XCTAssertTrue(store.proofs.isEmpty)

    store.add(Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3))

    XCTAssertEqual(store.proofs.count, 1, "the app keeps working in memory")
    var isDirectory: ObjCBool = false
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
      "the unread bytes must still be there"
    )
    XCTAssertTrue(isDirectory.boolValue, "the store must not have replaced them")
    let siblings = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    XCTAssertTrue(
      siblings.filter { $0.lastPathComponent.contains(".corrupt-") }.isEmpty,
      "an unreadable file is not corruption and must not be quarantined"
    )
  }

  // MARK: - Helpers

  private func makeIsolatedDirectory(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  /// The core assertion of beid#135: after a write that would previously
  /// have replaced the undecodable file, its original bytes still exist
  /// somewhere in the directory, under a name that is not the canonical
  /// one.
  private func assertCorruptBytesSurvived(
    _ corruptBytes: Data,
    in directory: URL,
    canonicalFileURL: URL,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let survivors = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    .filter { $0 != canonicalFileURL }
    .filter { (try? Data(contentsOf: $0)) == corruptBytes }

    XCTAssertEqual(
      survivors.count,
      1,
      "the bytes that failed to decode must survive a later write",
      file: file,
      line: line
    )
    guard let quarantinedURL = survivors.first else { return }
    XCTAssertTrue(
      quarantinedURL.lastPathComponent.contains(".corrupt-"),
      "quarantined at an unexpected name: \(quarantinedURL.lastPathComponent)",
      file: file,
      line: line
    )
  }

  private func makeBindingRecord() -> BindingRecord {
    BindingRecord(
      proofId: UUID(),
      eventCode: "TEST-EVENT",
      walletAddress: "0x0000000000000000000000000000000000000001",
      eventSigningPublicKey: Data(repeating: 0x02, count: 33),
      ownerPublicKey: Data(repeating: 0x03, count: 33),
      chainId: 1,
      nonce: Data(repeating: 0x04, count: 16),
      issuedAt: "2026-01-01T00:00:00Z",
      walletSignatureHex: String(repeating: "0a", count: 65),
      deviceSignature: BarnardCoreRecoverableSignature(
        r: [UInt8](repeating: 1, count: 32),
        s: [UInt8](repeating: 2, count: 32),
        v: 0
      )
    )
  }

  private func makeSelfProofRecord() -> SelfProofRecord {
    SelfProofRecord(
      proofId: UUID(),
      eventCode: "TEST-EVENT",
      eventIdHash: Data(repeating: 0xAB, count: 32),
      eventSigningPublicKey: Data(repeating: 0x02, count: 33),
      eninStart: 100,
      eninEnd: 200,
      ownerPublicKey: Data(repeating: 0x03, count: 33),
      signature: BarnardCoreRecoverableSignature(
        r: [UInt8](repeating: 1, count: 32),
        s: [UInt8](repeating: 2, count: 32),
        v: 0
      )
    )
  }
}
