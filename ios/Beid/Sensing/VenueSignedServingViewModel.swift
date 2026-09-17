// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation

enum VenueBundleURLTemplate {
  static let placeholder = "{eventId}"

  /// Builds only an HTTPS URL for the canonical 32-byte event id. The id is
  /// already URL-safe hex; validating it here prevents a routing hint or an
  /// arbitrary template value from becoming an acquisition source.
  static func normalizedEventId(_ eventIdHex: String) -> String {
    eventIdHex.hasPrefix("0x") || eventIdHex.hasPrefix("0X")
      ? String(eventIdHex.dropFirst(2)).lowercased()
      : eventIdHex.lowercased()
  }

  static func url(template: String, eventIdHex: String) -> URL? {
    let normalized = normalizedEventId(eventIdHex)
    guard normalized.count == 64,
      normalized.allSatisfy({ $0.isHexDigit }),
      template.contains(placeholder),
      let result = URL(string: template.replacingOccurrences(of: placeholder, with: normalized)),
      result.scheme?.lowercased() == "https",
      result.host != nil else { return nil }
    return result
  }
}

/// Fires once at an absolute instant. Injected so tests reach expiry without
/// sleeping, and so the production timer is the only thing here that knows
/// about wall-clock scheduling.
@MainActor
protocol VenueExpiryScheduling: AnyObject {
  /// `stopAtUnixSeconds` is EXCLUSIVE and comes from the permit. Nothing here
  /// recomputes an ENIN boundary or rounds the instant; it only waits for it.
  func schedule(stopAtUnixSeconds: Int64, now: Int64, fire: @escaping @MainActor () async -> Void)
  func cancel()
}

@MainActor
final class VenueExpiryTimer: VenueExpiryScheduling {
  private var task: Task<Void, Never>?

