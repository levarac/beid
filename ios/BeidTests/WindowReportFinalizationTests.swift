// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// `SensingCoordinator`'s explicit-stop window-close fix
/// (`docs/specs/session-end-finalization.md` §3.3/§3.5, sub-slice 1, §8.1).
/// Drives the real (non-demo) detection path via
/// `handleDetection(enin:rpid:)` — a test seam, since `BarnardDetectionEvent`
/// has no public initializer outside the Barnard module — rather than
/// `runDemoSequence`, since demo mode deliberately never produces
/// `WindowReport`s (`SensingCoordinator.advanceDemoWindow()`'s own doc
/// comment).
@MainActor
final class WindowReportFinalizationTests: XCTestCase {
  private func makeCoordinator() -> (SensingCoordinator, WindowReportStore) {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("window-reports-test-\(UUID().uuidString).json")
    let store = WindowReportStore(fileURL: fileURL)
    let coordinator = SensingCoordinator(windowReportStore: store)
    // Real (non-demo) path: avoids racing runDemoSequence's own phase
    // transitions against this test's manual handleDetection(_:_:) calls.
    coordinator.useDemoEventMode = false
    return (coordinator, store)
  }

  func testSessionThatReachesRecordingWithoutCrossingAWindowBoundaryReportsExactlyOneWindowOnReset() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-WINDOW-RECORDING")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(enin: 1, rpid: "peer-\(index)")
    }

    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording phase, got \(coordinator.phase)")
      return
    }

    coordinator.reset()

    XCTAssertEqual(
      store.reports.count, 1,
      "a session that never crossed a window boundary must still report the one window it did observe"
    )
    XCTAssertEqual(store.reports.first?.enin, 1)
    XCTAssertEqual(store.reports.first?.peerCount, threshold)
  }

  func testSessionThatOnlyReachesEventFoundReportsExactlyOneWindowOnReset() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-WINDOW-EVENTFOUND")

    // Strictly below the confirm threshold — stays in .eventFound, never
    // reaches .recording. Proves the currentSessionEventCode scoping fix
    // (§3.2), not just the stop-time wiring the prior test already covers:
    // currentBindingEvent alone would return nil here and silently drop
    // this report.
    coordinator.handleDetection(enin: 1, rpid: "peer-0")

    guard case .eventFound = coordinator.phase else {
      XCTFail("expected .eventFound phase, got \(coordinator.phase)")
      return
    }

    coordinator.reset()

    XCTAssertEqual(
      store.reports.count, 1,
      "a session that observed a peer but never reached .recording must still report its one window"
    )
    XCTAssertEqual(store.reports.first?.peerCount, 1)
  }

  func testStopSensingThenResetDoesNotDoubleCountTheFinalWindow() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-WINDOW-DOUBLE-FINALIZE")

    let threshold = BeidConfig.eventConfirmThreshold
    for index in 0..<threshold {
      coordinator.handleDetection(enin: 1, rpid: "peer-\(index)")
    }

    coordinator.stopSensing()
    XCTAssertEqual(store.reports.count, 1)

    coordinator.reset()
    XCTAssertEqual(
      store.reports.count, 1,
      "reset() after stopSensing() must not re-close the already-closed window"
    )
  }

  func testSessionThatNeverObservesAnyPeerReportsNothing() {
    let (coordinator, store) = makeCoordinator()
    coordinator.startSensing(eventCode: "TEST-WINDOW-NO-PEERS")

    coordinator.reset()

    XCTAssertTrue(store.reports.isEmpty, "no window was ever open — nothing to report (§3.7)")
  }
}
