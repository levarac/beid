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
  private func makeCoordinator(
    sensingCryptography: any SensingCryptography = DeterministicSensingCryptography()
  ) -> (SensingCoordinator, WindowReportStore) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("window-finalization-test-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      preconditionFailure("Unable to create test directory: \(error)")
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let store = WindowReportStore(
      fileURL: directory.appendingPathComponent("window-reports.json")
    )
    let coordinator = SensingCoordinator(
      windowReportStore: store,
      selfProofStore: SelfProofStore(
        fileURL: directory.appendingPathComponent("self-proofs.json")
      ),
      unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
      sensingCryptography: sensingCryptography
    )
    // Real (non-demo) path: avoids racing runDemoSequence's own phase
    // transitions against this test's manual handleDetection(_:_:) calls.
    coordinator.useDemoEventMode = false
    return (coordinator, store)
  }

  func testFinalWindowUsesInjectedSignatureWithoutChangingItsBytesOrRecoveryID() {
    let signature = SensingRecoverableSignature(
      r: Data([0x00] + [UInt8](repeating: 0xa1, count: 31)),
      s: Data([0x00, 0x00] + [UInt8](repeating: 0xb2, count: 30)),
      v: 3
    )
    let cryptography = DeterministicSensingCryptography(windowReportSignature: signature)
    let (coordinator, store) = makeCoordinator(sensingCryptography: cryptography)
    coordinator.startSensing(eventCode: "TEST-WINDOW-FACADE")
    coordinator.handleDetection(enin: 7, rpid: "peer-0")

    coordinator.reset()

    let report = store.reports.first
    XCTAssertEqual(
      report?.signatureRHex,
      signature.r.map { String(format: "%02x", $0) }.joined()
    )
    XCTAssertEqual(
      report?.signatureSHex,
      signature.s.map { String(format: "%02x", $0) }.joined()
    )
    XCTAssertEqual(report?.signatureV, signature.v)
    XCTAssertEqual(
      cryptography.calls.filter {
        if case .signWindowReport = $0 { return true }
        return false
      }.count,
      1,
      "the final window must be signed exactly once through the injected facade"
    )
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
