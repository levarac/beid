// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import BarnardCore
import BeidSharedKit
import CryptoKit
import Foundation

/// A numeric clock reading, not a claim of independently authenticated time.
enum VenueClockReading: Equatable {
  case available(unixSeconds: Int64)
  case unavailable
}

/// Consumers MUST switch exhaustively over these four CaseIterable enums,
/// without a default. Synthesized allCases checks outcome coverage; exhaustive
/// switches separately make an added outcome break a consumer's build.
enum VenueImportFailure: String, CaseIterable, Hashable {
  case malformedOrOutOfBounds
  case handoffMismatch
  case unsupportedDeployment
  case registryUnavailable
  case registrySourceMismatch
  case anchoredRecordMissing
  case definitionRejected
  /// The anchored definition gates entry on a code, and serving gated events
  /// is not supported. NATIVE-ONLY: `shared/` emits no identity code for
  /// this, so `importFailure(forIdentityCode:)` never produces it and stays a
  /// closed table over `shared/`'s six codes. `malformedOrOutOfBounds` is the
  /// existing precedent for a case this host decides on its own.
  ///
  /// Decided at import rather than at serving: the operator should learn when
  /// they load the pack, not by watching it quietly fail to serve. A gated
  /// definition reaching `evaluate` therefore means the registry changed the
  /// definition after a successful import, which is what `staleDefinition`
  /// already means.
  case gatedEventUnsupported
}

enum VenueServingBlock: String, CaseIterable, Hashable {
  case clockUnavailable
  case notStarted
  case expired
  case noCurrentEnvelope
  case envelopeRejected
  case staleDefinition
  case registryUnavailable
}

enum VenueRadioState: String, CaseIterable, Hashable {
  case stopped
  case waitingForBluetooth
  /// The SDK reports this before the OS completes startAdvertising. It is
  /// deliberately not a confirmed-advertising or receiver-observed state.
  case advertisingRequested
  case failed
}

enum VenueRadioFailure: String, CaseIterable, Hashable, Error {
  case containerInstallRejected
  case bluetoothUnavailable
  case advertiseFailed
  case gattServiceFailed
}

/// Moving context out of the enum must not permit contradictory combinations.
/// Only notStarted carries a retry instant, and it must be nonnegative.
struct VenueServingRejection: Equatable {
  let reason: VenueServingBlock
  let recheckAtUnixSeconds: Int64?

  init?(reason: VenueServingBlock, recheckAtUnixSeconds: Int64? = nil) {
    switch reason {
    case .notStarted:
      guard let recheckAtUnixSeconds, recheckAtUnixSeconds >= 0 else { return nil }
    case .clockUnavailable, .expired, .noCurrentEnvelope, .envelopeRejected,
         .staleDefinition, .registryUnavailable:
      guard recheckAtUnixSeconds == nil else { return nil }
    }
    self.reason = reason
    self.recheckAtUnixSeconds = recheckAtUnixSeconds
  }
}

/// A failed update always has a cause; other states never carry one.
struct VenueRadioUpdate: Equatable {
  let state: VenueRadioState
  let failure: VenueRadioFailure?

  init?(state: VenueRadioState, failure: VenueRadioFailure? = nil) {
    switch state {
    case .failed:
      guard failure != nil else { return nil }
    case .stopped, .waitingForBluetooth, .advertisingRequested:
      guard failure == nil else { return nil }
    }
    self.state = state
    self.failure = failure
  }
}

/// Public source artifacts, safe to persist. They must be imported again after
/// restart; persistence is not a cache of verification or a serving permit.
struct VenuePublicArtifact: Equatable {
  let bundleBytes: Data
  let handoffBytes: Data
}

struct VenueArtifactIdentity: Equatable {
  let eventIdHex: String
  let definitionSequence: Int64
  let bundleDigestHex: String
}

/// An opaque identity-verification receipt. This does NOT authenticate every
/// envelope, prove current eligibility, or establish event-wide coverage.
/// EventDefinitionV1 has no display name; only an SDK-verified permit has one.
/// No production construction path exists in the initial interface commit.
final class VenueImportedBundle {
  let identity: VenueArtifactIdentity
  let publicArtifact: VenuePublicArtifact

  fileprivate init(identity: VenueArtifactIdentity, publicArtifact: VenuePublicArtifact) {
    self.identity = identity
    self.publicArtifact = publicArtifact
  }
}

enum VenueVerificationScope: Equatable {
  case currentLeaseOnly
}

