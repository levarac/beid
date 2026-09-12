// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Fires once at an absolute instant. Injected so tests reach expiry without
/// sleeping, and so the production timer is the only thing here that knows
/// about wall-clock scheduling.
@MainActor
protocol VenueExpiryScheduling: AnyObject {
  /// `stopAtUnixSeconds` is EXCLUSIVE and comes from the permit. Nothing here
  /// recomputes an ENIN boundary or rounds the instant; it only waits for it.
  func schedule(stopAtUnixSeconds: Int64, now: Int64, fire: @escaping () -> Void)
  func cancel()
}

@MainActor
final class VenueExpiryTimer: VenueExpiryScheduling {
  private var task: Task<Void, Never>?

  func schedule(stopAtUnixSeconds: Int64, now: Int64, fire: @escaping () -> Void) {
    cancel()
    let seconds = stopAtUnixSeconds - now
    // The instant is exclusive, so an already-reached deadline fires at once
    // rather than being nudged forward to make it schedulable.
    guard seconds > 0 else {
      fire()
      return
    }
    task = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
      guard !Task.isCancelled else { return }
      self?.task = nil
      fire()
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}

/// What the organizer screen is currently showing.
///
/// `imported` deliberately carries an identity and NO display name. A receipt
/// verifies identity, not a schedule, and `EventDefinitionV1` contains no name
/// at all — the name exists only on an SDK-verified permit. A case here that
/// could hold a name would be a case that invites presenting a receipt as
/// ready, so the type refuses to hold one.
enum VenueServingStatus: Equatable {
  case idle
  case acquiring
  case importing
  /// Identity verified. NOT a claim that serving is possible, permitted or
  /// scheduled — nothing may be installed from this state.
  case imported(VenueArtifactIdentity)
  case evaluating(VenueArtifactIdentity)
  /// The only state that means bytes were handed to the radio. Its facts are
  /// copied from the permit and never recomputed.
  case serving(displayName: String, stopAtUnixSeconds: Int64)
  case blocked(VenueServingRejection)
  case importRejected(VenueImportFailure)
  case acquisitionFailed(VenueAcquisitionFailure)
  /// The radio refused the bytes. Kept separate from `blocked` so an effect
  /// failure is never displayed as a verification verdict the verifier never
  /// issued.
  case radioRefused(VenueRadioFailure)
}

/// Drives the signed venue-serving screen (beid#432).
///
/// The rules this type exists to keep, none of which are defensive:
///
/// - It never derives an event id, digest, window or deadline. Every such
///   fact is copied off a permit, which is the only thing that fixes them.
/// - Import success is identity, never permission. Only `evaluate` returning
///   a permit reaches `installAndStart`.
/// - A stored artifact is re-imported and re-evaluated from its public bytes.
///   No receipt and no permit is ever restored.
/// - Every invalidating transition clears the radio FIRST and bumps the
///   request generation, so a late async completion cannot install bytes for
///   a request that has already been superseded.
@MainActor
final class VenueSignedServingViewModel: ObservableObject {
  @Published private(set) var status: VenueServingStatus = .idle
  @Published private(set) var radio: VenueRadioUpdate
  @Published private(set) var storedSourceDescription: String?

  private let verifier: any VenueBundleVerifying
  private var broadcasting: any VenueSignedContainerBroadcasting
  private let acquisition: any VenueArtifactAcquiring
  private let store: VenuePublicArtifactStore
  private let clock: () -> VenueClockReading
  private let expiry: any VenueExpiryScheduling

  /// Incremented by every invalidating transition. A completion whose captured
  /// generation no longer matches is discarded rather than installed.
  private var generation = 0

  /// The receipt for the artifact currently in play, kept so a refresh can
  /// re-evaluate without re-importing. Identity verification is clock-free and
  /// does not expire — only the serving DECISION does — so clearing the radio
  /// deliberately does not drop it. It is never persisted and is never
  /// authority to serve; only a fresh `evaluate` can permit anything.
  private var receipt: VenueImportedBundle?

