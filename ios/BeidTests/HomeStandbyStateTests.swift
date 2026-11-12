// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Combine
import XCTest
@testable import Beid

final class HomeStandbyStateTests: XCTestCase {
  func testFallbackUsesTheThirtySecondBoundary() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasJoinableCandidates: false, now: 100)
    XCTAssertFalse(state.offersCodeEntry(at: 129))
    XCTAssertTrue(state.offersCodeEntry(at: 130))
  }

  func testCandidateArrivalCancelsAndRemovalRestartsTheInterval() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasJoinableCandidates: false, now: 100)
    state.update(isEnabled: true, hasJoinableCandidates: true, now: 129)
    XCTAssertFalse(state.offersCodeEntry(at: 200))
    state.update(isEnabled: true, hasJoinableCandidates: false, now: 300)
    XCTAssertFalse(state.offersCodeEntry(at: 329))
    XCTAssertTrue(state.offersCodeEntry(at: 330))
  }

  func testLeavingHomeOrPausingDiscoveryDiscardsTheInterval() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasJoinableCandidates: false, now: 100)
    state.update(isEnabled: false, hasJoinableCandidates: false, now: 129)
    XCTAssertFalse(state.offersCodeEntry(at: 500))
    state.update(isEnabled: true, hasJoinableCandidates: false, now: 600)
    XCTAssertFalse(state.offersCodeEntry(at: 629))
    XCTAssertTrue(state.offersCodeEntry(at: 630))
  }

  func testRepeatedUpdatesDoNotRestartAnUninterruptedInterval() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasJoinableCandidates: false, now: 100)
    state.update(isEnabled: true, hasJoinableCandidates: false, now: 115)
    state.update(isEnabled: true, hasJoinableCandidates: false, now: 129)
    XCTAssertTrue(state.offersCodeEntry(at: 130))
    XCTAssertEqual(state.elapsed(at: 130), 30)
  }

  func testOnlyUnjoinableCandidatesStillOfferCodeEntryAtThirtySeconds() {
    var state = HomeStandbyState()
    // A nearby event is visible but its JOIN control is disabled, so the
    // caller reports no joinable candidate and the timer keeps running.
    state.update(isEnabled: true, hasJoinableCandidates: false, now: 100)
    state.update(isEnabled: true, hasJoinableCandidates: false, now: 115)
    XCTAssertFalse(state.offersCodeEntry(at: 129))
    XCTAssertTrue(state.offersCodeEntry(at: 130))
  }

  func testNoCandidatesOffersCodeEntryAtThirtySeconds() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasJoinableCandidates: false, now: 0)
    XCTAssertFalse(state.offersCodeEntry(at: 29))
    XCTAssertTrue(state.offersCodeEntry(at: 30))
  }

  func testJoinableCandidateKeepsCodeEntryHidden() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasJoinableCandidates: true, now: 0)
    XCTAssertFalse(state.offersCodeEntry(at: 30))
    XCTAssertFalse(state.offersCodeEntry(at: 300))
  }

  func testUnjoinableCandidateBecomingJoinableResetsTheTimer() {
    var state = HomeStandbyState()
    state.update(isEnabled: true, hasJoinableCandidates: false, now: 100)
    state.update(isEnabled: true, hasJoinableCandidates: true, now: 125)
    XCTAssertFalse(state.offersCodeEntry(at: 200))
    XCTAssertNil(state.listeningStartedAt)
    state.update(isEnabled: true, hasJoinableCandidates: false, now: 210)
    XCTAssertFalse(state.offersCodeEntry(at: 239))
    XCTAssertTrue(state.offersCodeEntry(at: 240))
  }

  func testNoFallbackBeforeDiscoveryBeginsOrWhileCandidatesExist() {
    var state = HomeStandbyState()
    XCTAssertFalse(state.offersCodeEntry(at: 300))
    state.update(isEnabled: true, hasJoinableCandidates: true, now: 100)
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

  func testPendingStopAcknowledgementRestartsReenabledHomeDiscovery() async {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    sensing.useDemoEventMode = false
    let app = makeApp(sensing: sensing)
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    await deliverScanState(true, through: engine, to: sensing)

    app.updateHomeStandby(isVisible: false, isSceneActive: true)
    XCTAssertEqual(engine.stopDiscoveryScanCallCount, 1)
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    XCTAssertTrue(app.homeStandbyDiscoveryActive)
    XCTAssertTrue(sensing.isScanning, "The previous scan still awaits its stop acknowledgement")
    XCTAssertEqual(engine.startDiscoveryScanCallCount, 1, "Restart waits for the stopped callback")

    await deliverScanState(false, through: engine, to: sensing)
    XCTAssertEqual(engine.startDiscoveryScanCallCount, 2, "The stop acknowledgement must release the deferred start")
    await deliverScanState(true, through: engine, to: sensing)
    XCTAssertTrue(sensing.isScanning)
    XCTAssertEqual(sensing.phase, .idle)
    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 0)
    XCTAssertFalse(engine.didJoin)
  }

  func testDisablingAgainCancelsADeferredHomeDiscoveryRestart() async {
    let engine = RecordingEventJoinControl()
    let sensing = makeIsolatedSensingCoordinator(for: self, eventJoinControl: engine)
    sensing.useDemoEventMode = false
    let app = makeApp(sensing: sensing)
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    await deliverScanState(true, through: engine, to: sensing)

    app.updateHomeStandby(isVisible: false, isSceneActive: true)
    app.updateHomeStandby(isVisible: true, isSceneActive: true)
    app.updateHomeStandby(isVisible: true, isSceneActive: false)
    await deliverScanState(false, through: engine, to: sensing)

    XCTAssertFalse(app.homeStandbyDiscoveryActive)
    XCTAssertNil(app.homeStandby.listeningStartedAt)
    XCTAssertFalse(sensing.isScanning)
    XCTAssertEqual(engine.startDiscoveryScanCallCount, 1, "A stopped callback cannot restart background discovery")
    XCTAssertEqual(engine.stopDiscoveryScanCallCount, 1)
    XCTAssertEqual(engine.requestJoinPermissionsCallCount, 0)
    XCTAssertFalse(engine.didJoin)
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

  func testSensingScreenShowsListeningStateOnlyAfterJoining() {
    let sensing = makeIsolatedSensingCoordinator(for: self)
    sensing.useDemoEventMode = true
    XCTAssertFalse(SensingView(sensing: sensing).isListeningAfterJoin, "before JOIN the screen still asks for it")
    sensing.startSensing()
    XCTAssertEqual(sensing.phase, .sensing)
    XCTAssertTrue(SensingView(sensing: sensing).isListeningAfterJoin)
    _ = sensing.reset()
  }

  private func deliverScanState(
    _ isScanning: Bool,
    through engine: RecordingEventJoinControl,
    to sensing: SensingCoordinator
  ) async {
    let delivered = expectation(description: "The engine reports scanning=\(isScanning)")
    let observation = sensing.$isScanning.dropFirst().prefix(1).sink { _ in delivered.fulfill() }
    engine.emitState(isScanning: isScanning)
    await fulfillment(of: [delivered], timeout: 1)
    observation.cancel()
    XCTAssertEqual(sensing.isScanning, isScanning)
  }

  private func makeApp(sensing: SensingCoordinator) -> AppCoordinator {
    let defaults = UserDefaults(suiteName: "HomeStandbyLifecycleTests.\(UUID().uuidString)")!
    let app = AppCoordinator(sensingCoordinator: sensing, registryClient: nil, userDefaults: defaults)
    app.screen = .home
    return app
  }
}