/// Exact SDK-verified hop-zero bytes with a protocol-owned exclusive deadline.
/// Consumers may format these facts but must not derive/extend the deadline,
/// choose another slice, or call this evidence of a successful radio effect.
/// Only this file can construct a production permit; the initial interface
/// commit intentionally contains no production verification implementation.
final class VenueServePermit {
  let identity: VenueArtifactIdentity
  let container: Data
  let displayName: String
  let payloadDigestHex: String
  let currentEnin: Int64
  let stopAtUnixSeconds: Int64
  let verificationScope: VenueVerificationScope = .currentLeaseOnly

  fileprivate init(
    identity: VenueArtifactIdentity,
    container: Data,
    displayName: String,
    payloadDigestHex: String,
    currentEnin: Int64,
    stopAtUnixSeconds: Int64
  ) {
    self.identity = identity
    self.container = container
    self.displayName = displayName
    self.payloadDigestHex = payloadDigestHex
    self.currentEnin = currentEnin
    self.stopAtUnixSeconds = stopAtUnixSeconds
  }
}

enum VenueImportResult {
  case imported(VenueImportedBundle)
  case rejected(VenueImportFailure)
}

enum VenueServingDecision {
  case permitted(VenueServePermit)
  case blocked(VenueServingRejection)
}

@MainActor
protocol VenueBundleVerifying {
  /// Import is clock-free. It binds public bytes to the expected handoff and
  /// configured registry source, then verifies the named anchored definition.
  func importBundle(bundleBytes: Data, handoffBytes: Data) async -> VenueImportResult
  func evaluate(_ imported: VenueImportedBundle, clock: VenueClockReading) async -> VenueServingDecision
}

/// Additive signed-container port; the existing v1 VenueDeviceBroadcasting
/// protocol stays unchanged until the native effects/UI follow-up replaces it.
@MainActor
protocol VenueSignedContainerBroadcasting {
  var onState: ((VenueRadioUpdate) -> Void)? { get set }
  /// Clear BEFORE replacing. Barnard retains the old container when a new
  /// install throws. On failure clear again; do not leave earlier bytes live.
  func installAndStart(_ permit: VenueServePermit) throws
  func clearAndStop()
}

// MARK: - Production verifier (beid#432)

/// Pure, dependency-free helpers factored out of `ProductionVenueBundleVerifier`
/// so the security-critical mappings and arithmetic can be unit-tested
/// directly, without a registry client, a network, or a chain-anchored bundle.
///
/// The two lookup tables here (`importFailure(forIdentityCode:)` and the
/// re-verification mapping in `ProductionVenueBundleVerifier` below) are
/// native-only judgement calls: `shared/` does not specify them, and
/// `docs/venue-serving-contract.md` says the analogous serving-code mapping
/// "goes to an independent reviewer... as a separate object." These are that
/// object, kept intentionally separable so a reviewer can audit them without
/// reading the rest of the verifier.
enum VenueBundleVerificationLogic {
  /// `VenueBundleIdentity.kt`'s snake_case failure codes, verbatim, mapped to
  /// the native camelCase cases. An explicit table rather than a generated
  /// transform, so a code `shared/` adds later fails this lookup (`nil`)
  /// instead of silently landing on the wrong case.
  static func importFailure(forIdentityCode code: String) -> VenueImportFailure? {
    switch code {
    case "handoff_mismatch": return .handoffMismatch
    case "deployment_mismatch": return .unsupportedDeployment
    case "registry_unavailable": return .registryUnavailable
    case "registry_source_mismatch": return .registrySourceMismatch
    case "definition_not_registered": return .anchoredRecordMissing
    case "invalid_definition": return .definitionRejected
    default: return nil
    }
  }

  /// `VenueCurrentLease.kt`'s block codes match the native case names
  /// verbatim by design (`docs/venue-serving-contract.md`), so this is a
  /// `rawValue` lookup, not a translation table.
  static func servingBlock(forCode code: String) -> VenueServingBlock? {
    VenueServingBlock(rawValue: code)
  }

  /// `EventJoinMode` is a `shared/` enum with two cases today; B005 encodes
  /// join mode as a single byte, 0 or 1. A future third case must fail
  /// closed (`nil`) rather than silently guess a byte for it.
  static func barnardJoinMode(
    _ mode: ExportedKotlinPackages.org.levarac.parallax.registry.EventJoinMode?
  ) -> UInt8? {
    switch mode {
    case .OPEN: return 0
    case .GATED: return 1
    case nil: return nil
    @unknown default: return nil
    }
  }