  /// Whether the operator currently wants this device to serve.
  ///
  /// Without this, an explicit stop would be undone by the next foreground or
  /// clock change, because those refresh and a refresh that is permitted
  /// installs. A stop must outlast the app going to the background.
  private var wantsServing = false

  /// Ownership token for `wantsServing`, bumped by every writer of it.
  ///
  /// `generation` cannot answer this question, and using it was the defect.
  /// The two are asking different things:
  ///
  /// - `generation` asks "has this request been superseded, so must it stop
  ///   touching the screen." A lifecycle invalidation bumps it —
  ///   `sceneDidEnterBackground()` calls `invalidate()` — WITHOUT establishing
  ///   any new intent.
  /// - this asks "is the intent currently in force still the one this request
  ///   established, so may this request retract it."
  ///
  /// Gating the retraction on `generation` conflated them: a replacement fetch
  /// that failed after a background return looked superseded, skipped
  /// abandoning its own intent, and left the device free to restore and
  /// broadcast the event the operator was replacing.
  private var servingIntentEpoch = 0

  /// True for the whole of a `supply` call, from asking for a source until
  /// that request has resolved one way or the other.
  ///
  /// `refresh()` consults it BEFORE doing anything, because `receipt == nil`
  /// has three causes and only one of them warrants restoring the stored
  /// artifact:
  ///
  /// - nothing was ever supplied — restore, which is what the fallback exists
  ///   for
  /// - a supply is IN FLIGHT — the operator has asked for something else and
  ///   is waiting for it
  /// - a supply just FAILED — they asked for something else and did not get it
  ///
  /// Reading all three as the first one put the event being REPLACED on the
  /// air while its replacement was still downloading. This flag separates the
  /// second cause; the third is handled by retracting the intent, so the
  /// lifecycle entry points never reach `refresh()` at all.
  private var isSupplyInFlight = false

  /// Takes ownership of `wantsServing` for the caller. Every writer of that
  /// flag calls this, so "am I still the owner" is answerable by comparison.
  @discardableResult
  private func takeServingIntent() -> Int {
    servingIntentEpoch += 1
    return servingIntentEpoch
  }

  init(
    verifier: any VenueBundleVerifying,
    broadcasting: any VenueSignedContainerBroadcasting,
    acquisition: any VenueArtifactAcquiring,
    store: VenuePublicArtifactStore,
    clock: @escaping () -> VenueClockReading,
    expiry: (any VenueExpiryScheduling)? = nil
  ) {
    self.verifier = verifier
    self.broadcasting = broadcasting
    self.acquisition = acquisition
    self.store = store
    self.clock = clock
    // `VenueExpiryTimer` is `@MainActor`; a default-argument expression is not
    // evaluated in the initializer's own isolation, so the default is
    // constructed here in the (main-actor) init body instead of as a parameter
    // default. Same trap `VenueDeviceOrganizerViewModel` documents for
    // `VenueDeviceAssignmentStore`.
    self.expiry = expiry ?? VenueExpiryTimer()
    // A view model starts stopped; nothing is on the air until a permit is.
    radio = VenueRadioUpdate(state: .stopped)!
    storedSourceDescription = store.record?.sourceDescription
    self.broadcasting.onState = { [weak self] update in
      self?.handleRadioUpdate(update)
    }
  }

  /// Guards against a `clearAndStop()` whose own `onState` reports `.failed`.
  /// The scripted fake emits `.stopped` there, but the port does not promise
  /// that, and without this a production adapter that reported a failure while
  /// being cleared would drive this handler into unbounded recursion.
  private var isHandlingRadioFailure = false

  /// True only for the duration of `installAndStart`.
  ///
  /// The radio can fail SYNCHRONOUSLY inside that call — barnard reports
  /// `bluetooth_not_ready` inline, with no dispatch, and `startAdvertise()`
  /// cannot throw — so the handler runs while `install` is still between its
  /// call and its `status = .serving`. Nothing is `.serving` yet at that
  /// instant, which is precisely why the failure cannot be handled by the
  /// same state test the asynchronous case uses.
  private var isInstalling = false

