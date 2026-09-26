#if DEBUG
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

  private func makeViewModel(clock: (() -> VenueClockReading)? = nil) -> VenueSignedServingViewModel {
    VenueSignedServingViewModel(
      verifier: ports,
      broadcasting: ports,
      acquisition: acquisition,
      store: store,
      clock: clock ?? { [unowned self] in self.clockReading },
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

  func testPermitThatExpiresDuringInstallIsClearedBeforeServing() async throws {
    var clockReads = 0
    let viewModel = makeViewModel(clock: {
      clockReads += 1
      return .available(unixSeconds: clockReads <= 2
        ? VenueServingContractFixture.exclusiveStopUnixSeconds - 1
        : VenueServingContractFixture.exclusiveStopUnixSeconds)
    })
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]

    await supply(viewModel)

    XCTAssertGreaterThanOrEqual(clockReads, 3)
    XCTAssertNil(ports.installedPermit)
    XCTAssertFalse(expiry.isScheduled)
    XCTAssertEqual(viewModel.status, .blocked(try rejection(.expired)))
  }

  func testExpiryTimerUsesThePostInstallClockReading() async throws {
    var clockReads = 0
    let postInstallNow = VenueServingContractFixture.exclusiveStopUnixSeconds - 1
    let viewModel = makeViewModel(clock: {
      clockReads += 1
      return .available(unixSeconds: clockReads <= 2
        ? postInstallNow - 1
        : postInstallNow)
    })
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]

    await supply(viewModel)

    XCTAssertEqual(viewModel.status, .serving(
      displayName: VenueServingContractFixture.displayName,
      stopAtUnixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds
    ))
    XCTAssertEqual(expiry.scheduledNow, postInstallNow)
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

  /// The same defect through the lifecycle door: backgrounding mid-fetch must
  /// not let the failed replacement leave its intent standing.
  ///
  /// `sceneDidEnterBackground()` calls `invalidate()`, which bumps the
  /// generation, and deliberately does not touch `wantsServing`. The catch
  /// branches tested generation equality before abandoning the replacement, so
  /// a fetch that failed after a background return returned early and left the
  /// intent in force. On foreground, `refresh()` found no receipt, fell
  /// through to `restoreFromStorage()`, and the replaced event went back on
  /// the air.
  ///
  /// Generation equality cannot carry this: it answers "was this request
  /// superseded", and a lifecycle invalidation supersedes a request without
  /// establishing a new intent. Those are different questions and this test is
  /// the one that separates them.
  ///
  /// The scripted replies are again the ones that SUCCEED, so the previous
  /// version fails by actually serving the replaced event rather than on an
  /// unscripted call. Reverting `supply`'s catch branches to gate
  /// `abandonReplacement()` behind the generation guard turns this RED.
  func testBackgroundingDuringAReplacementFetchStillAbandonsTheFailedIntent() async throws {
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

    // The replacement fetch is still in flight.
    acquisition.replies = [.deferred]
    let task = Task {
      await viewModel.supply(
        bundleSource: URL(string: "https://replacement.example/bundle")!,
        handoffSource: URL(string: "https://replacement.example/handoff")!,
        sourceDescription: "replacement.example"
      )
    }
    await acquisition.waitForAcquisitionCount(1)

    // The operator backgrounds the app while it is fetching. This bumps the
    // generation without touching the intent.
    viewModel.sceneDidEnterBackground()
    // Only now does the fetch fail.
    XCTAssertTrue(acquisition.failAcquisition(id: 0, with: .transportFailure))
    await task.value

    let importsBeforeForeground = importCalls.count
    await viewModel.sceneWillEnterForeground()

    XCTAssertEqual(
      importCalls.count, importsBeforeForeground,
      "a replacement that failed while backgrounded must not re-import the bundle it was replacing"
    )
    XCTAssertTrue(installCalls.isEmpty, "the replaced event must never go back on the air by itself")
    XCTAssertNil(ports.installedPermit)
    XCTAssertEqual(
      viewModel.status, .idle,
      "the screen was reset by backgrounding and nothing may put it back into a serving state"
    )
  }

  /// The property round 10 verified, kept explicit so the invalidation fix
  /// above cannot be "simplified" into reopening it: a stale request that
  /// fails must never clear an intent a NEWER request established.
  func testAStaleFailedFetchDoesNotClearTheIntentOfANewerRequest() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]

    acquisition.replies = [.deferred, .artifact(fixture.artifact)]
    let stale = Task {
      await viewModel.supply(
        bundleSource: URL(string: "https://stale.example/bundle")!,
        handoffSource: URL(string: "https://stale.example/handoff")!,
        sourceDescription: "stale.example"
      )
    }
    await acquisition.waitForAcquisitionCount(1)

    // A newer supply lands and succeeds while the first is still in flight.
    await viewModel.supply(
      bundleSource: URL(string: "https://current.example/bundle")!,
      handoffSource: URL(string: "https://current.example/handoff")!,
      sourceDescription: "current.example"
    )
    XCTAssertEqual(
      viewModel.status,
      .serving(
        displayName: VenueServingContractFixture.displayName,
        stopAtUnixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds
      )
    )

    // The superseded fetch now fails. It must not tear down the newer one.
    XCTAssertTrue(acquisition.failAcquisition(id: 0, with: .transportFailure))
    await stale.value

    XCTAssertEqual(
      viewModel.status,
      .serving(
        displayName: VenueServingContractFixture.displayName,
        stopAtUnixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds
      ),
      "a stale failure must not clear the intent or the state a newer request established"
    )
    // And a foreground return must still be able to refresh, which it cannot
    // do if the stale failure cleared the newer intent.
    ports.evaluationReplies = [.immediate(.blocked(try rejection(.expired)))]
    await viewModel.sceneWillEnterForeground()
    XCTAssertEqual(viewModel.status, .blocked(try rejection(.expired)))
  }

  /// Bytes that are recognisably NOT the stored artifact, so a test can say
  /// WHICH event reached the verifier rather than merely that one did.
  private var replacementArtifact: VenuePublicArtifact {
    VenuePublicArtifact(bundleBytes: Data([0xA1, 0xA2, 0xA3]), handoffBytes: Data([0xB1, 0xB2]))
  }

  private var importedBundleBytes: [Data] {
    ports.calls.compactMap {
      if case .importing(_, let bundle, _) = $0 { return bundle }
      return nil
    }
  }

  /// Route 2: a clock change while a replacement is still downloading must not
  /// put the event being replaced on the air.
  ///
  /// Nothing fails here, which is what makes it a different defect from the
  /// acquisition-failure one. `supply` sets `wantsServing` before acquiring,
  /// so `systemClockDidChange()` passes its guard, `refresh()` finds no
  /// receipt — because the supply has not produced one YET — and falls through
  /// to `restoreFromStorage()`. The stored bytes are the ones the operator is
  /// replacing.
  ///
  /// `receipt == nil` has three causes and only one of them warrants
  /// restoring: nothing ever supplied. "A supply is in flight" and "a supply
  /// just failed" both mean the operator has asked for something else.
  func testClockChangeWhileAReplacementIsInFlightDoesNotServeTheReplacedEvent() async throws {
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

    acquisition.replies = [.deferred]
    let task = Task {
      await viewModel.supply(
        bundleSource: URL(string: "https://replacement.example/bundle")!,
        handoffSource: URL(string: "https://replacement.example/handoff")!,
        sourceDescription: "replacement.example"
      )
    }
    await acquisition.waitForAcquisitionCount(1)

    // The wall clock moves while the replacement is still downloading.
    await viewModel.systemClockDidChange()

    XCTAssertFalse(
      importedBundleBytes.contains(fixture.artifact.bundleBytes),
      "the event being replaced must not be imported while its replacement is still downloading"
    )
    XCTAssertTrue(installCalls.isEmpty, "nothing may go on the air during a pending replacement")
    XCTAssertNil(ports.installedPermit)

    // Let the in-flight supply finish so the task does not outlive the test.
    XCTAssertTrue(acquisition.completeAcquisition(id: 0, with: replacementArtifact))
    await task.value
  }

  /// Route 3, the worst of the three: the replacement SUCCEEDS and is silently
  /// discarded, leaving the replaced event on the air with nothing on screen
  /// to say so.
  ///
  /// `refresh()` calls `invalidate()` before it does anything else, so a clock
  /// change during a pending supply bumps the generation. When the fetch then
  /// succeeds, `supply` hits its own generation guard and returns — the new
  /// bundle is never stored, never imported, never served, and no error is
  /// raised because nothing failed.
  ///
  /// This is why the guard has to sit BEFORE `invalidate()` rather than at the
  /// `receipt == nil` fallback: by the time the fallback is reached the
  /// generation has already moved and the supply is already doomed.
  ///
  /// A test that only looked for an error state would pass here while the
  /// device served the wrong event, so this asserts WHICH bytes reached the
  /// verifier.
  func testAReplacementThatSucceedsDuringAClockChangeIsNotSilentlyDiscarded() async throws {
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

    acquisition.replies = [.deferred]
    let task = Task {
      await viewModel.supply(
        bundleSource: URL(string: "https://replacement.example/bundle")!,
        handoffSource: URL(string: "https://replacement.example/handoff")!,
        sourceDescription: "replacement.example"
      )
    }
    await acquisition.waitForAcquisitionCount(1)

    await viewModel.systemClockDidChange()
    // The replacement arrives successfully, after the clock change.
    XCTAssertTrue(acquisition.completeAcquisition(id: 0, with: replacementArtifact))
    await task.value

    XCTAssertTrue(
      importedBundleBytes.contains(replacementArtifact.bundleBytes),
      "the replacement the operator asked for must actually be imported, not silently dropped"
    )
    XCTAssertFalse(
      importedBundleBytes.contains(fixture.artifact.bundleBytes),
      "the replaced event must not be the one that ends up served"
    )
    XCTAssertEqual(
      store.record?.bundleBytes, replacementArtifact.bundleBytes,
      "a replacement that succeeded must be the one stored"
    )
    XCTAssertEqual(viewModel.storedSourceDescription, "replacement.example")
  }

  /// Requirement 3: the fallback still exists for the case it was written for.
  /// Nothing supplied this run, a stored record present, a foreground return —
  /// the stored artifact is restored, exactly as before.
  func testAForegroundReturnWithNothingSuppliedStillRestoresTheStoredArtifact() async throws {
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

    // The operator presses reload, which is the only way `wantsServing`
    // becomes true without a supply, then backgrounds and returns.
    await viewModel.restoreFromStorage()
    XCTAssertTrue(importedBundleBytes.contains(fixture.artifact.bundleBytes))

    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]
    await viewModel.sceneWillEnterForeground()

    XCTAssertEqual(
      viewModel.status,
      .serving(
        displayName: VenueServingContractFixture.displayName,
        stopAtUnixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds
      ),
      "the restore path the fallback exists for must keep working"
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

  /// A registry `validFrom` can be supplied in the wrong unit (for example,
  /// milliseconds), producing a recheck instant far beyond UInt64 nanoseconds.
  /// The production timer must saturate that delay rather than trapping while
  /// still allowing the operator to cancel the pending wait.
  func testExpiryTimerSaturatesHugeRecheckWithoutOverflow() async {
    let timer = VenueExpiryTimer()
    var fired = false

    timer.schedule(stopAtUnixSeconds: Int64.max, now: 0) {
      fired = true
    }
    timer.cancel()
    await Task.yield()

    XCTAssertFalse(fired, "a cancelled saturated recheck must not fire")
  }

  /// The exclusive deadline remains immediate when it has already been
  /// reached; saturation must not alter that normal boundary behavior.
  func testExpiryTimerFiresImmediatelyAtExclusiveDeadline() async {
    let timer = VenueExpiryTimer()
    var fired = false

    timer.schedule(stopAtUnixSeconds: 10, now: 10) {
      fired = true
    }
    await Task.yield()

    XCTAssertTrue(fired)
    timer.cancel()
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

  // MARK: - beid#531 — the serving screen names the event actually installed

  func testServingEventIdIsTheInstalledPermitsEvent() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]

    await supply(viewModel)

    guard case .serving = viewModel.status else {
      return XCTFail("expected .serving, got \(viewModel.status)")
    }
    let installed = try XCTUnwrap(ports.installedPermit)
    XCTAssertEqual(viewModel.servingEventIdHex, installed.identity.eventIdHex)
    XCTAssertEqual(viewModel.servingEventIdHex, VenueServingContractFixture.eventIdHex)
  }

  /// The threat in beid#531 is a different event's pack being served at the
  /// same venue, so the ID on screen must come from the permit that reached
  /// `installAndStart`, not from the import receipt. The two agree for every
  /// permit the production verifier builds today; this test separates them so
  /// a display sourced from the receipt goes red.
  func testServingEventIdFollowsThePermitWhenItNamesAnotherEvent() async throws {
    let viewModel = makeViewModel()
    let otherIdentity = VenueArtifactIdentity(
      eventIdHex: "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90",
      definitionSequence: 1,
      bundleDigestHex: VenueServingContractFixture.bundleDigestHex
    )
    // Without this the test would stop discriminating if the literal above
    // ever drifted onto the fixture's own event.
    XCTAssertNotEqual(otherIdentity.eventIdHex, fixture.identity.eventIdHex)
    let otherEventPermit = VenueServingContractTestFactory.permit(
      identity: otherIdentity,
      container: fixture.container,
      displayName: VenueServingContractFixture.displayName,
      payloadDigestHex: VenueServingContractFixture.payloadDigestHex,
      currentEnin: VenueServingContractFixture.currentEnin,
      startAtUnixSeconds: VenueServingContractFixture.currentUnixSeconds,
      stopAtUnixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds
    )
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(otherEventPermit))]

    await supply(viewModel)

    guard case .serving = viewModel.status else {
      return XCTFail("expected .serving, got \(viewModel.status)")
    }
    XCTAssertEqual(ports.installedPermit?.identity.eventIdHex, otherIdentity.eventIdHex)
    XCTAssertEqual(viewModel.servingEventIdHex, otherIdentity.eventIdHex)
    XCTAssertNotEqual(viewModel.servingEventIdHex, fixture.identity.eventIdHex)
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

  /// A clock notification can be delivered while CoreBluetooth keeps the
  /// process alive after the scene entered background. The VM transition must
  /// remain ineligible there: a callback must not re-evaluate the selected
  /// receipt, install a permit, or arm a new deadline.
  ///
  /// This is deliberately a VM-only witness. It proves the effect of a
  /// delivered callback, not that iOS delivers NSSystemClockDidChange in the
  /// background or that radio bytes remain on air after suspension.
  func testBackgroundClockChangeCannotRestartAnActiveServingLease() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]

    await supply(viewModel)
    XCTAssertNotNil(ports.installedPermit)
    XCTAssertTrue(expiry.isScheduled)

    viewModel.sceneDidEnterBackground()
    let callsAfterBackground = ports.calls.count

    await viewModel.systemClockDidChange()

    XCTAssertEqual(
      ports.calls.count,
      callsAfterBackground,
      "a background clock callback must not start a new verification"
    )
    XCTAssertNil(ports.installedPermit, "background clock must not restart serving")
    XCTAssertFalse(expiry.isScheduled, "background clock must not arm a deadline")
    XCTAssertEqual(viewModel.status, .idle)
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

    // Structural (beid#702, T5): the record's fields are EXACTLY the public
    // bytes, their source and when they were stored. Screen 14 reads this
    // record, so the day a display name, verdict, deadline or key field is
    // added here is the day 14 could present a stale verification as current.
    // Checked twice because each misses something: the encoded keys omit a nil
    // optional (`encodeIfPresent`), and the declared fields do not show a key
    // smuggled in by a custom `encode(to:)`.
    let publicFields: Set<String> = ["bundleBytes", "handoffBytes", "sourceDescription", "storedAt"]
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertFalse(object.isEmpty, "the encoded record must have keys to compare")
    XCTAssertEqual(Set(object.keys), publicFields)
    let declared = Mirror(reflecting: record).children.compactMap(\.label)
    XCTAssertEqual(declared.count, publicFields.count, "declared fields: \(declared)")
    XCTAssertEqual(Set(declared), publicFields)
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


