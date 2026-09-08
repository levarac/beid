// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import BeidSharedKit
import Foundation

/// The Barnard participation operations `SensingCoordinator` drives, behind a
/// protocol whose only way into a join is a capability (beid#410, the iOS half
/// of beid#374).
///
/// ## Why the whole surface and not just the join
///
/// This is deliberately every Barnard call the coordinator makes, rather than
/// a narrow gate bolted beside a retained `BarnardEngine`. The point is what
/// is *absent*: there is no `joinEvent(String)` and no argumentless
/// `startAuto()` on this protocol, so a coordinator holding only an event code
/// has no method to call. A narrow gate next to a raw engine would leave both
/// of those reachable, and the next author would reach them — the defect this
/// closes was written by someone who had them to hand.
///
/// This mirrors Android's `EventJoinEngine` (beid#374), which made the same
/// move for the same reason. Barnard's string join API still exists and is
/// still what ends up being called; the conversion from a capability to that
/// string happens inside the production adapter below, where it cannot be
/// reached with a string that did not come from a registry-verified context.
///
/// ## Two string doors on iOS, not one
///
/// Android had a single ungated entry. iOS had two, and the second was the
/// dangerous one. `BarnardEngine.configure(eventCode:)` is not a settings
/// call: when the code it is handed differs from the current one it calls
/// `rpid.joinEvent(eventCode)` itself, under the reason code
/// `configure_event`. So `configure` was a join in everything but name, and
/// `startSensing` reached it without passing through `joinEvent` at all. Both
/// doors are closed by the same absence here.
///
/// Permissions are on this protocol for a reason that is not symmetry. The iOS
/// Simulator has no BLE radio, so `requestPermissions` never reports
/// `canScan`/`canAdvertise` there and its completion never runs (AGENTS.md).
/// Every existing test that drives the real sensing path therefore stops short
/// of the engine entirely. Without a seam a test can inject, iOS could not
/// assert that the gate holds — only that nothing happened, which is what
/// already happens when the gate is absent. An apparatus that cannot tell a
/// working gate from a missing one is not evidence about either.
protocol EventJoinControlling: AnyObject {
  /// Barnard's event stream. Satisfied by `BarnardEngine`'s own stored
  /// property, so production wiring is unchanged.
  var onEvent: ((BarnardEvent) -> Void)? { get set }

  /// Asks for the radio permissions sensing needs, and reports the only two
  /// fields this app reads.
  ///
  /// Takes plain `Bool`s rather than Barnard's `BarnardPermissionStatus` for
  /// the same reason `SensingCoordinator.handleEventInfoEnvelopeV2` takes
  /// plain fields rather than `BarnardB005VerifiedEnvelope`: that struct has
  /// no public initializer, so a test could not synthesize one, and a seam a
  /// test cannot drive is not a seam. Passing the Barnard type here would
  /// have left the gate exactly as unobservable as it was before this change.
  ///
  /// Named apart from Barnard's own `requestPermissions(completion:)` for the
  /// reason `ParticipantRelayControlling.setParticipantRelayVerifier` records:
  /// an extension method sharing a name and a prefix of its argument labels
  /// would call itself.
  func requestJoinPermissions(
    _ completion: @escaping (_ canScan: Bool, _ canAdvertise: Bool) -> Void
  )

  /// Joins the verified event and starts automatic operation, as one act.
  ///
  /// The two are merged rather than offered as an ordered pair because a pair
  /// can be half-called: a host that joined and then returned early would
  /// leave Barnard joined to an event this app is not sensing for. Android's
  /// `EventJoinEngine.joinAndStart` merged them first, for the same reason.
  ///
  /// The capability carries the code, so no caller can pair a verified event
  /// with some other string — an API shaped like `join(context, someCode)`
  /// would put that hole straight back.
  func joinAndStart(
    _ context: ExportedKotlinPackages.org.levarac.parallax.discovery.RegistryVerifiedJoinContext
  )

  /// Clears the joined event. Named apart from Barnard's `leaveEvent()` for
  /// the self-call reason above.
  func leaveJoinedEvent()

  /// Stops scanning and advertising. Named apart from Barnard's `stopAuto()`
  /// for the self-call reason above.
  func stopAutomaticOperation()

  /// The event code Barnard currently holds, which is how this app confirms a
  /// join took effect. Named apart from Barnard's `getCurrentEventCode()` for
  /// the self-call reason above.
  func currentJoinedEventCode() -> String?
}

/// Production adapter. `onEvent` is satisfied by `BarnardEngine`'s own stored
/// property; the rest forward, and none of them re-decide anything Barnard
/// already owns.
extension BarnardEngine: EventJoinControlling {
  func requestJoinPermissions(
    _ completion: @escaping (_ canScan: Bool, _ canAdvertise: Bool) -> Void
  ) {
    requestPermissions { status in
      completion(status.canScan, status.canAdvertise)
    }
  }

  /// The only place in this app where an event code reaches Barnard's string
  /// join API. The string is not chosen here — it is
  /// `RegistryVerifiedJoinContext.joinCode`, fixed by the shared issuer when
  /// the capability was granted, so this adapter cannot pair a verified event
  /// with any other text.
  ///
  /// `joinEvent` rather than the `configure(eventCode:)` the previous code
  /// path used. Both reach `rpid.joinEvent`, so the join itself is unchanged.
  /// `configure` additionally rewrites the ENIN mode, the ENIN length and the
  /// beacon chain on every call — but it writes exactly its own parameter
  /// defaults, and those are the same values `BarnardEngine` already holds
  /// from its stored properties (`.fixedLength`, `300`, `.ethereumMainnet`).
  /// It was the only `configure` call the coordinator made, so nothing else
  /// had moved them off those values either. Dropping it therefore changes no
  /// setting; it only removes a second string door. Checked against the
  /// Barnard sources rather than assumed, because "the defaults are the same"
  /// is the kind of claim that is quietly wrong after an SDK bump — if a
  /// future Barnard changes either set of defaults, this call must become
  /// `configure(eventCode: context.joinCode)` again.
  func joinAndStart(
    _ context: ExportedKotlinPackages.org.levarac.parallax.discovery.RegistryVerifiedJoinContext
  ) {
    joinEvent(context.joinCode)
    startAuto()
  }

  func leaveJoinedEvent() {
    leaveEvent()
  }

  func stopAutomaticOperation() {
    stopAuto()
  }

  func currentJoinedEventCode() -> String? {
    getCurrentEventCode()
  }
}
