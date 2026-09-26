// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BarnardCore
import Foundation
import Security

/// Richer beid-side resolution boundary used before Barnard's optional-only
/// storage protocol. It prevents a Keychain read failure from being mistaken
/// for an absent value by `BarnardCoreKeyManager.loadOrCreate`.
protocol OwnerKeySeedResolving: BarnardCoreKeyStorage {
  func resolveSeed(
    forKey key: String,
    randomSource: any OwnerKeyRandomBytesGenerating
  ) throws -> [UInt8]
}

enum BeidKeychainReadResult: Equatable {
  case found(Data)
  case notFound
  case failure(OSStatus)
}

struct BeidKeychainWrite: Equatable {
  let service: String
  let account: String
  let data: Data
  let accessible: String
  let synchronizable: Bool
}

struct BeidKeychainItemAttributes: Equatable {
  let service: String
  let account: String
  let accessible: String
  let synchronizable: Bool
}

protocol BeidKeychainAccessing {
  func read(service: String, account: String) -> BeidKeychainReadResult
  func write(_ write: BeidKeychainWrite) -> OSStatus
  func remove(service: String, account: String) -> OSStatus
  func attributes(service: String, account: String) -> BeidKeychainItemAttributes?
}

struct SystemBeidKeychainAccess: BeidKeychainAccessing {
  func read(service: String, account: String) -> BeidKeychainReadResult {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(
      query(service: service, account: account, returning: kSecReturnData),
      &result
    )
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { return .failure(errSecDecode) }
      return .found(data)
    case errSecItemNotFound:
      return .notFound
    default:
      return .failure(status)
    }
  }

  func write(_ write: BeidKeychainWrite) -> OSStatus {
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: write.service,
      kSecAttrAccount as String: write.account,
      kSecValueData as String: write.data,
      kSecAttrAccessible as String: write.accessible,
      kSecAttrSynchronizable as String: write.synchronizable
    ]
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecDuplicateItem else { return addStatus }

    let updates: [String: Any] = [
      kSecValueData as String: write.data,
      kSecAttrAccessible as String: write.accessible
    ]
    return SecItemUpdate(
      query(service: write.service, account: write.account),
      updates as CFDictionary
    )
  }

  func remove(service: String, account: String) -> OSStatus {
    SecItemDelete(query(service: service, account: account))
  }

  func attributes(service: String, account: String) -> BeidKeychainItemAttributes? {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(
      query(service: service, account: account, returning: kSecReturnAttributes),
      &result
    )
    guard status == errSecSuccess,
          let attributes = result as? [String: Any],
          let storedService = attributes[kSecAttrService as String] as? String,
          let storedAccount = attributes[kSecAttrAccount as String] as? String,
          let accessible = attributes[kSecAttrAccessible as String] as? String else {
      return nil
    }
    return BeidKeychainItemAttributes(
      service: storedService,
      account: storedAccount,
      accessible: accessible,
      synchronizable: attributes[kSecAttrSynchronizable as String] as? Bool ?? false
    )
  }

  private func query(
    service: String,
    account: String,
    returning returnType: CFString? = nil
  ) -> CFDictionary {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false
    ]
    if let returnType {
      query[returnType as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
    }
    return query as CFDictionary
  }
}

enum BeidKeychainKeyStorageError: Error, Equatable {
  case readFailed(OSStatus)
  case invalidSeedLength(Int)
  case writeFailed(OSStatus)
  case verificationFailed
  case conflictingLegacySeed
}

