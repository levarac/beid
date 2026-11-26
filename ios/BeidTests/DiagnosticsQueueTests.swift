// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import Beid

final class DiagnosticsQueueTests: XCTestCase {
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  private let firstCode = "11111111-1111-4111-8111-111111111111." + String(repeating: "ab", count: 32)
  private let secondCode = "22222222-2222-4222-8222-222222222222." + String(repeating: "cd", count: 32)
  private let identity = "01" + String(repeating: "ef", count: 16)

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  func testFreshInstallStartsWithConsentOff() {
    let queue = DiagnosticsQueue(directory: directory)

    XCTAssertFalse(queue.isEnabled, "A fresh install must require explicit consent")
    queue.record(.lifecycle(.foreground))
    XCTAssertNil(queue.nextBatch())
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  @MainActor
  func testConsentOffAndSynchronousRevocationBeforeDispatchNeverCallUpload() async throws {
    let queue = DiagnosticsQueue(directory: directory)
    let uploadCalled = expectation(description: "Upload called without current consent")
    uploadCalled.isInverted = true
    let controller = DiagnosticsController(queue: queue) { _ in
      uploadCalled.fulfill()
      return 202
    }
    controller.setForeground(true)
    controller.record(.lifecycle(.foreground))
    controller.flush()
    try controller.enable(code: firstCode)
    controller.record(.lifecycle(.background))
    controller.flush()
    try controller.revoke()
    await fulfillment(of: [uploadCalled], timeout: 0.05)
    XCTAssertFalse(controller.isEnabled)
    XCTAssertNil(queue.nextBatch())
  }

  @MainActor
  func testOfflineRevocationCancelsInFlightUploadAndCannotTouchNewConsent() async throws {
    let queue = DiagnosticsQueue(directory: directory)
    let uploadStarted = expectation(description: "Offline upload began")
    let uploadCancelled = expectation(description: "In-flight upload task cancelled")
    let controller = DiagnosticsController(queue: queue) { _ in
      uploadStarted.fulfill()
      do {
        try await Task.sleep(for: .seconds(30))
        return 202
      } catch {
        uploadCancelled.fulfill()
        throw error
      }
    }
    try controller.enable(code: firstCode)
    controller.record(.lifecycle(.foreground))
    controller.flush()
    await fulfillment(of: [uploadStarted], timeout: 1)

    try controller.revoke()
    try controller.enable(code: firstCode)
    controller.record(.lifecycle(.foreground))
    let reopted = try XCTUnwrap(queue.nextBatch())
    await fulfillment(of: [uploadCancelled], timeout: 1)
    XCTAssertEqual(queue.nextBatch(), reopted)
    try controller.revoke()
  }

  func testOfflineRevocationErasesQueueAndIdentityAcrossRestartAndReoptIn() throws {
    let queue = DiagnosticsQueue(directory: directory)
    try queue.enable(code: firstCode)
    queue.record(.lifecycle(.foreground))
    let old = try XCTUnwrap(queue.nextBatch())

    try queue.revoke()
    XCTAssertFalse(queue.isEnabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

    let restarted = DiagnosticsQueue(directory: directory)
    XCTAssertFalse(restarted.isEnabled)
    XCTAssertNil(restarted.nextBatch())
    try restarted.enable(code: firstCode)
    XCTAssertNil(restarted.nextBatch())
    restarted.record(.lifecycle(.foreground))
    let new = try XCTUnwrap(restarted.nextBatch())
    XCTAssertNotEqual(try json(old)["debug_id"] as? String, try json(new)["debug_id"] as? String)
    XCTAssertNotEqual(old.id, new.id)
  }

  func testRevocationKeepsConsentOffAfterRestartWhenConsentFileCannotBeRemoved() throws {
    let fileManager = ConsentRemovalFailure()
    let queue = DiagnosticsQueue(directory: directory, fileManager: fileManager)
    try queue.enable(code: firstCode)
    queue.record(.lifecycle(.foreground))
    let oldBatch = try XCTUnwrap(queue.nextBatch())

    fileManager.failConsentRemoval = true
    XCTAssertThrowsError(try queue.revoke())
    XCTAssertFalse(queue.isEnabled)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("consent.json").path))

    let restarted = DiagnosticsQueue(directory: directory)
    XCTAssertFalse(restarted.isEnabled, "A cleanup error must not restore the revoked consent")
    XCTAssertNil(restarted.nextBatch(), "The previous trial's queued batch must stay offline")

    try restarted.enable(code: firstCode)
    XCTAssertNil(restarted.nextBatch())
    restarted.record(.lifecycle(.foreground))
    let newBatch = try XCTUnwrap(restarted.nextBatch())
    XCTAssertNotEqual(try json(oldBatch)["debug_id"] as? String, try json(newBatch)["debug_id"] as? String)
  }

