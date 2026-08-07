// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import Foundation
import XCTest
@testable import Beid

final class SensingCryptographyTests: XCTestCase {
  private func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  func testBarnardFacadeForwardsDistinctSelfProofRange() throws {
    let cryptography = BarnardSensingCryptography()
    let eventCode = "FACADE-SELF-PROOF"
    let eventIdHash = EventIdHash.compute(eventCode: eventCode)
    let eventSigningPublicKey = Data([
      0x02, 0xc6, 0x04, 0x7f, 0x94, 0x41, 0xed, 0x7d,
      0x6d, 0x30, 0x45, 0x40, 0x6e, 0x95, 0xc0, 0x7c,
      0xd8, 0x5c, 0x77, 0x8e, 0x4b, 0x8c, 0xef, 0x3c,
      0xa7, 0xab, 0xac, 0x09, 0xb9, 0x5c, 0x70, 0x9e, 0xe5,
    ])
    let ownerPublicKey = cryptography.ownerPublicKey()
    let eninStart: UInt64 = 1
    let eninEnd = UInt64(BeidConfig.eventConfirmThreshold + 1)

    let signature = try XCTUnwrap(
      cryptography.signSelfProof(
        eventIdHash: eventIdHash,
        eventSigningPublicKey: eventSigningPublicKey,
        eninStart: eninStart,
        eninEnd: eninEnd
      )
    )

    XCTAssertTrue(
      BarnardCoreSigning.verifySelfProof(
        eventIdHash: Array(eventIdHash),
        eventSigningPublicKey: Array(eventSigningPublicKey),
        eninStart: eninStart,
        eninEnd: eninEnd,
        ownerPublicKey: Array(ownerPublicKey),
        signature: BarnardCoreRecoverableSignature(
          r: Array(signature.r),
          s: Array(signature.s),
          v: signature.v
        )
      )
    )
  }

  @MainActor
  func testCoordinatorOwnsOnlyTheSensingCryptographyFacade() {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    let storedPropertyNames = Set(
      Mirror(reflecting: coordinator).children.compactMap(\.label)
    )

    XCTAssertTrue(
      storedPropertyNames.contains("sensingCryptography"),
      "SensingCoordinator must own one injectable cryptography facade"
    )
    XCTAssertFalse(
      storedPropertyNames.contains("identity"),
      "SensingCoordinator must not retain BarnardIdentity beside the facade"
    )
    XCTAssertFalse(
      storedPropertyNames.contains("ownerKeyProvider"),
      "SensingCoordinator must not retain OwnerKeyProvider beside the facade"
    )
  }

  @MainActor
  func testCoordinatorRoutesBindingAndSelfProofCryptographyThroughInjectedFacade() async {
    let eventSigningPublicKey = Data([0x02] + [UInt8](repeating: 0xa1, count: 32))
    let ownerPublicKey = Data([
      0x02, 0x79, 0xbe, 0x66, 0x7e, 0xf9, 0xdc, 0xbb,
      0xac, 0x55, 0xa0, 0x62, 0x95, 0xce, 0x87, 0x0b,
      0x07, 0x02, 0x9b, 0xfc, 0xdb, 0x2d, 0xce, 0x28,
      0xd9, 0x59, 0xf2, 0x81, 0x5b, 0x16, 0xf8, 0x17,
      0x98,
    ])
    let selfProofSignature = SensingRecoverableSignature(
      r: Data([0x00] + [UInt8](repeating: 0xc3, count: 31)),
      s: Data([0x00, 0x00] + [UInt8](repeating: 0xd4, count: 30)),
      v: 3
    )
    let walletAcknowledgementSignature = SensingRecoverableSignature(
      r: Data([0x00] + [UInt8](repeating: 0xe5, count: 31)),
      s: Data([0x00, 0x00] + [UInt8](repeating: 0xf6, count: 30)),
      v: 2
    )
    let cryptography = DeterministicSensingCryptography(
      eventSigningPublicKey: eventSigningPublicKey,
      ownerPublicKey: ownerPublicKey,
      selfProofSignature: selfProofSignature,
      walletAcknowledgementSignature: walletAcknowledgementSignature
    )
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: cryptography
    )
    let event = EventSession(id: "FACADE-EVENT", name: "Facade Event", venue: nil)
    let walletAddress = "0x" + String(repeating: "12", count: 20)
    let walletSignatureHex = "0x" + String(repeating: "ab", count: 65)

    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    XCTAssertNotNil(coordinator.beginBinding(walletAddress: walletAddress, chainId: "eip155:1"))
    let bindingRecord = coordinator.completeBinding(
      walletAddress: walletAddress,
      walletSignatureHex: walletSignatureHex
    )
    let selfProofRecord = coordinator.reset()

