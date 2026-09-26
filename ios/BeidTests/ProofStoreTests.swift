// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

@MainActor
final class ProofStoreTests: XCTestCase {
  private func makeTempFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("proofs-test-\(UUID().uuidString).json")
  }

  func testAddPersistsAndReloadsRoundTrip() {
    let fileURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = ProofStore(fileURL: fileURL)
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
    store.add(proof)

    XCTAssertEqual(store.proofs.count, 1)

    let reloaded = ProofStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.proofs.count, 1)
    XCTAssertEqual(reloaded.proofs.first?.eventName, "ETHGlobal Tokyo")
    XCTAssertEqual(reloaded.proofs.first?.id, proof.id)
  }

  func testNewestProofIsFirst() {
    let fileURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = ProofStore(fileURL: fileURL)
    let first = Proof(eventName: "Event A", date: Date(), peersVerified: 1)
    let second = Proof(eventName: "Event B", date: Date(), peersVerified: 2)
    store.add(first)
    store.add(second)

    XCTAssertEqual(store.proofs.map(\.eventName), ["Event B", "Event A"])
  }

  func testEmptyStoreLoadsWithNoFile() {
    let fileURL = makeTempFileURL()
    let store = ProofStore(fileURL: fileURL)
    XCTAssertTrue(store.proofs.isEmpty)
  }
}