// MARK: - Accepted Issue 545 ownership model: behavioral regression witnesses

extension VenueSignedServingViewModelTests {
  private enum PendingStage: String, CaseIterable {
    case acquisition, importing, evaluation
  }

  private func resetOwnershipHarness() {
    ports = ScriptedVenuePorts()
    acquisition = StubVenueArtifactAcquisition()
    store = makeTemporaryArtifactStore()
    expiry = FakeVenueExpiryScheduler()
    clockReading = .available(unixSeconds: now)
  }

  private func seedStoredArtifact() {
    store.store(VenuePublicArtifactRecord(
      bundleBytes: fixture.artifact.bundleBytes,
      handoffBytes: fixture.artifact.handoffBytes,
      sourceDescription: "previous.example", storedAt: Date()
    ))
  }

  private func startPending(
    _ stage: PendingStage, model: VenueSignedServingViewModel
  ) async -> Task<Void, Never> {
    acquisition.replies = stage == .acquisition ? [.deferred] : [.artifact(replacementArtifact)]
    ports.importReplies = stage == .importing ? [.deferred] : [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = stage == .evaluation ? [.deferred] : [.immediate(.permitted(fixture.permit()))]
    let task = Task {
      await model.supply(
        bundleSource: URL(string: "https://replacement.example/bundle")!,
        handoffSource: URL(string: "https://replacement.example/handoff")!,
        sourceDescription: "replacement.example"
      )
    }
    switch stage {
    case .acquisition: await acquisition.waitForAcquisitionCount(1)
    case .importing: await ports.waitForCallCount(2)
    case .evaluation: await ports.waitForCallCount(3)
    }
    return task
  }

  private func finishPending(_ stage: PendingStage, success: Bool) {
    switch stage {
    case .acquisition:
      if success { XCTAssertTrue(acquisition.completeAcquisition(id: 0, with: replacementArtifact)) }
      else { XCTAssertTrue(acquisition.failAcquisition(id: 0, with: .transportFailure)) }
    case .importing:
      XCTAssertTrue(ports.completeImport(
        id: 0, with: success ? .imported(fixture.imported()) : .rejected(.definitionRejected)
      ))
    case .evaluation:
      XCTAssertTrue(ports.completeEvaluation(
        id: 1, with: success ? .permitted(fixture.permit()) : .blocked(VenueServingRejection(reason: .expired)!)
      ))
    }
  }

  func testW04BackgroundSuccessPreservesReplacementWithBothForegroundOrders() async throws {
    for foregroundBeforeResult in [false, true] {
      resetOwnershipHarness()
      seedStoredArtifact()
      let model = makeViewModel()
      let pending = await startPending(.acquisition, model: model)
      model.sceneDidEnterBackground()
      if foregroundBeforeResult { await model.sceneWillEnterForeground() }
      finishPending(.acquisition, success: true)
      await pending.value
      if !foregroundBeforeResult {
        XCTAssertNil(ports.installedPermit, "W04 no background install")
        await model.sceneWillEnterForeground()
      }
      XCTAssertEqual(store.record?.bundleBytes, replacementArtifact.bundleBytes, "W04 selected B retained")
      XCTAssertTrue(importedBundleBytes.contains(replacementArtifact.bundleBytes), "W04 B imported")
      XCTAssertFalse(importedBundleBytes.contains(fixture.artifact.bundleBytes), "W04 A never restored")
      XCTAssertNotNil(ports.installedPermit, "W04 current B can serve after foreground")
      print("W04 foregroundBeforeResult=\(foregroundBeforeResult)")
    }
  }

  func testW08ReloadDeadlineClearsWhileObsoleteSupplyIsPendingAtEveryStage() async throws {
    for stage in PendingStage.allCases {
      for completeOldBeforeDeadline in [false, true] {
        resetOwnershipHarness()
        seedStoredArtifact()
        let model = makeViewModel()
        let old = await startPending(stage, model: model)
        ports.importReplies = [.immediate(.imported(fixture.imported()))]
        ports.evaluationReplies = [
          .immediate(.permitted(fixture.permit())),
          .immediate(.blocked(VenueServingRejection(reason: .expired)!)),
        ]
        await model.restoreFromStorage()
        XCTAssertNotNil(ports.installedPermit)
        if completeOldBeforeDeadline {
          finishPending(stage, success: true)
          await old.value
        }
        let callsBefore = ports.calls.count
        clockReading = .available(unixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds)
        await expiry.fireAndWait()
        XCTAssertNil(ports.installedPermit, "W08 deadline independent of obsolete \(stage)")
        XCTAssertEqual(ports.calls.dropFirst(callsBefore).first, .clearing, "W08 clear first")
        XCTAssertEqual(model.status, .blocked(VenueServingRejection(reason: .expired)!))
        if !completeOldBeforeDeadline {
          finishPending(stage, success: true)
          await old.value
        }
        XCTAssertNil(ports.installedPermit, "W08 stale cleanup cannot resurrect")
        print("W08 stage=\(stage.rawValue) oldBeforeDeadline=\(completeOldBeforeDeadline)")
      }
    }
  }

  func testW14CancelledTaskCannotCommitNormalLateResultAtAnyStage() async throws {
    for stage in PendingStage.allCases {
      for success in [false, true] {
        resetOwnershipHarness()
        seedStoredArtifact()
        let model = makeViewModel()
        let task = await startPending(stage, model: model)
        let recordBeforeCancel = store.record
        let importsBeforeCancel = importedBundleBytes
        task.cancel()
        finishPending(stage, success: success)
        await task.value
        XCTAssertNil(ports.installedPermit, "W14 cancelled \(stage) result=\(success)")
        XCTAssertTrue(installCalls.isEmpty)
        XCTAssertEqual(store.record, recordBeforeCancel, "W14 no post-cancel persistence")
        XCTAssertEqual(importedBundleBytes, importsBeforeCancel, "W14 no next stage after cancel")
        XCTAssertEqual(model.status, .idle, "W14 cancelled workflow retires locally")
        print("W14 stage=\(stage.rawValue) success=\(success)")
      }
    }
  }

  func testW11ClockWhileBackgroundNeverInstallsAtAnyStage() async throws {
    for stage in PendingStage.allCases {
      resetOwnershipHarness()
      seedStoredArtifact()
      let model = makeViewModel()
      let task = await startPending(stage, model: model)
      model.sceneDidEnterBackground()
      await model.systemClockDidChange()
      finishPending(stage, success: true)
      await task.value
      await model.systemClockDidChange()
      XCTAssertNil(ports.installedPermit, "W11 \(stage) background clock")
      XCTAssertTrue(installCalls.isEmpty)
      XCTAssertFalse(expiry.isScheduled)
      print("W11 stage=\(stage.rawValue)")
    }
  }

  func testW18RepeatedStalePermitsConsumeAtMostOneImmediateRetry() async throws {
    let model = makeViewModel()
    clockReading = .available(unixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds)
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    // A finite tail makes the defective recursion terminate, so RED is an
    // assertion about excess work, never a test process hang or stack crash.
    ports.evaluationReplies = [
      .immediate(.permitted(fixture.permit())),
      .immediate(.permitted(fixture.permit())),
      .immediate(.permitted(fixture.permit())),
      .immediate(.blocked(VenueServingRejection(reason: .expired)!)),
    ]
    await supply(model)
    let evaluations = ports.calls.filter { if case .evaluating = $0 { return true }; return false }
    XCTAssertEqual(evaluations.count, 2, "W18 initial evaluation plus one fresh retry")
    XCTAssertNil(ports.installedPermit)
    XCTAssertFalse(expiry.isScheduled)
  }

  /// A delayed first verification can return a permit after its window has
  /// ended. The VM must perform only one fresh decision, then surface a
  /// terminal expired state without installing or spinning on the registry.
  func testW20DelayedVerificationCrossingDeadlineStopsAfterOneFreshDecision() async throws {
    let model = makeViewModel()
    let pending = await startPending(.evaluation, model: model)
    ports.evaluationReplies = [.immediate(.blocked(try rejection(.expired)))]
    clockReading = .available(unixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds)

    finishPending(.evaluation, success: true)
    await pending.value

    let evaluations = ports.calls.filter { if case .evaluating = $0 { return true }; return false }
    XCTAssertEqual(evaluations.count, 2)
    XCTAssertTrue(installCalls.isEmpty)
    XCTAssertEqual(model.status, .blocked(try rejection(.expired)))
    XCTAssertFalse(expiry.isScheduled)
  }

  func testW19NonfutureNotStartedDoesNotArmAnImmediateLoop() async throws {
    for offset in [Int64(0), -1] {
      resetOwnershipHarness()
      let model = makeViewModel()
      ports.importReplies = [.immediate(.imported(fixture.imported()))]
      ports.evaluationReplies = [.immediate(.blocked(
        VenueServingRejection(reason: .notStarted, recheckAtUnixSeconds: now + offset)!
      ))]
      await supply(model)
      XCTAssertFalse(expiry.isScheduled, "W19 recheck offset=\(offset) cannot enqueue immediate retries")
      XCTAssertNil(ports.installedPermit)
      print("W19 offset=\(offset)")
    }
  }
}


extension VenueSignedServingViewModelTests {
  func testW05DuplicateAcquisitionAllResultAndCompletionOrders() async throws {
    for oldFirst in [false, true] {
      for oldSuccess in [false, true] {
        for currentSuccess in [false, true] {
          resetOwnershipHarness()
          seedStoredArtifact()
          let model = makeViewModel()
          acquisition.replies = [.deferred, .deferred]
          ports.importReplies = [.immediate(.imported(fixture.imported()))]
          ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]
          let first = Task {
            await model.supply(bundleSource: URL(string: "https://old.example/b")!,
                               handoffSource: URL(string: "https://old.example/h")!, sourceDescription: "old")
          }
          await acquisition.waitForAcquisitionCount(1)
          let second = Task {
            await model.supply(bundleSource: URL(string: "https://current.example/b")!,
                               handoffSource: URL(string: "https://current.example/h")!, sourceDescription: "current")
          }
          await acquisition.waitForAcquisitionCount(2)
          for id in oldFirst ? [0, 1] : [1, 0] {
            let success = id == 0 ? oldSuccess : currentSuccess
            if success {
              XCTAssertTrue(acquisition.completeAcquisition(
                id: id, with: id == 0 ? fixture.artifact : replacementArtifact
              ))
            } else { XCTAssertTrue(acquisition.failAcquisition(id: id, with: .transportFailure)) }
            if id == 0 { await first.value } else { await second.value }
            if oldFirst && id == 0 {
              // The stale completion cannot release the pending current work.
              await model.sceneWillEnterForeground()
              await model.systemClockDidChange()
              XCTAssertTrue(importedBundleBytes.isEmpty, "W05 obsolete completion released current workflow")
            }
          }
          XCTAssertFalse(importedBundleBytes.contains(fixture.artifact.bundleBytes))
          XCTAssertEqual(store.record?.sourceDescription, currentSuccess ? "current" : "previous.example")
          XCTAssertEqual(store.record?.bundleBytes, currentSuccess ? replacementArtifact.bundleBytes : fixture.artifact.bundleBytes)
          XCTAssertEqual(installCalls.count, currentSuccess ? 1 : 0)
          print("W05 oldFirst=\(oldFirst) oldSuccess=\(oldSuccess) currentSuccess=\(currentSuccess)")
        }
      }
    }
  }

