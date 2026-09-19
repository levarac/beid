// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation

/// The registry read the join gate stands on, behind a protocol so a test can
/// answer it (beid#410).
///
/// ## Why this exists, stated as the defect it fixes
///
/// The gate's first version read through the Kotlin `RegistryClient` directly.
/// Nothing in `BeidTests` can construct one, so every gate test built the
/// coordinator with no client at all — which meant `beginRegistryVerifiedJoin`
/// returned at its *first* guard and no test ever reached the read, the
/// issuer, or any refusal past "no registry configured". Deleting the entire
/// body of that method left the whole suite green. The tests looked like
/// coverage of a gate and were coverage of one early return.
///
/// This protocol is the seam that makes the real refusals expressible. It
/// mirrors Android's `EventJoinRegistry`, which exists for the same reason.
///
/// ## The completion is Optional, and that is the point
///
/// The shared `jointestsupport` factory makes the resolution shape available
/// to tests without exposing the registry constructor to production callers.
/// A fake can therefore answer:
///
/// - **nil**, the read failed or produced no definition;
/// - **never**, the read is still outstanding;
/// - **late**, after the caller has moved on.
///
/// It can also answer with a successful read or a failed non-null resolution;
/// the production adapter filters the latter to nil before the join gate sees
/// it. Pending and late answers remain explicit cases because cancellation and
/// stale-completion guards are separate behavior.
/// Why a join attempt was refused, for a surface the user can see.
///
/// Native rather than shared on purpose. Android reports refusals through
/// `EventJoinUiState.JoinFailed`, which is Android's own UI state and not a
/// shared `ScanPhaseKind`, so the symmetric iOS answer is a native type here.
/// Neither platform adds a phase kind for this.
///
/// The cases name the branch that refused rather than re-deriving the shared
/// verdict. `NearbyEventJoinEligibility` carries the precise reason and is
/// exported, but its generated Swift surface offers no `name`, no
/// `description` and no equality — only static accessors, `allCases` and
/// `valueOf` — checked in the generated `BeidSharedKit.swift` rather than
/// assumed. So there is no sound way to map it to a native case from Swift
/// today. It is logged verbatim for diagnosis, and giving it a comparable or
/// nameable Swift surface is shared-side work (beid#391), not something to
/// fake here with identity comparisons that happen to work.
enum EventJoinRefusal: Equatable {
  /// No registry client is configured, so nothing can be verified.
  case noRegistryConfigured
  /// The selected code never obtained a canonical Event ID, so there is no
  /// registry answer to stand on.
  case noCanonicalEventId
  /// The read did not produce a definition.
  case registryReadFailed
  /// The read produced a definition the shared issuer refused to grant a
  /// capability for. The shared verdict is in the log.
  case definitionNotEligible
}

@MainActor
protocol EventJoinRegistry: AnyObject {
  /// Reads the definition for `eventIdHex` and answers with it, or with nil
  /// when the read did not produce one.
  ///
  /// The second value is the registry's own `errorCode` for a read that
  /// produced nothing, and nil for one that did. It is separate from the
  /// resolution rather than replacing the nil filter, because "nil means no
  /// definition" is a contract both platforms rely on — Android's
  /// `EventJoinRegistry.kt` does `completion(resolution.takeIf { it.isSuccess })`
  /// — and collapsing that would make `.registryReadFailed` unreachable
  /// again, the exact regression the filter was added to fix.
  ///
  /// Without it a failed read can only say `UNKNOWN`. With it the same
  /// `shared/` classifier the code-to-id lookup already uses can name the
  /// situation (beid#472).
  ///
  /// Returns a handle so an abandoned attempt can be cancelled rather than
  /// left to answer into a session that has moved on.
  @discardableResult
  func resolveEventDefinition(
    eventIdHex: String,
    nowEpochSeconds: Int64,
    completion: @escaping (
      ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinitionResolution?,
      _ failureErrorCode: String?
    ) -> Void
  ) -> any EventIdentityVerificationRequest
}

/// Production adapter over the KMP registry client.
///
/// Reads at the safe pin and at the time it is called, and hands the whole
/// resolution back without interpreting it: whether that resolution is good
/// enough to join is the shared issuer's decision, not this adapter's.
@MainActor
final class RegistryEventJoinRegistry: EventJoinRegistry {
  typealias DefinitionReader = (
    String,
    Int64,
    @escaping (ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinitionResolution) -> Void
  ) -> any EventIdentityVerificationRequest

  private let readDefinition: DefinitionReader

  init(client: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient) {
    self.readDefinition = { eventIdHex, nowEpochSeconds, completion in
      let request = client.resolveEventDefinition(
        eventIdHex: eventIdHex,
        pin: ExportedKotlinPackages.org.levarac.parallax.registry.safeRegistryReadPin(),
        useTimeEpochSeconds: nowEpochSeconds
      ) { resolution in
        completion(resolution)
      }
      return RegistryEventJoinRequest(request: request)
    }
  }

  /// Test seam for the adapter itself. Production continues to use the
  /// platform's real KMP RegistryClient above; tests can supply a non-null
  /// failed resolution, which is the shape that client actually returns.
  init(testReader: @escaping DefinitionReader) {
    self.readDefinition = testReader
  }

  @discardableResult
  func resolveEventDefinition(
    eventIdHex: String,
    nowEpochSeconds: Int64,
    completion: @escaping (
      ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinitionResolution?,
      _ failureErrorCode: String?
    ) -> Void
  ) -> any EventIdentityVerificationRequest {
    return readDefinition(eventIdHex, nowEpochSeconds) { resolution in
      Task { @MainActor in
        // Mirrors Android's `EventJoinRegistry.kt:69`
        // (`completion(resolution.takeIf { it.isSuccess })`).
        //
        // The shared client's completion is **not** optional:
        // `RegistryClient.resolveEventDefinition` declares
        // `completion: (EventDefinitionResolution) -> Unit`, so a failed read
        // arrives as a resolution carrying `isSuccess == false`, never as
        // nil. Without this filter the failure flowed on to the issuer and
        // came back refused as `.definitionNotEligible`, which left the nil
        // branch — `.registryReadFailed` — dead on a real device and
        // reachable only from a fake. The two branches now mean on iOS what
        // they mean on Android.
        completion(
          resolution.isSuccess ? resolution : nil,
          resolution.isSuccess ? nil : resolution.errorCode
        )
      }
    }
  }
}

/// Cancellation handle for one join-time registry read.
@MainActor
private final class RegistryEventJoinRequest: EventIdentityVerificationRequest {
  private var request: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryRequest?

  init(request: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryRequest) {
    self.request = request
  }

  func cancel() {
    request?.cancel()
    request = nil
  }

  deinit {
    request?.cancel()
  }
}
