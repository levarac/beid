// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import Beid

@MainActor
final class ManualReportSubmissionRetryScheduler: ReportSubmissionRetryScheduler {
  final class Entry: ReportSubmissionRetryCancellation {
    let deadline: TimeInterval
    let action: @MainActor () -> Void
    private(set) var cancelled = false

    init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
      self.deadline = deadline
      self.action = action
    }

    func cancel() { cancelled = true }
  }

  var now: TimeInterval = 0
  private(set) var entries: [Entry] = []
  var onSchedule: (() -> Void)?

  func schedule(
    after delay: TimeInterval,
    action: @escaping @MainActor () -> Void
  ) -> any ReportSubmissionRetryCancellation {
    let entry = Entry(deadline: now + delay, action: action)
    entries.append(entry)
    onSchedule?()
    return entry
  }

  func advance(by duration: TimeInterval) {
    now += duration
    for entry in entries where !entry.cancelled && entry.deadline <= now {
      entry.cancel()
      entry.action()
    }
  }
}

@MainActor
final class ReportSubmissionRetryTests: XCTestCase {
  func testExponentialBackoffIsCappedAndStopsAfterSixAttempts() {
    let scheduler = ManualReportSubmissionRetryScheduler()
    let controller = ReportSubmissionRetryController(scheduler: scheduler, now: { scheduler.now })
    let id = UUID()
    var retryCount = 0
    XCTAssertTrue(controller.beginAttempt(for: id))

    for delay in [2.0, 4.0, 8.0, 8.0, 8.0] {
      controller.retry(for: id) { retryCount += 1 }
      XCTAssertEqual(scheduler.entries.last?.deadline, scheduler.now + delay)
      XCTAssertFalse(controller.beginAttempt(for: id), "app events must respect the retry deadline")
      scheduler.advance(by: delay - 0.5)
      XCTAssertEqual(retryCount, scheduler.entries.count - 1)
      scheduler.advance(by: 0.5)
      XCTAssertTrue(controller.beginAttempt(for: id))
    }
    controller.retry(for: id) { retryCount += 1 }
    XCTAssertEqual(retryCount, 5)
    XCTAssertEqual(scheduler.entries.count, 5)
    XCTAssertFalse(controller.beginAttempt(for: id), "the pending capture has exhausted its attempt budget")
  }

  func testEventTriggeredAttemptInvalidatesAnAlreadyQueuedTimerCallback() {
    let scheduler = ManualReportSubmissionRetryScheduler()
    let controller = ReportSubmissionRetryController(scheduler: scheduler, now: { scheduler.now })
    let id = UUID()
    var callbacks = 0
    XCTAssertTrue(controller.beginAttempt(for: id))
    controller.retry(for: id) { callbacks += 1 }

    scheduler.now = 2
    XCTAssertTrue(controller.beginAttempt(for: id))
    XCTAssertTrue(scheduler.entries[0].cancelled)
    scheduler.entries[0].action()
    XCTAssertEqual(callbacks, 0, "a cancelled timer may already be queued on the main actor")
  }

  func testEarlyTimerPreservesTheDeadlineWithoutConsumingAnotherAttempt() {
    let scheduler = ManualReportSubmissionRetryScheduler()
    let controller = ReportSubmissionRetryController(scheduler: scheduler, now: { scheduler.now })
    let id = UUID()
    var callbacks = 0
    XCTAssertTrue(controller.beginAttempt(for: id))
    controller.retry(for: id) { callbacks += 1 }

    scheduler.now = 1
    scheduler.entries[0].action()
    XCTAssertTrue(scheduler.entries[0].cancelled)
    XCTAssertEqual(scheduler.entries[1].deadline, 2)
    XCTAssertEqual(callbacks, 0)
    scheduler.advance(by: 1)
    XCTAssertEqual(callbacks, 1)
    XCTAssertTrue(controller.beginAttempt(for: id))
    controller.retry(for: id) { callbacks += 1 }
    XCTAssertEqual(scheduler.entries.last?.deadline, 6)
  }

  func testStopCancelsTimersAndIgnoresLateCallbacksAndFailures() {
    let scheduler = ManualReportSubmissionRetryScheduler()
    let controller = ReportSubmissionRetryController(scheduler: scheduler, now: { scheduler.now })
    let id = UUID()
    var callbacks = 0
    XCTAssertTrue(controller.beginAttempt(for: id))
    controller.retry(for: id) { callbacks += 1 }
    controller.stop()
    controller.retry(for: id) { callbacks += 1 }

    XCTAssertTrue(scheduler.entries[0].cancelled)
    scheduler.now = 2
    scheduler.entries[0].action()
    XCTAssertEqual(callbacks, 0)
    XCTAssertEqual(scheduler.entries.count, 1)
    XCTAssertFalse(controller.beginAttempt(for: id))
  }

