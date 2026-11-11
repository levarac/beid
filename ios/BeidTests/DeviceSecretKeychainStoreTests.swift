// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Barnard
import BarnardCore
import Foundation
import Security
import XCTest
@testable import Beid

/// The device secret's storage boundary.
///
/// Barnard creates a new secret whenever its storage answers a read with nil,
/// so the store has to separate "never stored" from "could not read" before
/// Barnard is involved. These tests pin that separation from both sides: a
/// read failure of any kind writes nothing and creates nothing, and a definite
/// item-not-found creates exactly one secret that every later instance reads.
///
/// Secret-bearing values are compared with `XCTAssertTrue(a == b)` rather
/// than `XCTAssertEqual`, so a failure message never prints them.
final class DeviceSecretKeychainStoreTests: XCTestCase {
  private let account = DeviceSecretKeychainStore.deviceSecretKey
  private let thisDeviceOnly = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

  // MARK: - Round trip

  func testSystemKeychainRoundTripKeepsTheSecretOnThisDeviceOnly() throws {
    let service = "org.levarac.beid.tests.device-secret.\(UUID().uuidString)"
    let keychain = SystemBeidKeychainAccess()
    addTeardownBlock { _ = keychain.remove(service: service, account: self.account) }

    let first = try DeviceSecretKeychainStore(keychain: keychain, service: service).resolve()
    let second = try DeviceSecretKeychainStore(keychain: keychain, service: service).resolve()

    let firstSecret = try XCTUnwrap(first.bytes(forKey: account))
    let secondSecret = try XCTUnwrap(second.bytes(forKey: account))
    XCTAssertEqual(firstSecret.count, 32)
    XCTAssertTrue(firstSecret == secondSecret, "a second store must read the secret the first one created")
    let attributes = try XCTUnwrap(keychain.attributes(service: service, account: account))
    XCTAssertEqual(
      attributes.accessible,
      thisDeviceOnly,
      "readable after first unlock for background sensing, and never part of a backup or a device transfer"
    )
    XCTAssertFalse(attributes.synchronizable, "the secret must not sync through iCloud Keychain")
  }

  // MARK: - A failed read never creates or replaces

  func testReadFailureNeverGeneratesOrOverwritesTheStoredSecret() {
    let existing = Data(repeating: 0xA1, count: 32)
    for status in [errSecInteractionNotAllowed, errSecNotAvailable, errSecMissingEntitlement, errSecDecode] {
      let keychain = InMemoryDeviceSecretKeychain(storedData: existing, readResults: [.failure(status)])
      let random = CountingDeviceSecretRandomSource()
      let store = DeviceSecretKeychainStore(keychain: keychain, randomSource: random)

      XCTAssertThrowsError(try store.resolve(), "status \(status)") { error in
        XCTAssertEqual(error as? DeviceSecretError, .readFailed(status))
      }
      XCTAssertEqual(random.callCount, 0, "status \(status): a read failure must not generate a secret")
      XCTAssertEqual(keychain.addCount, 0, "status \(status): a read failure must not create an item")
      XCTAssertEqual(keychain.writeCount, 0, "status \(status): a read failure must not replace the item")
      XCTAssertTrue(keychain.storedData == existing, "status \(status): the stored secret must be untouched")
    }
  }

  func testWrongLengthItemIsRefusedAndLeftInPlace() {
    let short = Data(repeating: 0xB2, count: 16)
    let keychain = InMemoryDeviceSecretKeychain(storedData: short)
    let random = CountingDeviceSecretRandomSource()
    let store = DeviceSecretKeychainStore(keychain: keychain, randomSource: random)

    XCTAssertThrowsError(try store.resolve()) { error in
      XCTAssertEqual(error as? DeviceSecretError, .invalidLength(16))
    }
    XCTAssertEqual(random.callCount, 0)
    XCTAssertEqual(keychain.addCount + keychain.writeCount + keychain.removeCount, 0)
    XCTAssertTrue(keychain.storedData == short)
  }

  func testFailedReadIsRetriedOnTheNextResolve() throws {
    let existing = Data(repeating: 0xC3, count: 32)
    let keychain = InMemoryDeviceSecretKeychain(
      storedData: existing,
      readResults: [.failure(errSecInteractionNotAllowed)]
    )
    let random = CountingDeviceSecretRandomSource()
    let store = DeviceSecretKeychainStore(keychain: keychain, randomSource: random)

    XCTAssertThrowsError(try store.resolve())
    let resolved = try store.resolve()

    XCTAssertTrue(resolved.bytes(forKey: account) == Array(existing), "after the device unlocks, the stored secret is used")
    XCTAssertEqual(random.callCount, 0)
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
  }

  // MARK: - Not found creates exactly once

  func testNotFoundCreatesExactlyOnceAndTheValueIsStableAcrossInstances() throws {
    let keychain = InMemoryDeviceSecretKeychain()
    let random = CountingDeviceSecretRandomSource(bytes: [UInt8](repeating: 0x11, count: 32))
    let firstStore = DeviceSecretKeychainStore(keychain: keychain, randomSource: random)

    let first = try firstStore.resolve()
    let again = try firstStore.resolve()
    let fromSecondStore = try DeviceSecretKeychainStore(keychain: keychain, randomSource: random).resolve()

    XCTAssertEqual(random.callCount, 1, "exactly one secret is generated")
    XCTAssertEqual(keychain.addCount, 1, "exactly one item is created")
    XCTAssertEqual(keychain.writeCount, 0, "creation never goes through the replacing write")
    XCTAssertEqual(keychain.lastAdd?.accessible, thisDeviceOnly)
    XCTAssertEqual(keychain.lastAdd?.synchronizable, false)
    let secret = first.bytes(forKey: account)
    XCTAssertTrue(secret == [UInt8](repeating: 0x11, count: 32))
    XCTAssertTrue(again.bytes(forKey: account) == secret)
    XCTAssertTrue(fromSecondStore.bytes(forKey: account) == secret)
  }

