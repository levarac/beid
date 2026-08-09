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

// MARK: - gh#156: UserDefaults.data(forKey:) type-mismatch verification

/// Verifies, by actually running it, the one claim
/// `docs/specs/owner-key-seed-read-failure.md` §3.1 flags as Apple's
/// documented Foundation behavior rather than something read from source or
/// executed: `UserDefaults.data(forKey:)` returns `nil` not only when
/// nothing is stored under a key, but also when something IS stored under
/// it with a non-`Data` type. Deliberately independent of
/// `BeidUserDefaultsKeyStorage`'s own wrapping logic — this is Apple's API
/// contract under test, not beid's.
final class UserDefaultsDataForKeyTypeMismatchTests: XCTestCase {
  func testDataForKeyReturnsNilForNonDataStoredValue() {
    let suiteName = "org.levarac.beid.tests.userDefaultsTypeMismatch.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertNil(defaults.data(forKey: "seed"), "nothing stored yet")

    defaults.set("not-a-data-value", forKey: "seed")
    XCTAssertNotNil(
      defaults.object(forKey: "seed"),
      "something IS stored under this key now"
    )
    XCTAssertNil(
      defaults.data(forKey: "seed"),
      """
      Apple's own type-safe accessor must return nil for a non-Data stored \
      value, indistinguishable from unset — this is the exact ambiguity \
      §5's pre-flight check exists to resolve
      """
    )
  }
}

// MARK: - gh#156 §9 criteria 1/2/3/5/6: BeidUserDefaultsKeyStorage pre-flight

/// Exercises `BeidUserDefaultsKeyStorage.bytes(forKey:)` directly — the
/// actual pre-flight layer `docs/specs/owner-key-seed-read-failure.md` §5
/// adds — against all four stored shapes it must tell apart from a
/// genuinely valid seed: never stored, wrong type, right type but too
/// short, right type but too long.
final class BeidUserDefaultsKeyStorageTests: XCTestCase {
  private let seedKey = "beid.ownerKeySeed.testFixture"

  func testBytesForKeyReturnsNilWhenNothingStored() {
    let storage = makeIsolatedStorage()

    XCTAssertNil(storage.bytes(forKey: seedKey))
    XCTAssertNil(storage.lastQuarantinedSeedKey, "nothing was there to quarantine")
  }

  func testBytesForKeyQuarantinesAndReturnsNilForWrongTypedValue() {
    let storage = makeIsolatedStorage()
    storage.defaults.set("not-a-seed", forKey: seedKey)

    XCTAssertNil(storage.bytes(forKey: seedKey), "a wrong-typed value must not pass through")

    let quarantineKey = try! XCTUnwrap(storage.lastQuarantinedSeedKey)
    XCTAssertTrue(quarantineKey.hasPrefix("\(seedKey).quarantine."))
    XCTAssertEqual(
      storage.defaults.object(forKey: quarantineKey) as? String,
      "not-a-seed",
      "the original value must survive verbatim under the quarantine key"
    )
    XCTAssertNil(
      storage.defaults.object(forKey: seedKey),
      "the canonical key must be genuinely empty afterward, not just failing data(forKey:)"
    )
  }

  func testBytesForKeyQuarantinesAndReturnsNilForTooShortSeed() {
    let storage = makeIsolatedStorage()
    let tooShort = Data(repeating: 0xAB, count: 16)
    storage.defaults.set(tooShort, forKey: seedKey)

    XCTAssertNil(storage.bytes(forKey: seedKey), "< 32 bytes must not pass through")

    let quarantineKey = try! XCTUnwrap(storage.lastQuarantinedSeedKey)
    XCTAssertEqual(storage.defaults.object(forKey: quarantineKey) as? Data, tooShort)
    XCTAssertNil(storage.defaults.object(forKey: seedKey))
  }

  func testBytesForKeyQuarantinesAndReturnsNilForTooLongSeed() {
    let storage = makeIsolatedStorage()
    let tooLong = Data(repeating: 0xCD, count: 40)
    storage.defaults.set(tooLong, forKey: seedKey)

    XCTAssertNil(
      storage.bytes(forKey: seedKey),
      "> 32 bytes must not pass through — loadOrCreate's own `>= minimumByteCount` " +
        "check alone would have accepted this and crashed deriveOwnerKeyPair (§7)"
    )

    let quarantineKey = try! XCTUnwrap(storage.lastQuarantinedSeedKey)
    XCTAssertEqual(storage.defaults.object(forKey: quarantineKey) as? Data, tooLong)
    XCTAssertNil(storage.defaults.object(forKey: seedKey))
  }

