// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#if DEBUG
import Foundation
import XCTest
@testable import Beid

/// One fake for both sides of the venue seam. No automatic happy-path reply:
/// every verification response is scripted, including delayed completions.
@MainActor
final class ScriptedVenuePorts: VenueBundleVerifying, VenueSignedContainerBroadcasting {
  enum Reply<Value> {
    case immediate(Value)
    case deferred
  }

  enum Call: Equatable {
    case importing(id: Int, bundle: Data, handoff: Data)
    case evaluating(id: Int, identity: VenueArtifactIdentity, clock: VenueClockReading)
    case installing(container: Data, stopAtUnixSeconds: Int64)
    case clearing
  }

  var importReplies: [Reply<VenueImportResult>] = []
  var evaluationReplies: [Reply<VenueServingDecision>] = []
  var nextInstallFailure: VenueRadioFailure?
  /// A radio update emitted from INSIDE `installAndStart`, before it returns.
  ///
  /// Barnard really does this. `startAdvertiseInternal` calls
  /// `emitConstraint("bluetooth_not_ready")` inline for `.poweredOff`,
  /// `.unauthorized` and `.unsupported`, and `emitConstraint` is a direct
  /// `onEvent?(...)` with no dispatch, so the consumer's handler runs BEFORE
  /// `installAndStart` returns. `startAdvertise()` itself cannot throw and
  /// `configureOwnEventInfoEnvelopeV2` validates container structure only, so
  /// the install returns normally while the radio has already failed.
  ///
  /// Without this the fake can only express failures arriving AFTER
  /// `installAndStart` returns, which is why a consumer that handled only
  /// those looked fully covered. A whole class of defect was unreachable by
  /// any test in this suite, not merely untested.
  var nextSynchronousStateDuringInstall: VenueRadioUpdate?
  var onState: ((VenueRadioUpdate) -> Void)?
  private(set) var calls: [Call] = []
  private(set) var installedPermit: VenueServePermit?
  private var nextRequestID = 0
  private var imports: [Int: CheckedContinuation<VenueImportResult, Never>] = [:]
  private var evaluations: [Int: CheckedContinuation<VenueServingDecision, Never>] = [:]
  private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  var pendingImportIDs: [Int] { imports.keys.sorted() }
  var pendingEvaluationIDs: [Int] { evaluations.keys.sorted() }

  func importBundle(bundleBytes: Data, handoffBytes: Data) async -> VenueImportResult {
    let id = takeRequestID()
    record(.importing(id: id, bundle: bundleBytes, handoff: handoffBytes))
    guard !importReplies.isEmpty else {
      XCTFail("ScriptedVenuePorts received an unscripted import")
      return .rejected(.registryUnavailable)
    }
    switch importReplies.removeFirst() {
    case .immediate(let result): return result
    case .deferred:
      return await withCheckedContinuation { imports[id] = $0 }
    }
  }

  func evaluate(_ imported: VenueImportedBundle, clock: VenueClockReading) async -> VenueServingDecision {
    let id = takeRequestID()
    record(.evaluating(id: id, identity: imported.identity, clock: clock))
    guard !evaluationReplies.isEmpty else {
      XCTFail("ScriptedVenuePorts received an unscripted evaluation")
      return .blocked(VenueServingRejection(reason: .registryUnavailable)!)
    }
    switch evaluationReplies.removeFirst() {
    case .immediate(let result): return result
    case .deferred:
      return await withCheckedContinuation { evaluations[id] = $0 }
    }
  }

  /// Results can be released out of order. The consumer, not this fake, must
  /// reject completions belonging to a superseded UI request generation.
  @discardableResult
  func completeImport(id: Int, with result: VenueImportResult) -> Bool {
    guard let continuation = imports.removeValue(forKey: id) else { return false }
    continuation.resume(returning: result)
    return true
  }

  @discardableResult
  func completeEvaluation(id: Int, with result: VenueServingDecision) -> Bool {
    guard let continuation = evaluations.removeValue(forKey: id) else { return false }
    continuation.resume(returning: result)
    return true
  }

  func installAndStart(_ permit: VenueServePermit) throws {
    record(.installing(container: permit.container, stopAtUnixSeconds: permit.stopAtUnixSeconds))
    if let failure = nextInstallFailure {
      nextInstallFailure = nil
      // Deliberately retain the prior payload, exactly as the real SDK does.
      throw failure
    }
    installedPermit = permit
    // Emitted here, after the container is installed and before returning,
    // because that is where barnard emits it: the envelope is configured
    // first, then startAdvertise reports the constraint inline.
    if let update = nextSynchronousStateDuringInstall {
      nextSynchronousStateDuringInstall = nil
      emit(update)
    }
    // Deliberately emit no radio success. Tests must supply actual SDK-like
    // updates, including waiting, an optimistic request and later failures.
  }

  func clearAndStop() {
    record(.clearing)
    installedPermit = nil
    emit(VenueRadioUpdate(state: .stopped)!)
  }

  func emit(_ update: VenueRadioUpdate) {
    onState?(update)
  }

  /// Await a recorded request without polling/sleeping. Recording occurs in
  /// the same actor turn that registers the deferred continuation.
  func waitForCallCount(_ count: Int) async {
    guard calls.count < count else { return }
    await withCheckedContinuation { observers.append((count, $0)) }
  }

  private func takeRequestID() -> Int {
    defer { nextRequestID += 1 }
    return nextRequestID
  }

  private func record(_ call: Call) {
    calls.append(call)
    let ready = observers.filter { $0.count <= calls.count }
    observers.removeAll { $0.count <= calls.count }
    for observer in ready { observer.continuation.resume() }
  }
}
#endif
