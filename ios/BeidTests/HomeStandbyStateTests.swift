// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

final class HomeStandbyStateTests: XCTestCase {
  func testFallbackUsesTheThirtySecondBoundary() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasCandidates: false, now: 100)
    XCTAssertFalse(state.offersCodeEntry(at: 129))
    XCTAssertTrue(state.offersCodeEntry(at: 130))
  }

  func testCandidateArrivalCancelsAndRemovalRestartsTheInterval() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasCandidates: false, now: 100)
    state.update(isEnabled: true, hasCandidates: true, now: 129)
    XCTAssertFalse(state.offersCodeEntry(at: 200))
    state.update(isEnabled: true, hasCandidates: false, now: 300)
    XCTAssertFalse(state.offersCodeEntry(at: 329))
    XCTAssertTrue(state.offersCodeEntry(at: 330))
  }

  func testLeavingHomeOrPausingDiscoveryDiscardsTheInterval() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasCandidates: false, now: 100)
    state.update(isEnabled: false, hasCandidates: false, now: 129)
    XCTAssertFalse(state.offersCodeEntry(at: 500))
    state.update(isEnabled: true, hasCandidates: false, now: 600)
    XCTAssertFalse(state.offersCodeEntry(at: 629))
    XCTAssertTrue(state.offersCodeEntry(at: 630))
  }

  func testRepeatedUpdatesDoNotRestartAnUninterruptedInterval() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasCandidates: false, now: 100)
    state.update(isEnabled: true, hasCandidates: false, now: 115)
    state.update(isEnabled: true, hasCandidates: false, now: 129)
    XCTAssertTrue(state.offersCodeEntry(at: 130))
    XCTAssertEqual(state.elapsed(at: 130), 30)
  }

  func testNoFallbackBeforeDiscoveryBeginsOrWhileCandidatesExist() {
    var state = HomeStandbyState()
    XCTAssertFalse(state.offersCodeEntry(at: 300))
    state.update(isEnabled: true, hasCandidates: true, now: 100)
    XCTAssertFalse(state.offersCodeEntry(at: 300))
    XCTAssertEqual(state.elapsed(at: 300), 0)
  }
}

@MainActor
final class HomeStandbyLifecycleTests: XCTestCase {
  func testVisibleIdleHomeStartsOnlyDiscoveryAndLeavingStopsItsScan() {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    sensing.useDemoEventMode = false
    let app = makeApp(sensing: sensing)
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    XCTAssertEqual(engine.startDiscoveryScanCallCount, 1)
    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 0)
    XCTAssertEqual(engine.joinAndStartContexts.count, 0)
    XCTAssertEqual(sensing.phase, .idle)
    XCTAssertNotNil(app.homeStandby.listeningStartedAt)
    app.updateHomeStandby(isVisible: false, isSceneActive: true)
    XCTAssertEqual(engine.stopDiscoveryScanCallCount, 1)
    XCTAssertNil(app.homeStandby.listeningStartedAt)
  }

  func testBackgroundAndTabSwitchingPauseAndRestartDiscovery() {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    sensing.useDemoEventMode = false
    let app = makeApp(sensing: sensing)
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    app.updateHomeStandby(isVisible: true, isSceneActive: false)
    XCTAssertEqual(engine.stopDiscoveryScanCallCount, 1)
    XCTAssertNil(app.homeStandby.listeningStartedAt)
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    app.selectedHomeTab = .records
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    XCTAssertEqual(engine.stopDiscoveryScanCallCount, 2)
    app.selectedHomeTab = .now
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    XCTAssertEqual(engine.startDiscoveryScanCallCount, 3)
  }

  func testAccountAndCodeEntrySuspendEmptyDiscovery() {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    sensing.useDemoEventMode = false
    let app = makeApp(sensing: sensing)
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    app.accountSheetPresented = true
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    XCTAssertFalse(app.homeStandbyDiscoveryActive)
    app.accountSheetPresented = false
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    app.homeEventCodeSheetPresented = true
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    XCTAssertEqual(engine.stopDiscoveryScanCallCount, 2)
    XCTAssertNil(app.homeStandby.listeningStartedAt)
  }

  func testDemoStandbyWaitsForAnExplicitJoin() {
    let sensing = makeIsolatedSensingCoordinator(for: self)
    sensing.useDemoEventMode = true
    let app = makeApp(sensing: sensing)
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    XCTAssertTrue(sensing.homeDemoEventAvailable)
    XCTAssertEqual(sensing.phase, .idle)
    XCTAssertNil(sensing.currentProofID)
    XCTAssertFalse(app.scanPresented)
    XCTAssertFalse(app.homeStandby.offersCodeEntry(at: app.homeStandbyNow + 60))
    app.joinDemoEventFromHome()
    XCTAssertTrue(app.scanPresented)
    XCTAssertNotEqual(sensing.phase, .idle)
    _ = sensing.reset()
  }

  func testReturningHomePreservesAnAlreadyStartedSession() {
    let sensing = makeIsolatedSensingCoordinator(for: self)
    sensing.useDemoEventMode = true
    sensing.startSensing()
    let activePhase = sensing.phase
    let app = makeApp(sensing: sensing)
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    XCTAssertEqual(sensing.phase, activePhase)
    XCTAssertFalse(app.homeStandbyDiscoveryActive)
    XCTAssertNil(app.homeStandby.listeningStartedAt)
    _ = sensing.reset()
  }

  func testHomeCodeEntryStartsTheSelectedEventThroughTheExistingGate() async {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    sensing.useDemoEventMode = false
    let app = makeApp(sensing: sensing)
    app.resolveCanonicalEventIdHexOverride = { _ in
      .init(eventIdHex: String(repeating: "aa", count: 32), errorCode: nil)
    }
    app.homeEventCodeSheetPresented = true
    let outcome = await app.joinEventFromHomeResolvingCanonicalId(code: "sample-event")
    XCTAssertEqual(outcome, .completed(nil))
    XCTAssertFalse(app.homeEventCodeSheetPresented)
    XCTAssertTrue(app.scanPresented)
    XCTAssertEqual(sensing.phase, .sensing)
    XCTAssertEqual(engine.joinAndStartContexts.count, 0, "permission and registration still gate admission")
    _ = sensing.reset()
  }

  private func makeApp(sensing: SensingCoordinator) -> AppCoordinator {
    let defaults = UserDefaults(suiteName: "HomeStandbyLifecycleTests.\(UUID().uuidString)")!
    let app = AppCoordinator(sensingCoordinator: sensing, registryClient: nil, userDefaults: defaults)
    app.screen = .home
    return app
  }
}