  /// A failure that arrived during `installAndStart`, for `install` to act on
  /// once the call returns.
  ///
  /// Recorded rather than acted on immediately so the teardown does not run
  /// underneath a call that has not returned yet, and so `install` never sets
  /// `.serving` over it. The alternative — setting `.serving` BEFORE the call
  /// so the ordinary guard catches it — was rejected: it would display
  /// serving before any byte reached the radio, trading a false negative for
  /// a false positive in the one display beid#531 relies on.
  private var pendingInstallFailure: VenueRadioFailure?

  /// The radio's state is always recorded. A FAILURE additionally tears down
  /// the serving state, because the screen is the only thing telling the
  /// operator whether this device is actually serving.
  ///
  /// beid#531 was decided to ship without an operator confirmation gate, on
  /// the basis that the operator can see what is being broadcast once
  /// advertising starts. That makes this display a safety control. Leaving
  /// `status` on `.serving` after the radio died would make the control lie in
  /// the direction hardest to notice: the operator believes they are serving,
  /// attendees cannot join, and nothing on screen disagrees.
  private func handleRadioUpdate(_ update: VenueRadioUpdate) {
    radio = update
    guard update.state == .failed, let failure = update.failure else { return }
    if isInstalling {
      // Arrived from inside `installAndStart`, which has not returned. Hand it
      // to `install` rather than tearing down under a call still in progress;
      // `install` takes its failure path instead of claiming `.serving`.
      pendingInstallFailure = failure
      return
    }
    // Only a device that believes it is serving has anything to tear down.
    // This handler is long-lived and fires outside any request, so a late
    // failure can also arrive after an explicit stop or onto a blocked
    // screen; there it must not overwrite a verdict the verifier issued or an
    // idle state the operator chose.
    //
    // The cost of this rule, stated because it is a real one: the port
    // carries no request id, so a failure belonging to a PREVIOUS permit that
    // arrives after a newer one installed will tear the newer one down. That
    // is the over-eager direction, and it is the safe one — it ends in a
    // visible `.radioRefused` the operator can retry from, never in bytes
    // left on the air or a screen claiming to serve.
    guard case .serving = status else { return }
    guard !isHandlingRadioFailure else { return }
    isHandlingRadioFailure = true
    defer { isHandlingRadioFailure = false }

    // `invalidate()` rather than a hand-rolled sequence: it already clears the
    // radio BEFORE bumping the generation, in that order and for the reason
    // documented on it, and cancels the permit's deadline. Clearing it here
    // also re-enters this handler with `.stopped`, which is why `radio` is
    // reassigned afterwards rather than before -- otherwise that re-entrant
    // `.stopped` would be the last write and the radio would read as stopped
    // while the status reported a failure.
    invalidate()
    radio = VenueRadioUpdate(state: .failed, failure: failure)!
    // Report the effect failure as itself, never as a verification verdict --
    // the same separation the synchronous install-failure path keeps.
    status = .radioRefused(failure)
    // `wantsServing` is deliberately NOT cleared. A radio failure is not an
    // operator stop, so a later foreground return or clock change may retry.
    //
    // What makes that retry safe is the `pendingInstallFailure` check in
    // `install`, NOT this handler. On a retry against a still-dead radio,
    // barnard reports the constraint synchronously from inside
    // `installAndStart` and this handler is not the code that acts on it —
    // nothing is `.serving` at that instant. An earlier version of this
    // comment claimed the retry "reports itself again" through here, which
    // was false in exactly the path it was defending: the failure was
    // recorded and then stepped over, and `.serving` was displayed against a
    // dead radio on every retry after the first.
  }

  // MARK: - Requests