  /// Criterion 6: no regression for an already-valid stored seed — the
  /// pre-flight check must be a no-op here.
  func testBytesForKeyReturnsValidSeedUnchangedWithoutQuarantining() {
    let storage = makeIsolatedStorage()
    let validSeed = Data(repeating: 0x11, count: 32)
    storage.defaults.set(validSeed, forKey: seedKey)

    XCTAssertEqual(storage.bytes(forKey: seedKey), Array(validSeed))
    XCTAssertNil(storage.lastQuarantinedSeedKey, "a valid seed must never be quarantined")
  }

  private func makeIsolatedStorage() -> BeidUserDefaultsKeyStorage {
    let suiteName = "org.levarac.beid.tests.ownerKeyStorage.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    return BeidUserDefaultsKeyStorage(defaults: defaults)
  }
}

// MARK: - gh#156 §9 criteria 2/4/5: end-to-end via OwnerKeyProvider (Signal A)

/// Drives the failure through `OwnerKeyProvider.publicKeyCompressed()` end
/// to end, using the real `BeidUserDefaultsKeyStorage` (not a fake), so
/// these tests prove both that a bad stored seed can never reach
/// `BarnardCoreSigning.deriveOwnerKeyPair`'s `precondition` (it would crash
/// the test process, not just fail an assertion) and that Signal A
/// (`quarantinedSeedKey`) is readable and non-nil afterward.
final class OwnerKeyProviderRegenerationTests: XCTestCase {
  /// Mirrors `OwnerKeyProvider`'s own private `seedKey` constant
  /// (`OwnerKeyProvider.swift:29`) — not accessible from here, so the
  /// literal is duplicated deliberately rather than exported just for
  /// tests.
  private let seedKey = "beid.ownerKeySeed"

  func testPublicKeyCompressedRegeneratesAndPreservesWhenStoredSeedIsWrongType() {
    let defaults = makeIsolatedDefaults()
    defaults.set("not-a-seed", forKey: seedKey)
    let provider = OwnerKeyProvider(keyStorage: BeidUserDefaultsKeyStorage(defaults: defaults))

    _ = provider.publicKeyCompressed() // must not crash

    assertRegeneratedAndPreserved(defaults: defaults, provider: provider, original: "not-a-seed" as NSString)
  }

  func testPublicKeyCompressedRegeneratesAndPreservesWhenStoredSeedIsTooShort() {
    let defaults = makeIsolatedDefaults()
    let tooShort = Data(repeating: 0xAB, count: 16)
    defaults.set(tooShort, forKey: seedKey)
    let provider = OwnerKeyProvider(keyStorage: BeidUserDefaultsKeyStorage(defaults: defaults))

    _ = provider.publicKeyCompressed() // must not crash

    assertRegeneratedAndPreserved(defaults: defaults, provider: provider, original: tooShort as NSData)
  }

  /// Criterion 5: this is the case that was previously unflagged — a stored
  /// seed longer than 32 bytes passed `loadOrCreate`'s own
  /// `>= minimumByteCount` check and reached `deriveOwnerKeyPair`'s
  /// `precondition(accountSecret.count == 32)` unmodified, which traps.
  func testPublicKeyCompressedRegeneratesWithoutCrashingWhenStoredSeedIsTooLong() {
    let defaults = makeIsolatedDefaults()
    let tooLong = Data(repeating: 0xCD, count: 40)
    defaults.set(tooLong, forKey: seedKey)
    let provider = OwnerKeyProvider(keyStorage: BeidUserDefaultsKeyStorage(defaults: defaults))

    _ = provider.publicKeyCompressed() // must not crash — this is the regression this spec fixes

    assertRegeneratedAndPreserved(defaults: defaults, provider: provider, original: tooLong as NSData)
  }

