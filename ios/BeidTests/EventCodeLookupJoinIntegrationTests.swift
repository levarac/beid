// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation
import XCTest
@testable import Beid

/// Proves the manual event-code join path (beid#258 P1-1) through
/// `AppCoordinator.joinEventResolvingCanonicalId(code:)` — the composed
/// "resolve, then join with that exact code" method `EventCodeEntryView
/// .submit()` calls — never a hand-substituted `canonicalEventIdHex` passed
/// straight into `joinEvent`, which would skip the lookup this suite exists
/// to exercise.
///
/// Most of this suite intentionally does not stand up a real network
/// server: this codebase's `createSepoliaRegistryClient(...)` refuses
/// loopback HTTP for every URL template it accepts (`RegistryClientTest.kt`'s
/// own `localhostHttpDefinitionTemplateSurfacesTypedConfigurationError` /
/// `loopbackAddressHttpDefinitionTemplateSurfacesTypedConfigurationError`
/// establish that as an existing, deliberate constraint predating this
/// change, not something specific to the new lookup) — so a hermetic
/// success-path fetch is not reachable from a Swift XCTest for this
/// package. That path is proven at the Kotlin layer instead, against a real
/// `RegistryHttpTransport`-shaped fake transport that exercises the actual
/// `EventCodeLookupFetcher`/JSON-parsing/hex-validation logic:
/// `EventCodeLookupFetcherTest.fetchReturnsTheEventIdFromASuccessfulLookup`
/// et al. in `shared/src/commonTest`. `EventCodeEntryView.submit()` itself
/// is a private method on a SwiftUI view and, like this codebase's other
/// view-level behavior, belongs to `EventMembershipUITests` rather than a
/// unit test.
///
/// The one property that genuinely needs a controlled concurrent race —
/// `joinAttemptGeneration` supersession while an earlier lookup is still
/// suspended — uses `AppCoordinator.resolveCanonicalEventIdHexOverride`
/// (test-only, see its own doc comment) plus `ContinuationRelay` below to
/// get a real, test-controlled suspension point without a flaky
/// wall-clock-dependent test. A naive *sequential* version of this test
/// (`Task { await coordinator.joinEventResolvingCanonicalId(...) }` then
/// immediately `coordinator.returnToWalletConnect()`) does **not** work:
/// Swift's `Task { }` creation never suspends its creator, so the
/// cancellation's generation bump provably runs before the child task's own
/// bump — the reverse of a real abandon-mid-lookup. `ContinuationRelay`
/// exists specifically to get the ordering right instead.
@MainActor
final class EventCodeLookupJoinIntegrationTests: XCTestCase {
  /// Selecting a code with no registry client configured is not a *code
  /// entry* error, so this surface shows nothing. It is also not a join:
  /// `SensingCoordinator.joinEvent` records the code and tells Barnard
  /// nothing (beid#410). The refusal lives one step later, in
  /// `beginRegistryVerifiedJoin` at `startSensing`, which answers
  /// `.noRegistryConfigured` — pinned by
  /// `EventJoinGateTests.testStartSensingLeavesNoSensingScreenWhenNoRegistryIsConfigured`,
  /// which asserts the session returns to idle rather than merely that the
  /// refusal value was published.
  ///
  /// Named for selection on purpose. Under its previous name this test read
  /// as proof that an unverified *join* was acceptable, and that reading sent
  /// two separate reviewers after a P1 that does not exist (2026-09-09).
  func testSelectingAnEventCodeIsNotAnErrorWhenNoRegistryClientIsConfigured() async throws {
    let coordinator = AppCoordinator(registryClient: nil)

    let outcome = await coordinator.joinEventResolvingCanonicalId(code: "ethtokyo2026")

    XCTAssertEqual(outcome, .completed(nil))
    XCTAssertNil(coordinator.sensingCoordinator.joinedCanonicalEventIdHex)
  }

