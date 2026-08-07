// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import XCTest
@testable import Beid

/// `EventIdHash` is beid's own construction choice
/// (`docs/specs/barnard-binding-conformance.md` §2.2's recommendation,
/// `SHA256(UTF8(eventCode))`) — not something Barnard pins, so this asserts
/// against the standard NIST SHA-256 test vectors (FIPS 180-4), an
/// independent primary source, not beid's own re-derivation.
final class EventIdHashTests: XCTestCase {
  func testComputeMatchesNistSha256EmptyStringVector() {
    XCTAssertEqual(
      EventIdHash.compute(eventCode: "").hexString,
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
  }

  func testComputeMatchesNistSha256AbcVector() {
    XCTAssertEqual(
      EventIdHash.compute(eventCode: "abc").hexString,
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
  }
}

/// Golden-vector conformance for the self-proof message's 135-byte layout
/// against Barnard's own pinned offsets
/// (`BarnardOwnerKeyMessageTests.testSelfProofBuilderSignerAndVerifier`,
/// `levarac/barnard` v0.3.0, read directly from source). Calls
/// `BarnardCoreSigning.buildSelfProofMessage` directly (Barnard's own
/// function, not beid's re-derivation of the same bytes) with the exact
/// literal inputs Barnard's own suite uses, per
/// `docs/specs/barnard-binding-conformance.md` §5 — a self-consistency test
/// here would prove nothing.
final class SelfProofMessageLayoutTests: XCTestCase {
  /// `eventHash` in Barnard's own test: `(0x00...0x1f).map(UInt8.init)`.
  private let eventIdHash = (0x00...0x1f).map(UInt8.init)
  /// `compressedPublicKey(privateKey: scalarTwo)` in Barnard's own test
  /// (`scalarTwo` = private key `2`) — independently cross-validated this
  /// session against Barnard's own pinned `generatorCompressed` constant
  /// using a standard secp256k1 implementation (not Barnard's/beid's code):
  /// both computed `02` + generator-x `79be66...f81798` for private key
  /// `1`, confirming the same curve parameterization, before deriving
  /// `2 * G` the same way for private key `2`.
  private let eventSigningPublicKey = bytesFromHex(
    "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
  )
  /// Barnard's own pinned `generatorCompressed` constant, used as
  /// `ownerPublicKey` in Barnard's `testSelfProofBuilderSignerAndVerifier`.
  private let ownerPublicKey = bytesFromHex(
    "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
  )

  func testSelfProofMessageLayoutMatchesBarnardPinnedOffsets() throws {
    let message = try XCTUnwrap(
      BarnardCoreSigning.buildSelfProofMessage(
        eventIdHash: eventIdHash,
        eventSigningPublicKey: eventSigningPublicKey,
        eninStart: 0x0102_0304_0506_0708,
        eninEnd: 0x1112_1314_1516_1718,
        ownerPublicKey: ownerPublicKey
      )
    )

    XCTAssertEqual(message.count, 135)
    XCTAssertEqual(Array(message.prefix(21)), Array("barnard-self-proof:v1".utf8))
    XCTAssertEqual(Array(message[21..<53]), eventIdHash)
    XCTAssertEqual(Array(message[53..<86]), eventSigningPublicKey)
    XCTAssertEqual(
      Array(message[86..<102]),
      bytesFromHex("01020304050607081112131415161718")
    )
    XCTAssertEqual(Array(message[102..<135]), ownerPublicKey)
  }
}

/// Proves `OwnerKeyProvider.signSelfProof` (beid's own code, already shipped
/// in sub-slice A) produces a signature Barnard's own `verifySelfProof`
/// accepts — not a beid-only round trip (`verifySelfProof` is Barnard's
/// implementation, called directly, never beid's re-derivation of
/// verification logic).
final class OwnerKeyProviderSelfProofTests: XCTestCase {
  /// Same sequential-byte seed `OwnerKeyProviderTests` already pins against
  /// Barnard's `deriveOwnerKeyPair` golden vector — public key
  /// `03879beac8b548009124867a99a358aeb34ff42f957f868bbc83339568b16d9c67`.
  private let ownerPublicKey = bytesFromHex(
    "03879beac8b548009124867a99a358aeb34ff42f957f868bbc83339568b16d9c67"
  )
  private let eventIdHash = Data(repeating: 0xAB, count: 32)
  private let eventSigningPublicKey = bytesFromHex(
    "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
  )

  func testSignSelfProofProducesABarnardVerifiableSignature() throws {
    let provider = OwnerKeyProvider(
      keyStorage: FixedSeedKeyStorage(seed: Data((0..<32).map(UInt8.init))),
      randomSource: NeverCalledRandomSource()
    )

    let signature = try XCTUnwrap(
      provider.signSelfProof(
        eventIdHash: eventIdHash,
        eventSigningPublicKey: Data(eventSigningPublicKey),
        eninStart: 100,
        eninEnd: 200
      )
    )

    XCTAssertTrue(
      BarnardCoreSigning.verifySelfProof(
        eventIdHash: Array(eventIdHash),
        eventSigningPublicKey: eventSigningPublicKey,
        eninStart: 100,
        eninEnd: 200,
        ownerPublicKey: ownerPublicKey,
        signature: signature
      )
    )
  }

  func testSignSelfProofSignatureFailsVerificationForATamperedEninRange() throws {
    let provider = OwnerKeyProvider(
      keyStorage: FixedSeedKeyStorage(seed: Data((0..<32).map(UInt8.init))),
      randomSource: NeverCalledRandomSource()
    )

    let signature = try XCTUnwrap(
      provider.signSelfProof(
        eventIdHash: eventIdHash,
        eventSigningPublicKey: Data(eventSigningPublicKey),
        eninStart: 100,
        eninEnd: 200
      )
    )

    XCTAssertFalse(
      BarnardCoreSigning.verifySelfProof(
        eventIdHash: Array(eventIdHash),
        eventSigningPublicKey: eventSigningPublicKey,
        eninStart: 100,
        eninEnd: 201,
        ownerPublicKey: ownerPublicKey,
        signature: signature
      )
    )
  }
}

final class SelfProofRecordTests: XCTestCase {
  func testSelfProofRecordRoundTripsThroughCodable() throws {
    let record = SelfProofRecord(
      proofId: UUID(),
      eventCode: "TEST-EVENT",
      eventIdHash: Data(repeating: 0xAB, count: 32),
      eventSigningPublicKey: Data(bytesFromHex(
        "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
      )),
      eninStart: 100,
      eninEnd: 200,
      ownerPublicKey: Data(bytesFromHex(
        "03879beac8b548009124867a99a358aeb34ff42f957f868bbc83339568b16d9c67"
      )),
      signature: BarnardCoreRecoverableSignature(
        r: [UInt8](repeating: 1, count: 32),
        s: [UInt8](repeating: 2, count: 32),
        v: 0
      )
    )

    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(SelfProofRecord.self, from: data)

    XCTAssertEqual(decoded, record)
  }
}

/// `SensingCoordinator` session-lifecycle wiring: signed once per event, at
/// session end, never mid-session
/// (`docs/specs/barnard-binding-conformance.md` §7.2).
@MainActor
final class SensingCoordinatorSelfProofTests: XCTestCase {
  func testStopSensingReturnsNilWhenNoSessionEverStarted() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    XCTAssertNil(coordinator.stopSensing(), "no Proof, no ENIN window — nothing to attest")
  }

  func testSelfProofIsProducedOnlyWhenSessionEndsAfterRecordingBegan() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    let event = EventSession(id: "TEST-SELF-PROOF", name: "Test Self Proof", venue: nil)
    var collectedProof: Proof?
    coordinator.onProofCollected = { collectedProof = $0 }

    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording phase before session end")
      return
    }

