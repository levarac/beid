// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import Foundation
import Security
import XCTest
@testable import Beid

final class BeidKeychainKeyStorageTests: XCTestCase {
  private let seedKey = "beid.ownerKeySeed"

  func testSystemKeychainRoundTripUsesBackupPreservingNonSynchronizableItem() throws {
    let key = "\(seedKey).roundTrip.\(UUID().uuidString)"
    let storage = BeidKeychainKeyStorage()
    let seed = [UInt8](repeating: 0xA5, count: 32)
    addTeardownBlock { storage.removeBytes(forKey: key) }

    storage.setBytes(seed, forKey: key)

    XCTAssertEqual(storage.bytes(forKey: key), seed)
    let attributes = try XCTUnwrap(storage.itemAttributes(forKey: key))
    XCTAssertEqual(attributes.service, BeidKeychainKeyStorage.service)
    XCTAssertEqual(attributes.account, key)
    XCTAssertEqual(attributes.accessible, kSecAttrAccessibleAfterFirstUnlock as String)
    XCTAssertFalse(attributes.synchronizable)
  }

  func testResolveReturnsNilOnlyForGenuinelyAbsentItemThenCreatesAndVerifiesSeed() throws {
    let keychain = FakeBeidKeychainAccess()
    let random = CountingRandomSource(bytes: [UInt8](repeating: 0x11, count: 32))
    let storage = makeStorage(keychain: keychain)

    let resolved = try storage.resolveSeed(forKey: seedKey, randomSource: random)

    XCTAssertEqual(resolved, [UInt8](repeating: 0x11, count: 32))
    XCTAssertEqual(random.callCount, 1)
    XCTAssertEqual(keychain.storedData, Data(repeating: 0x11, count: 32))
    XCTAssertEqual(keychain.lastWrite?.accessible, kSecAttrAccessibleAfterFirstUnlock as String)
    XCTAssertEqual(keychain.lastWrite?.synchronizable, false)
  }

  func testResolveFailsClosedOnTransientReadErrorWithoutGeneratingOrWriting() {
    let keychain = FakeBeidKeychainAccess(readResults: [.failure(errSecInteractionNotAllowed)])
    let random = CountingRandomSource(bytes: [UInt8](repeating: 0x22, count: 32))
    let storage = makeStorage(keychain: keychain)

    XCTAssertThrowsError(try storage.resolveSeed(forKey: seedKey, randomSource: random)) { error in
      XCTAssertEqual(
        error as? BeidKeychainKeyStorageError,
        .readFailed(errSecInteractionNotAllowed)
      )
    }
    XCTAssertEqual(random.callCount, 0, "locked Keychain must never trigger generation")
    XCTAssertNil(keychain.lastWrite)
  }

  func testResolveFailsClosedOnUnknownReadErrorWithoutGenerating() {
    let unknownStatus = OSStatus(-9_999)
    let keychain = FakeBeidKeychainAccess(readResults: [.failure(unknownStatus)])
    let random = CountingRandomSource(bytes: [UInt8](repeating: 0x33, count: 32))
    let storage = makeStorage(keychain: keychain)

    XCTAssertThrowsError(try storage.resolveSeed(forKey: seedKey, randomSource: random)) { error in
      XCTAssertEqual(error as? BeidKeychainKeyStorageError, .readFailed(unknownStatus))
    }
    XCTAssertEqual(random.callCount, 0)
  }

  func testMigrationWritesAndVerifiesLegacySeedBeforeRemovingUserDefaults() throws {
    let legacySeed = Data((0..<32).map(UInt8.init))
    let defaults = makeIsolatedDefaults()
    defaults.set(legacySeed, forKey: seedKey)
    let keychain = FakeBeidKeychainAccess()
    let storage = makeStorage(keychain: keychain, defaults: defaults)

    let resolved = try storage.resolveSeed(
      forKey: seedKey,
      randomSource: CountingRandomSource(bytes: [UInt8](repeating: 0xFF, count: 32))
    )

    XCTAssertEqual(resolved, Array(legacySeed))
    XCTAssertEqual(keychain.storedData, legacySeed)
    XCTAssertNil(defaults.object(forKey: seedKey))
  }

  func testMigrationKeepsLegacySeedWhenWriteCannotBeVerified() {
    let legacySeed = Data(repeating: 0x44, count: 32)
    let defaults = makeIsolatedDefaults()
    defaults.set(legacySeed, forKey: seedKey)
    let keychain = FakeBeidKeychainAccess(persistWrites: false)
    let storage = makeStorage(keychain: keychain, defaults: defaults)

    XCTAssertThrowsError(
      try storage.resolveSeed(
        forKey: seedKey,
        randomSource: CountingRandomSource(bytes: [UInt8](repeating: 0x55, count: 32))
      )
    )
    XCTAssertEqual(defaults.data(forKey: seedKey), legacySeed)
  }