  func testW06ObsoleteAcquisitionCannotReleaseCurrentImportOrEvaluation() async throws {
    for stage in [PendingStage.importing, .evaluation] {
      for oldSuccess in [false, true] {
        resetOwnershipHarness()
        let model = makeViewModel()
        let old = await startPending(.acquisition, model: model)
        acquisition.replies = [.artifact(replacementArtifact)]
        ports.importReplies = stage == .importing ? [.deferred] : [.immediate(.imported(fixture.imported()))]
        ports.evaluationReplies = stage == .evaluation ? [.deferred] : [.immediate(.permitted(fixture.permit()))]
        let second = Task {
          await model.supply(bundleSource: URL(string: "https://current.example/b")!,
                             handoffSource: URL(string: "https://current.example/h")!, sourceDescription: "current")
        }
        await ports.waitForCallCount(stage == .importing ? 3 : 4)
        let before = ports.calls.count
        finishPending(.acquisition, success: oldSuccess)
        await old.value
        await model.sceneWillEnterForeground()
        XCTAssertEqual(ports.calls.count, before, "W06 obsolete task must not unlock current \(stage)")
        if stage == .importing {
          XCTAssertTrue(ports.completeImport(id: 0, with: .imported(fixture.imported())))
        } else {
          XCTAssertTrue(ports.completeEvaluation(id: 1, with: .permitted(fixture.permit())))
        }
        await second.value
        XCTAssertNotNil(ports.installedPermit)
        XCTAssertEqual(store.record?.sourceDescription, "current")
        print("W06 stage=\(stage.rawValue) oldSuccess=\(oldSuccess)")
      }
    }
  }