    let record = coordinator.stopSensing()

    guard let record else {
      XCTFail("expected a SelfProofRecord once the session ends with a Proof and an observed ENIN window")
      return
    }
    XCTAssertEqual(record.eventCode, event.id)
    XCTAssertEqual(record.proofId, collectedProof?.id)
    XCTAssertLessThanOrEqual(record.eninStart, record.eninEnd)
    XCTAssertFalse(record.eventSigningPublicKeyHex.isEmpty)
    XCTAssertFalse(record.ownerPublicKeyHex.isEmpty)
    XCTAssertFalse(record.signatureRHex.isEmpty)
    XCTAssertEqual(coordinator.phase, .idle, "session ended")
  }

  func testResetAfterASelfProofIsProducedDoesNotProduceASecondOne() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.runDemoSequence(demoEvent: .demoSample, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertNotNil(coordinator.stopSensing())
    XCTAssertNil(coordinator.reset(), "session state was already cleared by stopSensing()")
  }
}

private func bytesFromHex(_ hex: String) -> [UInt8] {
  stride(from: 0, to: hex.count, by: 2).map { offset in
    let start = hex.index(hex.startIndex, offsetBy: offset)
    let end = hex.index(start, offsetBy: 2)
    return UInt8(hex[start..<end], radix: 16)!
  }
}

private extension Data {
  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

private struct FixedSeedKeyStorage: BarnardCoreKeyStorage {
  let seed: Data

  func bytes(forKey key: String) -> [UInt8]? {
    Array(seed)
  }

  func setBytes(_ bytes: [UInt8], forKey key: String) {}
}

private struct NeverCalledRandomSource: BarnardCoreRandomSource {
  func randomBytes(count: Int) -> [UInt8] {
    XCTFail("randomSource must not be used when a seed is already stored")
    return [UInt8](repeating: 0, count: count)
  }
}
