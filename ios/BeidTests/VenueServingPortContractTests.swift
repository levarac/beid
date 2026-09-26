// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

#if DEBUG
import Foundation
import XCTest
@testable import Beid

/// Interface/fake tests only. A passing result here is NOT evidence that the
/// real provider verifies a bundle or that the native consumer stops a radio.
/// Those implementations must run the same fixture and outcome inventory.
@MainActor
final class VenueServingPortContractTests: XCTestCase {
  func testServingContextRejectsEveryInvalidReasonAndInstantPairing() {
    for reason in VenueServingBlock.allCases {
      let absent = VenueServingRejection(reason: reason)
      let present = VenueServingRejection(reason: reason, recheckAtUnixSeconds: 1_800_000_300)
      let negative = VenueServingRejection(reason: reason, recheckAtUnixSeconds: -1)
      if reason == .notStarted {
        XCTAssertNil(absent)
        XCTAssertNotNil(present)
        XCTAssertNotNil(VenueServingRejection(reason: reason, recheckAtUnixSeconds: 0))
      } else {
        XCTAssertNotNil(absent)
        XCTAssertNil(present)
      }
      XCTAssertNil(negative)
    }
  }

  func testRadioContextRejectsEveryInvalidStateAndFailurePairing() {
    for state in VenueRadioState.allCases {
      let absent = VenueRadioUpdate(state: state)
      if state == .failed { XCTAssertNil(absent) } else { XCTAssertNotNil(absent) }
      for failure in VenueRadioFailure.allCases {
        let paired = VenueRadioUpdate(state: state, failure: failure)
        if state == .failed { XCTAssertNotNil(paired) } else { XCTAssertNil(paired) }
      }
    }
  }

  func testFakeActuallyReturnsEveryCompilerEnumeratedOutcome() async throws {
    let fixture = try VenueServingContractFixture.load()
    let fake = ScriptedVenuePorts()
    var imports = Set<VenueImportFailure>()
    var serving = Set<VenueServingBlock>()
    var radio = Set<VenueRadioState>()
    var failures = Set<VenueRadioFailure>()

    for failure in VenueImportFailure.allCases {
      fake.importReplies.append(.immediate(.rejected(failure)))
      let result = await fake.importBundle(
        bundleBytes: fixture.artifact.bundleBytes, handoffBytes: fixture.artifact.handoffBytes
      )
      guard case .rejected(let observed) = result else { return XCTFail("Expected a rejected import") }
      XCTAssertEqual(observed, failure)
      imports.insert(observed)
    }
    for reason in VenueServingBlock.allCases {
      let rejection = try XCTUnwrap(VenueServingRejection(
        reason: reason, recheckAtUnixSeconds: reason == .notStarted ? 1_800_000_300 : nil
      ))
      fake.evaluationReplies.append(.immediate(.blocked(rejection)))
      let result = await fake.evaluate(fixture.imported(), clock: .available(unixSeconds: 1_800_000_000))
      guard case .blocked(let observed) = result else { return XCTFail("Expected a blocked lease") }
      XCTAssertEqual(observed, rejection)
      serving.insert(observed.reason)
    }
    fake.onState = { update in
      radio.insert(update.state)
      if let failure = update.failure { failures.insert(failure) }
    }
    for state in VenueRadioState.allCases where state != .failed {
      fake.emit(try XCTUnwrap(VenueRadioUpdate(state: state)))
    }
    for failure in VenueRadioFailure.allCases {
      fake.emit(try XCTUnwrap(VenueRadioUpdate(state: .failed, failure: failure)))
    }
    assertVenueOutcomeCoverage(imports: imports, serving: serving, radio: radio, radioFailures: failures)
    XCTAssertNil(fake.installedPermit, "Returning/replaying verification facts must not install bytes")
  }

  func testImportedReceiptDoesNotInstallAnythingBeforeEvaluation() async throws {
    let fixture = try VenueServingContractFixture.load()
    let fake = ScriptedVenuePorts()
    fake.importReplies = [.immediate(.imported(fixture.imported()))]

    let result = await fake.importBundle(
      bundleBytes: fixture.artifact.bundleBytes, handoffBytes: fixture.artifact.handoffBytes
    )

    guard case .imported(let imported) = result else { return XCTFail("Expected identity-only receipt") }
    XCTAssertEqual(imported.identity, fixture.identity)
    XCTAssertEqual(imported.publicArtifact, fixture.artifact)
    XCTAssertNil(fake.installedPermit)
    XCTAssertEqual(fake.calls.count, 1)
  }