  func testW07ExplicitReloadOwnsEveryLateResultPartition() async throws {
    for stage in PendingStage.allCases {
      for success in [false, true] {
        resetOwnershipHarness()
        seedStoredArtifact()
        let model = makeViewModel()
        let old = await startPending(stage, model: model)
        let selectedRecord = store.record
        ports.importReplies = [.immediate(.imported(fixture.imported()))]
        ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]
        await model.restoreFromStorage()
        let selectedStatus = model.status
        let count = ports.calls.count
        finishPending(stage, success: success)
        await old.value
        XCTAssertEqual(model.status, selectedStatus)
        XCTAssertEqual(store.record, selectedRecord)
        XCTAssertEqual(ports.calls.count, count, "W07 no obsolete side effects")
        XCTAssertNotNil(ports.installedPermit)
        print("W07 stage=\(stage.rawValue) oldSuccess=\(success)")
      }
    }
  }

  func testW09StopRetiresEveryLateResultPartition() async throws {
    for stage in PendingStage.allCases {
      for success in [false, true] {
        resetOwnershipHarness()
        seedStoredArtifact()
        let model = makeViewModel()
        let old = await startPending(stage, model: model)
        model.stop()
        let recordAtStop = store.record
        let countAtStop = ports.calls.count
        finishPending(stage, success: success)
        await old.value
        await model.sceneWillEnterForeground()
        await model.systemClockDidChange()
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(store.record, recordAtStop)
        XCTAssertEqual(ports.calls.count, countAtStop)
        XCTAssertNil(ports.installedPermit)
        print("W09 stage=\(stage.rawValue) success=\(success)")
      }
    }
  }

  func testW10BackgroundRetainsSelectedWorkAcrossAllStagesAndForegroundOrders() async throws {
    for stage in PendingStage.allCases {
      for foregroundFirst in [false, true] {
        resetOwnershipHarness()
        seedStoredArtifact()
        let model = makeViewModel()
        let old = await startPending(stage, model: model)
        if stage == .evaluation { ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))] }
        model.sceneDidEnterBackground()
        if foregroundFirst { await model.sceneWillEnterForeground() }
        finishPending(stage, success: true)
        await old.value
        if !foregroundFirst {
          XCTAssertNil(ports.installedPermit)
          await model.sceneWillEnterForeground()
        }
        XCTAssertEqual(store.record?.bundleBytes, replacementArtifact.bundleBytes)
        XCTAssertFalse(importedBundleBytes.contains(fixture.artifact.bundleBytes), "W10 no automatic A fallback")
        XCTAssertNotNil(ports.installedPermit, "W10 selected workflow resumes \(stage)")
        print("W10 stage=\(stage.rawValue) foregroundFirst=\(foregroundFirst)")
      }
    }
  }

  func testW15QueuedExpiryCannotReviveStoppedOrReplacedWorkflow() async throws {
    for replacement in ["stop", "supply", "reload"] {
      resetOwnershipHarness()
      let model = makeViewModel()
      ports.importReplies = [.immediate(.imported(fixture.imported()))]
      ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]
      await supply(model)
      let queued = try XCTUnwrap(expiry.takeQueuedFire())
      if replacement == "stop" {
        model.stop()
      } else {
        ports.importReplies = [.immediate(.rejected(.definitionRejected))]
        if replacement == "supply" { await supply(model) }
        else { await model.restoreFromStorage() }
      }
      let count = ports.calls.count
      let status = model.status
      await queued()
      XCTAssertEqual(ports.calls.count, count)
      XCTAssertEqual(model.status, status)
      XCTAssertNil(ports.installedPermit)
      print("W15 replacement=\(replacement)")
    }
  }
}