  /// Whether an anchored definition can be projected onto a
  /// `BarnardEventDefinitionV1` at all, as an exhaustive outcome rather than
  /// the single `nil` this replaced.
  ///
  /// The two inputs are not independent, which is why one `nil` was the wrong
  /// shape. `EventDefinitionCborCodec.kt:298-307` REQUIRES an open definition
  /// to carry an `eventCodeHash` (and requires it to equal the canonical
  /// `eventCodeHashForOpenEventV1(eventId)`), and FORBIDS a gated one from
  /// carrying any. A decoded definition therefore announces its join mode by
  /// hash presence alone: "gated" and "hash missing" are the same observation
  /// seen from two sides. Collapsing them lost which one it was, so every
  /// gated event surfaced as `envelopeRejected` -- a verdict about an
  /// envelope that had verified perfectly well.
  enum DefinitionProjection: Equatable {
    /// An open event, carrying the well-formed 8-byte hash B005 compares
    /// against.
    case open
    /// The event gates entry on a code. A gated definition publishes no
    /// `eventCodeHash` by construction, so this path has nothing to compare a
    /// B005 envelope's hash against. Sourcing one through a trusted input is
    /// a design phase 1 does not have; gated events are unsupported here.
    case gatedUnsupported
    /// Neither: no join mode at all, or an open definition whose hash is
    /// missing or malformed. Fails closed.
    case unusable
  }

  /// The import-time verdict for a projection. `nil` means import may
  /// proceed.
  ///
  /// Only the gated case is decided here, deliberately. Import is clock-free
  /// and identity-only, and a definition that fails to project for any OTHER
  /// reason -- no join mode at all, or an open definition whose hash is
  /// missing or malformed -- keeps the path it has always had, where the
  /// serving decision is what refuses it. Widening this to `.unusable` would
  /// relocate an existing refusal, which is not what this change is for.
  static func importFailure(forProjection projection: DefinitionProjection) -> VenueImportFailure? {
    switch projection {
    case .gatedUnsupported:
      return .gatedEventUnsupported
    case .open, .unusable:
      return nil
    }
  }

  static func definitionProjection(
    joinMode: ExportedKotlinPackages.org.levarac.parallax.registry.EventJoinMode?,
    eventCodeHash: [UInt8]?
  ) -> DefinitionProjection {
    switch joinMode {
    case .GATED:
      return .gatedUnsupported
    case .OPEN:
      guard let eventCodeHash, eventCodeHash.count == 8 else { return .unusable }
      return .open
    case nil:
      return .unusable
    @unknown default:
      return .unusable
    }
  }

