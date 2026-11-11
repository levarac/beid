// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Barnard
import BarnardCore
import Foundation

/// App-owned, lossless copy of Barnard's recoverable signature components.
/// `r` and `s` remain the exact returned bytes, and `v` remains the raw
/// recovery identifier. This type performs no validation or normalization.
struct SensingRecoverableSignature: Equatable {
  let r: Data
  let s: Data
  let v: Int

  init(r: Data, s: Data, v: Int) {
    self.r = r
    self.s = s
    self.v = v
  }

  init(barnard signature: BarnardRecoverableSignature) {
    self.init(r: signature.r, s: signature.s, v: signature.v)
  }

  init(barnardCore signature: BarnardCoreRecoverableSignature) {
    self.init(r: Data(signature.r), s: Data(signature.s), v: signature.v)
  }
}

/// Pure indirection over the cryptographic operations used by sensing.
/// Callers retain every lifecycle, payload, validation, and persistence
/// decision; implementations only forward one operation and map its result.
protocol SensingCryptography: AnyObject {
  /// Retains one resolved signing input across an asynchronous operation.
  func signingSnapshot() throws -> any SensingCryptography
  /// Resolves the current device secret for input from an earlier session.
  func recoverySigningSnapshot() throws -> any SensingCryptography
  func eventSigningPublicKey(eventCode: String) throws -> Data
  func ownerPublicKey() throws -> Data

  func signWindowReport(
    eventCode: String,
    bytes: Data
  ) throws -> SensingRecoverableSignature

  func signSelfProof(
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64
  ) throws -> SensingRecoverableSignature?

  func signWalletAcknowledgement(
    walletAddress: Data,
    walletSignature: Data
  ) throws -> SensingRecoverableSignature?
}

enum EventSigningKeyContinuityError: Error {
  case changed
}

extension SensingCryptography {
  func signingSnapshot() throws -> any SensingCryptography { self }
  func recoverySigningSnapshot() throws -> any SensingCryptography { try signingSnapshot() }

  /// Compares and signs through one immutable device-secret resolution.
  func signingSnapshot(eventCode: String, matching publicKey: Data?) throws -> any SensingCryptography {
    let snapshot = try signingSnapshot()
    let currentPublicKey = try snapshot.eventSigningPublicKey(eventCode: eventCode)
    guard let publicKey, currentPublicKey == publicKey else {
      throw EventSigningKeyContinuityError.changed
    }
    return snapshot
  }
}

/// Production adapter for the two Barnard-backed key owners used by sensing.
/// A session retains its resolved device secret; owner-key operations keep
/// their existing provider boundary.
final class BarnardSensingCryptography: SensingCryptography {
  private let deviceSecretStore: DeviceSecretKeychainStore
  private var sessionStorage: ResolvedDeviceSecretStorage?
  /// Not `private`: `SensingCoordinator` downcasts to this concrete type to
  /// read `ownerKeyProvider.quarantinedSeedKey` (gh#156 Signal A,
  /// `docs/specs/owner-key-seed-read-failure.md` §8) — a beid-only signal
  /// with no place on the `SensingCryptography` protocol itself, since
  /// every other implementation (test fakes) has no owner-key storage to
  /// report on.
  let ownerKeyProvider: OwnerKeyProvider

  init(
    ownerKeyProvider: OwnerKeyProvider = OwnerKeyProvider(keyStorage: BeidKeychainKeyStorage()),
    deviceSecretStore: DeviceSecretKeychainStore = .shared
  ) {
    self.ownerKeyProvider = ownerKeyProvider
    self.deviceSecretStore = deviceSecretStore
  }

  /// Called before a new session starts. A failed resolution cannot reuse a
  /// previous session's secret to admit the new one.
  func prepareSession() throws -> ResolvedDeviceSecretStorage {
    sessionStorage = nil
    let storage = try deviceSecretStore.resolve()
    sessionStorage = storage
    return storage
  }

  func signingSnapshot() throws -> any SensingCryptography {
    let snapshot = BarnardSensingCryptography(
      ownerKeyProvider: ownerKeyProvider,
      deviceSecretStore: deviceSecretStore
    )
    snapshot.sessionStorage = try sessionStorage ?? deviceSecretStore.resolve()
    return snapshot
  }

  func recoverySigningSnapshot() throws -> any SensingCryptography {
    let snapshot = BarnardSensingCryptography(
      ownerKeyProvider: ownerKeyProvider,
      deviceSecretStore: deviceSecretStore
    )
    snapshot.sessionStorage = try deviceSecretStore.resolve()
    return snapshot
  }

  private func identity() throws -> BarnardIdentity {
    BarnardIdentity(keyStorage: try sessionStorage ?? deviceSecretStore.resolve())
  }

  func eventSigningPublicKey(eventCode: String) throws -> Data {
    try identity().signingPublicKey(eventCode: eventCode)
  }

  func ownerPublicKey() throws -> Data {
    try ownerKeyProvider.publicKeyCompressed()
  }

  func signWindowReport(
    eventCode: String,
    bytes: Data
  ) throws -> SensingRecoverableSignature {
    SensingRecoverableSignature(
      barnard: try identity().sign(eventCode: eventCode, bytes: bytes)
    )
  }

  func signSelfProof(
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64
  ) throws -> SensingRecoverableSignature? {
    try ownerKeyProvider.signSelfProof(
      eventIdHash: eventIdHash,
      eventSigningPublicKey: eventSigningPublicKey,
      eninStart: eninStart,
      eninEnd: eninEnd
    ).map { SensingRecoverableSignature(barnardCore: $0) }
  }

  func signWalletAcknowledgement(
    walletAddress: Data,
    walletSignature: Data
  ) throws -> SensingRecoverableSignature? {
    try ownerKeyProvider.signWalletAcknowledgement(
      walletAddress: walletAddress,
      walletSignature: walletSignature
    ).map { SensingRecoverableSignature(barnardCore: $0) }
  }
}
