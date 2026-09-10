// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

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