  func testAttemptBudgetsAreIndependentForEachPendingCapture() {
    let scheduler = ManualReportSubmissionRetryScheduler()
    let controller = ReportSubmissionRetryController(scheduler: scheduler, now: { scheduler.now })
    let first = UUID()
    let second = UUID()
    for _ in 0..<6 { XCTAssertTrue(controller.beginAttempt(for: first)) }
    XCTAssertFalse(controller.beginAttempt(for: first))
    XCTAssertTrue(controller.beginAttempt(for: second))
    controller.retry(for: second) {}
    XCTAssertEqual(scheduler.entries.last?.deadline, 2)
  }

  func testFinishingACaptureCancelsItsScheduledCallback() {
    let scheduler = ManualReportSubmissionRetryScheduler()
    let controller = ReportSubmissionRetryController(scheduler: scheduler, now: { scheduler.now })
    let id = UUID()
    var callbacks = 0
    XCTAssertTrue(controller.beginAttempt(for: id))
    controller.retry(for: id) { callbacks += 1 }
    controller.finish(id)
    scheduler.now = 2
    scheduler.entries[0].action()
    XCTAssertTrue(scheduler.entries[0].cancelled)
    XCTAssertEqual(callbacks, 0)
  }

  func testReleasingTheControllerCancelsTimersWithoutARetainCycle() {
    let scheduler = ManualReportSubmissionRetryScheduler()
    var controller: ReportSubmissionRetryController? = ReportSubmissionRetryController(
      scheduler: scheduler, now: { scheduler.now }
    )
    weak var releasedController = controller
    let id = UUID()
    var callbacks = 0
    XCTAssertEqual(controller?.beginAttempt(for: id), true)
    controller?.retry(for: id) { callbacks += 1 }
    controller = nil
    XCTAssertNil(releasedController)
    XCTAssertTrue(scheduler.entries[0].cancelled)
    scheduler.now = 2
    scheduler.entries[0].action()
    XCTAssertEqual(callbacks, 0)
  }
}

/// Proves `ReportSubmissionRuntime.submissionState(forEventCode:)` — the
/// query beid#292's Transparency screen uses for its "Sent" and "Acceptance
/// receipt" rows — reads real, durable `ReportSubmissionStore` state rather
/// than returning a constant. Seeds a record through the store's own
/// state-machine API (`add` -> `markSubmitting` -> `storeReceipt`), not by
/// constructing `.accepted` directly, and asserts the runtime built on top
/// of that same file reports it correctly and only for the matching event
/// code.
@MainActor
final class ReportSubmissionStateQueryTests: XCTestCase {
  func testCountOnlyCaptureIsDurableScopedAndDoesNotCreateSubmissionWork() throws {
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-exclusion-query")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let runtime = try XCTUnwrap(makeEnabledRuntime(fileURL: fileURL, provider: NeverInvokedEventDefinitionContextProvider()))

    runtime.captureAndQueueWindow(
      id: UUID(),
      eventCode: "EVENTA",
      eventIdHex: nil,
      enin: 7,
      peerRpids: ["peer-a", "peer-b"],
      reporterRpid: nil,
      participantCommitment: nil
    )

    XCTAssertEqual(runtime.excludedWindowCount(forEventCode: "EVENTA"), 1)
    XCTAssertEqual(runtime.excludedWindowCount(forEventCode: "EVENTB"), 0)
    let reloaded = ReportSubmissionStore(fileURL: fileURL)
    XCTAssertEqual(reloaded.exclusions.first?.peerCount, 2)
    XCTAssertEqual(reloaded.exclusions.first?.reasonCode, "legacy-count-only")
    XCTAssertTrue(reloaded.pendingCaptures.isEmpty)
    XCTAssertTrue(reloaded.records.isEmpty)
  }

  func testCountOnlyCaptureStillRetriesPreviouslyPendingCaptures() throws {
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-exclusion-retry")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let store = ReportSubmissionStore(fileURL: fileURL)
    try store.addPendingCapture(
      ReportSubmissionCapture(
        id: UUID(),
        eventCode: "EARLIER",
        eventIdHex: String(repeating: "11", count: 32),
        enin: 6,
        peerRpids: ["peer"],
        reporterRpid: "reporter",
        participantCommitment: nil
      )
    )
    let provider = CountingEventDefinitionContextProvider()
    let runtime = try XCTUnwrap(makeEnabledRuntime(fileURL: fileURL, provider: provider))

    runtime.captureAndQueueWindow(
      id: UUID(),
      eventCode: "COUNT-ONLY",
      eventIdHex: nil,
      enin: 7,
      peerRpids: ["peer"],
      reporterRpid: nil,
      participantCommitment: nil
    )

    XCTAssertEqual(provider.resolveCallCount, 1)
  }

  func testSubmissionStateReflectsRealStoredAcceptanceAndIsScopedByEventCode() throws {
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-query")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")