  func testPendingBatchBytesAndSequenceSurviveRestart() throws {
    let queue = DiagnosticsQueue(directory: directory)
    try queue.enable(code: firstCode)
    queue.record(.lifecycle(.foreground))
    let first = try XCTUnwrap(queue.nextBatch())

    let restarted = DiagnosticsQueue(directory: directory)
    XCTAssertTrue(restarted.isEnabled)
    let retry = try XCTUnwrap(restarted.nextBatch())
    XCTAssertEqual(first, retry)
    restarted.removeBatch(first.id)
    restarted.record(.lifecycle(.background))
    let next = try XCTUnwrap(restarted.nextBatch())
    XCTAssertEqual(try events(next).first?["seq"] as? Int, 2)
  }

  func testBatchByteLimitQueueCapacityAndAgeEvictOldest() throws {
    var now: Int64 = 1_795_676_400_000
    let queue = DiagnosticsQueue(
      directory: directory, batchByteLimit: 800, queueByteLimit: 1600, maxAgeMilliseconds: 100,
      clock: { DiagnosticsTimestamp(wall: now, monotonic: now) }
    )
    try queue.enable(code: firstCode)
    for _ in 0..<24 {
      queue.record(.peerDetected(rpid: identity, rssi: -61))
    }
    var delivered: [Int] = []
    var discarded = 0
    var totalBytes = 0
    while let batch = queue.nextBatch() {
      XCTAssertLessThanOrEqual(batch.body.count, 800)
      totalBytes += batch.body.count
      delivered += try events(batch).compactMap { $0["seq"] as? Int }
      discarded += try XCTUnwrap(json(batch)["dropped_events"] as? Int)
      queue.removeBatch(batch.id)
    }
    XCTAssertLessThanOrEqual(totalBytes, 1600)
    XCTAssertEqual(delivered.last, 24)
    XCTAssertGreaterThan(delivered.first ?? 0, 1)
    XCTAssertGreaterThan(discarded, 0)

    queue.record(.lifecycle(.foreground))
    XCTAssertNotNil(queue.nextBatch())
    now += 100
    XCTAssertNil(queue.nextBatch())
  }

  func testSyntheticIdentifiersUseOnlyTrialScopedCanonicalAliases() throws {
    let queue = DiagnosticsQueue(directory: directory)
    try queue.enable(code: firstCode)
    queue.record(.peerDetected(rpid: identity, rssi: -64))
    queue.record(.rssiUpdated(rpid: identity.uppercased(), rssi: -63))
    queue.record(.peerDetected(rpid: "02" + String(repeating: "ef", count: 16), rssi: -62))
    let batch = try XCTUnwrap(queue.nextBatch())
    let firstEvents = try events(batch)
    XCTAssertEqual(firstEvents.count, 2)
    let alias = try XCTUnwrap(firstEvents.first?["peer_alias"] as? String)
    XCTAssertEqual(alias, "5d0730aa54e013e68ec85926e34b222f6596e9d88b249cfa2c61a9aea149c30b")
    XCTAssertEqual(alias, firstEvents.last?["peer_alias"] as? String)
    XCTAssertEqual(firstEvents.first?["alias_kind"] as? String, "b002_rpid_v1")
    let wire = String(decoding: batch.body, as: UTF8.self)
    XCTAssertFalse(wire.contains(identity))
    XCTAssertFalse(wire.contains(String(firstCode.split(separator: ".")[1])))

    try queue.revoke()
    try queue.enable(code: secondCode)
    queue.record(.peerDetected(rpid: identity, rssi: -64))
    let otherBatch = try XCTUnwrap(queue.nextBatch())
    XCTAssertNotEqual(alias, try events(otherBatch).first?["peer_alias"] as? String)
  }

  @MainActor
  func testSharedFixtureAndRadarTransitionsUseObservedAliasOnly() throws {
    let queue = DiagnosticsQueue(directory: directory)
    let controller = DiagnosticsController(queue: queue, upload: nil)
    let key = (0...31).map { String(format: "%02x", $0) }.joined()
    let rpid = "01" + (240...255).map { String(format: "%02x", $0) }.joined()
    let displayID = "synthetic-stable-display-id"
    controller.setForeground(true)
    try controller.enable(code: "11111111-1111-4111-8111-111111111111." + key)
    controller.recordRadarProjection(from: [], to: ["unresolved"])
    controller.recordLastDetection(
      displayID: displayID, rpid: rpid, timestamp: Date(timeIntervalSince1970: 1_795_676_401),
      reason: .detection
    )
    controller.recordRadarProjection(from: [], to: [displayID])
    controller.recordRadarProjection(from: [displayID], to: [displayID])
    controller.recordRadarProjection(from: [displayID], to: [])

    let batch = try XCTUnwrap(queue.nextBatch())
    let wireEvents = try events(batch)
    XCTAssertEqual(wireEvents.compactMap { $0["kind"] as? String }, [
      "last_detection_updated", "radar_peer_rendered", "radar_peer_removed"
    ])
    XCTAssertEqual(wireEvents.first?["last_seen_ms"] as? Int64, 1_795_676_401_000)
    XCTAssertEqual(Set(wireEvents.compactMap { $0["peer_alias"] as? String }), [
      "2c4fa415c500b5fd66ae13a75e9efa13291453df3bb9bcd4331c670c78c47055"
    ])
    let body = String(decoding: batch.body, as: UTF8.self)
    XCTAssertFalse(body.contains(displayID))
    XCTAssertFalse(body.contains(rpid))
    XCTAssertFalse(body.contains(key))
    try controller.revoke()
  }

