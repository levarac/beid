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
  private var pending: (() -> Void)?

  var isScheduled: Bool { pending != nil }

  func schedule(stopAtUnixSeconds: Int64, now: Int64, fire: @escaping () -> Void) {
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
    pending()
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
  }

  var replies: [Reply] = []
  private(set) var requestedSources: [(bundle: URL, handoff: URL)] = []

  func acquire(bundleSource: URL, handoffSource: URL) async throws -> VenuePublicArtifact {
    requestedSources.append((bundleSource, handoffSource))
    guard !replies.isEmpty else {
      XCTFail("StubVenueArtifactAcquisition received an unscripted acquisition")
      throw VenueAcquisitionFailure.transportFailure
    }
    switch replies.removeFirst() {
    case .artifact(let artifact): return artifact
    case .failure(let failure): throw failure
    }
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