  /// Same distinction as above for an unconfigured lookup URL template: the
  /// selection is recorded with no canonical id, and the nil asserted below
  /// is precisely the state `beginRegistryVerifiedJoin` refuses with
  /// `.noCanonicalEventId` — pinned by
  /// `EventJoinGateTests.testStartSensingStartsNothingWithoutACanonicalEventId`.
  func testSelectingAnEventCodeIsNotAnErrorWhenTheLookupUrlTemplateIsNotConfigured() async throws {
    let coordinator = try makeCoordinator(eventCodeLookupUrlTemplate: nil)

    let outcome = await coordinator.joinEventResolvingCanonicalId(code: "ethtokyo2026")

    XCTAssertEqual(outcome, .completed(nil))
    XCTAssertNil(coordinator.sensingCoordinator.joinedCanonicalEventIdHex)
  }

  func testResolveCanonicalEventIdHexReturnsNilWhenTheLookupUrlTemplateIsInvalid() async throws {
    // Missing the required `{code}` placeholder.
    let coordinator = try makeCoordinator(
      eventCodeLookupUrlTemplate: "https://operator.example/v1/events/by-code/fixed"
    )

    let canonicalEventIdHex = await coordinator.resolveCanonicalEventIdHex(forCode: "ethtokyo2026")

    XCTAssertNil(canonicalEventIdHex)
  }

  func testResolveCanonicalEventIdHexReturnsNilForAnEmptyCodeWithoutAttemptingALookup() async throws {
    let coordinator = try makeCoordinator(
      eventCodeLookupUrlTemplate: "https://operator.example/v1/events/by-code/{code}"
    )

    let canonicalEventIdHex = await coordinator.resolveCanonicalEventIdHex(forCode: "   ")

    XCTAssertNil(canonicalEventIdHex)
  }

  /// A resolved ID never bypasses `attemptJoinEvent`'s existing validation —
  /// composing the two calls with a code that normalizes to empty still
  /// reports `.emptyCode`, exactly as it would with no lookup at all.
  func testJoinEventResolvingCanonicalIdStillReportsEmptyCode() async throws {
    let coordinator = AppCoordinator(registryClient: nil)

    let outcome = await coordinator.joinEventResolvingCanonicalId(code: "   ")

    XCTAssertEqual(outcome, .completed(.emptyCode))
  }

  /// The `joinAttemptGeneration` guard must not treat ordinary, one-at-a-time
  /// sequential calls as superseding each other — only a call that starts
  /// while an *earlier* one is still awaiting its lookup should ever see its
  /// result discarded. Two fully-awaited calls in a row both reporting their
  /// own real, non-`.superseded` outcome is the non-pathological baseline
  /// this suite's real race test (below) builds on.
  func testSequentialJoinAttemptsEachCompleteWithoutSupersedingEachOther() async throws {
    let coordinator = AppCoordinator(registryClient: nil)

    let first = await coordinator.joinEventResolvingCanonicalId(code: "   ")
    let second = await coordinator.joinEventResolvingCanonicalId(code: "ethtokyo2026")

    XCTAssertEqual(first, .completed(.emptyCode))
    XCTAssertEqual(second, .completed(nil))
  }

  /// The actual concurrent race: attempt "first" starts and suspends inside
  /// its lookup (captured by the relay, never a real network call), then
  /// attempt "second" starts and completes *while "first" is still
  /// suspended*, then only "first"'s continuation is released. "first" must
  /// come back `.superseded` — its lookup does complete, just too late to
  /// matter — and must not have joined anything; "second" must complete
  /// normally, unaffected by "first" ever existing.
  func testALaterConcurrentAttemptSupersedesAnEarlierStillSuspendedOne() async throws {
    let coordinator = AppCoordinator(registryClient: nil)
    let relay = ContinuationRelay()
    coordinator.resolveCanonicalEventIdHexOverride = { code in
      code == "first"
        ? .init(eventIdHex: await relay.suspend(), errorCode: nil)
        : .noAnswer
    }

    async let firstOutcome = coordinator.joinEventResolvingCanonicalId(code: "first")
    await relay.waitUntilSuspended()
    let secondOutcome = await coordinator.joinEventResolvingCanonicalId(code: "second")
    await relay.resume(returning: nil)

    let resolvedFirstOutcome = await firstOutcome
    XCTAssertEqual(resolvedFirstOutcome, .superseded)
    XCTAssertEqual(secondOutcome, .completed(nil))
    XCTAssertNil(coordinator.sensingCoordinator.joinedCanonicalEventIdHex)
  }