  func testInterruptedMigrationConvergesWhenBothStoresContainSameSeed() throws {
    let seed = Data(repeating: 0x66, count: 32)
    let defaults = makeIsolatedDefaults()
    defaults.set(seed, forKey: seedKey)
    let keychain = FakeBeidKeychainAccess(storedData: seed)
    let storage = makeStorage(keychain: keychain, defaults: defaults)

    XCTAssertEqual(
      try storage.resolveSeed(
        forKey: seedKey,
        randomSource: CountingRandomSource(bytes: [UInt8](repeating: 0x77, count: 32))
      ),
      Array(seed)
    )
    XCTAssertNil(defaults.object(forKey: seedKey))
  }

  func testCorruptedLegacyValueIsQuarantinedAndSignalAIsPreserved() throws {
    let defaults = makeIsolatedDefaults()
    defaults.set("not-a-seed", forKey: seedKey)
    let keychain = FakeBeidKeychainAccess()
    let storage = makeStorage(keychain: keychain, defaults: defaults)
    let provider = OwnerKeyProvider(
      keyStorage: storage,
      randomSource: CountingRandomSource(bytes: [UInt8](repeating: 0x88, count: 32))
    )

    _ = provider.publicKeyCompressed()

    let quarantineKey = try XCTUnwrap(provider.quarantinedSeedKey)
    XCTAssertTrue(quarantineKey.hasPrefix("\(seedKey).quarantine."))
    XCTAssertEqual(defaults.string(forKey: quarantineKey), "not-a-seed")
    XCTAssertNil(defaults.object(forKey: seedKey))
  }

  func testMigrationPreservesOwnerPublicKeyForSignalBComparison() throws {
    let seed = Data((0..<32).map(UInt8.init))
    let defaults = makeIsolatedDefaults()
    defaults.set(seed, forKey: seedKey)
    let migratedProvider = OwnerKeyProvider(
      keyStorage: makeStorage(keychain: FakeBeidKeychainAccess(), defaults: defaults),
      randomSource: CountingRandomSource(bytes: [UInt8](repeating: 0x99, count: 32))
    )
    let originalProvider = OwnerKeyProvider(
      keyStorage: MutableSeedKeyStorage(seed: Array(seed)),
      randomSource: CountingRandomSource(bytes: [])
    )

    XCTAssertEqual(migratedProvider.publicKeyCompressed(), originalProvider.publicKeyCompressed())
  }

  func testProviderRereadsSeedInsteadOfRetainingPrivateKeyPair() {
    let firstSeed = Data(repeating: 0x01, count: 32)
    let keychain = FakeBeidKeychainAccess(storedData: firstSeed)
    let provider = OwnerKeyProvider(
      keyStorage: makeStorage(keychain: keychain),
      randomSource: CountingRandomSource(bytes: [])
    )
    let firstPublicKey = provider.publicKeyCompressed()

    keychain.storedData = Data(repeating: 0x02, count: 32)

    XCTAssertNotEqual(provider.publicKeyCompressed(), firstPublicKey)
    XCTAssertGreaterThanOrEqual(keychain.readCount, 2)
  }

  private func makeStorage(
    keychain: FakeBeidKeychainAccess,
    defaults: UserDefaults? = nil
  ) -> BeidKeychainKeyStorage {
    BeidKeychainKeyStorage(
      keychain: keychain,
      legacyStorage: BeidUserDefaultsKeyStorage(defaults: defaults ?? makeIsolatedDefaults())
    )
  }

  private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "org.levarac.beid.tests.ownerKeyKeychain.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    return defaults
  }
}

private final class FakeBeidKeychainAccess: BeidKeychainAccessing {
  var storedData: Data?
  var readResults: [BeidKeychainReadResult]
  var persistWrites: Bool
  private(set) var readCount = 0
  private(set) var lastWrite: BeidKeychainWrite?

  init(
    storedData: Data? = nil,
    readResults: [BeidKeychainReadResult] = [],
    persistWrites: Bool = true
  ) {
    self.storedData = storedData
    self.readResults = readResults
    self.persistWrites = persistWrites
  }

  func read(service: String, account: String) -> BeidKeychainReadResult {
    readCount += 1
    if !readResults.isEmpty {
      return readResults.removeFirst()
    }
    return storedData.map(BeidKeychainReadResult.found) ?? .notFound
  }

  func write(_ write: BeidKeychainWrite) -> OSStatus {
    lastWrite = write
    if persistWrites {
      storedData = write.data
    }
    return errSecSuccess
  }

  func remove(service: String, account: String) -> OSStatus {
    storedData = nil
    return errSecSuccess
  }

  func attributes(service: String, account: String) -> BeidKeychainItemAttributes? {
    guard storedData != nil, let lastWrite else { return nil }
    return BeidKeychainItemAttributes(
      service: service,
      account: account,
      accessible: lastWrite.accessible,
      synchronizable: lastWrite.synchronizable
    )
  }
}

private final class CountingRandomSource: BarnardCoreRandomSource {
  let bytes: [UInt8]
  private(set) var callCount = 0

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  func randomBytes(count: Int) -> [UInt8] {
    callCount += 1
    return bytes
  }
}

private final class MutableSeedKeyStorage: BarnardCoreKeyStorage {
  var seed: [UInt8]

  init(seed: [UInt8]) {
    self.seed = seed
  }

  func bytes(forKey key: String) -> [UInt8]? {
    seed
  }

  func setBytes(_ bytes: [UInt8], forKey key: String) {
    seed = bytes
  }
}