  private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "org.levarac.beid.tests.ownerKeyProviderRegeneration.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    return defaults
  }

  private func assertRegeneratedAndPreserved(
    defaults: UserDefaults,
    provider: OwnerKeyProvider,
    original: NSObject,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let quarantineKey = provider.quarantinedSeedKey
    XCTAssertNotNil(quarantineKey, "Signal A must be readable and non-nil", file: file, line: line)
    if let quarantineKey {
      XCTAssertEqual(
        defaults.object(forKey: quarantineKey) as? NSObject,
        original,
        "the original value must survive verbatim under the quarantine key",
        file: file,
        line: line
      )
    }

    let regenerated = defaults.data(forKey: seedKey)
    XCTAssertEqual(
      regenerated?.count,
      32,
      "the canonical key must hold a freshly generated, exactly-32-byte seed",
      file: file,
      line: line
    )
    XCTAssertNotEqual(
      regenerated as NSObject?,
      original,
      "the regenerated seed must be distinct from the discarded original",
      file: file,
      line: line
    )
  }
}

// MARK: - gh#156 §9 criterion 4: Signal B (owner public key mismatch)

/// `OwnerKeyRegenerationDetector.ownerPublicKeyMismatchDetected` is a pure
/// comparison, decoupled from `SensingCoordinator`'s BLE engine and
/// file-backed stores — tested directly with plain records.
final class OwnerKeyRegenerationDetectorTests: XCTestCase {
  func testReportsNoMismatchWhenEveryRecordMatchesTheActiveKey() {
    let activeKey = Data(repeating: 0x03, count: 33)

    let mismatch = OwnerKeyRegenerationDetector.ownerPublicKeyMismatchDetected(
      activeOwnerPublicKey: activeKey,
      selfProofRecords: [makeSelfProofRecord(ownerPublicKey: activeKey)],
      bindingRecords: [makeBindingRecord(ownerPublicKey: activeKey)]
    )

    XCTAssertFalse(mismatch)
  }

  func testReportsNoMismatchWhenNoRecordsExistYet() {
    let activeKey = Data(repeating: 0x03, count: 33)

    let mismatch = OwnerKeyRegenerationDetector.ownerPublicKeyMismatchDetected(
      activeOwnerPublicKey: activeKey,
      selfProofRecords: [],
      bindingRecords: []
    )

    XCTAssertFalse(mismatch)
  }

  func testReportsMismatchWhenASelfProofRecordHasADifferentOwnerKey() {
    let activeKey = Data(repeating: 0x03, count: 33)
    let staleKey = Data(repeating: 0x09, count: 33)

    let mismatch = OwnerKeyRegenerationDetector.ownerPublicKeyMismatchDetected(
      activeOwnerPublicKey: activeKey,
      selfProofRecords: [makeSelfProofRecord(ownerPublicKey: staleKey)],
      bindingRecords: []
    )

    XCTAssertTrue(mismatch)
  }

  func testReportsMismatchWhenABindingRecordHasADifferentOwnerKey() {
    let activeKey = Data(repeating: 0x03, count: 33)
    let staleKey = Data(repeating: 0x09, count: 33)

    let mismatch = OwnerKeyRegenerationDetector.ownerPublicKeyMismatchDetected(
      activeOwnerPublicKey: activeKey,
      selfProofRecords: [],
      bindingRecords: [makeBindingRecord(ownerPublicKey: staleKey)]
    )

    XCTAssertTrue(mismatch)
  }

  private func makeSelfProofRecord(ownerPublicKey: Data) -> SelfProofRecord {
    SelfProofRecord(
      proofId: UUID(),
      eventCode: "TEST-EVENT",
      eventIdHash: Data(repeating: 0xAB, count: 32),
      eventSigningPublicKey: Data(repeating: 0x02, count: 33),
      eninStart: 100,
      eninEnd: 200,
      ownerPublicKey: ownerPublicKey,
      signature: BarnardCoreRecoverableSignature(
        r: [UInt8](repeating: 1, count: 32),
        s: [UInt8](repeating: 2, count: 32),
        v: 0
      )
    )
  }

  private func makeBindingRecord(ownerPublicKey: Data) -> BindingRecord {
    BindingRecord(
      proofId: UUID(),
      eventCode: "TEST-EVENT",
      walletAddress: "0x0000000000000000000000000000000000000001",
      eventSigningPublicKey: Data(repeating: 0x02, count: 33),
      ownerPublicKey: ownerPublicKey,
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
}