extension VenueSignedServingViewModelTests {
  func testW13SessionLossRetiresPendingWorkAndRejectsLateResults() async throws {
    for stage in PendingStage.allCases {
      resetOwnershipHarness()
      seedStoredArtifact()
      let model = makeViewModel()
      model.beginSession(isForeground: true)
      let old = await startPending(stage, model: model)
      model.endSession()
      let recordAtLoss = store.record
      let countAtLoss = ports.calls.count
      XCTAssertEqual(model.status, .idle, "W13 synchronous session retirement")
      finishPending(stage, success: true)
      await old.value
      XCTAssertEqual(model.status, .idle)
      XCTAssertNil(ports.installedPermit)
      XCTAssertEqual(store.record, recordAtLoss)
      XCTAssertEqual(ports.calls.count, countAtLoss)
      // A new destination session starts stopped; it never restores by itself.
      model.beginSession(isForeground: true)
      await model.sceneWillEnterForeground()
      XCTAssertEqual(model.status, .idle)
      XCTAssertNil(ports.installedPermit)
      print("W13 stage=\(stage.rawValue)")
    }
  }

  func testW13SessionLossClearsCurrentEffectImmediately() async throws {
    let model = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]
    await supply(model)
    XCTAssertNotNil(ports.installedPermit)
    model.endSession()
    XCTAssertNil(ports.installedPermit)
    XCTAssertFalse(expiry.isScheduled)
    XCTAssertEqual(model.status, .idle)
  }
}


