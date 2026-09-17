// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#if DEBUG
import Foundation
import XCTest
@testable import Beid

/// Records the deadline it was handed and fires only when a test says so, so
/// expiry is reached without sleeping and without the test depending on real
/// elapsed time.
@MainActor
final class FakeVenueExpiryScheduler: VenueExpiryScheduling {
  private(set) var scheduledStopAt: Int64?
  private(set) var scheduledNow: Int64?
  private(set) var cancelCount = 0
  private var pending: (@MainActor () async -> Void)?

  var isScheduled: Bool { pending != nil }

  func schedule(stopAtUnixSeconds: Int64, now: Int64, fire: @escaping @MainActor () async -> Void) {
    scheduledStopAt = stopAtUnixSeconds
    scheduledNow = now
    pending = fire
  }

  func cancel() {
    cancelCount += 1
    pending = nil
  }

  /// Fires the pending deadline. Fails rather than silently doing nothing if
  /// nothing was scheduled, so a test cannot pass by never arming a timer.
  func fire(file: StaticString = #filePath, line: UInt = #line) {
    guard let pending else {
      XCTFail("fired an expiry timer that was never scheduled", file: file, line: line)
      return
    }
    self.pending = nil
    Task { await pending() }
  }

  /// Takes a queued callback independently of cancel, to model delivery races.
  func takeQueuedFire() -> (@MainActor () async -> Void)? {
    defer { pending = nil }
    return pending
  }

  /// Acknowledges the entire async handler, including a no-effect failure.
  func fireAndWait(file: StaticString = #filePath, line: UInt = #line) async {
    guard let fire = takeQueuedFire() else {
      XCTFail("fired an expiry timer that was never scheduled", file: file, line: line)
      return
    }
    await fire()
  }
}

/// Supplies acquisition results without touching the filesystem or network.
/// An unscripted call fails the test rather than inventing an artifact,
/// matching `ScriptedVenuePorts`' rule.
@MainActor
final class StubVenueArtifactAcquisition: VenueArtifactAcquiring {
  enum Reply {
    case artifact(VenuePublicArtifact)
    case failure(VenueAcquisitionFailure)
    /// Leaves the acquisition suspended until the test resolves it.
    ///
    /// A real fetch takes time, and things happen to the app during it — the
    /// operator backgrounds it, the scene lifecycle fires, the generation
    /// moves. Without this the double resolves inside `supply`'s own `await`
    /// and no test can place ANY event between the request and its outcome,
    /// which made a whole family of mid-flight interleavings unreachable
    /// rather than merely untested. `ScriptedVenuePorts.Reply.deferred` exists
    /// for the same reason on the verification seam.
    case deferred
  }

  var replies: [Reply] = []
  private(set) var requestedSources: [(bundle: URL, handoff: URL?)] = []
  private var pending: [Int: CheckedContinuation<VenuePublicArtifact, Error>] = [:]
  private var nextRequestID = 0
  private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  var pendingAcquisitionIDs: [Int] { pending.keys.sorted() }

  /// The bundle-only request the link path makes. It draws from the same scripted
  /// `replies` queue and returns that reply's bundle half, so a test scripting a
  /// link supply and a test scripting the two-URL supply write the same thing.
  func acquireBundle(bundleSource: URL) async throws -> Data {
    try await acquire(bundleSource: bundleSource, handoffSource: nil).bundleBytes
  }

  func acquire(bundleSource: URL, handoffSource: URL) async throws -> VenuePublicArtifact {
    try await acquire(bundleSource: bundleSource, handoffSource: Optional(handoffSource))
  }

  private func acquire(bundleSource: URL, handoffSource: URL?) async throws -> VenuePublicArtifact {
    let id = nextRequestID
    nextRequestID += 1
    requestedSources.append((bundleSource, handoffSource))
    let ready = observers.filter { $0.count <= requestedSources.count }
    observers.removeAll { $0.count <= requestedSources.count }
    for observer in ready { observer.continuation.resume() }
    guard !replies.isEmpty else {
      XCTFail("StubVenueArtifactAcquisition received an unscripted acquisition")
      throw VenueAcquisitionFailure.transportFailure
    }
    switch replies.removeFirst() {
    case .artifact(let artifact): return artifact
    case .failure(let failure): throw failure
    case .deferred:
      return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
  }

  /// Await a recorded request without polling, so a test can act at a precise
  /// point between the request and its outcome.
  func waitForAcquisitionCount(_ count: Int) async {
    guard requestedSources.count < count else { return }
    await withCheckedContinuation { observers.append((count, $0)) }
  }

  @discardableResult
  func failAcquisition(id: Int, with failure: VenueAcquisitionFailure) -> Bool {
    guard let continuation = pending.removeValue(forKey: id) else { return false }
    continuation.resume(throwing: failure)
    return true
  }

  @discardableResult
  func completeAcquisition(id: Int, with artifact: VenuePublicArtifact) -> Bool {
    guard let continuation = pending.removeValue(forKey: id) else { return false }
    continuation.resume(returning: artifact)
    return true
  }
}

/// A store backed by a unique temporary file.
///
/// Every test gets its own path. A shared default path would let one test's
/// stored artifact decide another's starting state — the same within-suite
/// contamination family as beid#244, and the reason `AGENTS.md` insists a
/// test count means nothing without knowing the state it ran against.
@MainActor
func makeTemporaryArtifactStore() -> VenuePublicArtifactStore {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("venue-artifact-\(UUID().uuidString).json")
  return VenuePublicArtifactStore(fileURL: url)
}
#endif
