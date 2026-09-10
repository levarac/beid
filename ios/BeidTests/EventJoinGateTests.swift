// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import XCTest
@testable import Beid

/// The iOS half of the beid#374 join gate (beid#410).
///
/// ## What the first version of this suite got wrong
///
/// It asserted refusals without reaching them. `makeIsolatedSensingCoordinator`
/// passed no registry, so `beginRegistryVerifiedJoin` returned at its *first*
/// guard and nothing downstream ran — the read, the issuer and every refusal
/// past "none configured" were untouched. **Deleting the entire body of that
/// method left every test green.** The file also carried a long comment
/// claiming it drove every refusal and could tell a working gate from a
/// missing one. It drove one early return, and it could not.
///
/// The specific error is worth naming because it is subtle: the suite *did*
/// have a positive control — it asserted the permission callback was reached.
/// That control was simply one layer too shallow. Reaching the permission
/// callback and then hitting a nil-registry guard is also exactly what a
/// deleted gate body looks like, so the control could not separate them.
///
/// ## What makes these tests bite instead
///
/// `FakeEventJoinRegistry` records the event ids the gate actually asked
/// about. A test that asserts `requestedEventIdHexes` is non-empty is
/// asserting the gate reached the *read* — the depth the old suite never got
/// to. Delete the body of `beginRegistryVerifiedJoin` now and those
/// assertions fail, which is the property a coverage claim has to have.
///
/// Two tests go further and pin behaviour that is invisible to a refusal
/// assertion alone. A late permission grant, and a late registry answer, both
/// used to act on a session the user had already left; the tests for those
/// assert on what the *stale* path would have done (asked the registry;
/// skipped a cancel), because asserting "nothing joined" cannot distinguish a
/// working guard from an answer that would never have joined anyway.
///
/// ## What still cannot be expressed here
///
/// Swift still cannot construct the successful `EventDefinitionResolution`
/// needed to prove the *operator-lookup* evidence shape admits. That type —
/// like `EventDefinitionContext` behind it — has an internal Kotlin
/// constructor, which Swift Export emits with only a package initializer.
/// `RegistryClient` also has no public fakeable initializer.
///
/// beid#141 closes the broader positive-control gap through the other evidence
/// shape: focused `SensingCoordinatorTests` walk the real nearby promotion
/// reducer, issue `fromNearbyCandidate`, and assert one capability reaches
/// `joinAndStart`. The nearby refusal below also reaches
/// `.definitionNotEligible` directly with an unverified candidate. The
/// remaining unpinned claim is narrower: `RegistryEventJoinRegistry` filters
/// a failed non-optional production resolution to nil before the
/// operator-lookup gate sees it. That adapter still rests on inspection and
/// Android symmetry until a constructible Swift registry result exists.
@MainActor
final class EventJoinGateTests: XCTestCase {
  private let canonicalEventIdHex = "0x\(String(repeating: "a", count: 64))"

  /// Lets the coordinator's `Task { @MainActor in ... }` hops run.
  private func settle() async {
    try? await Task.sleep(nanoseconds: 20_000_000)
  }

