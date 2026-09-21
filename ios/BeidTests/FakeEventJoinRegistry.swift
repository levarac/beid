// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation
@testable import Beid

/// Drives `SensingCoordinator`'s beid#410 join gate from a unit test.
///
/// ## What this fake can do
///
/// It uses shared test factories for both a real failed resolution and a real
/// successful resolution. The failed resolution is passed through the same
/// nullable filter as the production adapter, so the coordinator sees the
/// exact post-adapter shape while this fixture still exercises the non-null
/// object the KMP client actually returns.
@MainActor
final class FakeEventJoinRegistry: EventJoinRegistry {
  enum Answer {
    /// Builds a failed non-null resolution, then applies the production
    /// adapter's filter before answering the coordinator.
    ///
    /// `errorCode` is what the registry reported, which is what a refusal is
    /// classified from. `nil` models a failure that carried no code.
    case readFails(errorCode: String?)
    /// Does not answer on its own. The read stays outstanding, so it can be
    /// observed through `isHoldingRead`, cancelled, or answered after the fact
    /// with `answerHeldReadAsFailure()`.
    ///
    /// There was a second case, `answersLate`, that did the storing this one
    /// only claimed to do. Two cases for one behavior is what let `holds`
    /// become a no-op without any test noticing — see `isHoldingRead`.
    case holds
    /// Answers with `resolution` immediately. Build one with
    /// `FakeEventJoinRegistry.admittingResolution(...)`, or hand-build a
    /// rejected one to cover a refusing branch of the real gate.
    ///
    /// The shared test factory builds the successful resolution without making
    /// the registry constructors public to production callers.
    case resolves(
      ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinitionResolution
    )
  }

  /// A registry answer the beid#410 gate admits.
  ///
  /// The validity window is centred on `nowEpochSeconds`, which defaults to
  /// the **wall clock the coordinator itself will read**, so a test does not
  /// have to reason about the clock to get past the expiry check. A fixed
  /// default was tried first and expired the moment real time passed it.
  /// Pass a window that excludes `now`, or `joinMode: ...GATED`, to exercise
  /// the refusing branches through the *real* decision rather than a second
  /// one.
  static func admittingResolution(
    eventIdHex: String,
    nowEpochSeconds: Int64 = Int64(Date().timeIntervalSince1970),
    eventCodeHashHex: String? = nil,
    joinMode: ExportedKotlinPackages.org.levarac.parallax.registry.EventJoinMode =
      ExportedKotlinPackages.org.levarac.parallax.registry.EventJoinMode.OPEN
  ) -> ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinitionResolution {
    BeidSharedKit.jointestsupport.createEventDefinitionResolutionForTesting(
      eventIdHex: eventIdHex,
      definitionHashHex: "0x" + String(repeating: "b", count: 64),
      blockHashHex: "0x" + String(repeating: "c", count: 64),
      eventCodeHashHex: eventCodeHashHex,
      validFromEpochSeconds: nowEpochSeconds - 86_400,
      validUntilEpochSeconds: nowEpochSeconds + 86_400,
      joinMode: joinMode,
      keySetDigestHex: nil
    )
  }

  var answer: Answer = .readFails(errorCode: nil)

  /// The event ids the gate actually asked about, in order.
  ///
  /// This is the assertion that has teeth. Before the seam existed, every gate
  /// test built the coordinator with no registry at all, so the gate returned
  /// at its first guard and nothing downstream ran — deleting the whole body of
  /// `beginRegistryVerifiedJoin` left the suite green. A test that asserts this
  /// array is non-empty is asserting the gate *reached the read*, which is the
  /// depth the old tests never got to.
  private(set) var requestedEventIdHexes: [String] = []
  private(set) var cancelCount = 0

  private var heldCompletion: (
    (
      ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinitionResolution?,
      String?
    ) -> Void
  )?

  /// Whether a read is still outstanding.
  ///
  /// Derived from the stored completion rather than tracked separately, so
  /// there is one source of truth for "outstanding". It used to read as false
  /// for the whole of `.holds`, because that case stored nothing — the two
  /// tests that assert it had never executed anywhere, since the Xcode project
  /// did not compile this file into the test target (beid#410).
  var isHoldingRead: Bool { heldCompletion != nil }

  @discardableResult
  func resolveEventDefinition(
    eventIdHex: String,
    nowEpochSeconds: Int64,
    completion: @escaping (
      ExportedKotlinPackages.org.levarac.parallax.registry.EventDefinitionResolution?,
      String?
    ) -> Void
  ) -> any EventIdentityVerificationRequest {
    requestedEventIdHexes.append(eventIdHex)
    switch answer {
    case let .readFails(errorCode):
      let resolution = BeidSharedKit.jointestsupport
        .createFailedEventDefinitionResolutionForTesting(
          errorCode: errorCode,
          errorMessage: "fake definition read failed"
        )
      completion(
        resolution.isSuccess ? resolution : nil,
        resolution.isSuccess ? nil : resolution.errorCode
      )
    case .holds:
      heldCompletion = completion
    case let .resolves(resolution):
      completion(resolution, nil)
    }
    return FakeEventJoinRequest { [weak self] in
      self?.cancelCount += 1
    }
  }

  /// Answers a held read as a failure.
  func answerHeldReadAsFailure(errorCode: String? = nil) {
    let completion = heldCompletion
    heldCompletion = nil
    completion?(nil, errorCode)
  }

  /// Answers a held read with a resolution.
  ///
  /// The shared test factory makes this late successful answer constructible
  /// without changing the production registry API.
  func answerHeldRead(
    with resolution: ExportedKotlinPackages.org.levarac.parallax.registry
      .EventDefinitionResolution
  ) {
    let completion = heldCompletion
    heldCompletion = nil
    completion?(resolution, nil)
  }
}

/// Cancellation handle the fake hands back, so a test can assert an abandoned
/// read was cancelled rather than merely ignored.
@MainActor
private final class FakeEventJoinRequest: EventIdentityVerificationRequest {
  private let onCancel: () -> Void
  private var cancelled = false

  init(onCancel: @escaping () -> Void) {
    self.onCancel = onCancel
  }

  func cancel() {
    guard !cancelled else { return }
    cancelled = true
    onCancel()
  }
}