  /// Same shape as the race above, but "first" is superseded by
  /// `cancelPendingJoinAttempt` (via `returnToWalletConnect`, its only
  /// production caller) instead of by a second join attempt — the onboarding
  /// join surface's path behind the beid#258 P1-1 round-2 fix (abandoning
  /// the join surface must invalidate whatever lookup was still in flight).
  func testReturnToWalletConnectWhileSuspendedSupersedesTheInFlightOnboardingAttempt() async throws {
    let coordinator = AppCoordinator(registryClient: nil)
    let relay = ContinuationRelay()
    coordinator.resolveCanonicalEventIdHexOverride = { _ in
      .init(eventIdHex: await relay.suspend(), errorCode: nil)
    }

    async let outcome = coordinator.joinEventResolvingCanonicalId(code: "abandoned")
    await relay.waitUntilSuspended()
    coordinator.returnToWalletConnect()
    await relay.resume(returning: "0x" + String(repeating: "aa", count: 32))

    let resolvedOutcome = await outcome
    XCTAssertEqual(resolvedOutcome, .superseded)
    XCTAssertNil(coordinator.sensingCoordinator.joinedCanonicalEventIdHex)
  }

  /// The account-sheet join surface's equivalent of the test above — the
  /// path behind the beid#258 P1-1 round-3 fix, where `AccountSheetView`'s
  /// custom cancelling `Binding` and its toolbar Cancel button both call
  /// `cancelPendingAccountSheetJoinAttempt()` synchronously before dismissing
  /// the sheet. Calling that same coordinator method directly here — rather
  /// than re-deriving it in the test — is what actually makes this exercise
  /// the account-sheet path specifically: without it, this test would pass
  /// even if the round-3 `Binding`/Cancel-button fix were reverted back to
  /// the reactive `.onChange` this round replaced, since nothing else here
  /// would call it.
  func testCancelPendingAccountSheetJoinAttemptWhileSuspendedSupersedesTheInFlightAttempt() async throws {
    let coordinator = AppCoordinator(registryClient: nil)
    let relay = ContinuationRelay()
    coordinator.resolveCanonicalEventIdHexOverride = { _ in
      .init(eventIdHex: await relay.suspend(), errorCode: nil)
    }

    async let outcome = coordinator.joinEventFromAccountSheetResolvingCanonicalId(code: "abandoned")
    await relay.waitUntilSuspended()
    coordinator.cancelPendingAccountSheetJoinAttempt()
    await relay.resume(returning: "0x" + String(repeating: "aa", count: 32))

    let resolvedOutcome = await outcome
    XCTAssertEqual(resolvedOutcome, .superseded)
    XCTAssertNil(coordinator.sensingCoordinator.joinedCanonicalEventIdHex)
  }

  private func makeCoordinator(eventCodeLookupUrlTemplate: String?) throws -> AppCoordinator {
    let registryClient = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.registry.createSepoliaRegistryClient(
        readerAddressHex: "0x" + String(repeating: "11", count: 20),
        etherscanApiKey: nil,
        definitionUrlTemplate: nil,
        eventKeySetUrlTemplate: nil,
        eventCodeLookupUrlTemplate: eventCodeLookupUrlTemplate,
        eventCodeHashLookupUrlTemplate: nil
      )
    )
    return AppCoordinator(registryClient: registryClient)
  }
}

