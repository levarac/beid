// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

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
  func eventSigningPublicKey(eventCode: String) -> Data
  func ownerPublicKey() -> Data

  func signWindowReport(
    eventCode: String,
    bytes: Data
  ) -> SensingRecoverableSignature

  func signSelfProof(
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64
  ) -> SensingRecoverableSignature?

  func signWalletAcknowledgement(
    walletAddress: Data,
    walletSignature: Data
  ) -> SensingRecoverableSignature?
}

/// Production adapter for the two Barnard-backed key owners used by sensing.
/// Each method makes exactly one provider call and copies its result without
/// adding sensing decisions or re-checking Barnard semantics.
final class BarnardSensingCryptography: SensingCryptography {
  private let identity = BarnardIdentity()
  /// Not `private`: `SensingCoordinator` downcasts to this concrete type to
  /// read `ownerKeyProvider.quarantinedSeedKey` (gh#156 Signal A,
  /// `docs/specs/owner-key-seed-read-failure.md` §8) — a beid-only signal
  /// with no place on the `SensingCryptography` protocol itself, since
  /// every other implementation (test fakes) has no owner-key storage to
  /// report on.
  let ownerKeyProvider: OwnerKeyProvider

  init(ownerKeyProvider: OwnerKeyProvider = OwnerKeyProvider(keyStorage: BeidKeychainKeyStorage())) {
    self.ownerKeyProvider = ownerKeyProvider
  }

  func eventSigningPublicKey(eventCode: String) -> Data {
    identity.signingPublicKey(eventCode: eventCode)
  }

  func ownerPublicKey() -> Data {
    ownerKeyProvider.publicKeyCompressed()
  }

  func signWindowReport(
    eventCode: String,
    bytes: Data
  ) -> SensingRecoverableSignature {
    SensingRecoverableSignature(
      barnard: identity.sign(eventCode: eventCode, bytes: bytes)
    )
  }

  func signSelfProof(
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64
  ) -> SensingRecoverableSignature? {
    ownerKeyProvider.signSelfProof(
      eventIdHash: eventIdHash,
      eventSigningPublicKey: eventSigningPublicKey,
      eninStart: eninStart,
      eninEnd: eninEnd
    ).map { SensingRecoverableSignature(barnardCore: $0) }
  }

  func signWalletAcknowledgement(
    walletAddress: Data,
    walletSignature: Data
  ) -> SensingRecoverableSignature? {
    ownerKeyProvider.signWalletAcknowledgement(
      walletAddress: walletAddress,
      walletSignature: walletSignature
    ).map { SensingRecoverableSignature(barnardCore: $0) }
  }
}
