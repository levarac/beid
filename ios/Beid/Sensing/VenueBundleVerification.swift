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
    guard
      let bundle = ExportedKotlinPackages.org.levarac.parallax.venue.decodeVenueBundle(
        bytes: ExportedKotlinPackages.kotlin.ByteArray(bundleBytes)
      ),
      let handoff = ExportedKotlinPackages.org.levarac.parallax.venue.decodeVenueHandoff(
        bytes: ExportedKotlinPackages.kotlin.ByteArray(handoffBytes)
      )
    else {
      return .rejected(.malformedOrOutOfBounds)
    }

    switch await verifyIdentity(bundle: bundle, handoff: handoff) {
    case .noClient:
      return .rejected(.registryUnavailable)
    case .rejected(let code):
      return .rejected(VenueBundleVerificationLogic.importFailure(forIdentityCode: code) ?? .definitionRejected)
    case .ok:
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
      let bundle = ExportedKotlinPackages.org.levarac.parallax.venue.decodeVenueBundle(
        bytes: ExportedKotlinPackages.kotlin.ByteArray(imported.publicArtifact.bundleBytes)
      ),
      let handoff = ExportedKotlinPackages.org.levarac.parallax.venue.decodeVenueHandoff(
        bytes: ExportedKotlinPackages.kotlin.ByteArray(imported.publicArtifact.handoffBytes)
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
      return await evaluateCoverageAndLease(identity: identity, bundle: bundle, now: now)
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

  // MARK: - Coverage and current lease

  /// Re-verifies every envelope, once against the definition's whole
  /// validity window (coverage) and once against the current clock (the
  /// lease candidate list), then asks `shared/` for the current decision.
  ///
  /// Both probes call the SAME `BarnardB005EnvelopeV2.verify`; only the
  /// `currentEnin` they ask differs. The coverage probe uses each
  /// envelope's own untrusted `validFromEnin` hint (from
  /// `schedulingFields(container:)`) -- reading that hint only to CHOOSE
  /// which ENIN to ask `verify` to check is exactly the trust boundary
  /// `BarnardB005SchedulingFields` documents. The lease probe uses the
  /// clock's own ENIN. Either probe succeeding also reveals the envelope's
  /// true (verified) `[validFromEnin, relayExpiresAtEnin)` window, since
  /// those bounds are envelope-level constants independent of which ENIN
  /// inside them `verify` was asked about.
  ///
  /// `registryAgreement` is checked for both probes, never left to
  /// `evaluateVenueCurrentLease`: `shared/` cannot verify that a
  /// `VenueVerifiedScheduling` actually came from the SDK or that it
  /// matches the anchored definition, so an envelope that verifies but
  /// disagrees with the registry is treated as rejected, exactly like a
  /// failed signature.
  private func evaluateCoverageAndLease(
    identity: ExportedKotlinPackages.org.levarac.parallax.venue.VenueBundleIdentity,
    bundle: ExportedKotlinPackages.org.levarac.parallax.venue.VenueBundle,
    now: Int64
  ) async -> VenueServingDecision {
    guard let barnardDefinition = Self.barnardDefinition(from: identity.definition) else {
      // The anchored definition lacks a joinMode/eventCodeHash pair, so no
      // envelope can be compared against it at all. There is no dedicated
      // outcome for this; every candidate is treated as rejected.
      return .blocked(VenueServingRejection(reason: .envelopeRejected)!)
    }

    let envelopeCount = Int(bundle.envelopeCount)
    var currentLeaseCandidates:
      [ExportedKotlinPackages.org.levarac.parallax.venue.VenueVerifiedScheduling?] = []
    var servableByIndex: [Int: (verified: BarnardB005VerifiedEnvelope, container: [UInt8])] = [:]
    var coverageIntervals: [(from: Int64, to: Int64)] = []
    var referenceEninSeconds: UInt16?

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

      if let coverageVerified = BarnardB005EnvelopeV2.verify(
        container: container, currentEnin: hint.validFromEnin, nameValidator: nameValidator
      ), BarnardB005EnvelopeV2.registryAgreement(coverageVerified, definition: barnardDefinition) == .agrees {
        coverageIntervals.append((coverageVerified.validFromEnin, coverageVerified.relayExpiresAtEnin))
        if referenceEninSeconds == nil { referenceEninSeconds = coverageVerified.eninSeconds }
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
      if referenceEninSeconds == nil { referenceEninSeconds = leaseVerified.eninSeconds }
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

    if let referenceEninSeconds,
       let window = VenueBundleVerificationLogic.definitionEninWindow(
         validFromUnixSeconds: identity.definition.validFrom.value,
         validUntilUnixSeconds: identity.definition.validUntil.value,
         eninSeconds: Int64(referenceEninSeconds)
       ),
       VenueBundleVerificationLogic.hasCoverageGap(
         candidates: coverageIntervals, requiredStart: window.start, requiredEnd: window.end
       )
    {
      // A verified future (or past) slice is missing from this bundle. The
      // current instant may still be servable on its own, but a bundle
      // that cannot cover its own declared event span was not delivered
      // intact, so nothing from it is served.
      return .blocked(VenueServingRejection(reason: .envelopeRejected)!)
    }

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

  private static func barnardDefinition(
    from definition: ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinition
  ) -> BarnardEventDefinitionV1? {
    guard
      let joinMode = VenueBundleVerificationLogic.barnardJoinMode(definition.joinMode),
      let eventCodeHashHex = definition.eventCodeHashHex,
      let eventCodeHash = Self.bytes(fromHex: eventCodeHashHex), eventCodeHash.count == 8
    else { return nil }
    return BarnardEventDefinitionV1(
      eventId: Self.swiftBytes(fromKotlin: definition.eventId.toByteArray()),
      keySetDigest: Self.swiftBytes(fromKotlin: definition.keySetDigest.toByteArray()),
      joinMode: joinMode,
      eventCodeHash: eventCodeHash,
      validFromUnixSeconds: definition.validFrom.value,
      validUntilUnixSeconds: definition.validUntil.value
    )
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

private extension ExportedKotlinPackages.kotlin.ByteArray {
  convenience init(_ data: Data) {
    let bytes = [UInt8](data)
    self.init(size: Int32(bytes.count)) { index in Int8(bitPattern: bytes[Int(index)]) }
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
