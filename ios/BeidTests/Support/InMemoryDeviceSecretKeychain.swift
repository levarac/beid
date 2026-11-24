// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import Security
@testable import Beid

/// In-memory stand-in for the system Keychain, for tests of
/// `DeviceSecretKeychainStore` and of the objects built from it.
///
/// Records every create and every replace separately. The property under test
/// is that a failed read never leads to a write of either kind, so a fake that
/// folded the two together could not show it.
final class InMemoryDeviceSecretKeychain: BeidKeychainAccessing {
  var storedData: Data?
  /// Answers for the next reads, in order, before falling back to
  /// `storedData`. A queued failure models a read error while an item exists.
  var readResults: [BeidKeychainReadResult]
  /// Status `add` reports when it does not succeed.
  var addStatus: OSStatus = errSecSuccess
  /// Models another writer creating the item between the read that found
  /// nothing and this store's own add: the add then meets an existing item.
  var itemAddedByAnotherWriter: Data?
  /// Stored in place of the bytes an `add` carried, so the read-back differs.
  var dataStoredOnAdd: Data?

  private(set) var readCount = 0
  private(set) var addCount = 0
  private(set) var writeCount = 0
  private(set) var removeCount = 0
  private(set) var lastAdd: BeidKeychainWrite?

  init(storedData: Data? = nil, readResults: [BeidKeychainReadResult] = []) {
    self.storedData = storedData
    self.readResults = readResults
  }

  func read(service: String, account: String) -> BeidKeychainReadResult {
    readCount += 1
    if !readResults.isEmpty {
      return readResults.removeFirst()
    }
    return storedData.map(BeidKeychainReadResult.found) ?? .notFound
  }

  func add(_ write: BeidKeychainWrite) -> OSStatus {
    addCount += 1
    lastAdd = write
    if let itemAddedByAnotherWriter {
      storedData = itemAddedByAnotherWriter
      self.itemAddedByAnotherWriter = nil
      return errSecDuplicateItem
    }
    guard storedData == nil else { return errSecDuplicateItem }
    guard addStatus == errSecSuccess else { return addStatus }
    storedData = dataStoredOnAdd ?? write.data
    return errSecSuccess
  }

  func write(_ write: BeidKeychainWrite) -> OSStatus {
    writeCount += 1
    storedData = write.data
    return errSecSuccess
  }

  func remove(service: String, account: String) -> OSStatus {
    removeCount += 1
    storedData = nil
    return errSecSuccess
  }

  func attributes(service: String, account: String) -> BeidKeychainItemAttributes? {
    guard storedData != nil, let lastAdd else { return nil }
    return BeidKeychainItemAttributes(
      service: service,
      account: account,
      accessible: lastAdd.accessible,
      synchronizable: lastAdd.synchronizable
    )
  }
}

/// Random source for device-secret tests: fixed bytes or a fixed failure, and
/// a count of how often it was asked.
final class CountingDeviceSecretRandomSource: OwnerKeyRandomBytesGenerating {
  var result: Result<[UInt8], OwnerKeyOperationError>
  private(set) var callCount = 0

  init(bytes: [UInt8] = [UInt8](repeating: 0x5A, count: 32)) {
    result = .success(bytes)
  }

  init(failure: OwnerKeyOperationError) {
    result = .failure(failure)
  }

  func randomBytes(count: Int) throws -> [UInt8] {
    callCount += 1
    return try result.get()
  }
}
