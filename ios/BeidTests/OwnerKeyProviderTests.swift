// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import XCTest
@testable import Beid

/// Golden-vector conformance for `OwnerKeyProvider.publicKeyCompressed()`
/// against Barnard's own pinned `deriveOwnerKeyPair` test vectors
/// (`BarnardOwnerKeyPrimitiveTests.testDeriveOwnerKeyPairMatchesCrossImplementationVectors`,
/// `levarac/barnard` v0.3.0, read directly from source — not beid's own
/// re-derivation of the same logic). Per
/// `docs/specs/barnard-binding-conformance.md` §5, a self-consistency test
/// here would prove nothing; these assert against Barnard's independently
/// pinned output.
final class OwnerKeyProviderTests: XCTestCase {
  func testPublicKeyCompressedMatchesBarnardPinnedZeroSeedVector() {
    let provider = OwnerKeyProvider(
      keyStorage: FixedSeedKeyStorage(seed: Data(repeating: 0, count: 32)),
      randomSource: NeverCalledRandomSource()
    )

    XCTAssertEqual(
      provider.publicKeyCompressed().hexString,
      "03351e5165d083f53425fc4a51e7228d53e88eb2899bcb6a83368a8aafaa1de5f4"
    )
  }

  func testPublicKeyCompressedMatchesBarnardPinnedSequentialSeedVector() {
    let provider = OwnerKeyProvider(
      keyStorage: FixedSeedKeyStorage(seed: Data((0..<32).map(UInt8.init))),
      randomSource: NeverCalledRandomSource()
    )

    XCTAssertEqual(
      provider.publicKeyCompressed().hexString,
      "03879beac8b548009124867a99a358aeb34ff42f957f868bbc83339568b16d9c67"
    )
  }
}

/// Pre-seeds `OwnerKeyProvider`'s stored `accountSecret` so
/// `BarnardCoreKeyManager.loadOrCreate` returns a fixed 32-byte value
/// instead of generating a random one, making derivation deterministic.
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

private extension Data {
  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
