// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import BeidSharedKit
import Foundation
@testable import Beid

/// Observable stand-in for the Barnard participation seam (beid#410).
///
/// Exists because `SensingCoordinator` previously held a concrete
/// `BarnardEngine`, which a test cannot construct in an observable form. That
/// left iOS unable to assert anything about joining at all: on a BLE-less
/// Simulator `requestPermissions` never reports `canScan`/`canAdvertise`, so
/// its completion never ran, so every existing real-path test stopped short of
/// the engine. An apparatus that can only observe "nothing happened" cannot
/// tell a working gate from a missing one, because a missing gate also
/// produces nothing on that host.
///
/// ## What this fake can express, and why each one is deliberate
///
/// - **More than one join.** `joinAndStartContexts` is an array, not an
///   `Optional`. A fake that recorded only the last call could not fail a
///   double join, and "joined twice" is a real defect shape for a path that
///   runs inside a permission callback that a host may invoke more than once.
/// - **A grant that must still start nothing.** `permissionOutcome` defaults
///   to `.neverAnswers`, which is what the real Simulator does. A test that
///   wants the gate exercised must *deliberately* grant, and a granted
///   permission followed by an empty `joinAndStartContexts` is exactly the
///   assertion that distinguishes a working gate from an absent one. Without a
///   grant this fake is as blind as the old apparatus, so the default is the
///   honest one rather than the convenient one.
/// - **The exact string that reached Barnard.** `joinedCodes` reads
///   `joinCode` off the recorded capability, so a test can assert that the
///   code Barnard was handed is the one the shared issuer fixed, rather than
///   merely that some join occurred. That is the property the production
///   adapter claims, so it is the one worth pinning.
/// - **Refusal to answer at all.** `.neverAnswers` is not an absence of
///   behaviour, it is a case — the host really does behave this way, and a
///   fake that always fired its callback synchronously would encode an
///   assumption about Barnard that Barnard does not promise.
final class RecordingEventJoinControl: EventJoinControlling, @unchecked Sendable {
  /// How this fake answers a permission request.
  enum PermissionOutcome {
    /// Never calls the completion — the BLE-less Simulator's real behaviour,
    /// and the default so no test is granted permissions by accident.
    case neverAnswers
    /// Calls the completion with both capabilities granted.
    case granted
    /// Calls the completion with both capabilities refused.
    case denied
    /// Calls the completion with exactly these values.
    case reports(canScan: Bool, canAdvertise: Bool)
    /// Keeps the completion so a test can answer it after the fact.
    ///
    /// Every other case fires synchronously, which made a *late* grant
    /// inexpressible — and a late grant is precisely the case that used to
    /// join an event after the user had already stopped. An apparatus that
    /// cannot express the failure cannot pin the fix.
    case answersLate
  }

  var onEvent: ((BarnardEvent) -> Void)?

  var permissionOutcome: PermissionOutcome = .neverAnswers

  /// What `currentJoinedEventCode()` reports. Settable so a test can model
  /// Barnard holding an event, or holding none.
  var currentEventCode: String?

  private(set) var requestJoinPermissionsCallCount = 0
  private(set) var startDiscoveryScanCallCount = 0
  private(set) var stopDiscoveryScanCallCount = 0
  private(set) var joinAndStartContexts:
    [ExportedKotlinPackages.org.levarac.parallax.discovery.RegistryVerifiedJoinContext] = []
  private(set) var leaveJoinedEventCallCount = 0
  private(set) var stopAutomaticOperationCallCount = 0

  /// The join codes Barnard was actually handed, in order.
  var joinedCodes: [String] {
    joinAndStartContexts.map(\.joinCode)
  }

  /// Whether anything was joined at all. Named for the assertion tests
  /// actually make, so a refusal reads as a refusal rather than as `== 0`.
  var didJoin: Bool {
    !joinAndStartContexts.isEmpty
  }

  /// Whether a permission request is still outstanding.
  var isHoldingPermissionRequest: Bool { heldPermissionCompletion != nil }

  private var heldPermissionCompletion: ((Bool, Bool) -> Void)?

  func requestJoinPermissions(
    _ completion: @escaping (_ canScan: Bool, _ canAdvertise: Bool) -> Void
  ) {
    requestJoinPermissionsCallCount += 1
    switch permissionOutcome {
    case .neverAnswers:
      return
    case .granted:
      completion(true, true)
    case .denied:
      completion(false, false)
    case let .reports(canScan, canAdvertise):
      completion(canScan, canAdvertise)
    case .answersLate:
      heldPermissionCompletion = completion
    }
  }

  func startDiscoveryScan() {
    startDiscoveryScanCallCount += 1
  }

  func stopDiscoveryScan() {
    stopDiscoveryScanCallCount += 1
  }

  /// Answers a held permission request, granting both capabilities.
  func grantHeldPermissionRequest() {
    let completion = heldPermissionCompletion
    heldPermissionCompletion = nil
    completion?(true, true)
  }

  func joinAndStart(
    _ context: ExportedKotlinPackages.org.levarac.parallax.discovery.RegistryVerifiedJoinContext
  ) {
    joinAndStartContexts.append(context)
    currentEventCode = context.joinCode
  }

  func leaveJoinedEvent() {
    leaveJoinedEventCallCount += 1
    currentEventCode = nil
  }

  func stopAutomaticOperation() {
    stopAutomaticOperationCallCount += 1
  }

  func currentJoinedEventCode() -> String? {
    currentEventCode
  }
}