  func schedule(stopAtUnixSeconds: Int64, now: Int64, fire: @escaping @MainActor () async -> Void) {
    cancel()
    let (difference, overflow) = stopAtUnixSeconds.subtractingReportingOverflow(now)
    let seconds = stopAtUnixSeconds <= now ? 0 : (overflow ? Int64.max : difference)
    // The instant is exclusive, so an already-reached deadline fires at once
    // rather than being nudged forward to make it schedulable.
    guard seconds > 0 else {
      task = Task { await fire() }
      return
    }
    task = Task { [weak self] in
      let nanos = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanos.overflow ? UInt64.max : nanos.partialValue)
      guard !Task.isCancelled else { return }
      self?.task = nil
      await fire()
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
/// Why a pasted or scanned venue link never became a request.
///
/// Deliberately its own type, beside `VenueAcquisitionFailure` and
/// `VenueImportFailure` rather than folded into either. Nothing was fetched and
/// nothing was verified, so an operator holding a mistyped link must not be told
/// that a bundle was rejected — the link never named one.
enum VenueLinkFailure: String, CaseIterable, Hashable {
  /// No absolute URI before the `#`, no fragment, or a fragment that is not the
  /// base64url of a `VenueHandoffV1`. The shared decoder decides all three.
  case malformedLink
  /// A six-field handoff. It is valid, and it names no bundle, so this screen has
  /// nothing to fetch. `venue-bundle.md` makes label 7 optional on purpose.
  case missingBundleUrl
  /// The handoff's `bundleUrl` is syntactically a URI but not one this app fetches.
  case unsupportedBundleUrl
}

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

  /// The event id the pasted link's own fragment named, published the moment the
  /// fragment decodes and before anything is fetched.
  ///
  /// Distinct from `servingEventIdHex`, which is copied off an installed permit.
  /// This one is only what the operator was handed: it says which event the link
  /// claims, not that the claim was verified. Issue #597 asks for it because
  /// Supply was previously silent, so a venue operator could not tell a link that
  /// decoded from one that did nothing.
  @Published private(set) var linkEventIdHex: String?

  /// Why the last link was refused, or nil.
  ///
  /// Deliberately NOT a `VenueServingStatus` case. A refused link is a fact about
  /// the text field, not about what the radio is doing: an operator already
  /// serving who fumbles a paste must keep serving. Routing this through `status`
  /// would have put a bad paste on the same path as a verdict, and every
  /// invalidating status transition clears the radio first — so a typo would have
  /// taken an event off the air, which is the accident class beid#597 exists to
  /// remove rather than relocate.
  @Published private(set) var linkFailure: VenueLinkFailure?

  private let verifier: any VenueBundleVerifying
  private var broadcasting: any VenueSignedContainerBroadcasting
  private let acquisition: any VenueArtifactAcquiring
  private let store: VenuePublicArtifactStore
  private let clock: () -> VenueClockReading
  private let expiry: any VenueExpiryScheduling
  private let canonicalEventIdHex: String?
  private let bundleURLTemplate: String?

  /// The effect lease and selected workflow have different lifetimes.
  /// Background revokes a lease but retains the selected public artifact.
  private var generation = UUID()

  private enum Stage { case acquiring, importing, evaluating, parked, settled }
  private struct Workflow {
    let id = UUID()
    var artifact: VenuePublicArtifact?
    var receipt: VenueImportedBundle?
    var expectedCanonicalEventIdHex: String?
    var stage: Stage
  }
  private var workflow: Workflow?
  private var activeOperation: UUID?
  private var operationTask: Task<Void, Never>?
  private var isBackgrounded = false
  private var sessionActive = true

  @Published private(set) var hasUnsavedArtifact = false

  /// The event of the permit that reached `installAndStart`, shown beside the
  /// display name while serving (beid#531). Read off the installed permit, not
  /// the import receipt: the permit is what is actually on the air, and the
  /// operator needs this value precisely to tell one event's pack from
  /// another's at the same venue.
  var servingEventIdHex: String? {
    guard case .serving = status else { return nil }
    return servingPermitIdentity?.eventIdHex
  }

  /// Written only immediately before `status = .serving`, and read only
  /// through `servingEventIdHex`'s `.serving` guard, so a value left from an
  /// earlier permit is never exposed once serving ends.
  private var servingPermitIdentity: VenueArtifactIdentity?

  var canonicalEventIdHexForAcquisition: String? { canonicalEventIdHex }

  private var eligible: Bool { sessionActive && !isBackgrounded }

  init(
    verifier: any VenueBundleVerifying,
    broadcasting: any VenueSignedContainerBroadcasting,
    acquisition: any VenueArtifactAcquiring,
    store: VenuePublicArtifactStore,
    clock: @escaping () -> VenueClockReading,
    expiry: (any VenueExpiryScheduling)? = nil,
    canonicalEventIdHex: String? = nil,
    bundleURLTemplate: String? = nil
  ) {
    self.verifier = verifier
    self.broadcasting = broadcasting
    self.acquisition = acquisition
    self.store = store
    self.clock = clock
    self.canonicalEventIdHex = canonicalEventIdHex
    self.bundleURLTemplate = bundleURLTemplate
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

  /// Suppresses callbacks caused by our own clear. A `.stopped` update from
  /// the SDK while serving is otherwise an external loss of the radio.
  private var isClearingRadio = false

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
    guard !isClearingRadio else { return }
    if update.state == .stopped {
      guard case .serving = status else { return }
      invalidate()
      status = .idle
      return
    }
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
    // The current selected workflow is deliberately NOT cleared. A radio failure is not an
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

  // MARK: - Workflow ownership

  /// Superseding an operation revokes its local authority without waiting for
  /// its network callback. Cancellation of cooperative ports releases resources.
  private func select(_ artifact: VenuePublicArtifact?, stage: Stage, expectedCanonicalEventIdHex: String? = nil) -> UUID {
    invalidate()
    operationTask?.cancel()
    operationTask = nil
    activeOperation = nil
    workflow = Workflow(artifact: artifact, receipt: nil, expectedCanonicalEventIdHex: expectedCanonicalEventIdHex, stage: stage)
    return workflow!.id
  }

  private func owns(_ owner: UUID, operation: UUID) -> Bool {
    sessionActive && workflow?.id == owner && activeOperation == operation
  }

  private func mayCommit(_ owner: UUID, operation: UUID) -> Bool {
    guard owns(owner, operation: operation) else { return false }
    guard !Task.isCancelled else {
      retire(owner: owner, operation: operation)
      return false
    }
    return true
  }

  private func retire(owner: UUID, operation: UUID) {
    guard owns(owner, operation: operation) else { return }
    stop()
  }

  private func runOperation(
    owner: UUID,
    body: @escaping @MainActor (UUID) async -> Void
  ) async {
    let operation = UUID()
    activeOperation = operation
    let task = Task { await body(operation) }
    operationTask = task
    await withTaskCancellationHandler {
      if Task.isCancelled { task.cancel() }
      await task.value
    } onCancel: { [weak self] in
      task.cancel()
      Task { @MainActor in self?.retire(owner: owner, operation: operation) }
    }
    // An obsolete completion cannot release a newer operation's barrier.
    if activeOperation == operation {
      activeOperation = nil
      operationTask = nil
    }
  }

  // MARK: - Requests

  func supply(bundleSource: URL, handoffSource: URL, sourceDescription: String, expectedCanonicalEventIdHex: String? = nil) async {
    guard sessionActive else { return }
    let owner = select(nil, stage: .acquiring, expectedCanonicalEventIdHex: expectedCanonicalEventIdHex)
    status = eligible ? .acquiring : .idle
    await runOperation(owner: owner) { [self] operation in
      let artifact: VenuePublicArtifact
      do {
        artifact = try await acquisition.acquire(bundleSource: bundleSource, handoffSource: handoffSource)
      } catch {
        guard mayCommit(owner, operation: operation) else { return }
        // Failed selection retires intent. Stored older bytes remain available
        // only to the explicit reload action.
        workflow = nil
        status = eligible ? .acquisitionFailed((error as? VenueAcquisitionFailure) ?? .transportFailure) : .idle
        return
      }
      guard mayCommit(owner, operation: operation) else { return }
      workflow?.artifact = artifact
      let configured = workflow?.expectedCanonicalEventIdHex != nil
      await resumeSelected(owner: owner, operation: operation)
      guard mayCommit(owner, operation: operation) else { return }
      if configured {
        guard let expected = workflow?.expectedCanonicalEventIdHex,
          let actual = workflow?.receipt?.identity.eventIdHex,
          VenueBundleURLTemplate.normalizedEventId(actual) == VenueBundleURLTemplate.normalizedEventId(expected) else { return }
      }
      store.store(VenuePublicArtifactRecord(
        bundleBytes: artifact.bundleBytes, handoffBytes: artifact.handoffBytes,
        sourceDescription: sourceDescription, storedAt: Date()))
      hasUnsavedArtifact = store.persistenceWriteFailure != nil || store.isPersistenceSuspended
      storedSourceDescription = sourceDescription
    }
  }

  /// Supplies from the single carrier a venue operator actually hands over: a
  /// link whose fragment holds the base64url `VenueHandoffV1`, pasted or scanned
  /// (beid#597).
  ///
  /// The fragment never reaches a server, so the handoff is treated as coming
  /// from whoever handed the link over — which is exactly what
  /// `protocol/spec/v0.1/venue-bundle.md` requires and what the previous
  /// two-URL form could not express, because it fetched the handoff from a host.
  ///
  /// Both the bytes and the fields come from `shared/`. Nothing here decodes
  /// base64url or CBOR: the bytes handed to the verifier are the bytes the shared
  /// decoder accepted, so there is no second, native opinion about what a link
  /// carries. Verification itself is unchanged — the same import compares every
  /// field this handoff shares with the bundle, and the same digest check runs.
  func supply(link rawLink: String) async {
    guard sessionActive else { return }
    let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
    linkEventIdHex = nil
    linkFailure = nil
    guard
      let handoffBytes = ExportedKotlinPackages.org.levarac.parallax.venue
        .decodeVenueHandoffLinkBytes(link: link),
      let handoff = ExportedKotlinPackages.org.levarac.parallax.venue
        .decodeVenueHandoffLink(link: link)
    else {
      linkFailure = .malformedLink
      return
    }
    linkEventIdHex = VenueKotlinBytes.hexString(VenueKotlinBytes.swiftBytes(handoff.eventId.toByteArray()))
    guard let bundleUrlText = handoff.bundleUrl else {
      linkFailure = .missingBundleUrl
      return
    }
    // `bundleUrl` passed the shared decoder's URI-syntax check, which deliberately
    // admits schemes this app does not fetch. Which transports are permitted is a
    // native policy, and it is enforced here rather than by widening that check.
    guard let bundleSource = URL(string: bundleUrlText),
      bundleSource.isFileURL || bundleSource.scheme?.lowercased() == "https"
    else {
      linkFailure = .unsupportedBundleUrl
      return
    }

    let owner = select(nil, stage: .acquiring)
    status = eligible ? .acquiring : .idle
    await runOperation(owner: owner) { [self] operation in
      let bundleBytes: Data
      do {
        bundleBytes = try await acquisition.acquireBundle(bundleSource: bundleSource)
      } catch {
        guard mayCommit(owner, operation: operation) else { return }
        workflow = nil
        status = eligible ? .acquisitionFailed((error as? VenueAcquisitionFailure) ?? .transportFailure) : .idle
        return
      }
      guard mayCommit(owner, operation: operation) else { return }
      let artifact = VenuePublicArtifact(
        bundleBytes: bundleBytes,
        handoffBytes: Data(VenueKotlinBytes.swiftBytes(handoffBytes))
      )
      workflow?.artifact = artifact
      await resumeSelected(owner: owner, operation: operation)
      guard mayCommit(owner, operation: operation) else { return }
      // Names where the BUNDLE came from. The handoff came from the link, and the
      // spec is explicit that a consumer credits it to whoever handed that over,
      // never to a host — so this string must not read as the handoff's origin.
      let description = "link, bundle from \(bundleSource.host ?? bundleUrlText)"
      store.store(VenuePublicArtifactRecord(
        bundleBytes: artifact.bundleBytes, handoffBytes: artifact.handoffBytes,
        sourceDescription: description, storedAt: Date()))
      hasUnsavedArtifact = store.persistenceWriteFailure != nil || store.isPersistenceSuspended
      storedSourceDescription = description
    }
  }

  /// Acquires the selected event's bundle when the app is configured for the
  /// operator endpoint. With no template or no canonical id, the existing
  /// manual URL flow remains the only path.
  func supplyConfigured(
    canonicalEventIdHex: String,
    bundleURLTemplate: String,
    handoffSource: URL,
    sourceDescription: String
  ) async {
    guard let bundleSource = VenueBundleURLTemplate.url(
      template: bundleURLTemplate, eventIdHex: canonicalEventIdHex
    ) else {
      status = .acquisitionFailed(.unsupportedScheme)
      return
    }
    await supply(bundleSource: bundleSource, handoffSource: handoffSource, sourceDescription: sourceDescription, expectedCanonicalEventIdHex: canonicalEventIdHex)
  }

  /// Reload is a new explicit selection and supersedes every older operation.
  func restoreFromStorage() async {
    guard sessionActive else { return }
    let owner = select(store.record?.artifact, stage: .parked)
    guard let record = store.record else {
      workflow = nil
      status = .idle
      return
    }
    storedSourceDescription = record.sourceDescription
    await runOperation(owner: owner) { [self] operation in
      await resumeSelected(owner: owner, operation: operation)
    }
  }

  func refresh() async {
    guard eligible, let owner = workflow?.id, activeOperation == nil else { return }
    invalidate()
    await runOperation(owner: owner) { [self] operation in
      await resumeSelected(owner: owner, operation: operation)
    }
  }

  func stop() {
    invalidate()
    operationTask?.cancel()
    operationTask = nil
    activeOperation = nil
    workflow = nil
    status = .idle
    // Both belong to the link that is no longer being acted on. Leaving them
    // would show an event id beside "Not serving."
    linkEventIdHex = nil
    linkFailure = nil
  }

  // MARK: - Lifecycle

  func beginSession(isForeground: Bool) {
    sessionActive = true
    isBackgrounded = !isForeground
  }

  func endSession() {
    stop()
    sessionActive = false
  }

  func sceneDidEnterBackground() {
    isBackgrounded = true
    invalidate()
    status = .idle
  }

  func sceneWillEnterForeground() async {
    isBackgrounded = false
    guard sessionActive else { return }
    await refresh()
  }

  func systemClockDidChange() async {
    guard eligible else { return }
    // No effect is installed while this operation is pending. Retain the
    // selection, but require a pending decision to use the new clock epoch.
    if activeOperation != nil {
      if workflow?.stage == .evaluating { generation = UUID() }
      return
    }
    await refresh()
  }

  // MARK: - Pipeline

  private func resumeSelected(owner: UUID, operation: UUID) async {
    guard mayCommit(owner, operation: operation) else { return }
    guard eligible else { workflow?.stage = .parked; status = .idle; return }
    if workflow?.receipt == nil {
      guard let artifact = workflow?.artifact else { return }
      workflow?.stage = .importing
      status = .importing
      let result = await verifier.importBundle(bundleBytes: artifact.bundleBytes, handoffBytes: artifact.handoffBytes)
      guard mayCommit(owner, operation: operation) else { return }
      switch result {
      case .rejected(let failure):
        workflow?.stage = .settled
        status = eligible ? .importRejected(failure) : .idle
        return
      case .imported(let imported):
        if let expected = workflow?.expectedCanonicalEventIdHex,
          VenueBundleURLTemplate.normalizedEventId(imported.identity.eventIdHex)
            != VenueBundleURLTemplate.normalizedEventId(expected) {
          workflow?.stage = .settled
          status = .acquisitionFailed(.eventIdentityMismatch)
          return
        }
        workflow?.receipt = imported
      }
    }
    guard eligible else { workflow?.stage = .parked; status = .idle; return }
    guard let imported = workflow?.receipt else { return }
    await evaluate(imported, owner: owner, operation: operation)
  }

  /// At most an initial decision plus one fresh decision. A stale result after
  /// background or a changed permit interval never becomes install authority.
  private func evaluate(_ imported: VenueImportedBundle, owner: UUID, operation: UUID) async {
    for attempt in 0...1 {
      guard mayCommit(owner, operation: operation) else { return }
      guard eligible else { workflow?.stage = .parked; status = .idle; return }
      workflow?.stage = .evaluating
      status = .evaluating(imported.identity)
      let lease = generation
      let decision = await verifier.evaluate(imported, clock: clock())
      guard mayCommit(owner, operation: operation) else { return }
      guard eligible else { workflow?.stage = .parked; status = .idle; return }
      // Even if foreground returned first, an old background-era decision is
      // revalidated. No recursive evaluation or immediate timer loop.
      if lease != generation {
        if attempt == 0 { continue }
        break
      }
      switch decision {
      case .blocked(let rejection):
        workflow?.stage = .settled
        status = .blocked(rejection)
        scheduleRecheckIfNeeded(for: rejection, generation: lease)
        return
      case .permitted(let permit):
        guard case .available(let now) = clock() else {
          workflow?.stage = .settled
          status = .blocked(VenueServingRejection(reason: .clockUnavailable)!)
          return
        }
        guard now >= permit.startAtUnixSeconds, now < permit.stopAtUnixSeconds else {
          if attempt == 0 { continue }
          break
        }
        install(permit, generation: lease, now: now)
        workflow?.stage = .settled
        return
      }
    }
    workflow?.stage = .parked
    status = .blocked(VenueServingRejection(reason: .expired)!)
  }

  /// `.notStarted` is the one rejection that names its own wake-up instant
  /// (`recheckAtUnixSeconds`). Without arming a timer for it, a device
  /// holding a not-yet-started pack never re-evaluates on its own and stays
  /// blocked until some unrelated event (foreground, clock change) happens
  /// to trigger a refresh (beid#530).
  private func scheduleRecheckIfNeeded(for rejection: VenueServingRejection, generation: UUID) {
    guard rejection.reason == .notStarted, let recheckAt = rejection.recheckAtUnixSeconds else { return }
    guard case .available(let now) = clock(), recheckAt > now else { return }
    expiry.schedule(stopAtUnixSeconds: recheckAt, now: now) { [weak self] in
      await self?.handleExpiry(generation: generation)
    }
  }

  private func install(_ permit: VenueServePermit, generation: UUID, now: Int64) {
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
      clearRadio()
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
      clearRadio()
      radio = VenueRadioUpdate(state: .failed, failure: failure)!
      status = .radioRefused(failure)
      return
    }

    // The synchronous install effect can cross the exclusive deadline. The
    // permit was checked before entering the effect, so check again before
    // publishing `.serving` or arming a timer against an expired permit.
    guard case .available(let installedAt) = clock() else {
      clearRadio()
      status = .blocked(VenueServingRejection(reason: .clockUnavailable)!)
      return
    }
    guard installedAt >= permit.startAtUnixSeconds,
      installedAt < permit.stopAtUnixSeconds else {
      clearRadio()
      status = .blocked(VenueServingRejection(reason: .expired)!)
      return
    }

    servingPermitIdentity = permit.identity
    status = .serving(displayName: permit.displayName, stopAtUnixSeconds: permit.stopAtUnixSeconds)

    // Run a timer against the exclusive instant the permit fixed.
    expiry.schedule(stopAtUnixSeconds: permit.stopAtUnixSeconds, now: installedAt) { [weak self] in
      await self?.handleExpiry(generation: generation)
    }
  }

  private func handleExpiry(generation: UUID) async {
    guard generation == self.generation else { return }
    // Expiry clears first, irrespective of outstanding obsolete work.
    invalidate()
    status = .blocked(VenueServingRejection(reason: .expired)!)
    await refresh()
  }

  /// Clears the radio FIRST, then invalidates every in-flight request.
  ///
  /// Order matters: a caller that bumped the generation before clearing would
  /// have a window in which the previous permit's bytes were still live while
  /// nothing owned them any more.
  @discardableResult
  private func invalidate() -> UUID {
    clearRadio()
    expiry.cancel()
    generation = UUID()
    return generation
  }

  private func clearRadio() {
    isClearingRadio = true
    broadcasting.clearAndStop()
    isClearingRadio = false
  }
}
