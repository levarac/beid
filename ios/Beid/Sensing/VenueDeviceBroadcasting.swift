// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import Foundation

/// Pure indirection over the Barnard B005 venue-device serving operations
/// (gh#138). Mirrors `SensingCryptography`'s facade shape: callers retain
/// every validation and lifecycle decision, implementations only forward the
/// call. Deliberately its own `BarnardEngine` rather than a reference to
/// `SensingCoordinator`'s — `docs/specs/participation-surface.md` §2 scopes
/// #138 as "a new, separate screen calling `BarnardEngine.
/// configureEventInfoServing` directly," unrelated to the participation-
/// lifecycle region `SensingCoordinator` owns.
protocol VenueDeviceBroadcasting: AnyObject {
  /// Configures this broadcaster for `eventCode` and starts serving B005
  /// with `label`, then begins advertising. `eventCode` must match what a
  /// participant's app would derive its B004 hash from — Barnard's own
  /// `payloadIfServing` refuses to serve if the two disagree, so this call
  /// always configures both together on the same engine instance rather
  /// than assuming a prior `configure(eventCode:)` call.
  ///
  /// Throws only from Barnard's own `BarnardEventInfoCodec.
  /// validateEventDisplayName` (`BarnardEventInfoError.invalidDisplayName`)
  /// — callers should pre-validate `label` for a same-turn UI error; this is
  /// the SDK's own last-line check, not the first signal a user should see.
  func startBroadcasting(eventCode: String, label: String) throws

  /// Stops discovery-serving and advertising. Safe to call when already
  /// stopped (turning the on/off toggle off twice, or off without ever
  /// having turned on).
  func stopBroadcasting()
}

/// Production adapter. Owns one dedicated `BarnardEngine` instance, separate
/// from `SensingCoordinator`'s — see the protocol doc comment.
final class BarnardVenueDeviceBroadcasting: VenueDeviceBroadcasting {
  private let engine = BarnardEngine()

  func startBroadcasting(eventCode: String, label: String) throws {
    engine.configure(eventCode: eventCode)
    try engine.configureEventInfoServing(
      organizerDesignated: true,
      eventActiveForDiscovery: true,
      eventDisplayName: label
    )
    engine.startAdvertise()
  }

  func stopBroadcasting() {
    // `eventDisplayName` defaults to `nil`, which `configureEventInfoServing`
    // never validates, so this can never actually throw — but the method is
    // `throws` at the type level, so a call site is still required.
    try? engine.configureEventInfoServing(eventActiveForDiscovery: false)
    engine.stopAdvertise()
  }
}