  /// Acquires from a file or HTTPS source, persists the public bytes, then
  /// imports and evaluates them.
  func supply(bundleSource: URL, handoffSource: URL, sourceDescription: String) async {
    let generation = invalidate()
    let intent = takeServingIntent()
    // Covers the whole call, not just the fetch: a refresh landing during the
    // import or the evaluation would bump the generation just the same and
    // discard the request the operator is waiting for.
    isSupplyInFlight = true
    defer { isSupplyInFlight = false }
    wantsServing = true
    // Replaced input: the previous receipt describes a different artifact and
    // must not survive into this request.
    receipt = nil
    status = .acquiring

    let artifact: VenuePublicArtifact
    do {
      artifact = try await acquisition.acquire(bundleSource: bundleSource, handoffSource: handoffSource)
    } catch let failure as VenueAcquisitionFailure {
      abandonReplacement(ifStillOwnedBy: intent)
      guard generation == self.generation else { return }
      status = .acquisitionFailed(failure)
      return
    } catch {
      abandonReplacement(ifStillOwnedBy: intent)
      guard generation == self.generation else { return }
      status = .acquisitionFailed(.transportFailure)
      return
    }
    guard generation == self.generation else { return }

    store.store(
      VenuePublicArtifactRecord(
        bundleBytes: artifact.bundleBytes,
        handoffBytes: artifact.handoffBytes,
        sourceDescription: sourceDescription,
        storedAt: Date()
      )
    )
    storedSourceDescription = sourceDescription
    await importAndEvaluate(artifact, generation: generation)
  }

  /// Drops the standing intent to serve after a replacement could not be
  /// fetched, WITHOUT touching the stored record.
  ///
  /// `supply` sets `wantsServing` and clears `receipt` before acquiring, so a
  /// failed fetch leaves a device that intends to serve, holds no receipt, and
  /// still has the PREVIOUS event's bundle in the store. The next foreground
  /// return or clock change would then pass its `wantsServing` guard, find no
  /// receipt in `refresh`, fall through to `restoreFromStorage`, and put the
  /// event the operator was replacing back on the air. Their last visible
  /// signal would be an error and the device's next autonomous act would be to
  /// broadcast what the error was about.
  ///
  /// The intent is cleared; the data is not. The stored bundle is still there
  /// and still loadable, deliberately: the operator may well want it back, and
  /// the screen's reload button calls `restoreFromStorage()` directly, which
  /// sets `wantsServing` itself. What this removes is only the AUTOMATIC
  /// resumption. `supply` already ran `invalidate()`, so nothing is on the air
  /// and no deadline is armed — the device lands idle with an error on screen
  /// and stays there until the operator chooses one of the two buttons.
  /// Runs BEFORE the generation guard in both catch branches, deliberately.
  /// Whether this request may still paint the screen and whether it must
  /// retract its own intent are separate questions, and a backgrounded app
  /// answers them differently: it may not paint, and it must still retract.
  ///
  /// `ifStillOwnedBy` is what keeps that from reopening the case it replaced.
  /// A request only retracts the intent it established itself; once a newer
  /// `supply`, a `restoreFromStorage` or an explicit `stop` has taken
  /// ownership, this is a no-op and their intent stands.
  private func abandonReplacement(ifStillOwnedBy intent: Int) {
    guard intent == servingIntentEpoch else { return }
    wantsServing = false
  }

  /// Re-imports the stored public bytes. This is the ONLY restore path: the
  /// bytes go back through the verifier exactly as if they had just arrived.
  func restoreFromStorage() async {
    let generation = invalidate()
    // Takes ownership of the intent, so an older in-flight `supply` that fails
    // afterwards cannot retract the intent this restore just established.
    takeServingIntent()
    wantsServing = true
    receipt = nil
    guard let record = store.record else {
      status = .idle
      return
    }
    storedSourceDescription = record.sourceDescription
    await importAndEvaluate(record.artifact, generation: generation)
  }

