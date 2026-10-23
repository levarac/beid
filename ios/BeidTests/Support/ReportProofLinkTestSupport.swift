// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation
import XCTest
@testable import Beid

/// Same shape as `makeIsolatedSensingCoordinator`, over a caller-owned
/// directory and with a `ReportProofLinkStore` injected (beid#701). The
/// directory is returned by the caller's own choice so a test can read every
/// file the session wrote beside the link file.
@MainActor
func makeLinkedSensingCoordinator(
  directory: URL,
  sensingCryptography: any SensingCryptography = DeterministicSensingCryptography(),
  reportSubmissionRuntime: (any WindowReportSubmissionRuntimeProtocol)?,
  reportProofLinkStore: ReportProofLinkStore?,
  eventJoinControl: (any EventJoinControlling)? = RecordingEventJoinControl(),
  eventJoinRegistry: (any EventJoinRegistry)? = nil
) -> SensingCoordinator {
  SensingCoordinator(
    windowReportStore: WindowReportStore(
      fileURL: directory.appendingPathComponent("window-reports.json")
    ),
    selfProofStore: SelfProofStore(
      fileURL: directory.appendingPathComponent("self-proofs.json")
    ),
    selfProofCheckpointStore: SelfProofCheckpointStore(
      fileURL: directory.appendingPathComponent("self-proof-checkpoint.json")
    ),
    bindingRecordStore: BindingRecordStore(
      fileURL: directory.appendingPathComponent("binding-records.json")
    ),
    sessionAggregateSnapshotStore: SessionAggregateSnapshotStore(
      fileURL: directory.appendingPathComponent("session-aggregate-snapshots.json")
    ),
    unsentWindowLedgerFileURL: directory.appendingPathComponent("ledger.snapshot"),
    sensingCryptography: sensingCryptography,
    reportSubmissionRuntime: reportSubmissionRuntime,
    reportProofLinkStore: reportProofLinkStore,
    eventJoinControl: eventJoinControl,
    eventJoinRegistry: eventJoinRegistry
  )
}

/// Creates an isolated directory removed when `testCase` tears down.
func makeReportProofLinkTestDirectory(for testCase: XCTestCase, named name: String) throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  testCase.addTeardownBlock {
    try? FileManager.default.removeItem(at: directory)
  }
  return directory
}

/// `ReportSubmissionWiringTests`' spy shape (that one is `private` to its
/// file), plus what the link store answered for the window at the instant
/// the capture was handed over. That second value is what pins the order
/// "link first, then capture": a link written after the capture reads as
/// `nil` here even though it exists by the time the test looks.
@MainActor
final class ReportProofLinkRuntimeSpy: WindowReportSubmissionRuntimeProtocol {
  struct Capture {
    let id: UUID
    let eventCode: String
    let enin: Int
    let linkAtCapture: Result<UUID?, ReportProofLinkStore.ReadError>?
  }

  private(set) var captures: [Capture] = []
  private(set) var submitPendingCallCount = 0
  /// Read at capture time. `nil` records no link observation.
  var linkStoreObservedAtCapture: ReportProofLinkStore?

  func captureAndQueueWindow(
    id: UUID,
    eventCode: String,
    eventIdHex: String?,
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
        linkAtCapture: linkStoreObservedAtCapture?.proofId(forWindowId: id)
      )
    )
  }

  func submitPending() {
    submitPendingCallCount += 1
  }

  func submissionState(forEventCode eventCode: String) -> ReportSubmissionState? { nil }

  func excludedWindowCount(forEventCode eventCode: String) -> Int { 0 }
}