extension VenueSignedServingViewModelTests {
  func testInvalidConfiguredReplacementCannotClaimFailureWhileAnOlderPermitIsServing() async throws {
    let model = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]
    await supply(model)

    let permitBefore = ports.installedPermit
    let statusBefore = model.status
    XCTAssertNotNil(permitBefore)
    XCTAssertTrue(expiry.isScheduled)

    await model.supplyConfigured(
      canonicalEventIdHex: fixture.identity.eventIdHex,
      bundleURLTemplate: "http://venue.example/artifacts/{eventId}",
      handoffSource: URL(string: "https://venue.example/handoff")!,
      sourceDescription: "venue.example"
    )

    XCTAssertEqual(model.status, statusBefore, "invalid input must not contradict the active permit")
    XCTAssertEqual(ports.installedPermit?.identity.eventIdHex, permitBefore?.identity.eventIdHex)
    XCTAssertTrue(expiry.isScheduled)
  }

  func testConfiguredBundleTemplateUsesCanonicalEventIDForAcquisition() async throws {
    let model = makeViewModel()
    acquisition.replies = [.artifact(fixture.artifact)]
    ports.importReplies = [.immediate(.rejected(.definitionRejected))]
    let eventId = String(repeating: "ab", count: 32)
    let task = Task {
      await model.supplyConfigured(
        canonicalEventIdHex: eventId,
        bundleURLTemplate: "https://venue.example/artifacts/{eventId}",
        handoffSource: URL(string: "https://venue.example/handoff")!,
        sourceDescription: "venue.example"
      )
    }
    await acquisition.waitForAcquisitionCount(1)
    XCTAssertEqual(acquisition.requestedSources.first?.bundle.absoluteString,
                   "https://venue.example/artifacts/\(eventId)")
    XCTAssertEqual(acquisition.requestedSources.first?.handoff?.absoluteString,
                   "https://venue.example/handoff")
    _ = await task.value
  }

  func testConfiguredBundleTemplateRejectsNonHTTPSAndMalformedEventID() throws {
    let eventId = String(repeating: "ab", count: 32)
    XCTAssertNil(VenueBundleURLTemplate.url(template: "http://venue.example/{eventId}", eventIdHex: eventId))
    XCTAssertNil(VenueBundleURLTemplate.url(template: "https://venue.example/{eventId}", eventIdHex: "not-an-event-id"))
  }

  func testConfiguredAcquisitionFailureLeavesManualHandoffRescueAvailable() async throws {
    let model = makeViewModel()
    acquisition.replies = [.failure(.transportFailure)]
    await model.supplyConfigured(
      canonicalEventIdHex: String(repeating: "cd", count: 32),
      bundleURLTemplate: "https://venue.example/artifacts/{eventId}",
      handoffSource: URL(string: "https://venue.example/handoff")!,
      sourceDescription: "venue.example"
    )
    XCTAssertEqual(model.status, .acquisitionFailed(.transportFailure))
    XCTAssertTrue(acquisition.requestedSources.count == 1)
  }

  func testConfiguredAcquisitionRejectsAValidBundleForAnotherEvent() async throws {
    let model = makeViewModel()
    acquisition.replies = [.artifact(fixture.artifact)]
    let otherIdentity = VenueArtifactIdentity(
      eventIdHex: String(repeating: "ef", count: 32),
      definitionSequence: fixture.identity.definitionSequence,
      bundleDigestHex: fixture.identity.bundleDigestHex
    )
    ports.importReplies = [.immediate(.imported(VenueImportedBundle(
      identity: otherIdentity, publicArtifact: fixture.artifact
    )))]
    await model.supplyConfigured(
      canonicalEventIdHex: fixture.identity.eventIdHex,
      bundleURLTemplate: "https://venue.example/artifacts/{eventId}",
      handoffSource: URL(string: "https://venue.example/handoff")!,
      sourceDescription: "venue.example"
    )
    XCTAssertEqual(model.status, .acquisitionFailed(.eventIdentityMismatch))
    XCTAssertNil(store.record)
    XCTAssertTrue(installCalls.isEmpty)
  }

  func testW22FailedSaveIsVisibleAndDoesNotMasqueradeAsDurableReplacement() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("artifact.json")
    // Missing parent reliably fails atomic write without changing permissions.
    let failingStore = VenuePublicArtifactStore(fileURL: url)
    let record = VenuePublicArtifactRecord(
      bundleBytes: fixture.artifact.bundleBytes, handoffBytes: fixture.artifact.handoffBytes,
      sourceDescription: "memory-only", storedAt: Date()
    )
    failingStore.store(record)
    XCTAssertEqual(failingStore.record, record, "W22 current session retains public bytes")
    XCTAssertNotNil(failingStore.persistenceWriteFailure, "W22 write failure must be visible")
    XCTAssertNil(VenuePublicArtifactStore(fileURL: url).record, "W22 no false restart retention")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    failingStore.store(record)
    XCTAssertNil(failingStore.persistenceWriteFailure, "W22 an explicit successful retry clears failure")
    XCTAssertEqual(VenuePublicArtifactStore(fileURL: url).record, record)
  }

  func testAsynchronousRadioStopAfterInstallClearsServingLease() async throws {
    let viewModel = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]

    await supply(viewModel)
    XCTAssertEqual(viewModel.status, .serving(
      displayName: VenueServingContractFixture.displayName,
      stopAtUnixSeconds: VenueServingContractFixture.exclusiveStopUnixSeconds
    ))
    XCTAssertNotNil(ports.installedPermit)
    XCTAssertTrue(expiry.isScheduled)

    ports.emit(try XCTUnwrap(VenueRadioUpdate(state: .stopped)))

    XCTAssertEqual(viewModel.status, .idle)
    XCTAssertNil(ports.installedPermit)
    XCTAssertFalse(expiry.isScheduled)
    XCTAssertEqual(viewModel.radio.state, .stopped)
  }
}


