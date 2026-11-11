// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BarnardCore
import Foundation
import Security

enum DeviceSecretError: Error, Equatable {
  case readFailed(OSStatus)
  case invalidLength(Int)
  case randomFailed(OSStatus)
  case invalidRandomByteCount(Int)
  case writeFailed(OSStatus)
  case verificationFailed
}

final class DeviceSecretKeychainStore {
  static let service = "org.levarac.beid.device-secret"
  static let deviceSecretKey = "barnard.rpidSeed"
  static let shared = DeviceSecretKeychainStore()

  private let keychain: any BeidKeychainAccessing
  private let randomSource: any OwnerKeyRandomBytesGenerating
  private let service: String

  init(
    keychain: any BeidKeychainAccessing = SystemBeidKeychainAccess(),
    randomSource: any OwnerKeyRandomBytesGenerating = SystemOwnerKeyRandomSource(),
    service: String = DeviceSecretKeychainStore.service
  ) {
    self.keychain = keychain
    self.randomSource = randomSource
    self.service = service
  }

  func resolve() throws -> ResolvedDeviceSecretStorage {
    if let stored = try readSecret() {
      return ResolvedDeviceSecretStorage(secret: stored)
    }
    let generated: [UInt8]
    do {
      generated = try randomSource.randomBytes(count: 32)
    } catch OwnerKeyOperationError.randomFailed(let status) {
      throw DeviceSecretError.randomFailed(status)
    }
    guard generated.count == 32 else {
      throw DeviceSecretError.invalidRandomByteCount(generated.count)
    }
    let status = keychain.add(BeidKeychainWrite(
      service: service,
      account: Self.deviceSecretKey,
      data: Data(generated),
      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
      synchronizable: false
    ))
    guard status == errSecSuccess || status == errSecDuplicateItem else {
      throw DeviceSecretError.writeFailed(status)
    }
    guard let stored = try readSecret(),
          status == errSecDuplicateItem || stored == generated else {
      throw DeviceSecretError.verificationFailed
    }
    return ResolvedDeviceSecretStorage(secret: stored)
  }

  private func readSecret() throws -> [UInt8]? {
    switch keychain.read(service: service, account: Self.deviceSecretKey) {
    case .found(let data):
      guard data.count == 32 else { throw DeviceSecretError.invalidLength(data.count) }
      return Array(data)
    case .notFound:
      return nil
    case .failure(let status):
      throw DeviceSecretError.readFailed(status)
    }
  }

  static func removeLegacyUserDefaultsCopy(from defaults: UserDefaults) {
    defaults.removeObject(forKey: deviceSecretKey)
  }
}

/// A checked, immutable SDK input: its optional-only API cannot turn a later
/// Keychain failure into a request to regenerate. Resolve before each session
/// and retain the value for its radio and signing operations.
struct ResolvedDeviceSecretStorage: BarnardCoreKeyStorage, Equatable {
  fileprivate let secret: [UInt8]

  fileprivate init(secret: [UInt8]) {
    self.secret = secret
  }

  func bytes(forKey key: String) -> [UInt8]? { secret }
  func setBytes(_ bytes: [UInt8], forKey key: String) {}
}

/// The UI reports availability without exposing storage details.
enum EventSigningKeyFailure: String, Identifiable {
  case unavailable
  case changed
  case discardFailed

  var id: String { rawValue }

  var title: String {
    switch self {
    case .changed:
      return String(localized: "eventSigningKeyFailure.changed.title", defaultValue: "Earlier record discarded")
    case .unavailable, .discardFailed:
      return String(localized: "eventSigningKeyFailure.title", defaultValue: "Recording unavailable")
    }
  }

  var message: String {
    switch self {
    case .unavailable:
      return String(
        localized: "eventSigningKeyFailure.unavailable",
        defaultValue: "The device signing key is unavailable. Unlock your device and try again."
      )
    case .changed:
      return String(
        localized: "eventSigningKeyFailure.changed",
        defaultValue: "A record from an earlier session could not be saved because this device's signing key changed."
      )
    case .discardFailed:
      return String(
        localized: "eventSigningKeyFailure.discardFailed",
        defaultValue: "A record from an earlier session could not be saved or removed. Recording is unavailable."
      )
    }
  }
}