/// Owner-key seed storage. `AfterFirstUnlock` intentionally omits
/// `ThisDeviceOnly` so encrypted backups and direct device migration can
/// carry the seed, while `synchronizable = false` keeps it out of iCloud
/// Keychain sync.
final class BeidKeychainKeyStorage:
  OwnerKeySeedResolving,
  OwnerKeySeedQuarantineObserving {
  static let service = "org.levarac.beid.owner-key-seed"

  private let keychain: any BeidKeychainAccessing
  private let legacyStorage: BeidUserDefaultsKeyStorage

  var lastQuarantinedSeedKey: String? {
    legacyStorage.lastQuarantinedSeedKey
  }

  init(
    keychain: any BeidKeychainAccessing = SystemBeidKeychainAccess(),
    legacyStorage: BeidUserDefaultsKeyStorage = BeidUserDefaultsKeyStorage()
  ) {
    self.keychain = keychain
    self.legacyStorage = legacyStorage
  }

  func bytes(forKey key: String) -> [UInt8]? {
    switch keychain.read(service: Self.service, account: key) {
    case .found(let data):
      precondition(data.count == 32, "Stored owner key seed must be exactly 32 bytes")
      return Array(data)
    case .notFound:
      return nil
    case .failure(let status):
      preconditionFailure("Keychain read failed with OSStatus \(status)")
    }
  }

  func setBytes(_ bytes: [UInt8], forKey key: String) {
    let status = keychain.write(makeWrite(bytes: bytes, key: key))
    precondition(status == errSecSuccess, "Keychain write failed with OSStatus \(status)")
  }

  func resolveSeed(
    forKey key: String,
    randomSource: any OwnerKeyRandomBytesGenerating
  ) throws -> [UInt8] {
    switch try readStrictSeed(forKey: key) {
    case .some(let keychainSeed):
      try reconcileLegacyCopy(keychainSeed, forKey: key)
      return keychainSeed
    case .none:
      if let legacySeed = legacyStorage.bytes(forKey: key) {
        try persistAndVerify(legacySeed, forKey: key)
        legacyStorage.removeBytes(forKey: key)
        return legacySeed
      }

      let generated = try randomSource.randomBytes(count: 32)
      guard generated.count == 32 else {
        throw OwnerKeyOperationError.invalidRandomByteCount(generated.count)
      }
      try persistAndVerify(generated, forKey: key)
      return generated
    }
  }

  func removeBytes(forKey key: String) {
    let status = keychain.remove(service: Self.service, account: key)
    precondition(
      status == errSecSuccess || status == errSecItemNotFound,
      "Keychain delete failed with OSStatus \(status)"
    )
  }

  func itemAttributes(forKey key: String) -> BeidKeychainItemAttributes? {
    keychain.attributes(service: Self.service, account: key)
  }

  private func readStrictSeed(forKey key: String) throws -> [UInt8]? {
    switch keychain.read(service: Self.service, account: key) {
    case .found(let data):
      guard data.count == 32 else {
        throw BeidKeychainKeyStorageError.invalidSeedLength(data.count)
      }
      return Array(data)
    case .notFound:
      return nil
    case .failure(let status):
      throw BeidKeychainKeyStorageError.readFailed(status)
    }
  }

  private func persistAndVerify(_ seed: [UInt8], forKey key: String) throws {
    let status = keychain.write(makeWrite(bytes: seed, key: key))
    guard status == errSecSuccess else {
      throw BeidKeychainKeyStorageError.writeFailed(status)
    }
    guard try readStrictSeed(forKey: key) == seed else {
      throw BeidKeychainKeyStorageError.verificationFailed
    }
  }

  private func reconcileLegacyCopy(_ keychainSeed: [UInt8], forKey key: String) throws {
    guard legacyStorage.defaults.object(forKey: key) != nil else { return }
    guard let legacySeed = legacyStorage.bytes(forKey: key) else {
      // Invalid legacy data was quarantined by the strict legacy reader.
      return
    }
    guard legacySeed == keychainSeed else {
      throw BeidKeychainKeyStorageError.conflictingLegacySeed
    }
    legacyStorage.removeBytes(forKey: key)
  }

  private func makeWrite(bytes: [UInt8], key: String) -> BeidKeychainWrite {
    BeidKeychainWrite(
      service: Self.service,
      account: key,
      data: Data(bytes),
      accessible: kSecAttrAccessibleAfterFirstUnlock as String,
      synchronizable: false
    )
  }
}