extension VenueSignedServingViewModelTests {
  func testW14CancellationRetiresAuthorityBeforeNoncooperativeOperationReturns() async throws {
    for stage in PendingStage.allCases {
      resetOwnershipHarness()
      seedStoredArtifact()
      let model = makeViewModel()
      let pending = await startPending(stage, model: model)
      pending.cancel()
      // Cancellation retirement runs on MainActor. No external result is
      // delivered until this local-authority assertion has completed.
      for _ in 0..<100 where model.status != .idle { await Task.yield() }
      XCTAssertEqual(model.status, .idle)
      XCTAssertNil(ports.installedPermit)
      let calls = ports.calls.count
      await model.sceneWillEnterForeground()
      XCTAssertEqual(ports.calls.count, calls)
      finishPending(stage, success: true)
      await pending.value
      XCTAssertEqual(model.status, .idle)
      XCTAssertNil(ports.installedPermit)
    }
  }

  func testClockDiscontinuityDuringEvaluationRequiresFreshDecision() async throws {
    resetOwnershipHarness()
    let model = makeViewModel()
    let pending = await startPending(.evaluation, model: model)
    ports.evaluationReplies = [.immediate(.blocked(VenueServingRejection(reason: .expired)!))]
    await model.systemClockDidChange()
    finishPending(.evaluation, success: true)
    await pending.value
    XCTAssertNil(ports.installedPermit)
    XCTAssertEqual(model.status, .blocked(VenueServingRejection(reason: .expired)!))
    let decisions = ports.calls.filter { if case .evaluating = $0 { return true }; return false }
    XCTAssertEqual(decisions.count, 2)
  }
}

// MARK: - beid#702: screen 14's Saved pack area reads storage and nothing else

extension VenueSignedServingViewModelTests {
  private func savedPackRecord(_ source: String = "link, bundle from organizer.example") -> VenuePublicArtifactRecord {
    VenuePublicArtifactRecord(
      bundleBytes: fixture.artifact.bundleBytes,
      handoffBytes: fixture.artifact.handoffBytes,
      sourceDescription: source,
      storedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )
  }

  /// Screen 14's objects over `store`, with every port scripted, exactly as
  /// production builds them apart from the ports.
  private func makeOrganizerTools(store: VenuePublicArtifactStore) -> OrganizerToolsObjects {
    OrganizerToolsObjects(store: store) { [unowned self] store in
      VenueSignedServingViewModel(
        verifier: ports,
        broadcasting: ports,
        acquisition: acquisition,
        store: store,
        clock: { [unowned self] in self.clockReading },
        expiry: expiry
      )
    }
  }