  /// Floor division/modulo matching Kotlin's `Math.floorDiv`/`floorMod`
  /// (rounds toward negative infinity; Swift's `/`/`%` truncate toward
  /// zero). Duplicated from `BarnardB005EnvelopeV2.registryAgreement`'s
  /// private helpers of the same name/behavior, because that function
  /// exposes only its agree/mismatch verdict, never the two ENIN bounds a
  /// coverage check over the WHOLE definition window needs. The barnard
  /// Kotlin/Swift pair already duplicates this exact pair of functions
  /// across languages for the same reason, so a third copy here follows an
  /// established pattern rather than starting a new one.
  static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b, r = a % b
    return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
  }

  static func floorMod(_ a: Int64, _ b: Int64) -> Int64 {
    let r = a % b
    return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
  }

  /// The definition's Unix-second validity window, converted to the same
  /// inclusive ENIN convention `BarnardB005EnvelopeV2.registryAgreement`
  /// uses for its `registryStartEnin`/`registryEndEnin` (start rounded up,
  /// end rounded down). Returns `nil` for a malformed window, matching that
  /// function's own well-formedness guard.
  static func definitionEninWindow(
    validFromUnixSeconds: Int64,
    validUntilUnixSeconds: Int64,
    eninSeconds: Int64
  ) -> (start: Int64, end: Int64)? {
    guard eninSeconds > 0, validFromUnixSeconds >= 0, validUntilUnixSeconds >= 0,
          validFromUnixSeconds <= validUntilUnixSeconds
    else { return nil }
    let start = -floorDiv(-validFromUnixSeconds, eninSeconds)
    let q = floorDiv(validUntilUnixSeconds, eninSeconds)
    let r = floorMod(validUntilUnixSeconds, eninSeconds)
    let end = r == eninSeconds - 1 ? q : q - 1
    return (start, end)
  }

  /// True when the union of `candidates` (each `[from, to)`, half-open)
  /// leaves any ENIN in `[requiredStart, requiredEnd)` uncovered.
  ///
  /// `requiredEnd` is EXCLUSIVE, deliberately: per
  /// `BarnardB005EnvelopeV2.registryAgreement`'s own documentation, the ENIN
  /// at `requiredEnd` itself can never be covered by any envelope
  /// (`relayExpiresAtEnin <= validThroughEnin` bars an envelope from ending
  /// after the definition's last inclusive ENIN), so requiring an inclusive
  /// `[requiredStart, requiredEnd]` would reject every real bundle.
  static func hasCoverageGap(
    candidates: [(from: Int64, to: Int64)],
    requiredStart: Int64,
    requiredEnd: Int64
  ) -> Bool {
    guard requiredStart < requiredEnd else { return false }
    let sorted = candidates
      .filter { $0.from < $0.to }
      .sorted { $0.from < $1.from }
    var coveredThrough = requiredStart
    for candidate in sorted {
      if candidate.from > coveredThrough { break }
      coveredThrough = max(coveredThrough, candidate.to)
      if coveredThrough >= requiredEnd { return false }
    }
    return coveredThrough < requiredEnd
  }

  /// The coverage verdict, as an exhaustive three-way outcome rather than an
  /// optional/boolean pair a caller could chain with `if let` and
  /// accidentally fall through on `nil`. `.uncomputable` covers BOTH "no
  /// envelope verified at all" (`referenceEninSeconds == nil`) and "the
  /// definition's own window will not convert to ENIN terms"
  /// (`definitionEninWindow` returns `nil`) -- "could not determine
  /// coverage" and "coverage is satisfied" must never produce the same
  /// outcome, so both map to a refusal here, not to a pass-through. Whether
  /// the second case is actually reachable given this file's window formula
  /// matching `BarnardB005EnvelopeV2.registryAgreement`'s is a cross-repo
  /// invariant this file cannot enforce on its own, so it is not assumed
  /// impossible.
  ///
  /// PHASE 2 MACHINERY. Nothing in `ProductionVenueBundleVerifier` calls this
  /// today: the venue lane owner's 2026-09-10 ruling
  /// (`docs/plans/2026-09-10-venue-bundle-import.md`) scopes phase 1 to a
  /// current lease and explicitly not to complete signed schedule coverage,
  /// so `evaluateCurrentLease` deliberately does not gate on it. It is kept,
  /// with its tests, because phase 2 needs exactly this.
  enum CoverageOutcome: Equatable { case uncomputable, gap, covered }

  /// KNOWN LIMITATION, latent rather than live: `coverageIntervals` are
  /// compared as raw ENIN numbers against a window converted at the single
  /// `referenceEninSeconds` granularity, without checking that every interval
  /// was computed at that same granularity. A single real bundle today only
  /// ever carries one envelope (barnard's producer emits one per bundle;
  /// nothing writes a multi-envelope VenueBundleV1 yet -- see
  /// levarac/parallax#108), so this cannot be exercised now. It would matter
  /// for a bundle whose envelopes legitimately (or adversarially) mix
  /// eninSeconds values once multi-envelope bundles exist: mixing ENIN
  /// numbers computed at different granularities would compare incompatible
  /// units. A phase-2 caller building `coverageIntervals` owes that check.
  static func coverageOutcome(
    referenceEninSeconds: UInt16?,
    validFromUnixSeconds: Int64,
    validUntilUnixSeconds: Int64,
    coverageIntervals: [(from: Int64, to: Int64)]
  ) -> CoverageOutcome {
    guard let referenceEninSeconds,
          let window = definitionEninWindow(
            validFromUnixSeconds: validFromUnixSeconds,
            validUntilUnixSeconds: validUntilUnixSeconds,
            eninSeconds: Int64(referenceEninSeconds)
          )
    else { return .uncomputable }
    return hasCoverageGap(candidates: coverageIntervals, requiredStart: window.start, requiredEnd: window.end)
      ? .gap : .covered
  }
}

/// Production `VenueBundleVerifying`. This is the first production caller of
/// the shared decode/identity/lease functions and of Barnard's B005 envelope
/// verification together; see `docs/venue-serving-contract.md` and beid#432.
///
/// Lives in this file because `VenueImportedBundle` and `VenueServePermit`
/// have `fileprivate` initializers by design (see their doc comments above):
/// only code in this file may construct a production receipt or permit.
///
/// `evaluate` re-reads the registry and re-derives identity from the
/// receipt's own stored bytes on every call — it never reuses the
/// `VenueBundleIdentity` `importBundle` saw. Caching that would let a
/// registry update after import stay invisible ("cache consistency is not
/// freshness"), which is exactly the failure mode `staleDefinition` exists
/// to catch.
@MainActor
final class ProductionVenueBundleVerifier: VenueBundleVerifying {
  private let registryClient: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient?
  private let nameValidator: any BarnardB005DisplayNameNormalizing

  init(
    registryClient: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient?,
    nameValidator: any BarnardB005DisplayNameNormalizing = BarnardB005NativeDisplayNameNormalizer()
  ) {
    self.registryClient = registryClient
    self.nameValidator = nameValidator
  }