@MainActor
final class ActiveSessionControlsTests: XCTestCase {
  private let event = EventSession(id: "TEST-CONTROLS", name: "Test Controls Event", venue: nil)

  func testBluetoothSettingsResetsOnlyWhenNoEventSessionIsActive() {
    typealias App = AppCoordinator
    XCTAssertTrue(App.shouldResetSensing(beforeOpeningBluetoothSettingsIn: .idle, joinedEventCode: nil))
    XCTAssertTrue(App.shouldResetSensing(beforeOpeningBluetoothSettingsIn: .sensing, joinedEventCode: nil))
    XCTAssertFalse(App.shouldResetSensing(beforeOpeningBluetoothSettingsIn: .sensing, joinedEventCode: "code"))
    XCTAssertFalse(App.shouldResetSensing(beforeOpeningBluetoothSettingsIn: .eventFound(event), joinedEventCode: "code"))
    XCTAssertFalse(App.shouldResetSensing(
      beforeOpeningBluetoothSettingsIn: .recording(event: event, peersVerified: 1), joinedEventCode: "code"))
    XCTAssertFalse(App.shouldResetSensing(
      beforeOpeningBluetoothSettingsIn: .signalLost(event: event, peersVerified: 1), joinedEventCode: "code"))
  }

  func testStopControlShowsWhenJoinedEvenBeforeTheFirstPhoneIsHeard() {
    XCTAssertFalse(ScanFlowView.showsStopControl(phase: .idle, joinedEventCode: nil))
    XCTAssertFalse(ScanFlowView.showsStopControl(phase: .idle, joinedEventCode: "code"))
    XCTAssertFalse(ScanFlowView.showsStopControl(phase: .sensing, joinedEventCode: nil))
    XCTAssertTrue(ScanFlowView.showsStopControl(phase: .sensing, joinedEventCode: "code"))
    XCTAssertTrue(ScanFlowView.showsStopControl(phase: .eventFound(event), joinedEventCode: nil))
    XCTAssertTrue(ScanFlowView.showsStopControl(phase: .recording(event: event, peersVerified: 1), joinedEventCode: nil))
    XCTAssertTrue(ScanFlowView.showsStopControl(phase: .signalLost(event: event, peersVerified: 1), joinedEventCode: nil))
  }
}