    XCTAssertEqual(
      bindingRecord?.eventSigningPublicKeyHex,
      hexString(eventSigningPublicKey)
    )
    XCTAssertEqual(bindingRecord?.ownerPublicKeyHex, hexString(ownerPublicKey))
    XCTAssertEqual(
      bindingRecord?.deviceSignatureRHex,
      hexString(walletAcknowledgementSignature.r)
    )
    XCTAssertEqual(
      bindingRecord?.deviceSignatureSHex,
      hexString(walletAcknowledgementSignature.s)
    )
    XCTAssertEqual(bindingRecord?.deviceSignatureV, walletAcknowledgementSignature.v)
    XCTAssertEqual(
      selfProofRecord?.signatureRHex,
      hexString(selfProofSignature.r)
    )
    XCTAssertEqual(
      selfProofRecord?.signatureSHex,
      hexString(selfProofSignature.s)
    )
    XCTAssertEqual(selfProofRecord?.signatureV, selfProofSignature.v)

    XCTAssertEqual(
      cryptography.calls,
      [
        .eventSigningPublicKey(eventCode: event.id),
        .ownerPublicKey,
        .ownerPublicKey,
        .signWalletAcknowledgement(
          walletAddress: Data(repeating: 0x12, count: 20),
          walletSignature: Data(repeating: 0xab, count: 65)
        ),
        .eventSigningPublicKey(eventCode: event.id),
        .eventSigningPublicKey(eventCode: event.id),
        .ownerPublicKey,
        .signSelfProof(
          eventIdHash: EventIdHash.compute(eventCode: event.id),
          eventSigningPublicKey: eventSigningPublicKey,
          eninStart: 1,
          eninEnd: UInt64(BeidConfig.eventConfirmThreshold + 1)
        ),
      ]
    )
  }

  func testDeterministicFakeReturnsConfiguredValuesAndRecordsCallsInOrder() {
    let eventPublicKey = Data([0x02] + [UInt8](repeating: 0xa1, count: 32))
    let ownerPublicKey = Data([0x03] + [UInt8](repeating: 0xb2, count: 32))
    let windowSignature = SensingRecoverableSignature(
      r: Data(repeating: 0xc3, count: 32),
      s: Data(repeating: 0xd4, count: 32),
      v: 0
    )
    let selfProofSignature = SensingRecoverableSignature(
      r: Data(repeating: 0xe5, count: 32),
      s: Data(repeating: 0xf6, count: 32),
      v: 1
    )
    let walletAcknowledgementSignature = SensingRecoverableSignature(
      r: Data(repeating: 0x17, count: 32),
      s: Data(repeating: 0x28, count: 32),
      v: 0
    )
    let cryptography = DeterministicSensingCryptography(
      eventSigningPublicKey: eventPublicKey,
      ownerPublicKey: ownerPublicKey,
      windowReportSignature: windowSignature,
      selfProofSignature: selfProofSignature,
      walletAcknowledgementSignature: walletAcknowledgementSignature
    )
    let windowBytes = Data([0x01, 0x02])
    let eventIdHash = Data(repeating: 0x03, count: 32)
    let walletAddress = Data(repeating: 0x04, count: 20)
    let walletSignature = Data(repeating: 0x05, count: 65)

    XCTAssertEqual(cryptography.eventSigningPublicKey(eventCode: "EVENT-A"), eventPublicKey)
    XCTAssertEqual(cryptography.ownerPublicKey(), ownerPublicKey)
    XCTAssertEqual(
      cryptography.signWindowReport(eventCode: "EVENT-A", bytes: windowBytes),
      windowSignature
    )
    XCTAssertEqual(
      cryptography.signSelfProof(
        eventIdHash: eventIdHash,
        eventSigningPublicKey: eventPublicKey,
        eninStart: 41,
        eninEnd: 42
      ),
      selfProofSignature
    )
    XCTAssertEqual(
      cryptography.signWalletAcknowledgement(
        walletAddress: walletAddress,
        walletSignature: walletSignature
      ),
      walletAcknowledgementSignature
    )
    XCTAssertEqual(
      cryptography.calls,
      [
        .eventSigningPublicKey(eventCode: "EVENT-A"),
        .ownerPublicKey,
        .signWindowReport(eventCode: "EVENT-A", bytes: windowBytes),
        .signSelfProof(
          eventIdHash: eventIdHash,
          eventSigningPublicKey: eventPublicKey,
          eninStart: 41,
          eninEnd: 42
        ),
        .signWalletAcknowledgement(
          walletAddress: walletAddress,
          walletSignature: walletSignature
        ),
      ]
    )
  }

  func testDeterministicFakeCanReturnNilForOptionalOwnerSignatures() {
    let cryptography = DeterministicSensingCryptography(
      selfProofSignature: nil,
      walletAcknowledgementSignature: nil
    )

    XCTAssertNil(cryptography.signSelfProof(
      eventIdHash: Data(repeating: 0x01, count: 32),
      eventSigningPublicKey: Data([0x02] + [UInt8](repeating: 0x03, count: 32)),
      eninStart: 1,
      eninEnd: 2
    ))
    XCTAssertNil(cryptography.signWalletAcknowledgement(
      walletAddress: Data(repeating: 0x04, count: 20),
      walletSignature: Data(repeating: 0x05, count: 65)
    ))
  }

  func testSignatureValuePreservesLeadingZeroBytesAndRecoveryIDExactly() {
    let r = Data([0x00] + [UInt8](repeating: 0x11, count: 31))
    let s = Data([0x00, 0x00] + [UInt8](repeating: 0x22, count: 30))
    let signature = SensingRecoverableSignature(r: r, s: s, v: 3)

    XCTAssertEqual(signature.r, r)
    XCTAssertEqual(signature.s, s)
    XCTAssertEqual(signature.r.count, 32)
    XCTAssertEqual(signature.s.count, 32)
    XCTAssertEqual(signature.r.first, 0x00)
    XCTAssertEqual(signature.s.prefix(2), Data([0x00, 0x00]))
    XCTAssertEqual(signature.v, 3, "the facade must not normalize the raw recovery id")
  }

  func testBarnardCoreMappingPreservesWidthLeadingZeroesAndRecoveryID() {
    let r = [UInt8(0x00)] + [UInt8](repeating: 0x31, count: 31)
    let s = [UInt8(0x00), UInt8(0x00)] + [UInt8](repeating: 0x42, count: 30)
    let barnardSignature = BarnardCoreRecoverableSignature(r: r, s: s, v: 3)

    let mapped = SensingRecoverableSignature(barnardCore: barnardSignature)

    XCTAssertEqual(mapped.r, Data(r))
    XCTAssertEqual(mapped.s, Data(s))
    XCTAssertEqual(mapped.r.count, 32)
    XCTAssertEqual(mapped.s.count, 32)
    XCTAssertEqual(mapped.v, 3)
  }
}