  /// Re-evaluates the current receipt against a freshly read clock. Used by
  /// expiry, foreground return and clock changes. It asks the verifier for a
  /// new decision; it never extends the deadline it was previously given.
  func refresh() async {
    // BEFORE `invalidate()`, deliberately, and this ordering is the fix rather
    // than an optimisation. `invalidate()` bumps the generation, and a supply
    // in flight is guarded on that generation — so refreshing underneath one
    // does not merely restore the wrong artifact, it also makes the
    // replacement the operator is waiting for fail its own guard when it
    // arrives and be discarded with nothing shown. A guard placed at the
    // `receipt == nil` fallback below would be too late to prevent that: the
    // generation has already moved by the time the fallback is reached.
    //
    // A supply owns the device until it resolves. Nothing here has anything to
    // re-decide meanwhile.
    guard !isSupplyInFlight else { return }
    let generation = invalidate()
    guard let receipt else {
      // Nothing has been imported this run and nothing is being supplied, so
      // the stored artifact is the only thing this could be about.
      await restoreFromStorage()
      return
    }
    await evaluate(receipt, generation: generation)
  }

  /// An explicit stop by the operator. Sticky: it survives backgrounding and
  /// clock changes, which is what stops a later refresh from silently putting
  /// this device back on the air.
  func stop() {
    invalidate()
    // An explicit stop owns the intent too: a `supply` still in flight must
    // not be the one that decides what the flag means after the operator has
    // deliberately stopped.
    takeServingIntent()
    wantsServing = false
    receipt = nil
    status = .idle
  }

  // MARK: - Lifecycle

  /// Scene departure requires clearing: the app is no longer in a position to
  /// observe expiry or a radio failure, so it must not leave bytes on the air.
  func sceneDidEnterBackground() {
    invalidate()
    status = .idle
  }

  func sceneWillEnterForeground() async {
    guard wantsServing else { return }
    await refresh()
  }

  /// A wall-clock discontinuity invalidates the comparison the permit was
  /// granted under, in either direction, so the answer is re-asked rather
  /// than recomputed from the deadline already held.
  func systemClockDidChange() async {
    guard wantsServing else { return }
    await refresh()
  }

  // MARK: - Pipeline

  private func importAndEvaluate(_ artifact: VenuePublicArtifact, generation: Int) async {
    status = .importing
    let result = await verifier.importBundle(
      bundleBytes: artifact.bundleBytes,
      handoffBytes: artifact.handoffBytes
    )
    guard generation == self.generation else { return }

    switch result {
    case .rejected(let failure):
      status = .importRejected(failure)
    case .imported(let imported):
      receipt = imported
      // Identity only. Deliberately no install and no readiness claim here.
      status = .imported(imported.identity)
      await evaluate(imported, generation: generation)
    }
  }

  private func evaluate(_ imported: VenueImportedBundle, generation: Int) async {
    status = .evaluating(imported.identity)
    let decision = await verifier.evaluate(imported, clock: clock())
    guard generation == self.generation else { return }

    switch decision {
    case .blocked(let rejection):
      status = .blocked(rejection)
      scheduleRecheckIfNeeded(for: rejection, generation: generation)
    case .permitted(let permit):
      await install(permit, imported: imported, generation: generation)
    }
  }

  /// `.notStarted` is the one rejection that names its own wake-up instant
  /// (`recheckAtUnixSeconds`). Without arming a timer for it, a device
  /// holding a not-yet-started pack never re-evaluates on its own and stays
  /// blocked until some unrelated event (foreground, clock change) happens
  /// to trigger a refresh (beid#530).
  private func scheduleRecheckIfNeeded(for rejection: VenueServingRejection, generation: Int) {
    guard rejection.reason == .notStarted, let recheckAt = rejection.recheckAtUnixSeconds else { return }
    guard case .available(let now) = clock() else { return }
    expiry.schedule(stopAtUnixSeconds: recheckAt, now: now) { [weak self] in
      Task { @MainActor in await self?.handleExpiry(generation: generation) }
    }
  }