  func importBundle(bundleBytes: Data, handoffBytes: Data) async -> VenueImportResult {
    // Hex, not a constructed ByteArray: Swift Export's ByteArray constructor
    // is a fatalError() stub in this toolchain (confirmed by reading the
    // generated bridging source at
    // shared/build/SwiftExport/iosSimulatorArm64/Debug/files/KotlinStdlib/KotlinStdlib.swift),
    // so decodeVenueBundleHex/decodeVenueHandoffHex are the only working path
    // a Swift caller has into these decoders. See their doc comments in
    // VenueBundleCodec.kt.
    guard
      let bundle = ExportedKotlinPackages.org.levarac.parallax.venue.decodeVenueBundleHex(
        hex: Self.hexString([UInt8](bundleBytes))
      ),
      let handoff = ExportedKotlinPackages.org.levarac.parallax.venue.decodeVenueHandoffHex(
        hex: Self.hexString([UInt8](handoffBytes))
      )
    else {
      return .rejected(.malformedOrOutOfBounds)
    }

    switch await verifyIdentity(bundle: bundle, handoff: handoff) {
    case .noClient:
      return .rejected(.registryUnavailable)
    case .rejected(let code):
      return .rejected(VenueBundleVerificationLogic.importFailure(forIdentityCode: code) ?? .definitionRejected)
    case .ok(let identity):
      // Identity is sound, but this host serves open events only. Refusing
      // here rather than at serving time is what makes the outcome legible:
      // the operator is told when they load the pack.
      if let failure = VenueBundleVerificationLogic.importFailure(
        forProjection: Self.definitionProjection(of: identity.definition)
      ) {
        return .rejected(failure)
      }
      return .imported(VenueImportedBundle(
        identity: VenueArtifactIdentity(
          eventIdHex: Self.hexString(Self.swiftBytes(fromKotlin: bundle.eventId.toByteArray())),
          definitionSequence: bundle.definitionSequence,
          bundleDigestHex: Self.hexString(Self.swiftBytes(fromKotlin: bundle.bundleDigest.toByteArray()))
        ),
        publicArtifact: VenuePublicArtifact(bundleBytes: bundleBytes, handoffBytes: handoffBytes)
      ))
    }
  }

  func evaluate(_ imported: VenueImportedBundle, clock: VenueClockReading) async -> VenueServingDecision {
    guard case .available(let now) = clock else {
      return .blocked(VenueServingRejection(reason: .clockUnavailable)!)
    }
    guard
      let bundle = ExportedKotlinPackages.org.levarac.parallax.venue.decodeVenueBundleHex(
        hex: Self.hexString([UInt8](imported.publicArtifact.bundleBytes))
      ),
      let handoff = ExportedKotlinPackages.org.levarac.parallax.venue.decodeVenueHandoffHex(
        hex: Self.hexString([UInt8](imported.publicArtifact.handoffBytes))
      )
    else {
      // The receipt's own stored bytes no longer decode. This can only
      // follow corruption after a successful import; there is no dedicated
      // outcome for it, so it is treated as an unavailable source of truth
      // rather than invented as a new case.
      return .blocked(VenueServingRejection(reason: .registryUnavailable)!)
    }

    switch await verifyIdentity(bundle: bundle, handoff: handoff) {
    case .noClient:
      return .blocked(VenueServingRejection(reason: .registryUnavailable)!)
    case .rejected(let code):
      return .blocked(Self.reimportFailureRejection(forIdentityCode: code))
    case .ok(let identity):
      return await evaluateCurrentLease(identity: identity, bundle: bundle, now: now)
    }
  }

  // MARK: - Identity

  private enum IdentityOutcome {
    case ok(ExportedKotlinPackages.org.levarac.parallax.venue.VenueBundleIdentity)
    case rejected(String)
    /// No registry client is configured at all (e.g. missing Info.plist
    /// reader address). Distinct from a configured client whose read
    /// failed, which still reaches `verifyVenueBundleIdentity` and comes
    /// back as `.rejected("registry_unavailable")`.
    case noClient
  }

  private func verifyIdentity(
    bundle: ExportedKotlinPackages.org.levarac.parallax.venue.VenueBundle,
    handoff: ExportedKotlinPackages.org.levarac.parallax.venue.VenueHandoff
  ) async -> IdentityOutcome {
    let eventIdHex = Self.hexString(Self.swiftBytes(fromKotlin: bundle.eventId.toByteArray()))
    guard let resolution = await resolveRegistry(eventIdHex: eventIdHex) else {
      return .noClient
    }
    let check = ExportedKotlinPackages.org.levarac.parallax.venue.verifyVenueBundleIdentity(
      bundle: bundle, handoff: handoff, registry: resolution
    )
    if let identity = check.identity { return .ok(identity) }
    return .rejected(check.failureCode ?? "unknown")
  }

