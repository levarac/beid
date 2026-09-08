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
/// `EventDefinitionResolution` carries an `internal` Kotlin constructor, so
/// Swift Export gives it only a `package` initializer and no Swift code —
/// production or test — can build one. A fake can therefore answer:
///
/// - **nil**, the read failed or produced no definition;
/// - **never**, the read is still outstanding;
/// - **late**, after the caller has moved on.
///
/// It cannot answer with a *successful* read, and that is a property of the
/// shared type rather than a gap here. Android records the same limit in
/// `FakeEventJoinRegistry` and reaches a successful join by walking the real
/// promotion path instead. iOS has no caller for that path yet, so the
/// positive case stays unexpressible on this host until shared test support
/// exists (beid#391). The three refusals above are exactly the ones beid#374's
/// acceptance criterion names.
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
  /// Returns a handle so an abandoned attempt can be cancelled rather than
  /// left to answer into a session that has moved on.
  @discardableResult
  func resolveEventDefinition(
    eventIdHex: String,
    nowEpochSeconds: Int64,
    completion: @escaping (
      ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinitionResolution?
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
  private let client: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient

  init(client: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient) {
    self.client = client
  }

  @discardableResult
  func resolveEventDefinition(
    eventIdHex: String,
    nowEpochSeconds: Int64,
    completion: @escaping (
      ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinitionResolution?
    ) -> Void
  ) -> any EventIdentityVerificationRequest {
    let request = client.resolveEventDefinition(
      eventIdHex: eventIdHex,
      pin: ExportedKotlinPackages.org.levarac.parallax.registry.safeRegistryReadPin(),
      useTimeEpochSeconds: nowEpochSeconds
    ) { resolution in
      Task { @MainActor in
        completion(resolution)
      }
    }
    return RegistryEventJoinRequest(request: request)
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
