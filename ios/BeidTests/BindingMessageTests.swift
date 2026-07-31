// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

final class BindingMessageTests: XCTestCase {
  private let sampleKey = Data([0x02] + Array(repeating: 0xAB, count: 32))
  private let sampleIssuedAt = Date(timeIntervalSince1970: 1_800_000_000)

  func testCanonicalBytesAreDeterministicForIdenticalInputs() {
    let a = BindingMessage(eventCode: "ETHTOKYO2026", eventSigningPublicKey: sampleKey, issuedAt: sampleIssuedAt)
    let b = BindingMessage(eventCode: "ETHTOKYO2026", eventSigningPublicKey: sampleKey, issuedAt: sampleIssuedAt)

    XCTAssertEqual(a.canonicalBytes, b.canonicalBytes)
    XCTAssertEqual(a.walletDigestHex(), b.walletDigestHex())
  }

  func testCanonicalBytesChangeWithEventCode() {
    let a = BindingMessage(eventCode: "EVENT-A", eventSigningPublicKey: sampleKey, issuedAt: sampleIssuedAt)
    let b = BindingMessage(eventCode: "EVENT-B", eventSigningPublicKey: sampleKey, issuedAt: sampleIssuedAt)

    XCTAssertNotEqual(a.canonicalBytes, b.canonicalBytes)
    XCTAssertNotEqual(a.walletDigestHex(), b.walletDigestHex())
  }

  func testCanonicalBytesChangeWithSigningPublicKey() {
    let otherKey = Data([0x03] + Array(repeating: 0xCD, count: 32))
    let a = BindingMessage(eventCode: "EVENT-A", eventSigningPublicKey: sampleKey, issuedAt: sampleIssuedAt)
    let b = BindingMessage(eventCode: "EVENT-A", eventSigningPublicKey: otherKey, issuedAt: sampleIssuedAt)

    XCTAssertNotEqual(a.canonicalBytes, b.canonicalBytes)
  }

  func testCanonicalBytesChangeWithIssuedAt() {
    let a = BindingMessage(eventCode: "EVENT-A", eventSigningPublicKey: sampleKey, issuedAt: sampleIssuedAt)
    let b = BindingMessage(eventCode: "EVENT-A", eventSigningPublicKey: sampleKey, issuedAt: sampleIssuedAt.addingTimeInterval(1))

    XCTAssertNotEqual(a.canonicalBytes, b.canonicalBytes, "the verifiable timestamp must be covered by the signed bytes")
  }

  func testCanonicalBytesEmbedEventCodeAndSigningPublicKeyVerbatim() {
    let message = BindingMessage(eventCode: "EVENT-A", eventSigningPublicKey: sampleKey, issuedAt: sampleIssuedAt)
    let bytes = message.canonicalBytes

    XCTAssertNotNil(bytes.range(of: Data("EVENT-A".utf8)), "eventCode must appear verbatim in the signed bytes")
    XCTAssertNotNil(bytes.range(of: sampleKey), "the per-event signing public key must appear verbatim in the signed bytes")
  }

  func testWalletDigestHexIsZeroXPrefixedSha256Hex() {
    let message = BindingMessage(eventCode: "EVENT-A", eventSigningPublicKey: sampleKey, issuedAt: sampleIssuedAt)
    let digest = message.walletDigestHex()

    XCTAssertTrue(digest.hasPrefix("0x"))
    XCTAssertEqual(digest.count, 2 + 64, "0x + 32-byte SHA-256 hex digest")
    XCTAssertTrue(digest.dropFirst(2).allSatisfy(\.isHexDigit))
  }
}
