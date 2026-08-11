// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

@MainActor
final class ProofSignatureTests: XCTestCase {
  private func makeTempFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("proofs-signature-test-\(UUID().uuidString).json")
  }

  func testDefaultSignatureStateIsNotRequested() {
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
    XCTAssertEqual(proof.signatureState, .notRequested)
  }

  func testUpdateSignatureStatePersistsAcrossReload() {
    let fileURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = ProofStore(fileURL: fileURL)
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
    store.add(proof)

    store.updateSignatureState(for: proof.id, to: .rejected)
    XCTAssertEqual(store.proof(withId: proof.id)?.signatureState, .rejected)

    let reloaded = ProofStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.proof(withId: proof.id)?.signatureState, .rejected)
  }

  func testLoadingStoreSanitizesStrandedAwaitingApprovalToDeferred() {
    // Simulates the process being killed while `.awaitingApproval` was
    // persisted (e.g. jetsam while the user backgrounded the app to
    // approve in their wallet — the flow's own prime scenario). Without
    // sanitizing on load, this proof would spin forever with no retry
    // affordance on next launch.
    let fileURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = ProofStore(fileURL: fileURL)
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
    store.add(proof)
    store.updateSignatureState(for: proof.id, to: .awaitingApproval)

    let reloaded = ProofStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.proof(withId: proof.id)?.signatureState, .deferred)
  }

  func testLoadingStoreSanitizesStrandedConnectingToDeferred() {
    let fileURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = ProofStore(fileURL: fileURL)
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
    store.add(proof)
    store.updateSignatureState(for: proof.id, to: .connecting)

    let reloaded = ProofStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.proof(withId: proof.id)?.signatureState, .deferred)
  }

  func testUpdateSignatureStateIsNoOpForUnknownProof() {
    let fileURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = ProofStore(fileURL: fileURL)
    store.updateSignatureState(for: UUID(), to: .rejected)
    XCTAssertTrue(store.proofs.isEmpty)
  }

  func testDecodingProofWithoutSignatureStateKeyDefaultsToNotRequested() throws {
    // Simulates a proof persisted before `signatureState` existed, so
    // ProofStore.load() (broad `try?`) doesn't silently discard every
    // previously stored proof on the first launch after this feature ships.
    let legacyJSON = """
    {
      "id": "\(UUID().uuidString)",
      "eventName": "ETHGlobal Tokyo",
      "date": \(Date().timeIntervalSinceReferenceDate),
      "method": "Bluetooth Sensing",
      "peersVerified": 3,
      "gradientSeed": 42
    }
    """
    let decoder = JSONDecoder()
    let proof = try decoder.decode(Proof.self, from: Data(legacyJSON.utf8))
    XCTAssertEqual(proof.signatureState, .notRequested)
  }

  func testSignaturePayloadHashIsStableForSameProof() {
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
    let issuedAt = Date()
    let payloadA = SignaturePayload(proof: proof, chainId: "eip155:1", issuedAt: issuedAt)
    let payloadB = SignaturePayload(proof: proof, chainId: "eip155:1", issuedAt: issuedAt)
    XCTAssertEqual(payloadA.proofHash, payloadB.proofHash)
  }

  func testSignaturePayloadNonceDiffersBetweenAttempts() {
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
    let payloadA = SignaturePayload(proof: proof, chainId: "eip155:1")
    let payloadB = SignaturePayload(proof: proof, chainId: "eip155:1")
    XCTAssertNotEqual(payloadA.nonce, payloadB.nonce)
  }

  func testSigningDigestChangesWhenNonceDiffers() throws {
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
    let issuedAt = Date()
    let payloadA = SignaturePayload(proof: proof, chainId: "eip155:1", issuedAt: issuedAt)
    let payloadB = SignaturePayload(proof: proof, chainId: "eip155:1", issuedAt: issuedAt)
    let digestA = try payloadA.signingDigestHex()
    let digestB = try payloadB.signingDigestHex()
    XCTAssertNotEqual(digestA, digestB, "distinct nonces must produce distinct signing digests")
  }

  func testSigningDigestIsHexPrefixed() throws {
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
    let payload = SignaturePayload(proof: proof, chainId: "eip155:1")
    let digest = try payload.signingDigestHex()
    XCTAssertTrue(digest.hasPrefix("0x"))
    XCTAssertEqual(digest.count, 66) // "0x" + 64 hex chars (SHA-256)
  }

  func testProofWithSignedStateRoundTripsThroughCodable() throws {
    let proof = Proof(eventName: "ETHGlobal Tokyo", date: Date(), peersVerified: 3)
    let payload = SignaturePayload(proof: proof, chainId: "eip155:1")
    var signedProof = proof
    signedProof.signatureState = .signed(SignatureRecord(
      signerAddress: "0xabc",
      signatureHex: "0xdeadbeef",
      payload: payload,
      signedAt: Date()
    ))

    let data = try JSONEncoder().encode(signedProof)
    let decoded = try JSONDecoder().decode(Proof.self, from: data)
    XCTAssertEqual(decoded.signatureState, signedProof.signatureState)
  }
}
