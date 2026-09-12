// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// The ten scenarios `docs/venue-serving-contract.md` requires the consumer to
/// exercise, driven against the REAL `VenueSignedServingViewModel` and the
/// scripted ports — never a happy-path fake of this suite's own.
@MainActor
final class VenueSignedServingViewModelTests: XCTestCase {
  private var ports: ScriptedVenuePorts!
  private var acquisition: StubVenueArtifactAcquisition!
  private var store: VenuePublicArtifactStore!
  private var expiry: FakeVenueExpiryScheduler!
  private var fixture: VenueServingContractFixture!
  private var now: Int64!
  private var clockReading: VenueClockReading!

  override func setUp() async throws {
    try await super.setUp()
    ports = ScriptedVenuePorts()
    acquisition = StubVenueArtifactAcquisition()
    store = makeTemporaryArtifactStore()
    expiry = FakeVenueExpiryScheduler()
    fixture = try VenueServingContractFixture.load()
    now = VenueServingContractFixture.currentUnixSeconds
    clockReading = .available(unixSeconds: VenueServingContractFixture.currentUnixSeconds)
  }

  private func makeViewModel() -> VenueSignedServingViewModel {
    VenueSignedServingViewModel(
      verifier: ports,
      broadcasting: ports,
      acquisition: acquisition,
      store: store,
      clock: { [unowned self] in self.clockReading },
      expiry: expiry
    )
  }

  private func rejection(_ reason: VenueServingBlock) throws -> VenueServingRejection {
    switch reason {
    case .notStarted:
      return try XCTUnwrap(VenueServingRejection(reason: .notStarted, recheckAtUnixSeconds: now + 60))
    case .clockUnavailable, .expired, .noCurrentEnvelope, .envelopeRejected,
         .staleDefinition, .registryUnavailable:
      return try XCTUnwrap(VenueServingRejection(reason: reason))
    }
  }

  /// Drives a full supply through to whatever the scripted replies produce.
  private func supply(_ viewModel: VenueSignedServingViewModel) async {
    acquisition.replies = [.artifact(fixture.artifact)]
    await viewModel.supply(
      bundleSource: URL(string: "https://venue.example/bundle")!,
      handoffSource: URL(string: "https://venue.example/handoff")!,
      sourceDescription: "venue.example"
    )
  }

  private var installCalls: [ScriptedVenuePorts.Call] {
    ports.calls.filter {
      if case .installing = $0 { return true }
      return false
    }
  }

  // MARK: - Scenario 1 — every import rejection

  func testEveryImportRejectionIsSurfacedAndNothingIsInstalled() async throws {
    for failure in VenueImportFailure.allCases {
      ports = ScriptedVenuePorts()
      acquisition = StubVenueArtifactAcquisition()
      store = makeTemporaryArtifactStore()
      expiry = FakeVenueExpiryScheduler()
      let viewModel = makeViewModel()
      ports.importReplies = [.immediate(.rejected(failure))]

      await supply(viewModel)

      XCTAssertEqual(viewModel.status, .importRejected(failure))
      XCTAssertTrue(installCalls.isEmpty, "a rejected import must never install: \(failure)")
      XCTAssertNil(ports.installedPermit)
    }
  }

  // MARK: - Scenario 2 — identity imported but not evaluated

