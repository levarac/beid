// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import Foundation
import Security

/// App-generated secp256k1 owner key — the cross-event identity anchor in
/// `commit = H(event signing key ‖ owner key ‖ salt)` (whitepaper §3.2,
/// `docs/specs/scan-protocol-model.md` §5). Resolved 2026-07-30 (D1): no
/// continuity for v1 — the key regenerates per device/reinstall, stored at
/// the same level `BarnardIdentity`'s `DeviceSecret` uses today (plain
/// `UserDefaults`, not Keychain/iCloud; that migration is a deferred slice
/// per `docs/specs/scan-slice2-redesign.md` §9.1).
///
/// Reuses `BarnardCoreSigning`'s already-tested secp256k1 derivation
/// (`BarnardCore` is the same pinned `Barnard` package/version already in
/// the app, just a second product from it — no new external dependency)
/// rather than hand-rolling elliptic-curve math in the app layer. The
/// random seed below is generated independently of `DeviceSecret`, so the
/// owner key has no relationship to — and no continuity story inherited
/// from — the event signing key/TEK root.
///
/// The owner private key never leaves this type — only the public key
/// (`publicKeyCompressed()`) and signatures (`signSelfProof`,
/// `signWalletAcknowledgement`) do, mirroring `BarnardIdentity.sign(eventCode:bytes:)`'s
/// gatekeeping of the event signing key (`docs/specs/barnard-binding-conformance.md` §2.1).
final class OwnerKeyProvider {
  private static let seedKey = "beid.ownerKeySeed"

  private let keyStorage: any BarnardCoreKeyStorage
  private let randomSource: any BarnardCoreRandomSource
  /// The owner key is stable for the device's lifetime (until reinstall) —
  /// cached after first derivation so repeated `SensingCoordinator
  /// .beginEventFound` calls (once per scan session) don't re-run
  /// secp256k1 scalar multiplication every time.
  private var cachedKeyPair: BarnardCoreSigningKeyPair?

  init(
    keyStorage: any BarnardCoreKeyStorage = BeidUserDefaultsKeyStorage(),
    randomSource: any BarnardCoreRandomSource = BeidSystemRandomSource()
  ) {
    self.keyStorage = keyStorage
    self.randomSource = randomSource
  }

  /// Compressed secp256k1 public key — the only owner-key component that
  /// ever leaves the device (per the key roster, secrets never leave;
  /// only public keys, signatures, and commitment hashes do).
  func publicKeyCompressed() -> Data {
    Data(keyPair().publicKeyCompressed)
  }

  /// Owner-key-signed self-proof (`docs/specs/barnard-binding-conformance.md`
  /// §2.2) — `nil` if `eventIdHash`/`eventSigningPublicKey` fail Barnard's
  /// own shape validation (see `BarnardCoreSigning.buildSelfProofMessage`).
  func signSelfProof(
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64
  ) -> BarnardCoreRecoverableSignature? {
    let pair = keyPair()
    return BarnardCoreSigning.signSelfProof(
      ownerPrivateKey: pair.privateKey,
      eventIdHash: Array(eventIdHash),
      eventSigningPublicKey: Array(eventSigningPublicKey),
      eninStart: eninStart,
      eninEnd: eninEnd,
      ownerPublicKey: pair.publicKeyCompressed
    )
  }

  /// Owner-key-signed wallet acknowledgement (`docs/specs/barnard-binding-conformance.md`
  /// §2.4) — `nil` if `walletAddress`/`walletSignature` fail Barnard's own
  /// shape validation (see `BarnardCoreSigning.buildWalletAcknowledgementMessage`).
  func signWalletAcknowledgement(
    walletAddress: Data,
    walletSignature: Data
  ) -> BarnardCoreRecoverableSignature? {
    BarnardCoreSigning.signWalletAcknowledgement(
      ownerPrivateKey: keyPair().privateKey,
      walletAddress: Array(walletAddress),
      walletSignature: Array(walletSignature)
    )
  }

  private func keyPair() -> BarnardCoreSigningKeyPair {
    if let cachedKeyPair {
      return cachedKeyPair
    }
    let seed = BarnardCoreKeyManager.loadOrCreate(
      key: Self.seedKey,
      minimumByteCount: 32,
      generatedByteCount: 32,
      storage: keyStorage,
      randomSource: randomSource
    )
    let keyPair = BarnardCoreSigning.deriveOwnerKeyPair(accountSecret: seed)
    cachedKeyPair = keyPair
    return keyPair
  }
}

/// App-layer mirror of the SDK's internal `BarnardUserDefaultsKeyStorage`
/// (not public from `Barnard`/`BarnardCore`) — same plain-`UserDefaults`
/// storage level as `DeviceSecret`, per `OwnerKeyProvider`'s doc comment.
struct BeidUserDefaultsKeyStorage: BarnardCoreKeyStorage {
  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func bytes(forKey key: String) -> [UInt8]? {
    defaults.data(forKey: key).map(Array.init)
  }

  func setBytes(_ bytes: [UInt8], forKey key: String) {
    defaults.set(Data(bytes), forKey: key)
  }
}

/// App-layer mirror of the SDK's internal `BarnardSystemRandomSource`.
struct BeidSystemRandomSource: BarnardCoreRandomSource {
  func randomBytes(count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return bytes
  }
}
