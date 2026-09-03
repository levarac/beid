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

    XCTAssertNotEqual(eninStart, eninEnd, "This test's guarantee rests on these two values differing. If they're equal, a swap or duplication becomes a no-op and the test passes while verifying nothing.")

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

  func testBarnardFacadeForwardsWalletAcknowledgementInputs() throws {
    let cryptography = BarnardSensingCryptography()
    let ownerPublicKey = cryptography.ownerPublicKey()
    let walletAddress = Data((0x20...0x33).map(UInt8.init))
    let walletSignature = Data((0x40...0x80).map(UInt8.init))

    let signature = try XCTUnwrap(
      cryptography.signWalletAcknowledgement(
        walletAddress: walletAddress,
        walletSignature: walletSignature
      )
    )

    XCTAssertTrue(
      BarnardCoreSigning.verifyWalletAcknowledgement(
        ownerPublicKey: Array(ownerPublicKey),
        walletAddress: Array(walletAddress),
        walletSignature: Array(walletSignature),
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

  /// beid#316: `completeBinding` now verifies the wallet ack signature for
  /// real (piece b, delegated to `BarnardCoreSigning.verifyWalletBinding`),
  /// so the injected `ownerPublicKey`/acknowledgement and the wallet
  /// address/signature below must be genuinely consistent with each
  /// other — arbitrary fabricated bytes (this test's shape before #316)
  /// would now make `completeBinding` correctly reject the record, which
  /// would defeat this test's actual purpose (proving the facade's return
  /// values route into the persisted records and self-proof unmodified).
  /// The wallet signature itself can only be computed after `beginBinding`
  /// returns (it embeds a runtime nonce/timestamp this test doesn't
  /// control), and the acknowledgement `DeterministicSensingCryptography`
  /// must return depends on that wallet signature's exact bytes — hence
  /// `walletAcknowledgementSignatureResult` is set post-construction rather
  /// than through `init` like this double's other injected results.
  @MainActor
  func testCoordinatorRoutesBindingAndSelfProofCryptographyThroughInjectedFacade() async {
    let eventSigningPublicKey = Data([0x02] + [UInt8](repeating: 0xa1, count: 32))
    let ownerKeyPair = BarnardCoreSigning.deriveOwnerKeyPair(
      accountSecret: [UInt8](repeating: 0x31, count: 32)
    )
    let ownerPublicKey = Data(ownerKeyPair.publicKeyCompressed)
    // Independent synthetic wallet keypair — not the owner key above.
    let walletKeyPair = BarnardCoreSigning.deriveOwnerKeyPair(
      accountSecret: [UInt8](repeating: 0x32, count: 32)
    )
    guard
      let walletAddressBytes = BarnardCoreSigning.ethereumAddress(
        publicKeyCompressed: walletKeyPair.publicKeyCompressed
      )
    else {
      XCTFail("expected walletKeyPair to yield a valid Ethereum address")
      return
    }
    let walletAddress = "0x" + walletAddressBytes.map { String(format: "%02x", $0) }.joined()
    let selfProofSignature = SensingRecoverableSignature(
      r: Data([0x00] + [UInt8](repeating: 0xc3, count: 31)),
      s: Data([0x00, 0x00] + [UInt8](repeating: 0xd4, count: 30)),
      v: 3
    )
    let cryptography = DeterministicSensingCryptography(
      eventSigningPublicKey: eventSigningPublicKey,
      ownerPublicKey: ownerPublicKey,
      selfProofSignature: selfProofSignature
    )
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: cryptography
    )
    let event = EventSession(id: "FACADE-EVENT", name: "Facade Event", venue: nil)

    coordinator.runDemoSequence(demoEvent: event, stepDelayNanos: 0)
    await coordinator.waitForDemoSequenceToFinish()
    guard let messageHex = coordinator.beginBinding(walletAddress: walletAddress, chainId: "eip155:1") else {
      XCTFail("expected beginBinding to succeed")
      return
    }

    let walletSignatureBytes = Self.signEip191(messageHex: messageHex, privateKey: walletKeyPair.privateKey)
    let walletSignatureHex = "0x" + walletSignatureBytes.map { String(format: "%02x", $0) }.joined()

    guard
      let acknowledgement = BarnardCoreSigning.signWalletAcknowledgement(
        ownerPrivateKey: ownerKeyPair.privateKey,
        walletAddress: walletAddressBytes,
        walletSignature: walletSignatureBytes
      )
    else {
      XCTFail("expected a valid wallet acknowledgement signature")
      return
    }
    let walletAcknowledgementSignature = SensingRecoverableSignature(barnardCore: acknowledgement)
    cryptography.walletAcknowledgementSignatureResult = walletAcknowledgementSignature

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
          walletAddress: Data(walletAddressBytes),
          walletSignature: Data(walletSignatureBytes)
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

  private static func signEip191(messageHex: String, privateKey: [UInt8]) -> [UInt8] {
    let digest = BarnardCoreSigning.computeEip191Digest(messageBytes: decodeHex(messageHex))
    let signature = BarnardCoreSigning.signRecoverable(privateKey: privateKey, messageHash32: digest)
    return signature.r + signature.s + [UInt8(signature.v)]
  }

  private static func decodeHex(_ string: String) -> [UInt8] {
    let stripped = string.hasPrefix("0x") || string.hasPrefix("0X")
      ? String(string.dropFirst(2))
      : string
    var bytes = [UInt8]()
    bytes.reserveCapacity(stripped.count / 2)
    var index = stripped.startIndex
    while index < stripped.endIndex {
      let next = stripped.index(index, offsetBy: 2)
      guard let byte = UInt8(stripped[index..<next], radix: 16) else {
        preconditionFailure("messageHex must be well-formed hex")
      }
      bytes.append(byte)
      index = next
    }
    return bytes
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
