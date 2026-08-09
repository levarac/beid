// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import XCTest
@testable import Beid

final class VenueDeviceBroadcastingTests: XCTestCase {
  /// gh#138 dual-role verification (`docs/specs/participation-surface.md`
  /// §3.2/§5.2): can one `BarnardEngine` instance act as a sensing
  /// participant (`configure(eventCode:) + startAuto()`) AND serve B005
  /// venue-device info (`configureEventInfoServing`) at the same time?
  ///
  /// Source-read finding this session (`BarnardEngine.swift`,
  /// `BarnardEventInfo.swift`, pinned revision `57a8a7df7f4b2078150eabff4c06a46cfb2aae0f`
  /// == the exact commit `Package.resolved` pins for 0.3.0): B005's
  /// `configureEventInfoServing` is a pure state setter that only assigns
  /// `eventInfoServePolicy`/`eventInfoDisplayName`; it never touches
  /// scanning, advertising, or `configure(eventCode:)`. B002-B005 are added
  /// together as one GATT service in `buildAndAddGattService()`, so nothing
  /// disables one characteristic set when the other is active. This test
  /// exercises that claim directly rather than trusting the source read
  /// alone — a passing build here is the actual evidence the finding is
  /// real, not just plausible.
  ///
  /// iOS Simulator has no BLE radio (see `ios/README.md`, AGENTS.md), so
  /// `startAuto()`'s scan/advertise never actually go live here — Barnard's
  /// own permission-status check (`BarnardEngine.permissionStatusPayload`)
  /// reports `canScan`/`canAdvertise` false on simulator regardless of
  /// authorization, and `SensingCoordinator.startSensing` already relies on
  /// that gate for its own real (non-demo) path. What this test proves is
  /// narrower and still the thing gh#138 needed verified: neither call
  /// throws, and `configureEventInfoServing` does not reset or otherwise
  /// disturb the `eventCode` `configure(eventCode:)` set on the same engine
  /// instance.
  func testDualRoleConfigureAndServeEventInfoOnSameEngineInstance() throws {
    let engine = BarnardEngine()
    let eventCode = "DUALROLE-TEST-EVENT"

    engine.configure(eventCode: eventCode)
    XCTAssertEqual(engine.getCurrentEventCode(), eventCode)

    // Participant role: scan + advertise for the same engine instance.
    engine.startAuto()

    // Organizer role, same instance, same moment — must not throw and must
    // not interfere with the participant role's eventCode.
    XCTAssertNoThrow(
      try engine.configureEventInfoServing(
        organizerDesignated: true,
        eventActiveForDiscovery: true,
        eventDisplayName: "Dual Role Booth"
      )
    )

    XCTAssertEqual(
      engine.getCurrentEventCode(),
      eventCode,
      "configureEventInfoServing must not reset the participant eventCode configure(eventCode:) set"
    )

    let state = engine.getState()
    XCTAssertEqual(
      state.eventCode,
      eventCode,
      "the engine's overall state must still reflect the participant eventCode after organizer-role calls"
    )

    engine.stopAuto()
    engine.dispose()
  }

  /// Same scenario, opposite call order — the organizer role activating
  /// before the participant role joins an event should not prevent the
  /// later `configure(eventCode:)` from taking effect either.
  func testDualRoleServeEventInfoBeforeConfiguringParticipantEventCode() throws {
    let engine = BarnardEngine()

    XCTAssertNoThrow(
      try engine.configureEventInfoServing(
        organizerDesignated: true,
        eventActiveForDiscovery: true,
        eventDisplayName: "Booth Set Up Early"
      )
    )

    let eventCode = "DUALROLE-TEST-EVENT-2"
    engine.configure(eventCode: eventCode)
    engine.startAuto()

    XCTAssertEqual(engine.getCurrentEventCode(), eventCode)

    engine.stopAuto()
    engine.dispose()
  }

  func testFacadeStartBroadcastingConfiguresEventCodeAndDoesNotThrowForAValidLabel() {
    let broadcasting = BarnardVenueDeviceBroadcasting()
    XCTAssertNoThrow(
      try broadcasting.startBroadcasting(eventCode: "FACADE-EVENT", label: "Front Desk")
    )
    // Safe to call more than once, and stop is safe without a prior start.
    broadcasting.stopBroadcasting()
    broadcasting.stopBroadcasting()
  }

  func testFacadeStartBroadcastingThrowsForAnOverlongLabel() {
    let broadcasting = BarnardVenueDeviceBroadcasting()
    let overlongLabel = String(repeating: "a", count: 65)

    XCTAssertThrowsError(
      try broadcasting.startBroadcasting(eventCode: "FACADE-EVENT", label: overlongLabel)
    ) { error in
      XCTAssertEqual(error as? BarnardEventInfoError, .invalidDisplayName)
    }
  }
}