  private func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("venue-artifact-702-\(UUID().uuidString).json")
  }

  // T1 — the four states and their order.
  func testSavedPackRowStateResolvesEveryStateInPriorityOrder() {
    let record = savedPackRecord()
    XCTAssertFalse(record.sourceDescription.isEmpty, "a real record must be the input")
    let resolve = SavedPackRowState.resolve

    // S0
    XCTAssertEqual(resolve(nil, false, false, false), SavedPackRowState.none)
    // S1: nothing held, and the unreadable file was set aside.
    XCTAssertEqual(resolve(nil, false, false, true), .unreadable)
    // S1: nothing held, and the unreadable file was left in place (writes suspended).
    XCTAssertEqual(resolve(nil, false, true, false), .unreadable)
    // S2: the source and time are the record's own, not substitutes.
    XCTAssertEqual(
      resolve(record, false, false, false),
      .saved(source: record.sourceDescription, storedAt: record.storedAt)
    )
    guard case .saved(let source, let storedAt) = resolve(record, false, false, false) else {
      return XCTFail("a durable record must resolve to .saved")
    }
    XCTAssertEqual(source, "link, bundle from organizer.example")
    XCTAssertEqual(storedAt, Date(timeIntervalSince1970: 1_790_000_000))
    // S3 over S2: a failed or suspended write still leaves `record` set.
    XCTAssertEqual(resolve(record, true, false, false), .notSaved(source: record.sourceDescription))
    XCTAssertEqual(resolve(record, false, true, false), .notSaved(source: record.sourceDescription))
    XCTAssertEqual(resolve(record, true, true, true), .notSaved(source: record.sourceDescription))
    // S2 over S1: a record held after a quarantine is what this device has now.
    XCTAssertEqual(
      resolve(record, false, false, true),
      .saved(source: record.sourceDescription, storedAt: record.storedAt)
    )
    // A failure with nothing held is not a pack that was not saved.
    XCTAssertEqual(resolve(nil, true, false, false), SavedPackRowState.none)
    XCTAssertEqual(resolve(nil, true, true, true), .unreadable)
  }

  // T1 — the store's real properties reach the resolver.
  func testSavedPackRowStateReadsTheStoresRealState() throws {
    // S0 on a fresh store.
    XCTAssertEqual(makeOrganizerTools(store: VenuePublicArtifactStore(fileURL: temporaryStoreURL())).savedPack, SavedPackRowState.none)

    // S2 after a durable write, read back through a fresh load.
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let record = savedPackRecord()
    VenuePublicArtifactStore(fileURL: url).store(record)
    let reloaded = VenuePublicArtifactStore(fileURL: url)
    XCTAssertEqual(reloaded.record, record, "the record must really have been written")
    XCTAssertEqual(
      makeOrganizerTools(store: reloaded).savedPack,
      .saved(source: record.sourceDescription, storedAt: record.storedAt)
    )

    // S3 from a real failed write (missing parent directory, as in W22).
    let failingURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("artifact.json")
    let failing = VenuePublicArtifactStore(fileURL: failingURL)
    failing.store(record)
    XCTAssertNotNil(failing.record)
    XCTAssertNotNil(failing.persistenceWriteFailure)
    XCTAssertEqual(makeOrganizerTools(store: failing).savedPack, .notSaved(source: record.sourceDescription))

    // S1 from a real quarantine.
    let corruptURL = temporaryStoreURL()
    try Data("not a record".utf8).write(to: corruptURL)
    let quarantined = VenuePublicArtifactStore(fileURL: corruptURL)
    let movedTo = try XCTUnwrap(quarantined.quarantinedFileURL, "the corrupt file must really be quarantined")
    defer { try? FileManager.default.removeItem(at: movedTo) }
    XCTAssertNil(quarantined.record)
    XCTAssertEqual(makeOrganizerTools(store: quarantined).savedPack, .unreadable)

    // S1 from a real unpreserved load: a DIRECTORY at the store's path exists,
    // cannot be read as data, and that read error is not a DecodingError, so
    // nothing is quarantined and writes are suspended instead.
    let blockedURL = temporaryStoreURL()
    try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: blockedURL) }
    let unpreserved = VenuePublicArtifactStore(fileURL: blockedURL)
    XCTAssertTrue(unpreserved.isPersistenceSuspended, "the unreadable path must really suspend writes")
    XCTAssertNil(unpreserved.quarantinedFileURL, "a read failure that is not a decode failure is left in place")
    XCTAssertNil(unpreserved.record)
    XCTAssertEqual(makeOrganizerTools(store: unpreserved).savedPack, .unreadable)
  }

  // T2 — building 14 and reading its state fetches nothing, verifies nothing
  // and touches no radio.
  func testOrganizerToolsReadsStorageWithoutFetchingVerifyingOrBroadcasting() async throws {
    store.store(savedPackRecord())
    XCTAssertNotNil(store.record, "a stored pack must exist, or there is nothing 14 could act on")

    let tools = makeOrganizerTools(store: store)
    XCTAssertEqual(tools.savedPack, .saved(source: savedPackRecord().sourceDescription, storedAt: savedPackRecord().storedAt))
    // Give any work construction may have started a chance to reach a port.
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(tools.savedPack, .saved(source: savedPackRecord().sourceDescription, storedAt: savedPackRecord().storedAt))

    XCTAssertTrue(ports.calls.isEmpty, "14 must not import, evaluate, install or clear: \(ports.calls)")
    XCTAssertTrue(acquisition.requestedSources.isEmpty, "14 must not fetch")
    XCTAssertEqual(tools.serving.status, .idle)

    // Positive control: the same doubles DO count when 14b acts, so the zeros
    // above are not a broken counter.
    ports.importReplies = [.immediate(.rejected(.registryUnavailable))]
    await tools.serving.restoreFromStorage()
    XCTAssertTrue(
      ports.calls.contains(.importing(id: 0, bundle: fixture.artifact.bundleBytes, handoff: fixture.artifact.handoffBytes)),
      "14b's reload must reach the verifier through these doubles: \(ports.calls)"
    )
    acquisition.replies = [.failure(.transportFailure)]
    await tools.serving.supply(
      bundleSource: URL(string: "https://venue.example/bundle")!,
      handoffSource: URL(string: "https://venue.example/handoff")!,
      sourceDescription: "venue.example"
    )
    XCTAssertEqual(acquisition.requestedSources.count, 1, "14b's supply must reach acquisition through this double")
  }

  /// 14 and 14b share ONE store: what 14b saves is what 14 then reports.
  func testOrganizerToolsViewModelWritesTheSameStoreFourteenReads() async throws {
    let tools = makeOrganizerTools(store: store)
    XCTAssertTrue(tools.store === store)
    XCTAssertEqual(tools.savedPack, SavedPackRowState.none)
    ports.importReplies = [.immediate(.rejected(.registryUnavailable))]
    acquisition.replies = [.artifact(fixture.artifact)]

    await tools.serving.supply(
      bundleSource: URL(string: "https://venue.example/bundle")!,
      handoffSource: URL(string: "https://venue.example/handoff")!,
      sourceDescription: "venue.example"
    )

    let record = try XCTUnwrap(tools.store.record, "14b's supply must have stored into 14's store")
    XCTAssertEqual(tools.savedPack, .saved(source: "venue.example", storedAt: record.storedAt))
  }

  // T3 — building 14 and reading its state writes nothing.
  func testOrganizerToolsLeavesTheStoredFileUntouched() async throws {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }
    VenuePublicArtifactStore(fileURL: url).store(savedPackRecord())
    let before = try Data(contentsOf: url)
    let inodeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
    XCTAssertFalse(before.isEmpty, "the stored file must exist and hold the record")
    XCTAssertNotNil(inodeBefore)

    let tools = makeOrganizerTools(store: VenuePublicArtifactStore(fileURL: url))
    XCTAssertEqual(tools.savedPack, .saved(source: savedPackRecord().sourceDescription, storedAt: savedPackRecord().storedAt))
    for _ in 0..<10 { await Task.yield() }
    _ = tools.savedPack

    XCTAssertEqual(try Data(contentsOf: url), before, "14 must not rewrite the stored pack")
    // An atomic write replaces the file even with identical bytes.
    let inodeAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
    XCTAssertEqual(inodeAfter, inodeBefore, "14 must not replace the stored file")
  }

  // T4 — 14b's departure ends serving, which is why 14 never shows it.
  func testEndSessionWhileServingStopsTheRadioAndForgetsTheServedEvent() async throws {
    let model = makeViewModel()
    ports.importReplies = [.immediate(.imported(fixture.imported()))]
    ports.evaluationReplies = [.immediate(.permitted(fixture.permit()))]
    await supply(model)
    guard case .serving = model.status else {
      return XCTFail("expected .serving before ending the session, got \(model.status)")
    }
    XCTAssertNotNil(model.servingEventIdHex)
    let clearsBefore = ports.calls.filter { $0 == .clearing }.count

    model.endSession()

    XCTAssertEqual(model.status, .idle)
    XCTAssertNil(model.servingEventIdHex)
    XCTAssertGreaterThan(ports.calls.filter { $0 == .clearing }.count, clearsBefore, "ending must clear the radio")
    XCTAssertNil(ports.installedPermit)
  }
}
#endif