  private func makeGatedCoordinator(
    engine: RecordingEventJoinControl,
    registry: FakeEventJoinRegistry? = nil,
    relay: RecordingParticipantRelayControl? = nil
  ) -> SensingCoordinator {
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      participantRelayControl: relay,
      eventJoinControl: engine,
      eventJoinRegistry: registry
    )
    coordinator.useDemoEventMode = false
    return coordinator
  }

  // MARK: - Selecting is not joining

  /// The defect this issue exists for, stated as its inverse. `joinEvent` used
  /// to call `BarnardEngine.joinEvent` on its very next line.
  func testSelectingAnEventDoesNotJoinBarnard() {
    let engine = RecordingEventJoinControl()
    let coordinator = makeGatedCoordinator(engine: engine)

    XCTAssertTrue(coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex))

    XCTAssertFalse(engine.didJoin, "selecting must not reach Barnard")
    XCTAssertEqual(coordinator.joinedEventCode, "ethtokyo2026")
  }

  // MARK: - Refusals that actually reach the read

  /// Mirrors Android's `joinEventStartsNeitherJoinNorSensingWhenNoRegistryIsConfigured`.
  ///
  /// The load-bearing assertion is `phase`, not `joinRefusal`. `startSensing`
  /// sets `.sensing` before the permission request, so a gate that returns
  /// without calling `refuseJoin` leaves the user on a sensing screen with the
  /// radio off and nothing on screen to explain it — the exact failure
  /// `refuseJoin`'s own doc comment says it exists to kill. A test that
  /// asserted only the published refusal value would stay green through
  /// precisely that regression, which is why the phase assertion comes first.
  ///
  /// This branch had a test at f21e2b1
  /// (`testStartSensingStartsNeitherJoinNorSensingWhenNoRegistryIsConfigured`)
  /// and lost it at 38ea66d, when the suite was rebuilt around
  /// `FakeEventJoinRegistry` and every remaining case started passing a
  /// registry. The rewrite that made the gate testable dropped the one branch
  /// that was already covered.
  func testStartSensingLeavesNoSensingScreenWhenNoRegistryIsConfigured() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let relay = RecordingParticipantRelayControl()
    // No registry at all: `makeGatedCoordinator` defaults `registry` to nil.
    let coordinator = makeGatedCoordinator(engine: engine, relay: relay)
    coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)

    coordinator.startSensing()
    await settle()

    XCTAssertEqual(
      coordinator.phase, .idle,
      "a refusal must return the session to idle; leaving it sensing strands the user on a sensing screen with the radio off"
    )
    XCTAssertEqual(coordinator.joinRefusal, .noRegistryConfigured)
    XCTAssertFalse(engine.didJoin, "no registry means nothing was verified, so nothing may join")
    XCTAssertNil(relay.verifier, "a refused join must leave the relay disarmed")
  }

  /// Mirrors Android's `joinEventStartsNeitherJoinNorSensingWhenTheRegistryLookupFails`.
  func testStartSensingStartsNeitherJoinNorSensingWhenTheRegistryReadFails() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    registry.answer = .readFails
    let coordinator = makeGatedCoordinator(engine: engine, registry: registry)
    coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)

    coordinator.startSensing()
    await settle()

    XCTAssertEqual(
      registry.requestedEventIdHexes, [canonicalEventIdHex],
      "the gate must reach the registry read; an empty list means it refused earlier and this test proves nothing"
    )
    XCTAssertFalse(engine.didJoin, "a failed read must start neither join nor sensing")
    XCTAssertEqual(coordinator.joinRefusal, .registryReadFailed)
    XCTAssertEqual(coordinator.phase, .idle, "a refusal must not leave the user on a sensing screen")
  }

  /// Mirrors Android's `joinEventStartsNeitherJoinNorSensingWhileTheRegistryLookupIsPending`.
  func testStartSensingStartsNeitherJoinNorSensingWhileTheRegistryReadIsPending() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    registry.answer = .holds
    let coordinator = makeGatedCoordinator(engine: engine, registry: registry)
    coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)

    coordinator.startSensing()
    await settle()

    XCTAssertEqual(registry.requestedEventIdHexes, [canonicalEventIdHex])
    XCTAssertTrue(registry.isHoldingRead, "the read must still be outstanding for this to be the pending case")
    XCTAssertFalse(engine.didJoin, "a read still in flight must start nothing")
  }

  /// A code that never obtained a canonical id never had a registry answer, so
  /// the gate refuses before the read rather than reading with nothing to ask.
  func testStartSensingStartsNothingWithoutACanonicalEventId() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    let coordinator = makeGatedCoordinator(engine: engine, registry: registry)
    coordinator.joinEvent("ethtokyo2026")

    coordinator.startSensing()
    await settle()

    XCTAssertTrue(registry.requestedEventIdHexes.isEmpty, "there is no id to ask about")
    XCTAssertFalse(engine.didJoin)
    XCTAssertEqual(coordinator.joinRefusal, .noCanonicalEventId)
  }

  /// gh#101. The event code used to fall back to the literal
  /// `"beid-demo-event"`, so a host that had never joined anything could start
  /// its radio on a hardcoded code.
  func testStartSensingStartsNothingWhenNoEventWasSelected() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    let coordinator = makeGatedCoordinator(engine: engine, registry: registry)

    coordinator.startSensing()
    await settle()

    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 1)
    XCTAssertFalse(engine.didJoin, "no event was selected, so there is nothing to sense for")
    XCTAssertEqual(engine.joinedCodes, [], "and Barnard must never receive the beid-demo-event fallback")
    guard case .idle = coordinator.phase else {
      return XCTFail("starting nothing must return the phase to idle, not leave it at \(coordinator.phase)")
    }
  }

  func testStartSensingStartsNothingWhenPermissionsAreRefused() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .denied
    let registry = FakeEventJoinRegistry()
    let coordinator = makeGatedCoordinator(engine: engine, registry: registry)
    coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)

    coordinator.startSensing()
    await settle()

    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 1)
    XCTAssertTrue(registry.requestedEventIdHexes.isEmpty, "a refused grant must not even reach the read")
    XCTAssertFalse(engine.didJoin)
    // NOTE: the phase is deliberately not asserted here yet. `startSensing`
    // leaves it at `.sensing` after a refusal — a real defect (the screen
    // claims to be sensing over a radio that never started) — but five
    // ReportSubmissionOperatorIntegrationTests currently enter their session
    // through exactly that hole, because the Simulator has no BLE radio and
    // refuses the grant. Closing it needs an admitting registry seam, which
    // `EventDefinitionResolution`'s internal constructor does not allow from
    // Swift today. Tracked separately; do not "fix" this by asserting here.
  }

  /// The same refusal on the card path (beid#141). It already resets the
  /// phase; this pins that down so the two entry points cannot drift apart
  /// again in the other direction.
  func testNearbyJoinReturnsToIdleWhenPermissionsAreRefused() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .denied
    let registry = FakeEventJoinRegistry()
    let coordinator = makeGatedCoordinator(engine: engine, registry: registry)

    coordinator.joinNearbyEvent(eventCodeHashHex: "0102030405060708")
    await settle()

    XCTAssertFalse(engine.didJoin)
    guard case .idle = coordinator.phase else {
      return XCTFail("a refused grant must return the phase to idle, not leave it at \(coordinator.phase)")
    }
  }

  func testNearbyJoinRefusesAnUnverifiedCandidateAfterPermissionCompletes() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let store = ExportedKotlinPackages.org.levarac.parallax.discovery
      .createNearbyEventDiscoveryStore()
    _ = ExportedKotlinPackages.org.levarac.parallax.discovery.recordNearbyEventHintFromHex(
      store: store,
      peripheralId: "peripheral-unverified",
      eventDisplayName: "Unverified beacon",
      eventCodeHashHex: "0102030405060708",
      censusHex: nil,
      additionalNamesOmitted: false,
      additionalEventsOmitted: false,
      observedAtEpochMillis: 1_800_000_000_000
    )
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      nearbyDiscoveryStore: store,
      nearbyDiscoveryClock: { 1_800_000_000_000 }
    )
    coordinator.useDemoEventMode = false

    coordinator.joinNearbyEvent(eventCodeHashHex: "0102030405060708")
    await settle()

    XCTAssertFalse(engine.didJoin)
    XCTAssertEqual(coordinator.joinRefusal, .definitionNotEligible)
    XCTAssertEqual(coordinator.phase, .idle)
  }

  // MARK: - Answers that arrive after the user moved on

  /// Mirrors Android's `aVerificationThatAnswersAfterTheUserLeftStartsNothing`.
  ///
  /// Asserts that the stale grant never reaches the registry. Asserting only
  /// "nothing joined" would pass whether or not the guard exists, because the
  /// fake registry cannot answer with a success anyway — so that assertion
  /// could not tell the guard from the limitation.
  func testAPermissionGrantThatLandsAfterTheUserStoppedStartsNothing() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .answersLate
    let registry = FakeEventJoinRegistry()
    let coordinator = makeGatedCoordinator(engine: engine, registry: registry)
    coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)

    coordinator.startSensing()
    await settle()
    XCTAssertTrue(engine.isHoldingPermissionRequest, "the grant must be outstanding for this to be the late case")

    _ = coordinator.stopSensing()
    engine.grantHeldPermissionRequest()
    await settle()

    XCTAssertTrue(
      registry.requestedEventIdHexes.isEmpty,
      "a grant landing after the user stopped must not start a registry read for an abandoned session"
    )
    XCTAssertFalse(engine.didJoin)
  }

  /// Mirrors the read half of Android's
  /// `aVerificationThatAnswersAfterTheUserLeftStartsNothing`, which fires both
  /// `completeHeldLookup` and `completeHeldDefinition`. iOS previously
  /// mirrored only its permission half.
  ///
  /// The other half of the same guard: the *read* can also answer after the
  /// user stopped, and that half had no test at all.
  ///
  /// `beginRegistryVerifiedJoin` checks `isCurrentJoinAttempt` twice, once at
  /// the permission grant and once inside the read's completion, because the
  /// two waits are separate and either can outlive the attempt. Only the first
  /// was pinned. Cancellation does not make this redundant: a real registry
  /// client may already have the answer in flight when `cancel` arrives, so
  /// the completion has to be safe on its own rather than merely unlikely.
  ///
  /// The assertion with teeth is `joinRefusal`, not `didJoin`. A stale answer
  /// that got through would write `.registryReadFailed` into a session the
  /// user already ended, leaving a refusal on screen for an attempt that no
  /// longer exists; `didJoin` would stay false either way, because the fake
  /// cannot answer with a success (see `FakeEventJoinRegistry`).
  func testARegistryReadThatAnswersAfterTheUserStoppedStartsNothing() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    registry.answer = .holds
    let coordinator = makeGatedCoordinator(engine: engine, registry: registry)
    coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)

    coordinator.startSensing()
    await settle()
    XCTAssertEqual(registry.requestedEventIdHexes, [canonicalEventIdHex])
    XCTAssertTrue(registry.isHoldingRead, "the read must be outstanding for this to be the late case")

    _ = coordinator.stopSensing()
    registry.answerHeldReadAsFailure()
    await settle()

    XCTAssertNil(
      coordinator.joinRefusal,
      "an answer landing after the user stopped must not record a refusal against the ended session"
    )
    XCTAssertFalse(engine.didJoin)
    XCTAssertEqual(coordinator.phase, .idle)
  }

  /// Leaving must cancel an outstanding read rather than let it answer into a
  /// session that no longer exists. Asserted through the cancel count, which a
  /// missing guard would leave at zero.
  func testLeavingCancelsAnOutstandingRegistryRead() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    registry.answer = .holds
    let coordinator = makeGatedCoordinator(engine: engine, registry: registry)
    coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)

    coordinator.startSensing()
    await settle()
    XCTAssertTrue(registry.isHoldingRead)

    coordinator.leaveEvent()
    await settle()

    XCTAssertEqual(registry.cancelCount, 1, "an abandoned read must be cancelled, not merely ignored")
    XCTAssertFalse(engine.didJoin)
  }

  /// Mirrors Android's `aRefusedJoinLeavesNoRecordingAndNoRelay`.
  ///
  /// beid#374's invariant has four parts — join, key, recording, relay — and
  /// until now this test asserted two of them while its doc comment claimed
  /// the Android mirror, which also drives detections. Detections keep
  /// arriving from the radio whether or not this device joined anything, so
  /// "nothing joined" does not by itself establish that a later detection
  /// cannot carry a refused join into a recording session. That is the part
  /// the detections below add.
  func testARefusedJoinLeavesNoRecordingAndNoRelay() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    registry.answer = .readFails
    let relay = RecordingParticipantRelayControl()
    let coordinator = makeGatedCoordinator(engine: engine, registry: registry, relay: relay)
    coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)

    coordinator.startSensing()
    await settle()

    XCTAssertEqual(registry.requestedEventIdHexes, [canonicalEventIdHex])
    XCTAssertFalse(engine.didJoin)
    XCTAssertNil(relay.verifier, "a refused join must leave the relay disarmed")

    // The radio does not stop because this device refused to join.
    coordinator.handleDetection(enin: 1, rpid: "aa", detectedDisplayId: "device-1")
    coordinator.handleDetection(enin: 2, rpid: "bb", detectedDisplayId: "device-2")
    coordinator.handleDetection(enin: 3, rpid: "cc", detectedDisplayId: "device-3")
    await settle()

    switch coordinator.phase {
    case .recording, .eventFound, .signalLost:
      XCTFail(
        "detections must not carry a refused join into a recording session; phase was \(coordinator.phase)"
      )
    case .idle, .sensing:
      break
    }
    XCTAssertNil(relay.verifier, "detections must not arm the relay for a refused join")
    XCTAssertFalse(engine.didJoin, "detections must not retroactively join a refused event")
  }

  // MARK: - Demo mode stays outside the gate

  /// Demo mode never reaches Barnard and is the App Review path. It must not
  /// ask for permissions, read the registry, or join.
  func testDemoModeNeitherRequestsPermissionsNorReadsTheRegistry() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      eventJoinRegistry: registry
    )
    coordinator.useDemoEventMode = true

    coordinator.startSensing()
    await settle()

    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 0)
    XCTAssertTrue(registry.requestedEventIdHexes.isEmpty)
    XCTAssertFalse(engine.didJoin)
  }

  // MARK: - Leaving

  func testLeavingClearsTheJoinedEvent() {
    let engine = RecordingEventJoinControl()
    engine.currentEventCode = "ethtokyo2026"
    let coordinator = makeGatedCoordinator(engine: engine)

    coordinator.leaveEvent()

    XCTAssertEqual(engine.leaveJoinedEventCallCount, 1)
    XCTAssertNil(coordinator.joinedEventCode)
  }
}
