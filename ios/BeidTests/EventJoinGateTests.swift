// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

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
/// No test proves a *verified* event joins. `fromOperatorLookup` needs an
/// `EventDefinitionResolution`, and that type — like `EventDefinitionContext`
/// behind it — carries an `internal` Kotlin constructor, which Swift Export
/// emits with only a `package` initializer. No Swift code can build one.
/// Android hit the same wall and reaches a successful join by walking the real
/// nearby promotion path; that fixture is Kotlin-side and iOS has no caller
/// for that path yet. Closing this needs shared test support (beid#391).
///
/// So this suite proves the gate refuses, and cannot prove it ever admits.
/// That is stated rather than left as an absence, because a suite that only
/// ever observes "nothing joined" cannot by itself distinguish a working gate
/// from an app that joins nothing at all.
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
  func testARefusedJoinLeavesNoRelay() async {
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
