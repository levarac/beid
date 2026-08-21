// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import XCTest
@testable import Beid

@MainActor
private final class ReportSubmissionRuntimeSpy: WindowReportSubmissionRuntimeProtocol {
  struct Capture {
    let id: UUID
    let eventCode: String
    let enin: Int
    let peerRpids: Set<String>
    let reporterRpid: String?
    let participantCommitment: Data?
  }

  var captures: [Capture] = []
  var submitPendingCallCount = 0

  func captureAndQueueWindow(
    id: UUID,
    eventCode: String,
    enin: Int,
    peerRpids: Set<String>,
    reporterRpid: String?,
    participantCommitment: Data?
  ) {
    captures.append(
      Capture(
        id: id,
        eventCode: eventCode,
        enin: enin,
        peerRpids: peerRpids,
        reporterRpid: reporterRpid,
        participantCommitment: participantCommitment
      )
    )
  }

  func submitPending() {
    submitPendingCallCount += 1
  }
}

@MainActor
final class ReportSubmissionWiringTests: XCTestCase {
  func testWindowCloseCapturesLosslessInputsOnceAcrossForegroundAndBackgroundTriggers() {
    let runtime = ReportSubmissionRuntimeSpy()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      reportSubmissionRuntime: runtime
    )
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: "TEST-REPORT-SUBMISSION-WIRING")

    let threshold = BeidConfig.eventConfirmThreshold
    let reporterRpid = "01" + String(repeating: "aa", count: 16)
    var expectedPeerRpids = Set<String>()
    for index in 0..<threshold {
      let rpid = "peer-\(index)"
      expectedPeerRpids.insert(rpid)
      coordinator.handleDetection(
        enin: 7,
        rpid: rpid,
        detectedDisplayId: DetectionFixture.displayId(device: index),
        reporterRpid: reporterRpid
      )
    }

    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording phase, got \(coordinator.phase)")
      return
    }

    coordinator.checkpointOpenWindowForBackgrounding()
    _ = coordinator.stopSensing()
    coordinator.reset()

    XCTAssertEqual(runtime.captures.count, 1)
    XCTAssertFalse(runtime.captures.first?.eventCode.isEmpty ?? true)
    XCTAssertEqual(runtime.captures.first?.enin, 7)
    XCTAssertEqual(runtime.captures.first?.peerRpids, expectedPeerRpids)
    XCTAssertEqual(runtime.captures.first?.reporterRpid, reporterRpid)
    XCTAssertGreaterThanOrEqual(runtime.submitPendingCallCount, 4)
  }

  func testLegacyCountOnlyWindowPassesNoReporterRpidToSubmissionBoundary() {
    let runtime = ReportSubmissionRuntimeSpy()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      reportSubmissionRuntime: runtime
    )
    coordinator.useDemoEventMode = false
    coordinator.startSensing(eventCode: "TEST-REPORT-SUBMISSION-LEGACY")

    for index in 0..<BeidConfig.eventConfirmThreshold {
      coordinator.handleDetection(
        enin: 3,
        rpid: "peer-\(index)",
        detectedDisplayId: DetectionFixture.displayId(device: index)
      )
    }
    coordinator.reset()

    XCTAssertEqual(runtime.captures.count, 1)
    XCTAssertNil(runtime.captures.first?.reporterRpid)
  }
}