  func testImportedIdentityAloneNeverInstallsOrClaimsReady() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.deferred]

    acquisition.replies = [.artifact(fixture.artifact)]
    let task = Task {
      await viewModel.supply(
        bundleSource: URL(string: "https://venue.example/bundle")!,
        handoffSource: URL(string: "https://venue.example/handoff")!,
        sourceDescription: "venue.example"
      )
    }
    // Import recorded, then evaluation recorded and left hanging.
    await ports.waitForCallCount(3)

    // Identity is verified and evaluation is outstanding. Nothing may be on
    // the air, and nothing may present a name — a receipt has none.
    XCTAssertEqual(viewModel.status, .evaluating(fixture.identity))
    XCTAssertTrue(installCalls.isEmpty)
    XCTAssertNil(ports.installedPermit)
    XCTAssertEqual(viewModel.radio.state, .stopped)

    task.cancel()
    ports.completeEvaluation(id: 1, with: .blocked(try rejection(.noCurrentEnvelope)))
    _ = await task.value
  }

  // MARK: - Scenario 3 — a delayed result belonging to a superseded request

  func testDelayedImportCompletingAfterANewerRequestNeverInstalls() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.deferred, .immediate(.rejected(.definitionRejected))]

    acquisition.replies = [.artifact(fixture.artifact), .artifact(fixture.artifact)]
    let first = Task {
      await viewModel.supply(
        bundleSource: URL(string: "https://venue.example/one")!,
        handoffSource: URL(string: "https://venue.example/one-handoff")!,
        sourceDescription: "one"
      )
    }
    await ports.waitForCallCount(2)

    // A newer request supersedes the first while it is still in flight.
    await viewModel.supply(
      bundleSource: URL(string: "https://venue.example/two")!,
      handoffSource: URL(string: "https://venue.example/two-handoff")!,
      sourceDescription: "two"
    )
    XCTAssertEqual(viewModel.status, .importRejected(.definitionRejected))

    // The superseded completion arrives late, carrying a valid permit-worthy
    // import. It must be discarded rather than installed.
    ports.completeImport(id: 0, with: .imported(fixture.imported()))
    _ = await first.value

    XCTAssertEqual(viewModel.status, .importRejected(.definitionRejected))
    XCTAssertTrue(installCalls.isEmpty)
  }

  // MARK: - Scenario 4 — every serving rejection

  func testEveryServingRejectionIsSurfacedAndNothingIsInstalled() async throws {
    for reason in VenueServingBlock.allCases {
      ports = ScriptedVenuePorts()
      acquisition = StubVenueArtifactAcquisition()
      store = makeTemporaryArtifactStore()
      expiry = FakeVenueExpiryScheduler()
      let viewModel = makeViewModel()
      let blocked = try rejection(reason)
      ports.importReplies = [.immediate(.imported(fixture.imported()))]
      ports.evaluationReplies = [.immediate(.blocked(blocked))]

      await supply(viewModel)

      XCTAssertEqual(viewModel.status, .blocked(blocked))
      XCTAssertTrue(installCalls.isEmpty, "a blocked evaluation must never install: \(reason)")
      if reason == .notStarted {
        // beid#530: `.notStarted` is the one rejection that names its own
        // wake-up instant, and it must arm a timer for it -- otherwise a
        // device holding a not-yet-started pack never re-evaluates on its
        // own once blocked.
        XCTAssertEqual(
          expiry.scheduledStopAt, blocked.recheckAtUnixSeconds,
          "notStarted must arm its own recheck: \(reason)"
        )
        XCTAssertEqual(expiry.scheduledNow, now)
      } else {
        XCTAssertFalse(expiry.isScheduled, "a blocked evaluation must not arm a deadline: \(reason)")
      }
    }
  }

  // MARK: - beid#530 — expired permit during evaluation, and notStarted's recheck

  /// Proves the need for the `now < permit.stopAtUnixSeconds` guard in
  /// `install(_:imported:generation:)` (beid#530) by reverting that method to
  /// its pre-fix body against this exact test; see the PR body for the
  /// captured RED output.
  func testPermitThatExpiredDuringEvaluationIsNeverInstalled() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.deferred, .immediate(.blocked(try rejection(.expired)))]

    acquisition.replies = [.artifact(fixture.artifact)]
    let task = Task {
      await viewModel.supply(
        bundleSource: URL(string: "https://venue.example/bundle")!,
        handoffSource: URL(string: "https://venue.example/handoff")!,
        sourceDescription: "venue.example"
      )
    }
    // supply()'s own invalidate() clears first, then import, then the first
    // (deferred) evaluation is recorded -- three calls, not two.
    await ports.waitForCallCount(3)

    // The clock advances to exactly the permit's exclusive deadline while
    // evaluation is still outstanding, so the permit is stale the instant
    // its result arrives.
    clockReading = .available(unixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds)
    // Request id 1, not 0: importBundle's own (immediate) call already
    // consumed id 0 from the ports' shared counter, exactly as
    // testImportedIdentityAloneNeverInstallsOrClaimsReady's completeEvaluation(id: 1, ...)
    // already establishes above.
    ports.completeEvaluation(id: 1, with: .permitted(fixture.permit()))
    await task.value

    XCTAssertTrue(
      installCalls.isEmpty,
      "a permit that expired during evaluation must never reach installAndStart"
    )
    XCTAssertNil(ports.installedPermit)
    // install() re-ran evaluate with the fresh clock reading rather than
    // installing, and the second scripted reply is what that re-run consumed.
    XCTAssertEqual(viewModel.status, .blocked(try rejection(.expired)))
  }

  // MARK: - An asynchronous radio failure after a successful install

  private var clearCalls: [ScriptedVenuePorts.Call] {
    ports.calls.filter {
      if case .clearing = $0 { return true }
      return false
    }
  }

  /// A radio that dies AFTER a successful install must stop the serving
  /// state, not leave the screen claiming to serve.
  ///
  /// The constructor's `onState` handler used to be one statement --
  /// `self?.radio = update` -- which never looked at `update.state`. So an
  /// asynchronous `bluetoothUnavailable`/`advertiseFailed`/`gattServiceFailed`
  /// left `status` on `.serving`, the expiry timer armed and the container
  /// installed, while nothing was on the air.
  ///
  /// That display is a safety control, not a convenience: beid#531 was decided
  /// to ship WITHOUT an operator confirmation gate on the basis that the
  /// operator can see what is being broadcast. A control that can report
  /// serving while the radio is dead is not one.
  ///
  /// Reverting the handler to that single statement turns this RED; see the PR
  /// body for the captured output.
  func testAsynchronousRadioFailureAfterInstallStopsServingRatherThanClaimingIt() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]

    await supply(viewModel)

    // Precondition. Without it every assertion below could pass simply
    // because nothing ever reached the radio.
    XCTAssertEqual(
      viewModel.status,
      .serving(
        displayName: VenueServingContractFixture.displayName,
        stopAtUnixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds
      )
    )
    XCTAssertTrue(expiry.isScheduled)
    XCTAssertNotNil(ports.installedPermit)
    let clearsBeforeFailure = clearCalls.count

    // The radio dies with no request in flight and nothing thrown: just an
    // SDK callback arriving on a view model that believes it is serving.
    ports.emit(try XCTUnwrap(VenueRadioUpdate(state: .failed, failure: .advertiseFailed)))

    XCTAssertEqual(viewModel.status, .radioRefused(.advertiseFailed))
    XCTAssertEqual(viewModel.radio, VenueRadioUpdate(state: .failed, failure: .advertiseFailed))
    // Asserting the status alone would pass while the deadline stayed armed
    // and the container stayed live, which is most of the defect.
    XCTAssertFalse(expiry.isScheduled, "a dead radio must not leave the permit's deadline armed")
    XCTAssertGreaterThan(
      clearCalls.count, clearsBeforeFailure,
      "the container must be cleared, not left installed under a failed radio"
    )
    XCTAssertNil(ports.installedPermit)

    // A radio failure is not an operator stop. A later foreground return must
    // still be able to retry, so `wantsServing` has to survive this.
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.blocked(try rejection(.expired)))]
    await viewModel.sceneWillEnterForeground()
    XCTAssertEqual(
      viewModel.status, .blocked(try rejection(.expired)),
      "a radio failure must not be sticky like an explicit stop: the operator can still retry"
    )
  }

  /// A radio failure arriving SYNCHRONOUSLY, from inside `installAndStart`,
  /// must take the failure path rather than being stepped over.
  ///
  /// This is the ordinary Bluetooth-off path, not a corner. `installAndStart`
  /// returns normally when the radio is unavailable — `startAdvertise()`
  /// cannot throw and the envelope configuration validates structure only —
  /// while `startAdvertiseInternal` reports the constraint inline, with no
  /// dispatch. So the handler runs while `install` is still between its call
  /// and its `status = .serving`.
  ///
  /// The first version of this fix guarded on `case .serving`, which is not
  /// yet true at that instant, so the failure was dropped and `.serving` was
  /// then set anyway. Worse, it worked on the FIRST failure and not on any
  /// retry: `peripheralManagerDidUpdateState` emits nothing when state settles
  /// to `.poweredOff` with nothing advertising, so the first advertise sees
  /// `.unknown` and produces no constraint (the asynchronous path, which the
  /// earlier fix handled), while every advertise after that produces the
  /// synchronous one.
  ///
  /// Reverting `install` and `handleRadioUpdate` to that previous version —
  /// no `isInstalling`/`pendingInstallFailure`, `guard case .serving` alone —
  /// turns this RED; see the PR body for the captured output.
  func testRadioFailureArrivingDuringInstallIsNotSteppedOverBySettingServing() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]
    ports.nextSynchronousStateDuringInstall =
      try XCTUnwrap(VenueRadioUpdate(state: .failed, failure: .bluetoothUnavailable))

    await supply(viewModel)

    XCTAssertEqual(viewModel.status, .radioRefused(.bluetoothUnavailable))
    XCTAssertEqual(viewModel.radio, VenueRadioUpdate(state: .failed, failure: .bluetoothUnavailable))
    // The same four faces the asynchronous test asserts. Status alone would
    // pass while the deadline stayed armed and the container stayed live.
    XCTAssertFalse(expiry.isScheduled, "a radio that failed during install must not leave a deadline armed")
    XCTAssertNil(ports.installedPermit)
    let installIndex = try XCTUnwrap(
      ports.calls.firstIndex {
        if case .installing = $0 { return true }
        return false
      }
    )
    XCTAssertTrue(
      ports.calls[installIndex...].contains {
        if case .clearing = $0 { return true }
        return false
      },
      "the container must be cleared AFTER the install that failed, not left live"
    )
  }

  /// A `.failed` update arriving when nothing is being served is recorded on
  /// `radio` but must not rewrite `status`.
  ///
  /// The handler is long-lived and fires outside any request, so a late
  /// failure can arrive after an operator stop or onto a blocked screen.
  /// Letting it overwrite `status` there would replace a verification verdict,
  /// or a deliberate idle state, with a stale effect failure.
  func testRadioFailureArrivingWhileNothingIsServingLeavesTheStatusAlone() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.blocked(try rejection(.expired)))]

    await supply(viewModel)
    XCTAssertEqual(viewModel.status, .blocked(try rejection(.expired)))

    ports.emit(try XCTUnwrap(VenueRadioUpdate(state: .failed, failure: .bluetoothUnavailable)))

    XCTAssertEqual(
      viewModel.status, .blocked(try rejection(.expired)),
      "a radio failure must not overwrite a verification verdict the verifier actually issued"
    )
    // The radio's own state is still reported: it is a fact about the radio.
    XCTAssertEqual(viewModel.radio, VenueRadioUpdate(state: .failed, failure: .bluetoothUnavailable))
  }

  // MARK: - A failed replacement fetch must not resume the replaced event

  private var importCalls: [ScriptedVenuePorts.Call] {
    ports.calls.filter {
      if case .importing = $0 { return true }
      return false
    }
  }

  /// After the operator points at a new source and the fetch fails, the device
  /// must do NOTHING on its own — not quietly resume the event they were
  /// replacing.
  ///
  /// `supply` sets `wantsServing = true` and `receipt = nil` before acquiring.
  /// Its catch branches reported the failure but left the intent standing, and
  /// the store still held the OLD bundle. So the next foreground return passed
  /// its `wantsServing` guard, `refresh` found no receipt and fell through to
  /// `restoreFromStorage`, and the previous event went back on the air. The
  /// operator's last visible signal was an error; the device's next autonomous
  /// act was to broadcast the thing that error was about.
  ///
  /// The replies scripted below are deliberately the ones that SUCCEED. Under
  /// the previous version this test does not fail on an unscripted call — it
  /// fails by actually installing and serving the replaced event, which is the
  /// harm stated as output.
  ///
  /// Reverting the two catch branches in `supply` to their previous bodies
  /// turns this RED; see the PR body for the captured output.
  func testFailedReplacementFetchDoesNotLetTheNextForegroundResumeTheReplacedEvent() async throws {
    // A previous event's bundle is already stored, as it would be after a
    // successful supply in an earlier session.
    store.store(
      VenuePublicArtifactRecord(
        bundleBytes: fixture.artifact.bundleBytes,
        handoffBytes: fixture.artifact.handoffBytes,
        sourceDescription: "previous.example",
        storedAt: Date()
      )
    )
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]

    // The operator points at a replacement and the fetch fails.
    acquisition.replies = [.failure(.transportFailure)]
    await viewModel.supply(
      bundleSource: URL(string: "https://replacement.example/bundle")!,
      handoffSource: URL(string: "https://replacement.example/handoff")!,
      sourceDescription: "replacement.example"
    )
    XCTAssertEqual(viewModel.status, .acquisitionFailed(.transportFailure))
    let importsBeforeForeground = importCalls.count

    // Drive the real sequence rather than inspecting the flag: asserting
    // `wantsServing` is false would keep passing if the guard later moved.
    await viewModel.sceneWillEnterForeground()

    XCTAssertEqual(
      importCalls.count, importsBeforeForeground,
      "a failed replacement must not re-import the bundle it was replacing"
    )
    XCTAssertTrue(installCalls.isEmpty, "the replaced event must never go back on the air by itself")
    XCTAssertNil(ports.installedPermit)
    XCTAssertEqual(
      viewModel.status, .acquisitionFailed(.transportFailure),
      "the operator's last signal must still be on screen, not replaced by a serving state"
    )
  }

  /// The stored record itself is untouched, and the explicit reload path still
  /// works. The fix clears the operator's INTENT, not their data: a stored
  /// bundle they may well want to load again deliberately stays exactly where
  /// it was, reachable from the screen's own button.
  func testFailedReplacementLeavesTheStoredBundleLoadableOnDemand() async throws {
    store.store(
      VenuePublicArtifactRecord(
        bundleBytes: fixture.artifact.bundleBytes,
        handoffBytes: fixture.artifact.handoffBytes,
        sourceDescription: "previous.example",
        storedAt: Date()
      )
    )
    let viewModel = makeViewModel()
    acquisition.replies = [.failure(.unreadable)]
    await viewModel.supply(
      bundleSource: URL(string: "https://replacement.example/bundle")!,
      handoffSource: URL(string: "https://replacement.example/handoff")!,
      sourceDescription: "replacement.example"
    )
    XCTAssertEqual(viewModel.status, .acquisitionFailed(.unreadable))
    XCTAssertNotNil(store.record, "a failed fetch must not delete what was already stored")

    // The operator presses "reload stored bundle", which is the path
    // `VenueSignedServingView` wires to `restoreFromStorage()` directly.
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]
    await viewModel.restoreFromStorage()

    XCTAssertEqual(
      viewModel.status,
      .serving(
        displayName: VenueServingContractFixture.displayName,
        stopAtUnixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds
      ),
      "clearing the intent must not disable the explicit reload the operator can still choose"
    )
  }

  // MARK: - The production clock supplier this view model reads (beid#530)

  /// `VenueDeviceClock.read` must round its `Date` UP, not truncate it.
  ///
  /// Truncating turns a reading taken 0.1 s BEFORE a permit's exclusive
  /// `stopAtUnixSeconds` into `stopAt - 1`. That passes `install`'s
  /// `now < permit.stopAtUnixSeconds` guard, and `VenueExpiryTimer.schedule`
  /// then computes `stopAt - now == 1` and sleeps a whole second -- so the
  /// timer fires roughly 0.9 s AFTER the exclusive deadline, with expired
  /// signed bytes on the air for that interval. Rounding up yields `stopAt`,
  /// the guard fails, and the permit is refused. That direction can only ever
  /// refuse EARLIER than the true instant, never later, which is the safe way
  /// to be wrong about a deadline.
  ///
  /// This test drives the REAL `VenueDeviceClock.read`, deliberately. Every
  /// other test in this file hands the view model a hand-built
  /// `.available(...)`, which would pass identically before and after this
  /// fix and would prove nothing: the defect and its fix both live inside
  /// `read`. Reverting `read`'s body to `Int64(now().timeIntervalSince1970)`
  /// turns this RED; see the PR body for the captured output.
  func testSubSecondClockReadBeforeTheDeadlineRefusesRatherThanServingPastIt() async throws {
    let stopAt = VenueServingContractFixture.exclusiveStopUnixSeconds
    clockReading = VenueDeviceClock.read(now: { Date(timeIntervalSince1970: Double(stopAt) - 0.1) })

    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    // Two replies: the permit `install` has to refuse, then the verdict the
    // re-evaluation it runs instead consumes. Without the second reply the
    // refusal path would ask the ports for an unscripted evaluation.
    ports.evaluationReplies = [
      .immediate(.permitted(fixture.permit())),
      .immediate(.blocked(try rejection(.expired))),
    ]

    await supply(viewModel)

    XCTAssertTrue(
      installCalls.isEmpty,
      "a clock reading 0.1s before the exclusive deadline must not install: truncating it to stopAt - 1 "
        + "passes the guard and then leaves expired signed bytes on the air for the timer's whole second"
    )
    XCTAssertNil(ports.installedPermit)
    XCTAssertEqual(viewModel.status, .blocked(try rejection(.expired)))
  }

  /// The same rounding, asserted directly on the clock rather than through
  /// the view model, so a future reader can see the reading itself.
  func testClockRoundsASubSecondReadingUpRatherThanTruncatingItBackwards() {
    let stopAt = VenueServingContractFixture.exclusiveStopUnixSeconds
    XCTAssertEqual(
      VenueDeviceClock.read(now: { Date(timeIntervalSince1970: Double(stopAt) - 0.1) }),
      .available(unixSeconds: stopAt)
    )
    // An exact whole second is already the instant it names; rounding up must
    // not push it forward by one.
    XCTAssertEqual(
      VenueDeviceClock.read(now: { Date(timeIntervalSince1970: Double(stopAt)) }),
      .available(unixSeconds: stopAt)
    )
  }

  /// Rounding up must not lift an implausible reading over the sanity floor
  /// and make `.unavailable` unreachable. 2001-01-01T00:00:00Z is the instant
  /// factory-reset devices and simulators without network time frequently
  /// boot at, which is the case `VenueDeviceClock`'s floor exists to catch.
  func testRoundingUpLeavesTheSanityFloorAndNegativeReadingsUnavailable() {
    XCTAssertEqual(VenueDeviceClock.read(now: { Date(timeIntervalSince1970: 978_307_200) }), .unavailable)
    XCTAssertEqual(
      VenueDeviceClock.read(now: { Date(timeIntervalSince1970: Double(VenueDeviceClock.sanityFloorUnixSeconds - 1)) }),
      .unavailable
    )
    // Before the epoch: rounding toward +infinity must stay well below the
    // floor rather than landing on it.
    XCTAssertEqual(VenueDeviceClock.read(now: { Date(timeIntervalSince1970: -1.5) }), .unavailable)
  }

  /// A clock that moves BACKWARD across an ENIN boundary during evaluation
  /// must not install either.
  ///
  /// The permit is verified for one specific ENIN — `currentEnin` — whose
  /// wall-clock window is `[currentEnin * eninSeconds, (currentEnin + 1) *
  /// eninSeconds)`, the upper end being `stopAtUnixSeconds`. The guard in
  /// `install` checked only that upper end, so a reading that fell BEFORE the
  /// verified slice still passed it, and an envelope verified for a later
  /// slice was installed for an earlier one it was never checked against.
  ///
  /// This is the exact mirror of beid#530. That defect and its round-up fix
  /// both closed the upper end; the lower end was open the whole time. The
  /// clock-change notification is asynchronous and cannot win this race.
  ///
  /// Reverting the guard to `now < permit.stopAtUnixSeconds` alone turns this
  /// RED; see the PR body for the captured output.
  func testClockMovingBackBeforeTheVerifiedEninDuringEvaluationIsNeverInstalled() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.deferred, .immediate(.blocked(try rejection(.expired)))]

    acquisition.replies = [.artifact(fixture.artifact)]
    let task = Task {
      await viewModel.supply(
        bundleSource: URL(string: "https://venue.example/bundle")!,
        handoffSource: URL(string: "https://venue.example/handoff")!,
        sourceDescription: "venue.example"
      )
    }
    await ports.waitForCallCount(3)

    // One second before the permit's own slice begins, and so still comfortably
    // below `stopAtUnixSeconds` — which is exactly why the upper-bound-only
    // guard let it through.
    clockReading = .available(unixSeconds: VenueServingContractFixture.currentUnixSeconds - 1)
    ports.completeEvaluation(id: 1, with: .permitted(fixture.permit()))
    await task.value

    XCTAssertTrue(
      installCalls.isEmpty,
      "an envelope verified for a later ENIN must never be installed for an earlier one"
    )
    XCTAssertNil(ports.installedPermit)
    // Re-evaluated with the fresh reading rather than serving: the second
    // scripted reply is what that re-run consumed.
    XCTAssertEqual(viewModel.status, .blocked(try rejection(.expired)))
    XCTAssertFalse(expiry.isScheduled, "nothing was installed, so no deadline may be armed")
  }

  // MARK: - Scenario 5 — a current lease, then expiry

  func testPermittedLeaseInstallsExactPermitBytesAndArmsTheExclusiveDeadline() async throws {
    let viewModel = makeViewModel()
    let permit = fixture.permit()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(permit))]

    await supply(viewModel)

    XCTAssertEqual(
      viewModel.status,
      .serving(
        displayName: VenueServingContractFixture.displayName,
        stopAtUnixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds
      )
    )
    XCTAssertEqual(ports.installedPermit?.container, fixture.container)
    // The deadline is the permit's own instant, not a recomputed one.
    XCTAssertEqual(expiry.scheduledStopAt, VenueServingContractFixture.exclusiveStopUnixSeconds)
    XCTAssertEqual(expiry.scheduledNow, now)
  }

  func testExpiryClearsBeforeReEvaluatingAndABlockedRefreshLeavesNothingLive() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [
      .immediate(.permitted(fixture.permit())),
      .immediate(.blocked(try rejection(.expired))),
    ]

    await supply(viewModel)
    XCTAssertNotNil(ports.installedPermit)

    let callsBeforeExpiry = ports.calls.count
    expiry.fire()
    // Wait on the fake's own recording rather than yielding a fixed number of
    // times: expiry clears and then re-evaluates, so those two calls are the
    // deterministic signal that the refresh has run.
    await ports.waitForCallCount(callsBeforeExpiry + 2)

    XCTAssertEqual(viewModel.status, .blocked(try rejection(.expired)))
    XCTAssertNil(ports.installedPermit, "expiry must clear rather than leave bytes live")
    // The first thing expiry did was clear.
    XCTAssertEqual(ports.calls[callsBeforeExpiry], .clearing)
  }

  // MARK: - Scenario 6 — clock discontinuity

  func testBackwardAndForwardClockJumpsReEvaluateRatherThanRecompute() async throws {
    for jump in [Int64(-86_400), Int64(86_400), Int64(1_000_000)] {
      ports = ScriptedVenuePorts()
      acquisition = StubVenueArtifactAcquisition()
      store = makeTemporaryArtifactStore()
      expiry = FakeVenueExpiryScheduler()
      clockReading = .available(unixSeconds: now)
      let viewModel = makeViewModel()
      ports.importReplies = [.immediate(.imported(fixture.imported()))]
      ports.evaluationReplies = [
        .immediate(.permitted(fixture.permit())),
        .immediate(.blocked(try rejection(.expired))),
      ]

      await supply(viewModel)
      XCTAssertNotNil(ports.installedPermit)

      // The wall clock jumps, including a jump clean over the whole lease.
      clockReading = .available(unixSeconds: now + jump)
      await viewModel.systemClockDidChange()

      XCTAssertNil(ports.installedPermit, "a clock jump must clear: \(jump)")
      XCTAssertEqual(viewModel.status, .blocked(try rejection(.expired)))
      // The re-decision came from the verifier, asked with the NEW reading.
      XCTAssertEqual(
        ports.calls.last(where: {
          if case .evaluating = $0 { return true }
          return false
        }),
        .evaluating(id: 2, identity: fixture.identity, clock: .available(unixSeconds: now + jump))
      )
    }
  }

  func testForegroundReturnWithAnOldCompletionStillPendingDiscardsIt() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.deferred, .immediate(.blocked(try rejection(.staleDefinition)))]

    acquisition.replies = [.artifact(fixture.artifact)]
    let pending = Task {
      await viewModel.supply(
        bundleSource: URL(string: "https://venue.example/bundle")!,
        handoffSource: URL(string: "https://venue.example/handoff")!,
        sourceDescription: "venue.example"
      )
    }
    await ports.waitForCallCount(3)

    viewModel.sceneDidEnterBackground()
    await viewModel.sceneWillEnterForeground()

    // The evaluation from before backgrounding finally answers, with a permit.
    ports.completeEvaluation(id: 1, with: .permitted(fixture.permit()))
    _ = await pending.value

    XCTAssertNil(ports.installedPermit, "a superseded permit must never reach the radio")
    XCTAssertTrue(installCalls.isEmpty)
  }

  func testSceneDepartureClearsImmediately() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]

    await supply(viewModel)
    XCTAssertNotNil(ports.installedPermit)

    viewModel.sceneDidEnterBackground()

    XCTAssertNil(ports.installedPermit)
    XCTAssertEqual(viewModel.status, .idle)
    XCTAssertEqual(ports.calls.last, .clearing)
  }

  // MARK: - Scenario 7 — clear before replace, clear again on failure

  func testRejectedReplacementClearsBeforeInstallingAndClearsAgainOnFailure() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [
      .immediate(.imported(fixture.imported())),
      .immediate(.imported(fixture.imported())),
    ]
    ports.evaluationReplies = [
      .immediate(.permitted(fixture.permit())),
      .immediate(.permitted(fixture.permit())),
    ]

    await supply(viewModel)
    XCTAssertNotNil(ports.installedPermit, "the first install must succeed")

    let boundary = ports.calls.count
    ports.nextInstallFailure = .containerInstallRejected
    await supply(viewModel)

    // The exact ordered RADIO effects of a rejected replacement, with the
    // verification calls filtered out so the order being asserted is the one
    // that matters: clear, attempt, clear again.
    let effects = ports.calls[boundary...].filter {
      switch $0 {
      case .clearing, .installing: return true
      case .importing, .evaluating: return false
      }
    }
    XCTAssertEqual(
      effects,
      [
        .clearing,
        .installing(
          container: fixture.container,
          stopAtUnixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds
        ),
        .clearing,
      ],
      "a rejected replacement must clear, attempt, and clear again"
    )
    XCTAssertNil(ports.installedPermit, "the previous container must not survive a failed replacement")
    XCTAssertEqual(viewModel.status, .radioRefused(.containerInstallRejected))
    XCTAssertEqual(viewModel.radio.state, .failed)
    XCTAssertEqual(viewModel.radio.failure, .containerInstallRejected)
  }

  // MARK: - Scenarios 8 and 9 — radio states without inventing confirmation

  func testRadioUpdatesAreSurfacedAndAdvertisingRequestedIsNeverPromoted() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]

    await supply(viewModel)

    ports.emit(try XCTUnwrap(VenueRadioUpdate(state: .waitingForBluetooth)))
    XCTAssertEqual(viewModel.radio.state, .waitingForBluetooth)

    ports.emit(try XCTUnwrap(VenueRadioUpdate(state: .advertisingRequested)))
    XCTAssertEqual(viewModel.radio.state, .advertisingRequested)
    // Requested is the strongest claim available: the SDK reports advertising
    // before the OS confirms and never emits a success event, so nothing here
    // may report on-air.
    XCTAssertNil(viewModel.radio.failure)

    // Stopping after a request must not be recorded as having been on air.
    viewModel.stop()
    XCTAssertEqual(viewModel.radio.state, .stopped)
    XCTAssertEqual(viewModel.status, .idle)
  }

  func testEveryRadioFailureIsSurfaced() async throws {
    let viewModel = makeViewModel()
    for failure in VenueRadioFailure.allCases {
      ports.emit(try XCTUnwrap(VenueRadioUpdate(state: .failed, failure: failure)))
      XCTAssertEqual(viewModel.radio.state, .failed)
      XCTAssertEqual(viewModel.radio.failure, failure)
    }
  }

  func testAnExplicitStopSurvivesForegroundingAndClockChanges() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]

    await supply(viewModel)
    XCTAssertNotNil(ports.installedPermit)

    viewModel.stop()
    let callsAfterStop = ports.calls.count

    // Nothing further is scripted. If either lifecycle hook re-evaluated, the
    // fake would record an unscripted call and fail this test for us.
    await viewModel.sceneWillEnterForeground()
    await viewModel.systemClockDidChange()

    XCTAssertEqual(ports.calls.count, callsAfterStop, "a stop must not be undone by lifecycle events")
    XCTAssertNil(ports.installedPermit)
    XCTAssertEqual(viewModel.status, .idle)
  }

  // MARK: - Scenario 10 — restored bytes are re-imported, never resumed

  func testRestoreReImportsStoredBytesAndRefusesWhenTheyNoLongerVerify() async throws {
    // A previous run stored public bytes and served them.
    let first = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]
    await supply(first)
    XCTAssertNotNil(store.record, "supply must persist the public source bytes")

    // A fresh view model over the SAME store restores. The bytes go back
    // through the verifier, which now refuses them.
    ports = ScriptedVenuePorts()
    expiry = FakeVenueExpiryScheduler()
    let restored = makeViewModel()
    ports.importReplies = [.immediate(.rejected(.registryUnavailable))]

    await restored.restoreFromStorage()

    XCTAssertEqual(restored.status, .importRejected(.registryUnavailable))
    XCTAssertTrue(installCalls.isEmpty, "a restore must never resume serving")
    XCTAssertNil(ports.installedPermit)
    // The restore re-imported rather than resuming: an import call was made
    // with the stored bytes.
    XCTAssertEqual(
      ports.calls.first,
      .clearing
    )
    XCTAssertTrue(
      ports.calls.contains(.importing(id: 0, bundle: fixture.artifact.bundleBytes, handoff: fixture.artifact.handoffBytes)),
      "restore must re-import the stored public bytes"
    )
  }

  func testStoredRecordHoldsOnlyPublicBytes() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]

    await supply(viewModel)

    let record = try XCTUnwrap(store.record)
    XCTAssertEqual(record.bundleBytes, fixture.artifact.bundleBytes)
    XCTAssertEqual(record.handoffBytes, fixture.artifact.handoffBytes)
    // The permit's display name and container are SDK-verified facts that must
    // not be reachable from storage.
    let encoded = try JSONEncoder().encode(record)
    let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
    XCTAssertFalse(
      text.contains(VenueServingContractFixture.displayName),
      "a stored artifact must not carry a permit's display name"
    )
  }

  // MARK: - Acquisition refusals are not import verdicts

  func testAcquisitionFailureIsNotReportedAsAnImportRejection() async throws {
    for failure in VenueAcquisitionFailure.allCases {
      ports = ScriptedVenuePorts()
      acquisition = StubVenueArtifactAcquisition()
      store = makeTemporaryArtifactStore()
      expiry = FakeVenueExpiryScheduler()
      let viewModel = makeViewModel()
      acquisition.replies = [.failure(failure)]

      await viewModel.supply(
        bundleSource: URL(string: "https://venue.example/bundle")!,
        handoffSource: URL(string: "https://venue.example/handoff")!,
        sourceDescription: "venue.example"
      )

      XCTAssertEqual(viewModel.status, .acquisitionFailed(failure))
      // Nothing was verified, so nothing may be reported as rejected, and
      // nothing may be stored.
      XCTAssertNil(store.record)
      // The ONLY port call is the opening clear. No import was attempted, so
      // no verdict about the bundle exists to report.
      XCTAssertEqual(ports.calls, [.clearing], "acquisition failure must not reach the verifier: \(failure)")
    }
  }

  // MARK: - Outcome coverage, from OBSERVED outcomes

  func testObservedOutcomesCoverEveryDeclaredCase() async throws {
    var observedImports: Set<VenueImportFailure> = []
    var observedServing: Set<VenueServingBlock> = []
    var observedRadio: Set<VenueRadioState> = []
    var observedRadioFailures: Set<VenueRadioFailure> = []

    // Scripting FROM allCases is fine; what must not be prefilled is the
    // observed set, which only ever records what the view model surfaced.
    for failure in VenueImportFailure.allCases {
      ports = ScriptedVenuePorts()
      acquisition = StubVenueArtifactAcquisition()
      store = makeTemporaryArtifactStore()
      expiry = FakeVenueExpiryScheduler()
      let viewModel = makeViewModel()
      ports.importReplies = [.immediate(.rejected(failure))]
      await supply(viewModel)
      if case .importRejected(let observed) = viewModel.status {
        observedImports.insert(observed)
      }
    }

    for reason in VenueServingBlock.allCases {
      ports = ScriptedVenuePorts()
      acquisition = StubVenueArtifactAcquisition()
      store = makeTemporaryArtifactStore()
      expiry = FakeVenueExpiryScheduler()
      let viewModel = makeViewModel()
      ports.importReplies = [.immediate(.imported(fixture.imported()))]
      ports.evaluationReplies = [.immediate(.blocked(try rejection(reason)))]
      await supply(viewModel)
      if case .blocked(let observed) = viewModel.status {
        observedServing.insert(observed.reason)
      }
    }

    ports = ScriptedVenuePorts()
    acquisition = StubVenueArtifactAcquisition()
    store = makeTemporaryArtifactStore()
    expiry = FakeVenueExpiryScheduler()
    let viewModel = makeViewModel()
    observedRadio.insert(viewModel.radio.state)

    for state in [VenueRadioState.waitingForBluetooth, .advertisingRequested] {
      ports.emit(try XCTUnwrap(VenueRadioUpdate(state: state)))
      observedRadio.insert(viewModel.radio.state)
    }
    for failure in VenueRadioFailure.allCases {
      ports.emit(try XCTUnwrap(VenueRadioUpdate(state: .failed, failure: failure)))
      observedRadio.insert(viewModel.radio.state)
      if let observed = viewModel.radio.failure {
        observedRadioFailures.insert(observed)
      }
    }
    viewModel.stop()
    observedRadio.insert(viewModel.radio.state)

    assertVenueOutcomeCoverage(
      imports: observedImports,
      serving: observedServing,
      radio: observedRadio,
      radioFailures: observedRadioFailures
    )
  }
}