  private func resolveRegistry(
    eventIdHex: String
  ) async -> ExportedKotlinPackages.org.levarac.parallax.registry.RegistryResolution? {
    guard let registryClient else { return nil }
    return await withCheckedContinuation { continuation in
      _ = registryClient.resolve(
        eventIdHex: eventIdHex,
        pin: ExportedKotlinPackages.org.levarac.parallax.registry.safeRegistryReadPin()
      ) { resolution in
        continuation.resume(returning: resolution)
      }
    }
  }

  /// Maps a re-verification failure (identity re-checked inside `evaluate`,
  /// not `importBundle`) to a `VenueServingBlock`. `shared/`'s identity
  /// codes have no serving-block counterpart at all -- `verifyVenueBundleIdentity`
  /// is clock-free and `VenueServingBlock` is about the current instant --
  /// so this is a native-only judgement call, not a `shared/`-specified
  /// mapping. `handoff_mismatch` and `deployment_mismatch` are pure
  /// functions of bytes that already imported successfully once, so
  /// reaching them here should not happen in practice; they still need a
  /// safe mapping, so they share the `staleDefinition` bucket with
  /// `definition_not_registered`/`invalid_definition` ("this bundle's
  /// registration truth changed, or was never sound enough to keep
  /// serving"). `registry_unavailable`/`registry_source_mismatch` are the
  /// two that can genuinely change between calls (a network flake, or a
  /// reconfigured reader address) and map to `.registryUnavailable`.
  private static func reimportFailureRejection(forIdentityCode code: String) -> VenueServingRejection {
    let reason: VenueServingBlock =
      switch code {
      case "registry_unavailable", "registry_source_mismatch": .registryUnavailable
      default: .staleDefinition
      }
    return VenueServingRejection(reason: reason)!
  }

  // MARK: - Current lease