  func testFrozenPermitCarriesExactBytesAndAnExclusiveCurrentLeaseDeadline() async throws {
    let fixture = try VenueServingContractFixture.load()
    let fake = ScriptedVenuePorts()
    fake.evaluationReplies = [.immediate(.permitted(fixture.permit()))]

    let result = await fake.evaluate(fixture.imported(), clock: .available(unixSeconds: 1_800_000_000))

    guard case .permitted(let permit) = result else { return XCTFail("Expected current-lease permit") }
    XCTAssertEqual(permit.container, fixture.container)
    XCTAssertEqual(permit.identity.eventIdHex, VenueServingContractFixture.eventIdHex)
    XCTAssertEqual(permit.identity.bundleDigestHex, VenueServingContractFixture.bundleDigestHex)
    XCTAssertEqual(permit.identity.definitionSequence, 1)
    XCTAssertEqual(permit.displayName, VenueServingContractFixture.displayName)
    XCTAssertEqual(permit.payloadDigestHex, VenueServingContractFixture.payloadDigestHex)
    XCTAssertEqual(permit.currentEnin, 6_000_000)
    XCTAssertEqual(permit.stopAtUnixSeconds, 1_800_000_300)
    XCTAssertEqual(permit.verificationScope, .currentLeaseOnly)
    XCTAssertNil(fake.installedPermit)
  }

  func testDeferredImportsCanFinishInReverseOrderAndOnlyOnce() async throws {
    let fixture = try VenueServingContractFixture.load()
    let fake = ScriptedVenuePorts()
    fake.importReplies = [.deferred, .deferred]
    let first = Task { await fake.importBundle(bundleBytes: Data([1]), handoffBytes: Data([2])) }
    await fake.waitForCallCount(1)
    let second = Task { await fake.importBundle(bundleBytes: Data([3]), handoffBytes: Data([4])) }
    await fake.waitForCallCount(2)
    XCTAssertEqual(fake.pendingImportIDs, [0, 1])

    XCTAssertTrue(fake.completeImport(id: 1, with: .imported(fixture.imported())))
    guard case .imported = await second.value else { return XCTFail("Second request should finish first") }
    XCTAssertEqual(fake.pendingImportIDs, [0])
    XCTAssertTrue(fake.completeImport(id: 0, with: .rejected(.registryUnavailable)))
    guard case .rejected(let failure) = await first.value else { return XCTFail("Expected delayed failure") }
    XCTAssertEqual(failure, .registryUnavailable)
    XCTAssertFalse(fake.completeImport(id: 0, with: .imported(fixture.imported())))
    XCTAssertNil(fake.installedPermit, "Stale completion filtering is the consumer's job")
  }

  func testDelayedEvaluationKeepsItsOwnClockAcrossANewerRequest() async throws {
    let fixture = try VenueServingContractFixture.load()
    let fake = ScriptedVenuePorts()
    fake.evaluationReplies = [.deferred, .immediate(.blocked(try XCTUnwrap(
      VenueServingRejection(reason: .expired)
    )))]
    let first = Task {
      await fake.evaluate(fixture.imported(), clock: .available(unixSeconds: 1_800_000_000))
    }
    await fake.waitForCallCount(1)
    let newer = await fake.evaluate(fixture.imported(), clock: .available(unixSeconds: 1_800_001_000))
    guard case .blocked(let rejection) = newer else { return XCTFail("Clock jump must be scriptable") }
    XCTAssertEqual(rejection.reason, .expired)
    XCTAssertTrue(fake.completeEvaluation(id: 0, with: .permitted(fixture.permit())))
    guard case .permitted = await first.value else { return XCTFail("Old result remains deliverable") }
    XCTAssertEqual(fake.calls, [
      .evaluating(id: 0, identity: fixture.identity, clock: .available(unixSeconds: 1_800_000_000)),
      .evaluating(id: 1, identity: fixture.identity, clock: .available(unixSeconds: 1_800_001_000)),
    ])
    XCTAssertNil(fake.installedPermit)
  }

  func testCurrentLeaseCanBecomeExpiredOrStaleWithoutProducingReplacementBytes() async throws {
    let fixture = try VenueServingContractFixture.load()
    let fake = ScriptedVenuePorts()
    for reason in [VenueServingBlock.expired, .staleDefinition] {
      fake.evaluationReplies = [
        .immediate(.permitted(fixture.permit())),
        .immediate(.blocked(try XCTUnwrap(VenueServingRejection(reason: reason)))),
      ]
      guard case .permitted = await fake.evaluate(fixture.imported(), clock: .available(unixSeconds: 1_800_000_000))
      else { return XCTFail("Initial lease missing") }
      guard case .blocked(let rejection) = await fake.evaluate(fixture.imported(), clock: .available(unixSeconds: 1_800_000_300))
      else { return XCTFail("Renewal should be blocked") }
      XCTAssertEqual(rejection.reason, reason)
    }
    XCTAssertNil(fake.installedPermit)
  }

