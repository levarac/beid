// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BarnardCore
import XCTest
@testable import Beid

/// Golden-vector conformance tests for `BindingMessage`
/// (`docs/specs/barnard-binding-conformance.md` §2.3, §5, §7.3). The pinned
/// inputs/outputs below are read directly from `levarac/barnard` v0.3.0's
/// own test suite
/// (`BarnardOwnerKeyMessageTests.testCanonicalBindingTextMatchesPinnedBytesAndDigest`,
/// revision `57a8a7df7f4b2078150eabff4c06a46cfb2aae0f`) — this asserts
/// beid's new type produces what Barnard's own suite independently
/// expects, not that beid's implementation is self-consistent (§5's
/// explicit failure mode: a test that only checks beid against itself
/// proves nothing about conformance).
final class BindingMessageTests: XCTestCase {
  private let pinnedWalletAddress = bytes("14791697260e4c9a71f18484c9f997b308e59325")
  private let pinnedOwnerPublicKey = bytes(
    "03879beac8b548009124867a99a358aeb34ff42f957f868bbc83339568b16d9c67"
  )
  private let pinnedNonce = bytes("000102030405060708090a0b0c0d0e0f")
  private let pinnedIssuedAt = "2026-07-30T09:00:00Z"
  private let pinnedText = """
    beid.levarac.org wants to bind this wallet to a Levarac owner key.

    This signature authorizes no transaction and moves no assets.

    Domain-Tag: barnard-account-binding:v1
    Wallet: 0x14791697260e4c9a71f18484c9f997b308e59325
    Owner-Key: 0x03879beac8b548009124867a99a358aeb34ff42f957f868bbc83339568b16d9c67
    Chain-ID: eip155:1
    Scope: global
    Nonce: 0x000102030405060708090a0b0c0d0e0f
    Issued-At: 2026-07-30T09:00:00Z
    """
  private let pinnedEip191DigestHex =
    "1aad6c43694a0e64bf3994959907b7392a590a1e7139bc9f52a86dc71709dc44"

  private func pinnedMessage() -> BindingMessage {
    BindingMessage(
      walletAddress: pinnedWalletAddress,
      ownerPublicKey: pinnedOwnerPublicKey,
      chainId: 1,
      nonce: pinnedNonce,
      issuedAt: pinnedIssuedAt
    )
  }

  func testCanonicalTextMatchesBarnardsPinnedGoldenVector() throws {
    let text = try XCTUnwrap(pinnedMessage().canonicalText())

    XCTAssertEqual(text, pinnedText)
    XCTAssertEqual(Array(text.utf8).count, 407, "Barnard's own pinned vector is exactly 407 UTF-8 bytes")
    XCTAssertFalse(text.hasSuffix("\n"))
  }

  func testEip191DigestMatchesBarnardsPinnedGoldenVector() throws {
    let text = try XCTUnwrap(pinnedMessage().canonicalText())
    let digest = BarnardCoreSigning.computeEip191Digest(text: text)

    XCTAssertEqual(hexString(digest), pinnedEip191DigestHex)
  }

  func testWalletMessageHexCarriesTextBytesNotADigest() throws {
    // The mechanical consequence §2.3 calls out: `personal_sign`'s message
    // parameter must carry the ~400 raw text bytes, not a 32-byte digest —
    // the existing call shape (an opaque 0x-hex string) doesn't change,
    // only what the hex decodes to.
    let messageHex = try XCTUnwrap(pinnedMessage().walletMessageHex())

    XCTAssertTrue(messageHex.hasPrefix("0x"))
    let decoded = try XCTUnwrap(Data(testHexEncoded: messageHex))
    XCTAssertEqual(
      decoded.count,
      407,
      "must carry the canonical text's raw UTF-8 bytes, not a 32-byte SHA-256 digest"
    )
    XCTAssertEqual(String(decoding: decoded, as: UTF8.self), pinnedText)
  }

  func testCanonicalTextChangesWithNonceAndIssuedAt() {
    let a = pinnedMessage()
    let b = BindingMessage(
      walletAddress: pinnedWalletAddress,
      ownerPublicKey: pinnedOwnerPublicKey,
      chainId: 1,
      nonce: bytes("100102030405060708090a0b0c0d0e0f"),
      issuedAt: pinnedIssuedAt
    )
    let c = BindingMessage(
      walletAddress: pinnedWalletAddress,
      ownerPublicKey: pinnedOwnerPublicKey,
      chainId: 1,
      nonce: pinnedNonce,
      issuedAt: "2026-07-30T09:00:01Z"
    )

    XCTAssertNotEqual(a.canonicalText(), b.canonicalText(), "nonce must be covered by the signed text")
    XCTAssertNotEqual(a.canonicalText(), c.canonicalText(), "issuedAt must be covered by the signed text")
  }

  func testCanonicalTextRejectsWalletAddressOfTheWrongLength() {
    let message = BindingMessage(
      walletAddress: pinnedWalletAddress.dropLast(),
      ownerPublicKey: pinnedOwnerPublicKey,
      chainId: 1,
      nonce: pinnedNonce,
      issuedAt: pinnedIssuedAt
    )

    XCTAssertNil(message.canonicalText(), "Barnard's own shape validation must reject a non-20-byte wallet address")
  }

  func testCanonicalIssuedAtFormatsSecondPrecisionUtc() {
    // 2026-07-30T09:00:00Z (Unix 1785402000), matching the golden vector's
    // own Issued-At — beid's own Date-formatting logic, not part of
    // Barnard's pinned vector, so a direct assertion here (unlike the
    // conformance tests above) is appropriate.
    let date = Date(timeIntervalSince1970: 1_785_402_000)

    XCTAssertEqual(BindingMessage.canonicalIssuedAt(date), pinnedIssuedAt)
  }
}

private func bytes(_ hex: String) -> Data {
  Data(stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
    let start = hex.index(hex.startIndex, offsetBy: offset)
    let end = hex.index(start, offsetBy: 2)
    return UInt8(hex[start..<end], radix: 16)!
  })
}

private func hexString(_ bytes: [UInt8]) -> String {
  bytes.map {
    let value = String($0, radix: 16)
    return value.count == 1 ? "0" + value : value
  }.joined()
}

private extension Data {
  init?(testHexEncoded string: String) {
    let stripped = string.hasPrefix("0x") || string.hasPrefix("0X")
      ? String(string.dropFirst(2))
      : string
    guard stripped.count.isMultiple(of: 2) else { return nil }
    var decoded = [UInt8]()
    decoded.reserveCapacity(stripped.count / 2)
    var index = stripped.startIndex
    while index < stripped.endIndex {
      let next = stripped.index(index, offsetBy: 2)
      guard let byte = UInt8(stripped[index..<next], radix: 16) else { return nil }
      decoded.append(byte)
      index = next
    }
    self = Data(decoded)
  }
}