  private func install(_ permit: VenueServePermit, imported: VenueImportedBundle, generation: Int) async {
    // The deadline must be schedulable before the bytes go on the air. Read
    // the clock first: serving with no stop instant is the one outcome worse
    // than not serving at all.
    let reading = clock()
    guard case .available(let now) = reading else {
      status = .blocked(VenueServingRejection(reason: .clockUnavailable)!)
      return
    }
    // BOTH ends, deliberately. The permit was verified for one ENIN, whose
    // wall-clock span is `[startAtUnixSeconds, stopAtUnixSeconds)`, and a
    // reading outside EITHER end is a reading the envelope was never checked
    // against.
    //
    // The upper end is beid#530: the permit expired between the moment
    // `evaluate` issued it and this clock read, and installing anyway for a
    // narrower window would still be the vulnerability the deadline exists to
    // prevent, only smaller.
    //
    // The lower end is its mirror, and was open while the upper end was fixed
    // twice. A clock moving BACKWARD across an ENIN boundary during
    // `evaluate` still satisfies `now < stopAtUnixSeconds` while falling
    // before the slice the envelope was verified for, so an upper-bound-only
    // guard installed it for a slice nothing had checked. The clock-change
    // notification is asynchronous and cannot win that race, so this guard is
    // the only thing standing in it.
    //
    // Either way the answer is re-asked with the fresh reading rather than
    // recomputed from the permit already in hand.
    guard now >= permit.startAtUnixSeconds, now < permit.stopAtUnixSeconds else {
      await evaluate(imported, generation: generation)
      return
    }

    pendingInstallFailure = nil
    isInstalling = true
    defer { isInstalling = false }
    do {
      try broadcasting.installAndStart(permit)
    } catch {
      // Clear AGAIN. A rejected install retains the PREVIOUS container, so
      // without this the last event's signed bytes would stay live under a
      // failure. The port puts this on the consumer, not on the
      // implementation: the scripted fake deliberately keeps the earlier
      // bytes until the consumer clears them, and the production adapter's
      // own clear does not discharge this obligation.
      broadcasting.clearAndStop()
      let failure = (error as? VenueRadioFailure) ?? .containerInstallRejected
      // Report the effect failure as itself, never as a verification verdict.
      radio = VenueRadioUpdate(state: .failed, failure: failure)!
      status = .radioRefused(failure)
      return
    }

    // `installAndStart` returned without throwing, which is NOT the same as
    // the radio being up: barnard returns normally with the radio dead and
    // reports the constraint through `onState` on the way. Check before
    // claiming to serve, or this method writes `.serving` straight over a
    // failure that already arrived.
    if let failure = pendingInstallFailure {
      pendingInstallFailure = nil
      // Same three steps, in the same order, as the thrown-install path
      // above: clear the container first, then report the radio, then the
      // status. No deadline has been armed yet, so there is none to cancel.
      broadcasting.clearAndStop()
      radio = VenueRadioUpdate(state: .failed, failure: failure)!
      status = .radioRefused(failure)
      return
    }

    status = .serving(displayName: permit.displayName, stopAtUnixSeconds: permit.stopAtUnixSeconds)

    // Run a timer against the exclusive instant the permit fixed.
    expiry.schedule(stopAtUnixSeconds: permit.stopAtUnixSeconds, now: now) { [weak self] in
      Task { @MainActor in await self?.handleExpiry(generation: generation) }
    }
  }

  private func handleExpiry(generation: Int) async {
    guard generation == self.generation else { return }
    await refresh()
  }

  /// Clears the radio FIRST, then invalidates every in-flight request.
  ///
  /// Order matters: a caller that bumped the generation before clearing would
  /// have a window in which the previous permit's bytes were still live while
  /// nothing owned them any more.
  @discardableResult
  private func invalidate() -> Int {
    broadcasting.clearAndStop()
    expiry.cancel()
    generation += 1
    return generation
  }
}
