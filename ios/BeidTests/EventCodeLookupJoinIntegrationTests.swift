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
  func testJoinEventResolvingCanonicalIdReturnsNoErrorWhenNoRegistryClientIsConfigured() async throws {
    let coordinator = AppCoordinator(registryClient: nil)

    let outcome = await coordinator.joinEventResolvingCanonicalId(code: "ethtokyo2026")

    XCTAssertEqual(outcome, .completed(nil))
    XCTAssertNil(coordinator.sensingCoordinator.joinedCanonicalEventIdHex)
  }

  func testJoinEventResolvingCanonicalIdReturnsNoErrorWhenTheLookupUrlTemplateIsNotConfigured() async throws {
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
      code == "first" ? await relay.suspend() : nil
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
    coordinator.resolveCanonicalEventIdHexOverride = { _ in await relay.suspend() }

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
    coordinator.resolveCanonicalEventIdHexOverride = { _ in await relay.suspend() }

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
        eventCodeLookupUrlTemplate: eventCodeLookupUrlTemplate
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