  func testRejectedInstallRetainsOldBytesUntilAnExplicitClear() throws {
    let fixture = try VenueServingContractFixture.load()
    let fake = ScriptedVenuePorts()
    try fake.installAndStart(fixture.permit())
    fake.nextInstallFailure = .containerInstallRejected

    XCTAssertThrowsError(try fake.installAndStart(fixture.permit())) { error in
      XCTAssertEqual(error as? VenueRadioFailure, .containerInstallRejected)
    }
    XCTAssertEqual(fake.installedPermit?.container, fixture.container)
    fake.clearAndStop()
    XCTAssertNil(fake.installedPermit)

    fake.nextInstallFailure = .containerInstallRejected
    XCTAssertThrowsError(try fake.installAndStart(fixture.permit()))
    fake.clearAndStop()
    XCTAssertNil(fake.installedPermit)
    XCTAssertEqual(fake.calls, [
      .installing(container: fixture.container, stopAtUnixSeconds: 1_800_000_300),
      .installing(container: fixture.container, stopAtUnixSeconds: 1_800_000_300),
      .clearing,
      .installing(container: fixture.container, stopAtUnixSeconds: 1_800_000_300),
      .clearing,
    ])
  }

  func testStartupHasNoAutomaticSuccessAndCanFailAfterAnAdvertisingRequest() throws {
    let fixture = try VenueServingContractFixture.load()
    let fake = ScriptedVenuePorts()
    var observed: [VenueRadioUpdate] = []
    fake.onState = { observed.append($0) }
    try fake.installAndStart(fixture.permit())
    XCTAssertTrue(observed.isEmpty)
    let waiting = try XCTUnwrap(VenueRadioUpdate(state: .waitingForBluetooth))
    let requested = try XCTUnwrap(VenueRadioUpdate(state: .advertisingRequested))
    fake.emit(waiting)
    fake.emit(requested)
    for reason in VenueRadioFailure.allCases {
      fake.emit(try XCTUnwrap(VenueRadioUpdate(state: .failed, failure: reason)))
    }
    XCTAssertEqual(Array(observed.prefix(2)), [waiting, requested])
    XCTAssertEqual(Set(observed.compactMap(\.failure)), Set(VenueRadioFailure.allCases))
    XCTAssertEqual(observed.last?.state, .failed)
  }

  func testUnavailableAndBackwardClockReadingsRemainExplicitInputs() async throws {
    let fixture = try VenueServingContractFixture.load()
    let fake = ScriptedVenuePorts()
    let clocks: [VenueClockReading] = [.unavailable, .available(unixSeconds: 1_799_999_900)]
    let rejections = [
      try XCTUnwrap(VenueServingRejection(reason: .clockUnavailable)),
      try XCTUnwrap(VenueServingRejection(reason: .notStarted, recheckAtUnixSeconds: 1_800_000_000)),
    ]
    for (clock, expected) in zip(clocks, rejections) {
      fake.evaluationReplies.append(.immediate(.blocked(expected)))
      guard case .blocked(let observed) = await fake.evaluate(fixture.imported(), clock: clock)
      else { return XCTFail("Expected explicit clock refusal") }
      XCTAssertEqual(observed, expected)
    }
    XCTAssertNil(fake.installedPermit)
  }

  func testPersistedBytesCanBeRejectedOnRelaunchForCorruptionOrUnavailableRegistry() async throws {
    let fixture = try VenueServingContractFixture.load()
    let fake = ScriptedVenuePorts()
    var corrupted = fixture.artifact.bundleBytes
    corrupted[0] ^= 1
    for (bytes, failure) in [
      (corrupted, VenueImportFailure.malformedOrOutOfBounds),
      (fixture.artifact.bundleBytes, VenueImportFailure.registryUnavailable),
    ] {
      fake.importReplies.append(.immediate(.rejected(failure)))
      guard case .rejected(let observed) = await fake.importBundle(
        bundleBytes: bytes, handoffBytes: fixture.artifact.handoffBytes
      ) else { return XCTFail("Persisted bytes must go through import again") }
      XCTAssertEqual(observed, failure)
    }
    XCTAssertNil(fake.installedPermit)
  }
}
#endif