  func testCreationKeepsAnItemThatAnotherWriterAddedFirst() throws {
    let theirs = Data(repeating: 0xD4, count: 32)
    let keychain = InMemoryDeviceSecretKeychain()
    keychain.itemAddedByAnotherWriter = theirs
    let store = DeviceSecretKeychainStore(
      keychain: keychain,
      randomSource: CountingDeviceSecretRandomSource(bytes: [UInt8](repeating: 0x22, count: 32))
    )

    let resolved = try store.resolve()

    XCTAssertTrue(resolved.bytes(forKey: account) == Array(theirs), "the item already stored wins")
    XCTAssertEqual(keychain.writeCount, 0, "an existing item is never replaced")
    XCTAssertTrue(keychain.storedData == theirs)
  }

  func testRandomFailureCreatesNothing() {
    let keychain = InMemoryDeviceSecretKeychain()
    let store = DeviceSecretKeychainStore(
      keychain: keychain,
      randomSource: CountingDeviceSecretRandomSource(failure: .randomFailed(-42))
    )

    XCTAssertThrowsError(try store.resolve()) { error in
      XCTAssertEqual(error as? DeviceSecretError, .randomFailed(-42))
    }
    XCTAssertEqual(keychain.addCount + keychain.writeCount, 0)
    XCTAssertNil(keychain.storedData)
  }

  func testWriteFailureAndReadBackMismatchAreRefused() {
    let failingKeychain = InMemoryDeviceSecretKeychain()
    failingKeychain.addStatus = errSecInteractionNotAllowed
    XCTAssertThrowsError(try DeviceSecretKeychainStore(
      keychain: failingKeychain,
      randomSource: CountingDeviceSecretRandomSource()
    ).resolve()) { error in
      XCTAssertEqual(error as? DeviceSecretError, .writeFailed(errSecInteractionNotAllowed))
    }

    let mismatchKeychain = InMemoryDeviceSecretKeychain()
    mismatchKeychain.dataStoredOnAdd = Data(repeating: 0xE5, count: 32)
    XCTAssertThrowsError(try DeviceSecretKeychainStore(
      keychain: mismatchKeychain,
      randomSource: CountingDeviceSecretRandomSource()
    ).resolve()) { error in
      XCTAssertEqual(error as? DeviceSecretError, .verificationFailed)
    }
    XCTAssertEqual(mismatchKeychain.writeCount, 0)
  }

  // MARK: - What Barnard sees

  func testBarnardDerivesOneKeyFromEveryObjectBuiltOnTheResolvedSecret() throws {
    let keychain = InMemoryDeviceSecretKeychain()
    let random = CountingDeviceSecretRandomSource(bytes: [UInt8](repeating: 0x33, count: 32))
    let storage = try DeviceSecretKeychainStore(keychain: keychain, randomSource: random).resolve()
    let laterStorage = try DeviceSecretKeychainStore(keychain: keychain, randomSource: random).resolve()

    let identity = BarnardIdentity(keyStorage: storage)
    let laterIdentity = BarnardIdentity(keyStorage: laterStorage)
    XCTAssertTrue(identity.signingPublicKey(eventCode: "EVENT-A") == laterIdentity.signingPublicKey(eventCode: "EVENT-A"))
    let engine = BarnardEngine(keyStorage: storage)
    let laterEngine = BarnardEngine(keyStorage: laterStorage)
    XCTAssertTrue(engine.exportCurrentTek() == laterEngine.exportCurrentTek())
    XCTAssertEqual(random.callCount, 1, "Barnard must never take its own create path")
    XCTAssertEqual(keychain.addCount, 1)
    XCTAssertEqual(keychain.writeCount, 0)
  }

  // MARK: - The old UserDefaults copy

  func testLegacyUserDefaultsCopyIsDeletedWithoutBeingRead() {
    let suiteName = "org.levarac.beid.tests.deviceSecret.\(UUID().uuidString)"
    let defaults = ReadRecordingDefaults(suiteName: suiteName)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data(repeating: 0xF6, count: 32), forKey: account)
    defaults.readKeys = []

    DeviceSecretKeychainStore.removeLegacyUserDefaultsCopy(from: defaults)

    XCTAssertFalse(defaults.readKeys.contains(account), "the old value is deleted, never read")
    XCTAssertNil(defaults.object(forKey: account))
  }
}

/// Records which keys were read, so a test can show a value was removed
/// without first being read.
private final class ReadRecordingDefaults: UserDefaults {
  var readKeys: [String] = []

  override func object(forKey defaultName: String) -> Any? {
    readKeys.append(defaultName)
    return super.object(forKey: defaultName)
  }

  override func data(forKey defaultName: String) -> Data? {
    readKeys.append(defaultName)
    return super.data(forKey: defaultName)
  }
}
