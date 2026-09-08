// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// The iOS half of the beid#374 join gate (beid#410).
///
/// ## Why every test here asserts a *positive* fact as well as a refusal
///
/// Each test below ends in "and nothing was joined". On its own that assertion
/// is nearly worthless on this host: the iOS Simulator has no BLE radio, so
/// before this change `requestPermissions` never reported `canScan`/
/// `canAdvertise`, its completion never ran, and *nothing was ever joined in
/// any test whatsoever*. A refusal test written against that apparatus is green
/// whether the gate works, whether it is absent, and whether the code under it
/// was deleted outright.
///
/// So every test here also asserts `requestJoinPermissionsCallCount == 1`. That
/// is the positive control: it proves the run actually reached the gated path
/// and was refused there, rather than stopping somewhere earlier and looking
/// identical. `RecordingEventJoinControl.permissionOutcome` is what makes that
/// possible, and it defaults to `.neverAnswers` precisely so a test has to opt
/// into the grant deliberately.
///
/// It is the same discipline `ParticipantRelayTests.testResettingClearsTheRelay`
/// records for itself — arm the thing first, or the assertion is not about what
/// its name claims.
///
/// ## What this suite deliberately cannot do, and why that is not a gap here
///
/// There is no test that a *verified* event joins successfully, because Swift
/// cannot build one to verify. `fromOperatorLookup` needs an
/// `EventDefinitionResolution`, and that type — like `EventDefinitionContext`
/// behind it — carries an `internal` Kotlin constructor, which Swift Export
/// emits with only a `package` initializer. No Swift code, production or test,
/// can construct either.
///
/// Android reached the same wall and recorded it in `FakeEventJoinRegistry.kt`,
/// resolving it by walking the real nearby promotion path into a
/// registry-verified candidate. That fixture is Kotlin-side and unreachable
/// from Swift, and iOS has no surface that joins a discovered candidate yet.
/// Closing this needs shared-side test support (beid#391), not another iOS
/// test. It is called out rather than left as an absence, because a suite that
/// can only ever observe "nothing joined" cannot by itself distinguish a
/// working gate from an app that joins nothing at all.
@MainActor
final class EventJoinGateTests: XCTestCase {
  /// Lets the coordinator's `Task { @MainActor in ... }` hop run before the
  /// assertions read the fake.
  private func settle() async {
    try? await Task.sleep(nanoseconds: 20_000_000)
  }

  // MARK: - Selecting is not joining

  /// The defect this issue exists for, stated as its inverse.
  ///
  /// `joinEvent` used to call `BarnardEngine.joinEvent` on its very next line,
  /// so the app was joined before any registry read had verified anything. It
  /// must now reach Barnard not at all: the join belongs to `startSensing`,
  /// behind the capability.
  func testSelectingAnEventDoesNotJoinBarnard() {
    let engine = RecordingEventJoinControl()
    let coordinator = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    coordinator.useDemoEventMode = false

    XCTAssertTrue(coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: "abc123"))

    XCTAssertFalse(
      engine.didJoin,
      "selecting an event must not reach Barnard; the join belongs behind the capability"
    )
    XCTAssertEqual(coordinator.joinedEventCode, "ethtokyo2026", "the selection is still recorded")
  }

  // MARK: - startSensing refuses without a capability

  /// The second door, and the one no issue text named: `startSensing` reached
  /// `configure(eventCode:)` and `startAuto()` without passing through
  /// `joinEvent` at all.
  func testStartSensingStartsNeitherJoinNorSensingWhenNoRegistryIsConfigured() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let coordinator = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    coordinator.useDemoEventMode = false
    coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: "abc123")

    coordinator.startSensing()
    await settle()

    XCTAssertEqual(
      engine.requestJoinPermissionsCallCount, 1,
      "the run must actually reach the gated path, or the refusal below proves nothing"
    )
    XCTAssertFalse(
      engine.didJoin,
      "with no registry client there is nothing to verify against, so nothing may start"
    )
  }

  /// A code that never obtained a canonical id never had a registry answer, so
  /// there is nothing to issue a capability from.
  func testStartSensingStartsNeitherJoinNorSensingWithoutACanonicalEventId() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let coordinator = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    coordinator.useDemoEventMode = false
    coordinator.joinEvent("ethtokyo2026")

    coordinator.startSensing()
    await settle()

    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 1)
    XCTAssertFalse(engine.didJoin)
  }

  /// gh#101, closed here. `startSensing`'s event code used to fall back to the
  /// literal `"beid-demo-event"`, so a host that had never joined anything
  /// could start its radio on a hardcoded code — an ungated path with a
  /// built-in destination.
  func testStartSensingStartsNothingWhenNoEventWasSelected() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let coordinator = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    coordinator.useDemoEventMode = false

    coordinator.startSensing()
    await settle()

    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 1)
    XCTAssertFalse(engine.didJoin, "no event was selected, so there is nothing to sense for")
    XCTAssertEqual(
      engine.joinedCodes, [],
      "and in particular Barnard must never be handed the beid-demo-event fallback"
    )
  }

  /// Refused permissions must stop the sequence before the gate, not after it.
  func testStartSensingStartsNothingWhenPermissionsAreRefused() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .denied
    let coordinator = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    coordinator.useDemoEventMode = false
    coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: "abc123")

    coordinator.startSensing()
    await settle()

    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 1)
    XCTAssertFalse(engine.didJoin)
  }

  /// Scanning without advertising is not a partial grant this app proceeds on:
  /// both arms are required, and the pair is asserted rather than assumed
  /// because `.reports` can express the mixed case that `.granted`/`.denied`
  /// cannot.
  func testStartSensingStartsNothingWhenOnlyScanningIsPermitted() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .reports(canScan: true, canAdvertise: false)
    let coordinator = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    coordinator.useDemoEventMode = false
    coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: "abc123")

    coordinator.startSensing()
    await settle()

    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 1)
    XCTAssertFalse(engine.didJoin)
  }

  // MARK: - Demo mode stays outside the gate

  /// Demo mode never reaches Barnard, and it is the App Review path. It must
  /// not ask for permissions or join, whatever the gate does.
  func testDemoModeNeitherRequestsPermissionsNorJoins() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let coordinator = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    coordinator.useDemoEventMode = true

    coordinator.startSensing()
    await settle()

    XCTAssertEqual(
      engine.requestJoinPermissionsCallCount, 0,
      "demo mode must not touch the radio path at all"
    )
    XCTAssertFalse(engine.didJoin)
  }

  // MARK: - Leaving

  /// Leaving clears Barnard's event even though selecting never set one there,
  /// so a session begun by a previous `startSensing` is properly ended.
  func testLeavingClearsTheJoinedEvent() {
    let engine = RecordingEventJoinControl()
    engine.currentEventCode = "ethtokyo2026"
    let coordinator = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    coordinator.useDemoEventMode = false

    coordinator.leaveEvent()

    XCTAssertEqual(engine.leaveJoinedEventCallCount, 1)
    XCTAssertNil(coordinator.joinedEventCode)
  }
}
