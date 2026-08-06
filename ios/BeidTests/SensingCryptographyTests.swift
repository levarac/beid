// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import Foundation
import XCTest
@testable import Beid

final class SensingCryptographyTests: XCTestCase {
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