  func testStrictEnvelopeAndClockJumpStartsNewBatch() throws {
    var now = DiagnosticsTimestamp(wall: 1_795_676_400_000, monotonic: 9_000)
    let queue = DiagnosticsQueue(directory: directory, clock: { now })
    try queue.enable(code: firstCode)
    queue.record(.lifecycle(.foreground))
    now = DiagnosticsTimestamp(wall: now.wall + 3_000, monotonic: now.monotonic + 100)
    queue.record(.lifecycle(.background))

    let first = try XCTUnwrap(queue.nextBatch())
    queue.removeBatch(first.id)
    let second = try XCTUnwrap(queue.nextBatch())
    let envelope = try json(first)
    XCTAssertEqual(Set(envelope.keys), [
      "v", "run_id", "debug_id", "batch_id", "model", "os_version", "app_build",
      "source_sha", "clock_sync", "dropped_events", "events"
    ])
    XCTAssertTrue(envelope["source_sha"] is NSNull)
    let clock = try XCTUnwrap(envelope["clock_sync"] as? [String: Any])
    XCTAssertEqual(Set(clock.keys), ["wall_ms", "monotonic_ms", "offset_ms", "uncertainty_ms"])
    XCTAssertTrue(clock["offset_ms"] is NSNull)
    XCTAssertTrue(clock["uncertainty_ms"] is NSNull)
    XCTAssertEqual(try events(first).map { $0["kind"] as? String }, ["foreground"])
    XCTAssertEqual(try events(second).map { $0["kind"] as? String }, ["background"])
  }

  func testClockCorrectionStartsNewBatchAndExpiresAfterClockJump() throws {
    var now = DiagnosticsTimestamp(wall: 1_795_676_400_000, monotonic: 9_000)
    let queue = DiagnosticsQueue(directory: directory, clock: { now })
    try queue.enable(code: firstCode)
    queue.record(.lifecycle(.foreground))
    queue.setClockCorrection(DiagnosticsClockCorrection(sampledAt: now, offset: -19, uncertainty: 5))
    now = DiagnosticsTimestamp(wall: now.wall + 500, monotonic: now.monotonic + 500)
    queue.record(.lifecycle(.background))
    now = DiagnosticsTimestamp(wall: now.wall + 4_000, monotonic: now.monotonic + 1_000)
    queue.record(.lifecycle(.foreground))

    let uncorrected = try XCTUnwrap(queue.nextBatch())
    queue.removeBatch(uncorrected.id)
    let corrected = try XCTUnwrap(queue.nextBatch())
    queue.removeBatch(corrected.id)
    let afterJump = try XCTUnwrap(queue.nextBatch())
    let measured = try XCTUnwrap(json(corrected)["clock_sync"] as? [String: Any])
    let unavailable = try XCTUnwrap(json(afterJump)["clock_sync"] as? [String: Any])
    XCTAssertEqual(measured["offset_ms"] as? Int, -19)
    XCTAssertEqual(measured["uncertainty_ms"] as? Int, 5)
    XCTAssertTrue(unavailable["offset_ms"] is NSNull)
    XCTAssertTrue(unavailable["uncertainty_ms"] is NSNull)
  }

  private func json(_ batch: DiagnosticsQueuedBatch) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: batch.body) as? [String: Any])
  }

  private func events(_ batch: DiagnosticsQueuedBatch) throws -> [[String: Any]] {
    try XCTUnwrap(json(batch)["events"] as? [[String: Any]])
  }
}

private final class ConsentRemovalFailure: FileManager, @unchecked Sendable {
  var failConsentRemoval = false

  override func removeItem(at url: URL) throws {
    if failConsentRemoval && url.lastPathComponent == "consent.json" {
      throw CocoaError(.fileWriteNoPermission)
    }
    try super.removeItem(at: url)
  }
}
