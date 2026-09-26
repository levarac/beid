// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import XCTest
@testable import Beid

/// beid#701 T2: `SensingCoordinator.closeWindow` writes exactly one link per
/// closed window, to the Proof of the session that owns the window, before
/// the capture is handed to the submission runtime — and a link failure
/// never costs the capture.
///
/// Driven through the real detection path, like
/// `ReportSubmissionWiringTests`. The join control never answers the
/// permission request, which is what the BLE-less Simulator does, so the
/// session runs from `startSensing`'s own state without a registry.
@MainActor
final class ReportProofLinkWiringTests: XCTestCase {
  private let eventCode = "TEST-REPORT-PROOF-LINK"
  private let reporterRpid = "01" + String(repeating: "aa", count: 16)

  private struct SessionDidNotRecord: Error {}

  private struct Fixture {
    let coordinator: SensingCoordinator
    let runtime: ReportProofLinkRuntimeSpy
    let linkStore: ReportProofLinkStore
    let linkFileURL: URL
  }

  private func makeFixture(
    linkFileURL: URL? = nil,
    withRuntime: Bool = true
  ) throws -> Fixture {
    let directory = try makeReportProofLinkTestDirectory(for: self, named: "beid-report-proof-link-wiring")
    let resolvedLinkURL = linkFileURL ?? directory.appendingPathComponent("report-proof-links.json")
    let linkStore = ReportProofLinkStore(fileURL: resolvedLinkURL)
    let runtime = ReportProofLinkRuntimeSpy()
    runtime.linkStoreObservedAtCapture = linkStore
    let coordinator = makeLinkedSensingCoordinator(
      directory: directory,
      reportSubmissionRuntime: withRuntime ? runtime as (any WindowReportSubmissionRuntimeProtocol) : nil,
      reportProofLinkStore: linkStore
    )
    coordinator.useDemoEventMode = false
    return Fixture(
      coordinator: coordinator,
      runtime: runtime,
      linkStore: linkStore,
      linkFileURL: resolvedLinkURL
    )
  }

  /// Starts a session and drives it to `.recording` in `enin`, returning the
  /// Proof id the coordinator holds while recording.
  private func startRecordingSession(
    _ coordinator: SensingCoordinator,
    enin: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UUID {
    coordinator.startSensing(eventCode: eventCode)
    for device in 0..<BeidConfig.eventConfirmThreshold {
      coordinator.handleDetection(
        enin: enin,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: enin),
        detectedDisplayId: DetectionFixture.displayId(device: device),
        reporterRpid: reporterRpid
      )
    }
    guard case .recording = coordinator.phase else {
      XCTFail("expected .recording, got \(coordinator.phase)", file: file, line: line)
      throw SessionDidNotRecord()
    }
    return try XCTUnwrap(coordinator.currentProofID, file: file, line: line)
  }

  private func assertLinked(
    _ capture: ReportProofLinkRuntimeSpy.Capture?,
    to proofId: UUID,
    in linkStore: ReportProofLinkStore,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let capture = try XCTUnwrap(capture, "no capture was forwarded", file: file, line: line)
    XCTAssertEqual(
      linkStore.proofId(forWindowId: capture.id),
      .success(proofId),
      "the closed window must link to the Proof of the session that owned it",
      file: file,
      line: line
    )
    XCTAssertEqual(
      capture.linkAtCapture,
      Result<UUID?, ReportProofLinkStore.ReadError>.success(proofId),
      "the link must already exist when the capture is handed to the runtime",
      file: file,
      line: line
    )
  }

  // MARK: - The three close triggers

  func testEninBoundaryCloseLinksTheWindowToTheRecordingProof() throws {
    let fixture = try makeFixture()
    let proofId = try startRecordingSession(fixture.coordinator, enin: 7)

    fixture.coordinator.handleDetection(
      enin: 8,
      rpid: DetectionFixture.rotatingRpid(device: 0, enin: 8),
      detectedDisplayId: DetectionFixture.displayId(device: 0),
      reporterRpid: reporterRpid
    )

    XCTAssertEqual(fixture.runtime.captures.count, 1, "the ENIN boundary closes exactly one window")
    XCTAssertEqual(fixture.runtime.captures.first?.enin, 7)
    try assertLinked(fixture.runtime.captures.first, to: proofId, in: fixture.linkStore)
    XCTAssertEqual(fixture.linkStore.links.count, 1)
  }

  func testBackgroundCheckpointCloseLinksTheWindowToTheRecordingProof() throws {
    let fixture = try makeFixture()
    let proofId = try startRecordingSession(fixture.coordinator, enin: 7)

    fixture.coordinator.checkpointOpenWindowForBackgrounding()

    XCTAssertEqual(fixture.runtime.captures.count, 1)
    try assertLinked(fixture.runtime.captures.first, to: proofId, in: fixture.linkStore)
    XCTAssertEqual(fixture.linkStore.links.count, 1)
  }

  func testStopSensingCloseLinksTheWindowToTheRecordingProof() throws {
    let fixture = try makeFixture()
    let proofId = try startRecordingSession(fixture.coordinator, enin: 7)

    _ = fixture.coordinator.stopSensing()

    XCTAssertEqual(fixture.runtime.captures.count, 1)
    try assertLinked(fixture.runtime.captures.first, to: proofId, in: fixture.linkStore)
    XCTAssertEqual(fixture.linkStore.links.count, 1)
  }