  /// Re-verifies every envelope against the current clock's ENIN, then asks
  /// `shared/` for the current decision.
  ///
  /// The probe reads each envelope's own untrusted `eninSeconds` hint (from
  /// `schedulingFields(container:)`) only to CHOOSE which ENIN to ask
  /// `BarnardB005EnvelopeV2.verify` about, which is exactly the trust
  /// boundary `BarnardB005SchedulingFields` documents. A successful
  /// verification then reveals the envelope's true (verified)
  /// `[validFromEnin, relayExpiresAtEnin)` window, since those bounds are
  /// envelope-level constants independent of which ENIN inside them `verify`
  /// was asked about.
  ///
  /// `registryAgreement` is checked here, never left to
  /// `evaluateVenueCurrentLease`: `shared/` cannot verify that a
  /// `VenueVerifiedScheduling` actually came from the SDK or that it
  /// matches the anchored definition, so an envelope that verifies but
  /// disagrees with the registry is treated as rejected, exactly like a
  /// failed signature.
  ///
  /// This method deliberately does NOT check signed schedule coverage over
  /// the definition's whole validity window. See the comment before the
  /// `evaluateVenueCurrentLease` call below for the ruling that puts that in
  /// phase 2.
  private func evaluateCurrentLease(
    identity: ExportedKotlinPackages.org.levarac.parallax.venue.VenueBundleIdentity,
    bundle: ExportedKotlinPackages.org.levarac.parallax.venue.VenueBundle,
    now: Int64
  ) async -> VenueServingDecision {
    let barnardDefinition: BarnardEventDefinitionV1
    switch Self.barnardDefinition(from: identity.definition) {
    case .usable(let definition):
      barnardDefinition = definition
    case .gatedUnsupported:
      // `importBundle` already refuses a gated definition
      // (`.gatedEventUnsupported`), so reaching this arm means the registry
      // replaced the definition with a gated one AFTER a successful import.
      // That is exactly what `staleDefinition` means -- "this bundle's
      // registration truth changed" -- and its copy, which tells the operator
      // a newer definition exists and to load the current bundle, is true
      // here. A native-only `VenueServingBlock` case is not available:
      // `VenueCurrentLease.kt:50-53` requires these raw values to match
      // `shared/`'s block codes verbatim, with no translation step.
      return .blocked(VenueServingRejection(reason: .staleDefinition)!)
    case .unusable:
      // The anchored definition carries no usable joinMode/eventCodeHash
      // pair, so no envelope can be compared against it at all. There is no
      // dedicated outcome for this; every candidate is treated as rejected.
      return .blocked(VenueServingRejection(reason: .envelopeRejected)!)
    }

    let envelopeCount = Int(bundle.envelopeCount)
    var currentLeaseCandidates:
      [ExportedKotlinPackages.org.levarac.parallax.venue.VenueVerifiedScheduling?] = []
    var servableByIndex: [Int: (verified: BarnardB005VerifiedEnvelope, container: [UInt8])] = [:]

    for index in 0..<envelopeCount {
      guard let kotlinBytes = bundle.envelopeAt(index: Int32(index)) else {
        currentLeaseCandidates.append(nil)
        continue
      }
      let envelopeBytes = Self.swiftBytes(fromKotlin: kotlinBytes)
      guard
        let container = BarnardB005EnvelopeV2.encodeContainer(relayHopCount: 0, signedEnvelope: envelopeBytes),
        let hint = BarnardB005EnvelopeV2.schedulingFields(container: container),
        hint.eninSeconds > 0
      else {
        currentLeaseCandidates.append(nil)
        continue
      }

      let currentEninGuess = VenueBundleVerificationLogic.floorDiv(now, Int64(hint.eninSeconds))
      guard
        let leaseVerified = BarnardB005EnvelopeV2.verify(
          container: container, currentEnin: currentEninGuess, nameValidator: nameValidator
        ),
        BarnardB005EnvelopeV2.registryAgreement(leaseVerified, definition: barnardDefinition) == .agrees
      else {
        currentLeaseCandidates.append(nil)
        continue
      }
      currentLeaseCandidates.append(
        ExportedKotlinPackages.org.levarac.parallax.venue.VenueVerifiedScheduling(
          validFromEnin: leaseVerified.validFromEnin,
          validThroughEnin: leaseVerified.validThroughEnin,
          relayExpiresAtEnin: leaseVerified.relayExpiresAtEnin,
          eninSeconds: Int32(leaseVerified.eninSeconds),
          verifiedAtEnin: currentEninGuess
        )
      )
      servableByIndex[index] = (leaseVerified, container)
    }

    // NO SIGNED-SCHEDULE-COVERAGE GATE HERE, DELIBERATELY. Do not "restore"
    // one as a missing security check.
    //
    // An earlier revision of this method computed
    // `VenueBundleVerificationLogic.coverageOutcome` over the definition's
    // whole validity window and refused on `.gap`/`.uncomputable` before
    // reaching `evaluateVenueCurrentLease`. That is phase-2 scope, and the
    // venue lane owner ruled it out of phase 1 on 2026-09-10. The ruling is
    // recorded verbatim in `docs/plans/2026-09-10-venue-bundle-import.md`
    // ("Dependencies and evidence"): phase 1 proves a CURRENT LEASE, ending
    // no later than `currentEnin + 1`, after real SDK verification at the
    // current ENIN; it does not claim complete signed schedule coverage.
    //
    // The gate was not merely out of scope, it was wrong for the packs that
    // exist: a bundle carrying a single envelope for an event longer than one
    // relay lifetime cannot tile its own definition window, so the gate
    // refused before a current permit or a `notStarted` recheck could be
    // issued at all. That describes every pack barnard's producer can make
    // today.
    //
    // `coverageOutcome` and the helpers under it are kept, unused by this
    // path, because phase 2 needs exactly that machinery. Their round-2
    // property -- that "could not determine coverage" must never read as
    // "coverage is satisfied" -- still holds inside those functions and is
    // still tested. That concern is about a gate's fail-open direction, so it
    // only bites when coverage gates something; in phase 1 it gates nothing.
    //
    // Every other refusal in this file is load-bearing and stays: an
    // unreadable envelope, a missing `barnardDefinition`, a `servableByIndex`
    // miss, an unknown re-verification code, an unknown block code, and a
    // failed rejection init all still fail closed.
    let decision = ExportedKotlinPackages.org.levarac.parallax.venue.evaluateVenueCurrentLease(
      identity: identity, candidates: currentLeaseCandidates, clockUnixSeconds: now
    )
    if let lease = decision.lease {
      guard let servable = servableByIndex[Int(lease.selectedEnvelopeIndex)] else {
        // Unreachable in practice: shared/ can only select an index this
        // loop marked servable. Fails closed rather than force-unwrapping.
        return .blocked(VenueServingRejection(reason: .envelopeRejected)!)
      }
      let permit = VenueServePermit(
        identity: VenueArtifactIdentity(
          eventIdHex: Self.hexString(Self.swiftBytes(fromKotlin: bundle.eventId.toByteArray())),
          definitionSequence: bundle.definitionSequence,
          bundleDigestHex: Self.hexString(Self.swiftBytes(fromKotlin: bundle.bundleDigest.toByteArray()))
        ),
        container: Data(servable.container),
        displayName: servable.verified.eventDisplayName,
        payloadDigestHex: Self.sha256Hex(servable.verified.signedEnvelope),
        currentEnin: lease.currentEnin,
        stopAtUnixSeconds: lease.stopAtUnixSeconds
      )
      return .permitted(permit)
    }

    // shared/'s block codes match VenueServingBlock's case names verbatim
    // by design; a lookup miss means shared/ added a case native has not
    // caught up to yet, which fails closed to registryUnavailable rather
    // than guessing.
    let reason = VenueBundleVerificationLogic.servingBlock(forCode: decision.blockCode ?? "") ?? .registryUnavailable
    let recheck = reason == .notStarted ? decision.recheckAtUnixSeconds : nil
    return .blocked(
      VenueServingRejection(reason: reason, recheckAtUnixSeconds: recheck)
        ?? VenueServingRejection(reason: .registryUnavailable)!
    )
  }