    let seedStore = ReportSubmissionStore(fileURL: fileURL)
    let record = makeRecord(eventCode: "EVENTA")
    try seedStore.add(record)
    try seedStore.markSubmitting(for: record.id)
    try seedStore.storeReceipt(
      for: record.id,
      signedReceiptHex: String(repeating: "ab", count: 24)
    )

    let runtime = try XCTUnwrap(
      makeEnabledRuntime(fileURL: fileURL, provider: NeverInvokedEventDefinitionContextProvider()),
      "expected an enabled ReportSubmissionRuntime for this test bundle"
    )

    XCTAssertEqual(runtime.submissionState(forEventCode: "EVENTA"), .accepted)
    XCTAssertNil(
      runtime.submissionState(forEventCode: "EVENTB"),
      "a different event code with no records must not read the seeded event's state"
    )
  }

  func testSubmissionStateReportsSubmittingBeforeAReceiptExists() throws {
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-query-submitting")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")

    let seedStore = ReportSubmissionStore(fileURL: fileURL)
    let record = makeRecord(eventCode: "EVENTA")
    try seedStore.add(record)
    try seedStore.markSubmitting(for: record.id)

    let runtime = try XCTUnwrap(makeEnabledRuntime(fileURL: fileURL, provider: NeverInvokedEventDefinitionContextProvider()))

    XCTAssertEqual(runtime.submissionState(forEventCode: "EVENTA"), .submitting)
  }

  private func makeEnabledRuntime(
    fileURL: URL,
    provider: any EventDefinitionContextProvider
  ) throws -> ReportSubmissionRuntime? {
    let bundleDirectory = try makeIsolatedDirectory(named: "beid-report-submission-query-bundle")
    let plist: [String: Any] = [
      "CFBundleIdentifier": "org.levarac.beid.tests.\(UUID().uuidString)",
      "CFBundlePackageType": "BNDL",
      "BeidReportSubmissionEnabled": "1"
    ]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try plistData.write(to: bundleDirectory.appendingPathComponent("Info.plist"))
    let bundle = try XCTUnwrap(Bundle(url: bundleDirectory))
    return ReportSubmissionRuntime.makeIfEnabled(
      bundle: bundle,
      eventSigningCryptography: NeverInvokedSensingCryptography(),
      definitionProvider: provider,
      fileURL: fileURL
    )
  }

  private func makeRecord(eventCode: String) -> ReportSubmissionRecord {
    ReportSubmissionRecord(
      id: UUID(),
      eventCode: eventCode,
      endpoint: "https://operator.example",
      receiptPublicKeyHex: "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5",
      eventIdHex: String(repeating: "11", count: 32),
      eventDefinitionDigestHex: String(repeating: "22", count: 32),
      validFrom: 1,
      validUntil: 2,
      signedObservationHex: "aabbcc",
      observationDigestHex: String(repeating: "33", count: 32),
      createdAt: Date(timeIntervalSince1970: 123)
    )
  }

  private func makeIsolatedDirectory(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

@MainActor
private final class CountingEventDefinitionContextProvider: EventDefinitionContextProvider {
  private(set) var resolveCallCount = 0

  func resolve(
    eventIdHex _: String,
    completion: @escaping (VerifiedSubmissionDefinition?) -> Void
  ) {
    resolveCallCount += 1
    completion(nil)
  }
}

/// Never expected to run any cryptographic operation — this test only
/// exercises the read-only `submissionState(forEventCode:)` query, never
/// `captureAndQueueWindow`/`submitPending`, so no signing call should ever
/// reach this stub.
private final class NeverInvokedSensingCryptography: SensingCryptography {
  func eventSigningPublicKey(eventCode: String) -> Data {
    XCTFail("not expected to be invoked by this test")
    return Data()
  }

  func ownerPublicKey() throws -> Data {
    XCTFail("not expected to be invoked by this test")
    return Data()
  }

  func signWindowReport(eventCode: String, bytes: Data) -> SensingRecoverableSignature {
    XCTFail("not expected to be invoked by this test")
    return SensingRecoverableSignature(r: Data(), s: Data(), v: 0)
  }

  func signSelfProof(
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64
  ) throws -> SensingRecoverableSignature? {
    XCTFail("not expected to be invoked by this test")
    return nil
  }

  func signWalletAcknowledgement(
    walletAddress: Data,
    walletSignature: Data
  ) throws -> SensingRecoverableSignature? {
    XCTFail("not expected to be invoked by this test")
    return nil
  }
}

/// Never expected to run — this test never calls `captureAndQueueWindow`, so
/// no registry resolution should ever reach this stub.
@MainActor
private final class NeverInvokedEventDefinitionContextProvider: EventDefinitionContextProvider {
  func resolve(
    eventIdHex: String,
    completion: @escaping (VerifiedSubmissionDefinition?) -> Void
  ) {
    XCTFail("not expected to be invoked by this test")
    completion(nil)
  }
}
