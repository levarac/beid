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

  /// Signal A of gh#156's regeneration-detectability mechanism
  /// (`docs/specs/owner-key-seed-read-failure.md` §8): non-nil once this
  /// session's key resolution has quarantined an unreadable stored seed.
  /// `nil` both when nothing has been quarantined yet and when
  /// `keyStorage` doesn't report quarantine at all (e.g. a plain test fake).
  var quarantinedSeedKey: String? {
    (keyStorage as? OwnerKeySeedQuarantineObserving)?.lastQuarantinedSeedKey
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

/// Narrow channel `OwnerKeyProvider` optionally consults to learn whether
/// its `keyStorage` quarantined an unreadable stored seed —
/// `BarnardCoreKeyStorage.bytes(forKey:)`'s own `[UInt8]?` boundary carries
/// no such signal (§3.2), so this is a beid-only addition layered outside
/// Barnard's protocol. Mirrors `SelfProofStore.quarantinedFileURL`'s
/// existing readable-property pattern
/// (`docs/specs/owner-key-seed-read-failure.md` §8).
protocol OwnerKeySeedQuarantineObserving: AnyObject {
  var lastQuarantinedSeedKey: String? { get }
}

/// App-layer mirror of the SDK's internal `BarnardUserDefaultsKeyStorage`
/// (not public from `Barnard`/`BarnardCore`) — same plain-`UserDefaults`
/// storage level as `DeviceSecret`, per `OwnerKeyProvider`'s doc comment.
///
/// A class, not a struct: quarantine detection (gh#156) needs
/// `bytes(forKey:)` — a non-`mutating` `BarnardCoreKeyStorage` requirement
/// — to record that it happened, so `OwnerKeyProvider` can read it back
/// afterward via `OwnerKeySeedQuarantineObserving`.
final class BeidUserDefaultsKeyStorage: BarnardCoreKeyStorage, OwnerKeySeedQuarantineObserving {
  let defaults: UserDefaults
  private(set) var lastQuarantinedSeedKey: String?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Distinguishes "never stored" from "stored but unreadable" before
  /// `BarnardCoreKeyManager.loadOrCreate` ever sees this key
  /// (`docs/specs/owner-key-seed-read-failure.md` §5) — `loadOrCreate`'s own
  /// `[UInt8]?` boundary cannot make that distinction (§3.2), so it has to
  /// happen here, on beid's side of the port. The validity test is
  /// `count == 32`, not `loadOrCreate`'s own `>= minimumByteCount`:
  /// `BarnardCoreSigning.deriveOwnerKeyPair` traps on anything other than
  /// exactly 32 bytes, so a too-long stored value must be rejected here
  /// too, not only a too-short one (§7).
  func bytes(forKey key: String) -> [UInt8]? {
    guard defaults.object(forKey: key) != nil else { return nil }
    guard let data = defaults.data(forKey: key), data.count == 32 else {
      quarantine(key: key)
      return nil
    }
    return Array(data)
  }

  func setBytes(_ bytes: [UInt8], forKey key: String) {
    defaults.set(Data(bytes), forKey: key)
  }

  /// Preserves whatever raw value is stored under `key` (wrong type or
  /// wrong length — `bytes(forKey:)` above has already determined it is one
  /// of the two) at a new key before clearing the canonical one, so
  /// `loadOrCreate`'s subsequent generate-and-store call proceeds against a
  /// genuinely, definitionally empty key rather than discarding the
  /// original value unseen. Mirrors `CorruptStoreQuarantine`'s file-rename
  /// principle adapted to `UserDefaults`, which has no rename primitive of
  /// its own (§3.3, §6). `object(forKey:)`, not `data(forKey:)`, on
  /// purpose: the raw value must be copied verbatim regardless of its
  /// concrete type.
  private func quarantine(key: String) {
    let rawValue = defaults.object(forKey: key)
    let timestampMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    let quarantineKey = "\(key).quarantine.\(timestampMilliseconds)-\(UUID().uuidString.lowercased())"
    defaults.set(rawValue, forKey: quarantineKey)
    defaults.removeObject(forKey: key)
    lastQuarantinedSeedKey = quarantineKey
    print("Quarantined an unreadable owner key seed at UserDefaults key \(quarantineKey)")
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
