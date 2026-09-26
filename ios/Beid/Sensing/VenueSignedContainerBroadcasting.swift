// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Barnard
import Foundation

/// Translates Barnard engine signals into the four `VenueRadioState` cases.
///
/// The decision takes the engine's own reason/error/constraint CODES rather
/// than a `BarnardEvent`, and that shape is forced rather than chosen:
/// `BarnardState`, `BarnardErrorEvent` and `BarnardConstraintEvent` declare
/// public properties but no public initializer, so a test target outside the
/// Barnard module cannot construct a synthetic `BarnardEvent` at all. Keeping
/// the decision on plain codes is what lets the PRODUCTION mapping — not a
/// fake — be exercised across every declared radio case without a radio.
/// Destructuring the event stays in the adapter below, where it is a single
/// pattern match with no judgment in it.
///
/// Verified against levarac/barnard `d382de873fa355a7cb21d219b2e33903105e86fa`
/// (an ancestor of tag `v0.9.0`, the version `ios/project.yml` pins),
/// `packages/swift/barnard/Sources/Barnard/BarnardEngine.swift`.
enum VenueRadioEventMapping {
  /// `nil` means the signal says nothing about this device's serving radio.
  /// Returning `nil` rather than a state is deliberate: unrelated engine
  /// traffic must not be able to invent a transition.
  static func update(stateReasonCode: String?) -> VenueRadioUpdate? {
    switch stateReasonCode {
    case "advertise_start":
      // `:1186-1188` sets isAdvertising and emits this immediately after
      // calling CBPeripheralManager.startAdvertising, BEFORE the OS confirms.
      // The completion callback `:2165-2170` fires only on failure and has no
      // success event, so on-air is not observable from inside the app. This
      // stays `advertisingRequested` and no label, delay or absence of an
      // error may promote it.
      return VenueRadioUpdate(state: .advertisingRequested)
    case "advertise_stop":
      return VenueRadioUpdate(state: .stopped)
    case "advertise_failed":
      // `:2165-2170` emits an error AND a state for the same failure. The
      // error arm carries the cause, so ignoring the state here is what keeps
      // one OS failure from becoming two radio updates.
      return nil
    default:
      return nil
    }
  }

  static func update(constraintCode: String) -> VenueRadioUpdate? {
    // `:1166-1176`: the engine sets shouldStartAdvertiseWhenReady = true and
    // emits only a debug line for `.unknown`/`.resetting`, which resolve on
    // their own; it reaches this constraint only for peripheral states that
    // will not — powered off, unauthorized, unsupported — and clears the
    // pending flag in that arm. Nothing is pending, so this is a failure
    // rather than waiting.
    guard constraintCode == "bluetooth_not_ready" else { return nil }
    return VenueRadioUpdate(state: .failed, failure: .bluetoothUnavailable)
  }

  static func update(errorCode: String) -> VenueRadioUpdate? {
    switch errorCode {
    case "advertise_failed":
      return VenueRadioUpdate(state: .failed, failure: .advertiseFailed)
    case "gatt_service_add_failed":
      return VenueRadioUpdate(state: .failed, failure: .gattServiceFailed)
    default:
      return nil
    }
  }
}

/// Production adapter for the signed-container port. Owns one dedicated
/// `BarnardEngine`, separate from `SensingCoordinator`'s and from the v1
/// `BarnardVenueDeviceBroadcasting`'s, for the reason the v1 facade already
/// documents: venue serving is its own screen and its own engine, unrelated
/// to the participation-lifecycle region.
///
/// This adapter never configures an event code, and that is a property of the
/// protocol rather than an omission. `ownEventInfoValue()` (`:786-787`)
/// returns a supplied v2 container directly and it takes precedence over the
/// v1 payload, while the advertisement itself (`:1180-1182`) carries only the
/// discovery service UUID. A signed container is therefore served without the
/// engine knowing any event code — which is why nothing here has to derive an
/// event identity it was not handed.
@MainActor
final class BarnardVenueSignedContainerBroadcasting: VenueSignedContainerBroadcasting {
  var onState: ((VenueRadioUpdate) -> Void)?

  private let engine: BarnardEngine

  init(engine: BarnardEngine = BarnardEngine()) {
    self.engine = engine
    self.engine.onEvent = { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, let update = Self.update(for: event) else { return }
        self.onState?(update)
      }
    }
  }

  /// Pure destructuring: which arm an event belongs to, with the judgment
  /// left to `VenueRadioEventMapping`.
  private static func update(for event: BarnardEvent) -> VenueRadioUpdate? {
    switch event {
    case .state(let state):
      return VenueRadioEventMapping.update(stateReasonCode: state.reasonCode)
    case .constraint(let constraint):
      return VenueRadioEventMapping.update(constraintCode: constraint.code)
    case .error(let error):
      return VenueRadioEventMapping.update(errorCode: error.code)
    case .detection, .rssiUpdate, .eventInfoHint, .eventInfoEnvelopeV2, .relayDecision:
      return nil
    }
  }

  /// Clears before replacing, and clears again if the install is rejected.
  ///
  /// Both clears are load-bearing rather than defensive.
  /// `configureOwnEventInfoEnvelopeV2` documents at `:675-677` that when the
  /// bytes are rejected "nothing is stored and any previous container stays
  /// in place" — so without the second clear a rejected replacement would
  /// leave the PREVIOUS event's signed bytes live on the air, which is the
  /// one outcome this screen must never produce.
  func installAndStart(_ permit: VenueServePermit) throws {
    // Clear BEFORE replacing.
    try? engine.configureOwnEventInfoEnvelopeV2(container: nil)
    do {
      try engine.configureOwnEventInfoEnvelopeV2(container: permit.container)
    } catch {
      // Clear AGAIN: the rejected install left the previous bytes in place.
      try? engine.configureOwnEventInfoEnvelopeV2(container: nil)
      throw VenueRadioFailure.containerInstallRejected
    }
    engine.startAdvertise()
  }

  func clearAndStop() {
    try? engine.configureOwnEventInfoEnvelopeV2(container: nil)
    engine.stopAdvertise()
  }
}
