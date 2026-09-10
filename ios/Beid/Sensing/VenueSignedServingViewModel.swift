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
      self?.radio = update
    }
  }

  // MARK: - Requests

  /// Acquires from a file or HTTPS source, persists the public bytes, then
  /// imports and evaluates them.
  func supply(bundleSource: URL, handoffSource: URL, sourceDescription: String) async {
    let generation = invalidate()
    wantsServing = true
    // Replaced input: the previous receipt describes a different artifact and
    // must not survive into this request.
    receipt = nil
    status = .acquiring

    let artifact: VenuePublicArtifact
    do {
      artifact = try await acquisition.acquire(bundleSource: bundleSource, handoffSource: handoffSource)
    } catch let failure as VenueAcquisitionFailure {
      guard generation == self.generation else { return }
      status = .acquisitionFailed(failure)
      return
    } catch {
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

  /// Re-imports the stored public bytes. This is the ONLY restore path: the
  /// bytes go back through the verifier exactly as if they had just arrived.
  func restoreFromStorage() async {
    let generation = invalidate()
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
    let generation = invalidate()
    guard let receipt else {
      // Nothing has been imported this run, so there is nothing to re-decide.
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
    case .permitted(let permit):
      install(permit, generation: generation)
    }
  }

  private func install(_ permit: VenueServePermit, generation: Int) {
    // The deadline must be schedulable before the bytes go on the air. Read
    // the clock first: serving with no stop instant is the one outcome worse
    // than not serving at all.
    let reading = clock()
    guard case .available(let now) = reading else {
      status = .blocked(VenueServingRejection(reason: .clockUnavailable)!)
      return
    }

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