/// A one-shot async gate for deterministically interleaving two concurrent
/// tasks in a test: `suspend()` parks the caller until `resume(returning:)`
/// is called from elsewhere, and `waitUntilSuspended()` lets that elsewhere
/// wait until a caller has genuinely parked before proceeding — without
/// either side polling or relying on real scheduling/timing order. An
/// actor, not a class with a lock, so it's safe to share across the
/// concurrent tasks a race test exists to create.
private actor ContinuationRelay {
  private var pending: CheckedContinuation<String?, Never>?
  private var suspendedSignal: CheckedContinuation<Void, Never>?

  func suspend() async -> String? {
    await withCheckedContinuation { continuation in
      pending = continuation
      suspendedSignal?.resume()
      suspendedSignal = nil
    }
  }

  func waitUntilSuspended() async {
    if pending != nil { return }
    await withCheckedContinuation { suspendedSignal = $0 }
  }

  func resume(returning value: String?) {
    pending?.resume(returning: value)
    pending = nil
  }
}

/// beid#472 — what a participant is told when the join gate refuses.
///
/// Before this, `SensingCoordinator` held the refusal in `joinRefusal` and no
/// view read it. "Nothing is happening" looked identical whether the radio had
/// never started or was simply alone in the room — the state the owner spent a
/// field session in on 2026-09-10.
///
/// These assert the reason key the coordinator publishes, not the copy: the
/// classification is `shared/`'s decision and is worth pinning, while the
/// sentences are this host's and belong to the view.
///
/// The refusal is deliberately **not** raised when the code is merely
/// selected. Selecting is not joining (`SensingCoordinator.joinEvent`, and the
/// two `testSelectingAnEventCodeIsNotAnError...` tests above), and an earlier
/// attempt at this feature that refused at selection broke both of them — the
/// gate is where the answer exists.
@MainActor
final class JoinGateRefusalReasonTests: XCTestCase {
  private let canonicalEventIdHex = "0x" + String(repeating: "a", count: 64)