  /// Why this is not an optional: see
  /// `VenueBundleVerificationLogic.DefinitionProjection`. A gated definition
  /// and a malformed one are different facts and must not share one `nil`.
  private enum DefinitionOutcome {
    case usable(BarnardEventDefinitionV1)
    case gatedUnsupported
    case unusable
  }

  /// The one place a `shared/` `EventDefinition` is read into the classifier,
  /// so `importBundle` and `evaluate` cannot drift apart on what "gated"
  /// means.
  private static func definitionProjection(
    of definition: ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinition
  ) -> VenueBundleVerificationLogic.DefinitionProjection {
    VenueBundleVerificationLogic.definitionProjection(
      joinMode: definition.joinMode,
      eventCodeHash: definition.eventCodeHashHex.flatMap { Self.bytes(fromHex: $0) }
    )
  }

  private static func barnardDefinition(
    from definition: ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinition
  ) -> DefinitionOutcome {
    let eventCodeHash = definition.eventCodeHashHex.flatMap { Self.bytes(fromHex: $0) }
    switch Self.definitionProjection(of: definition) {
    case .gatedUnsupported:
      return .gatedUnsupported
    case .unusable:
      return .unusable
    case .open:
      // `.open` is returned only for `EventJoinMode.OPEN` carrying a
      // well-formed 8-byte hash, so both of these hold by construction. They
      // are re-checked rather than force-unwrapped so a later change to the
      // classifier degrades to a refusal instead of a crash.
      guard
        let eventCodeHash,
        let joinMode = VenueBundleVerificationLogic.barnardJoinMode(definition.joinMode)
      else { return .unusable }
      return .usable(BarnardEventDefinitionV1(
        eventId: Self.swiftBytes(fromKotlin: definition.eventId.toByteArray()),
        keySetDigest: Self.swiftBytes(fromKotlin: definition.keySetDigest.toByteArray()),
        joinMode: joinMode,
        eventCodeHash: eventCodeHash,
        validFromUnixSeconds: definition.validFrom.value,
        validUntilUnixSeconds: definition.validUntil.value
      ))
    }
  }

  // MARK: - Byte/hex conversions

  private static func swiftBytes(fromKotlin bytes: ExportedKotlinPackages.kotlin.ByteArray) -> [UInt8] {
    (0..<Int(bytes.size)).map { UInt8(bitPattern: bytes[Int32($0)]) }
  }

  private static func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func bytes(fromHex hex: String) -> [UInt8]? {
    let clean = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
    guard clean.count % 2 == 0 else { return nil }
    var result: [UInt8] = []
    result.reserveCapacity(clean.count / 2)
    var index = clean.startIndex
    while index < clean.endIndex {
      let next = clean.index(index, offsetBy: 2)
      guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
      result.append(byte)
      index = next
    }
    return result
  }

  private static func sha256Hex(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
  }
}

#if DEBUG
/// Only for the test-target scripted fake. These factories do not exist in a
/// shipping configuration and are not a replacement for provider verification.
enum VenueServingContractTestFactory {
  static func imported(
    identity: VenueArtifactIdentity,
    publicArtifact: VenuePublicArtifact
  ) -> VenueImportedBundle {
    VenueImportedBundle(identity: identity, publicArtifact: publicArtifact)
  }

  static func permit(
    identity: VenueArtifactIdentity,
    container: Data,
    displayName: String,
    payloadDigestHex: String,
    currentEnin: Int64,
    stopAtUnixSeconds: Int64
  ) -> VenueServePermit {
    VenueServePermit(
      identity: identity,
      container: container,
      displayName: displayName,
      payloadDigestHex: payloadDigestHex,
      currentEnin: currentEnin,
      stopAtUnixSeconds: stopAtUnixSeconds
    )
  }
}
#endif