  // MARK: - Session identity is the Proof, never the event code or ENIN

  func testTwoSessionsWithTheSameEventCodeAndEninLinkToTheirOwnProofs() throws {
    let fixture = try makeFixture()

    let firstProofId = try startRecordingSession(fixture.coordinator, enin: 7)
    _ = fixture.coordinator.stopSensing()
    let secondProofId = try startRecordingSession(fixture.coordinator, enin: 7)
    _ = fixture.coordinator.stopSensing()

    XCTAssertNotEqual(firstProofId, secondProofId, "each session must have its own Proof")
    XCTAssertEqual(fixture.runtime.captures.count, 2)
    XCTAssertEqual(fixture.runtime.captures.map(\.enin), [7, 7])
    XCTAssertEqual(fixture.runtime.captures.map(\.eventCode), [eventCode, eventCode])
    try assertLinked(fixture.runtime.captures.first, to: firstProofId, in: fixture.linkStore)
    try assertLinked(fixture.runtime.captures.last, to: secondProofId, in: fixture.linkStore)
    XCTAssertEqual(
      fixture.linkStore.windowIds(forProofId: firstProofId),
      .success([fixture.runtime.captures[0].id])
    )
    XCTAssertEqual(
      fixture.linkStore.windowIds(forProofId: secondProofId),
      .success([fixture.runtime.captures[1].id])
    )
  }

  // MARK: - Nothing is written without a report to join

  func testNoSubmissionRuntimeWritesNoLinks() throws {
    let fixture = try makeFixture(withRuntime: false)
    _ = try startRecordingSession(fixture.coordinator, enin: 7)

    fixture.coordinator.handleDetection(
      enin: 8,
      rpid: DetectionFixture.rotatingRpid(device: 0, enin: 8),
      detectedDisplayId: DetectionFixture.displayId(device: 0),
      reporterRpid: reporterRpid
    )
    fixture.coordinator.checkpointOpenWindowForBackgrounding()
    _ = fixture.coordinator.stopSensing()

    XCTAssertEqual(fixture.linkStore.links, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linkFileURL.path))
  }

  func testSessionThatNeverRecordsWritesNoLinkAndNoCapture() throws {
    let fixture = try makeFixture()
    fixture.coordinator.startSensing(eventCode: eventCode)
    for device in 0..<(BeidConfig.eventConfirmThreshold - 1) {
      fixture.coordinator.handleDetection(
        enin: 7,
        rpid: DetectionFixture.rotatingRpid(device: device, enin: 7),
        detectedDisplayId: DetectionFixture.displayId(device: device),
        reporterRpid: reporterRpid
      )
    }
    if case .recording = fixture.coordinator.phase {
      XCTFail("below the confirm threshold the session must not record")
    }
    XCTAssertNil(fixture.coordinator.currentProofID)

    fixture.coordinator.checkpointOpenWindowForBackgrounding()
    _ = fixture.coordinator.stopSensing()

    XCTAssertTrue(fixture.runtime.captures.isEmpty)
    XCTAssertEqual(fixture.linkStore.links, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linkFileURL.path))
  }

  // MARK: - A link failure never costs the capture

  func testLinkWriteFailureStillForwardsTheCaptureOnceAndLeavesNoLink() throws {
    // A regular file where the link file's directory should be makes every
    // write fail at `createDirectory`, the way a full or broken volume would.
    let directory = try makeReportProofLinkTestDirectory(for: self, named: "beid-report-proof-link-blocked")
    let blocker = directory.appendingPathComponent("blocked")
    try Data("not a directory".utf8).write(to: blocker)
    let fixture = try makeFixture(linkFileURL: blocker.appendingPathComponent("report-proof-links.json"))
    _ = try startRecordingSession(fixture.coordinator, enin: 7)

    _ = fixture.coordinator.stopSensing()

    XCTAssertEqual(fixture.runtime.captures.count, 1, "a failed link write must not suppress or repeat the capture")
    let capture = try XCTUnwrap(fixture.runtime.captures.first)
    XCTAssertEqual(fixture.linkStore.proofId(forWindowId: capture.id), .success(nil))
    XCTAssertEqual(fixture.linkStore.links, [])
  }

  func testUnreadableLinkFileStillForwardsTheCaptureOnceAndIsLeftUntouched() throws {
    let directory = try makeReportProofLinkTestDirectory(for: self, named: "beid-report-proof-link-unreadable")
    let linkFileURL = directory.appendingPathComponent("report-proof-links.json")
    let unreadable = Data("not json".utf8)
    try unreadable.write(to: linkFileURL)
    let fixture = try makeFixture(linkFileURL: linkFileURL)
    _ = try startRecordingSession(fixture.coordinator, enin: 7)

    _ = fixture.coordinator.stopSensing()

    XCTAssertEqual(fixture.runtime.captures.count, 1)
    let capture = try XCTUnwrap(fixture.runtime.captures.first)
    XCTAssertEqual(fixture.linkStore.proofId(forWindowId: capture.id), .failure(.unreadable))
    XCTAssertEqual(try Data(contentsOf: linkFileURL), unreadable)
  }
}