  /// Waits until `condition` holds, or fails with `description`.
  ///
  /// **Not a fixed number of `Task.yield()` calls, and not a fixed sleep.** A
  /// refusal travels through the registry completion and a
  /// `Task { @MainActor }` hop, so how many turns it needs is a property of
  /// the machine, not of the code. The first version of these tests yielded
  /// eight times: it passed on the development machine and failed on the
  /// self-hosted runner, where four of them reported a nil reason key because
  /// the work simply had not happened yet. That is the lane earning its
  /// keep — and a reason not to take a local pass as the whole answer.
  private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 5,
    _ condition: @MainActor () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for \(description)")
  }

  private func refusalReasonKey(
    lookupErrorCode: String?,
    canonicalEventIdHex: String?
  ) async -> String? {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      eventJoinRegistry: registry
    )
    coordinator.useDemoEventMode = false
    XCTAssertTrue(
      coordinator.joinEvent(
        "ethtokyo2026",
        canonicalEventIdHex: canonicalEventIdHex,
        lookupErrorCode: lookupErrorCode
      )
    )
    coordinator.startSensing()
    await waitUntil("a refusal to be published") { coordinator.joinRefusalReasonKey != nil }
    return coordinator.joinRefusalReasonKey
  }

  func testATransportFailureDuringLookupIsReportedAsNeedingANetwork() async {
    let key = await refusalReasonKey(lookupErrorCode: "timeout", canonicalEventIdHex: nil)
    XCTAssertEqual(
      key,
      "network_required",
      "a lookup that never arrived must not be reported as a bad code"
    )
  }

  func testAnUnregisteredCodeIsReportedAsNoSuchEvent() async {
    let key = await refusalReasonKey(
      lookupErrorCode: "event_code_lookup_not_found",
      canonicalEventIdHex: nil
    )
    XCTAssertEqual(
      key,
      "event_not_found",
      "the endpoint answered and no event is registered — that is the participant's answer"
    )
  }

  func testAMisconfiguredDeploymentIsNotBlamedOnTheNetwork() async {
    let key = await refusalReasonKey(
      lookupErrorCode: "event_code_lookup_not_configured",
      canonicalEventIdHex: nil
    )
    XCTAssertEqual(
      key,
      "verification_failed",
      "a deployment with no lookup endpoint is broken for everyone and is not fixed by finding Wi-Fi"
    )
  }

  /// No canonical id and no error code either: nothing was asked.
  func testNoLookupAnswerAtAllIsStillExplained() async {
    let key = await refusalReasonKey(lookupErrorCode: nil, canonicalEventIdHex: nil)
    XCTAssertEqual(key, "verification_failed")
  }

  /// The gate's own verdict, for a read that succeeded. A definition outside
  /// its validity window is `EVENT_NOT_ACTIVE`, not a verification failure —
  /// the distinction a participant can act on, and the reason the gate's
  /// verdict is carried rather than flattened.
  func testAnExpiredDefinitionIsReportedAsNotOpenRightNow() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    let expiredWindowNow = Int64(Date().timeIntervalSince1970) - 10 * 86_400
    registry.answer = .resolves(
      FakeEventJoinRegistry.admittingResolution(
        eventIdHex: canonicalEventIdHex,
        nowEpochSeconds: expiredWindowNow
      )
    )
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      eventJoinRegistry: registry
    )
    coordinator.useDemoEventMode = false
    XCTAssertTrue(
      coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)
    )
    coordinator.startSensing()
    await waitUntil("a refusal to be published") { coordinator.joinRefusalReasonKey != nil }

    XCTAssertFalse(engine.didJoin, "an expired definition must not start a radio")
    XCTAssertEqual(
      coordinator.joinRefusalReasonKey,
      "event_not_active",
      "an expired event is not the same situation as one beid could not verify"
    )
  }

  /// A definition read that answered with nothing, carrying a transport error
  /// code. Before beid#472's follow-up this branch could only say `UNKNOWN`,
  /// because the adapter collapsed a failed read to nil and dropped the code
  /// with it.
  func testADefinitionReadThatFailedOnTransportSaysSo() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    registry.answer = .readFails(errorCode: "timeout")
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      eventJoinRegistry: registry
    )
    coordinator.useDemoEventMode = false
    XCTAssertTrue(
      coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)
    )
    coordinator.startSensing()
    await waitUntil("a refusal to be published") { coordinator.joinRefusalReasonKey != nil }

    XCTAssertEqual(registry.requestedEventIdHexes, [canonicalEventIdHex], "the read happened")
    XCTAssertFalse(engine.didJoin)
    XCTAssertEqual(
      coordinator.joinRefusalReasonKey,
      "network_required",
      "a read that never arrived is a connection problem, not an unverifiable event"
    )
  }

  /// The same read failing with no error code at all. Nothing to classify, so
  /// it must not pretend to know.
  func testADefinitionReadFailureWithNoCodeStaysUnknown() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    registry.answer = .readFails(errorCode: nil)
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      eventJoinRegistry: registry
    )
    coordinator.useDemoEventMode = false
    XCTAssertTrue(
      coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)
    )
    coordinator.startSensing()
    await waitUntil("a refusal to be published") { coordinator.joinRefusalReasonKey != nil }

    XCTAssertEqual(coordinator.joinRefusalReasonKey, "unknown")
  }

  /// An admitted join leaves nothing to explain.
  func testAnAdmittedJoinPublishesNoRefusal() async {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    registry.answer = .resolves(
      FakeEventJoinRegistry.admittingResolution(eventIdHex: canonicalEventIdHex)
    )
    let coordinator = makeIsolatedSensingCoordinator(
      for: self,
      eventJoinControl: engine,
      eventJoinRegistry: registry
    )
    coordinator.useDemoEventMode = false
    XCTAssertTrue(
      coordinator.joinEvent("ethtokyo2026", canonicalEventIdHex: canonicalEventIdHex)
    )
    coordinator.startSensing()
    await waitUntil("the gate to admit and start the radio") { engine.didJoin }

    XCTAssertNil(
      coordinator.joinRefusalReasonKey,
      "an admitted join leaves nothing to explain"
    )
  }
}
