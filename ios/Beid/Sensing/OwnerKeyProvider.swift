// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BarnardCore
import Foundation
import Security

/// App-generated secp256k1 owner key — the cross-event identity anchor in
/// `commit = H(event signing key ‖ owner key ‖ salt)` (whitepaper §3.2,
/// `docs/specs/scan-protocol-model.md` §5). Resolved 2026-07-30 (D1): no
/// continuity for v1 — the key regenerates after a reinstall that does not
/// restore an encrypted backup. The seed lives in a non-synchronizable
/// Keychain item whose accessibility class permits OS-standard encrypted
/// backup and device-to-device migration.
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

  private let keyStorage: any OwnerKeySeedResolving
  private let randomSource: any OwnerKeyRandomBytesGenerating

  init(
    keyStorage: any OwnerKeySeedResolving = BeidKeychainKeyStorage(),
    randomSource: any OwnerKeyRandomBytesGenerating = SystemOwnerKeyRandomSource()
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
  func publicKeyCompressed() throws -> Data {
    Data(try keyPair().publicKeyCompressed)
  }

  /// Owner-key-signed self-proof (`docs/specs/barnard-binding-conformance.md`
  /// §2.2) — `nil` if `eventIdHash`/`eventSigningPublicKey` fail Barnard's
  /// own shape validation (see `BarnardCoreSigning.buildSelfProofMessage`).
  func signSelfProof(
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64
  ) throws -> BarnardCoreRecoverableSignature? {
    let pair = try keyPair()
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
  ) throws -> BarnardCoreRecoverableSignature? {
    BarnardCoreSigning.signWalletAcknowledgement(
      ownerPrivateKey: try keyPair().privateKey,
      walletAddress: Array(walletAddress),
      walletSignature: Array(walletSignature)
    )
  }

  private func keyPair() throws -> BarnardCoreSigningKeyPair {
    let seed = try resolveSeed()

    // Deliberately derive per operation after re-reading the seed. The
    // private key pair therefore has method-call scope instead of remaining
    // resident for this provider's lifetime.
    return BarnardCoreSigning.deriveOwnerKeyPair(accountSecret: seed)
  }

  func resolveSeed() throws -> [UInt8] {
    do {
      return try keyStorage.resolveSeed(forKey: Self.seedKey, randomSource: randomSource)
    } catch let error as OwnerKeyOperationError {
      throw error
    } catch let error as BeidKeychainKeyStorageError {
      throw OwnerKeyOperationError.storage(error)
    }
  }
}

enum OwnerKeyOperationError: Error, Equatable {
  case randomFailed(OSStatus)
  case invalidRandomByteCount(Int)
  case storage(BeidKeychainKeyStorageError)
}

protocol OwnerKeyRandomBytesGenerating {
  func randomBytes(count: Int) throws -> [UInt8]
}

struct SystemOwnerKeyRandomSource: OwnerKeyRandomBytesGenerating {
  func randomBytes(count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    guard status == errSecSuccess else { throw OwnerKeyOperationError.randomFailed(status) }
    return bytes
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
final class BeidUserDefaultsKeyStorage: OwnerKeySeedResolving, OwnerKeySeedQuarantineObserving {
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

  func removeBytes(forKey key: String) {
    defaults.removeObject(forKey: key)
  }

  func resolveSeed(
    forKey key: String,
    randomSource: any OwnerKeyRandomBytesGenerating
  ) throws -> [UInt8] {
    if let existing = bytes(forKey: key) { return existing }
    let generated = try randomSource.randomBytes(count: 32)
    guard generated.count == 32 else {
      throw OwnerKeyOperationError.invalidRandomByteCount(generated.count)
    }
    setBytes(generated, forKey: key)
    return generated
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

/// App-layer mirror of the SDK's internal `BarnardSystemRandomSource` for
/// non-owner-key session salts and nonces. Owner seed generation uses the
/// throwing `SystemOwnerKeyRandomSource` above.
struct BeidSystemRandomSource: BarnardCoreRandomSource {
  func randomBytes(count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return bytes
  }
}
